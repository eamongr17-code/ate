-- 0101 — Photos move to Cloudflare R2 (Nov 2026).
--
-- Why: Supabase Free serves 5 GB of downloads a month, and every photo view is a download. R2 charges
-- nothing for downloads. The photos Worker (cloudflare/photos) sits on photos.<domain>: it serves reads
-- from R2 at the edge, takes uploads only from a signed-in account into its own folder (JPEG/PNG by
-- their bytes, 10 MB / 5 MB), and purges a deleted account's folders for delete-account.
--
-- What this adds:
--   1. photo_storage: one row, `base` = the Worker's URL (https://photos.<domain>/), or null = Supabase
--      Storage as before. The apps read it (photo_storage_config) and upload wherever it says, so the
--      cutover and any rollback are one row, set by .github/scripts/photos_setup.sh, never a new build.
--   2. storage_url_ok (0094) accepts <base><bucket>/<safe path> beside the Supabase URLs.
--   3. delete_entry (0037) reads the bucket path out of an R2 URL too; set_list_cover (0073) now
--      checks the host as well as the owner's folder (it accepted any host before).
--   4. move_photo_urls: after the setup script has copied files into R2 and checked each one, the
--      rows that name them switch to the R2 URL in one transaction. Only keys the script verified move;
--      a file never copied keeps its working Supabase URL. Supabase's copies stay as the rollback.
--
-- Grants are explicit (0100: new objects are closed by default). Nothing here deletes data.

set search_path = public, extensions;

-- ===========================================================================
-- 1. The switch
-- ===========================================================================
create table if not exists public.photo_storage (
  id         boolean     primary key default true check (id),
  base       text        check (base is null or base ~ '^https://[a-z0-9.-]+\.[a-z]{2,}/$'),
  updated_at timestamptz not null default now()
);
insert into public.photo_storage (id, base) values (true, null) on conflict (id) do nothing;

alter table public.photo_storage enable row level security;
revoke all on public.photo_storage from public, anon, authenticated;
grant select, insert, update on public.photo_storage to service_role;

comment on table public.photo_storage is
  '0101: where new photos go. base = the photos Worker (https://photos.<domain>/), null = Supabase Storage. One row; set by photos_setup.sh.';

create or replace function public.photo_base()
returns text language sql stable security definer set search_path = public, extensions as $$
  select s.base from public.photo_storage s where s.id
$$;
revoke all on function public.photo_base() from public, anon, authenticated;
grant execute on function public.photo_base() to anon, authenticated, service_role;

-- What the apps ask before an upload: {"base": "https://photos.<domain>/" | null}.
create or replace function public.photo_storage_config()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('base', public.photo_base())
$$;
revoke all on function public.photo_storage_config() from public, anon, authenticated;
grant execute on function public.photo_storage_config() to anon, authenticated, service_role;

