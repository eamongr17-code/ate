-- 0062 — own saves print their dish name with a capital (13 Oct beta).
--
-- A dish typed into Saved, or read off a shared post, was stored exactly as it arrived
-- ("margherita"), while every dish an entry prints is capitalised on create (0024). Same rule
-- here: whitespace collapsed, first letter capital, the rest as written ("Big Mac" stays).
-- New saves only; existing rows are left as they are.

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
  -- Printed the way every dish name is (find_or_create_dish, 0024): the first letter capital.
  v_name := upper(substr(v_name, 1, 1)) || substr(v_name, 2);
  insert into public.own_saves (user_id, dish_name, restaurant_id, source, source_url, source_author, source_caption)
  values (
    v_uid, v_name, p_restaurant_id, coalesce(nullif(btrim(p_source), ''), 'manual'), v_url,
    left(nullif(btrim(coalesce(p_source_author, '')), ''), 100),
    left(nullif(btrim(coalesce(p_source_caption, '')), ''), 2200)
  )
  returning id into v_id;
  return v_id;
end; $$;

