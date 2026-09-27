-- supabase/staging-seed/setup.sql — STAGING ONLY. Never a migration; never run on prod.
--
-- Creates the `staging_seed` schema: the provenance registry for the round-6 dummy dataset and the
-- helpers that insert it. Everything the seed creates is recorded here, so remove.sql can take exactly
-- that back out and nothing else. PostgREST does not expose this schema; the API roles get no access.
--
-- The guard refuses to run anywhere but staging (cvoitgoaosofkougmarn): the staging demo account's
-- fixed id must exist, photo URLs must point at the staging project, and none may point at prod.

create schema if not exists staging_seed;
revoke all on schema staging_seed from public, anon, authenticated;

create or replace function staging_seed.assert_staging()
returns void
language plpgsql
as $$
begin
  if not exists (select 1 from auth.users
                  where id = '3e801ac3-88ab-4763-a686-aeab9b79c624' and email = 'eamon@ate.test')
     or not exists (select 1 from public.entry_photos
                     where photo_url like 'https://cvoitgoaosofkougmarn.supabase.co/%')
     or exists (select 1 from public.entry_photos
                 where photo_url like 'https://vyaexmnajnbryimbkgkf.supabase.co/%') then
    raise exception 'staging_seed: this database is not STAGING (cvoitgoaosofkougmarn) — refusing';
  end if;
end;
$$;

select staging_seed.assert_staging();

-- What the seed made. `tbl` ∈ users · restaurants · entries. Saves by seeded users go with the users;
-- saves made in Eamon's name are listed separately (his real saves are never in here).
create table if not exists staging_seed.registry (
  tbl   text not null check (tbl in ('users', 'restaurants', 'entries')),
  id    uuid not null,
  batch text not null default 'r6',
  primary key (tbl, id)
);
create table if not exists staging_seed.saves (
  user_id uuid not null,
  dish_id uuid not null,
  batch   text not null default 'r6',
  primary key (user_id, dish_id)
);

-- Photos already in staging storage from the earlier demo seed: @ate.test folders only (never a real
-- account's), optionally excluding one folder — an author must never be handed a photo from their
-- OWN folder, or deleting the synthetic entry in the app would delete a file their real entry uses.
create or replace function staging_seed.photo_pool(p_exclude_folder text)
returns text[]
language sql
stable
as $$
  select coalesce(array_agg('https://cvoitgoaosofkougmarn.supabase.co/storage/v1/object/public/review-photos/' || o.name
                            order by o.name), '{}')
  from storage.objects o
  where o.bucket_id = 'review-photos'
    and o.name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}-[0-9]+\.jpg$'
    and split_part(o.name, '/', 1) in (select u.id::text from auth.users u where u.email like '%@ate.test')
    and split_part(o.name, '/', 1) is distinct from p_exclude_folder;
$$;

-- A demo account: auth user (+ email identity, password atedemo123) → handle_new_user makes the profile.
create or replace function staging_seed.put_user(j jsonb)
returns void
language plpgsql
as $$
declare
  v_id uuid := (j ->> 'id')::uuid;
  v_at timestamptz := (j ->> 'created_at')::timestamptz;
begin
  if exists (select 1 from auth.users where id = v_id) then
    insert into staging_seed.registry (tbl, id) values ('users', v_id) on conflict do nothing;
    return;
  end if;
  insert into auth.users
    (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
     raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token, email_change_token_new, email_change)
  values
    ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', j ->> 'email',
     extensions.crypt('atedemo123', extensions.gen_salt('bf')), v_at, v_at, v_at,
     '{"provider":"email","providers":["email"]}',
     jsonb_build_object('name', j ->> 'name', 'username', j ->> 'username'),
     '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  values (v_id, v_id, v_id::text, 'email',
          jsonb_build_object('sub', v_id::text, 'email', j ->> 'email', 'email_verified', true),
          v_at, v_at, v_at);
  insert into staging_seed.registry (tbl, id) values ('users', v_id) on conflict do nothing;
  update public.profiles
     set bio = j ->> 'bio', city = j ->> 'city', avatar_url = j ->> 'avatar_url', created_at = v_at
   where id = v_id;
end;
$$;

