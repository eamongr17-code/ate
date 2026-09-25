-- 0031_search_scopes.sql
-- Ate backend — the Search tab, audited against design/v1/Search.dc.html and
-- design/v1/SearchResults.dc.html. Four scope pills (Places · Dishes · People · Saved) and a
-- Nearby list that stands before a single key is pressed. Nothing here invents a read pattern:
-- every list is the house keyset (first page → nulls; next page → the LAST row's key), every
-- aggregate comes from the existing `dish_stats`/`restaurant_stats` views, and every function is
-- SECURITY INVOKER so RLS answers "whose block" exactly once (0019's `blocked_with`). (Every entry
-- is public from 0033 on, so blocks are the only viewer-relative rule left.)
--
-- WHAT THE AUDIT FOUND (each fixed below, in order):
--
--  1. THE ARTBOARD'S OWN EXAMPLE RETURNED NOTHING. SearchResults prints "ragu" → "Tagliatelle al
--     ragù", "Penne al ragù", "Pappardelle, duck ragù". `search_all` (0023) and
--     `search_local_restaurants` (0017) match with ILIKE, and `'ragù' ilike '%ragu%'` is FALSE —
--     so the three rows the design draws were unreachable. Melbourne menus are full of this
--     (ragù, crème, jalapeño, açaí, bánh mì, phở) and so are people's names. Accent folding is not
--     a nicety on this screen, it is the screen. Hence `unaccent` + `search_key()`, plus a trigram
--     GIN index on the folded name so the match stays index-eligible.
--
--  2. TWO OF THE FOUR SCOPES DID NOT EXIST. `search_all` returns place/dish/person, so People was
--     reachable but avatar-less (the avatar rode inside the `detail` jsonb) and Saved had no search
--     at all — the client would have had to filter `my_saved_dishes` locally, which stops being
--     true the moment the list is longer than one page.
--
--  3. NOTHING IN SEARCH WAS PAGEABLE. `search_all` takes `p_limit_per_kind` and no cursor: a scope
--     was capped at 25 rows with no way to ask for more. Every scope here is keyset-paged.
--
--  4. THE PLACE ROW PRINTED THE MANGLE. `search_all`'s place subtitle was
--     `coalesce(cuisine, city)`, and `restaurants.city` is "<street>, <suburb STATE post>" on every
--     row resolved live through `places-search op=details`. It reads `place_locality()` (0029) now,
--     which derives the suburb from the address on read. Also fixed at the source, forward-only, in
--     the edge function itself (same PR) — and NOT backfilled: rewriting stored rows to fix a
--     display string is not something this team does.
--
--  5. NEARBY COULD NOT PRINT ITS SCORE. design/v1/Search's Nearby rows are name · cuisine · score,
--     and `restaurants_nearby` (0005) returns no score. It is left EXACTLY as it is — the
--     `places-search` edge function calls it with the SERVICE ROLE, where an aggregate would be
--     computed past RLS and would count a blocked author's lines in the viewer's score. `nearby_places` is its
--     viewer-relative, keyset-paged sibling for the Search tab: SECURITY INVOKER, PostGIS-only,
--     no Google call, no spend, no rate limit. The composer's discovery path (op=nearby, which
--     falls back to Google to find places we do not hold) is untouched.
--
-- VIEWER-RELATIVE, AND WHAT THAT MEANS PER SCOPE (blocks, both directions, via `blocked_with`):
--   People — `profiles_select_visible` (0019) hides a blocked user, so they are not a row to
--     filter. This file writes no block predicate of its own, on purpose.
--   Dishes — a dish is returned only when the VIEWER can see at least one review of it. A dish
--     whose only lines are a blocked user's is gone, and so is an abandoned "add a new dish" shell
--     nobody ever logged. That is 0030's rule for `place_dishes`, applied to the same question.
--   Places — restaurants are world-readable catalogue rows and stay searchable; their aggregates
--     come from `restaurant_stats` (security_invoker), so the NUMBERS are viewer-relative even
--     though the row itself is not.
--   Saved — the caller's own rows only (`saves` RLS), which is what `my_saved_dishes` already is.
--
-- WIRE IMPACT
--   ADDITIVE: new RPCs `search_places`, `search_dishes`, `search_people`, `search_saved`,
--     `nearby_places`; new helpers `search_key`, `search_pattern`, `search_tier`; four trigram
--     indexes; the `unaccent` extension. Nothing existing is renamed, retyped or removed.
--   BEHAVIOURAL, same shape (annotate for iOS; nothing breaks): `search_all` now matches
--     accent-insensitively (MORE rows — "ragu" finds "ragù"), and its place `subtitle` falls back
--     to `place_locality(address, city)` instead of the raw `city`, so a place with no cuisine
--     prints "Carlton" where it used to print "12 Lygon St, Carlton VIC 3053". Its parameter list
--     and OUT columns are untouched, so `PlaceDirectoryClient`'s named-argument call keeps working
--     unedited.
--   NOT CHANGED: `restaurants_nearby`, `search_local_restaurants`, `search_manual_restaurants`,
--     `my_saved_dishes`. No table, column, policy or grant is altered. Nothing here writes.
--
-- LANDMINE 7 (data-model.md): a changed parameter list or OUT list means DROP-then-CREATE.
-- `search_all` keeps BOTH exactly, so create-or-replace is legal there and its grants survive. The
-- five new functions are dropped by their full signature first anyway, so a re-run can never leave
-- two overloads behind (two overloads = `42725` on every PostgREST named-argument call).

