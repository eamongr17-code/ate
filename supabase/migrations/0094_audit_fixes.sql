-- 0094_audit_fixes.sql
--
-- The independent audit (26 Oct, https://claude.ai/artifact/8aGPNWbA48M9Je6L58yBDm), database half.
-- Numbers are the report's. Every attack here was reproduced against the chain before this file and
-- is refused after it (supabase/tests/db/audit_fixes_test.mjs).
--
--    1. reviews: the app never writes a line itself (the sorter and the definer RPCs do); it only
--       PATCHes a line's tags. So authenticated loses INSERT / DELETE and keeps UPDATE (tags) only,
--       and the insert policy no longer admits a line with no entry. Closes fake loose 6s on anyone's
--       dish, and (4) the two-sixes bypass that moved a loose 6 onto an entry.
--    2. dishes: created only by find_or_create_dish (definer) and the service role. authenticated loses
--       INSERT / UPDATE / DELETE, so nobody can plant a dish whose merged_into_dish_id hijacks matching.
--    4. The two-sixes trigger also runs when a line's entry changes (defence in depth for 1).
--    5. delete_account queues the account's storage folders for the delete-account function, which
--       purges them after the rows are gone (storage is deleted through the Storage API, not SQL).
--    9. List invites spend the ate-with day budget (40 tags + invites + list invites a rolling day).
--   13. Client-written photo / avatar URLs must be this project's public storage (any host check that
--       a seed or the service role writes is skipped: only anon / authenticated writes are checked).
--   15. Hand-added places: 20 a day per account and length caps. Reports: one open report per
--       reporter per target (a repeat returns the first), 30 a day.
--   16. profiles.diet is the owner's alone: no client role can SELECT it; my_diet() reads your own.
--   17. A push token already registered to someone else only moves when that row is stale (7 days).
--   23. Pairs the dish-dedup model judged apart are remembered (dish_pair_verdicts), never asked again.
--   24. A failed photo match on an entry is recorded (photos_match_tried_at); a viewer's look does not
--       retry it for a day.
--   27. Text caps on dish names, hand-added place fields and review notes (NOT VALID: new writes only).
--   28. The unused V1-social tables lose client SELECT too (0093 took their writes).

-- ===========================================================================
-- 1 + 4. reviews: lines come from the server; the client edits tags only
-- ===========================================================================
revoke insert, update, delete on public.reviews from authenticated;
grant update (tags) on public.reviews to authenticated;

drop policy if exists reviews_insert_author on public.reviews;
create policy reviews_insert_author on public.reviews
  for insert to authenticated
  with check (
    reviewer_id = (select auth.uid())
    and entry_id is not null
    and exists (select 1 from public.entries e where e.id = entry_id and e.author_id = (select auth.uid()))
  );

drop policy if exists reviews_delete_author on public.reviews;

create or replace function public.trg_review_two_sixes()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_author  uuid;
  v_held    int;
  v_granted int;
  v_used    int;
begin
  if new.score is distinct from 6 then return new; end if;
  -- a 6 that stays on the same entry was already counted; a 6 moving onto an entry is a new one
  if tg_op = 'UPDATE' and old.score = 6 and old.entry_id is not distinct from new.entry_id then return new; end if;
  if new.entry_id is null then return new; end if;

  select e.author_id into v_author from public.entries e where e.id = new.entry_id;
  if v_author is null then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended('two_sixes:' || v_author::text, 0));

  -- A carry: the entry already holds fewer 6s than it was granted.
  select count(*)::int into v_held
  from public.reviews r
  where r.entry_id = new.entry_id and r.score = 6 and r.id <> new.id;
  select g.granted into v_granted from public.six_grants g where g.entry_id = new.entry_id;
  if v_held < coalesce(v_granted, 0) then return new; end if;

  -- New: two in any two months.
  select coalesce(sum(g.granted), 0)::int into v_used
  from public.six_grants g
  where g.author_id = v_author and g.first_at > now() - interval '2 months';
  if v_used >= 2 then
    new.score := 5.0;
    return new;
  end if;

  insert into public.six_grants (entry_id, author_id, granted)
  values (new.entry_id, v_author, 1)
  on conflict (entry_id) do update set granted = public.six_grants.granted + 1;
  return new;
end; $$;

drop trigger if exists reviews_two_sixes on public.reviews;
create trigger reviews_two_sixes
  before insert or update of score, entry_id on public.reviews
  for each row execute function public.trg_review_two_sixes();

revoke execute on function public.trg_review_two_sixes() from public, anon, authenticated;

