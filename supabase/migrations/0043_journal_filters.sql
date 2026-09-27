-- 0043_journal_filters.sql
-- Ate backend — round 4: JOURNAL FILTER AND SORT. The Journal lists YOUR visits; it can now be
-- narrowed (a place, a minimum score, a dietary tag, a date range) and re-ordered (newest, oldest,
-- or top — by the entry's best score). The read returns entry IDS IN ORDER plus the cursor fields;
-- the client reads the cards themselves from `entry_cards` (the one entry shape, never a second one).
--
--   my_entries(p_sort, p_restaurant_id, p_min_score, p_tag, p_from, p_to, p_limit, cursor…, p_tz)
--     → (id, created_at, best_score)
--     p_sort       newest (default) · oldest · top; anything else is 22023.
--     best_score   max(score) over the entry's lines; NULL when no line is scored.
--     p_min_score  best_score >= it (so unscored entries drop out once it is set).
--     p_tag        one dietary code: some line of the entry carries it. An unknown code matches nothing.
--     p_from/p_to  inclusive calendar dates of the VISIT (entries.created_at), in p_tz — default
--                  Australia/Melbourne, the launch market; pass the device zone, as statement_months.
--     KEYSET (pass every field from the LAST row, with the same filters):
--       newest → (created_at desc, id desc)          p_cursor_created_at, p_cursor_id
--       oldest → (created_at asc,  id asc)           p_cursor_created_at, p_cursor_id
--       top    → (best_score desc NULLS LAST, created_at desc, id desc)
--                                                   p_cursor_best_score (may be null), _created_at, _id
--     p_limit default 30, clamped 1..100.
--
--   my_entry_places(p_limit, cursor…) → (restaurant_id, name, locality, entry_count)
--     The places your entries are at — the Journal's place filter. Busiest first, then name, then id;
--     keyset (entry_count desc, name, restaurant_id). Called with no arguments it returns them all.
--
-- OWNER-ONLY by construction: both filter on author_id = auth.uid() (not merely on RLS, which since
-- 0033 lets anyone read anyone's entries). SECURITY INVOKER. anon has no EXECUTE (42501).
--
-- WIRE IMPACT: ADDITIVE — two new RPCs. Nothing existing changes.

set search_path = public, extensions;

-- ===========================================================================
-- 1. my_entries
-- ===========================================================================
create or replace function public.my_entries(
  p_sort              text        default 'newest',
  p_restaurant_id     uuid        default null,
  p_min_score         numeric     default null,
  p_tag               text        default null,
  p_from              date        default null,
  p_to                date        default null,
  p_limit             int         default 30,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_cursor_best_score numeric     default null,
  p_tz                text        default 'Australia/Melbourne'
)
returns table (
  id         uuid,
  created_at timestamptz,
  best_score numeric(2,1)
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_me   uuid := auth.uid();
  v_sort text := lower(btrim(coalesce(p_sort, 'newest')));
  v_tag  text := nullif(lower(btrim(coalesce(p_tag, ''))), '');
  v_tz   text := coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Australia/Melbourne');
  v_lim  int  := least(greatest(coalesce(p_limit, 30), 1), 100);
begin
  if v_me is null then
    raise exception 'my_entries needs a signed-in caller' using errcode = '42501';
  end if;
  if v_sort not in ('newest', 'oldest', 'top') then
    raise exception 'p_sort must be newest, oldest or top (got %)', p_sort using errcode = '22023';
  end if;

  return query
  with base as (
    select e.id,
           e.created_at,
           (select max(v.score) from public.reviews v where v.entry_id = e.id) as best_score
    from public.entries e
    where e.author_id = v_me
      and (p_restaurant_id is null or e.restaurant_id = p_restaurant_id)
      and (p_from is null or (e.created_at at time zone v_tz)::date >= p_from)
      and (p_to   is null or (e.created_at at time zone v_tz)::date <= p_to)
      and (v_tag is null or exists (
            select 1 from public.reviews v where v.entry_id = e.id and v_tag = any(v.tags)))
  )
  select b.id, b.created_at, b.best_score::numeric(2,1)
  from base b
  where (p_min_score is null or b.best_score >= p_min_score)
    and (
      p_cursor_id is null
      or (v_sort = 'newest' and (b.created_at, b.id) < (p_cursor_created_at, p_cursor_id))
      or (v_sort = 'oldest' and (b.created_at, b.id) > (p_cursor_created_at, p_cursor_id))
      or (v_sort = 'top' and (
            case
              when p_cursor_best_score is null then
                -- the cursor is already in the unscored tail
                b.best_score is null and (b.created_at, b.id) < (p_cursor_created_at, p_cursor_id)
              else
                b.best_score is null
                or b.best_score < p_cursor_best_score
                or (b.best_score = p_cursor_best_score
                    and (b.created_at, b.id) < (p_cursor_created_at, p_cursor_id))
            end))
    )
  order by
    case when v_sort = 'top'    then b.best_score end desc nulls last,
    case when v_sort = 'oldest' then b.created_at end asc,
    case when v_sort = 'oldest' then b.id         end asc,
    b.created_at desc,
    b.id desc
  limit v_lim;
end;
$$;

comment on function public.my_entries(text, uuid, numeric, text, date, date, int, timestamptz, uuid, numeric, text) is
  'Round 4 Journal: the caller''s own entry ids in order (newest | oldest | top by best line score, unscored last), filtered by place, min best score, one dietary tag, and visit dates (inclusive, in p_tz). Read the cards from entry_cards. Keyset: newest/oldest (created_at, id); top (best_score desc nulls last, created_at desc, id desc) — pass every field of the last row, with the same filters.';

-- ===========================================================================
-- 2. my_entry_places
-- ===========================================================================
create or replace function public.my_entry_places(
  p_limit                int  default null,
  p_cursor_entry_count   int  default null,
  p_cursor_name          text default null,
  p_cursor_restaurant_id uuid default null
)
returns table (
  restaurant_id uuid,
  name          text,
  locality      text,
  entry_count   int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select g.restaurant_id, g.name, g.locality, g.entry_count
  from (
    select r.id                                     as restaurant_id,
           r.name,
           public.place_locality(r.address, r.city) as locality,
           count(*)::int                            as entry_count
    from public.entries e
    join public.restaurants r on r.id = e.restaurant_id
    where e.author_id = (select auth.uid())
    group by r.id
  ) g
  where p_cursor_restaurant_id is null
     or (-g.entry_count, g.name, g.restaurant_id)
        > (-coalesce(p_cursor_entry_count, 0), coalesce(p_cursor_name, ''), p_cursor_restaurant_id)
  order by g.entry_count desc, g.name, g.restaurant_id
  limit case when p_limit is null then null else least(greatest(p_limit, 1), 500) end;
$$;

comment on function public.my_entry_places(int, int, text, uuid) is
  'Round 4 Journal place filter: the places the caller''s own entries are at, with how many visits each. Busiest first, then name, then id; keyset (entry_count, name, restaurant_id). No arguments = all of them.';

-- ===========================================================================
-- GRANTS — signed-in only.
-- ===========================================================================
revoke all on function public.my_entries(text, uuid, numeric, text, date, date, int, timestamptz, uuid, numeric, text) from public, anon;
revoke all on function public.my_entry_places(int, int, text, uuid) from public, anon;
grant execute on function public.my_entries(text, uuid, numeric, text, date, date, int, timestamptz, uuid, numeric, text) to authenticated;
grant execute on function public.my_entry_places(int, int, text, uuid) to authenticated;
