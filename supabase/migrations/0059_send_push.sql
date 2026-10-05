-- 0059_send_push.sql
-- Ate backend — PUSH DELIVERY for "ate with" (0058). The database decides WHAT is ready to push and
-- WHEN to wake the sender; the edge function `send-push` (supabase/functions/send-push) signs and sends.
--
-- ─── What is ready (push_is_ready): an `ate_with` notification that is unpushed, unread, undismissed,
--   under 24 h old, with fewer than 5 attempts and no live claim (a claim goes stale after 2 min, so a
--   crashed or transiently failed send is retried), whose tag is still PENDING, between two live
--   profiles with no block either way, and whose original entry has FINISHED SORTING — the approved
--   design (design/rebuild/ate-with.html, "The push"): sent once the tagger's dishes exist. A quiet
--   re-tag (0058: born read + pushed) is therefore never ready.
--
-- ─── The sender's three calls (service_role only; DEFINER, no client EXECUTE):
--   push_claim_ate_with(p_limit 50) → (notification_id, companion_id, entry_id, recipient_id, actor_username,
--       place_name, dish_names text[], badge, tokens jsonb [{token, apns_env}]). Atomic: FOR UPDATE SKIP
--       LOCKED, stamps push_claimed_at and push_attempts, so overlapping invocations never double-send.
--   push_mark_sent(p_ids uuid[]) → int: stamps pushed_at (also for a recipient with no device: there is
--       nothing to retry).
--   push_drop_tokens(p_tokens text[]) → int: deletes tokens APNs called dead (410 / BadDeviceToken).
--
-- ─── Waking the sender (push_kick): pg_net POSTs `{}` to the function, but ONLY when something is
--   ready, and only once both Vault secrets exist — `send_push_url` and `send_push_kick_secret`. No
--   Vault secrets = no HTTP at all, so this migration is inert until the lead finishes setup. Called:
--     * on INSERT of an ate_with notification (the tag of an already-sorted entry),
--     * on an entry becoming sorted while it has pending tags (the usual case: tag, then sort),
--     * every minute by pg_cron — the retry path (a failed or skipped send, a cold function).
--   WHY pg_net + pg_cron and not a Database Webhook: the project uses none of the three yet; a webhook
--   is configured in the dashboard (outside the repo) and fires on every insert, including ones not
--   yet sendable (entry still sorting) — it would need its own retry anyway. Both triggers swallow
--   every error: a push problem can never fail a tag, a sort or an insert.
--   KEYLESS SETUP: push_configure(p_url) (service_role/postgres only) stores the URL and, once, a random
--   32-byte kick secret the DATABASE generates — no one ever copies the service-role key. pg_net sends it
--   as the bearer; send-push accepts it (read once through push_kick_secret(), service_role only) or the
--   service-role key. Call push_configure only AFTER the APNS_* secrets are set and send-push is
--   deployed: an unconfigured function answers {configured:false} and claims nothing, and the drain would
--   keep waking it each minute while a tag is ready (≤ 24 h per tag).
--   The extensions are created only where available (hosted Supabase has both; the PGlite test
--   harness has neither, and there the kick is a no-op).
--
-- WIRE IMPACT: ADDITIVE — register_push_token's p_apns_env now defaults to 'production' (old calls unchanged).
--   Otherwise none for the app: two notifications columns it never reads, server-only functions.

set search_path = public, extensions;

-- ===========================================================================
-- 1. Columns + index.
-- ===========================================================================
alter table public.notifications add column if not exists push_claimed_at timestamptz;
alter table public.notifications add column if not exists push_attempts   smallint not null default 0;

create index if not exists notifications_push_pending_idx
  on public.notifications (created_at)
  where type = 'ate_with' and pushed_at is null and read_at is null and dismissed_at is null;

-- 0058's guard pins pushed_at for end users; the claim columns are the sender's alone too.
create or replace function public.trg_notification_update_guard()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  new.id           := old.id;
  new.recipient_id := old.recipient_id;
  new.actor_id     := old.actor_id;
  new.type         := old.type;
  new.review_id    := old.review_id;
  new.comment_id   := old.comment_id;
  new.companion_id := old.companion_id;
  new.created_at   := old.created_at;
  if (select auth.uid()) is not null then
    new.pushed_at       := old.pushed_at;
    new.push_claimed_at := old.push_claimed_at;
    new.push_attempts   := old.push_attempts;
  end if;
  return new;
end; $$;
revoke execute on function public.trg_notification_update_guard() from public, anon, authenticated;