create or replace function public.photo_storage_set(p_base text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  update public.photo_storage s set base = nullif(btrim(coalesce(p_base, '')), ''), updated_at = now() where s.id;
  return public.photo_storage_config();
end; $$;
revoke all on function public.photo_storage_set(text) from public, anon, authenticated;
grant execute on function public.photo_storage_set(text) to service_role;

-- `https://photos.x/review-photos/u/e-0.jpg?v=1` → `u/e-0.jpg` when the URL is on the current base and in
-- that bucket; null otherwise.
create or replace function public.photo_key_path(p_url text, p_bucket text)
returns text language sql stable security definer set search_path = public, extensions as $$
  select nullif(split_part(split_part(substr(p_url, char_length(b.prefix) + 1), '#', 1), '?', 1), '')
  from (select public.photo_base() || p_bucket || '/' as prefix) b
  where b.prefix is not null and starts_with(p_url, b.prefix)
$$;
revoke all on function public.photo_key_path(text, text) from public, anon, authenticated;
grant execute on function public.photo_key_path(text, text) to anon, authenticated, service_role;

-- ===========================================================================
-- 2. Client-written image URLs: our Supabase storage, or our R2 base (0094 + R2)
-- ===========================================================================
create or replace function public.storage_url_ok(p_url text, p_bucket text)
returns boolean language sql stable set search_path = public, extensions as $$
  select p_url is null or (
    char_length(p_url) <= 2048
    and p_url !~ '\.\.'
    and (
      p_url ~ ('^(https://(cvoitgoaosofkougmarn|vyaexmnajnbryimbkgkf)\.supabase\.co'
               || '|http://(127\.0\.0\.1|localhost):54321)/storage/v1/object/public/'
               || p_bucket || '/[A-Za-z0-9._/-]+(\?[A-Za-z0-9=&._-]*)?$')
      or (public.photo_base() is not null
          and starts_with(p_url, public.photo_base() || p_bucket || '/')
          and substr(p_url, char_length(public.photo_base() || p_bucket || '/') + 1)
              ~ '^[A-Za-z0-9._/-]+(\?[A-Za-z0-9=&._-]*)?$')
    )
  )
$$;
revoke all on function public.storage_url_ok(text, text) from public;
grant execute on function public.storage_url_ok(text, text) to anon, authenticated, service_role;

-- ===========================================================================
-- 3. delete_entry and set_list_cover know R2 URLs
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.delete_entry(p_entry_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $$
declare
  v_uid     uuid := (select auth.uid());
  v_author  uuid;
  v_paths   text[];
  v_deleted int;
begin
  if v_uid is null then
    raise exception 'delete_entry requires an authenticated caller' using errcode = '42501';
  end if;

  -- Lock the row so a concurrent sort/correction cannot write lines under an entry mid-delete.
  select e.author_id into v_author
  from public.entries e
  where e.id = p_entry_id
  for update;

  if not found then
    raise exception 'entry % not found', p_entry_id using errcode = 'P0002';
  end if;
  if v_author <> v_uid then
    raise exception 'delete_entry: not your entry' using errcode = '42501';
  end if;

  -- The files, read BEFORE the rows that name them go.
  with urls as (
    select x.photo_url as url
    from public.entry_photos x
    where x.entry_id = p_entry_id
    union
    select v.photo_url
    from public.reviews v
    where v.entry_id = p_entry_id and v.photo_url is not null
  ),
  unshared as (
    -- a URL another entry or line still prints is not ours to purge
    select u.url
    from urls u
    where not exists (
            select 1 from public.entry_photos o
            where o.photo_url = u.url and o.entry_id <> p_entry_id)
      and not exists (
            select 1 from public.reviews o
            where o.photo_url = u.url and o.entry_id is distinct from p_entry_id)
  ),
  originals as (
    -- 0101: a photo on R2 (photos.<domain>/review-photos/<path>) names the same bucket path
    select coalesce(
             (regexp_match(
                u.url,
                '/storage/v1/object/(?:public|sign|authenticated)/review-photos/([^?#]+)'
             ))[1],
             public.photo_key_path(u.url, 'review-photos')) as path
    from unshared u
  ),
  mine as (
    select o.path
    from originals o
    where o.path is not null
      and o.path like v_uid::text || '/%'
      and position('..' in o.path) = 0
  ),
  both_sizes as (
    select m.path from mine m
    union
    select regexp_replace(m.path, '\.[^./]*$', '') || '_t.jpg'
    from mine m
    where m.path !~ '_t\.jpg$'
  )
  select coalesce(array_agg(b.path order by b.path), '{}'::text[])
    into v_paths
  from both_sizes b;

  -- The rows. Every dependent goes by FK cascade (header); the catalogue stays.
  delete from public.entries where id = p_entry_id;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 1 then
    raise exception 'delete_entry: entry % was not deleted', p_entry_id using errcode = 'P0001';
  end if;

  return jsonb_build_object('photo_paths', to_jsonb(v_paths));
end; $$;
CREATE OR REPLACE FUNCTION public.set_list_cover(p_list_id uuid, p_item_id uuid DEFAULT NULL::uuid, p_photo_url text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $$
declare
  v_list public.user_lists := public.list_own(p_list_id);
  v_url  text := nullif(btrim(coalesce(p_photo_url, '')), '');
begin
  if p_item_id is not null and v_url is not null then
    raise exception 'one cover at a time' using errcode = '22023';
  end if;
  if p_item_id is not null and not exists (
    select 1 from public.user_list_items i
    where i.id = p_item_id and i.list_id = v_list.id and public.list_item_photo(i.entry_id, i.dish_id) is not null
  ) then
    raise exception 'cover_item_not_found' using errcode = 'P0002';
  end if;
  if v_url is not null and (
       char_length(v_url) > 500
       -- 0101: our storage only (Supabase or R2), and the owner's own list-covers folder
       or not public.storage_url_ok(v_url, 'review-photos')
       or coalesce((regexp_match(v_url, '/storage/v1/object/public/review-photos/([^?#]+)'))[1],
                   public.photo_key_path(v_url, 'review-photos'), '')
          !~ ('^' || v_list.owner_id::text || '/list-covers/[A-Za-z0-9._-]+$')) then
    raise exception 'bad_cover_url' using errcode = '22023';
  end if;
  update public.user_lists l set cover_item_id = p_item_id, cover_url = v_url, updated_at = now()
  where l.id = v_list.id;
  return jsonb_build_object('list_id', v_list.id, 'cover_item_id', p_item_id,
                            'cover_url', public.list_cover(v_list.id));
end; $$;
revoke all on function public.delete_entry(uuid) from public, anon;
grant execute on function public.delete_entry(uuid) to authenticated;
revoke all on function public.set_list_cover(uuid, uuid, text) from public, anon;
grant execute on function public.set_list_cover(uuid, uuid, text) to authenticated;

-- ===========================================================================
-- 4. Moving rows to R2, only for files the setup script copied and checked
-- ===========================================================================
-- p_from: the Supabase public prefix (https://<ref>.supabase.co/storage/v1/object/public/).
-- p_keys: bucket-qualified keys now in R2 (review-photos/<uid>/x.jpg). Each URL keeps its ?v= buster.
-- Every column that names a photo moves in one transaction. The triggers that would stamp updated_at
-- (feeds, the sort-staleness hint) or forget photo_also are paused for it: the photo is the same photo.
-- Idempotent: a second run finds nothing left on p_from for those keys.
create or replace function public.move_photo_urls(p_from text, p_keys text[])
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_to    text := public.photo_base();
  v_moved jsonb := '{}'::jsonb;
  v_n     int;
begin
  if v_to is null then raise exception 'photo_storage.base is not set' using errcode = '22023'; end if;
  if p_from !~ '^https?://[^/]+/storage/v1/object/public/$' then
    raise exception 'p_from must be a Supabase public storage prefix' using errcode = '22023';
  end if;
  if coalesce(cardinality(p_keys), 0) = 0 then return v_moved; end if;

  create temp table if not exists _photo_moves (old text primary key, new text not null) on commit drop;
  truncate _photo_moves;

  -- every URL in any photo column that starts with p_from and whose key was verified
  insert into _photo_moves (old, new)
  select u, v_to || substr(u, char_length(p_from) + 1)
  from (
    select photo_url u from public.entry_photos union
    select photo_url from public.photo_dishes union
    select photo_url from public.reviews union
    select avatar_url from public.profiles union
    select cover_url from public.user_lists union
    select cover_url from public.lists union
    select photo_url from public.dishes union
    select cover_url from public.restaurants union
    select jsonb_object_keys(photo_picks) from public.entries where photo_picks <> '{}'::jsonb union
    select jsonb_object_keys(photo_also) from public.entries where photo_also <> '{}'::jsonb
  ) x
  where u is not null and starts_with(u, p_from)
    and split_part(split_part(substr(u, char_length(p_from) + 1), '#', 1), '?', 1) = any (p_keys)
  on conflict do nothing;

  if not exists (select 1 from _photo_moves) then return v_moved; end if;

  alter table public.entries disable trigger entries_biu;
  alter table public.entries disable trigger entries_photo_also_forget;
  alter table public.reviews disable trigger reviews_set_restaurant_biu;

  update public.entry_photos t set photo_url = m.new from _photo_moves m where t.photo_url = m.old;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('entry_photos', v_n);
  update public.photo_dishes t set photo_url = m.new from _photo_moves m where t.photo_url = m.old;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('photo_dishes', v_n);
  update public.reviews t set photo_url = m.new from _photo_moves m where t.photo_url = m.old;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('reviews', v_n);
  update public.profiles t set avatar_url = m.new from _photo_moves m where t.avatar_url = m.old;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('profiles', v_n);
  update public.user_lists t set cover_url = m.new from _photo_moves m where t.cover_url = m.old;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('user_lists', v_n);
  update public.lists t set cover_url = m.new from _photo_moves m where t.cover_url = m.old;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('lists', v_n);
  update public.dishes t set photo_url = m.new from _photo_moves m where t.photo_url = m.old;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('dishes', v_n);
  update public.restaurants t set cover_url = m.new from _photo_moves m where t.cover_url = m.old;
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('restaurants', v_n);

  update public.entries e
     set photo_picks = (select coalesce(jsonb_object_agg(coalesce(m.new, k.key), k.value), '{}'::jsonb)
                        from jsonb_each(e.photo_picks) k left join _photo_moves m on m.old = k.key),
         photo_also  = (select coalesce(jsonb_object_agg(coalesce(m.new, k.key), k.value), '{}'::jsonb)
                        from jsonb_each(e.photo_also) k left join _photo_moves m on m.old = k.key)
   where exists (select 1 from jsonb_object_keys(e.photo_picks) k join _photo_moves m on m.old = k)
      or exists (select 1 from jsonb_object_keys(e.photo_also) k join _photo_moves m on m.old = k);
  get diagnostics v_n = row_count; v_moved := v_moved || jsonb_build_object('entries', v_n);

  alter table public.entries enable trigger entries_biu;
  alter table public.entries enable trigger entries_photo_also_forget;
  alter table public.reviews enable trigger reviews_set_restaurant_biu;

  return v_moved;
end; $$;
revoke all on function public.move_photo_urls(text, text[]) from public, anon, authenticated;
grant execute on function public.move_photo_urls(text, text[]) to service_role;

-- What the setup script copies: every Supabase-hosted photo the database names, as bucket keys.
create or replace function public.photo_keys_on_supabase(p_from text)
returns setof text language sql stable security definer set search_path = public, extensions as $$
  select distinct split_part(split_part(substr(u, char_length(p_from) + 1), '#', 1), '?', 1)
  from (
    select photo_url u from public.entry_photos union
    select photo_url from public.photo_dishes union
    select photo_url from public.reviews union
    select avatar_url from public.profiles union
    select cover_url from public.user_lists union
    select cover_url from public.lists union
    select photo_url from public.dishes union
    select cover_url from public.restaurants union
    select jsonb_object_keys(photo_picks) from public.entries where photo_picks <> '{}'::jsonb union
    select jsonb_object_keys(photo_also) from public.entries where photo_also <> '{}'::jsonb
  ) x
  where u is not null and starts_with(u, p_from)
$$;
revoke all on function public.photo_keys_on_supabase(text) from public, anon, authenticated;
grant execute on function public.photo_keys_on_supabase(text) to service_role;
