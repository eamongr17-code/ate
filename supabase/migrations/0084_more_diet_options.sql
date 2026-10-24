-- 0084 — more diet options (23 Oct, Eamon; mockup design/rebuild/diet-more.html).
--
-- Five codes join the five of 0036, appended so every existing canonical array keeps its order:
--   gf, df, v, vg, nf, pe (pescatarian), ha (halal), ef (egg free), pf (peanut free), sf (shellfish free)
--
-- What covers what (counting only — nothing is ever stored expanded):
--   vg → v, df, ef, pe        v → pe        nf → pf
-- So a vegan line counts toward Vegetarian, Pescatarian, Dairy free and Egg free; a vegetarian line
-- toward Pescatarian; a nut-free line toward Peanut free.
--
-- dish_diet_counts now carries EVERY counted code, not just those below the label: the app shows
-- plain pills and puts the counts behind a "?" popover, which needs the labelled codes' counts too.
-- A code someone turned off on the dish (a veto) is left out of the counts, as it is of the labels.
-- Older apps only ever draw counts for codes that are not labels, so they are unaffected.
--
-- CONTRACT: ADDITIVE for profiles.diet / reviews.tags / diet_tags / diet_off / sort-entry tags (five
-- more codes accepted). BEHAVIOURAL: dish_summary.diet_counts / place_dishes.diet_counts hold every
-- counted, unvetoed code (same column, same type). Same signatures throughout.

set search_path = public, extensions;

-- ===========================================================================
-- 1. The vocabulary.
-- ===========================================================================
create or replace function public.dish_tag_codes()
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$ select array['gf', 'df', 'v', 'vg', 'nf', 'pe', 'ha', 'ef', 'pf', 'sf']::text[] $$;

comment on function public.dish_tag_codes() is
  'The closed set of dietary tag codes, in canonical order: gf, df, v, vg, nf, pe, ha, ef, pf, sf (0036, 0084).';

-- ===========================================================================
-- 2. The closed-set CHECKs, widened.
-- ===========================================================================
alter table public.reviews drop constraint if exists reviews_tags_closed_set;
alter table public.reviews
  add constraint reviews_tags_closed_set
  check (tags <@ array['gf', 'df', 'v', 'vg', 'nf', 'pe', 'ha', 'ef', 'pf', 'sf']::text[]);

alter table public.reviews drop constraint if exists reviews_diet_tags_closed_set;
alter table public.reviews
  add constraint reviews_diet_tags_closed_set
  check (diet_tags <@ array['gf', 'df', 'v', 'vg', 'nf', 'pe', 'ha', 'ef', 'pf', 'sf']::text[]);

alter table public.reviews drop constraint if exists reviews_diet_off_closed_set;
alter table public.reviews
  add constraint reviews_diet_off_closed_set
  check (diet_off <@ array['gf', 'df', 'v', 'vg', 'nf', 'pe', 'ha', 'ef', 'pf', 'sf']::text[]);

alter table public.profiles drop constraint if exists profiles_diet_closed_set;
alter table public.profiles
  add constraint profiles_diet_closed_set
  check (diet <@ array['gf', 'df', 'v', 'vg', 'nf', 'pe', 'ha', 'ef', 'pf', 'sf']::text[]);

comment on column public.profiles.diet is
  'What this person always eats (0074, 0084): subset of {gf,df,v,vg,nf,pe,ha,ef,pf,sf}, canonical, {} = none. Stamped on every NEW dish line they log (reviews.diet_tags). Stored as picked: vegan is vg alone. Owner-written via profile PATCH.';

-- ===========================================================================
-- 3. What covers what.
-- ===========================================================================
create or replace function public.diet_tags_implied(p_tags text[])
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select public.dish_tags_canonical(
    coalesce(p_tags, '{}'::text[])
    || case when 'vg' = any(coalesce(p_tags, '{}'::text[])) then array['v', 'df', 'ef', 'pe']::text[] else '{}'::text[] end
    || case when 'v'  = any(coalesce(p_tags, '{}'::text[])) then array['pe']::text[] else '{}'::text[] end
    || case when 'nf' = any(coalesce(p_tags, '{}'::text[])) then array['pf']::text[] else '{}'::text[] end);
$$;

comment on function public.diet_tags_implied(text[]) is
  'A line''s tags as the dish label counts them: vg also counts as v, df, ef and pe; v as pe; nf as pf (0074, 0084). Canonical; never stored.';

create or replace function public.diet_codes_counting_as(p_code text)
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select case lower(btrim(coalesce(p_code, '')))
           when 'v'  then array['v', 'vg']::text[]
           when 'df' then array['df', 'vg']::text[]
           when 'ef' then array['ef', 'vg']::text[]
           when 'pe' then array['pe', 'v', 'vg']::text[]
           when 'pf' then array['pf', 'nf']::text[]
           else array[lower(btrim(coalesce(p_code, '')))]::text[]
         end;
$$;

comment on function public.diet_codes_counting_as(text) is
  'Line codes that count toward p_code on the dish label: v ← {v, vg}, df ← {df, vg}, ef ← {ef, vg}, pe ← {pe, v, vg}, pf ← {pf, nf}, else just itself (0074, 0084).';

-- ===========================================================================
-- 4. Every counted, unvetoed code — for the "?" popover.
-- ===========================================================================
create or replace function public.dish_diet_counts(p_dish_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(jsonb_object_agg(t.code, t.people), '{}'::jsonb)
  from public.dish_diet_tally(p_dish_id) t
  where t.people > 0 and not t.vetoed;
$$;

comment on function public.dish_diet_counts(uuid) is
  '{code: people} for every code at least one person marked on the dish within dish_label_window() and nobody turned off (0084; 0074 held only codes below the label). {} when none. Viewer-relative.';