-- ===========================================================================
-- 2. dishes: server-created only
-- ===========================================================================
revoke insert, update, delete on public.dishes from authenticated;
drop policy if exists dishes_insert_authed on public.dishes;

-- ===========================================================================
-- 5. delete_account: queue the storage purge in the same transaction as the delete
-- ===========================================================================
create table if not exists public.storage_purge_queue (
  user_id   uuid        primary key,          -- no FK: the account is gone by the time this is read
  queued_at timestamptz not null default now(),
  attempts  integer     not null default 0
);

comment on table public.storage_purge_queue is
  '0094: deleted accounts whose storage folders (review-photos/<uid>/, avatars/<uid>/) the delete-account function still has to empty. Server-internal: service_role only.';

alter table public.storage_purge_queue enable row level security;
revoke all on public.storage_purge_queue from public, anon, authenticated;
grant select, insert, update, delete on public.storage_purge_queue to service_role;

create or replace function public.delete_account()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_deleted int;
begin
  if v_uid is null then
    raise exception 'delete_account requires an authenticated caller' using errcode = '42501';
  end if;

  delete from auth.users where id = v_uid;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 1 then
    raise exception 'delete_account: no auth user % to delete', v_uid using errcode = 'P0002';
  end if;

  if exists (select 1 from public.profiles       where id = v_uid)
  or exists (select 1 from public.entries        where author_id = v_uid)
  or exists (select 1 from public.reviews        where reviewer_id = v_uid)
  or exists (select 1 from public.saves          where user_id = v_uid)
  or exists (select 1 from public.blocks         where blocker_id = v_uid or blocked_id = v_uid)
  or exists (select 1 from public.reports        where reporter_id = v_uid or profile_id = v_uid)
  or exists (select 1 from public.comments       where user_id = v_uid)
  or exists (select 1 from public.lists          where owner_id = v_uid)
  or exists (select 1 from public.follows        where follower_id = v_uid or followee_id = v_uid)
  or exists (select 1 from public.review_likes   where user_id = v_uid)
  or exists (select 1 from public.comment_likes  where user_id = v_uid)
  or exists (select 1 from public.review_tags    where tagged_user_id = v_uid or tagger_id = v_uid)
  or exists (select 1 from public.notifications  where recipient_id = v_uid or actor_id = v_uid)
  or exists (select 1 from public.sort_preview_cache where author_id = v_uid)
  or exists (select 1 from public.sort_preview_rate  where author_id = v_uid)
  or exists (select 1 from public.user_cravings  where user_id = v_uid)
  or exists (select 1 from public.entry_companions   where tagger_id = v_uid or companion_id = v_uid)
  or exists (select 1 from public.entry_invites      where inviter_id = v_uid or redeemed_by = v_uid)
  or exists (select 1 from public.device_push_tokens where user_id = v_uid)
  or exists (select 1 from public.ate_with_ledger    where actor_id = v_uid or recipient_id = v_uid)
  or exists (select 1 from public.user_lists         where owner_id = v_uid)
  or exists (select 1 from public.user_list_items    where owner_id = v_uid)
  then
    raise exception 'delete_account: personal rows survived the cascade for %', v_uid
      using errcode = 'P0001';
  end if;

  insert into public.storage_purge_queue (user_id) values (v_uid) on conflict (user_id) do nothing;

  return jsonb_build_object('ok', true, 'auth_user_deleted', true);
end; $$;

-- ===========================================================================
-- 9. List invites spend the ate-with day budget
-- ===========================================================================
alter table public.ate_with_ledger drop constraint if exists ate_with_ledger_kind_check;
alter table public.ate_with_ledger
  add constraint ate_with_ledger_kind_check check (kind in ('tag', 'invite', 'list'));

create or replace function public.set_list_people(p_list_id uuid, p_user_ids uuid[])
returns table (user_id uuid, username text, name text, avatar_url text, status text, invited_at timestamptz)
language plpgsql volatile security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_list public.user_lists := public.list_own(p_list_id);
  v_ids  uuid[];
  v_new  uuid;
  v_quiet boolean;
