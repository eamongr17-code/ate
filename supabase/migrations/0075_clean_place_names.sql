-- 0075_clean_place_names.sql
-- Ate backend — a place is called by its NAME, not by the keywords its owner padded the Google listing
-- with (Eamon, 20 Oct: "VIVIN Suk 22 - café grocery bistro - Local Organic Natural Artisan").
--
--   restaurants.google_name text NULL   the name exactly as Google gave it, kept only when it differs
--                                       from `name` (NULL = Google's name was already clean, or a
--                                       manual row).
--
-- THE RULE (clean_place_name, mirrored by functions/places-search/name.ts for predictions):
--   1. cut at the first spaced separator: " - ", " – ", " — ", " | ", " · ", " • ", or a bare "|".
--      A hyphen inside a word ("Ka-Pow") is not a separator.
--   2. drop one trailing (…) or […].
--   A step that would leave fewer than two characters is skipped. Nothing is inferred: no word lists,
--   no model, so a real name is never rewritten into something it isn't.
--
-- WRITES: trigger restaurants_clean_name_biu, on every INSERT and every UPDATE OF name of a
--   source='places' row (places-search's upserts re-send Google's raw name on each pick; the trigger
--   cleans it each time and keeps the raw text in google_name). Manual rows are what a person typed
--   and are never touched.
-- DATA: every existing Google row is cleaned once, here (fires the trigger). Dishes, entries and
--   reviews point at restaurants by id, so nothing else changes.
-- WIRE IMPACT: none (same `name` column, shorter text). google_name is not exposed.

set search_path = public, extensions;

alter table public.restaurants add column if not exists google_name text;

comment on column public.restaurants.google_name is
  'The Google listing''s name verbatim when clean_place_name() shortened it; NULL otherwise. See 0075.';

create or replace function public.clean_place_name(p_raw text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  with n as (
    select btrim(regexp_replace(coalesce(p_raw, ''), '\s+', ' ', 'g')) as name
  ), head as (
    select name, btrim((regexp_split_to_array(name, '\s+[-–—|·•]\s+|\s*\|\s*'))[1]) as h from n
  ), cut as (
    select case when char_length(h) >= 2 then h else name end as c from head
  ), bare as (
    select c, btrim(regexp_replace(c, '\s*[\(\[][^\)\]]*[\)\]]$', '')) as b from cut
  )
  select case when char_length(b) >= 2 then b else c end from bare;
$$;

comment on function public.clean_place_name(text) is
  'A Google listing''s name without padded keywords: cut at the first spaced separator, drop a trailing bracket. Mirrors places-search/name.ts. See 0075.';

create or replace function public.restaurants_clean_name()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_clean text;
begin
  if new.source <> 'places' then
    return new;
  end if;
  v_clean := public.clean_place_name(new.name);
  if v_clean is distinct from new.name then
    new.google_name := new.name;
    new.name := v_clean;
  elsif new.google_name is not null
        and public.clean_place_name(new.google_name) is distinct from new.name then
    -- A clean name that isn't the held listing's (Google dropped the padding): nothing is held back.
    -- An upsert's ON CONFLICT re-sends excluded.name, which this trigger already cleaned on the
    -- insert attempt; that matches the held listing, so the listing stays.
    new.google_name := null;
  end if;
  return new;
end;
$$;

drop trigger if exists restaurants_clean_name_biu on public.restaurants;
create trigger restaurants_clean_name_biu
  before insert or update of name on public.restaurants
  for each row execute function public.restaurants_clean_name();

-- Backfill: only the rows the rule would change.
update public.restaurants
   set name = name
 where source = 'places'
   and public.clean_place_name(name) is distinct from name;
