-- 0061_own_saves.sql
-- Ate backend — YOUR OWN SAVED DISHES (Eamon, 11 Oct 2026: the beta Saved). DRAFT — authored and tested
-- locally (PGlite); lands through a PR like every migration.
--
-- WHAT. Saved holds dishes you want to eat wherever you found them. A save FROM ATE is a `saves` row
--   (0020): a catalogue dish somebody reviewed, with its score. A save of YOUR OWN is a row here: a dish
--   name you typed (or Ate read off a TikTok / Instagram post you shared to it), at a real place, and
--   optionally the link it came from. The Saved list shows both, newest first; the table a row comes from
--   IS the distinction ("from Ate" vs "your own"), and `source` says where your own came from.
--
-- WHY A NEW TABLE, NOT A NULLABLE `saves.dish_id`. `saves` is keyed (user_id, dish_id) and read by
--   my_saved_dishes, search_saved, my_saved_cities, the Saved filters and the bookmark everywhere a dish
--   is drawn; every one of those assumes a catalogue dish with numbers. An own save has NO dish row on
--   purpose: the catalogue only ever holds what somebody actually ate and reviewed (scores are never
--   inferred), so a wish never mints a dish. Keeping it apart leaves every existing read untouched.
--
-- THE PLACE IS REAL. restaurant_id is NOT NULL: the app picks it through the same place sheet the
--   composer uses (a Google prediction becomes a row first; "Add a new place" makes a manual one), so a
--   saved dish always points at a place and none is ever guessed (design rule 8).
--
-- DONE WHEN EATEN. "I ate it" opens the composer on the place and the dish's name; once that entry is
--   saved the app removes the own save (remove_own_save). Nothing server-side ties them: an entry about
--   a dish you never saved, or a save you never review, are both normal.
--
-- ─── Storage (RLS: owner SELECT only; NO client write grant — the two RPCs below write)
--   own_saves (id, user_id, dish_name, restaurant_id, source, source_url, source_author, source_caption,
--     created_at). ≤ 500 per user. dish_name trimmed, 1–120. source ∈ manual | tiktok | instagram | link.
--     source_url https only, ≤ 2048. author ≤ 100, caption ≤ 2200 (Instagram's own caption cap).
--
-- ─── Reads / RPCs (signed in only)
--   my_own_saves (view, security_invoker) — the caller's rows with the place's name, city and locality.
--   add_own_save(p_dish_name, p_restaurant_id, p_source, p_source_url, p_source_author, p_source_caption)
--     → the new row's id. remove_own_save(p_id) → 1 removed · 0 already gone or not yours.
--
-- WIRE IMPACT: ADDITIVE — one table, one view, two RPCs. Nothing existing changes. delete_account needs
--   no change: the row cascades with the profile.

set search_path = public, extensions;

-- ===========================================================================
-- 1. Table.
-- ===========================================================================
create table if not exists public.own_saves (
  id             uuid        primary key default gen_random_uuid(),
  user_id        uuid        not null references public.profiles(id)    on delete cascade,
  dish_name      text        not null,
  restaurant_id  uuid        not null references public.restaurants(id) on delete cascade,
  source         text        not null default 'manual',
  source_url     text,
  source_author  text,
  source_caption text,
  created_at     timestamptz not null default now(),
  constraint own_saves_dish_name_ck check (dish_name = btrim(dish_name) and char_length(dish_name) between 1 and 120),
  constraint own_saves_source_ck    check (source in ('manual', 'tiktok', 'instagram', 'link')),
  constraint own_saves_url_ck       check (source_url is null or (source_url ~* '^https://' and char_length(source_url) <= 2048)),
  constraint own_saves_author_ck    check (source_author is null or char_length(source_author) <= 100),
  constraint own_saves_caption_ck   check (source_caption is null or char_length(source_caption) <= 2200)
);

comment on table public.own_saves is
  'A user''s own saved dishes: a typed dish name at a real place, optionally from a TikTok / Instagram / web link. No dish row, no score. Private to the owner. Written only by add_own_save / remove_own_save.';

create index if not exists own_saves_user_idx on public.own_saves (user_id, created_at desc, id desc);
create index if not exists own_saves_restaurant_idx on public.own_saves (restaurant_id);

alter table public.own_saves enable row level security;

drop policy if exists own_saves_select_own on public.own_saves;
create policy own_saves_select_own on public.own_saves
  for select to authenticated using (user_id = (select auth.uid()));

revoke all on public.own_saves from anon, authenticated;
grant select on public.own_saves to authenticated;
grant all on public.own_saves to service_role;

-- ===========================================================================
-- 2. The read: my_own_saves.
-- ===========================================================================
create or replace view public.my_own_saves
with (security_invoker = true) as
  select
    o.id,
    o.dish_name,
    r.id                                     as restaurant_id,
    r.name                                   as restaurant_name,
    nullif(btrim(coalesce(r.city, '')), '')  as restaurant_city,
    public.place_locality(r.address, r.city) as restaurant_locality,
    o.source,
    o.source_url,
    o.source_author,
    o.source_caption,
    o.created_at
  from public.own_saves o
  join public.restaurants r on r.id = o.restaurant_id
  where o.user_id = (select auth.uid());

comment on view public.my_own_saves is
  'The caller''s own saved dishes with their place. Order by created_at desc, id desc.';

revoke all on public.my_own_saves from anon;
grant select on public.my_own_saves to authenticated;

-- ===========================================================================
-- 3. Writes.
-- ===========================================================================
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
  v_name text := btrim(coalesce(p_dish_name, ''));
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
  insert into public.own_saves (user_id, dish_name, restaurant_id, source, source_url, source_author, source_caption)
  values (
    v_uid, v_name, p_restaurant_id, coalesce(nullif(btrim(p_source), ''), 'manual'), v_url,
    left(nullif(btrim(coalesce(p_source_author, '')), ''), 100),
    left(nullif(btrim(coalesce(p_source_caption, '')), ''), 2200)
  )
  returning id into v_id;
  return v_id;
end; $$;

-- 1 removed · 0 already gone or not yours (treat as done).
create or replace function public.remove_own_save(p_id uuid)
returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
  v_n   int;
begin
  if v_uid is null then
    raise exception 'sign in to save' using errcode = '42501';
  end if;
  delete from public.own_saves o where o.id = p_id and o.user_id = v_uid;
  get diagnostics v_n = row_count;
  return v_n;
end; $$;

revoke all on function public.add_own_save(text, uuid, text, text, text, text) from public, anon;
revoke all on function public.remove_own_save(uuid) from public, anon;
grant execute on function public.add_own_save(text, uuid, text, text, text, text) to authenticated;
grant execute on function public.remove_own_save(uuid) to authenticated;
