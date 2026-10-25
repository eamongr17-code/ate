-- 0089_new_to_record_score.sql
-- Ate backend — "New in …" rows print the dish's rating, never a "New" pill (Eamon, 25 Oct).
--
--   new_to_record(…) gains a trailing `score` column: the dish's average, dish_stats' own (1 dp over
--   the reviews the viewer can see), so a row reads exactly what the same dish's ranked row reads.
--   NULL when nobody scored it (scores never inferred). Read for at most p_limit (≤ 20) rows.
--
-- LANDMINE 7: the return shape changes, so both functions are DROPPED (browse twin first: it is the
--   dependent) and CREATED, and the grants are restated. 0085's body verbatim but for the new column.
--
-- WIRE IMPACT: ADDITIVE — one new trailing column. The client decodes it if present, so an app on an
--   older server simply prints no average.

set search_path = public, extensions;

drop function if exists browse.new_to_record(text, timestamptz, int, text, text);
drop function if exists public.new_to_record(text, timestamptz, int, text, text);

create function public.new_to_record(p_city text DEFAULT NULL::text, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 6, p_kind text DEFAULT NULL::text, p_slug text DEFAULT NULL::text)
 RETURNS TABLE(dish_id uuid, name text, restaurant_name text, suburb text, kind text, cover_url text, saved boolean, at timestamp with time zone, score numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
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
  select p.dish_id, p.name, rs.name, public.dish_locality(rs.chain_id, rs.address, rs.city), p.kind,
         nullif(btrim(coalesce(public.dish_cover_url(p.dish_id), '')), ''),
         (v_uid is not null and exists (select 1 from public.saves s where s.user_id = v_uid and s.dish_id = p.dish_id)),
         p.at,
         (select ds.score from public.dish_stats ds where ds.dish_id = p.dish_id)
  from page p
  join public.restaurants rs on rs.id = p.restaurant_id
  order by case p.kind when 'six' then 0 when 'five' then 1 else 2 end, p.at desc, p.dish_id;
end;
$function$;

comment on function public.new_to_record(text, timestamptz, int, text, text) is
  'Round 8 (0055), tag 0057, chains 0085, score 0089: what landed after p_since (NULL → 7 days ago; clamped to 90 days back), others'' lines only: a dish scored 6 (kind six), else 5.0 (five), else whose first line is after p_since (new). One row per dish, strongest kind; at = that line''s time; score = the dish''s average (dish_stats), NULL if unscored. Order six, five, new, then at desc. p_limit default 6, max 20. p_kind + p_slug: only dishes carrying that tag; both NULL = no filter. anon → browse twin.';

create function browse.new_to_record(p_city text, p_since timestamptz, p_limit int, p_kind text, p_slug text)
returns table (
  dish_id         uuid,
  name            text,
  restaurant_name text,
  suburb          text,
  kind            text,
  cover_url       text,
  saved           boolean,
  at              timestamptz,
  score           numeric
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select n.dish_id, n.name, n.restaurant_name, n.suburb, n.kind, n.cover_url, false, n.at, n.score
  from public.new_to_record(p_city, p_since, p_limit, p_kind, p_slug) n
  order by case n.kind when 'six' then 0 when 'five' then 1 else 2 end, n.at desc, n.dish_id;
$$;

revoke all on function public.new_to_record(text, timestamptz, int, text, text) from public;
grant execute on function public.new_to_record(text, timestamptz, int, text, text) to authenticated, anon, service_role;
revoke all on function browse.new_to_record(text, timestamptz, int, text, text) from public;
grant execute on function browse.new_to_record(text, timestamptz, int, text, text) to anon;
