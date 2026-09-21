-- 0022_entry_reads.sql
-- Ate backend — V1 RETHINK: every read the app needs for an entry, a feed, a
-- place page and a dish page — behind ONE row shape.
--
-- THE ONE SHAPE: `entry_cards`. Journal slip, Feed slip, the Entry page and the
-- Share receipt are the same data at four densities (docs/DESIGN.md Components),
-- so they are one row type: the entry + author + place + photos[] + items[] +
-- the receipt footer numbers (dish_count, avg_score). Three RPCs return
-- `setof entry_cards` — feed, by-author, at-place — so the client decodes ONE
-- struct and the four surfaces can never drift apart.
--
-- PAGINATION is the proven get_feed keyset: (created_at, id) row comparison,
-- descending, page-size-clamped. The global feed IS that query minus the follow
-- join (there are no follows in V1) — nothing new was invented.
--
-- AGGREGATES ARE VIEWER-RELATIVE, and that is deliberate. Every stat view/RPC here
-- is SECURITY INVOKER, so a PRIVATE entry's dish reviews (hidden by 0019's reviews
-- policy) contribute to nobody's averages but their author's. The alternative —
-- counting private reviews in public aggregates — leaks a score the moment a dish
-- has one reviewer. Privacy wins; flag for the lead as a product-visible choice.
--
-- WIRE IMPACT:
--   ADDITIVE : view `entry_cards`; RPCs `get_entry_feed`, `get_entries_by_author`,
--              `get_entries_at_place`, `place_dishes`, `place_summary`,
--              `dish_summary`, `get_dish_reviews`; columns appended to `dish_stats`
--              (scored_count, people_count) and `restaurant_stats` (people_count,
--              dish_count) — appended LAST, existing columns untouched.

set search_path = public, extensions;

-- ===========================================================================
-- dish_stats — + scored_count, + people_count (appended; 0009's columns unchanged).
-- `score` already ignores NULL scores because avg() skips NULLs — that is the
-- DESIGN rule 7 requirement, now made explicit by scored_count sitting next to it.
-- A dish with reviews but no scores reads score=NULL, review_count>0, scored_count=0
-- → the client draws an empty star.
-- ===========================================================================
create or replace view public.dish_stats
with (security_invoker = true) as
  select
    d.id              as dish_id,
    d.restaurant_id,
    round(avg(r.score), 1)::numeric(2,1) as score,     -- NULL when nobody scored it
    count(r.id)::int  as review_count,
    cov.cover_url,
    count(r.score)::int as scored_count,
    count(distinct r.reviewer_id)::int as people_count
  from public.dishes d
  left join public.reviews r on r.dish_id = d.id
  left join lateral (
    select rp.photo_url as cover_url
    from public.reviews rp
    where rp.dish_id = d.id
      and rp.photo_url is not null
    order by rp.created_at desc, rp.id desc
    limit 1
  ) cov on true
  where d.merged_into_dish_id is null
  group by d.id, d.restaurant_id, cov.cover_url;

comment on view public.dish_stats is
  'Per-dish aggregates over the reviews the VIEWER can see: score (NULL = nobody scored it), review_count (all), scored_count, people_count (distinct reviewers), cover_url. Live dishes only.';

-- ===========================================================================
-- restaurant_stats — + people_count, + dish_count (appended).
-- avg_rating stays the MEAN OF PER-DISH AVERAGES with null-score dishes excluded.
-- ===========================================================================
create or replace view public.restaurant_stats
with (security_invoker = true) as
  select
    rst.id as restaurant_id,
    round(avg(ds.score) filter (where ds.score is not null), 1)::numeric(2,1) as avg_rating,
    coalesce(sum(ds.review_count), 0)::int as review_count,
    cov.cover_url,
    coalesce(ppl.people_count, 0)::int as people_count,
    count(ds.dish_id) filter (where ds.review_count > 0)::int as dish_count
  from public.restaurants rst
  left join public.dish_stats ds on ds.restaurant_id = rst.id
  left join lateral (
    select rp.photo_url as cover_url
    from public.reviews rp
    where rp.restaurant_id = rst.id
      and rp.photo_url is not null
    order by rp.created_at desc, rp.id desc
    limit 1
  ) cov on true
  left join lateral (
    select count(distinct rp.reviewer_id)::int as people_count
    from public.reviews rp
    where rp.restaurant_id = rst.id
  ) ppl on true
  group by rst.id, cov.cover_url, ppl.people_count;

comment on view public.restaurant_stats is
  'Restaurant rating = MEAN OF PER-DISH AVERAGES (null-score dishes excluded) + review_count + cover_url + people_count (distinct reviewers) + dish_count (dishes with at least one visible review).';

grant select on public.dish_stats       to authenticated, anon;
grant select on public.restaurant_stats to authenticated, anon;

-- ===========================================================================
-- entry_cards — the one shape.
--
-- items[] carries `score: null` for a dish the user never numbered (rule 7) and
-- `note: null` when they wrote nothing about it — the receipt renders an empty star
-- and no quote. avg_score averages the SCORED items only ((4.5 + 3.0)/2 = 3.75 for a
-- three-dish receipt with one unscored dish — exactly the design's footer), while
-- dish_count counts every line. `saved` on each item is the viewer's own save state,
-- so the bookmark on a feed slip needs no second query.
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
      'city', r.city, 'cuisine', r.cuisine
    ) end as place,
    coalesce(ph.photos, '[]'::jsonb) as photos,
    coalesce(ph.photo_count, 0)      as photo_count,
    coalesce(it.items, '[]'::jsonb)  as items,
    coalesce(it.dish_count, 0)       as dish_count,
    it.avg_score
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
        'saved',     (s.user_id is not null)
      ) order by v.entry_position nulls last, v.created_at, v.id) as items,
      count(*)::int as dish_count,
      round(avg(v.score), 2)::numeric(3,2) as avg_score
    from public.reviews v
    join public.dishes d on d.id = v.dish_id
    left join public.saves s on s.dish_id = v.dish_id and s.user_id = (select auth.uid())
    where v.entry_id = e.id
  ) it on true;

