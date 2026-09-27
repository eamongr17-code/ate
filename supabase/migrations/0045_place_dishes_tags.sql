-- 0045_place_dishes_tags.sql
-- Ate backend — round 4: CHIPS ON "WHAT TO ORDER". `place_dishes` gains `tags text[]`, the dish's
-- aggregate dietary codes — the SAME rule as dish_summary.tags (0036, `dish_consensus_tags`): carried
-- by at least half of the lines review_count counts, and by at least one; canonical order; `{}` when
-- none. (`search_dishes` gets the same column in 0042, which creates it.)
--
-- A new OUT column ⇒ DROP-then-CREATE (landmine 7), the signed-out browse twin with it, both re-granted
-- exactly as 0030/0034 left them (public: authenticated + anon; browse: anon). The body, the ranking
-- (the ported DishRanking rule) and the 4-part keyset are 0034's verbatim; the chips are computed on
-- the page AFTER the limit, so paging is untouched and each returned row pays for its own chips once.
--
-- WIRE IMPACT: ADDITIVE — `tags` appended to place_dishes rows, signed in and signed out.

set search_path = public, extensions;

drop function if exists browse.place_dishes(uuid, int, int, numeric, text, uuid);
drop function if exists public.place_dishes(uuid, int, int, numeric, text, uuid);

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
  cover_url    text,
  -- appended 0045
  tags         text[]
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.place_dishes(p_restaurant_id, p_limit, p_cursor_review_count, p_cursor_score, p_cursor_dish_name, p_cursor_dish_id);
    return;
  end if;

  -- Signed in: 0034's page, then its chips.
  return query
  select pg.dish_id, pg.dish_name, pg.score, pg.people_count, pg.review_count, pg.cover_url,
         public.dish_consensus_tags(pg.dish_id)
  from (
    select ds.dish_id, d.name as dish_name, ds.score, ds.people_count, ds.review_count, ds.cover_url
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
    limit least(greatest(p_limit, 1), 200)
  ) pg
  order by pg.review_count desc, coalesce(pg.score, -1) desc, lower(pg.dish_name), pg.dish_id;
end;
$$;

create function browse.place_dishes(
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
  order by d.review_count desc, coalesce(d.score, -1) desc, lower(d.dish_name), d.dish_id;
$$;

comment on function public.place_dishes(uuid, int, int, numeric, text, uuid) is
  'Ranked "what to order" — the ported DishRanking rule: review_count desc, then score desc (unscored last, never dropped), then name (case-insensitive), then id. Review count leads on purpose: one 5.0 from one person must not lead a menu. Dishes with NO line are excluded; an unscored dish with a line stays. `tags` (0045) = the dish''s chips, the dish_summary.tags rule. Keyset is 4-part — pass p_cursor_review_count / p_cursor_score / p_cursor_dish_name / p_cursor_dish_id from the last row. anon → browse twin.';

revoke all on function public.place_dishes(uuid, int, int, numeric, text, uuid) from public;
grant execute on function public.place_dishes(uuid, int, int, numeric, text, uuid) to authenticated, anon;
revoke all on function browse.place_dishes(uuid, int, int, numeric, text, uuid) from public;
grant execute on function browse.place_dishes(uuid, int, int, numeric, text, uuid) to anon;
