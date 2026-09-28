-- 0055_feed_edition.sql
-- Ate backend — round 8: THE FEED BECOMES AN EDITION. The Feed stops being one list and becomes
-- sections: The Top Ate (a receipt of 8), Because you loved <dish>, New to the record, one shelf per
-- followed craving, then a short run of the existing feed cards. This migration is those reads, plus
-- the cravings a viewer follows.
--
-- ─── Reads (all new: ADDITIVE). All take p_city (a cities.id; NULL = everywhere), like get_entry_feed.
--   top_ate(p_city, p_limit 8) → (rank, dish_id, name, restaurant_id, restaurant_name, suburb, score,
--       review_count, cover_url, saved). Dishes with a line in the window, ranked by their ALL-TIME
--       printed score; a dish needs scored lines from 2 DIFFERENT people to be ranked (one person
--       logging a dish twice does not qualify it). Window: the last 7 days; if fewer than
--       p_limit dishes qualify, the last 30; then all time (in the city). The whole window ranks
--       together — widening never pins the 7-day dishes on top. Order within a printed score:
--       photographed first (a tie-break, never a filter), review_count desc, name, id.
--   because_you_loved(p_city, p_limit 10) → (anchor_dish_id, anchor_name, + similar_dishes' row + saved),
--       the anchor repeated on every row. Anchor = the dish of the viewer's most recent line scored 5.0
--       or 6. Rows = similar_dishes' rule (share a style or the cuisine; weight style 8 · cuisine 4 ·
--       suburb 2 · city 1, then score, review_count, name, id) over dishes in the city that the viewer
--       has never logged. If the newest anchor has no such row, the next-newest is tried (up to 5).
--       Signed out, or no 5.0 yet → [].
--   new_to_record(p_city, p_since, p_limit 6) → (dish_id, name, restaurant_name, suburb, kind, cover_url,
--       saved, at). What landed after p_since (the client's last open; NULL → 7 days; never more than 90 days back): a dish scored 6
--       ('six'), else scored 5.0 ('five'), else whose FIRST line is after p_since ('new'). One row per
--       dish, its strongest kind; `at` = that event's line time (the latest 6 / 5.0, or the first line).
--       The viewer's own lines are not news to them. Order: six, five, new, then `at` desc, dish_id.
--   craving_options() → (kind, slug, label, group): every style ('dishes') and cuisine ('cuisines')
--       tag on a logged dish, busiest first. 'moods' is part of the contract and empty for now.
--   my_cravings() → (kind, slug, label) in the order set. Signed out → [].
--   set_cravings(p_cravings jsonb) → the new set (my_cravings' rows). Replaces the whole set.
--   dishes_by_tag(…, p_city) → + `saved` (DROP + CREATE: landmine 7; the existing args bind unchanged).
--
-- ─── Storage: public.user_cravings (user_id, kind, slug, label, position, created_at)
--   PK (user_id, kind, slug) — TOTAL. Written ONLY by set_cravings (DEFINER; no client write grant);
--   the owner can SELECT their own. Cascades from profiles; delete_account verifies it (restated below).
--
-- ─── Signed out. The Feed is browseable signed out (0034), so top_ate, new_to_record and
--   craving_options dispatch anon to DEFINER twins in `browse` (saved = false). because_you_loved and
--   my_cravings answer [] to anon; set_cravings refuses (42501).
--
-- ─── Speed. The city's places come from 0052's place_city_cache (place_cities) once per call; tags
--   from 0053's dish_tag_links; covers are computed only for rows that can make the page.
--
-- WIRE IMPACT: ADDITIVE — six new RPCs, one new table; dishes_by_tag gains a trailing optional param and
-- a trailing OUT column (`saved`). No existing parameter or column changes meaning.

set search_path = public, extensions;

-- ===========================================================================
-- 1. Helpers.
-- ===========================================================================
-- The places in a city, once per call. NULL city → NULL (no filter); an unknown city → '{}' (nothing).
create or replace function public.city_places(p_city text)
returns uuid[]
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select case
    when nullif(lower(btrim(coalesce(p_city, ''))), '') is null then null
    else coalesce(array(select pc.restaurant_id from public.place_cities pc
                        where pc.city = lower(btrim(p_city))), '{}')
  end;
$$;

-- A tag's label: the one most of its dishes print (ties: alphabetical). NULL for a tag no dish carries.
create or replace function public.tag_label(p_kind text, p_slug text)
returns text
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select t.label
  from public.dish_tag_links t
  where t.kind = p_kind and t.slug = p_slug
  group by t.label
  order by count(*) desc, t.label
  limit 1;
$$;

revoke all on function public.city_places(text)     from public, anon;
revoke all on function public.tag_label(text, text) from public, anon;
grant execute on function public.city_places(text)     to authenticated, service_role;
grant execute on function public.tag_label(text, text) to authenticated, service_role;

-- ===========================================================================
-- 2. The Top Ate.
-- ===========================================================================
create or replace function public.top_ate(p_city text default null, p_limit int default 8)
returns table (
  rank            int,
  dish_id         uuid,
  name            text,
  restaurant_id   uuid,
  restaurant_name text,
  suburb          text,
  score           numeric(2,1),
  review_count    int,
  cover_url       text,
  saved           boolean
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_uid    uuid   := auth.uid();
  v_lim    int    := least(greatest(coalesce(p_limit, 8), 1), 20);
  v_places uuid[];
begin
  if current_user = 'anon' then
    return query select * from browse.top_ate(p_city, p_limit);
    return;
  end if;
  v_places := public.city_places(p_city);

  return query
  with stats as (
    -- every dish's all-time numbers over the lines the viewer can see (dish_stats' rule)
    select v.dish_id,
           round(avg(v.score), 1)::numeric(2,1) as score,
           count(*)::int                        as review_count,
           max(v.created_at)                    as last_at
    from public.reviews v
    where v_places is null or v.restaurant_id = any(v_places)
    group by v.dish_id
    having count(distinct v.reviewer_id) filter (where v.score is not null) >= 2
  ),
  live as (
    select s.dish_id, s.score, s.review_count, s.last_at, d.name, d.restaurant_id
    from stats s
    join public.dishes d on d.id = s.dish_id and d.merged_into_dish_id is null
  ),
  win as (
    select case
             when count(*) filter (where l.last_at >= now() - interval '7 days')  >= v_lim then now() - interval '7 days'
             when count(*) filter (where l.last_at >= now() - interval '30 days') >= v_lim then now() - interval '30 days'
             else '-infinity'::timestamptz
           end as since
    from live l
  ),
  pool as (
    select l.* from live l cross join win where l.last_at >= win.since
  ),
  -- only a dish scoring at least the v_lim-th best can make the page: covers for those alone
  cut as (
    select coalesce(min(x.score), -1) as floor
    from (select p.score from pool p order by p.score desc limit v_lim) x
  ),
  covered as (
    select p.*, nullif(btrim(coalesce(public.dish_cover_url(p.dish_id), '')), '') as cover_url
    from pool p cross join cut
    where p.score >= cut.floor
  ),
  ranked as (
    select c.*,
           row_number() over (order by c.score desc, (c.cover_url is not null) desc, c.review_count desc,
                                       lower(c.name), c.dish_id)::int as pos
    from covered c
  )
  select r.pos, r.dish_id, r.name, r.restaurant_id, rs.name, public.place_locality(rs.address, rs.city),
         r.score, r.review_count, r.cover_url,
         (v_uid is not null and exists (select 1 from public.saves s where s.user_id = v_uid and s.dish_id = r.dish_id))
  from ranked r
  join public.restaurants rs on rs.id = r.restaurant_id
  where r.pos <= v_lim
  order by r.pos;
end;
$$;

comment on function public.top_ate(text, int) is
  'Round 8 (0055): The Top Ate — dishes with a line in the last 7 days (fewer than p_limit → 30 days → all time), ranked by ALL-TIME printed score; needs scored lines from 2 different people. Within a score: photographed first, review_count desc, name, id. rank 1…n. p_limit default 8, max 20. Numbers over lines the viewer can see; saved = the viewer''s save. anon → browse twin.';

-- ===========================================================================
-- 3. Because you loved <dish>.
-- ===========================================================================
create or replace function public.because_you_loved(p_city text default null, p_limit int default 10)
returns table (
  anchor_dish_id  uuid,
  anchor_name     text,
  dish_id         uuid,
  name            text,
  restaurant_id   uuid,
  restaurant_name text,
  score           numeric(2,1),
  review_count    int,
  cover_url       text,
  saved           boolean
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_uid    uuid := auth.uid();
  v_lim    int  := least(greatest(coalesce(p_limit, 10), 1), 30);
  v_places uuid[];
  v_anchor record;
begin
  if v_uid is null then
    return;
  end if;
  v_places := public.city_places(p_city);

  for v_anchor in
    select a.dish_id, d.name
    from (
      select v.dish_id, max(v.created_at) as at
      from public.reviews v
      where v.reviewer_id = v_uid and v.score >= 5
      group by v.dish_id
    ) a
    join public.dishes d on d.id = a.dish_id and d.merged_into_dish_id is null
    order by a.at desc, a.dish_id
    limit 5
  loop
    return query
    with me as (
      select t.kind, t.slug from public.dish_tag_links t where t.dish_id = v_anchor.dish_id
    ),
    cand as (
      select distinct t.dish_id
      from public.dish_tag_links t
      join me on me.kind = t.kind and me.slug = t.slug
      where t.kind in ('style', 'cuisine') and t.dish_id <> v_anchor.dish_id
    ),
    eligible as (
      select c.dish_id, d.name, d.restaurant_id
      from cand c
      join public.dishes d on d.id = c.dish_id and d.merged_into_dish_id is null
      where (v_places is null or d.restaurant_id = any(v_places))
        and not exists (select 1 from public.reviews mine
                        where mine.dish_id = c.dish_id and mine.reviewer_id = v_uid)
    ),
    weighed as (
      select e.dish_id, e.name, e.restaurant_id,
             sum(case t.kind when 'style' then 8 when 'cuisine' then 4 when 'suburb' then 2 else 1 end)::int as weight
      from eligible e
      join public.dish_tag_links t on t.dish_id = e.dish_id
      join me on me.kind = t.kind and me.slug = t.slug
      group by e.dish_id, e.name, e.restaurant_id
    ),
    numbered as (
      select w.dish_id, w.name, w.restaurant_id, w.weight,
             round(avg(v.score), 1)::numeric(2,1) as score,
             count(*)::int as review_count
      from weighed w
      join public.reviews v on v.dish_id = w.dish_id
      group by w.dish_id, w.name, w.restaurant_id, w.weight
    ),
    page as (
      select n.*
      from numbered n
      order by n.weight desc, coalesce(n.score, -1) desc, n.review_count desc, lower(n.name), n.dish_id
      limit v_lim
    )
    select v_anchor.dish_id, v_anchor.name, p.dish_id, p.name, p.restaurant_id, r.name, p.score, p.review_count,
           public.dish_cover_url(p.dish_id),
           exists (select 1 from public.saves s where s.user_id = v_uid and s.dish_id = p.dish_id)
    from page p
    join public.restaurants r on r.id = p.restaurant_id
    order by p.weight desc, coalesce(p.score, -1) desc, p.review_count desc, lower(p.name), p.dish_id;

    if found then
      return;
    end if;
  end loop;
end;
$$;

comment on function public.because_you_loved(text, int) is
  'Round 8 (0055): "Because you loved <anchor>" — anchor = the dish of the viewer''s most recent line scored 5.0 or 6 (the next-newest of up to 5 when one has no rows). Rows = similar_dishes'' rule over dishes in p_city the viewer never logged; the anchor repeats on every row. p_limit default 10, max 30. Signed out / no 5.0 → [].';

-- ===========================================================================
-- 4. New to the record.
-- ===========================================================================
create or replace function public.new_to_record(
  p_city  text        default null,
  p_since timestamptz default null,
  p_limit int         default 6
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
begin
  if current_user = 'anon' then
    return query select * from browse.new_to_record(p_city, p_since, p_limit);
    return;
  end if;
  v_places := public.city_places(p_city);

  return query
  with recent as (
    select v.dish_id,
           max(v.created_at) filter (where v.score = 6) as six_at,
           max(v.created_at) filter (where v.score = 5) as five_at
    from public.reviews v
    where v.created_at > v_since
      and (v_places is null or v.restaurant_id = any(v_places))
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

comment on function public.new_to_record(text, timestamptz, int) is
  'Round 8 (0055): what landed after p_since (NULL → 7 days ago; clamped to 90 days back), others'' lines only: a dish scored 6 (kind six), else 5.0 (five), else whose first line is after p_since (new). One row per dish, strongest kind; at = that line''s time. Order six, five, new, then at desc. p_limit default 6, max 20. anon → browse twin.';

-- ===========================================================================
-- 5. Cravings — what a viewer follows; one Feed shelf each.
-- ===========================================================================
create table if not exists public.user_cravings (
  user_id    uuid        not null references public.profiles(id) on delete cascade,
  kind       text        not null check (kind in ('style', 'cuisine', 'suburb', 'city', 'diet')),
  slug       text        not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) <= 64),
  label      text        not null check (char_length(label) between 1 and 80),
  position   smallint    not null default 0,
  created_at timestamptz not null default now(),
  primary key (user_id, kind, slug)
);

alter table public.user_cravings enable row level security;
drop policy if exists user_cravings_select_own on public.user_cravings;
create policy user_cravings_select_own on public.user_cravings
  for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.user_cravings from anon, authenticated;
grant select on public.user_cravings to authenticated;
grant all on public.user_cravings to service_role;

comment on table public.user_cravings is
  'Round 8 (0055): the tags a viewer follows (round-7 kinds), in their order — one Feed shelf each (dishes_by_tag). Written only by set_cravings; owner-read.';

create or replace function public.craving_options()
returns table (kind text, slug text, label text, "group" text)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  if current_user = 'anon' then
    return query select * from browse.craving_options();
    return;
  end if;

  return query
  with tagged as (
    select t.kind, t.slug, count(*) as dishes
    from public.dish_tag_links t
    join public.dishes d on d.id = t.dish_id and d.merged_into_dish_id is null
    where t.kind in ('style', 'cuisine')
      and exists (select 1 from public.reviews v where v.dish_id = t.dish_id)
    group by t.kind, t.slug
  )
  select x.kind, x.slug, public.tag_label(x.kind, x.slug),
         case x.kind when 'style' then 'dishes' else 'cuisines' end
  from tagged x
  order by case x.kind when 'style' then 0 else 1 end, x.dishes desc, x.slug;
end;
$$;

comment on function public.craving_options() is
  'Round 8 (0055): the cravings picker — every style (group dishes) and cuisine (group cuisines) tag on a live, logged dish; busiest first within a group. group moods: none yet. anon → browse twin.';

create or replace function public.my_cravings()
returns table (kind text, slug text, label text)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then
    return;
  end if;
  return query
  select c.kind, c.slug, c.label
  from public.user_cravings c
  where c.user_id = (select auth.uid())
  order by c.position, c.kind, c.slug;
end;
$$;

comment on function public.my_cravings() is
  'Round 8 (0055): the caller''s cravings in the order set. Signed out → [].';

-- p_cravings: a JSON array of {kind, slug} (anything else in an element is ignored), in shelf order.
-- [] clears. A (kind, slug) must be a tag a dish carries now (diet: gf df v vg nf), or already one of
-- the caller's — so re-saving a set whose tag has since emptied never fails. Duplicates collapse to
-- the first. At most 24. Bad input → 22023; signed out → 42501.
create or replace function public.set_cravings(p_cravings jsonb)
returns table (kind text, slug text, label text)
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_set jsonb;
  v_bad text;
begin
  if v_uid is null then
    raise exception 'signed-in callers only' using errcode = '42501';
  end if;
  if p_cravings is null or jsonb_typeof(p_cravings) <> 'array' then
    raise exception 'p_cravings must be a JSON array of {kind, slug}' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_cravings) e
             where jsonb_typeof(e) <> 'object'
                or jsonb_typeof(e -> 'kind') is distinct from 'string'
                or jsonb_typeof(e -> 'slug') is distinct from 'string') then
    raise exception 'each craving must be {kind, slug} strings' using errcode = '22023';
  end if;

  -- one set per caller at a time
  perform 1 from public.profiles p where p.id = v_uid for update;

  -- the set asked for: trimmed, lower-cased, first of each duplicate, labelled — a known tag's label
  -- now, else (a tag no dish carries any more) the label it was followed under, else NULL (unknown)
  select coalesce(jsonb_agg(jsonb_build_object('kind', d.kind, 'slug', d.slug, 'label', coalesce(
           case when d.kind = 'diet' then case when d.slug = any('{gf,df,v,vg,nf}'::text[]) then upper(d.slug) end
                when d.kind in ('style', 'cuisine', 'suburb', 'city') then public.tag_label(d.kind, d.slug) end,
           (select c.label from public.user_cravings c
             where c.user_id = v_uid and c.kind = d.kind and c.slug = d.slug)))
         order by d.ord), '[]'::jsonb)
    into v_set
  from (
    select distinct on (lower(btrim(x.e ->> 'kind')), lower(btrim(x.e ->> 'slug')))
           lower(btrim(x.e ->> 'kind')) as kind, lower(btrim(x.e ->> 'slug')) as slug, x.ord
    from jsonb_array_elements(p_cravings) with ordinality as x(e, ord)
    order by lower(btrim(x.e ->> 'kind')), lower(btrim(x.e ->> 'slug')), x.ord
  ) d;

  select i.kind into v_bad from jsonb_to_recordset(v_set) as i(kind text, slug text, label text)
  where i.kind not in ('style', 'cuisine', 'suburb', 'city', 'diet') limit 1;
  if found then
    raise exception 'craving kind must be style, cuisine, suburb, city or diet (got %)', v_bad using errcode = '22023';
  end if;
  if jsonb_array_length(v_set) > 24 then
    raise exception 'at most 24 cravings' using errcode = '22023';
  end if;
  select i.kind || ':' || i.slug into v_bad from jsonb_to_recordset(v_set) as i(kind text, slug text, label text)
  where i.label is null limit 1;
  if found then
    raise exception 'unknown tag %', v_bad using errcode = '22023';
  end if;

  delete from public.user_cravings c where c.user_id = v_uid;
  insert into public.user_cravings (user_id, kind, slug, label, position)
  select v_uid, i.kind, i.slug, left(i.label, 80), i.pos::smallint
  from rows from (jsonb_to_recordset(v_set) as (kind text, slug text, label text)) with ordinality as i(kind, slug, label, pos);

  return query
  select c.kind, c.slug, c.label
  from public.user_cravings c
  where c.user_id = v_uid
  order by c.position, c.kind, c.slug;
end;
$$;

comment on function public.set_cravings(jsonb) is
  'Round 8 (0055): replaces the caller''s cravings with p_cravings — a JSON array of {kind, slug} in shelf order ([] clears; duplicates collapse; max 24). Each must be a tag a dish carries now, or one the caller already follows. Returns the new set (my_cravings'' rows). 22023 on bad input; 42501 signed out.';

-- ===========================================================================
-- 6. dishes_by_tag + p_city, + saved — DROP then CREATE (landmine 7), re-grant.
--    0053's body, plus: the city's places filter the candidates; each row carries the viewer's save.
-- ===========================================================================
drop function if exists public.dishes_by_tag(text, text, int, numeric, int, text, uuid);

create function public.dishes_by_tag(
  p_kind                text,
  p_slug                text,
  p_limit               int     default 30,
  p_cursor_score        numeric default null,
  p_cursor_review_count int     default null,
  p_cursor_name         text    default null,
  p_cursor_dish_id      uuid    default null,
  p_city                text    default null
)
returns table (
  dish_id         uuid,
  name            text,
  restaurant_id   uuid,
  restaurant_name text,
  score           numeric(2,1),
  review_count    int,
  cover_url       text,
  saved           boolean
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_uid    uuid   := auth.uid();
  v_kind   text   := lower(btrim(coalesce(p_kind, '')));
  v_slug   text   := lower(btrim(coalesce(p_slug, '')));
  v_lim    int    := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_places uuid[];
begin
  if v_uid is null then
    raise exception 'signed-in callers only' using errcode = '42501';
  end if;
  if v_kind not in ('style', 'cuisine', 'suburb', 'city', 'diet') then
    raise exception 'p_kind must be style, cuisine, suburb, city or diet (got %)', p_kind using errcode = '22023';
  end if;
  v_places := public.city_places(p_city);

  return query
  with cand as (
    select t.dish_id from public.dish_tag_links t
    where v_kind <> 'diet' and t.kind = v_kind and t.slug = v_slug
    union
    -- diet: any dish with a line carrying the code, kept below only if the consensus lists it
    select v.dish_id from public.reviews v
    where v_kind = 'diet' and v_slug = any(v.tags)
  ),
  placed as (
    select c.dish_id, d.name, d.restaurant_id
    from cand c
    join public.dishes d on d.id = c.dish_id and d.merged_into_dish_id is null
    where v_places is null or d.restaurant_id = any(v_places)
  ),
  numbered as (
    select c.dish_id, c.name, c.restaurant_id,
           round(avg(v.score), 1)::numeric(2,1) as score,
           count(*)::int as review_count
    from placed c
    join public.reviews v on v.dish_id = c.dish_id
    group by c.dish_id, c.name, c.restaurant_id
  ),
  page as (
    select n.dish_id, n.name, n.restaurant_id, r.name as restaurant_name, n.score, n.review_count
    from numbered n
    join public.restaurants r on r.id = n.restaurant_id
    where (v_kind <> 'diet' or v_slug = any(public.dish_consensus_tags(n.dish_id)))
      and (
        p_cursor_dish_id is null
        or coalesce(n.score, -1) < coalesce(p_cursor_score, -1)
        or (coalesce(n.score, -1) = coalesce(p_cursor_score, -1)
            and n.review_count < p_cursor_review_count)
        or (coalesce(n.score, -1) = coalesce(p_cursor_score, -1)
            and n.review_count = p_cursor_review_count
            and (lower(n.name), n.dish_id) > (lower(coalesce(p_cursor_name, '')), p_cursor_dish_id))
      )
    order by coalesce(n.score, -1) desc, n.review_count desc, lower(n.name), n.dish_id
    limit v_lim
  )
  select p.dish_id, p.name, p.restaurant_id, p.restaurant_name, p.score, p.review_count,
         public.dish_cover_url(p.dish_id),
         exists (select 1 from public.saves s where s.user_id = v_uid and s.dish_id = p.dish_id)
  from page p
  order by coalesce(p.score, -1) desc, p.review_count desc, lower(p.name), p.dish_id;
end;
$$;

comment on function public.dishes_by_tag(text, text, int, numeric, int, text, uuid, text) is
  'Round 7 (0053), city + saved 0055: a tag chip''s results — every live, logged dish carrying (p_kind, p_slug) from dish_tags (diet: the consensus rule, live), best first: printed score desc (a 6 above every 5, unscored last), review_count desc, lower(name), dish_id. Keyset: pass the last row''s score, review_count, name, dish_id (score may be null). p_city (0055): only dishes whose place is in that city (NULL = everywhere; unknown → []). saved = the viewer''s save. p_limit default 30, max 100. Unknown slug → []; unknown kind → 22023.';

-- ===========================================================================
-- 7. The browse twins — anon only, DEFINER, in the unexposed schema (0034's pattern). Each calls the
--    public read as its owner (the ordinary branch, auth.uid() NULL) and pins saved = false.
-- ===========================================================================
create or replace function browse.top_ate(p_city text, p_limit int)
returns table (
  rank            int,
  dish_id         uuid,
  name            text,
  restaurant_id   uuid,
  restaurant_name text,
  suburb          text,
  score           numeric(2,1),
  review_count    int,
  cover_url       text,
  saved           boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select t.rank, t.dish_id, t.name, t.restaurant_id, t.restaurant_name, t.suburb, t.score, t.review_count,
         t.cover_url, false
  from public.top_ate(p_city, p_limit) t
  order by t.rank;
$$;

create or replace function browse.new_to_record(p_city text, p_since timestamptz, p_limit int)
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
  from public.new_to_record(p_city, p_since, p_limit) n
  order by case n.kind when 'six' then 0 when 'five' then 1 else 2 end, n.at desc, n.dish_id;
$$;

create or replace function browse.craving_options()
returns table (kind text, slug text, label text, "group" text)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select o.kind, o.slug, o.label, o."group" from public.craving_options() o;
$$;

-- ===========================================================================
-- 8. delete_account — 0039's body verbatim, plus user_cravings in the "nothing survived" check.
--    Same signature: create or replace, grants restated.
-- ===========================================================================
create or replace function public.delete_account()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_deleted int;
begin
  if v_uid is null then
    raise exception 'delete_account requires an authenticated caller' using errcode = '42501';
  end if;

  -- Everything personal hangs off this row by `on delete cascade` (header of 0035). Any failure
  -- here — privilege, trigger, FK — propagates and rolls the whole call back.
  delete from auth.users where id = v_uid;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 1 then
    raise exception 'delete_account: no auth user % to delete', v_uid using errcode = 'P0002';
  end if;

  -- Verify, don't trust: if a future table forgets its cascade, this refuses to report success —
  -- and, by raising, un-deletes everything above.
  if exists (select 1 from public.profiles       where id = v_uid)
  or exists (select 1 from public.entries        where author_id = v_uid)
  or exists (select 1 from public.reviews        where reviewer_id = v_uid)
  or exists (select 1 from public.saves          where user_id = v_uid)
  or exists (select 1 from public.blocks         where blocker_id = v_uid or blocked_id = v_uid)
  or exists (select 1 from public.reports        where reporter_id = v_uid or profile_id = v_uid)
  or exists (select 1 from public.comments       where user_id = v_uid)
  or exists (select 1 from public.lists          where owner_id = v_uid)
  or exists (select 1 from public.follows        where follower_id = v_uid or followee_id = v_uid)
  or exists (select 1 from public.review_likes   where user_id = v_uid)
  or exists (select 1 from public.comment_likes  where user_id = v_uid)
  or exists (select 1 from public.review_tags    where tagged_user_id = v_uid or tagger_id = v_uid)
  or exists (select 1 from public.notifications  where recipient_id = v_uid or actor_id = v_uid)
  or exists (select 1 from public.sort_preview_cache where author_id = v_uid)
  or exists (select 1 from public.sort_preview_rate  where author_id = v_uid)
  or exists (select 1 from public.user_cravings  where user_id = v_uid)
  then
    raise exception 'delete_account: personal rows survived the cascade for %', v_uid
      using errcode = 'P0001';
  end if;

  -- Shape unchanged from 0032 so shipped decoders keep working; it can no longer say false.
  return jsonb_build_object('ok', true, 'auth_user_deleted', true);
end; $$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- ===========================================================================
-- 9. Grants.
-- ===========================================================================
revoke all on function public.top_ate(text, int)                                           from public;
revoke all on function public.because_you_loved(text, int)                                 from public;
revoke all on function public.new_to_record(text, timestamptz, int)                        from public;
revoke all on function public.craving_options()                                            from public;
revoke all on function public.my_cravings()                                                from public;
revoke all on function public.set_cravings(jsonb)                                          from public, anon;
revoke all on function public.dishes_by_tag(text, text, int, numeric, int, text, uuid, text) from public, anon;
grant execute on function public.top_ate(text, int)                                           to authenticated, anon, service_role;
grant execute on function public.because_you_loved(text, int)                                 to authenticated, anon, service_role;
grant execute on function public.new_to_record(text, timestamptz, int)                        to authenticated, anon, service_role;
grant execute on function public.craving_options()                                            to authenticated, anon, service_role;
grant execute on function public.my_cravings()                                                to authenticated, anon, service_role;
grant execute on function public.set_cravings(jsonb)                                          to authenticated, service_role;
grant execute on function public.dishes_by_tag(text, text, int, numeric, int, text, uuid, text) to authenticated, service_role;

revoke all on function browse.top_ate(text, int)                    from public;
revoke all on function browse.new_to_record(text, timestamptz, int) from public;
revoke all on function browse.craving_options()                     from public;
grant execute on function browse.top_ate(text, int)                    to anon;
grant execute on function browse.new_to_record(text, timestamptz, int) to anon;
grant execute on function browse.craving_options()                     to anon;
