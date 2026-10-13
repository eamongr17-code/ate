-- 0065 — dish names print in title case (13 Oct beta, Eamon: "the dish titles in the headings are
-- still not capitalised"). "Fish stir fry" prints "Fish Stir Fry"; small words stay lower inside a
-- name ("Cacio e Pepe", "Fish & Chips"); a word with its own capitals ("BBQ", "McFlurry") is kept;
-- a name typed all in capitals is lowered first. This replaces the 10 Oct sentence case.
--
--   dish_title(text)      the rule, in SQL. Mirrors titleCase in functions/sort-entry/validate.ts.
--                         Case only: it never trims or collapses spaces, so lower(dish_title(x)) =
--                         lower(x) and dishes_identity_uq can never collide on the backfill.
--   find_or_create_dish   a new dish's display name goes through dish_title (was: first letter).
--   add_own_save          the same for a dish you save yourself (was: first letter, 0062).
--   backfill              every dish and own save already stored, so old receipts match new ones.
--                         Case-only rewrite of display names; ids, links and scores are untouched.

create or replace function public.dish_title(p_name text)
returns text
language plpgsql immutable parallel safe
set search_path = public, extensions
as $$
declare
  -- Lower case inside a name; the first word is always capitalised. Same list as validate.ts.
  c_minor constant text[] := array[
    'a', 'an', 'and', '&', 'or', 'of', 'with', 'on', 'in', 'the', 'to', 'for', 'n',
    'al', 'alla', 'alle', 'di', 'da', 'de', 'del', 'della', 'e', 'con', 'y', 'en', 'au', 'aux', 'à'];
  v_name  text := coalesce(p_name, '');
  v_word  text;
  v_part  text;
  v_parts text[];
  v_out   text[] := '{}';
  v_i     int := 0;
begin
  if v_name = '' then
    return v_name;
  end if;
  if v_name !~ '[[:lower:]]' then
    v_name := lower(v_name);            -- all capitals carries no meaning
  end if;
  foreach v_word in array string_to_array(v_name, ' ') loop
    v_i := v_i + 1;
    if v_i > 1 and lower(v_word) = any (c_minor) then
      v_out := v_out || lower(v_word);
      continue;
    end if;
    v_parts := '{}';
    foreach v_part in array string_to_array(v_word, '-') loop
      if v_part = '' or substr(v_part, 2) ~ '[[:upper:]]' then
        v_parts := v_parts || v_part;    -- somebody's own spelling ("BBQ", "McFlurry")
      else
        v_parts := v_parts || (upper(substr(v_part, 1, 1)) || substr(v_part, 2));
      end if;
    end loop;
    v_out := v_out || array_to_string(v_parts, '-');
  end loop;
  return array_to_string(v_out, ' ');
end; $$;

comment on function public.dish_title(text) is
  'A dish name in title case (13 Oct): every word capitalised, small words lower inside, own capitals kept, all-caps lowered first. Case only; mirrors sort-entry validate.ts titleCase.';

create or replace function public.find_or_create_dish(
  p_restaurant_id uuid,
  p_name          text,
  p_created_by    uuid default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_name    text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_display text;
  v_id      uuid;
begin
  if p_restaurant_id is null then
    raise exception 'find_or_create_dish requires a restaurant' using errcode = '22023';
  end if;
  if v_name = '' then
    raise exception 'find_or_create_dish requires a dish name' using errcode = '22023';
  end if;

  select d.id into v_id
  from public.dishes d
  where d.restaurant_id = p_restaurant_id
    and lower(d.name) = lower(v_name)
    and d.merged_into_dish_id is null
  limit 1;
  if v_id is not null then
    return v_id;                      -- an existing dish keeps its own name
  end if;

  v_display := public.dish_title(v_name);

  begin
    insert into public.dishes (name, restaurant_id, created_by_user_id)
    values (v_display, p_restaurant_id, p_created_by)
    returning id into v_id;
  exception when unique_violation then
    -- lost the race against a concurrent creator: take theirs.
    select d.id into v_id
    from public.dishes d
    where d.restaurant_id = p_restaurant_id
      and lower(d.name) = lower(v_name)
      and d.merged_into_dish_id is null
    limit 1;
  end;

  return v_id;
end; $$;

comment on function public.find_or_create_dish(uuid, text, uuid) is
  'Select-then-insert the live dish (restaurant_id, lower(name)), normalising the DISPLAY name on create only (trim, collapse whitespace, title case via dish_title). NEVER ON CONFLICT — dishes_identity_uq is partial by design (0014/0016).';

revoke all on function public.find_or_create_dish(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.find_or_create_dish(uuid, text, uuid) to service_role;

create or replace function public.add_own_save(
  p_dish_name      text,
  p_restaurant_id  uuid,
  p_source         text default 'manual',
  p_source_url     text default null,
  p_source_author  text default null,
  p_source_caption text default null
)
returns uuid
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid  uuid := (select auth.uid());
  v_name text := btrim(regexp_replace(coalesce(p_dish_name, ''), '\s+', ' ', 'g'));
  v_url  text := nullif(btrim(coalesce(p_source_url, '')), '');
  v_id   uuid;
begin
  if v_uid is null then
    raise exception 'sign in to save' using errcode = '42501';
  end if;
  if char_length(v_name) not between 1 and 120 then
    raise exception 'dish_name' using errcode = '22023';
  end if;
  if not exists (select 1 from public.restaurants r where r.id = p_restaurant_id) then
    raise exception 'place not found' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('own_saves:' || v_uid::text, 0));
  if (select count(*) from public.own_saves o where o.user_id = v_uid) >= 500 then
    raise exception 'own_save_cap' using errcode = '54000';
  end if;
  -- Printed the way every dish name is (find_or_create_dish): title case.
  v_name := public.dish_title(v_name);
  insert into public.own_saves (user_id, dish_name, restaurant_id, source, source_url, source_author, source_caption)
  values (
    v_uid, v_name, p_restaurant_id, coalesce(nullif(btrim(p_source), ''), 'manual'), v_url,
    left(nullif(btrim(coalesce(p_source_author, '')), ''), 100),
    left(nullif(btrim(coalesce(p_source_caption, '')), ''), 2200)
  )
  returning id into v_id;
  return v_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Backfill: what is already stored prints the same way. Case only (see dish_title).
-- ---------------------------------------------------------------------------
update public.dishes d
set name = public.dish_title(d.name)
where d.name is distinct from public.dish_title(d.name);

update public.own_saves o
set dish_name = public.dish_title(o.dish_name)
where o.dish_name is distinct from public.dish_title(o.dish_name);
