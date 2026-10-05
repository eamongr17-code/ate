-- 0058_ate_with.sql
-- Ate backend — "ATE WITH": tag the people you ate with. DRAFT — authored and tested locally (PGlite);
-- not applied anywhere. Lands through a PR like every migration (staging after QA, prod by the CI job).
--
-- THE FLOW. Writing an entry, the author tags anyone on Ate ("ate with @jess") or mints an invite link
--   for someone not on Ate yet. The tagged person gets a notification (+ a push — delivery is an edge
--   function, see integration-design.md; nothing here sends anything). Opening it reads a PREFILL: the
--   same place, the same dishes, the tagger's visit time. They add only their own scores (words
--   optional) and post: that makes a NEW ENTRY, THEIRS (their author_id, their order number, their
--   Journal), linked to the original. Both cards print "with @…". A tag can be declined.
--
-- PENDING TAG vs THE TAGGER'S EDITS — the prefill FOLLOWS the live entry, it does not snapshot:
--   * a tag is made while composing, i.e. BEFORE the sorter has printed a single line — a snapshot taken
--     at tag time would almost always be empty. The prefill reads the original's lines when opened (and
--     says `sort_status`, so a still-pending sort reads as "dishes on their way", not "no dishes");
--   * a dish the tagger fixes (correct_entry_dish) is a correction the companion should inherit;
--   * once the companion POSTS, their lines are theirs (their own reviews rows): later edits or a
--     delete of the original never touch them;
--   * the original deleted BEFORE a response withdraws the tag: entry_companions cascades, its
--     notification cascades with it; a stale push opens to `P0002` → "no longer available".
--
-- ─── Storage (all new; RLS on every table; no client write grant on any — RPCs only)
--   entry_companions (id, entry_id, tagger_id, companion_id, status, response_entry_id, invite_id,
--       created_at, responded_at). UNIQUE (entry_id, companion_id) — TOTAL. status pending | accepted |
--       declined. response_entry_id UNIQUE (TOTAL; NULLs distinct), → entries ON DELETE SET NULL: the
--       responder deleting their entry unlinks it (the row stays accepted, the cards stop printing it).
--       SELECT: the two parties only.
--   entry_invites (id, entry_id, inviter_id, token_hash, expires_at, redeemed_by, redeemed_at,
--       created_at). Only sha256(token) is stored; the token is returned once, by the RPC that mints it.
--       14-day expiry, single use. SELECT: the inviter.
--   device_push_tokens (token PK, user_id, apns_env sandbox | production, bundle_id, created_at,
--       last_seen_at). Written by register/unregister RPCs; SELECT/DELETE own. ≤ 10 per user.
--   ate_with_ledger (actor_id, kind tag | invite, entry_id, recipient_id, created_at): append-only spend
--       record behind the day budget; server-internal (RLS on, no policy, no grant). Cascades/nulls on
--       account deletion; rows older than 2 days are purged on the actor's next spend.
--   notifications (0011, dormant until now) gains type 'ate_with', `companion_id` (→ entry_companions,
--       cascade) and `pushed_at` (the push sender's idempotency stamp; service role only).
--
-- ─── RPCs (all ADDITIVE)
--   tag_ate_with(p_entry_id, p_user_id) · untag_ate_with(p_entry_id, p_user_id)
--   create_ate_with_invite(p_entry_id) · revoke_ate_with_invite(p_invite_id) · redeem_ate_with_invite(p_token)
--   my_notifications(p_limit, p_cursor_created_at, p_cursor_id) · unread_notification_count() (0011's,
--       now counting only types this client renders) · dismiss_notification(p_id) (0011's, unchanged)
--   ate_with_prefill(p_companion_id) · respond_ate_with(p_companion_id, p_entry_id, p_items, p_body)
--   decline_ate_with(p_companion_id) · register_push_token(p_token, p_apns_env) · unregister_push_token(p_token)
--
-- ─── Rules. A tag is the AUTHOR's act on their OWN entry. Never yourself. Never across a block, either
--   direction (and a new block withdraws every PENDING tag between the pair). At most 6 people per
--   entry (every tag, declined included, + live invites); at most 40 tags + invites per tagger per rolling day.
--   Declined is sticky and keeps its seat: untag cannot free it or turn a "no" into a second notification.
--   The day budget is spent from an append-only ledger (ate_with_ledger) that untag/revoke never touch,
--   serialised per actor; re-tagging the same person on the same entry within a day is QUIET (the
--   notification lands read and pushed — no badge, no push) only if the untagged tag had reached them
--   (pushed or read); otherwise the re-tag notifies normally.
--
-- ─── entry_cards + `companions` (trailing column, ADDITIVE): [{user_id, username, name, avatar_url,
--   status, entry_id}] — the people this entry was eaten with. On an original: its accepted companions
--   (whose response still stands), plus PENDING ones when the viewer is the author or that companion.
--   On a response: the original's author + its other accepted companions. Blocked and deactivated
--   people are absent; `entry_id` = that person's entry for the visit (null while pending). `[]` never null.
--
-- WIRE IMPACT: ADDITIVE — new RPCs and tables, a trailing `companions` key on every entry_cards row
--   (decoders ignore unknown keys). Behavioural, dormant surface only: unread_notification_count counts
--   only 'ate_with' (no shipped V1 client calls it). Nothing existing changes meaning.

set search_path = public, extensions;

-- ===========================================================================
-- 1. Tables.
-- ===========================================================================
create table if not exists public.entry_invites (
  id           uuid        primary key default gen_random_uuid(),
  entry_id     uuid        not null references public.entries(id)  on delete cascade,
  inviter_id   uuid        not null references public.profiles(id) on delete cascade,
  token_hash   text        not null,
  expires_at   timestamptz not null default now() + interval '14 days',
  redeemed_by  uuid        references public.profiles(id) on delete set null,
  redeemed_at  timestamptz,
  created_at   timestamptz not null default now(),
  constraint entry_invites_token_hash_uq unique (token_hash),              -- TOTAL
  constraint entry_invites_hash_ck check (token_hash ~ '^[0-9a-f]{64}$'),
  constraint entry_invites_redeemed_ck check (redeemed_by is null or redeemed_at is not null)  -- redeemed_by nulls on account deletion
);
create index if not exists entry_invites_entry_idx   on public.entry_invites (entry_id);
create index if not exists entry_invites_inviter_idx on public.entry_invites (inviter_id, created_at desc);

create table if not exists public.entry_companions (
  id                uuid        primary key default gen_random_uuid(),
  entry_id          uuid        not null references public.entries(id)  on delete cascade,
  tagger_id         uuid        not null references public.profiles(id) on delete cascade,
  companion_id      uuid        not null references public.profiles(id) on delete cascade,
  status            text        not null default 'pending',
  response_entry_id uuid        references public.entries(id) on delete set null,
  invite_id         uuid        references public.entry_invites(id) on delete set null,
  created_at        timestamptz not null default now(),
  responded_at      timestamptz,
  constraint entry_companions_status_ck   check (status in ('pending', 'accepted', 'declined')),
  constraint entry_companions_no_self     check (companion_id <> tagger_id),
  constraint entry_companions_response_ck check (response_entry_id is null or status = 'accepted'),
  constraint entry_companions_pair_uq     unique (entry_id, companion_id),   -- TOTAL
  constraint entry_companions_response_uq unique (response_entry_id)         -- TOTAL (NULLs distinct)
);
create index if not exists entry_companions_companion_idx on public.entry_companions (companion_id, created_at desc);
create index if not exists entry_companions_tagger_idx    on public.entry_companions (tagger_id, created_at desc);

create table if not exists public.device_push_tokens (
  token        text        primary key,                                    -- TOTAL: the upsert target
  user_id      uuid        not null references public.profiles(id) on delete cascade,
  apns_env     text        not null,
  bundle_id    text        not null default 'com.eamongracias.ate',
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  constraint device_push_tokens_env_ck   check (apns_env in ('sandbox', 'production')),
  constraint device_push_tokens_token_ck check (token ~ '^[0-9a-f]{64,200}$')
);
create index if not exists device_push_tokens_user_idx on public.device_push_tokens (user_id, last_seen_at desc);

-- Append-only spend ledger behind the daily budget and the quiet re-tag. Server-internal: RLS on, no
-- policy, no client grant. entry_id carries no FK on purpose (a deleted entry's spend still counts).
create table if not exists public.ate_with_ledger (
  id           bigint      generated always as identity primary key,
  actor_id     uuid        not null references public.profiles(id) on delete cascade,
  kind         text        not null check (kind in ('tag', 'invite')),
  entry_id     uuid        not null,
  recipient_id uuid        references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  delivered    boolean     not null default false   -- set by untag: this tag's notification had been pushed or read
);
-- (a local DB that applied an earlier draft of this file has the table without the flag)
alter table public.ate_with_ledger add column if not exists delivered boolean not null default false;
create index if not exists ate_with_ledger_actor_idx on public.ate_with_ledger (actor_id, created_at desc);

comment on table public.entry_companions is
  'Ate with (0058): a person the author tagged on their entry. pending → accepted (response_entry_id = the companion''s OWN linked entry) | declined (sticky). Parties-only SELECT; written by RPCs.';
comment on table public.entry_invites is
  'Ate with (0058): an invite link for someone not on Ate. sha256(token) only; 14-day expiry; single use (redeem_ate_with_invite turns it into an entry_companions row). Inviter-only SELECT.';
comment on table public.device_push_tokens is
  'APNs device tokens (0058). apns_env = the build''s aps-environment (sandbox for Xcode builds, production for TestFlight/App Store). register_push_token moves a token to whoever signed in on the device last.';

-- notifications (0011): a new type and its subject.
alter table public.notifications add column if not exists companion_id uuid references public.entry_companions(id) on delete cascade;
alter table public.notifications add column if not exists pushed_at timestamptz;
create index if not exists notifications_companion_idx on public.notifications (companion_id) where companion_id is not null;

alter table public.notifications drop constraint if exists notifications_type_chk;
alter table public.notifications add constraint notifications_type_chk
  check (type in ('like', 'comment', 'follow', 'tag', 'ate_with'));
alter table public.notifications drop constraint if exists notifications_shape_chk;
alter table public.notifications add constraint notifications_shape_chk check (
  case type
    when 'like'     then review_id is not null and comment_id is null     and companion_id is null
    when 'comment'  then review_id is not null and comment_id is not null and companion_id is null
    when 'follow'   then review_id is null     and comment_id is null     and companion_id is null
    when 'tag'      then review_id is not null and comment_id is null     and companion_id is null
    when 'ate_with' then review_id is null     and comment_id is null     and companion_id is not null
  end
);
-- 0011's dedupe key ignored companion_id, so two tags by the same person would have collided. Nothing
-- upserts against it (the trigger's ON CONFLICT DO NOTHING names no arbiter), so it may stay partial.
drop index if exists public.notifications_dedupe_uq;
create unique index if not exists notifications_dedupe_uq
  on public.notifications (
    recipient_id, actor_id, type,
    coalesce(review_id,    '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(comment_id,   '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(companion_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where dismissed_at is null;

-- 0011's guard, plus the new columns: a recipient may change read_at / dismissed_at, nothing else.
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
    new.pushed_at := old.pushed_at;          -- the push sender (service role) is its only writer
  end if;
  return new;
end; $$;
revoke execute on function public.trg_notification_update_guard() from public, anon, authenticated;

-- ===========================================================================
-- 2. RLS + grants. No client INSERT/UPDATE/DELETE on the new tables except deleting your own token.
-- ===========================================================================
alter table public.entry_companions   enable row level security;
alter table public.entry_invites      enable row level security;
alter table public.device_push_tokens enable row level security;
alter table public.ate_with_ledger    enable row level security;

drop policy if exists entry_companions_select_party on public.entry_companions;
create policy entry_companions_select_party on public.entry_companions
  for select to authenticated
  using (tagger_id = (select auth.uid()) or companion_id = (select auth.uid()));

drop policy if exists entry_invites_select_inviter on public.entry_invites;
create policy entry_invites_select_inviter on public.entry_invites
  for select to authenticated using (inviter_id = (select auth.uid()));

drop policy if exists device_push_tokens_select_own on public.device_push_tokens;
create policy device_push_tokens_select_own on public.device_push_tokens
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists device_push_tokens_delete_own on public.device_push_tokens;
create policy device_push_tokens_delete_own on public.device_push_tokens
  for delete to authenticated using (user_id = (select auth.uid()));

revoke all on public.entry_companions   from anon, authenticated;
revoke all on public.entry_invites      from anon, authenticated;
revoke all on public.device_push_tokens from anon, authenticated;
revoke all on public.ate_with_ledger    from anon, authenticated;
grant select         on public.entry_companions   to authenticated;
grant select         on public.entry_invites      to authenticated;
grant select, delete on public.device_push_tokens to authenticated;
grant all on public.entry_companions, public.entry_invites, public.device_push_tokens, public.ate_with_ledger to service_role;

-- ===========================================================================
-- 3. Trigger: a block withdraws pending tags. (Notifications are written by the RPCs, which know
--    whether this is a re-tag inside the day — see ate_with_notify.)
-- ===========================================================================
create or replace function public.trg_block_withdraws_ate_with()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from public.entry_companions c
  where c.status = 'pending'
    and ((c.tagger_id = new.blocker_id and c.companion_id = new.blocked_id)
      or (c.tagger_id = new.blocked_id and c.companion_id = new.blocker_id));
  return null;
end; $$;
drop trigger if exists blocks_withdraw_ate_with_ai on public.blocks;
create trigger blocks_withdraw_ate_with_ai
  after insert on public.blocks
  for each row execute function public.trg_block_withdraws_ate_with();

revoke execute on function public.trg_block_withdraws_ate_with() from public, anon, authenticated;

-- ===========================================================================
-- 4. Helpers.
-- ===========================================================================
-- Seats taken on an entry: EVERY companion row (a decline keeps its seat) + live invites.
create or replace function public.ate_with_seats(p_entry_id uuid)
returns int language sql stable security definer set search_path = public, extensions as $$
  select (select count(*) from public.entry_companions c where c.entry_id = p_entry_id)::int
       + (select count(*) from public.entry_invites i
          where i.entry_id = p_entry_id and i.redeemed_at is null and i.expires_at > now())::int;
$$;

-- The caller's own entry, row-locked (serialises the seat count), or a raise.
create or replace function public.ate_with_own_entry(p_entry_id uuid)
returns public.entries language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid   uuid := (select auth.uid());
  v_entry public.entries;
begin
  if v_uid is null then
    raise exception 'sign in to tag' using errcode = '42501';
  end if;
  select * into v_entry from public.entries where id = p_entry_id for update;
  if not found then
    raise exception 'entry_not_found' using errcode = 'P0002';
  end if;
  if v_entry.author_id <> v_uid then
    raise exception 'not_your_entry' using errcode = '42501';
  end if;
  if v_entry.restaurant_id is null then           -- a pre-0040 placeless entry: nothing to prefill
    raise exception 'entry_has_no_place' using errcode = '22023';
  end if;
  return v_entry;
end; $$;

-- Spend one unit of the actor's rolling-day budget (40 tags + invites), from the append-only ledger —
-- untag/revoke delete companion and invite rows, never ledger rows, so a tag→untag loop still pays.
-- Serialised per actor (advisory xact lock) so parallel calls on different entries cannot pass 40.
-- Returns true when this (entry, recipient) was already tagged within the day AND that earlier tag had
-- actually reached them (its notification pushed or read before an untag — `delivered`): only then is
-- the re-tag quiet. Tag → untag before anything was delivered → the re-tag is a normal, loud one.
create or replace function public.ate_with_spend(p_uid uuid, p_kind text, p_entry_id uuid, p_recipient uuid)
returns boolean language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_again boolean;
begin
  perform pg_advisory_xact_lock(hashtextextended('ate_with_budget:' || p_uid::text, 0));
  delete from public.ate_with_ledger l where l.actor_id = p_uid and l.created_at < now() - interval '2 days';
  if (select count(*) from public.ate_with_ledger l
      where l.actor_id = p_uid and l.created_at > now() - interval '1 day') >= 40 then
    raise exception 'ate_with_rate_limited' using errcode = '54000';
  end if;
  v_again := p_recipient is not null and exists (
    select 1 from public.ate_with_ledger l
    where l.actor_id = p_uid and l.kind = 'tag' and l.entry_id = p_entry_id
      and l.recipient_id = p_recipient and l.created_at > now() - interval '1 day' and l.delivered);
  insert into public.ate_with_ledger (actor_id, kind, entry_id, recipient_id)
  values (p_uid, p_kind, p_entry_id, p_recipient);
  return v_again;
end; $$;

-- The companion's notification. Quiet (a re-tag of the same person on the same entry within the day):
-- the row still lands so the tag is reachable in the inbox, but born read and pushed — no badge, no push.
create or replace function public.ate_with_notify(p_companion_id uuid, p_quiet boolean)
returns void language sql volatile security definer set search_path = public, extensions as $$
  insert into public.notifications (recipient_id, actor_id, type, companion_id, read_at, pushed_at)
  select c.companion_id, c.tagger_id, 'ate_with', c.id,
         case when p_quiet then now() end, case when p_quiet then now() end
  from public.entry_companions c where c.id = p_companion_id
  on conflict do nothing;
$$;

-- entry_cards.companions — the people this entry was eaten with, as the VIEWER may see them.
-- DEFINER because entry_companions is parties-only under RLS while an accepted "with" is public, like
-- the entry. It is callable directly (the security_invoker view needs EXECUTE), so it applies the
-- entries SELECT rule itself (0033: own, or no block either way) to the entry's REAL author — read here,
-- never taken from the caller — and answers [] for an entry the viewer may not see.
create or replace function public.entry_with_people(p_entry_id uuid)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with entry as (
    select e.id, e.author_id
    from public.entries e
    where e.id = p_entry_id
      and (e.author_id = (select auth.uid()) or not public.blocked_with(e.author_id))
  ),
  host as (                                    -- this entry is someone's response: whose visit?
    select c.entry_id as host_entry, c.tagger_id as host_id
    from entry
    join public.entry_companions c on c.response_entry_id = entry.id and c.status = 'accepted'
    limit 1
  ),
  people as (
    select c.companion_id as user_id, c.status, c.response_entry_id as entry_id, 1 as ord, c.created_at
    from entry
    join public.entry_companions c on c.entry_id = entry.id
    where (c.status = 'accepted' and c.response_entry_id is not null)
       or (c.status = 'pending' and (select auth.uid()) in (c.tagger_id, c.companion_id))
    union all
    select h.host_id, 'accepted', h.host_entry, 0, null::timestamptz from host h
    union all
    select c.companion_id, 'accepted', c.response_entry_id, 1, c.created_at
    from host h
    join public.entry_companions c on c.entry_id = h.host_entry
    where c.status = 'accepted' and c.response_entry_id is not null and c.response_entry_id <> p_entry_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', p.id, 'username', p.username, 'name', p.name, 'avatar_url', p.avatar_url,
           'status', x.status, 'entry_id', x.entry_id)
         order by x.ord, x.created_at nulls first, p.username), '[]'::jsonb)
  from people x
  join public.profiles p on p.id = x.user_id
  where x.user_id <> (select author_id from entry)
    and p.deleted_at is null
    and not public.blocked_with(x.user_id);
$$;

revoke all on function public.ate_with_seats(uuid)                    from public, anon, authenticated;
revoke all on function public.ate_with_own_entry(uuid)                from public, anon, authenticated;
revoke all on function public.ate_with_spend(uuid, text, uuid, uuid)  from public, anon, authenticated;
revoke all on function public.ate_with_notify(uuid, boolean)          from public, anon, authenticated;
revoke all on function public.entry_with_people(uuid)                 from public, anon;
grant execute on function public.entry_with_people(uuid) to authenticated, service_role;

-- ===========================================================================
-- 5. entry_cards — 0036's view verbatim, plus the trailing `companions`.
-- Appending a column keeps create-or-replace legal; every `setof entry_cards` reader returns it.
-- ===========================================================================
create or replace view public.entry_cards
with (security_invoker = true) as
  select
    e.id,
    e.author_id,
    e.body,
    e.visibility,
    e.restaurant_id,
    e.restaurant_source,
    e.order_number,
    e.sort_status,
    e.sorted_at,
    e.created_at,
    e.updated_at,
    (e.author_id = (select auth.uid())) as is_mine,
    jsonb_build_object(
      'id', p.id, 'username', p.username, 'name', p.name,
      'avatar_url', p.avatar_url, 'city', p.city
    ) as author,
    case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'name', r.name, 'address', r.address,
      'city', r.city, 'cuisine', r.cuisine,
      'locality', public.place_locality(r.address, r.city)
    ) end as place,
    coalesce(ph.photos, '[]'::jsonb) as photos,
    coalesce(ph.photo_count, 0)      as photo_count,
    coalesce(it.items, '[]'::jsonb)  as items,
    coalesce(it.dish_count, 0)       as dish_count,
    it.avg_score,
    e.place_offset,
    char_length(e.place_query) as place_length,
    -- 0058: "ate with" — see entry_with_people.
    public.entry_with_people(e.id) as companions
  from public.entries e
  join public.profiles p on p.id = e.author_id
  left join public.restaurants r on r.id = e.restaurant_id
  left join lateral (
    select
      jsonb_agg(jsonb_build_object('url', x.photo_url, 'position', x.position)
                order by x.position) as photos,
      count(*)::int as photo_count
    from public.entry_photos x
    where x.entry_id = e.id
  ) ph on true
  left join lateral (
    select
      jsonb_agg(jsonb_build_object(
        'review_id', v.id,
        'dish_id',   v.dish_id,
        'dish_name', d.name,
        'score',     v.score,
        'note',      v.note,
        'position',  v.entry_position,
        'saved',     (s.user_id is not null),
        'evidence_offset', v.evidence_offset,
        'evidence_length', char_length(v.score_evidence),
        'mention_offset',  v.mention_offset,
        'mention_length',  char_length(v.mention_text),
        'corrected', (v.corrected_at is not null),
        'cover_url', public.dish_cover_url(v.dish_id),
        'tags', to_jsonb(v.tags)
      ) order by v.entry_position nulls last, v.created_at, v.id) as items,
      count(*)::int as dish_count,
      round(avg(v.score), 2)::numeric(3,2) as avg_score
    from public.reviews v
    join public.dishes d on d.id = v.dish_id
    left join public.saves s on s.dish_id = v.dish_id and s.user_id = (select auth.uid())
    where v.entry_id = e.id
  ) it on true;

comment on view public.entry_cards is
  'The one entry shape for Journal slip / Feed slip / Entry page / Share receipt: entry + author + place (+ locality, 0035) + photos[] + items[] (each with the dish''s cover_url and its dietary tags[], 0036) + receipt footer (dish_count, avg_score over scored items) + where each finding sits in body (0-based UNICODE SCALAR offsets) + companions[] (0058, "ate with"). Read a single entry with get_entry_card; page lists via get_entry_feed / get_entries_by_author / get_entries_at_place.';

-- An earlier draft (979136a) had entry_with_people(p_entry_id, p_author_id). Dropped only now, after the
-- view above stopped depending on it, so a local DB that applied that draft keeps no orphan overload.
drop function if exists public.entry_with_people(uuid, uuid);

-- ===========================================================================
-- 6. Tagging (the author's side).
-- ===========================================================================
create or replace function public.tag_ate_with(p_entry_id uuid, p_user_id uuid)
returns table (companion_id uuid, entry_id uuid, user_id uuid, status text, created_at timestamptz)
language plpgsql volatile security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_entry public.entries := public.ate_with_own_entry(p_entry_id);
  v_row   public.entry_companions;
  v_quiet boolean;
begin
  if p_user_id is null or p_user_id = v_entry.author_id then
    raise exception 'cannot_tag_yourself' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_user_id and p.deleted_at is null) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  if public.blocked_with(p_user_id) then
    raise exception 'blocked' using errcode = '42501';
  end if;

  select * into v_row from public.entry_companions c where c.entry_id = p_entry_id and c.companion_id = p_user_id;
  if not found then                                -- already there (any status, declined included): idempotent
    if public.ate_with_seats(p_entry_id) >= 6 then
      raise exception 'ate_with_cap' using errcode = '54000';
    end if;
    v_quiet := public.ate_with_spend(v_entry.author_id, 'tag', p_entry_id, p_user_id);
    insert into public.entry_companions (entry_id, tagger_id, companion_id)
    values (p_entry_id, v_entry.author_id, p_user_id)
    returning * into v_row;
    perform public.ate_with_notify(v_row.id, v_quiet);
  end if;
  return query select v_row.id, v_row.entry_id, v_row.companion_id, v_row.status, v_row.created_at;
end; $$;

-- Pending or accepted → gone (its notification with it). A decline is sticky: untag leaves it, so the
-- tagger cannot turn a "no" into a second notification. The companion's entry, if any, stays theirs.
create or replace function public.untag_ate_with(p_entry_id uuid, p_user_id uuid)
returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_entry public.entries := public.ate_with_own_entry(p_entry_id);
  v_n     int;
begin
  -- Before the notification cascades away: did this tag reach them? Record it on its ledger row, so a
  -- re-tag inside the day is quiet only when the first one was really delivered.
  update public.ate_with_ledger l
     set delivered = true
   where l.id = (select max(x.id) from public.ate_with_ledger x
                 where x.actor_id = v_entry.author_id and x.kind = 'tag'
                   and x.entry_id = v_entry.id and x.recipient_id = p_user_id)
     and exists (select 1 from public.notifications n
                 join public.entry_companions c on c.id = n.companion_id
                 where c.entry_id = v_entry.id and c.companion_id = p_user_id
                   and c.status in ('pending', 'accepted')
                   and (n.pushed_at is not null or n.read_at is not null));
  delete from public.entry_companions c
  where c.entry_id = v_entry.id and c.companion_id = p_user_id and c.status in ('pending', 'accepted');
  get diagnostics v_n = row_count;
  return v_n;
end; $$;

-- ===========================================================================
-- 7. Invites (someone not on Ate yet).
-- ===========================================================================
create or replace function public.create_ate_with_invite(p_entry_id uuid)
returns table (invite_id uuid, token text, expires_at timestamptz)
language plpgsql volatile security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_entry public.entries := public.ate_with_own_entry(p_entry_id);
  v_token text;
  v_row   public.entry_invites;
begin
  if public.ate_with_seats(p_entry_id) >= 6 then
    raise exception 'ate_with_cap' using errcode = '54000';
  end if;
  perform public.ate_with_spend(v_entry.author_id, 'invite', p_entry_id, null);
  -- 24 random bytes, base64url, no padding: 32 characters. Only its sha256 is kept.
  v_token := rtrim(translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/', '-_'), '=');
  insert into public.entry_invites (entry_id, inviter_id, token_hash)
  values (p_entry_id, v_entry.author_id, encode(extensions.digest(v_token, 'sha256'), 'hex'))
  returning * into v_row;
  return query select v_row.id, v_token, v_row.expires_at;
end; $$;

create or replace function public.revoke_ate_with_invite(p_invite_id uuid)
returns int language sql volatile security definer set search_path = public, extensions as $$
  with gone as (
    delete from public.entry_invites i
    where i.id = p_invite_id and i.inviter_id = (select auth.uid()) and i.redeemed_at is null
    returning 1
  )
  select count(*)::int from gone;
$$;

-- After sign-up (or by anyone already on Ate who opens the link). Single use: the first redeemer owns
-- it; the same person redeeming again gets the same row back.
create or replace function public.redeem_ate_with_invite(p_token text)
returns table (companion_id uuid, entry_id uuid, status text)
language plpgsql volatile security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_inv public.entry_invites;
  v_new uuid;
begin
  if v_uid is null then
    raise exception 'sign in to redeem' using errcode = '42501';
  end if;
  select * into v_inv from public.entry_invites i
  where i.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
  for update;
  if not found then
    raise exception 'invite_not_found' using errcode = 'P0002';
  end if;
  if v_inv.redeemed_at is not null then
    if v_inv.redeemed_by = v_uid then
      return query select c.id, c.entry_id, c.status from public.entry_companions c
                   where c.entry_id = v_inv.entry_id and c.companion_id = v_uid;
      return;
    end if;
    raise exception 'invite_used' using errcode = '23505';
  end if;
  if v_inv.expires_at <= now() then
    raise exception 'invite_expired' using errcode = '22023';
  end if;
  if v_inv.inviter_id = v_uid then
    raise exception 'cannot_tag_yourself' using errcode = '22023';
  end if;
  if public.blocked_with(v_inv.inviter_id) then
    raise exception 'blocked' using errcode = '42501';
  end if;

  update public.entry_invites set redeemed_by = v_uid, redeemed_at = now() where id = v_inv.id;
  insert into public.entry_companions (entry_id, tagger_id, companion_id, invite_id)
  values (v_inv.entry_id, v_inv.inviter_id, v_uid, v_inv.id)
  on conflict on constraint entry_companions_pair_uq do nothing   -- already tagged by handle: keep that row
  returning id into v_new;
  if v_new is not null then
    perform public.ate_with_notify(v_new, false);
  end if;
  return query select c.id, c.entry_id, c.status from public.entry_companions c
               where c.entry_id = v_inv.entry_id and c.companion_id = v_uid;
end; $$;

-- ===========================================================================
-- 8. Notifications (the companion's inbox).
-- ===========================================================================
-- The types this client renders. Legacy rows of 0011's types (likes, comments…) stay invisible.
create or replace function public.my_notifications(
  p_limit             int         default 30,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null
)
returns table (
  id               uuid,
  type             text,
  created_at       timestamptz,
  read_at          timestamptz,
  actor            jsonb,
  companion_id     uuid,
  companion_status text,
  entry_id         uuid,
  place            jsonb,
  visited_at       timestamptz
)
language plpgsql stable security invoker set search_path = public, extensions as $$
#variable_conflict use_column
begin
  -- The keyset is two-part: both fields of the last row, or neither.
  if (p_cursor_created_at is null) <> (p_cursor_id is null) then
    raise exception 'p_cursor_created_at and p_cursor_id go together' using errcode = '22023';
  end if;
  return query
  select n.id, n.type, n.created_at, n.read_at,
         jsonb_build_object('id', a.id, 'username', a.username, 'name', a.name, 'avatar_url', a.avatar_url),
         c.id, c.status, e.id,
         case when r.id is null then null else jsonb_build_object(
           'id', r.id, 'name', r.name, 'locality', public.place_locality(r.address, r.city)) end,
         e.created_at
  from public.notifications n
  join public.profiles a         on a.id = n.actor_id         -- RLS: blocked / deactivated actors vanish
  join public.entry_companions c on c.id = n.companion_id
  join public.entries e          on e.id = c.entry_id
  left join public.restaurants r on r.id = e.restaurant_id
  where n.recipient_id = (select auth.uid())
    and n.type = 'ate_with'
    and n.dismissed_at is null
    and (p_cursor_created_at is null or (n.created_at, n.id) < (p_cursor_created_at, p_cursor_id))
  order by n.created_at desc, n.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
end;
$$;

-- 0011's badge, same signature: now the count of what my_notifications can show.
create or replace function public.unread_notification_count()
returns integer language sql stable security invoker set search_path = public, extensions as $$
  select count(*)::int
  from public.notifications n
  join public.profiles a on a.id = n.actor_id
  where n.recipient_id = (select auth.uid())
    and n.type = 'ate_with'
    and n.read_at is null
    and n.dismissed_at is null;
$$;

-- ===========================================================================
-- 9. The companion's side: prefill, respond, decline.
-- ===========================================================================
-- The tag as the companion sees it, read LIVE from the original (follow, not snapshot — header).
-- Opening it marks its notification read. Not yours / withdrawn / blocked → P0002.
create or replace function public.ate_with_prefill(p_companion_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
  v_c   public.entry_companions;
  v_e   public.entries;
  v_out jsonb;
begin
  select * into v_c from public.entry_companions c where c.id = p_companion_id and c.companion_id = v_uid;
  if not found or public.blocked_with(v_c.tagger_id) then
    raise exception 'tag_not_found' using errcode = 'P0002';
  end if;
  select * into v_e from public.entries where id = v_c.entry_id;

  update public.notifications set read_at = now()
  where companion_id = v_c.id and recipient_id = v_uid and read_at is null;

  select jsonb_build_object(
    'companion_id', v_c.id,
    'status', v_c.status,
    'response_entry_id', v_c.response_entry_id,
    'entry_id', v_e.id,
    'visited_at', v_e.created_at,
    'sort_status', v_e.sort_status,
    'tagger', jsonb_build_object('id', a.id, 'username', a.username, 'name', a.name, 'avatar_url', a.avatar_url),
    'place', case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'name', r.name, 'address', r.address, 'locality', public.place_locality(r.address, r.city)) end,
    'dishes', coalesce((
      select jsonb_agg(jsonb_build_object('dish_id', x.dish_id, 'dish_name', x.name, 'position', x.pos) order by x.pos)
      from (
        select v.dish_id, d.name, min(v.entry_position) as pos   -- one row per dish (sittings collapse)
        from public.reviews v join public.dishes d on d.id = v.dish_id
        where v.entry_id = v_e.id
        group by v.dish_id, d.name
      ) x), '[]'::jsonb)
  ) into v_out
  from public.profiles a
  left join public.restaurants r on r.id = v_e.restaurant_id
  where a.id = v_c.tagger_id;
  return v_out;
end; $$;

-- Post the companion's own entry. p_entry_id is client-minted (retry-safe: the same id again returns
-- the same card). p_items = [{dish_id, score?, tags?}] in receipt order: dishes at the original's place
-- (one the tagger did not log is fine; leaving one out = "didn't have it"). Lines are the user's own,
-- stamped corrected so no re-sort ever replaces them. Notes come only from words (rule 9), so none here.
create or replace function public.respond_ate_with(
  p_companion_id uuid,
  p_entry_id     uuid,
  p_items        jsonb,
  p_body         text default ''
)
returns setof public.entry_cards
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid   uuid := (select auth.uid());
  v_c     public.entry_companions;
  v_e     public.entries;
  v_item  jsonb;
  v_dish  uuid;
  v_name  text;
  v_pos   int := 0;
  v_seen  uuid[] := '{}';
  v_body  text := coalesce(p_body, '');
begin
  select * into v_c from public.entry_companions c
  where c.id = p_companion_id and c.companion_id = v_uid
  for update;
  if not found or public.blocked_with(v_c.tagger_id) then
    raise exception 'tag_not_found' using errcode = 'P0002';
  end if;
  if v_c.status = 'accepted' then
    if v_c.response_entry_id = p_entry_id then
      return query select c.* from public.entry_cards c where c.id = p_entry_id;   -- a retry
      return;
    end if;
    raise exception 'already_responded' using errcode = '23505';
  end if;
  if v_c.status = 'declined' then
    raise exception 'tag_declined' using errcode = '22023';
  end if;
  if p_entry_id is null then
    raise exception 'p_entry_id required' using errcode = '22023';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 50 then
    raise exception 'p_items must be an array of at most 50 objects' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) = 0 and btrim(v_body) = '' then
    raise exception 'nothing_to_post' using errcode = '22023';
  end if;

  select * into v_e from public.entries where id = v_c.entry_id;

  insert into public.entries (id, author_id, body, restaurant_id, created_at)
  values (p_entry_id, v_uid, v_body, v_e.restaurant_id, v_e.created_at);   -- same visit, same time

  for v_item in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(v_item) <> 'object' or jsonb_typeof(v_item -> 'dish_id') <> 'string' then
      raise exception 'each item needs a dish_id' using errcode = '22023';
    end if;
    select coalesce(m.id, d.id), coalesce(m.name, d.name) into v_dish, v_name
    from public.dishes d
    left join public.dishes m on m.id = d.merged_into_dish_id
    where d.id = (v_item ->> 'dish_id')::uuid and d.restaurant_id = v_e.restaurant_id;
    if v_dish is null then
      raise exception 'dish_not_at_place' using errcode = '22023';
    end if;
    continue when v_dish = any(v_seen);                -- one line per dish
    v_seen := v_seen || v_dish;
    v_pos := v_pos + 1;
    insert into public.reviews
      (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, created_at, tags,
       corrected_at, corrected_from_name)
    values
      (v_uid, v_dish, v_e.restaurant_id, p_entry_id, v_pos,
       case when jsonb_typeof(v_item -> 'score') = 'number' then (v_item ->> 'score')::numeric end,
       v_e.created_at,
       case when jsonb_typeof(v_item -> 'tags') = 'array'
            then array(select jsonb_array_elements_text(v_item -> 'tags')) else '{}'::text[] end,
       now(), v_name);
  end loop;

  -- The receipt is printed: the lines are the user's. (Words, if any, may still be run through
  -- sort-entry with force — the corrected lines survive it and anything else the words name is added.)
  update public.entries
     set sort_status = 'sorted', sort_mode = 'companion', sorted_at = now()
   where id = p_entry_id;

  update public.entry_companions
     set status = 'accepted', response_entry_id = p_entry_id, responded_at = now()
   where id = v_c.id;
  update public.notifications set read_at = coalesce(read_at, now()), dismissed_at = now()
   where companion_id = v_c.id and dismissed_at is null;

  return query select c.* from public.entry_cards c where c.id = p_entry_id;
end; $$;

-- "Not me" — pending or accepted → declined. An accepted companion's own entry stays theirs, unlinked.
create or replace function public.decline_ate_with(p_companion_id uuid)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
begin
  update public.entry_companions
     set status = 'declined', response_entry_id = null, responded_at = now()
   where id = p_companion_id and companion_id = v_uid;
  if not found then
    raise exception 'tag_not_found' using errcode = 'P0002';
  end if;
  update public.notifications set read_at = coalesce(read_at, now()), dismissed_at = now()
   where companion_id = p_companion_id and dismissed_at is null;
  return 'declined';
end; $$;

-- ===========================================================================
-- 10. Device push tokens.
-- ===========================================================================
create or replace function public.register_push_token(p_token text, p_apns_env text)
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid   uuid := (select auth.uid());
  v_token text := lower(btrim(coalesce(p_token, '')));
begin
  if v_uid is null then
    raise exception 'sign in to register' using errcode = '42501';
  end if;
  if v_token !~ '^[0-9a-f]{64,200}$' or p_apns_env not in ('sandbox', 'production') then
    raise exception 'bad push token or apns_env' using errcode = '22023';
  end if;
  insert into public.device_push_tokens (token, user_id, apns_env)
  values (v_token, v_uid, p_apns_env)
  on conflict (token) do update                    -- PK: a TOTAL arbiter
    set user_id = excluded.user_id, apns_env = excluded.apns_env, last_seen_at = now();
  delete from public.device_push_tokens t
  where t.user_id = v_uid
    and t.token not in (select x.token from public.device_push_tokens x where x.user_id = v_uid
                        order by x.last_seen_at desc limit 10);
end; $$;

create or replace function public.unregister_push_token(p_token text)
returns void language sql volatile security invoker set search_path = public, extensions as $$
  delete from public.device_push_tokens
  where token = lower(btrim(coalesce(p_token, ''))) and user_id = (select auth.uid());
$$;

-- ===========================================================================
-- 11. delete_account — 0055's body verbatim, plus the four new tables in the "nothing survived" check.
-- ===========================================================================
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
  then
    raise exception 'delete_account: personal rows survived the cascade for %', v_uid
      using errcode = 'P0001';
  end if;

  return jsonb_build_object('ok', true, 'auth_user_deleted', true);
end; $$;

-- ===========================================================================
-- 12. Grants. Every RPC is signed-in only; anon gets nothing new.
-- ===========================================================================
revoke all on function public.tag_ate_with(uuid, uuid)                     from public, anon;
revoke all on function public.untag_ate_with(uuid, uuid)                   from public, anon;
revoke all on function public.create_ate_with_invite(uuid)                 from public, anon;
revoke all on function public.revoke_ate_with_invite(uuid)                 from public, anon;
revoke all on function public.redeem_ate_with_invite(text)                 from public, anon;
revoke all on function public.my_notifications(int, timestamptz, uuid)     from public, anon;
revoke all on function public.unread_notification_count()                  from public, anon;
revoke all on function public.ate_with_prefill(uuid)                       from public, anon;
revoke all on function public.respond_ate_with(uuid, uuid, jsonb, text)    from public, anon;
revoke all on function public.decline_ate_with(uuid)                       from public, anon;
revoke all on function public.register_push_token(text, text)              from public, anon;
revoke all on function public.unregister_push_token(text)                  from public, anon;
revoke all on function public.delete_account()                             from public, anon;
grant execute on function public.tag_ate_with(uuid, uuid)                  to authenticated, service_role;
grant execute on function public.untag_ate_with(uuid, uuid)                to authenticated, service_role;
grant execute on function public.create_ate_with_invite(uuid)              to authenticated, service_role;
grant execute on function public.revoke_ate_with_invite(uuid)              to authenticated, service_role;
grant execute on function public.redeem_ate_with_invite(text)              to authenticated, service_role;
grant execute on function public.my_notifications(int, timestamptz, uuid)  to authenticated, service_role;
grant execute on function public.unread_notification_count()               to authenticated, service_role;
grant execute on function public.ate_with_prefill(uuid)                    to authenticated, service_role;
grant execute on function public.respond_ate_with(uuid, uuid, jsonb, text) to authenticated, service_role;
grant execute on function public.decline_ate_with(uuid)                    to authenticated, service_role;
grant execute on function public.register_push_token(text, text)           to authenticated, service_role;
grant execute on function public.unregister_push_token(text)               to authenticated, service_role;
grant execute on function public.delete_account()                          to authenticated;
