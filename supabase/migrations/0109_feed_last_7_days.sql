-- 0109_feed_last_7_days.sql
-- The Feed shows the last 7 days of entries, newest POSTED first (Eamon, 5 Nov): "the time it's
-- posted is what matters on the feed, not the time when the dish was ate".
--
--   1. entries.posted_at — when the entry reached Ate. `created_at` is "when you ate" (0018, 0063:
--      client-set on insert, moved by set_entry_date), so it cannot say when something was posted.
--      posted_at defaults to now() and no client can write it (entries keeps its column-level
--      INSERT / UPDATE grants from 0018, which do not name it). Backfill below.
--   2. entry_cards gets a trailing `posted_at` (additive; create-or-replace stays legal).
--   3. get_entry_feed gains a trailing optional `p_within_days`. NULL (every existing caller: older
--      builds, the tag pages) = the call exactly as it was. Set = only entries posted in the last
--      N days by the SERVER's clock, ordered (posted_at, id) desc, and the cursor pair is then the
--      last row's (posted_at, id). Index: entries_posted_idx (posted_at desc, id desc).
--
-- Backfill. Nothing recorded the post time, so it is estimated from the earliest server-stamped
-- moment after posting: the sort (sorted_at), the first photo row, the photo-matcher's stamps, and
-- updated_at (stamped by every later write). An entry never re-dated has created_at ≈ the post
-- time, so the estimate is floored at created_at. Only the new column is written; entries_biu is
-- paused for the one UPDATE so updated_at is not restamped (as 0033 did).

set search_path = public, extensions;

-- ===========================================================================
-- 1. entries.posted_at
-- ===========================================================================
alter table public.entries add column if not exists posted_at timestamptz;

alter table public.entries disable trigger entries_biu;
update public.entries e
   set posted_at = greatest(
         e.created_at,
         least(
           e.sorted_at,
           (select min(x.created_at) from public.entry_photos x where x.entry_id = e.id),
           e.photos_located_at,
           e.photos_matched_at,
           e.photos_match_tried_at,
           e.updated_at
         )
       )
 where e.posted_at is null;
alter table public.entries enable trigger entries_biu;

alter table public.entries alter column posted_at set default now();
alter table public.entries alter column posted_at set not null;

comment on column public.entries.posted_at is
  'When the entry was posted to Ate (server clock, never client-written). created_at is when it was eaten. The Feed orders and windows on this (0109).';

create index if not exists entries_posted_idx on public.entries (posted_at desc, id desc);

-- ===========================================================================
-- 2. entry_cards — 0074's view verbatim, plus the trailing `posted_at`.
-- ===========================================================================
create or replace view public.entry_cards
with (security_invoker = true) as
  select
    e.id,
    e.author_id,
    e.body,
    e.visibility,
    e.restaurant_id,
    e.restaurant_source,
    e.order_number,
    e.sort_status,
    e.sorted_at,
    e.created_at,
    e.updated_at,
    (e.author_id = (select auth.uid())) as is_mine,
    jsonb_build_object(
      'id', p.id, 'username', p.username, 'name', p.name,
      'avatar_url', p.avatar_url, 'city', p.city
    ) as author,
    case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'name', r.name, 'address', r.address,
      'city', r.city, 'cuisine', r.cuisine,
      'locality', public.place_locality(r.address, r.city)
    ) end as place,
    coalesce(ph.photos, '[]'::jsonb) as photos,
    coalesce(ph.photo_count, 0)      as photo_count,
    coalesce(it.items, '[]'::jsonb)  as items,
    coalesce(it.dish_count, 0)       as dish_count,
    it.avg_score,
    e.place_offset,
    char_length(e.place_query) as place_length,
    -- 0058: "ate with" — see entry_with_people.
    public.entry_with_people(e.id) as companions,
    -- 0109: when it was posted (the Feed's order); created_at stays "when you ate".
    e.posted_at
  from public.entries e
  join public.profiles p on p.id = e.author_id
  left join public.restaurants r on r.id = e.restaurant_id
  left join lateral (
    select
      jsonb_agg(jsonb_build_object('url', x.photo_url, 'position', x.position)
                order by x.position) as photos,
      count(*)::int as photo_count
    from public.entry_photos x
    where x.entry_id = e.id
  ) ph on true
  left join lateral (
    select
      jsonb_agg(jsonb_build_object(
        'review_id', v.id,
        'dish_id',   v.dish_id,
        'dish_name', d.name,
        'score',     v.score,
        'note',      v.note,
        'position',  v.entry_position,
        'saved',     (s.user_id is not null),
        'evidence_offset', v.evidence_offset,
        'evidence_length', char_length(v.score_evidence),
        'mention_offset',  v.mention_offset,
        'mention_length',  char_length(v.mention_text),
        'corrected', (v.corrected_at is not null),
        'cover_url', public.dish_cover_url(v.dish_id),
        'tags', to_jsonb(v.tags),
        -- 0074: which of `tags` came from the author's diet ([] when none) — the app hides these
        -- from the author on their own screens; everyone else sees every tag.
        'diet_tags', to_jsonb(v.diet_tags)
      ) order by v.entry_position nulls last, v.created_at, v.id) as items,
      count(*)::int as dish_count,
      round(avg(v.score), 2)::numeric(3,2) as avg_score
    from public.reviews v
    join public.dishes d on d.id = v.dish_id
    left join public.saves s on s.dish_id = v.dish_id and s.user_id = (select auth.uid())
    where v.entry_id = e.id
  ) it on true;

-- ===========================================================================
-- 3. get_entry_feed + p_within_days. 0057's body verbatim but for the window.
-- ===========================================================================
drop function if exists browse.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text);
drop function if exists public.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text);

