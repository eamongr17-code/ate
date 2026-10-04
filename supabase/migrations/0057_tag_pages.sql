-- 0057_tag_pages.sql
-- Ate backend — THE CATEGORY (TAG) PAGE (design/rebuild/discover.html) and Feed shelves seeded without
-- asking. Two existing reads learn a tag filter; one new read says which tags a viewer favours.
--
--   new_to_record(p_city, p_since, p_limit, p_kind, p_slug) — + the tag: only dishes carrying it.
--   get_entry_feed(…, p_city, p_kind, p_slug) — + the tag: only entries with at least one line whose
--       dish carries it. Same keyset (created_at, id), same area/city filters.
--   my_taste_tags(p_city, p_limit 12) → (kind, slug, label, weight): the style and cuisine tags on
--       dishes the viewer scored 4.5+ or saved, weighted per line — a 4.5 counts 1, a 5.0 or a 6
--       counts 2 — plus 1 per saved dish; tags already in the viewer's user_cravings are left out.
--       Best first: weight desc, lower(label), kind, slug. p_city keeps only dishes whose place is in that
--       city (NULL = everywhere; unknown → []). Signed out → [].
--
-- THE TAG (both filters): p_kind ∈ style | cuisine | suburb | city | diet, p_slug its slug — exactly
--   dishes_by_tag's vocabulary (0053/0055): stored kinds from dish_tag_links; diet by the live consensus
--   rule (dish_consensus_tags). Both NULL (the default) = no filter = the old behaviour, row for row.
--   Only one of the two, or an unknown kind → 22023. An unknown slug → [].
--
-- SIGNED OUT: unchanged dispatch — anon goes to the browse twins (0034's pattern), which now pass the
--   tag through. my_taste_tags answers [] to anon.
--
-- LANDMINE 7: both changed reads gain parameters, so each is DROPPED (browse twin first: it is the
--   dependent) and CREATED, never create-or-replace (a second overload breaks named-argument calls),
--   and the grants are restated. Old calls bind unchanged: the new parameters are trailing defaults.
--
-- WIRE IMPACT: ADDITIVE — two optional trailing parameters on new_to_record and get_entry_feed; one new
--   RPC. No existing parameter, column or ordering changes meaning.

set search_path = public, extensions;

-- ===========================================================================
-- 1. The tag's dishes, once per call. NULL when no tag was asked for (no filter).
-- ===========================================================================
create or replace function public.tag_dish_ids(p_kind text, p_slug text)
returns uuid[]
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
declare
  v_kind text := nullif(lower(btrim(coalesce(p_kind, ''))), '');
  v_slug text := nullif(lower(btrim(coalesce(p_slug, ''))), '');
begin
  if v_kind is null and v_slug is null then
    return null;
  end if;
  if v_kind is null or v_slug is null then
    raise exception 'p_kind and p_slug go together (got %, %)', p_kind, p_slug using errcode = '22023';
  end if;
  if v_kind not in ('style', 'cuisine', 'suburb', 'city', 'diet') then
    raise exception 'p_kind must be style, cuisine, suburb, city or diet (got %)', p_kind using errcode = '22023';
  end if;
  if v_kind = 'diet' then
    -- any dish with a line carrying the code, kept only if the consensus lists it (dishes_by_tag's rule)
    return coalesce(array(
      select distinct v.dish_id from public.reviews v
      where v_slug = any(v.tags) and v.dish_id is not null
        and v_slug = any(public.dish_consensus_tags(v.dish_id))), '{}');
  end if;
  return coalesce(array(
    select t.dish_id from public.dish_tag_links t where t.kind = v_kind and t.slug = v_slug), '{}');
end;
$$;

comment on function public.tag_dish_ids(text, text) is
  '0057: the dishes carrying (p_kind, p_slug) — dish_tag_links for style/cuisine/suburb/city, the consensus rule for diet. NULL when both are NULL (no filter). One of the two, or an unknown kind → 22023.';

revoke all on function public.tag_dish_ids(text, text) from public, anon;
grant execute on function public.tag_dish_ids(text, text) to authenticated, service_role;

-- ===========================================================================
-- 2. new_to_record + the tag. 0055's body verbatim but for the tag filter in `recent`.
-- ===========================================================================
drop function if exists browse.new_to_record(text, timestamptz, int);
drop function if exists public.new_to_record(text, timestamptz, int);

create function public.new_to_record(
  p_city  text        default null,
  p_since timestamptz default null,
  p_limit int         default 6,
  p_kind  text        default null,
  p_slug  text        default null
)
returns table (
  dish_id         uuid,
  name            text,
  restaurant_name text,
  suburb          text,
  kind            text,
  cover_url       text,
  saved           boolean,
  at              timestamptz
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_uid    uuid        := auth.uid();
  -- the client's last open, NULL → 7 days; clamped to 90 days back (a long absence is not a scan of everything)
  v_since  timestamptz := greatest(coalesce(p_since, now() - interval '7 days'), now() - interval '90 days');
  v_lim    int         := least(greatest(coalesce(p_limit, 6), 1), 20);
  v_places uuid[];
  v_tagged uuid[];
begin
  if current_user = 'anon' then
    return query select * from browse.new_to_record(p_city, p_since, p_limit, p_kind, p_slug);
    return;
  end if;
  v_places := public.city_places(p_city);
  v_tagged := public.tag_dish_ids(p_kind, p_slug);

  return query
  with recent as (
    select v.dish_id,
           max(v.created_at) filter (where v.score = 6) as six_at,
           max(v.created_at) filter (where v.score = 5) as five_at
    from public.reviews v
    where v.created_at > v_since
      and (v_places is null or v.restaurant_id = any(v_places))
      and (v_tagged is null or v.dish_id = any(v_tagged))
      and (v_uid is null or v.reviewer_id <> v_uid)
    group by v.dish_id
  ),
  judged as (
    select r.dish_id,
           case when r.six_at  is not null then 'six'
                when r.five_at is not null then 'five'
                when f.created_at > v_since and (v_uid is null or f.reviewer_id <> v_uid) then 'new'
           end as kind,
           coalesce(r.six_at, r.five_at, f.created_at) as at
    from recent r
    cross join lateral (
      select v.reviewer_id, v.created_at from public.reviews v
      where v.dish_id = r.dish_id
      order by v.created_at, v.id
      limit 1
    ) f
  ),
  page as (
    select j.dish_id, j.kind, j.at, d.name, d.restaurant_id
    from judged j
    join public.dishes d on d.id = j.dish_id and d.merged_into_dish_id is null
    where j.kind is not null
    order by case j.kind when 'six' then 0 when 'five' then 1 else 2 end, j.at desc, j.dish_id
    limit v_lim
  )
  select p.dish_id, p.name, rs.name, public.place_locality(rs.address, rs.city), p.kind,
         nullif(btrim(coalesce(public.dish_cover_url(p.dish_id), '')), ''),
         (v_uid is not null and exists (select 1 from public.saves s where s.user_id = v_uid and s.dish_id = p.dish_id)),
         p.at
  from page p
  join public.restaurants rs on rs.id = p.restaurant_id
  order by case p.kind when 'six' then 0 when 'five' then 1 else 2 end, p.at desc, p.dish_id;
end;
$$;

comment on function public.new_to_record(text, timestamptz, int, text, text) is
  'Round 8 (0055), tag 0057: what landed after p_since (NULL → 7 days ago; clamped to 90 days back), others'' lines only: a dish scored 6 (kind six), else 5.0 (five), else whose first line is after p_since (new). One row per dish, strongest kind; at = that line''s time. Order six, five, new, then at desc. p_limit default 6, max 20. p_kind + p_slug (0057): only dishes carrying that tag (dishes_by_tag''s vocabulary); both NULL = no filter. anon → browse twin.';

create function browse.new_to_record(p_city text, p_since timestamptz, p_limit int, p_kind text, p_slug text)
returns table (
  dish_id         uuid,
  name            text,
  restaurant_name text,
  suburb          text,
  kind            text,
  cover_url       text,
  saved           boolean,
  at              timestamptz
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select n.dish_id, n.name, n.restaurant_name, n.suburb, n.kind, n.cover_url, false, n.at
  from public.new_to_record(p_city, p_since, p_limit, p_kind, p_slug) n
  order by case n.kind when 'six' then 0 when 'five' then 1 else 2 end, n.at desc, n.dish_id;
$$;

revoke all on function public.new_to_record(text, timestamptz, int, text, text) from public;
grant execute on function public.new_to_record(text, timestamptz, int, text, text) to authenticated, anon, service_role;
revoke all on function browse.new_to_record(text, timestamptz, int, text, text) from public;
grant execute on function browse.new_to_record(text, timestamptz, int, text, text) to anon;

-- ===========================================================================
-- 3. get_entry_feed + the tag. 0046's body verbatim but for the tag filter.
-- ===========================================================================
drop function if exists browse.get_entry_feed(timestamptz, uuid, int, boolean, text, text);
drop function if exists public.get_entry_feed(timestamptz, uuid, int, boolean, text, text);

create function public.get_entry_feed(
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20,
  p_include_own       boolean     default false,
  p_area              text        default null,
  p_city              text        default null,
  p_kind              text        default null,
  p_slug              text        default null
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
  v_places uuid[];
  v_tagged uuid[];
begin
  if current_user = 'anon' then
    return query select * from browse.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, p_include_own, p_area, p_city, p_kind, p_slug);
    return;
  end if;

  -- The city's places and the tag's dishes, once — never per row.
  if v_city is not null then
    v_places := coalesce(array(select pc.restaurant_id from public.place_cities pc where pc.city = v_city), '{}');
  end if;
  v_tagged := public.tag_dish_ids(p_kind, p_slug);

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
  limit least(greatest(p_page_size, 1), 50);
end;
$$;

comment on function public.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text) is
  'The Feed: every entry the viewer may see (blocked/deactivated authors gone), newest first, keyset (created_at, id). p_include_own defaults false. p_area (0038) = a feed_areas() locality; p_city (0046) = a cities.id — only entries whose place maps to it (place_cities); unknown → []. NULL = everywhere. p_kind + p_slug (0057): only entries with at least one line whose dish carries that tag; both NULL = no filter. anon → browse twin.';

create function browse.get_entry_feed(
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int,
  p_include_own       boolean,
  p_area              text,
  p_city              text,
  p_kind              text,
  p_slug              text
)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.*
  from public.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, true, p_area, p_city, p_kind, p_slug) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
    and exists (select 1 from public.profiles p where p.id = c.author_id and p.deleted_at is null)
  order by r.created_at desc, r.id desc;
$$;

revoke all on function public.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text) from public;
grant execute on function public.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text) to authenticated, anon, service_role;
revoke all on function browse.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text) from public;
grant execute on function browse.get_entry_feed(timestamptz, uuid, int, boolean, text, text, text, text) to anon;