-- ===========================================================================
-- 1b. The device's APNs environment, per token (it decides the host). 0058's `apns_env` IS that column —
-- the client already sends it. A TestFlight (Beta) build talks to STAGING yet holds a PRODUCTION token,
-- so the host can never be one per project: send-push picks it per token. Additive: the column and the
-- parameter default to 'production' (TestFlight + App Store), so `register_push_token(p_token)` alone
-- works and 0058's two-argument call is unchanged. Same signature → create or replace, grants survive.
-- ===========================================================================
alter table public.device_push_tokens alter column apns_env set default 'production';

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
  insert into public.device_push_tokens (token, user_id, apns_env)
  values (v_token, v_uid, v_env)
  on conflict (token) do update                    -- PK: a TOTAL arbiter
    set user_id = excluded.user_id, apns_env = excluded.apns_env, last_seen_at = now();
  delete from public.device_push_tokens t
  where t.user_id = v_uid
    and t.token not in (select x.token from public.device_push_tokens x where x.user_id = v_uid
                        order by x.last_seen_at desc limit 10);
end; $$;

-- ===========================================================================
-- 2. Readiness — the one predicate the claim and the kick share.
-- ===========================================================================
create or replace function public.push_is_ready(p_id uuid)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1
    from public.notifications n
    join public.entry_companions c on c.id = n.companion_id
    join public.entries e          on e.id = c.entry_id
    join public.profiles a         on a.id = n.actor_id
    join public.profiles r         on r.id = n.recipient_id
    where n.id = p_id
      and n.type = 'ate_with'
      and n.pushed_at is null and n.read_at is null and n.dismissed_at is null
      and n.created_at > now() - interval '24 hours'
      and n.push_attempts < 5
      and (n.push_claimed_at is null or n.push_claimed_at < now() - interval '2 minutes')
      and c.status = 'pending'
      and e.sort_status in ('sorted', 'failed')        -- failed: no dishes will come; send who + where
      and a.deleted_at is null and r.deleted_at is null
      and not exists (select 1 from public.blocks b
                      where (b.blocker_id = n.actor_id and b.blocked_id = n.recipient_id)
                         or (b.blocker_id = n.recipient_id and b.blocked_id = n.actor_id))
  );
$$;

-- ===========================================================================
-- 3. The sender's calls.
-- ===========================================================================
create or replace function public.push_claim_ate_with(p_limit int default 50)
returns table (
  notification_id uuid,
  companion_id    uuid,
  entry_id        uuid,
  recipient_id    uuid,
  actor_username  text,
  place_name      text,
  dish_names      text[],
  badge           int,
  tokens          jsonb
)
language plpgsql volatile security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_ids uuid[];
begin
  with picked as (
    select n.id
    from public.notifications n
    where n.type = 'ate_with' and n.pushed_at is null and n.read_at is null and n.dismissed_at is null
      and n.created_at > now() - interval '24 hours'
      -- inline, not only inside push_is_ready: after SKIP LOCKED waits out a concurrent claim, READ
      -- COMMITTED re-checks THIS where clause against the updated row — a function call is not re-run
      -- against it, so a row claimed a moment ago must be refused here.
      and (n.push_claimed_at is null or n.push_claimed_at < now() - interval '2 minutes')
      and public.push_is_ready(n.id)
    order by n.created_at
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
    for update of n skip locked
  ), claimed as (
    update public.notifications n
       set push_claimed_at = now(), push_attempts = n.push_attempts + 1
      from picked
     where n.id = picked.id
    returning n.id
  )
  select coalesce(array_agg(id), '{}') into v_ids from claimed;

  return query
  select n.id, c.id, e.id, n.recipient_id, a.username::text, rs.name,
         coalesce((select array_agg(x.name order by x.pos) from (
                     select d.name, min(v.entry_position) as pos
                     from public.reviews v join public.dishes d on d.id = v.dish_id
                     where v.entry_id = e.id
                     group by d.id, d.name) x), '{}'::text[]),
         (select count(*)::int from public.notifications u
          where u.recipient_id = n.recipient_id and u.type = 'ate_with'
            and u.read_at is null and u.dismissed_at is null),
         coalesce((select jsonb_agg(jsonb_build_object('token', t.token, 'apns_env', t.apns_env)
                                    order by t.last_seen_at desc)
                   from public.device_push_tokens t where t.user_id = n.recipient_id), '[]'::jsonb)
  from public.notifications n
  join public.entry_companions c on c.id = n.companion_id
  join public.entries e          on e.id = c.entry_id
  join public.profiles a         on a.id = n.actor_id
  left join public.restaurants rs on rs.id = e.restaurant_id
  where n.id = any(v_ids)
  order by n.created_at;
end; $$;

create or replace function public.push_mark_sent(p_ids uuid[])
returns int language sql volatile security definer set search_path = public, extensions as $$
  with done as (
    update public.notifications
       set pushed_at = now(), push_claimed_at = null
     where id = any(coalesce(p_ids, '{}')) and pushed_at is null
    returning 1
  )
  select count(*)::int from done;
$$;

create or replace function public.push_drop_tokens(p_tokens text[])
returns int language sql volatile security definer set search_path = public, extensions as $$
  with gone as (
    delete from public.device_push_tokens where token = any(coalesce(p_tokens, '{}')) returning 1
  )
  select count(*)::int from gone;