begin
  select coalesce(array_agg(distinct x), '{}') into v_ids
  from unnest(coalesce(p_user_ids, '{}')) x
  join public.profiles p on p.id = x
  where x <> v_list.owner_id and p.deleted_at is null and not public.blocked_with(x);
  if cardinality(v_ids) > 20 then
    raise exception 'list_people_cap' using errcode = '54000';
  end if;

  -- Off the list: their rows, and any invite still in their Notifications.
  update public.notifications n set dismissed_at = now(), read_at = coalesce(n.read_at, now())
  where n.type = 'list_invite' and n.list_id = v_list.id and n.dismissed_at is null
    and n.recipient_id <> all (v_ids);
  delete from public.user_list_members m where m.list_id = v_list.id and m.user_id <> all (v_ids);

  for v_new in
    insert into public.user_list_members (list_id, user_id)
    select v_list.id, x from unnest(v_ids) x
    on conflict (list_id, user_id) do nothing
    returning user_list_members.user_id
  loop
    -- 0094: every new invite spends the owner's day budget (create → invite → delete → repeat paid
    -- nothing before). Over it: 54000 ate_with_rate_limited, and nothing on this call lands.
    perform public.ate_with_spend(v_list.owner_id, 'list', v_list.id, v_new);
    v_quiet := exists (select 1 from public.notifications n
                       where n.type = 'list_invite' and n.list_id = v_list.id and n.recipient_id = v_new
                         and n.created_at > now() - interval '7 days');
    -- an earlier undismissed one would collide on the dedupe key: retire it, the new one replaces it
    update public.notifications n set dismissed_at = now()
    where n.type = 'list_invite' and n.list_id = v_list.id and n.recipient_id = v_new and n.dismissed_at is null;
    insert into public.notifications (recipient_id, actor_id, type, list_id, read_at, pushed_at)
    values (v_new, v_list.owner_id, 'list_invite', v_list.id,
            case when v_quiet then now() end, case when v_quiet then now() end);
  end loop;

  update public.user_lists l set updated_at = now() where l.id = v_list.id;
  return query select * from public.list_people(v_list.id);
end; $$;

-- ===========================================================================
-- 13. Client-written image URLs point at this project's public storage only
-- ===========================================================================
-- The two Supabase projects (staging, prod) and the local stack. Only checked for anon /
-- authenticated: definer RPCs, the service role and seeds write as other roles.
create or replace function public.storage_url_ok(p_url text, p_bucket text)
returns boolean language sql immutable set search_path = public, extensions as $$
  select p_url is null or (
    char_length(p_url) <= 2048
    and p_url ~ ('^(https://(cvoitgoaosofkougmarn|vyaexmnajnbryimbkgkf)\.supabase\.co'
                 || '|http://(127\.0\.0\.1|localhost):54321)/storage/v1/object/public/'
                 || p_bucket || '/[A-Za-z0-9._/-]+(\?[A-Za-z0-9=&._-]*)?$')
    and p_url !~ '\.\.'
  )
$$;

create or replace function public.trg_client_image_url()
returns trigger language plpgsql security invoker set search_path = public, extensions as $$
begin
  if current_user not in ('anon', 'authenticated') then return new; end if;
  -- nested, not AND-ed: plpgsql resolves new.<column> for the whole expression, on either table
  if tg_table_name = 'entry_photos' then
    if not public.storage_url_ok(new.photo_url, 'review-photos') then
      raise exception 'bad_photo_url' using errcode = '22023';
    end if;
  elsif tg_table_name = 'profiles' then
    if new.avatar_url is distinct from old.avatar_url and not public.storage_url_ok(new.avatar_url, 'avatars') then
      raise exception 'bad_avatar_url' using errcode = '22023';
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists entry_photos_url_ok on public.entry_photos;
create trigger entry_photos_url_ok
  before insert or update of photo_url on public.entry_photos
  for each row execute function public.trg_client_image_url();

drop trigger if exists profiles_avatar_url_ok on public.profiles;
create trigger profiles_avatar_url_ok
  before update of avatar_url on public.profiles
  for each row execute function public.trg_client_image_url();