create or replace function staging_seed.put_restaurant(j jsonb)
returns void
language plpgsql
as $$
begin
  insert into public.restaurants (id, google_place_id, source, name, address, city, cuisine, location, created_at)
  values ((j ->> 'id')::uuid, j ->> 'google_place_id', 'places', j ->> 'name', j ->> 'address', j ->> 'city',
          j ->> 'cuisine',
          extensions.ST_SetSRID(extensions.ST_MakePoint((j ->> 'lng')::float8, (j ->> 'lat')::float8), 4326)::geography,
          (j ->> 'created_at')::timestamptz)
  on conflict (id) do nothing;
  insert into staging_seed.registry (tbl, id) values ('restaurants', (j ->> 'id')::uuid) on conflict do nothing;
end;
$$;

-- An entry exactly as the app + sorter make one: INSERT (the trigger numbers it and stamps the place
-- 'user'), then the sorter's own SQL write path, apply_entry_sort — which validates every score,
-- note and offset against the words — then photo rows. No model call.
create or replace function staging_seed.put_entry(j jsonb)
returns void
language plpgsql
as $$
declare
  v_id     uuid := (j ->> 'id')::uuid;
  v_author uuid := coalesce((j ->> 'author')::uuid,
                            (select id from auth.users where email = j ->> 'author_email'));
  v_pool   text[];
  v_pick   jsonb;
  v_pos    int := 0;
begin
  if v_author is null then
    raise exception 'staging_seed: unknown author in %', j;
  end if;
  if exists (select 1 from public.entries where id = v_id) then
    return;
  end if;
  insert into public.entries (id, author_id, body, restaurant_id, created_at)
  values (v_id, v_author, j ->> 'body', (j ->> 'restaurant')::uuid, (j ->> 'created_at')::timestamptz);
  insert into staging_seed.registry (tbl, id) values ('entries', v_id) on conflict do nothing;
  perform public.apply_entry_sort(
    p_entry_id => v_id, p_restaurant_id => (j ->> 'restaurant')::uuid, p_items => j -> 'items',
    p_mode => 'stub', p_place_query => j ->> 'place_query',
    p_place_offset => (j ->> 'place_offset')::int, p_meta => null);
  if jsonb_array_length(coalesce(j -> 'photos', '[]')) > 0 then
    v_pool := staging_seed.photo_pool(v_author::text);
    if cardinality(v_pool) > 0 then
      for v_pick in select * from jsonb_array_elements(j -> 'photos') loop
        insert into public.entry_photos (entry_id, position, photo_url, created_at)
        values (v_id, v_pos, v_pool[((v_pick::text)::int % cardinality(v_pool)) + 1], (j ->> 'created_at')::timestamptz)
        on conflict do nothing;
        v_pos := v_pos + 1;
      end loop;
    end if;
  end if;
end;
$$;

-- A save of a dish some seeded entry printed, credited to that entry and its author.
create or replace function staging_seed.put_save(j jsonb)
returns void
language plpgsql
as $$
declare
  v_user  uuid := coalesce((j ->> 'user')::uuid, (select id from auth.users where email = j ->> 'user_email'));
  v_dish  uuid;
  v_src   uuid := (j ->> 'source_entry')::uuid;
  v_by    uuid;
begin
  select d.id into v_dish from public.dishes d
   where d.restaurant_id = (j ->> 'restaurant')::uuid and lower(d.name) = lower(j ->> 'dish_name')
     and d.merged_into_dish_id is null
   limit 1;
  select e.author_id into v_by from public.entries e where e.id = v_src;
  if v_dish is null or v_user is null or v_by is null then
    return;
  end if;
  if exists (select 1 from public.saves where user_id = v_user and dish_id = v_dish) then
    return;                                  -- never touch a save that is already there
  end if;
  insert into public.saves (user_id, dish_id, source_entry_id, source_user_id, created_at)
  values (v_user, v_dish, v_src, v_by, (j ->> 'at')::timestamptz);
  if not exists (select 1 from staging_seed.registry where tbl = 'users' and id = v_user) then
    insert into staging_seed.saves (user_id, dish_id) values (v_user, v_dish) on conflict do nothing;
  end if;
end;
$$;

revoke all on all functions in schema staging_seed from public, anon, authenticated;
revoke all on all tables in schema staging_seed from public, anon, authenticated;
