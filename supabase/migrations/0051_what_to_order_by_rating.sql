-- 0051_what_to_order_by_rating.sql
-- Ate backend — round 6: "WHAT TO ORDER" RANKS BY RATING (Eamon, build 81). The Place page's menu is
-- `place_dishes`, ordered on the SERVER (the client shows it as sent; PlacePageStore never re-sorts).
-- Since 0030 it led with review_count (the ported DishRanking rule: "one 5.0 from one person must not
-- lead a menu"). Eamon's call reverses that: the list reads top-down by the number it prints.
--
-- THE ORDER, total and deterministic:
--   1. score desc — the PRINTED score (numeric(2,1), one decimal, what the row shows), so two rows that
--      read "4.6" are a tie, never ordered by a hidden third decimal. A 6 (0041) sorts above every 5.
--   2. review_count desc — the tiebreak: of two 4.6s, the one ordered more times is the surer bet.
--   3. name (case-insensitive), 4. dish_id — so nothing shuffles between refreshes.
--   UNSCORED dishes (logged, never given a number) come after every scored dish, and among themselves
--   by review_count desc, then name, then id. A dish with no line at all is still not a menu item.
--   Consequence, accepted: a single 5.0 now leads a menu of many 4.5s.
--
-- The keyset keeps its four parameters (score, review_count, name, id — the same fields, now in this
-- order), so a shipped client's cursor stays correct: it passes the last row's four values and the
-- server compares them in the new order. Same signature ⇒ create or replace, grants survive; the
-- browse twin restates the order, so it is replaced too.
--
-- WIRE IMPACT: BEHAVIOURAL, NO SHAPE CHANGE. Same params, same OUT columns, different row order.
-- Client note: AteKit's DishRanking (the old client-side comparator, review-count-first) no longer
-- matches the server; any surface still using it should switch to the server order.

set search_path = public, extensions;

create or replace function public.place_dishes(
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
  cover_url    text,
  tags         text[]
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  if current_user = 'anon' then
    return query select * from browse.place_dishes(p_restaurant_id, p_limit, p_cursor_review_count, p_cursor_score, p_cursor_dish_name, p_cursor_dish_id);
    return;
  end if;

  return query
  select pg.dish_id, pg.dish_name, pg.score, pg.people_count, pg.review_count, pg.cover_url,
         public.dish_consensus_tags(pg.dish_id)
  from (
    select ds.dish_id, d.name as dish_name, ds.score, ds.people_count, ds.review_count, ds.cover_url
    from public.dish_stats ds
    join public.dishes d on d.id = ds.dish_id
    where ds.restaurant_id = p_restaurant_id
      and ds.review_count > 0
      and (
        p_cursor_dish_id is null
        or coalesce(ds.score, -1) < coalesce(p_cursor_score, -1)
        or (coalesce(ds.score, -1) = coalesce(p_cursor_score, -1)
            and ds.review_count < p_cursor_review_count)
        or (coalesce(ds.score, -1) = coalesce(p_cursor_score, -1)
            and ds.review_count = p_cursor_review_count
            and (lower(d.name), ds.dish_id) > (lower(coalesce(p_cursor_dish_name, '')), p_cursor_dish_id))
      )
    order by coalesce(ds.score, -1) desc, ds.review_count desc, lower(d.name), ds.dish_id
    limit least(greatest(p_limit, 1), 200)
  ) pg
  order by coalesce(pg.score, -1) desc, pg.review_count desc, lower(pg.dish_name), pg.dish_id;
end;
$$;

create or replace function browse.place_dishes(
  p_restaurant_id      uuid,
  p_limit              int,
  p_cursor_review_count int,
  p_cursor_score       numeric,
  p_cursor_dish_name   text,
  p_cursor_dish_id     uuid
)
returns table (
  dish_id      uuid,
  dish_name    text,
  score        numeric(2,1),
  people_count int,
  review_count int,
  cover_url    text,
  tags         text[]
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select d.*
  from public.place_dishes(p_restaurant_id, p_limit, p_cursor_review_count, p_cursor_score,
                           p_cursor_dish_name, p_cursor_dish_id) d
  order by coalesce(d.score, -1) desc, d.review_count desc, lower(d.dish_name), d.dish_id;
$$;

comment on function public.place_dishes(uuid, int, int, numeric, text, uuid) is
  '"What to order" (0051): by the printed score desc (a 6 above every 5), tiebreak review_count desc, then name (case-insensitive), then id. Unscored dishes after every scored one (review_count desc, name, id); a dish with NO line is excluded. `tags` = the dish''s chips. Keyset is 4-part — pass p_cursor_score / p_cursor_review_count / p_cursor_dish_name / p_cursor_dish_id from the last row. anon → browse twin.';
