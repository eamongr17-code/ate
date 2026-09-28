-- 0053_journal_days_and_dish_tags.sql
-- Ate backend — round 7, the Journal deep dive: a calendar of days, a live "Show N entries" count, and
-- DISH TAGS — chips on a dish that open "more like this" and a tag's own results page.
--
-- ─── Reads (all signed-in only, all new: ADDITIVE) ────────────────────────────────────────────────
--   journal_days(p_from, p_to, p_tz, …my_entries' filters)  → (day, entries, best_score, cover_url)
--       One row per local day in [p_from, p_to] that holds one of MY entries. best_score = the best
--       line score that day (a 6 is 6), NULL when none scored; cover_url = the newest entry that day
--       with a photo (its first entry_photo, else a line's photo). Optional trailing filters are
--       my_entries' own (p_min_score, p_max_score, p_city, p_restaurant_id, p_tag), so a filtered
--       Journal's calendar and month dividers count what the list shows. MONTH DIVIDER COUNTS: sum a
--       month's journal_days rows (same filters) — the whole month, not just the loaded pages.
--   my_entries_count(…my_entries' filters)  → int. Exactly how many rows my_entries would page out.
--   dish_tags(p_dish_id) → (kind, slug, label): style → cuisine → suburb → city → diet.
--   similar_dishes(p_dish_id, p_limit) → (dish_id, name, restaurant_id, restaurant_name, score,
--       review_count, cover_url): weighted tag overlap (style 8 · cuisine 4 · suburb 2 · city 1 — each
--       tier outweighs everything below it), then score, then review_count. It must share a STYLE or
--       the CUISINE ("same city" alone is not similar). Excludes the dish itself and unlogged dishes.
--   dishes_by_tag(p_kind, p_slug, p_limit, 4-part cursor) → the same row shape, best first:
--       place_dishes' order and keyset (0051) — score desc (a 6 above every 5, unscored last),
--       review_count desc, lower(name), dish_id.
--
-- ─── Storage: public.dish_tag_links (dish_id, kind, slug, label, source, ord) ────────────────────
--   PK (dish_id, kind, slug) — TOTAL, so it is a legal ON CONFLICT arbiter (landmine 1). Catalogue
--   data, the same for every viewer; nothing viewer-relative is stored.
--   kind cuisine · suburb · city  source 'place' — derived from the dish's restaurant, kept exact by
--       triggers: a new/renamed dish, a restaurant's cuisine change, and every place_city_cache
--       change (0052 — a place's locality and city), plus a change to `cities` (labels).
--       suburb = place_locality() (the chip we print), slug qualified by city ("richmond-melbourne")
--       because suburb names repeat across cities; omitted when it IS the city (Melbourne CBD).
--       city   = place_city_cache.city (0046's rule), label = cities.name.
--   kind style  1–3 lowercase words for what KIND of dish it is ("pasta", "dumplings", "dessert").
--       source 'keyword' — dish_style_guess(name): a fixed, deterministic keyword map. Every dish gets
--         these on insert (so the stub sorter needs no model), and the backfill below uses it.
--       source 'sorter'  — the model's styles (sort-entry items[].styles), written by apply_entry_sort
--         (and correct_entry_place when it prints a parked plan). A dish's first sorter styles REPLACE
--         its keyword guesses; later sorts add to them up to 3 in all, never remove one.
--   kind diet  NOT stored: dish_tags reads dish_consensus_tags() live (0036's rule, viewer-relative),
--       so the chip strip and dish_summary.tags can never disagree. dishes_by_tag('diet', code) filters
--       on the same live rule.
--   A merged dish (tombstone) keeps its rows but no read returns it.
--
-- ─── Write path ───────────────────────────────────────────────────────────────────────────────────
--   apply_entry_sort: 0044's body verbatim + items[].styles (validated by dish_styles_from_json:
--   lower-cased, accent-folded, a–z words, 3–24 chars, not a diet word, ≤3) applied to each NEW line's
--   dish, and kept in the parked plan. correct_entry_place: 0036's body verbatim + the parked plan's
--   styles. Same signatures ⇒ create or replace, grants survive. A corrected line's dish is the
--   user's: the sorter's styles are not applied to it.
--
-- DATA: dish_tag_links is filled for every existing dish here (derived catalogue rows; nothing that
-- exists is modified or deleted). WIRE IMPACT: ADDITIVE — five new RPCs; sort-entry items may carry
-- `styles` (sort + preview responses; absent when none). Nothing existing changes shape or behaviour.

set search_path = public, extensions;

-- ===========================================================================
-- 1. Helpers — slugs, style words, the keyword map.
-- ===========================================================================
create or replace function public.tag_slug(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select nullif(btrim(left(regexp_replace(public.search_key(p_text), '[^a-z0-9]+', '-', 'g'), 48), '-'), '');
$$;

comment on function public.tag_slug(text) is
  'Round 7 (0053): a tag''s URL-safe key — accent-folded, lower-case, runs of anything else → "-", ≤48 chars. NULL for nothing.';

-- One style word, cleaned — or NULL when it is not an acceptable style tag.
create or replace function public.dish_style_clean(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select case
           when s ~ '^[a-z]+([ -][a-z]+){0,3}$'
            and char_length(s) between 3 and 24
            and not (s = any (array['vegan', 'vegetarian', 'veggo', 'plant based', 'plant-based',
                                    'gluten free', 'gluten-free', 'dairy free', 'dairy-free', 'nut free', 'nut-free',
                                    'food', 'dish', 'dishes', 'meal', 'other', 'misc', 'good', 'great', 'delicious']))
           then s
         end
  from (select regexp_replace(public.search_key(p_text), '\s+', ' ', 'g') as s) x;
$$;

-- A sorter payload's styles → at most 3 clean, distinct words, first mention first. Never raises.
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
  'Round 7 (0053): sort-entry items[].styles → ≤3 distinct style words (dish_style_clean: accent-folded lower-case a–z words, 3–24 chars, no diet words). Garbage is dropped, never raised: a bad payload cannot abort a sort.';

-- THE KEYWORD MAP — a dish name → up to 3 styles, deterministic, no model. Dish TYPES outrank cooking
-- methods, which outrank proteins, so the 3-cap keeps the most telling words ("Tonkotsu ramen" →
-- noodles, soup, pork). Matched on search_key(name): "Crème brûlée" reads "creme brulee".
create or replace function public.dish_style_guess(p_name text)
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select coalesce(array_agg(k.style order by k.ord), '{}'::text[])
  from (
    select m.style, m.ord
    from (values
      ( 1, 'pizza',       '\m(pizzas?|margherita|pepperoni|calzones?)\M'),
      ( 2, 'pasta',       '\m(pastas?|spaghetti|linguine|rigatoni|penne|tagliatelle|pappardelle|fettuccine|bucatini|orecchiette|paccheri|mafaldine|agnolotti|ravioli|tortellini|tortelloni|lasagnes?|lasagna|gnocchi|carbonara|cacio e pepe|amatriciana|mac (and|n) cheese|macaroni|orzo|cavatelli|trofie|strozzapreti|pici|casarecce|conchiglie|farfalle|fusilli|ziti|vermicelloni)\M'),
      ( 3, 'noodles',     '\m(noodles?|ramen|udon|soba|pho|laksa|pad thai|pad see ew|kway teow|chow mein|lo mein|japchae|hor fun|vermicelli|bun cha|bun bo|mee goreng|mi goreng|dan dan|biang biang|yakisoba|naengmyeon|jjajangmyeon)\M'),
      ( 4, 'dumplings',   '\m(dumplings?|xiao long bao|xlb|gyozas?|har gow|siu mai|shumai|wontons?|momos?|jiaozi|baos?|pierogi|mandu|potstickers?)\M'),
      ( 5, 'dim sum',     '\m(dim sum|yum cha|har gow|siu mai|shumai|char siu bao|cheung fun|egg tarts?|turnip cake|xiao long bao)\M'),
      ( 6, 'sushi',       '\m(sushi|sashimi|nigiri|maki|temaki|hand rolls?|chirashi|tuna rolls?|salmon rolls?|california rolls?|uramaki|onigiri)\M'),
      ( 7, 'burgers',     '\m(burgers?|cheeseburgers?|smash|sliders?)\M'),
      ( 8, 'sandwiches',  '\m(sandwich(es)?|sandos?|banh mi|toasties?|panini|croque monsieur|croque madame|hoagies?|reubens?|lobster rolls?|po boys?)\M'),
      ( 9, 'tacos',       '\m(tacos?|birria|al pastor|tostadas?|carnitas)\M'),
      (10, 'wraps',       '\m(wraps?|burritos?|quesadillas?|shawarma|souvlaki|gyros?|kebabs?|doner|kottu|enchiladas?)\M'),
      (11, 'curry',       '\m(curry|curries|masala|korma|vindaloo|rendang|rogan josh|massaman|butter chicken|dal|dhal|daal|makhani|jalfrezi|saag|palak|madras|panang)\M'),
      (12, 'stew',        '\m(stews?|wat|tagine|goulash|bourguignon|cassoulet|casserole|chilli con carne|hotpot|hot pot|braised?|osso buco|jjigae)\M'),
      (13, 'soup',        '\m(soups?|broth|pho|laksa|ramen|chowder|bisque|minestrone|tom yum|tom kha|gazpacho|congee|jook|jjigae)\M'),
      (14, 'salad',       '\m(salads?|slaw|coleslaw|som tum|fattoush|tabbouleh|caesar|nicoise|panzanella|larb)\M'),
      (15, 'rice',        '\m(rice(?! paper)|tteokbokki|risotto|biryani|paella|bibimbap|donburi|don|nasi lemak|nasi goreng|congee|jook|arroz|pilaf|pilau|onigiri)\M'),
      (16, 'dessert',     '\m(desserts?|tiramisu|gelato|ice creams?|soft serve|sorbet|(?<!(crab|fish|rice|turnip|potato|corn) )cakes?|cheesecakes?|tarts?|tarte tatin|puddings?|brulee|panna cotta|pavlova|mousse|sundaes?|affogato|churros|cannoli|donuts?|doughnuts?|brownies?|crumble|loukoumades|knafeh|kunafa|baklava|mochi|sticky rice|thickshakes?|milkshakes?|eclairs?|macarons?|profiteroles|trifle|souffle|sticky date|bingsu|cendol|gulab jamun|kulfi|creme caramel|flan)\M'),
      (17, 'pastry',      '\m(croissants?|pastry|pastries|danish|scrolls?|cruffins?|pain au chocolat|pain au raisin|kouign[- ]amann|sausage rolls?|pies?|spanakopita|boreks?|bureks?|strudel|egg tarts?|samosas?|empanadas?|curry puffs?|palmiers?|cannoli)\M'),
      (18, 'bread',       '\m(breads?|sourdough|focaccia|naan|roti|flatbreads?|pita|pitta|toast|injera|garlic knots|bagels?|baguette|brioche|hoppers?|dosa|paratha|bruschetta|crostini)\M'),
      (19, 'breakfast',   '\m(breakfast|brunch|eggs?(?! tarts?)|benedict|hotcakes?|(?<!(duck|kimchi|onion|scallion|seafood) )pancakes?|waffles?|french toast|omelettes?|omelets?|granola|bircher|porridge|oats|acai|smashed avo|avo toast|avocado toast|scrambled|shakshuka|crepes?|hash browns?)\M'),
      (20, 'bbq',         '\m(bbq|barbecue|barbeque|brisket|ribs|smoked|pulled pork|burnt ends|galbi|kalbi|bulgogi|char siu|yakiniku)\M'),
      (21, 'grilled',     '\m(grilled|grill|chargrilled|charcoal|souvlaki|shish|skewers?|kebabs?|yakitori|satay|tibs|crying tiger|churrasco|asado|tandoori|tikka)\M'),
      (22, 'roast',       '\m(roast|roasted|rotisserie|confit|porchetta|pork belly|crispy pork|peking duck|suckling)\M'),
      (23, 'fried',       '\m(fried|karaage|tempura|katsu|schnitzel|croquetas?|croquettes?|arancini|fritters?|falafel|pakoras?|bhajis?|spring rolls?|calamari|fish and chips|onion rings|churros|agedashi|salt and pepper|wings)\M'),
      (24, 'raw',         '\m(tartare|crudo|carpaccio|ceviche|poke|sashimi|tataki|oysters?|yukhoe)\M'),
      (25, 'dips',        '\m(dips?|hummus|houmous|baba ghanoush|baba ganoush|guacamole|tzatziki|taramasalata|labneh|muhammara|sambol|sambal|salsa)\M'),
      (26, 'cheese',      '\m(cheese|cheeses|burrata|saganaki|stracciatella|halloumi|mozzarella|fondue|raclette|paneer|ricotta|feta|parmigiana|parmesan)\M'),
      (27, 'charcuterie', '\m(charcuterie|jamon|prosciutto|salumi|salami|cured meats?|pate|parfait|terrine|rillettes|mortadella|bresaola)\M'),
      (28, 'fries',       '\m(fries|chips|frites|wedges|patatas bravas|poutine)\M'),
      (29, 'potatoes',    '\m(potato|potatoes|patatas|gratin|dauphinoise|hash browns?|rosti|mash|mashed)\M'),
      (30, 'coffee',      '\m(coffee|latte|flat white|espresso|cappuccino|long black|short black|piccolo|cortado|macchiato|mocha|cold brew|batch brew|affogato)\M'),
      (31, 'drinks',      '\m((?<!prawn )cocktails?|negroni|spritz|martini|margarita|mojito|daiquiri|old fashioned|wine|beer|sake|soju|smoothies?|juice|kombucha|lemonade|soda|tea|chai|bubble tea|boba|lassi|hot chocolate|thickshakes?|milkshakes?)\M'),
      (32, 'seafood',     '\m(seafood|prawns?|shrimps?|oysters?|scallops?|squid|calamari|octopus|crab|lobster|mussels?|clams?|vongole|fish|salmon|tuna|kingfish|barramundi|snapper|anchovy|anchovies|gambas|sardines?|mackerel|cod|eel|unagi|uni|scampi|ceviche|nigiri|sashimi|crudo)\M'),
      (33, 'steak',       '\m(steaks?|ribeye|rib eye|scotch fillet|sirloin|t-bone|t bone|porterhouse|tomahawk|flank|rump|eye fillet|bistecca)\M'),
      (34, 'beef',        '\m(beef|wagyu|bulgogi|galbi|kalbi|brisket|rendang|tibs|birria|oxtail|short ribs?|bolognese|meatballs?|bo)\M'),
      (35, 'chicken',     '\m(chicken|karaage|wings|poulet|pollo|doro|yakitori|chook|parmi|parma)\M'),
      (36, 'pork',        '\m(pork|char siu|jamon|ham|bacon|prosciutto|pancetta|guanciale|carbonara|chorizo|sausages?|soppressata|nduja|porchetta|carnitas|al pastor|tonkotsu|tonkatsu|lechon|salami|mortadella|pepperoni|bun cha)\M'),
      (37, 'lamb',        '\m(lamb|mutton|goat|rogan josh)\M'),
      (38, 'duck',        '\m(duck|peking)\M'),
      (39, 'tofu',        '\m(tofu|tempeh|seitan|mapo)\M'),
      (40, 'vegetables',  '\m(eggplant|aubergine|gai lan|broccolini|broccoli|cauliflower|mushrooms?|funghi|greens|brussels sprouts|carrots?|beetroot|pumpkin|zucchini|kale|cabbage|kimchi|elote|corn|asparagus|tomatoes|veggie|vegetables?|veg)\M')
    ) as m(ord, style, pattern)
    where public.search_key(p_name) ~ m.pattern
    order by m.ord
    limit 3
  ) k;
$$;

comment on function public.dish_style_guess(text) is
  'Round 7 (0053): the deterministic keyword map — a dish name → up to 3 style words (dish types first, then cooking, then protein). The stub path''s styles and the backfill''s. Changing the map is a migration that re-runs dish_style_keyword_refresh().';

revoke all on function public.tag_slug(text)               from public, anon;
revoke all on function public.dish_style_clean(text)       from public, anon;
revoke all on function public.dish_styles_from_json(jsonb) from public, anon;
revoke all on function public.dish_style_guess(text)       from public, anon;
grant execute on function public.tag_slug(text)               to authenticated, service_role;
grant execute on function public.dish_style_clean(text)       to authenticated, service_role;
grant execute on function public.dish_styles_from_json(jsonb) to authenticated, service_role;
grant execute on function public.dish_style_guess(text)       to authenticated, service_role;

-- ===========================================================================
-- 2. dish_tag_links — the stored tags.
-- ===========================================================================
create table if not exists public.dish_tag_links (
  dish_id    uuid        not null references public.dishes(id) on delete cascade,
  kind       text        not null check (kind in ('style', 'cuisine', 'suburb', 'city')),
  slug       text        not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) <= 64),
  label      text        not null check (char_length(label) between 1 and 80),
  source     text        not null check (source in ('place', 'keyword', 'sorter')),
  ord        smallint    not null default 0,
  created_at timestamptz not null default now(),
  primary key (dish_id, kind, slug)
);
create index if not exists dish_tag_links_tag_idx on public.dish_tag_links (kind, slug, dish_id);

alter table public.dish_tag_links enable row level security;
drop policy if exists dish_tag_links_select on public.dish_tag_links;
create policy dish_tag_links_select on public.dish_tag_links for select to authenticated using (true);
revoke all on public.dish_tag_links from anon, authenticated;
grant select on public.dish_tag_links to authenticated;
grant all on public.dish_tag_links to service_role;

comment on table public.dish_tag_links is
  'Round 7 (0053): a dish''s tags — style (keyword map or the sorter''s), cuisine / suburb / city (derived from its restaurant, trigger-maintained). Catalogue data; never written by clients. Diet chips are not stored (dish_consensus_tags, live). Read through dish_tags / similar_dishes / dishes_by_tag.';

-- ===========================================================================
-- 3. Maintenance — place-derived tags, keyword styles, the sorter's styles.
-- ===========================================================================
-- Recompute cuisine / suburb / city for these dishes from their restaurant (0052's city cache).
create or replace function public.dish_place_tags_refresh(p_dish_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(cardinality(p_dish_ids), 0) = 0 then
    return;
  end if;
  delete from public.dish_tag_links t
  where t.dish_id = any(p_dish_ids) and t.kind in ('cuisine', 'suburb', 'city');

  insert into public.dish_tag_links (dish_id, kind, slug, label, source, ord)
  select x.dish_id, x.kind, x.slug, x.label, 'place', 0
  from (
    select d.id as dish_id, 'cuisine' as kind, public.tag_slug(r.cuisine) as slug,
           left(btrim(r.cuisine), 80) as label
    from public.dishes d join public.restaurants r on r.id = d.restaurant_id
    where d.id = any(p_dish_ids)
    union all
    select d.id, 'suburb',
           public.tag_slug(concat_ws(' ', public.place_locality(r.address, r.city), c.city)),
           left(public.place_locality(r.address, r.city), 80)
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    left join public.place_city_cache c on c.restaurant_id = r.id
    left join public.cities ci on ci.id = c.city
    where d.id = any(p_dish_ids)
      -- the suburb IS the city (Melbourne CBD): one chip, the city's
      and not coalesce(c.loc = lower(ci.name) or c.loc = any(ci.aliases), false)
    union all
    select d.id, 'city', ci.id, ci.name
    from public.dishes d
    join public.place_city_cache c on c.restaurant_id = d.restaurant_id
    join public.cities ci on ci.id = c.city
    where d.id = any(p_dish_ids)
  ) x
  where x.slug is not null and nullif(btrim(coalesce(x.label, '')), '') is not null
  on conflict (dish_id, kind, slug) do nothing;
end;
$$;

-- Keyword styles for these dishes — only where the sorter has not named any.
create or replace function public.dish_style_keyword_refresh(p_dish_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(cardinality(p_dish_ids), 0) = 0 then
    return;
  end if;
  delete from public.dish_tag_links t
  where t.dish_id = any(p_dish_ids) and t.kind = 'style' and t.source = 'keyword';

  insert into public.dish_tag_links (dish_id, kind, slug, label, source, ord)
  select d.id, 'style', public.tag_slug(g.style), g.style, 'keyword', g.ord
  from public.dishes d
  cross join lateral unnest(public.dish_style_guess(d.name)) with ordinality as g(style, ord)
  where d.id = any(p_dish_ids)
    and not exists (select 1 from public.dish_tag_links s
                    where s.dish_id = d.id and s.kind = 'style' and s.source = 'sorter')
  on conflict (dish_id, kind, slug) do nothing;
end;
$$;

-- The sorter named styles for a dish: they replace its keyword guesses; they add to earlier sorter
-- styles up to 3 in all and never remove one. A style that only repeats the cuisine is dropped.
create or replace function public.dish_apply_sorter_styles(p_dish_id uuid, p_styles text[])
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_style text;
  v_slug  text;
  v_have  int;
begin
  if p_dish_id is null or coalesce(cardinality(p_styles), 0) = 0 then
    return;
  end if;
  delete from public.dish_tag_links t
  where t.dish_id = p_dish_id and t.kind = 'style' and t.source = 'keyword';

  foreach v_style in array p_styles loop
    v_style := public.dish_style_clean(v_style);
    v_slug  := public.tag_slug(v_style);
    continue when v_slug is null;
    continue when exists (select 1 from public.dish_tag_links c
                          where c.dish_id = p_dish_id and c.kind = 'cuisine' and c.slug = v_slug);
    select count(*) into v_have from public.dish_tag_links s where s.dish_id = p_dish_id and s.kind = 'style';
    exit when v_have >= 3;
    insert into public.dish_tag_links (dish_id, kind, slug, label, source, ord)
    values (p_dish_id, 'style', v_slug, v_style, 'sorter', v_have + 1)
    on conflict (dish_id, kind, slug) do nothing;
  end loop;
end;
$$;

-- Triggers: a new or renamed dish; a restaurant's cuisine; a place's locality/city (0052's cache);
-- the cities themselves (labels, aliases).
create or replace function public.trg_dish_tags_dishes()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.dish_place_tags_refresh(array[new.id]);
  perform public.dish_style_keyword_refresh(array[new.id]);
  return null;
end;
$$;

drop trigger if exists dish_tags_dishes_aiu on public.dishes;
create trigger dish_tags_dishes_aiu
  after insert or update of name, restaurant_id on public.dishes
  for each row execute function public.trg_dish_tags_dishes();

create or replace function public.trg_dish_tags_restaurants()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.dish_place_tags_refresh(array(select d.id from public.dishes d where d.restaurant_id = new.id));
  return null;
end;
$$;

drop trigger if exists dish_tags_restaurants_au on public.restaurants;
create trigger dish_tags_restaurants_au
  after update of cuisine on public.restaurants
  for each row
  when (old.cuisine is distinct from new.cuisine)
  execute function public.trg_dish_tags_restaurants();

create or replace function public.trg_dish_tags_place_city()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.dish_place_tags_refresh(array(select d.id from public.dishes d where d.restaurant_id = new.restaurant_id));
  return null;
end;
$$;

-- Insert and update apart: WHEN may compare OLD only on an UPDATE trigger.
drop trigger if exists dish_tags_place_city_ai on public.place_city_cache;
create trigger dish_tags_place_city_ai
  after insert on public.place_city_cache
  for each row execute function public.trg_dish_tags_place_city();
drop trigger if exists dish_tags_place_city_au on public.place_city_cache;
create trigger dish_tags_place_city_au
  after update on public.place_city_cache
  for each row
  when (old.loc is distinct from new.loc or old.city is distinct from new.city)
  execute function public.trg_dish_tags_place_city();

create or replace function public.trg_dish_tags_cities()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.dish_place_tags_refresh(array(select d.id from public.dishes d));
  return null;
end;
$$;

-- Must run AFTER 0052's place_city_cities_aiud rebuilt the cache. Same-event triggers fire in name
-- order, so this one is named to sort after it.
drop trigger if exists zz_dish_tags_cities_aiud on public.cities;
create trigger zz_dish_tags_cities_aiud
  after insert or update or delete on public.cities
  for each statement execute function public.trg_dish_tags_cities();

revoke all on function public.dish_place_tags_refresh(uuid[])            from public, anon, authenticated;
revoke all on function public.dish_style_keyword_refresh(uuid[])         from public, anon, authenticated;
revoke all on function public.dish_apply_sorter_styles(uuid, text[])     from public, anon, authenticated;
revoke all on function public.trg_dish_tags_dishes()                     from public, anon, authenticated;
revoke all on function public.trg_dish_tags_restaurants()                from public, anon, authenticated;
revoke all on function public.trg_dish_tags_place_city()                 from public, anon, authenticated;
revoke all on function public.trg_dish_tags_cities()                     from public, anon, authenticated;
grant execute on function public.dish_place_tags_refresh(uuid[])        to service_role;
grant execute on function public.dish_style_keyword_refresh(uuid[])     to service_role;
grant execute on function public.dish_apply_sorter_styles(uuid, text[]) to service_role;

-- ===========================================================================
-- 4. Backfill — every existing dish (the staging seed included). Derived rows only.
-- ===========================================================================
select public.dish_place_tags_refresh(array(select d.id from public.dishes d));
select public.dish_style_keyword_refresh(array(select d.id from public.dishes d));

-- ===========================================================================
-- 5. apply_entry_sort — 0044's body verbatim, plus items[].styles (marked "0053").
-- ===========================================================================
create or replace function public.apply_entry_sort(
  p_entry_id      uuid,
  p_restaurant_id uuid    default null,
  p_items         jsonb   default '[]'::jsonb,
  p_mode          text    default 'stub',
  p_place_query   text    default null,
  p_place_offset  int     default null,
  p_meta          jsonb   default null
)
returns public.entries
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_entry       public.entries;
  v_rid         uuid;
  v_src         text;
  v_item        jsonb;
  v_name        text;
  v_score       numeric(2,1);
  v_evidence    text;
  v_note        text;
  v_mention     text;
  v_e_off       int;
  v_m_off       int;
  v_dish        uuid;
  v_pos         smallint := 0;
  v_validated   jsonb := '[]'::jsonb;
  v_corrections int;
  v_claimed     uuid[] := '{}';
  v_keep        public.reviews;
  v_matched     boolean;
  v_leftover    uuid;
  v_query       text;
  v_q_off       int;
  -- 0036
  v_tags        text[];
  v_prior       jsonb := '[]'::jsonb;   -- tags the replaced lines carried (T3)
  v_prior_ix    bigint;
  v_prior_taken bigint[] := '{}';
  -- 0044
  v_p_ev        text;
  v_p_off       int;
  v_p_at        int;
  -- 0053
  v_styles      text[];
begin
  select * into v_entry from public.entries where id = p_entry_id for update;
  if v_entry.id is null then
    raise exception 'entry % not found', p_entry_id using errcode = '02000';
  end if;

  select count(*) into v_corrections
  from public.reviews r
  where r.entry_id = p_entry_id and r.corrected_at is not null;

  -- rule 8 + R5: a place the USER attached is authoritative, and so is a place that has
  -- corrected lines hanging off it. The sorter may only fill a gap.
  if v_entry.restaurant_source = 'user'
     or (v_corrections > 0 and v_entry.restaurant_id is not null) then
    v_rid := v_entry.restaurant_id;
    v_src := v_entry.restaurant_source;
  elsif p_restaurant_id is not null then
    v_rid := p_restaurant_id;
    v_src := 'sorter';
  else
    v_rid := null;
    v_src := null;
  end if;

  -- WHERE the place is named in the words. After an explicit place correction there is
  -- no honest mention to record: the words named something else.
  if v_entry.place_corrected_at is not null then
    v_query := null;
    v_q_off := null;
  else
    v_query := nullif(btrim(coalesce(p_place_query, '')), '');
    v_q_off := public.verified_offset(v_entry.body, v_query, p_place_offset);
    if v_q_off is null then
      v_query := null;                -- not in the words ⇒ not a mention
    end if;
  end if;

  -- T3: remember the tags on the lines about to be replaced, in receipt order. An entry with
  -- no lines at all (placeless) inherits from its parked plan instead.
  -- 0044: …and a marked 6 (its evidence, and where it sat relative to the dish's mention).
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', lower(d.name), 'mention', lower(r.mention_text),
           'evidence', r.score_evidence, 'tags', to_jsonb(r.tags),
           'six', r.score = 6, 'offset', r.evidence_offset, 'moffset', r.mention_offset)
         order by r.entry_position nulls last, r.created_at, r.id), '[]'::jsonb)
    into v_prior
  from public.reviews r
  join public.dishes d on d.id = r.dish_id
  where r.entry_id = p_entry_id and r.corrected_at is null and (r.tags <> '{}'::text[] or r.score = 6);

  if not exists (select 1 from public.reviews r where r.entry_id = p_entry_id)
     and jsonb_typeof(v_entry.sort_plan) = 'array' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'name', lower(btrim(x.item ->> 'dish_name')), 'mention', lower(x.item ->> 'mention_text'),
             'evidence', x.item ->> 'score_evidence',
             'tags', to_jsonb(public.dish_tags_from_json(x.item -> 'tags')),
             'six', (x.item ->> 'score') in ('6', '6.0'),
             'offset', case when (x.item ->> 'evidence_offset') ~ '^\d{1,9}$' then (x.item ->> 'evidence_offset')::int end,
             'moffset', case when (x.item ->> 'mention_offset') ~ '^\d{1,9}$' then (x.item ->> 'mention_offset')::int end)
           order by x.ord), '[]'::jsonb)
      into v_prior
    from jsonb_array_elements(v_entry.sort_plan) with ordinality as x(item, ord)
    where cardinality(public.dish_tags_from_json(x.item -> 'tags')) > 0
       or (x.item ->> 'score') in ('6', '6.0');
  end if;

  -- R1: replace ONLY the lines the sorter owns.
  delete from public.reviews
  where entry_id = p_entry_id and corrected_at is null;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_name := btrim(coalesce(v_item ->> 'dish_name', ''));
    if v_name = '' or v_pos >= 24 then
      continue;
    end if;

    -- ---- score: half-step range, and EVIDENCE MUST BE IN THE USER'S WORDS -----
    begin
      v_score := (v_item ->> 'score')::numeric(2,1);
    exception when others then
      v_score := null;
    end;
    v_evidence := nullif(btrim(coalesce(v_item ->> 'score_evidence', '')), '');

    -- 0041: 0.5-5.0 in half steps, or THE SECRET 6. sort-entry proposes a 6 only on a span the
    -- client marked (six_tokens); this gate is the backstop: a 6 must be evidenced by a "6".
    if v_score is not null
       and not (v_score = 6 or (v_score >= 0.5 and v_score <= 5.0 and (v_score * 2) = floor(v_score * 2))) then
      v_score := null;
    end if;
    if v_score = 6 and (v_evidence is null or position('6' in v_evidence) = 0) then
      v_score := null;
    end if;
    -- THE RULE-7 GATE. No evidence, or evidence that is not literally in the body →
    -- there is no score. Applies identically to every sorter mode.
    if v_score is not null and (v_evidence is null or position(v_evidence in v_entry.body) = 0) then
      v_score    := null;
      v_evidence := null;
    end if;
    if v_score is null then
      v_evidence := null;
    end if;

    -- ---- note: must be a verbatim slice of the words (rule 9) -----------------
    v_note := nullif(btrim(coalesce(v_item ->> 'note', '')), '');
    if v_note is not null and position(v_note in v_entry.body) = 0 then
      v_note := null;
    end if;

    -- ---- WHERE: the sorter's offsets, verified against the body ---------------
    -- the regex is not decoration: a garbled payload must not abort the whole sort, and
    -- an offset is always a non-negative integer.
    v_mention := nullif(btrim(coalesce(v_item ->> 'mention_text', '')), '');
    v_e_off   := public.verified_offset(
      v_entry.body, v_evidence,
      case when (v_item ->> 'evidence_offset') ~ '^\d{1,9}$' then (v_item ->> 'evidence_offset')::int end);
    v_m_off   := public.verified_offset(
      v_entry.body, v_mention,
      case when (v_item ->> 'mention_offset') ~ '^\d{1,9}$' then (v_item ->> 'mention_offset')::int end);
    if v_m_off is null then
      v_mention := null;
    end if;

    -- ---- tags: marked by the client this time, known codes only (T4) ----------
    v_tags := public.dish_tags_from_json(v_item -> 'tags');
    -- 0053: the sorter's style words for this dish (validated; never a score, never the user's words)
    v_styles := public.dish_styles_from_json(v_item -> 'styles');

    v_pos := v_pos + 1;

    -- ---- R3: is this proposal a line the USER already fixed? ------------------
    v_matched := false;
    if v_corrections > 0 then
      select r.* into v_keep
      from public.reviews r
      join public.dishes d on d.id = r.dish_id
      where r.entry_id = p_entry_id
        and r.corrected_at is not null
        and not (r.id = any(v_claimed))
        and (
             lower(coalesce(r.corrected_from_name, '')) = lower(v_name)
          or lower(d.name) = lower(v_name)
          or (v_evidence is not null and r.score_evidence = v_evidence)
        )
      order by r.entry_position nulls last, r.created_at, r.id
      limit 1;
      v_matched := found;
    end if;

    if v_matched then
      v_claimed := v_claimed || v_keep.id;
      -- T2: its own tags, plus any marked for it now. Never fewer.
      v_tags := public.dish_tags_from_json(to_jsonb(v_keep.tags || v_tags));
      -- R2: ordering and WHERE only. The dish, the score, its evidence and the note are
      -- the user's and are not touched here.
      update public.reviews
         set entry_position  = v_pos,
             mention_text    = coalesce(v_mention, v_keep.mention_text),
             mention_offset  = coalesce(v_m_off,   v_keep.mention_offset),
             evidence_offset = case
                                 when v_keep.score_evidence is not null
                                      and v_keep.score_evidence = v_evidence then v_e_off
                                 else v_keep.evidence_offset
                               end,
             tags            = v_tags
       where id = v_keep.id;

      v_validated := v_validated || jsonb_build_object(
        'dish_name', v_name, 'score', v_score, 'score_evidence', v_evidence,
        'note', v_note, 'position', v_pos,
        'evidence_offset', v_e_off, 'mention_text', v_mention, 'mention_offset', v_m_off,
        'tags', to_jsonb(v_tags),
        'styles', to_jsonb(v_styles),
        'preserved', true
      );
      continue;
    end if;

    -- ---- T3: inherit the tags of the line this one replaces -------------------
    if jsonb_array_length(v_prior) > 0 then
      select p.ord into v_prior_ix
      from jsonb_array_elements(v_prior) with ordinality as p(e, ord)
      where not (p.ord = any(v_prior_taken))
        and (
             p.e ->> 'name' = lower(v_name)
          or (v_mention  is not null and p.e ->> 'mention'  = lower(v_mention))
          or (v_evidence is not null and p.e ->> 'evidence' = v_evidence)
        )
      order by p.ord
      limit 1;
      if v_prior_ix is not null then
        v_prior_taken := v_prior_taken || v_prior_ix;
        v_tags := public.dish_tags_from_json(
          to_jsonb(public.dish_tags_from_json(v_prior -> (v_prior_ix - 1)::int -> 'tags') || v_tags));
        -- 0044 SIX CARRY, keyed to the LINE: the replaced line held a user-marked 6 and this rebuilt
        -- line (matched to it above, as tags are) has no score. Its score-evidence span sat a fixed
        -- distance from its dish's mention; if the words at that distance from THIS line's mention
        -- still read the evidence — a lone 6 — the 6 stays, wherever the line now sits. An earlier
        -- mark, preserved; never a 6 read off the prose. Changed (the new score wins) or removed → gone.
        if v_score is null and v_m_off is not null and (v_prior -> (v_prior_ix - 1)::int ->> 'six')::boolean then
          v_p_ev  := v_prior -> (v_prior_ix - 1)::int ->> 'evidence';
          v_p_off := (v_prior -> (v_prior_ix - 1)::int ->> 'offset')::int;
          v_p_at  := v_m_off + v_p_off - (v_prior -> (v_prior_ix - 1)::int ->> 'moffset')::int;
          if v_p_ev is not null and v_p_at is not null and v_p_at >= 0 and position('6' in v_p_ev) > 0
             and substring(v_entry.body from v_p_at + 1 for char_length(v_p_ev)) = v_p_ev
             and (v_p_at = 0 or substring(v_entry.body from v_p_at for 1) !~ '[0-9.]')
             and substring(v_entry.body from v_p_at + char_length(v_p_ev) + 1 for 2) !~ '^([0-9]|[.][0-9])' then
            v_score    := 6;
            v_evidence := v_p_ev;
            v_e_off    := v_p_at;
          end if;
        end if;
      end if;
      v_prior_ix := null;
    end if;

    v_validated := v_validated || jsonb_build_object(
      'dish_name', v_name, 'score', v_score, 'score_evidence', v_evidence,
      'note', v_note, 'position', v_pos,
      'evidence_offset', v_e_off, 'mention_text', v_mention, 'mention_offset', v_m_off,
      'tags', to_jsonb(v_tags),
      'styles', to_jsonb(v_styles),
      'preserved', false
    );

    -- no place ⇒ no dish rows possible; the plan above is the record.
    if v_rid is not null then
      v_dish := public.find_or_create_dish(v_rid, v_name, v_entry.author_id);
      insert into public.reviews
        (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, score_evidence,
         note, evidence_offset, mention_text, mention_offset, created_at, tags)
      values
        (v_entry.author_id, v_dish, v_rid, p_entry_id, v_pos, v_score, v_evidence,
         v_note, v_e_off, v_mention, v_m_off, v_entry.created_at, v_tags);
      -- 0053: the dish's style tags (replacing its keyword guesses; never more than 3)
      perform public.dish_apply_sorter_styles(v_dish, v_styles);
    end if;
  end loop;

  -- R4: corrected lines the parse did not account for keep their place on the receipt,
  -- after the parsed ones, in their previous order.
  if v_corrections > 0 then
    for v_leftover in
      select r.id
      from public.reviews r
      where r.entry_id = p_entry_id
        and r.corrected_at is not null
        and not (r.id = any(v_claimed))
      order by r.entry_position nulls last, r.created_at, r.id
    loop
      v_pos := v_pos + 1;
      update public.reviews set entry_position = v_pos where id = v_leftover;
    end loop;
  end if;

  update public.entries
     set restaurant_id     = v_rid,
         restaurant_source = v_src,
         sort_status       = 'sorted',
         sort_mode         = p_mode,
         sort_error        = null,
         sorted_at         = now(),
         sort_plan         = v_validated,
         place_query       = v_query,
         place_offset      = v_q_off,
         sort_meta         = p_meta
   where id = p_entry_id
  returning * into v_entry;

  return v_entry;
end; $$;

comment on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int, jsonb) is
  'The sorter''s single transactional write: place + N dish reviews + where each finding sits in the body. PRESERVES every review the user corrected (corrected_at not null) — dish, score, evidence and note — and replaces only the sorter''s own lines, forced or not. Drops any score whose evidence is not a substring of the body (rule 7) and any note that is not (rule 9). Tags (0036): items[].tags are client-marked codes, filtered to the closed set; a re-sort never removes a tag. p_meta (0039) → entries.sort_meta ({cache_hit, model}). Scores 0.5-5.0 in half steps, or 6 evidenced by a "6" (0041); a re-sort keeps a replaced line''s 6 while the rebuilt line''s evidence span (same distance from its mention) still reads it (0044). items[].styles (0053): ≤3 style words per new line''s dish (dish_apply_sorter_styles), kept in the parked plan. service_role only.';

-- ===========================================================================
-- 6. correct_entry_place — 0036's body verbatim, plus the parked plan's styles (marked "0053").
-- ===========================================================================
create or replace function public.correct_entry_place(p_entry_id uuid, p_restaurant_id uuid)
returns public.entries
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_entry public.entries;
  v_rev   record;
  v_item  jsonb;
  v_dish  uuid;
  v_pos   smallint := 0;
  v_name  text;
  v_score numeric(2,1);
  v_evid  text;
  v_note  text;
  v_ment  text;
  v_e_off int;
  v_m_off int;
begin
  select * into v_entry from public.entries where id = p_entry_id for update;
  if v_entry.id is null or v_entry.author_id <> (select auth.uid()) then
    raise exception 'entry % not found or not yours', p_entry_id using errcode = '42501';
  end if;
  if p_restaurant_id is null then
    raise exception 'a restaurant is required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.restaurants r where r.id = p_restaurant_id) then
    raise exception 'restaurant % not found', p_restaurant_id using errcode = '23503';
  end if;

  if exists (select 1 from public.reviews v where v.entry_id = p_entry_id) then
    -- (a) repoint every existing line item to the same dish NAME at the new place.
    -- Moving a line to the equivalent dish at another restaurant is bookkeeping, not a
    -- per-line dish correction, so the correction trigger sits this one out. Tags ride
    -- the row untouched.
    perform set_config('ate.repointing', 'on', true);
    for v_rev in
      select v.id, v.entry_position, d.name
      from public.reviews v join public.dishes d on d.id = v.dish_id
      where v.entry_id = p_entry_id
      order by v.entry_position nulls last, v.created_at, v.id
    loop
      v_dish := public.find_or_create_dish(p_restaurant_id, v_rev.name, v_entry.author_id);
      -- restaurant_id is re-derived by trg_review_set_restaurant from the new dish.
      update public.reviews set dish_id = v_dish where id = v_rev.id;
    end loop;
    perform set_config('ate.repointing', 'off', true);
  else
    -- (b) print the parked plan at last.
    for v_item in select * from jsonb_array_elements(coalesce(v_entry.sort_plan, '[]'::jsonb)) loop
      v_name := btrim(coalesce(v_item ->> 'dish_name', ''));
      if v_name = '' or v_pos >= 24 then
        continue;
      end if;
      begin
        v_score := (v_item ->> 'score')::numeric(2,1);
      exception when others then
        v_score := null;
      end;
      v_evid := nullif(btrim(coalesce(v_item ->> 'score_evidence', '')), '');
      v_note := nullif(btrim(coalesce(v_item ->> 'note', '')), '');
      v_ment := nullif(btrim(coalesce(v_item ->> 'mention_text', '')), '');
      -- re-assert rules 7 + 9 against the body AS IT IS NOW: the plan was parked
      -- when the entry was sorted, and the author may have edited their words since.
      if v_score is not null and (v_evid is null or position(v_evid in v_entry.body) = 0) then
        v_score := null;
        v_evid  := null;
      end if;
      if v_note is not null and position(v_note in v_entry.body) = 0 then
        v_note := null;
      end if;
      v_e_off := public.verified_offset(
        v_entry.body, v_evid,
        case when (v_item ->> 'evidence_offset') ~ '^\d{1,9}$' then (v_item ->> 'evidence_offset')::int end);
      v_m_off := public.verified_offset(
        v_entry.body, v_ment,
        case when (v_item ->> 'mention_offset') ~ '^\d{1,9}$' then (v_item ->> 'mention_offset')::int end);
      if v_m_off is null then
        v_ment := null;
      end if;

      v_pos  := v_pos + 1;
      v_dish := public.find_or_create_dish(p_restaurant_id, v_name, v_entry.author_id);
      insert into public.reviews
        (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, score_evidence,
         note, evidence_offset, mention_text, mention_offset, created_at, tags)
      values
        (v_entry.author_id, v_dish, p_restaurant_id, p_entry_id, v_pos, v_score, v_evid,
         v_note, v_e_off, v_ment, v_m_off, v_entry.created_at,
         public.dish_tags_from_json(v_item -> 'tags'));
      -- 0053: the parked plan's style tags, onto the dish it now prints
      perform public.dish_apply_sorter_styles(v_dish, public.dish_styles_from_json(v_item -> 'styles'));
    end loop;
  end if;

  update public.entries
     set restaurant_id      = p_restaurant_id,
         restaurant_source  = 'user',
         sort_status        = 'sorted',
         place_corrected_at = now(),
         place_query        = null,
         place_offset       = null
   where id = p_entry_id
  returning * into v_entry;

  return v_entry;
end; $$;

-- ===========================================================================
-- 7. The Journal: my_entries' filter set, once — then the count and the calendar on it.
-- ===========================================================================
-- The caller's own entries passing my_entries' filters (0043/0047 rules exactly), with each one's
-- best line score. Internal: my_entries_count and journal_days read it; my_entries keeps its body.
create or replace function public.my_entries_filtered(
  p_min_score     numeric,
  p_max_score     numeric,
  p_city          text,
  p_from          date,
  p_to            date,
  p_tz            text,
  p_restaurant_id uuid,
  p_tag           text
)
returns table (id uuid, created_at timestamptz, best_score numeric)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_me     uuid := auth.uid();
  v_tag    text := nullif(lower(btrim(coalesce(p_tag, ''))), '');
  v_tz     text := coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Australia/Melbourne');
  v_city   text := nullif(lower(btrim(coalesce(p_city, ''))), '');
  v_places uuid[];
  v_start  timestamptz;
  v_end    timestamptz;
begin
  if v_me is null then
    raise exception 'signed-in callers only' using errcode = '42501';
  end if;
  if v_city is not null then
    v_places := coalesce(array(select pc.restaurant_id from public.place_cities pc where pc.city = v_city), '{}');
  end if;
  -- in_window()'s calendar-day rule as an index-friendly range (0052's window_bounds)
  select w.start_at, w.end_at into v_start, v_end from public.window_bounds(p_from, p_to, v_tz) w;

  return query
  select b.id, b.created_at, b.best_score
  from (
    select e.id, e.created_at,
           (select max(v.score) from public.reviews v where v.entry_id = e.id) as best_score
    from public.entries e
    where e.author_id = v_me
      and (p_restaurant_id is null or e.restaurant_id = p_restaurant_id)
      and (v_city is null or e.restaurant_id = any(v_places))
      and (p_from is null or e.created_at >= v_start)
      and (p_to   is null or e.created_at <  v_end)
      and (v_tag is null or exists (
            select 1 from public.reviews v where v.entry_id = e.id and v_tag = any(v.tags)))
  ) b
  where public.score_in_range(b.best_score, p_min_score, p_max_score);
end;
$$;

comment on function public.my_entries_filtered(numeric, numeric, text, date, date, text, uuid, text) is
  'Round 7 (0053), internal: the caller''s own entries through my_entries'' filters (place, city, score range, one dietary tag, visit days in p_tz), with best_score. my_entries_count and journal_days count exactly this set.';

-- "Show N entries".
create or replace function public.my_entries_count(
  p_min_score     numeric default null,
  p_max_score     numeric default null,
  p_city          text    default null,
  p_from          date    default null,
  p_to            date    default null,
  p_tz            text    default null,
  p_restaurant_id uuid    default null,
  p_tag           text    default null
)
returns int
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select count(*)::int
  from public.my_entries_filtered(p_min_score, p_max_score, p_city, p_from, p_to, p_tz, p_restaurant_id, p_tag);
$$;

comment on function public.my_entries_count(numeric, numeric, text, date, date, text, uuid, text) is
  'Round 7 (0053): how many entries my_entries returns (across every page) for the same filters — the filter sheet''s "Show N entries". p_tz default Australia/Melbourne; pass the device zone.';

-- The calendar: one row per local day that holds one of my entries.
create or replace function public.journal_days(
  p_from          date,
  p_to            date,
  p_tz            text    default null,
  p_min_score     numeric default null,
  p_max_score     numeric default null,
  p_city          text    default null,
  p_restaurant_id uuid    default null,
  p_tag           text    default null
)
returns table (
  day        date,
  entries    int,
  best_score numeric(2,1),
  cover_url  text
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with mine as (
    select f.id, f.created_at, f.best_score,
           (f.created_at at time zone coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Australia/Melbourne'))::date as day
    from public.my_entries_filtered(p_min_score, p_max_score, p_city, p_from, p_to, p_tz, p_restaurant_id, p_tag) f
  ),
  covered as (
    select m.*,
           coalesce(
             (select p.photo_url from public.entry_photos p where p.entry_id = m.id order by p.position limit 1),
             (select v.photo_url from public.reviews v
               where v.entry_id = m.id and v.photo_url is not null
               order by v.entry_position nulls last, v.id limit 1)
           ) as cover
    from mine m
  )
  select c.day,
         count(*)::int,
         max(c.best_score)::numeric(2,1),
         (array_agg(c.cover order by c.created_at desc, c.id desc) filter (where c.cover is not null))[1]
  from covered c
  group by c.day
  order by c.day;
$$;

comment on function public.journal_days(date, date, text, numeric, numeric, text, uuid, text) is
  'Round 7 (0053): the Journal calendar — for each local day (p_tz, default Australia/Melbourne) in [p_from, p_to] (inclusive, either open) holding one of the caller''s entries: how many, the best line score (a 6 is 6; NULL = none scored) and a cover (the newest entry that day with a photo: its first photo, else a line''s). Oldest day first. Optional trailing filters = my_entries'' (p_min_score, p_max_score, p_city, p_restaurant_id, p_tag). Month divider counts = the sum of a month''s rows.';

revoke all on function public.my_entries_filtered(numeric, numeric, text, date, date, text, uuid, text) from public, anon;
revoke all on function public.my_entries_count(numeric, numeric, text, date, date, text, uuid, text) from public, anon;
revoke all on function public.journal_days(date, date, text, numeric, numeric, text, uuid, text) from public, anon;
grant execute on function public.my_entries_filtered(numeric, numeric, text, date, date, text, uuid, text) to authenticated, service_role;
grant execute on function public.my_entries_count(numeric, numeric, text, date, date, text, uuid, text) to authenticated, service_role;
grant execute on function public.journal_days(date, date, text, numeric, numeric, text, uuid, text) to authenticated, service_role;

-- ===========================================================================
-- 8. Dish tags — the chip strip, "more like this", a tag's results page.
-- ===========================================================================
create or replace function public.dish_tags(p_dish_id uuid)
returns table (kind text, slug text, label text)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then
    raise exception 'signed-in callers only' using errcode = '42501';
  end if;
  return query
  select x.kind, x.slug, x.label
  from (
    select t.kind, t.slug, t.label,
           case t.kind when 'style' then 1 when 'cuisine' then 2 when 'suburb' then 3 else 4 end as tier,
           t.ord::bigint as ord
    from public.dish_tag_links t
    where t.dish_id = p_dish_id
    union all
    -- diet: 0036's consensus, live and viewer-relative — the same list as dish_summary.tags
    select 'diet', c.code, upper(c.code), 5, c.ord
    from unnest(public.dish_consensus_tags(p_dish_id)) with ordinality as c(code, ord)
  ) x
  order by x.tier, x.ord, x.slug;
end;
$$;

comment on function public.dish_tags(uuid) is
  'Round 7 (0053): a dish''s chips — style (1–3), cuisine, suburb, city, then diet (dish_summary.tags'' codes, label upper-case). Pass (kind, slug) to dishes_by_tag. [] for an unknown dish.';

-- The row every dish list here returns, for a set of candidate dishes: live, logged (≥1 line the
-- viewer can see), numbers over the lines the viewer can see (dish_stats' rule, blocks respected).
create or replace function public.similar_dishes(p_dish_id uuid, p_limit int default 10)
returns table (
  dish_id         uuid,
  name            text,
  restaurant_id   uuid,
  restaurant_name text,
  score           numeric(2,1),
  review_count    int,
  cover_url       text
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_lim int := least(greatest(coalesce(p_limit, 10), 1), 50);
begin
  if auth.uid() is null then
    raise exception 'signed-in callers only' using errcode = '42501';
  end if;
  return query
  with me as (
    select t.kind, t.slug from public.dish_tag_links t where t.dish_id = p_dish_id
  ),
  -- similar = shares a style or the cuisine; then every shared tag weighs in
  cand as (
    select distinct t.dish_id
    from public.dish_tag_links t
    join me on me.kind = t.kind and me.slug = t.slug
    where t.kind in ('style', 'cuisine') and t.dish_id <> p_dish_id
  ),
  weighed as (
    select c.dish_id,
           sum(case t.kind when 'style' then 8 when 'cuisine' then 4 when 'suburb' then 2 else 1 end)::int as weight
    from cand c
    join public.dish_tag_links t on t.dish_id = c.dish_id
    join me on me.kind = t.kind and me.slug = t.slug
    group by c.dish_id
  ),
  numbered as (
    select w.dish_id, w.weight,
           round(avg(v.score), 1)::numeric(2,1) as score,
           count(*)::int as review_count
    from weighed w
    join public.reviews v on v.dish_id = w.dish_id
    group by w.dish_id, w.weight
  ),
  page as (
    select n.dish_id, d.name, d.restaurant_id, r.name as restaurant_name, n.score, n.review_count, n.weight
    from numbered n
    join public.dishes d on d.id = n.dish_id and d.merged_into_dish_id is null
    join public.restaurants r on r.id = d.restaurant_id
    order by n.weight desc, coalesce(n.score, -1) desc, n.review_count desc, lower(d.name), n.dish_id
    limit v_lim
  )
  select p.dish_id, p.name, p.restaurant_id, p.restaurant_name, p.score, p.review_count,
         public.dish_cover_url(p.dish_id)
  from page p
  order by p.weight desc, coalesce(p.score, -1) desc, p.review_count desc, lower(p.name), p.dish_id;
end;
$$;

comment on function public.similar_dishes(uuid, int) is
  'Round 7 (0053): dishes like this one — sharing a style or the cuisine — ranked by weighted tag overlap (style 8, cuisine 4, suburb 2, city 1: each tier outweighs all below it), then printed score (unscored last), review_count, name, id. Excludes the dish itself, merged and never-logged dishes; numbers over lines the viewer can see. p_limit default 10, max 50. Unpaged.';

create or replace function public.dishes_by_tag(
  p_kind                text,
  p_slug                text,
  p_limit               int     default 30,
  p_cursor_score        numeric default null,
  p_cursor_review_count int     default null,
  p_cursor_name         text    default null,
  p_cursor_dish_id      uuid    default null
)
returns table (
  dish_id         uuid,
  name            text,
  restaurant_id   uuid,
  restaurant_name text,
  score           numeric(2,1),
  review_count    int,
  cover_url       text
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_slug text := lower(btrim(coalesce(p_slug, '')));
  v_lim  int  := least(greatest(coalesce(p_limit, 30), 1), 100);
begin
  if auth.uid() is null then
    raise exception 'signed-in callers only' using errcode = '42501';
  end if;
  if v_kind not in ('style', 'cuisine', 'suburb', 'city', 'diet') then
    raise exception 'p_kind must be style, cuisine, suburb, city or diet (got %)', p_kind using errcode = '22023';
  end if;

  return query
  with cand as (
    select t.dish_id from public.dish_tag_links t
    where v_kind <> 'diet' and t.kind = v_kind and t.slug = v_slug
    union
    -- diet: any dish with a line carrying the code, kept below only if the consensus lists it
    select v.dish_id from public.reviews v
    where v_kind = 'diet' and v_slug = any(v.tags)
  ),
  numbered as (
    select c.dish_id,
           round(avg(v.score), 1)::numeric(2,1) as score,
           count(*)::int as review_count
    from cand c
    join public.reviews v on v.dish_id = c.dish_id
    group by c.dish_id
  ),
  page as (
    select n.dish_id, d.name, d.restaurant_id, r.name as restaurant_name, n.score, n.review_count
    from numbered n
    join public.dishes d on d.id = n.dish_id and d.merged_into_dish_id is null
    join public.restaurants r on r.id = d.restaurant_id
    where (v_kind <> 'diet' or v_slug = any(public.dish_consensus_tags(n.dish_id)))
      and (
        p_cursor_dish_id is null
        or coalesce(n.score, -1) < coalesce(p_cursor_score, -1)
        or (coalesce(n.score, -1) = coalesce(p_cursor_score, -1)
            and n.review_count < p_cursor_review_count)
        or (coalesce(n.score, -1) = coalesce(p_cursor_score, -1)
            and n.review_count = p_cursor_review_count
            and (lower(d.name), n.dish_id) > (lower(coalesce(p_cursor_name, '')), p_cursor_dish_id))
      )
    order by coalesce(n.score, -1) desc, n.review_count desc, lower(d.name), n.dish_id
    limit v_lim
  )
  select p.dish_id, p.name, p.restaurant_id, p.restaurant_name, p.score, p.review_count,
         public.dish_cover_url(p.dish_id)
  from page p
  order by coalesce(p.score, -1) desc, p.review_count desc, lower(p.name), p.dish_id;
end;
$$;

comment on function public.dishes_by_tag(text, text, int, numeric, int, text, uuid) is
  'Round 7 (0053): a tag chip''s results — every live, logged dish carrying (p_kind, p_slug) from dish_tags (diet: the consensus rule, live), best first: printed score desc (a 6 above every 5, unscored last), review_count desc, lower(name), dish_id. Keyset: pass the last row''s score, review_count, name, dish_id (score may be null). p_limit default 30, max 100. Unknown slug → []; unknown kind → 22023.';

revoke all on function public.dish_tags(uuid)                                        from public, anon;
revoke all on function public.similar_dishes(uuid, int)                              from public, anon;
revoke all on function public.dishes_by_tag(text, text, int, numeric, int, text, uuid) from public, anon;
grant execute on function public.dish_tags(uuid)                                        to authenticated, service_role;
grant execute on function public.similar_dishes(uuid, int)                              to authenticated, service_role;
grant execute on function public.dishes_by_tag(text, text, int, numeric, int, text, uuid) to authenticated, service_role;
