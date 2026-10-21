-- 0078_diet_tally_once.sql
-- Ate backend — a dish's diet tally reads each line once, not once per diet code.
--
-- Found by the load test (supabase/tests/load): dish_diet_tally (0074) joined the five diet codes to
-- every line of the dish and expanded each line's tags (diet_tags_implied) once per code. place_dishes
-- calls it twice per dish (consensus tags + counts), so a busy place's dish list made ~10 calls per
-- line: 2.2 s for a place with 15 dishes and 4.7k lines. Now each line's implied tags are computed
-- once (and skipped for the many lines with no tags), then the five codes count over that.
--
-- Same rule, same numbers: people = distinct reviewers whose implied tags hold the code, vetoed = any
-- line's diet_off holds it, over the dish's lines in the label window. Same signature.

create or replace function public.dish_diet_tally(p_dish_id uuid)
returns table (code text, ord integer, people integer, vetoed boolean)
language sql
stable
set search_path = public, extensions
as $$
  select c.code,
         c.ord::int,
         (count(distinct v.reviewer_id) filter (where c.code = any(v.implied)))::int,
         coalesce(bool_or(c.code = any(v.diet_off)), false)
  from unnest(public.dish_tag_codes()) with ordinality as c(code, ord)
  left join (
    select r.reviewer_id,
           case when cardinality(r.tags) = 0 then '{}'::text[] else public.diet_tags_implied(r.tags) end as implied,
           r.diet_off
    from public.reviews r
    where r.dish_id = p_dish_id
      and r.created_at > now() - public.dish_label_window()
  ) v on true
  group by c.code, c.ord;
$$;
