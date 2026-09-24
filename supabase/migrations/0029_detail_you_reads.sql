-- 0029_detail_you_reads.sql
-- Ate backend — the Place / Dish / You / Ratings / Recap reads, audited against the
-- artboards they feed (design/v1/Restaurant, Dish, You, Ratings, Recap) and against the
-- ENTRIES model. 0022/0023 were written before the entry was the user's atom; this closes
-- the gaps that audit found. Nothing here invents a read path: every function already
-- existed, and every paged one keeps the proven (created_at, id) keyset.
--
-- WHAT WAS ACTUALLY WRONG (each fixed below, in order):
--
--  1. TWO SCREENS DISAGREED ABOUT THE SAME PERSON. `profile_summary` counted a user's
--     dishes by joining reviews → entries, so a review written before entries existed
--     (`entry_id is null` — staging holds 20 of them for @eamon; prod holds real ones)
--     counted for NOBODY, while `score_histogram` counted them. You printed "40 scored"
--     next to a Ratings chart summing to 60. Both now count by `reviews.reviewer_id`,
--     which is the line's author on every row the sorter or Wave 0 ever wrote. Orders and
--     Places stay ENTRY counts — that is what design/v1/You labels them.
--
--  2. THE PLACE HEADER'S TAG LINE HAD NO SOURCE. design/v1/Restaurant prints two chips
--     after the score: the cuisine and the LOCALITY ("Italian", "CBD"). `restaurants.city`
--     is a bare suburb for stub + manual rows but, for anything resolved live through
--     `places-search op=details`, it is the mangled "<street>, <suburb STATE post>" that
--     function's formatted-address split produces. `place_locality()` derives the chip from
--     the address (verbatim from Google) with the stored city as fallback — DERIVED ON
--     READ, so it is right for rows we already hold and needs no backfill of anyone's data.
--
--  3. EMPTY STRINGS WERE SERVED AS VALUES. `places-search` writes `cover_url: ''` and can
--     write `cuisine: ''`; `place_summary` passed them straight through, so a client that
--     null-checks drew a broken image and an empty chip. Every text column
--     `place_summary`/`dish_summary` returns is `nullif(btrim(…), '')` now: absent is NULL.
--
--  4. THE DISH HEADER IS A PHOTO STACK and `dish_summary` served ONE `cover_url`.
--     `dish_photos()` returns the photos the cover derivation already ranks, newest first —
--     so `photos[0].url` IS `cover_url`, by construction.
--
--  5. "YOUR 5.0s" AND THE RATINGS LIST DRAW A THUMBNAIL PER ROW, and `dishes_by_score`
--     served no photo at all. It now returns the dish's `cover_url`.
--
--  6. TWO LIST RPCs COULD NOT BE PAGED. `dishes_by_score` and `statement_months` returned
--     a capped list with no cursor. Both are keyset-paged now on the house contract (first
--     page → nulls; next page → the LAST row's key). `place_dishes` gains one too and
--     keeps its designed order — score desc, then people, then NAME — by comparing the
--     four-part key explicitly instead of dropping a tiebreak the menu is read by.
--
--  7. THE RECAP PRINTED A LIE ON A THIN MONTH. `most_ordered` / `most_visited` returned
--     the argmax even when the max was 1 — "Most ordered … Beef tartare x1" is real
--     September output from staging. A thing ordered once is not the most ordered: both are
--     NULL below 2 now, which the client already had to handle. The receipt also carries
--     the `username` it prints under the month, so Recap and Share are one call, not two.
--
--  8. `place_summary` COUNTED REVIEW LINES WHERE THE SCREEN COUNTS VISITS. `review_count`
--     (18 lines at Tipo 00) stays for anything using it; `entry_count` (the 8 visits those
--     lines came from) is the entries-era number and the public counterpart of the
--     "Your N visits" row, which was already `my_visits`.
--
-- VERIFIED-UNCHANGED (audited against the artboards, found already correct — no edit):
--   `get_entries_at_place` / `get_entries_by_author` already return `setof entry_cards`
--   (the ONE entry shape), already keyset-paged. `get_dish_reviews` already carries
--   `entry_id`, the author handle and the note, mine-first, 3-part keyset — but its
--   `entry_id` is NULLABLE on real rows (a Wave-0 line has no entry to open), which only
--   the doc knew. `score_histogram` (ten buckets, zeros included) and `is_dish_saved` are
--   correct as written. Comments are added where nullability or the shape lived only in the
--   contract doc.
--
-- VIEWER-RELATIVITY IS UNTOUCHED AND STILL THE POINT: every function here is SECURITY
-- INVOKER, so RLS answers "whose private entry, whose block" exactly once (0019's
-- `blocked_with`), and a NULL score stays NULL (DESIGN rule 7) — no aggregate, count or
-- photo in this file treats "no number" as a zero.
--
-- LANDMINE 7 (data-model.md): a function whose OUT list or parameter list changes must be
-- DROPPED and recreated — `create or replace` refuses the first, and silently creates a
-- SECOND OVERLOAD on the second, which makes every PostgREST named-argument call ambiguous
-- (42725 function is not unique) — a silent break for the client, not a warning. The DO
-- block below drops every overload BY NAME so that cannot happen, and the grants are
-- restated because a drop takes them with it.
--
-- WIRE IMPACT
--   ADDITIVE (appended last on every shape; no existing key renamed, retyped or removed):
--     place_summary + locality, + entry_count
--     dish_summary + photos, + restaurant_locality
--     dishes_by_score + cover_url
--     place_dishes + p_cursor_score / p_cursor_people / p_cursor_dish_name / p_cursor_dish_id
--     dishes_by_score + p_cursor_created_at / p_cursor_id
--     statement_months + p_cursor_month / p_limit
--     monthly_statement + "username"
--     new: place_locality(address, city), dish_photos(dish, limit)
--   BEHAVIOURAL (same shape, different value — sequenced with iOS through the lead):
--     profile_summary.dishes/scored/avg_score now include pre-entries lines (counts RISE
--       for a legacy user; identical for anyone who only ever wrote entries)
--     place_summary.address/city/cuisine/cover_url and dish_summary.restaurant_city are
--       NULL instead of '' when empty
--     monthly_statement.most_ordered/most_visited are NULL when the count is 1
--   NOT CHANGED: place_dishes' order (the cursor made it explicit, it did not move a row);
--     no table, column, policy or grant beyond restoring the five dropped functions'.
--     Nothing in this file writes.

set search_path = public, extensions;

-- ===========================================================================
-- 1. place_locality — the chip design/v1/Restaurant prints after the cuisine.
--
-- Pure text, IMMUTABLE, reads no table: the one place that knows how to get a suburb out
-- of what we hold. First non-empty wins:
--   1. the ADDRESS component in front of an AU state token
--      ("361 Little Bourke St, Melbourne VIC 3000, Australia" → "Melbourne"). `[^,]+?`
--      cannot cross a comma, so the capture is one address component and nothing more.
--      Case-SENSITIVE state list plus `\M` (end of word) on purpose: a lower-case 'wa'
--      would otherwise match inside "Wallace Ave".
--   2. the same shape inside the stored CITY — where places-search leaves the mangle for a
--      live Google resolution.
--   3. the stored city when it is already a bare locality: every manual row (0014 stores
--      the form's suburb there) and every stub row ("Fitzroy", "Melbourne").
--   4. the component before the country, for an address with no state token.
-- NULL when we cannot honestly name one — then the client draws no chip. It never guesses.
-- ===========================================================================
create or replace function public.place_locality(p_address text, p_city text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  with src as (
    select coalesce(p_address, '') as address, coalesce(p_city, '') as city
  ),
  parts as (
    select string_to_array(address, ',') as a from src
  )
  select nullif(btrim(coalesce(
    (select (regexp_match(address, '([^,]+?)[[:space:]]+(VIC|NSW|QLD|SA|WA|TAS|NT|ACT)\M'))[1] from src),
    (select (regexp_match(city,    '([^,]+?)[[:space:]]+(VIC|NSW|QLD|SA|WA|TAS|NT|ACT)\M'))[1] from src),
    (select city from src where position(',' in city) = 0),
    (select a[array_length(a, 1) - 1] from parts where array_length(a, 1) >= 3)
  )), '');
$$;

comment on function public.place_locality(text, text) is
  'The suburb chip for a place, derived on read from the address (authoritative) with the stored city as fallback. NULL when neither names one. Never stored: places-search leaves a mangled city on live Google rows, and no user data gets rewritten to fix a display string.';

revoke all on function public.place_locality(text, text) from public;
grant execute on function public.place_locality(text, text) to authenticated, anon, service_role;

-- ===========================================================================
-- 2. dish_photos — the tilted stack design/v1/Dish draws above the header.
--
-- Exactly the photos `dish_cover_url` (0026) ranks, in the same order, one per review:
-- `coalesce(reviews.photo_url, the first entry_photo of that review's entry)`, newest
-- review first. So `photos[0].url` IS the dish's `cover_url` and the stack cannot disagree
-- with the thumbnail. SECURITY INVOKER: a private entry's photo is in its author's stack
-- and nobody else's — the same rule the cover already follows.
-- ===========================================================================
create or replace function public.dish_photos(p_dish_id uuid, p_limit int default 8)
returns jsonb
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('url', p.url, 'entry_id', p.entry_id)
              order by p.created_at desc, p.review_id desc),
    '[]'::jsonb)
  from (
    select v.id as review_id, v.entry_id, v.created_at,
           coalesce(v.photo_url, ep.photo_url) as url
    from public.reviews v
    left join lateral (
      select x.photo_url
      from public.entry_photos x
      where x.entry_id = v.entry_id
      order by x.position, x.created_at
      limit 1
    ) ep on true
    where v.dish_id = p_dish_id
      and coalesce(v.photo_url, ep.photo_url) is not null
    order by v.created_at desc, v.id desc
    limit least(greatest(p_limit, 1), 24)
  ) p;
$$;

comment on function public.dish_photos(uuid, int) is
  'A dish''s photos, newest first, one per review, same derivation as dish_cover_url — photos[0].url == cover_url. [] when it has none. Viewer-relative through RLS.';

revoke all on function public.dish_photos(uuid, int) from public, anon;
grant execute on function public.dish_photos(uuid, int) to authenticated;

-- ===========================================================================
-- 3. Drop every overload of the five functions whose OUT or parameter list changes.
-- BY NAME, not by signature: a `drop … if exists` with the wrong signature silently does
-- nothing, and the CREATE below then leaves TWO overloads — landmine 7, a 42725 on every
-- named-argument call the client makes.
-- ===========================================================================
do $$
declare
  sigs text[];
  sig  text;
begin
  -- one catalog read, then the drops: never iterate a pg_proc cursor while dropping from it.
  select array_agg(p.oid::regprocedure::text)
    into sigs
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in (
      'place_summary', 'place_dishes', 'dish_summary', 'dishes_by_score', 'statement_months'
    );

  foreach sig in array coalesce(sigs, array[]::text[])
  loop
    execute format('drop function if exists %s', sig);
  end loop;
end $$;

-- ===========================================================================
-- 4. PLACE HEADER — one round trip for design/v1/Restaurant's title, chips, cover and
-- "Your N visits" row.
--   locality    — the second chip (see place_locality).
--   entry_count — VISITS here (entries), the public counterpart of my_visits. review_count
--                 is kept and still counts receipt LINES: at Tipo 00 that is 18 lines from
--                 8 visits, and printing the wrong one is a lie either way.
--   cover_url   — the newest visible dish photo (0026), falling back to the catalogue
--                 cover, NULL rather than '' when there is none.
-- ===========================================================================
create function public.place_summary(p_restaurant_id uuid)
returns table (
  restaurant_id uuid,
  name          text,
  address       text,
  city          text,
  cuisine       text,
  cover_url     text,
  avg_rating    numeric(2,1),
  review_count  int,
  people_count  int,
  dish_count    int,
  my_visits     int,
  my_last_visit timestamptz,
  -- appended 0029
  locality      text,
  entry_count   int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    r.id, r.name,
    nullif(btrim(r.address), ''), nullif(btrim(r.city), ''), nullif(btrim(r.cuisine), ''),
    nullif(btrim(coalesce(rs.cover_url, r.cover_url)), ''),
    rs.avg_rating, coalesce(rs.review_count, 0), coalesce(rs.people_count, 0),
    coalesce(rs.dish_count, 0),
    coalesce(mine.visits, 0), mine.last_visit,
    public.place_locality(r.address, r.city),
    coalesce(here.visits, 0)
  from public.restaurants r
  left join public.restaurant_stats rs on rs.restaurant_id = r.id
  left join lateral (
    select count(*)::int as visits, max(e.created_at) as last_visit
    from public.entries e
    where e.restaurant_id = r.id and e.author_id = (select auth.uid())
  ) mine on true
  left join lateral (
    select count(*)::int as visits
    from public.entries e
    where e.restaurant_id = r.id
  ) here on true
  where r.id = p_restaurant_id;
$$;

comment on function public.place_summary(uuid) is
  'The place page header in one call: the row (empty text as NULL), its viewer-relative aggregates, the locality chip, entry_count = visits here, and my_visits/my_last_visit. review_count counts receipt LINES; entry_count counts VISITS.';

-- ===========================================================================
-- 5. PLACE — "What to order", now pageable without losing its designed order.
--
-- The order is unchanged: score desc (unscored last), then people_count desc, then NAME.
-- The keyset is therefore four parts, compared branch by branch rather than as one row
-- comparison — a row comparison cannot mix descending score with ascending name, and
-- dropping the name tiebreak would reshuffle a menu's unreviewed tail on every read.
-- Pass all four values from the LAST row of the previous page (score may be null).
-- ===========================================================================
create function public.place_dishes(
  p_restaurant_id    uuid,
  p_limit            int     default 50,
  p_cursor_score     numeric default null,
  p_cursor_people    int     default null,
  p_cursor_dish_name text    default null,
  p_cursor_dish_id   uuid    default null
)
returns table (
  dish_id      uuid,
  dish_name    text,
  score        numeric(2,1),
  people_count int,
  review_count int,
  cover_url    text
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select ds.dish_id, d.name, ds.score, ds.people_count, ds.review_count, ds.cover_url
  from public.dish_stats ds
  join public.dishes d on d.id = ds.dish_id
  where ds.restaurant_id = p_restaurant_id
    and (
      p_cursor_dish_id is null
      or coalesce(ds.score, -1) < coalesce(p_cursor_score, -1)
      or (coalesce(ds.score, -1) = coalesce(p_cursor_score, -1)
          and ds.people_count < coalesce(p_cursor_people, 0))
      or (coalesce(ds.score, -1) = coalesce(p_cursor_score, -1)
          and ds.people_count = coalesce(p_cursor_people, 0)
          and (d.name, ds.dish_id) > (coalesce(p_cursor_dish_name, ''), p_cursor_dish_id))
    )
  order by coalesce(ds.score, -1) desc, ds.people_count desc, d.name, ds.dish_id
  limit least(greatest(p_limit, 1), 200);
$$;

comment on function public.place_dishes(uuid, int, numeric, int, text, uuid) is
  'Ranked "what to order": score desc (unscored last), people_count desc, name. Keyset is 4-part — pass p_cursor_score / p_cursor_people / p_cursor_dish_name / p_cursor_dish_id from the last row. Dishes with no reviews are included: a dish someone logged without a number still belongs on the menu.';

-- ===========================================================================
-- 6. DISH HEADER — + the photo stack, + the locality, and empty city as NULL.
-- A dish's "orders" is review_count: one entry prints one line per dish, so there is no
-- entry_count worth a column here (unlike a place, where the two differ by a factor).
-- ===========================================================================
create function public.dish_summary(p_dish_id uuid)
returns table (
  dish_id             uuid,
  dish_name           text,
  restaurant_id       uuid,
  restaurant_name     text,
  restaurant_city     text,
  score               numeric(2,1),
  review_count        int,
  scored_count        int,
  people_count        int,
  cover_url           text,
  saved               boolean,
  my_last_score       numeric(2,1),
  -- appended 0029
  photos              jsonb,
  restaurant_locality text
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    d.id, d.name, r.id, r.name, nullif(btrim(r.city), ''),
    ds.score, coalesce(ds.review_count, 0), coalesce(ds.scored_count, 0),
    coalesce(ds.people_count, 0),
    ds.cover_url,
    exists (select 1 from public.saves s where s.dish_id = d.id and s.user_id = (select auth.uid())),
    (
      select v.score from public.reviews v
      where v.dish_id = d.id and v.reviewer_id = (select auth.uid()) and v.score is not null
      order by v.created_at desc, v.id desc limit 1
    ),
    public.dish_photos(d.id, 8),
    public.place_locality(r.address, r.city)
  from public.dishes d
  join public.restaurants r on r.id = d.restaurant_id
  left join public.dish_stats ds on ds.dish_id = d.id
  where d.id = p_dish_id;
$$;

comment on function public.dish_summary(uuid) is
  'The dish page header in one call: the dish, its place, viewer-relative aggregates (score NULL = nobody scored it), the photo stack (photos[0].url == cover_url), and the viewer''s own save state + last score. A dish''s "orders" is review_count.';

-- ===========================================================================
-- 7. RATINGS bar tap / You's "Your 5.0s" — + the thumbnail, + a cursor.
-- One row per REVIEW, so two sittings of the same dish both show (sittings are a feature,
-- data-model landmine 4). `created_at` is the visit's date: a sorter-written line inherits
-- its entry's created_at (0021/0024), which is what design/v1/Ratings prints ("19 Sep").
-- ===========================================================================
create function public.dishes_by_score(
  p_user_id           uuid,
  p_score             numeric,
  p_limit             int         default 100,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null
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
  created_at      timestamptz,
  -- appended 0029
  cover_url       text
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select v.id, v.entry_id, d.id, d.name, r.id, r.name, v.score, v.note, v.created_at,
         public.dish_cover_url(d.id)
  from public.reviews v
  join public.dishes d      on d.id = v.dish_id
  join public.restaurants r on r.id = d.restaurant_id
  where v.reviewer_id = p_user_id
    and v.score = p_score::numeric(2,1)
    and (
      p_cursor_created_at is null
      or (v.created_at, v.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by v.created_at desc, v.id desc
  limit least(greatest(p_limit, 1), 500);
$$;

comment on function public.dishes_by_score(uuid, numeric, int, timestamptz, uuid) is
  'One user''s lines at exactly this score, newest first, with the dish''s cover_url for the tile. entry_id is NULL on a pre-entries line — the row still renders, it just has no entry to open. Keyset (created_at, id) desc.';

-- ===========================================================================
-- 8. RECAP PICKER — newest first, now paged on the month itself (a month is unique per
-- user, so the month IS the cursor).
-- ===========================================================================
create function public.statement_months(
  p_user_id      uuid,
  p_tz           text default 'Australia/Melbourne',
  p_cursor_month date default null,
  p_limit        int  default 60
)
returns table (month date, orders int)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select m.month, m.orders
  from (
    select (date_trunc('month', (e.created_at at time zone p_tz)))::date as month,
           count(*)::int as orders
    from public.entries e
    where e.author_id = p_user_id
    group by 1
  ) m
  where p_cursor_month is null or m.month < p_cursor_month
  order by m.month desc
  limit least(greatest(p_limit, 1), 240);
$$;

comment on function public.statement_months(uuid, text, date, int) is
  'Which months have a statement, newest first, with the entry count each. Month boundaries are local to p_tz. Keyset: pass the last row''s month as p_cursor_month.';

-- ===========================================================================
-- 9. Restore the grants the drop took with it.
-- ===========================================================================
revoke all on function public.place_summary(uuid)                                    from public, anon;
revoke all on function public.place_dishes(uuid, int, numeric, int, text, uuid)      from public, anon;
revoke all on function public.dish_summary(uuid)                                     from public, anon;
revoke all on function public.dishes_by_score(uuid, numeric, int, timestamptz, uuid) from public, anon;
revoke all on function public.statement_months(uuid, text, date, int)                from public, anon;

grant execute on function public.place_summary(uuid)                                    to authenticated;
grant execute on function public.place_dishes(uuid, int, numeric, int, text, uuid)      to authenticated;
grant execute on function public.dish_summary(uuid)                                     to authenticated;
grant execute on function public.dishes_by_score(uuid, numeric, int, timestamptz, uuid) to authenticated;
grant execute on function public.statement_months(uuid, text, date, int)                to authenticated;

-- ===========================================================================
-- 10. profile_summary — SAME shape (create or replace, no drop needed), one counting rule
-- changed. Orders and Places are ENTRY counts, which is what design/v1/You labels them.
-- Dishes / Scored / Avg are the person's receipt LINES, counted by `reviewer_id` instead of
-- through `entries` — because a line written before entries existed is still a dish they
-- logged, and the histogram beside it always counted those. One person, one set of numbers.
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
    p.id, p.username, p.name, p.avatar_url, p.bio, nullif(btrim(p.city), ''), p.created_at,
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
    where rv.reviewer_id = p.id
  ) v on true
  where p.id = p_user_id;
$$;

comment on function public.profile_summary(uuid) is
  'Profile header + derived counts. orders/places count ENTRIES (visits, distinct places); dishes/scored/avg_score count the person''s receipt LINES by reviewer_id, pre-entries ones included, so You and Ratings agree. Viewer-relative: a stranger sees their public entries only.';

-- ===========================================================================
-- 11. monthly_statement — same jsonb contract, three honest changes:
--   + "username", so the receipt design/v1/Recap prints under the month (and Share's copy
--     of it) needs no second call;
--   most_ordered / most_visited are NULL below a count of 2 — "Most ordered: Beef tartare
--     x1" was real September output, and a thing ordered once is not a habit. Both keys
--     were already documented nullable, so no client changes shape;
--   everything else is 0023 verbatim: bounds local to p_tz, "stars" the sum of what they
--     handed out, "average" over SCORED lines only (DESIGN rule 7 — an unscored dish never
--     drags an average down).
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
    having count(*) > 1
    order by count(*) desc, max(i.dish_name)
    limit 1
  ),
  most_visited as (
    select jsonb_build_object('restaurant_id', ent.restaurant_id,
                             'restaurant_name', max(r.name),
                             'count', count(*)::int) as v
    from ent join public.restaurants r on r.id = ent.restaurant_id
    where ent.restaurant_id is not null
    group by ent.restaurant_id
    having count(*) > 1
    order by count(*) desc, max(r.name)
    limit 1
  )
  select jsonb_build_object(
    -- the first of the month, ISO. (Formatted with DD, not a literal '01' — digits in
    -- a to_char pattern are not safe to assume pass through.)
    'month',        to_char(date_trunc('month', p_month::timestamp), 'YYYY-MM-DD'),
    'username',     (select p.username::text from public.profiles p where p.id = p_user_id),
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
  'The monthly statement as one jsonb object (month, username, orders, places, new_places, dishes, stars, average, top_dishes[], most_ordered, most_visited). Month boundaries are local to p_tz. most_ordered/most_visited are NULL below a count of 2. average/stars cover scored lines only.';

-- ===========================================================================
-- 12. The keyset dishes_by_score pages on. reviews_reviewer_score_idx (0018) is
-- (reviewer_id, score) — a prefix of this one, left in place (forward-only; dropping it
-- buys nothing during a release).
-- ===========================================================================
create index if not exists reviews_reviewer_score_recent_idx
  on public.reviews (reviewer_id, score, created_at desc, id desc)
  where score is not null;

-- ===========================================================================
-- 13. The reads this audit found already correct — documented where only the doc knew.
-- ===========================================================================
comment on function public.get_entries_by_author(uuid, timestamptz, uuid, int) is
  'One author''s entries as `entry_cards` — the ONE entry shape, never review rows. Yours includes private entries, someone else''s is public-only (RLS). Keyset (created_at, id) desc.';

comment on function public.get_entries_at_place(uuid, text, timestamptz, uuid, int) is
  'Entries at a place as `entry_cards` — the ONE entry shape. p_scope: mine (design/v1/Restaurant''s "Your N visits"), others, or all. Keyset (created_at, id) desc.';

comment on function public.get_dish_reviews(uuid, boolean, timestamptz, uuid, int) is
  'Reviews of a dish, the caller''s own first then newest. Keyset is (is_mine, created_at, id) desc — pass all three from the last row. entry_id is NULLABLE (a pre-entries line has no entry to open); score and note are nullable by design; photos[] belongs to the review''s ENTRY, so it can hold a photo of another dish from the same visit.';

comment on function public.score_histogram(uuid) is
  'Ten half-step buckets (0.5..5.0), zeros included: distinct dishes + line count per score for one user, counted by reviewer_id — the same population profile_summary''s dishes/scored count.';