-- ===========================================================================
-- 15. Hand-added places and reports have limits
-- ===========================================================================
create table if not exists public.manual_place_ledger (
  id         bigint      generated always as identity primary key,
  user_id    uuid        not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists manual_place_ledger_user_idx on public.manual_place_ledger (user_id, created_at desc);
alter table public.manual_place_ledger enable row level security;
revoke all on public.manual_place_ledger from public, anon, authenticated;
grant select, insert, delete on public.manual_place_ledger to service_role;

comment on table public.manual_place_ledger is
  '0094: one row per hand-added place, behind add_manual_restaurant''s 20-a-day cap. Server-internal.';

create or replace function public.add_manual_restaurant(
  p_name    text,
  p_city    text default '',
  p_cuisine text default null,
  p_address text default null
)
returns public.restaurants
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_name text := btrim(coalesce(p_name, ''));
  v_row  public.restaurants;
begin
  if v_uid is null then
    raise exception 'must be authenticated to add a restaurant'
      using errcode = '42501';  -- insufficient_privilege
  end if;

  if v_name = '' then
    raise exception 'restaurant name is required'
      using errcode = '22023';  -- invalid_parameter_value
  end if;
  if char_length(v_name) > 200 or char_length(coalesce(p_city, '')) > 100
     or char_length(coalesce(p_cuisine, '')) > 100 or char_length(coalesce(p_address, '')) > 500 then
    raise exception 'restaurant field too long' using errcode = '22001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('manual_place:' || v_uid::text, 0));
  delete from public.manual_place_ledger l where l.user_id = v_uid and l.created_at < now() - interval '2 days';
  if (select count(*) from public.manual_place_ledger l
      where l.user_id = v_uid and l.created_at > now() - interval '1 day') >= 20 then
    raise exception 'manual_place_rate_limited' using errcode = '54000';
  end if;
  insert into public.manual_place_ledger (user_id) values (v_uid);

  insert into public.restaurants (source, google_place_id, name, city, cuisine, address)
  values (
    'manual',
    null,
    v_name,
    btrim(coalesce(p_city, '')),
    nullif(btrim(coalesce(p_cuisine, '')), ''),
    nullif(btrim(coalesce(p_address, '')), '')
  )
  returning * into v_row;

  return v_row;
end; $$;

revoke all on function public.add_manual_restaurant(text, text, text, text) from public, anon;
grant execute on function public.add_manual_restaurant(text, text, text, text) to authenticated;

-- Reports: a repeat of an open report returns the first one; 30 new reports a rolling day.
create or replace function public.report_entry(p_entry_id uuid, p_reason text default null, p_note text default null)
returns uuid language plpgsql volatile security invoker
set search_path = public, extensions as $$
declare
  v_id uuid;
begin
  select r.id into v_id from public.reports r
  where r.reporter_id = (select auth.uid()) and r.entry_id = p_entry_id and r.status = 'open'
  limit 1;
  if v_id is not null then return v_id; end if;
  insert into public.reports (reporter_id, entry_id, reason, note)
  values (
    (select auth.uid()),
    p_entry_id,
    nullif(btrim(lower(coalesce(p_reason, ''))), ''),
    nullif(btrim(coalesce(p_note, '')), '')
  )
  returning id into v_id;
  return v_id;
end; $$;

create or replace function public.report_profile(p_user_id uuid, p_reason text default null, p_note text default null)
returns uuid language plpgsql volatile security invoker
set search_path = public, extensions as $$
declare
  v_id uuid;
begin
  select r.id into v_id from public.reports r
  where r.reporter_id = (select auth.uid()) and r.profile_id = p_user_id and r.status = 'open'
  limit 1;
  if v_id is not null then return v_id; end if;
  insert into public.reports (reporter_id, profile_id, reason, note)
  values (
    (select auth.uid()),
    p_user_id,
    nullif(btrim(lower(coalesce(p_reason, ''))), ''),
    nullif(btrim(coalesce(p_note, '')), '')
  )
  returning id into v_id;
  return v_id;
end; $$;

revoke all on function public.report_entry(uuid, text, text)    from public, anon;
revoke all on function public.report_profile(uuid, text, text)  from public, anon;
grant execute on function public.report_entry(uuid, text, text)   to authenticated;
grant execute on function public.report_profile(uuid, text, text) to authenticated;

create or replace function public.reports_today(p_uid uuid)
returns integer language sql volatile security definer set search_path = public, extensions as $$
  select count(*)::int from public.reports r
  where r.reporter_id = p_uid and p_uid = (select auth.uid()) and r.created_at > now() - interval '1 day'
$$;
revoke all on function public.reports_today(uuid) from public, anon, authenticated;
grant execute on function public.reports_today(uuid) to authenticated;

-- The count runs as definer (a reporter cannot read other people's reports, nor needs to); the
-- trigger itself is invoker so current_user still says who is writing.
create or replace function public.trg_report_budget()
returns trigger language plpgsql security invoker set search_path = public, extensions as $$
begin
  if current_user not in ('anon', 'authenticated') then return new; end if;
  if public.reports_today(new.reporter_id) >= 30 then
    raise exception 'report_rate_limited' using errcode = '54000';
  end if;
  return new;
end; $$;

drop trigger if exists reports_budget on public.reports;
create trigger reports_budget
  before insert on public.reports
  for each row execute function public.trg_report_budget();

-- ===========================================================================
-- 16. profiles.diet is private to its owner
-- ===========================================================================
do $$
declare
  v_cols text;
begin
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_cols
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass and a.attnum > 0 and not a.attisdropped
    and a.attname <> 'diet';
  execute 'revoke select on public.profiles from anon, authenticated';
  execute format('grant select (%s) on public.profiles to anon, authenticated', v_cols);
end $$;

create or replace function public.my_diet()
returns text[] language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select p.diet from public.profiles p where p.id = (select auth.uid())), '{}')
$$;
revoke all on function public.my_diet() from public, anon;
grant execute on function public.my_diet() to authenticated;

