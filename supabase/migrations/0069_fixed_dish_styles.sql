-- 0069_fixed_dish_styles.sql
-- Ate backend — style tags come ONLY from the fixed list of 40 (Eamon, 18 Oct). Until now the model
-- proposed free-form style words ("comfort food", "peppery", "spicy"), and each one became a tag chip
-- and a tag page title. The list is the one dish_style_guess's keyword map (0053) already uses:
--
--   pizza · pasta · noodles · dumplings · dim sum · sushi · burgers · sandwiches · tacos · wraps ·
--   curry · stew · soup · salad · rice · dessert · pastry · bread · breakfast · bbq · grilled · roast ·
--   fried · raw · dips · cheese · charcuterie · fries · potatoes · coffee · drinks · seafood · steak ·
--   beef · chicken · pork · lamb · duck · tofu · vegetables
--
-- Identical, same order, to DISH_STYLES in functions/sort-entry/styles.ts (the first gate; the model
-- is given the list as a tool-schema enum). tests/db/dish_tag_links_test.mjs pins TS = SQL = the map.
--
--   dish_style_list()        NEW. The list, as text[]. Immutable; same grants as its 0053 siblings.
--   dish_style_clean(text)   create or replace, same signature: a word is a style only if it is ON
--                            THE LIST (accent-folded, lower-cased, a hyphen read as a space, so
--                            "Dim-Sum" → "dim sum"). Was: any 1–4 a–z words. It gates both
--                            dish_styles_from_json and dish_apply_sorter_styles.
--   dish_styles_from_json    create or replace, same signature and body: drops anything off the list
--                            (through dish_style_clean). Never raises, as before.
--
-- DATA (DESTRUCTIVE on derived rows + one user table — needs the CEO's sign-off before the prod job):
--   1. dish_tag_links, kind 'style', slug on the list: label set to the list's word (a sorter's
--      "dim-sum" prints "dim sum"), so tag_label() reads one label per style.
--   2. dish_tag_links, kind 'style', slug NOT on the list: deleted (sorter-written free-form words;
--      keyword rows are always on the list). Catalogue data, re-derivable; no review is touched.
--   3. Every dish left with no style tag gets the keyword guess, exactly as a new dish does
--      (dish_style_keyword_refresh — it only writes where no sorter style remains).
--   4. Style ord renumbered 1..n per dish (deletions left gaps; dish_apply_sorter_styles appends at n+1).
--   5. user_cravings, kind 'style', slug NOT on the list: deleted. Such a tag no longer exists, so
--      its Feed shelf would be empty forever. Other kinds (cuisine/suburb/city/diet) are untouched.
--   Idempotent: a re-run finds nothing to change.
--
-- WIRE IMPACT: no shape changes. Behaviour: sort-entry items[].styles only ever carry list words;
-- dish_tags / similar_dishes / dishes_by_tag stop returning removed style slugs (dishes_by_tag on one
-- returns [], as for any unknown tag); my_cravings loses removed style rows. ADDITIVE-SAFE for the
-- shipped client (it already handles an empty tag page and an absent chip).

set search_path = public, extensions;

-- ===========================================================================
-- 1. The list, and the gates.
-- ===========================================================================
create or replace function public.dish_style_list()
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select array[
    'pizza', 'pasta', 'noodles', 'dumplings', 'dim sum', 'sushi', 'burgers', 'sandwiches', 'tacos', 'wraps',
    'curry', 'stew', 'soup', 'salad', 'rice', 'dessert', 'pastry', 'bread', 'breakfast', 'bbq',
    'grilled', 'roast', 'fried', 'raw', 'dips', 'cheese', 'charcuterie', 'fries', 'potatoes', 'coffee',
    'drinks', 'seafood', 'steak', 'beef', 'chicken', 'pork', 'lamb', 'duck', 'tofu', 'vegetables'
  ]::text[];
$$;

comment on function public.dish_style_list() is
  '0069: the 40 style tags, in dish_style_guess''s order — the ONLY styles a dish may carry. Identical to DISH_STYLES in functions/sort-entry/styles.ts.';

-- One style word → its entry on the list, or NULL when it is not on the list.
create or replace function public.dish_style_clean(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select case when x.s = any (public.dish_style_list()) then x.s end
  from (select btrim(regexp_replace(replace(public.search_key(p_text), '-', ' '), '\s+', ' ', 'g')) as s) x;
$$;

comment on function public.dish_style_clean(text) is
  '0069: one proposed style → its word on dish_style_list() (accent-folded, lower-cased, whitespace collapsed, "-" read as a space), else NULL. Mirrors cleanStyle in functions/sort-entry/styles.ts.';

-- Same body as 0053; the list rides dish_style_clean.
create or replace function public.dish_styles_from_json(p_styles jsonb)
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select coalesce(array_agg(z.s order by z.o), '{}'::text[])
  from (
    select y.s, min(y.o) as o
    from (
      select public.dish_style_clean(a.x) as s, a.o
      from jsonb_array_elements_text(case when jsonb_typeof(p_styles) = 'array' then p_styles else '[]'::jsonb end)
           with ordinality as a(x, o)
      where a.o <= 12
    ) y
    where y.s is not null
    group by y.s
    order by min(y.o)
    limit 3
  ) z;
$$;

comment on function public.dish_styles_from_json(jsonb) is
  '0069 (was 0053): sort-entry items[].styles → ≤3 distinct styles from dish_style_list() (dish_style_clean), first mention first. Anything off the list is dropped, never raised: a bad payload cannot abort a sort.';

revoke all on function public.dish_style_list() from public, anon;
grant execute on function public.dish_style_list() to authenticated, service_role;

-- ===========================================================================
-- 2. Data — style tags and followed styles off the list.
-- ===========================================================================
-- 1. One label per listed style: the list's word.
update public.dish_tag_links t
set label = l.style
from unnest(public.dish_style_list()) as l(style)
where t.kind = 'style'
  and t.slug = public.tag_slug(l.style)
  and t.label is distinct from l.style;

-- 2. Off-list styles go.
delete from public.dish_tag_links t
where t.kind = 'style'
  and not (t.slug = any (array(select public.tag_slug(l) from unnest(public.dish_style_list()) l)));

-- 3. A dish with no style left gets the keyword guess, as a new dish does.
select public.dish_style_keyword_refresh(array(
  select d.id from public.dishes d
  where not exists (select 1 from public.dish_tag_links s where s.dish_id = d.id and s.kind = 'style')));

-- 4. Close the ord gaps the deletions left.
update public.dish_tag_links t
set ord = r.n
from (
  select dish_id, slug, (row_number() over (partition by dish_id order by ord, created_at, slug))::smallint as n
  from public.dish_tag_links
  where kind = 'style'
) r
where t.kind = 'style' and t.dish_id = r.dish_id and t.slug = r.slug and t.ord is distinct from r.n;

-- 5. Followed styles that no longer exist.
delete from public.user_cravings c
where c.kind = 'style'
  and not (c.slug = any (array(select public.tag_slug(l) from unnest(public.dish_style_list()) l)));
