-- 0030_place_dishes_order.sql
-- Ate backend — "What to order" is ranked by the PRODUCT's rule, which is the one already
-- ported and tested in Swift (`AteKit/Sources/AteKit/Detail/DishRanking.swift`):
--
--     review_count DESC → score DESC (NULL last) → name (case-insensitive) → id
--
-- 0022 sorted score-first, and score-first is wrong on this screen. A 4.4 from three
-- people outranked a 4.2 from four, and a single 5.0 from one person would LEAD the menu —
-- the iOS lane hit both. "What should I order here?" is answered by what people actually
-- order and come back to; the score breaks the tie, it does not set the order. This is not
-- a new rule being invented here: it is the legacy repo's ranking, with its test cases, and
-- this migration makes the server agree with it so the list cannot differ by surface.
--
-- TWO MORE RULES IN THE SAME FUNCTION:
--
--  1. A DISH THAT HAS NEVER BEEN LOGGED IS NOT A MENU ITEM. `review_count = 0` is an
--     abandoned "add as a new dish" shell — someone opened the sheet, named a dish, and
--     never printed a line. It has no score, no photo and no reviewer, and it has been
--     padding the bottom of every place page. Gone from this read.
--     **An UNSCORED dish with a review row STAYS** — a dish someone logged without giving
--     it a number is exactly what DESIGN rule 7 protects, and it belongs on the menu.
--     Note this is viewer-relative like everything else: a dish whose only line lives in
--     someone else's PRIVATE entry reads `review_count = 0` for you, so it is not yours to
--     see here either. Same privacy rule as every aggregate (0022).
--
--  2. THE KEYSET FOLLOWS THE ORDER. Four parts now — `(review_count, score, name, id)` —
--     compared branch by branch, because a single row comparison cannot mix two DESC keys
--     with two ASC ones. Same contract as everywhere else: first page → pass nulls; next
--     page → pass all four values from the LAST row (`score` may be null).
--
-- COLLATION, said out loud: the name tiebreak is `lower(d.name)`, which is the
-- case-insensitive half of Swift's `localizedCaseInsensitiveCompare`. Two names that differ
-- only in case therefore tie here exactly as they tie there, and the `id` tiebreak decides —
-- and Postgres' uuid order is byte order, which is the same order as Swift's uppercase
-- `uuidString` comparison (hex digits sort as their nibble values). Accents are left to the
-- database's collation; the contract test asserts the server's order IS
-- `DishRanking.rank(...)` over the same rows, so any disagreement surfaces there rather
-- than as a list that reads differently on the two sides.
--
-- WIRE IMPACT
--   BEHAVIOURAL (same columns, different rows and different order — the point of the
--     migration): the menu is review-count-led, and never-logged dishes are gone. Any client
--     that re-sorted `place_dishes` client-side must stop: the server's order is the rule.
--   BREAKING, but on a parameter no caller has ever sent: `p_cursor_people` (0029, applied
--     to staging today, never to prod, not called by the app — `PlaceDirectoryClient` sends
--     only `p_restaurant_id` + `p_limit`) is replaced by `p_cursor_review_count`. Flagged to
--     the iOS lane through the lead; the first-page call is untouched.
--   NOT CHANGED: the returned columns (`dish_id, dish_name, score, people_count,
--     review_count, cover_url`), the 200-row clamp, SECURITY INVOKER, the grants.
--
-- LANDMINE 7: the parameter list changes, so this is DROP-then-CREATE (never
-- `create or replace`, which would leave two overloads and make every named-argument call
-- `42725`), and the grants are restated because a drop takes them with it.

set search_path = public, extensions;

do $$
declare
  sigs text[];
  sig  text;
begin
  select array_agg(p.oid::regprocedure::text)
    into sigs
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = 'place_dishes';

  foreach sig in array coalesce(sigs, array[]::text[])
  loop
    execute format('drop function if exists %s', sig);
  end loop;
end $$;

create function public.place_dishes(
  p_restaurant_id      uuid,
  p_limit              int     default 50,
  p_cursor_review_count int    default null,
  p_cursor_score       numeric default null,
  p_cursor_dish_name   text    default null,
  p_cursor_dish_id     uuid    default null
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
    -- never logged = not a menu item (an unscored dish WITH a line stays)
    and ds.review_count > 0
    and (
      p_cursor_dish_id is null
      or ds.review_count < p_cursor_review_count
      or (ds.review_count = p_cursor_review_count
          and coalesce(ds.score, -1) < coalesce(p_cursor_score, -1))
      or (ds.review_count = p_cursor_review_count
          and coalesce(ds.score, -1) = coalesce(p_cursor_score, -1)
          and (lower(d.name), ds.dish_id) > (lower(coalesce(p_cursor_dish_name, '')), p_cursor_dish_id))
    )
  order by ds.review_count desc, coalesce(ds.score, -1) desc, lower(d.name), ds.dish_id
  limit least(greatest(p_limit, 1), 200);
$$;

comment on function public.place_dishes(uuid, int, int, numeric, text, uuid) is
  'Ranked "what to order" — the ported DishRanking rule: review_count desc, then score desc (unscored last, never dropped), then name (case-insensitive), then id. Review count leads on purpose: one 5.0 from one person must not lead a menu. Dishes with NO line are excluded (abandoned "add a new dish" shells); an unscored dish with a line stays. Keyset is 4-part — pass p_cursor_review_count / p_cursor_score / p_cursor_dish_name / p_cursor_dish_id from the last row.';

revoke all on function public.place_dishes(uuid, int, int, numeric, text, uuid) from public, anon;
grant execute on function public.place_dishes(uuid, int, int, numeric, text, uuid) to authenticated;