comment on function public.my_diet() is
  '0094: the caller''s own profiles.diet (the column is not readable by any client role).';

-- ===========================================================================
-- 17. A live push token is not taken over by another account
-- ===========================================================================
create or replace function public.register_push_token(p_token text, p_apns_env text default 'production')
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid   uuid := (select auth.uid());
  v_token text := lower(btrim(coalesce(p_token, '')));
  v_env   text := lower(btrim(coalesce(p_apns_env, 'production')));
begin
  if v_uid is null then
    raise exception 'sign in to register' using errcode = '42501';
  end if;
  if v_token !~ '^[0-9a-f]{64,200}$' or v_env not in ('sandbox', 'production') then
    raise exception 'bad push token or apns_env' using errcode = '22023';
  end if;
  -- The device's own sign-out deletes its row (unregister), so a token still held by someone else
  -- and seen in the last 7 days is theirs: leave it. A stale one moves (an app deleted unsigned-out).
  insert into public.device_push_tokens (token, user_id, apns_env)
  values (v_token, v_uid, v_env)
  on conflict (token) do update
    set user_id = excluded.user_id, apns_env = excluded.apns_env, last_seen_at = now()
    where public.device_push_tokens.user_id = excluded.user_id
       or public.device_push_tokens.last_seen_at < now() - interval '7 days';
  delete from public.device_push_tokens t
  where t.user_id = v_uid
    and t.token not in (select x.token from public.device_push_tokens x where x.user_id = v_uid
                        order by x.last_seen_at desc limit 10);
end; $$;

-- ===========================================================================
-- 23. dish-dedup remembers the pairs it judged apart
-- ===========================================================================
create table if not exists public.dish_pair_verdicts (
  dish_a     uuid        not null references public.dishes(id) on delete cascade,
  dish_b     uuid        not null references public.dishes(id) on delete cascade,
  verdict    text        not null check (verdict in ('different', 'unsure')),
  judged_at  timestamptz not null default now(),
  primary key (dish_a, dish_b),
  constraint dish_pair_verdicts_order_ck check (dish_a < dish_b)
);
alter table public.dish_pair_verdicts enable row level security;
revoke all on public.dish_pair_verdicts from public, anon, authenticated;
grant select, insert, update, delete on public.dish_pair_verdicts to service_role;

comment on table public.dish_pair_verdicts is
  '0094: pairs the dish-dedup model judged different or unsure (dish_a < dish_b); a later scan skips them. Service role only.';

-- ===========================================================================
-- 24. A failed photo match is recorded
-- ===========================================================================
alter table public.entries add column if not exists photos_match_tried_at timestamptz;
comment on column public.entries.photos_match_tried_at is
  '0094: when match-photos last asked the model for this entry and got nothing usable. A viewer''s look does not ask again within a day.';

-- ===========================================================================
-- 27. Text caps (generous; NOT VALID so existing rows are left alone)
-- ===========================================================================
alter table public.dishes
  add constraint dishes_name_length_ck check (char_length(name) <= 200) not valid;
alter table public.restaurants
  add constraint restaurants_text_length_ck check (
    char_length(name) <= 300
    and char_length(coalesce(city, '')) <= 200
    and char_length(coalesce(cuisine, '')) <= 200
    and char_length(coalesce(address, '')) <= 1000
  ) not valid;
alter table public.reviews
  add constraint reviews_note_length_ck check (note is null or char_length(note) <= 2000) not valid;

-- ===========================================================================
-- 28. The unused social tables are not readable by clients
-- ===========================================================================
revoke select on
  public.comments, public.comment_likes, public.follows, public.review_likes, public.review_tags,
  public.lists, public.list_dishes
from anon, authenticated;

-- 5 (cont.). The delete-account function counts a failed purge, so a row that keeps failing is given up
-- on after 10 tries instead of being retried forever.
create or replace function public.storage_purge_failed(p_user_id uuid)
returns void language sql volatile security definer set search_path = public, extensions as $$
  update public.storage_purge_queue set attempts = attempts + 1 where user_id = p_user_id
$$;
revoke all on function public.storage_purge_failed(uuid) from public, anon, authenticated;
grant execute on function public.storage_purge_failed(uuid) to service_role;