-- ===========================================================================
-- 4. my_taste_tags — what the viewer clearly favours, to seed Feed shelves without asking.
-- ===========================================================================
create or replace function public.my_taste_tags(p_city text default null, p_limit int default 12)
returns table (kind text, slug text, label text, weight int)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_uid    uuid  := auth.uid();
  v_lim    int   := least(greatest(coalesce(p_limit, 12), 1), 50);
  v_places uuid[];
begin
  if v_uid is null then
    return;
  end if;
  v_places := public.city_places(p_city);

  return query
  with signals as (
    -- every line of yours scored 4.5+: a 5.0 or a 6 counts double
    select v.dish_id, case when v.score >= 5 then 2 else 1 end as w
    from public.reviews v
    where v.reviewer_id = v_uid and v.score >= 4.5 and v.dish_id is not null
    union all
    -- every dish you saved counts one
    select s.dish_id, 1 from public.saves s where s.user_id = v_uid
  ),
  live as (
    select d.id as dish_id, sum(x.w)::int as w
    from signals x
    join public.dishes d on d.id = x.dish_id and d.merged_into_dish_id is null
    where v_places is null or d.restaurant_id = any(v_places)
    group by d.id
  ),
  weighed as (
    select t.kind, t.slug, sum(l.w)::int as weight
    from live l
    join public.dish_tag_links t on t.dish_id = l.dish_id
    where t.kind in ('style', 'cuisine')
      and not exists (select 1 from public.user_cravings c
                      where c.user_id = v_uid and c.kind = t.kind and c.slug = t.slug)
    group by t.kind, t.slug
  )
  select w.kind, w.slug, public.tag_label(w.kind, w.slug), w.weight
  from weighed w
  order by w.weight desc, lower(public.tag_label(w.kind, w.slug)), w.kind, w.slug
  limit v_lim;
end;
$$;

comment on function public.my_taste_tags(text, int) is
  '0057: the style + cuisine tags the viewer clearly favours — on dishes they scored 4.5+ (per line; a 5.0 or 6 counts 2) or saved (1 per dish) — minus tags already in user_cravings. Best first: weight desc, lower(label), kind, slug. p_city = a cities.id (NULL = everywhere). p_limit default 12, max 50. Signed out → [].';

revoke all on function public.my_taste_tags(text, int) from public;
grant execute on function public.my_taste_tags(text, int) to authenticated, anon, service_role;