create function public.get_entry_feed(
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20,
  p_include_own       boolean     default false,
  p_area              text        default null,
  p_city              text        default null,
  p_kind              text        default null,
  p_slug              text        default null,
  p_within_days       int         default null
)
returns setof public.entry_cards
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_area   text   := nullif(lower(btrim(coalesce(p_area, ''))), '');
  v_city   text   := nullif(lower(btrim(coalesce(p_city, ''))), '');
  v_limit  int    := least(greatest(p_page_size, 1), 50);
  v_places uuid[];
  v_tagged uuid[];
  v_since  timestamptz;
begin
  if current_user = 'anon' then
    return query select * from browse.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, p_include_own, p_area, p_city, p_kind, p_slug, p_within_days);
    return;
  end if;

  if p_within_days is not null then
    if p_within_days < 1 or p_within_days > 365 then
      raise exception 'p_within_days' using errcode = '22023';
    end if;
    v_since := now() - make_interval(days => p_within_days);
  end if;

  -- The city's places and the tag's dishes, once — never per row.
  if v_city is not null then
    v_places := coalesce(array(select pc.restaurant_id from public.place_cities pc where pc.city = v_city), '{}');
  end if;
  v_tagged := public.tag_dish_ids(p_kind, p_slug);

  if v_since is null then
    -- As it always was: by when it was eaten, keyset (created_at, id).
    return query
    select c.*
    from public.entry_cards c
    where (p_include_own or c.author_id <> (select auth.uid()))
      and (v_area is null or lower(btrim(c.place ->> 'locality')) = v_area)
      and (v_city is null or c.restaurant_id = any(v_places))
      and (v_tagged is null or exists (
            select 1 from public.reviews v where v.entry_id = c.id and v.dish_id = any(v_tagged)))
      and (
        p_cursor_created_at is null
        or (c.created_at, c.id) <
           (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
      )
    order by c.created_at desc, c.id desc
    limit v_limit;
    return;
  end if;

  -- The window: posted in the last N days, newest posted first, keyset (posted_at, id) — the
  -- cursor pair carries the last row's posted_at (entries_posted_idx).
  return query
  select c.*
  from public.entry_cards c
  where c.posted_at >= v_since
    and (p_include_own or c.author_id <> (select auth.uid()))
    and (v_area is null or lower(btrim(c.place ->> 'locality')) = v_area)
    and (v_city is null or c.restaurant_id = any(v_places))
    and (v_tagged is null or exists (
          select 1 from public.reviews v where v.entry_id = c.id and v.dish_id = any(v_tagged)))
    and (
      p_cursor_created_at is null
      or (c.posted_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.posted_at desc, c.id desc
  limit v_limit;
end;
$$;

comment on function public.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text, int) is
  'The Feed: every entry the viewer may see (blocked/deactivated authors gone), newest first, keyset (created_at, id). p_include_own defaults false. p_area (0038) = a feed_areas() locality; p_city (0046) = a cities.id — only entries whose place maps to it (place_cities); unknown → []. NULL = everywhere. p_kind + p_slug (0057): only entries with at least one line whose dish carries that tag; both NULL = no filter. p_within_days (0109, 1–365): only entries POSTED in the last N days (server clock), ordered and keyed on (posted_at, id) instead — p_cursor_created_at then carries the last row''s posted_at; NULL = no window, the old order. anon → browse twin.';

create function browse.get_entry_feed(
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int,
  p_include_own       boolean,
  p_area              text,
  p_city              text,
  p_kind              text,
  p_slug              text,
  p_within_days       int
)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.*
  from public.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, true, p_area, p_city, p_kind, p_slug, p_within_days) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
    and exists (select 1 from public.profiles p where p.id = c.author_id and p.deleted_at is null)
  order by case when p_within_days is null then r.created_at else r.posted_at end desc, r.id desc;
$$;

revoke all on function public.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text, int) from public;
grant execute on function public.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text, int) to authenticated, anon, service_role;
revoke all on function browse.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text, int) from public;
grant execute on function browse.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text, int) to anon;