set search_path = public, extensions;

-- ===========================================================================
-- 0. THE MATCH KEY — one normalisation, used by every scope and by every index.
--
-- `unaccent` is the only new dependency in this file, and it is load-bearing (finding 1). The
-- TWO-ARGUMENT form takes an explicit dictionary, which is what lets the IMMUTABLE wrapper below be
-- honest enough for an index expression: bare `unaccent(text)` is STABLE because it resolves the
-- default dictionary at call time, and Postgres refuses a STABLE function in an index. This is the
-- documented recipe, not a trick.
-- ===========================================================================
create extension if not exists unaccent with schema extensions;

create or replace function public.search_key(p_text text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select lower(extensions.unaccent('extensions.unaccent'::regdictionary, btrim(coalesce(p_text, ''))));
$$;

comment on function public.search_key(text) is
  'The search match key: trimmed, accent-folded, lower-cased. IMMUTABLE so the trigram indexes can be built on it. ONE normalisation for the needle and the haystack — "ragu" has to find "ragù" (design/v1/SearchResults).';

-- The same key with LIKE metacharacters escaped, so a literal % / _ / \ a user typed matches itself
-- instead of acting as a wildcard. Backslash first, or the escapes get escaped.
create or replace function public.search_pattern(p_query text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select replace(replace(replace(public.search_key(p_query), '\', '\\'), '%', '\%'), '_', '\_');
$$;

comment on function public.search_pattern(text) is
  'search_key() with LIKE metacharacters escaped — the needle for a `like ''%'' || pattern || ''%''` predicate.';

-- How WELL a key matched, as an INT so no keyset cursor has to round-trip a float: 0 exact, 1 the
-- name starts with the query, 2 a WORD of the name starts with it, 3 it appears somewhere. Written
-- with position(), a literal substring search — no pattern, so nothing to escape. Tier 3 is also
-- what a NON-match returns, which is harmless everywhere it is used here: the WHERE clause has
-- already established containment, and `least(tier_a, tier_b)` can only be pulled DOWN by a real
-- match.
create or replace function public.search_tier(p_key text, p_query_key text)
returns int
language sql
immutable
set search_path = public, extensions
as $$
  select case
    when p_key = p_query_key                              then 0
    when position(p_query_key in p_key) = 1               then 1
    when position(' ' || p_query_key in ' ' || p_key) > 0 then 2
    else 3
  end;
$$;

comment on function public.search_tier(text, text) is
  'Match quality as an int: 0 exact, 1 prefix, 2 word-start, 3 contains. The leading sort key of every search scope — an int, so a cursor never round-trips a float.';

revoke all on function public.search_key(text)         from public, anon;
revoke all on function public.search_pattern(text)     from public, anon;
revoke all on function public.search_tier(text, text)  from public, anon;
grant execute on function public.search_key(text)        to authenticated, service_role;
grant execute on function public.search_pattern(text)    to authenticated, service_role;
grant execute on function public.search_tier(text, text) to authenticated, service_role;

-- ===========================================================================
-- 0b. INDEXES — the folded key, trigram GIN: exactly the pattern 0002/0012 use for the raw name.
-- The raw-name indexes STAY; `search_local_restaurants` (0017) still matches on `name` and its
-- word_similarity (`<%`) operator needs them.
-- `profiles.username` is citext, which has no gin_trgm_ops class — search_key() returns text, so
-- the cast 0012 had to write is already done.
-- ===========================================================================
create index if not exists restaurants_search_key_trgm
  on public.restaurants using gin (public.search_key(name) extensions.gin_trgm_ops);

create index if not exists dishes_search_key_trgm
  on public.dishes using gin (public.search_key(name) extensions.gin_trgm_ops);

create index if not exists profiles_username_search_key_trgm
  on public.profiles using gin (public.search_key(username::text) extensions.gin_trgm_ops);

create index if not exists profiles_name_search_key_trgm
  on public.profiles using gin (public.search_key(name) extensions.gin_trgm_ops);

-- ===========================================================================
-- 1. search_places — the Places pill with a query.
--
-- Prints exactly what the artboard prints: name, cuisine, score. `locality` rides along as the
-- honest second line for a place with no cuisine (`place_locality`, 0029 — never the raw `city`).
-- ORDER: match tier, then REVIEW COUNT DESC — 0030's reasoning for `place_dishes`, for the same
-- reason: one 5.0 from one person must not lead a list. Then name, then id, which makes the order
-- total and the cursor stable.
-- KEYSET (4 parts, pass all four from the LAST row): match_tier, review_count, name, restaurant_id.
-- ===========================================================================
drop function if exists public.search_places(text, int, int, int, text, uuid);

create function public.search_places(
  p_query               text,
  p_limit               int  default 20,
  p_cursor_match_tier   int  default null,
  p_cursor_review_count int  default null,
  p_cursor_name         text default null,
  p_cursor_id           uuid default null
)
returns table (
  restaurant_id uuid,
  name          text,
  cuisine       text,
  locality      text,
  avg_rating    numeric(2,1),
  review_count  int,
  people_count  int,
  dish_count    int,
  cover_url     text,
  match_tier    int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim
  ),
  hits as (
    select
      r.id,
      r.name,
      nullif(btrim(coalesce(r.cuisine, '')), '')           as cuisine,
      public.place_locality(r.address, r.city)             as locality,
      rs.avg_rating,
      coalesce(rs.review_count, 0)                         as review_count,
      coalesce(rs.people_count, 0)                         as people_count,
      coalesce(rs.dish_count, 0)                           as dish_count,
      nullif(btrim(coalesce(rs.cover_url, '')), '')        as cover_url,
      public.search_tier(public.search_key(r.name), q.key) as match_tier
    from public.restaurants r
    left join public.restaurant_stats rs on rs.restaurant_id = r.id
    cross join q
    where char_length(q.key) >= 2
      and public.search_key(r.name) like '%' || q.pat || '%'
  )
  select h.id, h.name, h.cuisine, h.locality, h.avg_rating,
         h.review_count, h.people_count, h.dish_count, h.cover_url, h.match_tier
  from hits h
  where p_cursor_id is null
     or (h.match_tier, -h.review_count, h.name, h.id)
        > (coalesce(p_cursor_match_tier, 0), -coalesce(p_cursor_review_count, 0),
           coalesce(p_cursor_name, ''), p_cursor_id)
  order by h.match_tier, h.review_count desc, h.name, h.id
  limit (select lim from q);
$$;

comment on function public.search_places(text, int, int, int, text, uuid) is
  'Search tab, Places scope: name · cuisine · score (design/v1/SearchResults). Accent-insensitive substring match, ranked by match tier then review count. Keyset (match_tier, review_count, name, restaurant_id) — pass all four from the last row.';

-- ===========================================================================
-- 2. search_dishes — the Dishes pill. The artboard's row is photo · dish name · PLACE name · score,
-- which is ONE row from ONE call: no client-side hydration of stats and restaurant names (three
-- round trips today, in DishSearchService).
--
-- A dish is returned only when the viewer can see at least one review of it (0030's rule): an
-- abandoned "add a new dish" shell is not a search result, and neither is a dish that exists only
-- because a blocked user logged it.
-- KEYSET (4 parts): match_tier, review_count, dish_name, dish_id.
-- ===========================================================================
drop function if exists public.search_dishes(text, int, int, int, text, uuid);

create function public.search_dishes(
  p_query               text,
  p_limit               int  default 20,
  p_cursor_match_tier   int  default null,
  p_cursor_review_count int  default null,
  p_cursor_dish_name    text default null,
  p_cursor_dish_id      uuid default null
)
returns table (
  dish_id             uuid,
  dish_name           text,
  restaurant_id       uuid,
  restaurant_name     text,
  restaurant_locality text,
  score               numeric(2,1),
  review_count        int,
  scored_count        int,
  people_count        int,
  cover_url           text,
  match_tier          int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim
  ),
  hits as (
    select
      d.id                                                 as dish_id,
      d.name                                               as dish_name,
      r.id                                                 as restaurant_id,
      r.name                                               as restaurant_name,
      public.place_locality(r.address, r.city)             as restaurant_locality,
      ds.score,
      coalesce(ds.review_count, 0)                         as review_count,
      coalesce(ds.scored_count, 0)                         as scored_count,
      coalesce(ds.people_count, 0)                         as people_count,
      nullif(btrim(coalesce(ds.cover_url, '')), '')        as cover_url,
      public.search_tier(public.search_key(d.name), q.key) as match_tier
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    left join public.dish_stats ds on ds.dish_id = d.id
    cross join q
    where char_length(q.key) >= 2
      and d.merged_into_dish_id is null
      and public.search_key(d.name) like '%' || q.pat || '%'
      and coalesce(ds.review_count, 0) > 0
  )
  select h.dish_id, h.dish_name, h.restaurant_id, h.restaurant_name, h.restaurant_locality,
         h.score, h.review_count, h.scored_count, h.people_count, h.cover_url, h.match_tier
  from hits h
  where p_cursor_dish_id is null
     or (h.match_tier, -h.review_count, h.dish_name, h.dish_id)
        > (coalesce(p_cursor_match_tier, 0), -coalesce(p_cursor_review_count, 0),
           coalesce(p_cursor_dish_name, ''), p_cursor_dish_id)
  order by h.match_tier, h.review_count desc, h.dish_name, h.dish_id
  limit (select lim from q);
$$;

comment on function public.search_dishes(text, int, int, int, text, uuid) is
  'Search tab, Dishes scope: cover · dish · place · score in ONE call (design/v1/SearchResults). Only dishes with a review the viewer can see — so a blocked user''s dish and an unlogged shell are both absent. Keyset (match_tier, review_count, dish_name, dish_id).';

-- ===========================================================================
-- 3. search_people — the People pill. handle, name, avatar; nothing else is drawn.
--
-- Tombstoned accounts are excluded (`deleted_at`); the CALLER is not — searching your own handle
-- and not finding yourself reads as a bug, so `is_me` is returned and the client decides.
-- KEYSET (3 parts): match_tier, username, user_id.
-- ===========================================================================
drop function if exists public.search_people(text, int, int, text, uuid);

create function public.search_people(
  p_query             text,
  p_limit             int  default 20,
  p_cursor_match_tier int  default null,
  p_cursor_username   text default null,
  p_cursor_user_id    uuid default null
)
returns table (
  user_id    uuid,
  username   citext,
  name       text,
  avatar_url text,
  city       text,
  is_me      boolean,
  match_tier int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim
  ),
  hits as (
    select
      p.id                                          as user_id,
      p.username,
      p.name,
      nullif(btrim(coalesce(p.avatar_url, '')), '') as avatar_url,
      nullif(btrim(coalesce(p.city, '')), '')       as city,
      (p.id = (select auth.uid()))                  as is_me,
      least(
        public.search_tier(public.search_key(p.username::text), q.key),
        public.search_tier(public.search_key(p.name), q.key)
      )                                             as match_tier
    from public.profiles p
    cross join q
    where char_length(q.key) >= 2
      and p.deleted_at is null
      and (
        public.search_key(p.username::text) like '%' || q.pat || '%'
        or public.search_key(p.name)        like '%' || q.pat || '%'
      )
  )
  select h.user_id, h.username, h.name, h.avatar_url, h.city, h.is_me, h.match_tier
  from hits h
  where p_cursor_user_id is null
     or (h.match_tier, h.username::text, h.user_id)
        > (coalesce(p_cursor_match_tier, 0), coalesce(p_cursor_username, ''), p_cursor_user_id)
  order by h.match_tier, h.username::text, h.user_id
  limit (select lim from q);
$$;

comment on function public.search_people(text, int, int, text, uuid) is
  'Search tab, People scope: handle · name · avatar, matched on handle OR name, accent-insensitive. Blocked users are absent because RLS says so (0019), not because this query remembers. Keyset (match_tier, username, user_id).';

-- ===========================================================================
-- 4. search_saved — the Saved pill. The SAME row as `my_saved_dishes`, same column names, so the
-- client decodes one shape whether it is browsing Saved or searching it, plus `restaurant_locality`
-- appended (the view's `restaurant_city` can be the mangle).
--
-- An EMPTY query returns everything, newest save first — that is the pill's pre-typing state, and
-- it is the same keyset, so the scope pages identically with or without a query.
-- Matching covers the dish name AND the restaurant name: "Tipo" should find what you saved there.
-- KEYSET (2 parts): saved_at, dish_id — `my_saved_dishes`' proven cursor, unchanged.
-- ===========================================================================
drop function if exists public.search_saved(text, int, timestamptz, uuid);

create function public.search_saved(
  p_query           text        default null,
  p_limit           int         default 20,
  p_cursor_saved_at timestamptz default null,
  p_cursor_dish_id  uuid        default null
)
returns table (
  dish_id             uuid,
  dish_name           text,
  restaurant_id       uuid,
  restaurant_name     text,
  restaurant_city     text,
  restaurant_locality text,
  dish_score          numeric(2,1),
  dish_cover_url      text,
  source_entry_id     uuid,
  source_user_id      uuid,
  source_username     citext,
  saved_at            timestamptz,
  cover_url           text
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim
  )
  select
    s.dish_id,
    d.name                                        as dish_name,
    r.id                                          as restaurant_id,
    r.name                                        as restaurant_name,
    nullif(btrim(coalesce(r.city, '')), '')       as restaurant_city,
    public.place_locality(r.address, r.city)      as restaurant_locality,
    ds.score                                      as dish_score,
    nullif(btrim(coalesce(ds.cover_url, '')), '') as dish_cover_url,
    s.source_entry_id,
    s.source_user_id,
    sp.username                                   as source_username,
    s.created_at                                  as saved_at,
    nullif(btrim(coalesce(ds.cover_url, '')), '') as cover_url
  from public.saves s
  join public.dishes d           on d.id = s.dish_id
  join public.restaurants r      on r.id = d.restaurant_id
  left join public.dish_stats ds on ds.dish_id = s.dish_id
  left join public.profiles sp   on sp.id = s.source_user_id
  cross join q
  where s.user_id = (select auth.uid())
    and (
      q.key = ''
      or public.search_key(d.name) like '%' || q.pat || '%'
      or public.search_key(r.name) like '%' || q.pat || '%'
    )
    and (
      p_cursor_dish_id is null
      or (s.created_at, s.dish_id) < (p_cursor_saved_at, p_cursor_dish_id)
    )
  order by s.created_at desc, s.dish_id desc
  limit (select lim from q);
$$;

comment on function public.search_saved(text, int, timestamptz, uuid) is
  'Search tab, Saved scope: my_saved_dishes'' columns (+ restaurant_locality), filtered by dish OR place name, accent-insensitive. An empty query is the whole list — the pill''s pre-typing state pages on the same keyset (saved_at, dish_id).';

-- ===========================================================================
-- 5. nearby_places — what design/v1/Search shows BEFORE a key is pressed: name · cuisine · score.
--
-- Viewer-relative by construction (SECURITY INVOKER over `restaurant_stats`), which is precisely
-- why this is NOT a widening of `restaurants_nearby`: that one is called by the `places-search`
-- edge function with the SERVICE ROLE, where an average would be computed past RLS and would count
-- the lines of people the viewer blocked (or who blocked them). This read costs nothing — PostGIS + the GIST index, no Google call,
-- no rate limit — because the Search tab is browsing what Ate already holds. Discovery of places we
-- do NOT hold stays where it belongs, in op=nearby's Google fallback for the composer.
--
-- ORDER/KEYSET: ST_Distance ascending, then restaurant_id. ST_Distance, NOT the `<->` KNN operator:
-- on geography those two use different models (sphere vs spheroid), and a cursor that compares one
-- against an order produced by the other skips rows. ST_DWithin still does the indexed work.
-- ===========================================================================
drop function if exists public.nearby_places(double precision, double precision, double precision, int, double precision, uuid);

create function public.nearby_places(
  p_lat               double precision,
  p_lng               double precision,
  p_radius_m          double precision default 5000,
  p_limit             int              default 20,
  p_cursor_distance_m double precision default null,
  p_cursor_id         uuid             default null
)
returns table (
  restaurant_id uuid,
  name          text,
  cuisine       text,
  locality      text,
  avg_rating    numeric(2,1),
  review_count  int,
  people_count  int,
  dish_count    int,
  cover_url     text,
  distance_m    double precision
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with origin as (
    select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::geography as g,
           least(greatest(coalesce(p_radius_m, 5000), 100), 50000) as radius,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim
  ),
  hits as (
    select
      r.id,
      r.name,
      nullif(btrim(coalesce(r.cuisine, '')), '')    as cuisine,
      public.place_locality(r.address, r.city)      as locality,
      rs.avg_rating,
      coalesce(rs.review_count, 0)                  as review_count,
      coalesce(rs.people_count, 0)                  as people_count,
      coalesce(rs.dish_count, 0)                    as dish_count,
      nullif(btrim(coalesce(rs.cover_url, '')), '') as cover_url,
      extensions.ST_Distance(r.location, o.g)       as distance_m
    from public.restaurants r
    left join public.restaurant_stats rs on rs.restaurant_id = r.id
    cross join origin o
    where r.location is not null
      and extensions.ST_DWithin(r.location, o.g, o.radius)
  )
  select h.id, h.name, h.cuisine, h.locality, h.avg_rating,
         h.review_count, h.people_count, h.dish_count, h.cover_url, h.distance_m
  from hits h
  where p_cursor_id is null
     or (h.distance_m, h.id) > (coalesce(p_cursor_distance_m, -1), p_cursor_id)
  order by h.distance_m, h.id
  limit (select lim from origin);
$$;

comment on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid) is
  'Search tab "Nearby" (design/v1/Search): places we already hold near a point, with their viewer-relative score. SECURITY INVOKER — unlike restaurants_nearby (0005), which the edge function calls service-role. PostGIS only: no Google call, no spend. Keyset (distance_m, restaurant_id).';

-- ===========================================================================
-- 6. search_all — UNCHANGED parameter list, UNCHANGED OUT columns (so create-or-replace is legal
-- and `PlaceDirectoryClient`'s named-argument call keeps working), with two behavioural fixes:
--   * every branch matches on `search_key`, so "ragu" finds "ragù" here too (finding 1);
--   * the place subtitle falls back to `place_locality(address, city)`, not the raw `city`
--     (finding 4) — this was the last caller reading the mangle.
-- Ranking still uses similarity() — on the folded key now — and still sets no pg_trgm GUC (the
-- 0017 landmine: setting one at migration time fails unless the library is already loaded).
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
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(p_limit_per_kind, 1), 25) as lim
  ),
  place_hits as (
    select 'place'::text as kind, r.id, r.name as title,
           coalesce(nullif(btrim(coalesce(r.cuisine, '')), ''),
                    public.place_locality(r.address, r.city)) as subtitle,
           rs.avg_rating as score,
           similarity(public.search_key(r.name), q.key)::real as match_rank,
           jsonb_build_object('city', r.city, 'cuisine', r.cuisine, 'address', r.address,
                              'locality', public.place_locality(r.address, r.city),
                              'people_count', coalesce(rs.people_count, 0)) as detail
    from public.restaurants r
    left join public.restaurant_stats rs on rs.restaurant_id = r.id
    cross join q
    where char_length(q.key) >= 2
      and public.search_key(r.name) like '%' || q.pat || '%'
    order by similarity(public.search_key(r.name), q.key) desc, r.name
    limit (select lim from q)
  ),
  dish_hits as (
    select 'dish'::text as kind, d.id, d.name as title, r.name as subtitle,
           ds.score,
           similarity(public.search_key(d.name), q.key)::real as match_rank,
           jsonb_build_object('restaurant_id', r.id, 'restaurant_city', r.city,
                              'restaurant_locality', public.place_locality(r.address, r.city),
                              'people_count', coalesce(ds.people_count, 0),
                              'cover_url', ds.cover_url) as detail
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    left join public.dish_stats ds on ds.dish_id = d.id
    cross join q
    where char_length(q.key) >= 2
      and d.merged_into_dish_id is null
      and public.search_key(d.name) like '%' || q.pat || '%'
    order by similarity(public.search_key(d.name), q.key) desc, d.name
    limit (select lim from q)
  ),
  people_hits as (
    select 'person'::text as kind, p.id, p.username::text as title, p.name as subtitle,
           null::numeric(2,1) as score,
           greatest(similarity(public.search_key(p.username::text), q.key),
                    similarity(public.search_key(p.name), q.key))::real as match_rank,
           jsonb_build_object('avatar_url', p.avatar_url, 'city', p.city) as detail
    from public.profiles p
    cross join q
    where char_length(q.key) >= 2
      and p.deleted_at is null
      and (public.search_key(p.username::text) like '%' || q.pat || '%'
           or public.search_key(p.name)        like '%' || q.pat || '%')
    order by greatest(similarity(public.search_key(p.username::text), q.key),
                      similarity(public.search_key(p.name), q.key)) desc, p.username
    limit (select lim from q)
  )
  select * from place_hits
  union all select * from dish_hits
  union all select * from people_hits;
$$;

comment on function public.search_all(text, int) is
  'Search places + dishes + people in one UNPAGED call; the composer''s place sheet reads its place rows. The Search TAB uses the four keyset-paged scope RPCs (0031). Accent-insensitive via search_key(); a place''s subtitle is cuisine, else place_locality() — never the raw city. No pg_trgm GUC (0017 landmine).';

-- ===========================================================================
-- GRANTS — `anon` is revoked on every V1 read path; the Search tab is signed-in only.
-- ===========================================================================
revoke all on function public.search_places(text, int, int, int, text, uuid) from public, anon;
revoke all on function public.search_dishes(text, int, int, int, text, uuid) from public, anon;
revoke all on function public.search_people(text, int, int, text, uuid)      from public, anon;
revoke all on function public.search_saved(text, int, timestamptz, uuid)     from public, anon;
revoke all on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid)
  from public, anon;

grant execute on function public.search_places(text, int, int, int, text, uuid) to authenticated;
grant execute on function public.search_dishes(text, int, int, int, text, uuid) to authenticated;
grant execute on function public.search_people(text, int, int, text, uuid)      to authenticated;
grant execute on function public.search_saved(text, int, timestamptz, uuid)     to authenticated;
grant execute on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid)
  to authenticated;
