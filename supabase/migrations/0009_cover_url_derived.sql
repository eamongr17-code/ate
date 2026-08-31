-- 0009_cover_url_derived.sql
-- Ate backend — IMG-1 / IMG-BE-1: server-derived dish + restaurant cover photos.
--
-- THE BUG (lead-confirmed on device): dish thumbnails show a camera placeholder
-- everywhere (restaurant detail dish list, Search→Dishes, saved lists, add-dishes
-- builder, profile diary) because `dishes.photo_url` is ALWAYS null — the photos
-- live on `reviews.photo_url`. The client-only FB3-2 fallback (`reviewCoversByDish`)
-- only sees the LOCAL store's reviews (the viewer's own + followed users'), so
-- dishes reviewed by strangers stay blank. The robust fix is server-side and
-- universal: derive the cover from ALL reviews, any user.
--
-- DESIGN — LIVE-DERIVED, NOT a denormalised column (data-model PV5-5 honesty rule):
--   * Dish cover     = the photo_url of that dish's MOST-RECENT review that HAS a
--                      photo (across ALL reviews, any user), else NULL.
--   * Restaurant cover = the photo_url of the MOST-RECENT review with a photo at that
--                      restaurant (any dish, any user), else NULL.
-- We compute these on read via a correlated LATERAL subquery inside the existing
-- stat views the client already consumes — so the value can NEVER go stale: it
-- updates the instant a new photo'd review lands or a photo is removed. No
-- ADD COLUMN, no trigger to keep fresh, no stale-counter class of bug.
--
-- "most-recent review that HAS a photo" (not simply the most-recent review) mirrors
-- the client's existing FB3-2 semantics (reviewCoversByDish picks the newest review
-- WITH a photo) — so an old photo'd review still covers a dish whose newest review
-- happens to be text-only.
--
-- CONTRACT (additive, non-breaking): `cover_url` is a NEW column appended to two
-- existing read views. Existing columns are untouched; the existing client (which
-- selects '*' and ignores the new field) keeps working unchanged. The physical
-- columns `dishes.photo_url` and `restaurants.cover_url` are left intact.
--   * dish_stats        gains  cover_url  (client already reads dish_stats via
--                                          getDishStats(), merged by dish_id)
--   * restaurant_stats  gains  cover_url  (client already reads restaurant_stats via
--                                          getRestaurantStats(), merged by restaurant_id)
--
-- FE (sequenced AFTER this, separate ship): surface `dish.cover_url` from the
-- dish-stats row and `restaurant.cover_url` from the restaurant-stats row, ahead of
-- the local FB3-2 fallback, as the universal thumbnail/hero source.

set search_path = public, extensions;

-- ===========================================================================
-- dish_stats: + cover_url (live-derived most-recent photo'd review per dish)
-- Recreated with the SAME existing columns (dish_id, restaurant_id, score,
-- review_count) plus cover_url appended LAST so column order is additive.
-- LATERAL picks the newest review WITH a photo for the dish; NULL when none.
-- ===========================================================================
create or replace view public.dish_stats
with (security_invoker = true) as
  select
    d.id              as dish_id,
    d.restaurant_id,
    round(avg(r.score), 1)::numeric(2,1) as score,   -- NULL when no reviews
    count(r.id)::int  as review_count,
    cov.cover_url
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
  'Per-dish derived avg score (NULL = unrated) + review count + cover_url '
  '(IMG-1: live-derived photo_url of the most-recent photo''d review for the dish, '
  'any user; NULL when none). Live dishes only.';

-- ===========================================================================
-- restaurant_stats: + cover_url (live-derived most-recent photo'd review at the
-- restaurant). Same existing columns (restaurant_id, avg_rating, review_count)
-- plus cover_url appended LAST. Reviews carry a denormalised restaurant_id
-- (kept authoritative by trg_review_set_restaurant), so the LATERAL is a direct
-- restaurant_id scan — no dish join needed.
-- ===========================================================================
create or replace view public.restaurant_stats
with (security_invoker = true) as
  select
    rst.id as restaurant_id,
    round(avg(ds.score) filter (where ds.score is not null), 1)::numeric(2,1) as avg_rating,
    coalesce(sum(ds.review_count), 0)::int as review_count,
    cov.cover_url
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
  group by rst.id, cov.cover_url;

comment on view public.restaurant_stats is
  'Restaurant rating = MEAN OF PER-DISH AVERAGES (data-model §1.2) + cover_url '
  '(IMG-1: live-derived photo_url of the most-recent photo''d review at the '
  'restaurant, any dish/user; NULL when none). Diverges from current client selector.';

-- Re-grant (create or replace preserves grants, but be explicit/idempotent).
grant select on public.dish_stats       to authenticated, anon;
grant select on public.restaurant_stats to authenticated, anon;
