-- 0023_stats_search.sql
-- Ate backend — V1 RETHINK: what Ate gives back (You · Ratings · Recap) and Search.
--
-- Every number here is DERIVED on read from entries/reviews. Nothing is stored, so
-- nothing can go stale, and all of it is viewer-relative through RLS: a stranger's
-- profile counts their PUBLIC entries only, your own counts everything.
--
-- The four screens and the call each one makes:
--   You / Profile          → profile_summary(user) + score_histogram(user)
--                            + dishes_by_score(user, 5.0)   ("Your 5.0s")
--   Ratings                → score_histogram(user), then dishes_by_score(user, bar)
--   Recap (statement)      → statement_months(user), then monthly_statement(user, month)
--   Search                 → search_all(query)
--
-- WIRE IMPACT: ADDITIVE — RPCs only.

set search_path = public, extensions;

-- ===========================================================================
-- profile_summary — the header of You and Profile in one round trip.
-- orders = entries · places = distinct places visited · dishes = receipt line items.
-- ===========================================================================
create or replace function public.profile_summary(p_user_id uuid)
returns table (
  user_id      uuid,
  username     citext,
  name         text,
  avatar_url   text,
  bio          text,
  city         text,
  created_at   timestamptz,
  orders       int,
  places       int,
  dishes       int,
  scored       int,
  avg_score    numeric(3,2),
  is_me        boolean
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    p.id, p.username, p.name, p.avatar_url, p.bio, p.city, p.created_at,
    coalesce(e.orders, 0), coalesce(e.places, 0),
    coalesce(v.dishes, 0), coalesce(v.scored, 0), v.avg_score,
    (p.id = (select auth.uid()))
  from public.profiles p
  left join lateral (
    select count(*)::int as orders,
           count(distinct en.restaurant_id)::int as places
    from public.entries en where en.author_id = p.id
  ) e on true
  left join lateral (
    select count(*)::int as dishes,
           count(rv.score)::int as scored,
           round(avg(rv.score), 2)::numeric(3,2) as avg_score
    from public.reviews rv
    join public.entries en2 on en2.id = rv.entry_id
    where en2.author_id = p.id
  ) v on true
  where p.id = p_user_id;
$$;

comment on function public.profile_summary(uuid) is
  'Profile header + derived counts (orders/places/dishes/scored/avg). Viewer-relative: a stranger sees public entries only.';

-- ===========================================================================
-- score_histogram — all TEN half-step buckets, zeros included, so the client draws
-- a complete chart without filling gaps. `dish_count` is what the Ratings screen
-- labels ("36 dishes" = distinct dishes scored at that value), `review_count` is the
-- raw number of times they gave it.
-- ===========================================================================
create or replace function public.score_histogram(p_user_id uuid)
returns table (
  score        numeric(2,1),
  dish_count   int,
  review_count int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    b.score::numeric(2,1),
    count(distinct v.dish_id)::int,
    count(v.id)::int
  from (select generate_series(0.5, 5.0, 0.5) as score) b
  left join public.reviews v
    on v.score = b.score
   and v.reviewer_id = p_user_id
  group by b.score
  order by b.score;
$$;

comment on function public.score_histogram(uuid) is
  'Ten half-step buckets (0.5..5.0), zeros included: distinct dishes + review count per score for one user.';

-- ===========================================================================
-- dishes_by_score — tap a histogram bar (Ratings), or read "Your 5.0s" (You).
-- Newest first; one row per review, so two sittings of the same dish both show.
-- ===========================================================================
create or replace function public.dishes_by_score(
  p_user_id uuid,
  p_score   numeric,
  p_limit   int default 100
)
returns table (
  review_id       uuid,
  entry_id        uuid,
  dish_id         uuid,
  dish_name       text,
  restaurant_id   uuid,
  restaurant_name text,
  score           numeric(2,1),
  note            text,
  created_at      timestamptz
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select v.id, v.entry_id, d.id, d.name, r.id, r.name, v.score, v.note, v.created_at
  from public.reviews v
  join public.dishes d      on d.id = v.dish_id
  join public.restaurants r on r.id = d.restaurant_id
  where v.reviewer_id = p_user_id
    and v.score = p_score::numeric(2,1)
  order by v.created_at desc, v.id desc
  limit least(greatest(p_limit, 1), 500);
$$;

-- ===========================================================================
-- statement_months — which months have a statement, newest first (the Recap picker).
-- p_tz: month boundaries are LOCAL wall-clock, so September is September in
-- Melbourne, not in UTC. Defaults to the launch market; pass the device zone.
-- ===========================================================================
create or replace function public.statement_months(
  p_user_id uuid,
  p_tz      text default 'Australia/Melbourne'
)
returns table (month date, orders int)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    (date_trunc('month', (e.created_at at time zone p_tz)))::date as month,
    count(*)::int as orders
  from public.entries e
  where e.author_id = p_user_id
  group by 1
  order by 1 desc;
$$;

-- ===========================================================================
-- monthly_statement — the Recap screen, one jsonb object.
--
-- Returns jsonb (not a wide table) because the nine figures are heterogeneous — six
-- scalars and three little lists — and because a jsonb payload can gain a key
-- additively without a signature change. Keys (all always present):
--   month, orders, places, new_places, dishes, stars, average,
--   top_dishes: [{dish_id, dish_name, restaurant_name, score}]   (up to 3)
--   most_ordered: {dish_name, count} | null
--   most_visited: {restaurant_id, restaurant_name, count} | null
--
-- "new_places" = places visited this month that this user had never visited before
-- the month started. "stars" = the sum of the scores they handed out. "average" is
-- over SCORED line items only — an unscored dish never drags an average down
-- (DESIGN rule 7).
-- ===========================================================================
create or replace function public.monthly_statement(
  p_user_id uuid,
  p_month   date,
  p_tz      text default 'Australia/Melbourne'
)
returns jsonb
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with bounds as (
    select
      (date_trunc('month', p_month::timestamp) at time zone p_tz) as start_ts,
      ((date_trunc('month', p_month::timestamp) + interval '1 month') at time zone p_tz) as end_ts
  ),
  ent as (
    select e.* from public.entries e, bounds b
    where e.author_id = p_user_id
      and e.created_at >= b.start_ts and e.created_at < b.end_ts
  ),
  items as (
    select v.*, d.name as dish_name, d.restaurant_id as dish_restaurant_id
    from public.reviews v
    join ent on ent.id = v.entry_id
    join public.dishes d on d.id = v.dish_id
  ),
  new_places as (
    select count(*)::int as n from (
      select distinct ent.restaurant_id
      from ent, bounds b
      where ent.restaurant_id is not null
        and not exists (
          select 1 from public.entries prior
          where prior.author_id = p_user_id
            and prior.restaurant_id = ent.restaurant_id
            and prior.created_at < b.start_ts
        )
    ) q
  ),
  top3 as (
    select coalesce(jsonb_agg(t order by t_score desc nulls last, t_created desc), '[]'::jsonb) as v
    from (
      select jsonb_build_object(
               'dish_id', i.dish_id, 'dish_name', i.dish_name,
               'restaurant_name', r.name, 'score', i.score
             ) as t,
             i.score as t_score, i.created_at as t_created
      from items i join public.restaurants r on r.id = i.dish_restaurant_id
      where i.score is not null
      order by i.score desc, i.created_at desc
      limit 3
    ) q
  ),
  most_ordered as (
    select jsonb_build_object('dish_name', max(i.dish_name), 'count', count(*)::int) as v
    from items i
    group by lower(i.dish_name)
    order by count(*) desc, max(i.dish_name)
    limit 1
  ),
  most_visited as (
    select jsonb_build_object('restaurant_id', ent.restaurant_id, 'restaurant_name', max(r.name), 'count', count(*)::int) as v
    from ent join public.restaurants r on r.id = ent.restaurant_id
    where ent.restaurant_id is not null
    group by ent.restaurant_id
    order by count(*) desc, max(r.name)
    limit 1
  )
  select jsonb_build_object(
    -- the first of the month, ISO. (Formatted with DD, not a literal '01' — digits in
    -- a to_char pattern are not safe to assume pass through.)
    'month',        to_char(date_trunc('month', p_month::timestamp), 'YYYY-MM-DD'),
    'orders',       (select count(*)::int from ent),
    'places',       (select count(distinct ent.restaurant_id)::int from ent where ent.restaurant_id is not null),
    'new_places',   (select n from new_places),
    'dishes',       (select count(*)::int from items),
    'stars',        coalesce((select sum(i.score) from items i), 0),
    'average',      (select round(avg(i.score), 2) from items i),
    'top_dishes',   (select v from top3),
    'most_ordered', (select v from most_ordered),
    'most_visited', (select v from most_visited)
  );
$$;

comment on function public.monthly_statement(uuid, date, text) is
  'The monthly statement as one jsonb object (orders, places, new_places, dishes, stars, average, top_dishes[], most_ordered, most_visited). Month boundaries are local to p_tz.';

-- ===========================================================================
-- search_all — one call behind the Places / Dishes / People tabs; the client splits
-- on `kind`. Ranked within each kind, p_limit_per_kind each.
--
-- Matching is ILIKE-substring, which the EXISTING total trigram GIN indexes cover
-- (restaurants_name_trgm, dishes_name_trgm, profiles_username_trgm/name_trgm — 0002
-- and 0012). It deliberately does NOT use the word_similarity `<%` operator: that
-- needs `set pg_trgm.word_similarity_threshold`, which fails at migration time
-- unless the pg_trgm library is already loaded in the session (the 0017 landmine).
-- similarity() is still used for RANKING, where no GUC is involved.
-- Restaurant name search for the composer's place picker stays where it is —
-- search_local_restaurants (0017), called by the places-search edge function.
-- ===========================================================================
create or replace function public.search_all(p_query text, p_limit_per_kind int default 10)
returns table (
  kind       text,
  id         uuid,
  title      text,
  subtitle   text,
  score      numeric(2,1),
  match_rank real,
  detail     jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with q as (
    select
      btrim(coalesce(p_query, '')) as query,
      -- escape LIKE metacharacters so a literal % / _ / \ matches literally
      replace(replace(replace(btrim(coalesce(p_query, '')), '\', '\\'), '%', '\%'), '_', '\_') as like_q,
      least(greatest(p_limit_per_kind, 1), 25) as lim
  ),
  place_hits as (
    select 'place'::text as kind, r.id, r.name as title,
           coalesce(nullif(r.cuisine, ''), r.city) as subtitle,
           rs.avg_rating as score,
           similarity(r.name, q.query)::real as match_rank,
           jsonb_build_object('city', r.city, 'cuisine', r.cuisine, 'address', r.address,
                              'people_count', coalesce(rs.people_count, 0)) as detail
    from public.restaurants r
    left join public.restaurant_stats rs on rs.restaurant_id = r.id
    cross join q
    where char_length(q.query) >= 2 and r.name ilike '%' || q.like_q || '%'
    order by similarity(r.name, q.query) desc, r.name
    limit (select lim from q)
  ),
  dish_hits as (
    select 'dish'::text as kind, d.id, d.name as title, r.name as subtitle,
           ds.score,
           similarity(d.name, q.query)::real as match_rank,
           jsonb_build_object('restaurant_id', r.id, 'restaurant_city', r.city,
                              'people_count', coalesce(ds.people_count, 0),
                              'cover_url', ds.cover_url) as detail
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    left join public.dish_stats ds on ds.dish_id = d.id
    cross join q
    where char_length(q.query) >= 2
      and d.merged_into_dish_id is null
      and d.name ilike '%' || q.like_q || '%'
    order by similarity(d.name, q.query) desc, d.name
    limit (select lim from q)
  ),
  people_hits as (
    select 'person'::text as kind, p.id, p.username::text as title, p.name as subtitle,
           null::numeric(2,1) as score,
           greatest(similarity(p.username::text, q.query), similarity(coalesce(p.name, ''), q.query))::real as match_rank,
           jsonb_build_object('avatar_url', p.avatar_url, 'city', p.city) as detail
    from public.profiles p
    cross join q
    where char_length(q.query) >= 2
      and p.deleted_at is null
      and (p.username::text ilike '%' || q.like_q || '%' or p.name ilike '%' || q.like_q || '%')
    order by greatest(similarity(p.username::text, q.query), similarity(coalesce(p.name, ''), q.query)) desc, p.username
    limit (select lim from q)
  )
  select * from place_hits
  union all select * from dish_hits
  union all select * from people_hits;
$$;

comment on function public.search_all(text, int) is
  'Search places + dishes + people in one call; client splits on kind. ILIKE-substring (covered by the existing trigram GINs), ranked by similarity(). No pg_trgm GUC (0017 landmine).';

revoke all on function public.profile_summary(uuid)                      from public, anon;
revoke all on function public.score_histogram(uuid)                      from public, anon;
revoke all on function public.dishes_by_score(uuid, numeric, int)        from public, anon;
revoke all on function public.statement_months(uuid, text)               from public, anon;
revoke all on function public.monthly_statement(uuid, date, text)        from public, anon;
revoke all on function public.search_all(text, int)                      from public, anon;

grant execute on function public.profile_summary(uuid)                   to authenticated;
grant execute on function public.score_histogram(uuid)                   to authenticated;
grant execute on function public.dishes_by_score(uuid, numeric, int)     to authenticated;
grant execute on function public.statement_months(uuid, text)            to authenticated;
grant execute on function public.monthly_statement(uuid, date, text)     to authenticated;
grant execute on function public.search_all(text, int)                   to authenticated;