$$;

-- ===========================================================================
-- 4. The kick. Dynamic SQL so it compiles where vault / pg_net are absent; every error is swallowed.
-- ===========================================================================
create or replace function public.push_kick()
returns boolean language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_url text;
  v_key text;
begin
  if not exists (
    select 1 from public.notifications n
    where n.type = 'ate_with' and n.pushed_at is null and n.read_at is null and n.dismissed_at is null
      and n.created_at > now() - interval '24 hours'
      and public.push_is_ready(n.id)
  ) then
    return false;
  end if;
  execute $q$select (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_url'),
                    (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_kick_secret')$q$
    into v_url, v_key;
  if v_url is null or v_key is null then
    return false;                                -- setup not finished: stay silent
  end if;
  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 5000)'
    using v_url, jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key);
  return true;
exception when others then
  return false;
end; $$;

create or replace function public.trg_push_kick_on_notification()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.type = 'ate_with' and new.pushed_at is null and new.read_at is null then
    perform public.push_kick();
  end if;
  return null;
exception when others then
  return null;
end; $$;
drop trigger if exists notifications_push_kick_ai on public.notifications;
create trigger notifications_push_kick_ai
  after insert on public.notifications
  for each row execute function public.trg_push_kick_on_notification();

create or replace function public.trg_push_kick_on_sorted()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.sort_status in ('sorted', 'failed') and old.sort_status is distinct from new.sort_status
     and exists (select 1 from public.entry_companions c where c.entry_id = new.id and c.status = 'pending') then
    perform public.push_kick();
  end if;
  return null;
exception when others then
  return null;
end; $$;
drop trigger if exists entries_push_kick_au on public.entries;
create trigger entries_push_kick_au
  after update of sort_status on public.entries
  for each row execute function public.trg_push_kick_on_sorted();

-- ===========================================================================
-- 4b. Keyless setup. Vault is reached through dynamic SQL so this file applies where Vault is absent.
-- ===========================================================================
-- Stores the function URL and, if absent, a database-generated kick secret. Returns nothing: the secret
-- is never returned, raised or logged. Re-running it updates the URL and keeps the secret.
create or replace function public.push_configure(p_url text)
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_url text := btrim(coalesce(p_url, ''));
  v_id  uuid;
begin
  if v_url !~ '^https://[^/\s]+/functions/v1/send-push$' then
    raise exception 'p_url must be https://<project>/functions/v1/send-push' using errcode = '22023';
  end if;
  execute $q$select id from vault.secrets where name = 'send_push_url'$q$ into v_id;
  if v_id is null then
    execute $q$select vault.create_secret($1, 'send_push_url', 'send-push function URL (0059)')$q$ using v_url;
  else
    execute $q$select vault.update_secret($1, $2)$q$ using v_id, v_url;
  end if;
  v_id := null;
  execute $q$select id from vault.secrets where name = 'send_push_kick_secret'$q$ into v_id;
  if v_id is null then
    execute $q$select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'send_push_kick_secret',
                                          'bearer pg_net sends to send-push (0059); generated here, never copied')$q$;
  end if;
end; $$;

-- The kick secret, for send-push's own service-role client (it compares bearers against it).
create or replace function public.push_kick_secret()
returns text language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v text;
begin
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'send_push_kick_secret'$q$ into v;
  return v;
exception when others then
  return null;
end; $$;

-- ===========================================================================
-- 5. Extensions + the minute drain, only where the platform has them.
-- ===========================================================================
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  end if;
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    execute $c$select cron.schedule('send-push-drain', '* * * * *', 'select public.push_kick()')$c$;
  end if;
end $$;

-- ===========================================================================
-- 6. Grants: the sender (service_role) only.
-- ===========================================================================
revoke all on function public.push_is_ready(uuid)              from public, anon, authenticated;
revoke all on function public.push_claim_ate_with(int)         from public, anon, authenticated;
revoke all on function public.push_mark_sent(uuid[])           from public, anon, authenticated;
revoke all on function public.push_drop_tokens(text[])         from public, anon, authenticated;
revoke all on function public.push_kick()                      from public, anon, authenticated;
revoke all on function public.push_configure(text)             from public, anon, authenticated;
revoke all on function public.push_kick_secret()               from public, anon, authenticated;
revoke all on function public.trg_push_kick_on_notification()  from public, anon, authenticated;
revoke all on function public.trg_push_kick_on_sorted()        from public, anon, authenticated;
grant execute on function public.push_claim_ate_with(int)  to service_role;
grant execute on function public.push_mark_sent(uuid[])    to service_role;
grant execute on function public.push_drop_tokens(text[])  to service_role;
grant execute on function public.push_kick()               to service_role;
grant execute on function public.push_configure(text)      to service_role;
grant execute on function public.push_kick_secret()        to service_role;