comment on view public.entry_cards is
  'The one entry shape for Journal slip / Feed slip / Entry page / Share receipt: entry + author + place + photos[] + items[] + receipt footer (dish_count, avg_score over scored items). Read a single entry with ?id=eq.<uuid>; page lists via get_entry_feed / get_entries_by_author / get_entries_at_place.';

grant select on public.entry_cards to authenticated;

-- ===========================================================================
-- THE THREE PAGED READS. Same cursor contract everywhere:
--   first page → pass NULLs; next page → pass the LAST row's created_at + id.
--   Passing created_at without id degrades to a created_at-only cursor (it uses the
--   zero UUID as the tiebreak) rather than returning nothing.
-- ===========================================================================

-- Global feed: every public entry, newest first. This is get_feed minus the follow
-- join — blocked users are already gone via RLS, so there is no filter here for them.
-- p_include_own defaults FALSE (your own visits live in Journal); pass true for a
-- single global stream.
create or replace function public.get_entry_feed(
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20,
  p_include_own       boolean     default false
)
returns setof public.entry_cards
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select c.*
  from public.entry_cards c
  where c.visibility = 'public'
    and (p_include_own or c.author_id <> (select auth.uid()))
    and (
      p_cursor_created_at is null
      or (c.created_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(p_page_size, 1), 50);
$$;

comment on function public.get_entry_feed(timestamptz, uuid, int, boolean) is
  'Global feed of public entries, keyset (created_at,id) desc. Blocked users excluded by RLS. p_include_own=false by default.';

-- My journal, and any public profile's entries. RLS decides what is visible: your
-- own call returns private entries too, someone else's returns only public ones.
create or replace function public.get_entries_by_author(
  p_author_id         uuid,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20
)
returns setof public.entry_cards
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select c.*
  from public.entry_cards c
  where c.author_id = p_author_id
    and (
      p_cursor_created_at is null
      or (c.created_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(p_page_size, 1), 50);
$$;

-- The place page's two lists: 'mine' = "Your 3 visits", 'others' = everyone else's
-- entries here, 'all' = both.
create or replace function public.get_entries_at_place(
  p_restaurant_id     uuid,
  p_scope             text        default 'all',
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20
)
returns setof public.entry_cards
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select c.*
  from public.entry_cards c
  where c.restaurant_id = p_restaurant_id
    and case p_scope
          when 'mine'   then c.author_id  = (select auth.uid())
          when 'others' then c.author_id <> (select auth.uid())
          else true
        end
    and (
      p_cursor_created_at is null
      or (c.created_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(p_page_size, 1), 50);
$$;

-- ===========================================================================
-- PLACE PAGE — "What to order": dishes ranked by score, with the people count.
-- Unscored dishes sink to the bottom (nulls last) rather than vanishing: a dish
-- someone logged without a number still belongs on the menu.
-- ===========================================================================
create or replace function public.place_dishes(p_restaurant_id uuid, p_limit int default 50)
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
  order by ds.score desc nulls last, ds.people_count desc, d.name
  limit least(greatest(p_limit, 1), 200);
$$;

comment on function public.place_dishes(uuid, int) is
  'Ranked "what to order" for a place: score desc (unscored last), then people_count, then name.';

-- One round trip for the place header: the row, its aggregates, and my history here.
create or replace function public.place_summary(p_restaurant_id uuid)
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
  my_last_visit timestamptz
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    r.id, r.name, r.address, r.city, r.cuisine,
    coalesce(rs.cover_url, r.cover_url),
    rs.avg_rating, coalesce(rs.review_count, 0), coalesce(rs.people_count, 0),
    coalesce(rs.dish_count, 0),
    coalesce(mine.visits, 0), mine.last_visit
  from public.restaurants r
  left join public.restaurant_stats rs on rs.restaurant_id = r.id
  left join lateral (
    select count(*)::int as visits, max(e.created_at) as last_visit
    from public.entries e
    where e.restaurant_id = r.id and e.author_id = (select auth.uid())
  ) mine on true
  where r.id = p_restaurant_id;
$$;

-- ===========================================================================
-- DISH PAGE — the header, then the reviews with MINE FIRST.
-- ===========================================================================
create or replace function public.dish_summary(p_dish_id uuid)
returns table (
  dish_id         uuid,
  dish_name       text,
  restaurant_id   uuid,
  restaurant_name text,
  restaurant_city text,
  score           numeric(2,1),
  review_count    int,
  scored_count    int,
  people_count    int,
  cover_url       text,
  saved           boolean,
  my_last_score   numeric(2,1)
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    d.id, d.name, r.id, r.name, r.city,
    ds.score, coalesce(ds.review_count, 0), coalesce(ds.scored_count, 0), coalesce(ds.people_count, 0),
    ds.cover_url,
    exists (select 1 from public.saves s where s.dish_id = d.id and s.user_id = (select auth.uid())),
    (
      select v.score from public.reviews v
      where v.dish_id = d.id and v.reviewer_id = (select auth.uid()) and v.score is not null
      order by v.created_at desc, v.id desc limit 1
    )
  from public.dishes d
  join public.restaurants r on r.id = d.restaurant_id
  left join public.dish_stats ds on ds.dish_id = d.id
  where d.id = p_dish_id;
$$;

-- Reviews for a dish, the viewer's own first (design/v1/Dish: "You" sits above the
-- others), then newest. The keyset therefore has THREE parts — pass all three
-- values from the last row of the previous page.
create or replace function public.get_dish_reviews(
  p_dish_id           uuid,
  p_cursor_mine       boolean     default null,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20
)
returns table (
  review_id  uuid,
  entry_id   uuid,
  author     jsonb,
  score      numeric(2,1),
  note       text,
  created_at timestamptz,
  is_mine    boolean,
  photos     jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select
    v.id, v.entry_id,
    jsonb_build_object('id', p.id, 'username', p.username, 'name', p.name, 'avatar_url', p.avatar_url),
    v.score, v.note, v.created_at,
    (v.reviewer_id = (select auth.uid())),
    coalesce((
      select jsonb_agg(jsonb_build_object('url', x.photo_url, 'position', x.position) order by x.position)
      from public.entry_photos x where x.entry_id = v.entry_id
    ), '[]'::jsonb)
  from public.reviews v
  join public.profiles p on p.id = v.reviewer_id
  where v.dish_id = p_dish_id
    and (
      p_cursor_created_at is null
      or (
        (case when v.reviewer_id = (select auth.uid()) then 1 else 0 end),
        v.created_at, v.id
      ) < (
        (case when coalesce(p_cursor_mine, false) then 1 else 0 end),
        p_cursor_created_at,
        coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid)
      )
    )
  order by (v.reviewer_id = (select auth.uid())) desc, v.created_at desc, v.id desc
  limit least(greatest(p_page_size, 1), 50);
$$;

comment on function public.get_dish_reviews(uuid, boolean, timestamptz, uuid, int) is
  'Reviews of a dish, the caller''s own first then newest. Keyset is (is_mine, created_at, id) desc — pass all three from the last row.';

revoke all on function public.get_entry_feed(timestamptz, uuid, int, boolean)                from public, anon;
revoke all on function public.get_entries_by_author(uuid, timestamptz, uuid, int)            from public, anon;
revoke all on function public.get_entries_at_place(uuid, text, timestamptz, uuid, int)       from public, anon;
revoke all on function public.place_dishes(uuid, int)                                        from public, anon;
revoke all on function public.place_summary(uuid)                                             from public, anon;
revoke all on function public.dish_summary(uuid)                                              from public, anon;
revoke all on function public.get_dish_reviews(uuid, boolean, timestamptz, uuid, int)         from public, anon;

grant execute on function public.get_entry_feed(timestamptz, uuid, int, boolean)              to authenticated;
grant execute on function public.get_entries_by_author(uuid, timestamptz, uuid, int)          to authenticated;
grant execute on function public.get_entries_at_place(uuid, text, timestamptz, uuid, int)     to authenticated;
grant execute on function public.place_dishes(uuid, int)                                      to authenticated;
grant execute on function public.place_summary(uuid)                                          to authenticated;
grant execute on function public.dish_summary(uuid)                                           to authenticated;
grant execute on function public.get_dish_reviews(uuid, boolean, timestamptz, uuid, int)      to authenticated;
