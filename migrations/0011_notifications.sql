-- 0011_notifications.sql
-- Ate backend — Batch 5, NOTIF (#2): a unified in-app notification centre.
--
-- Grounded in docs/specs/tagging-spike.md §3 ("the moment Eamon wants ONE unified
-- notification centre spanning tags + likes + comments + follows, you want a single
-- notifications table … that generic table IS item #2 NOTIF"), the locked decisions,
-- and the established edge/RLS/trigger/realtime patterns (0003/0004/0005/0008/0010).
--
-- LOCKED DECISIONS folded in (do not re-litigate):
--   * notification types v1 = ALL FOUR: 'like' | 'comment' | 'follow' | 'tag'.
--   * dismiss = SOFT-delete (dismissed_at timestamp), NOT a row DELETE.
--   * unread badge = TOTAL unread count (count of NOT-read, NOT-dismissed rows for me).
--   * delivery = LIVE Realtime — notifications is published to supabase_realtime so a
--     recipient sees new rows + read/dismiss state changes without a refresh.
--
-- MODEL: ONE polymorphic row per notifiable event. A trigger on each source edge/
-- child table (review_likes, comments, follows, review_tags) INSERTs a notification
-- addressed to the RECIPIENT (the content owner / followee / tagged user), naming the
-- ACTOR (who did it) and the SUBJECT (the review/comment/tag involved) so the FE can
-- render the row text + deep-link without re-joining four tables.
--
-- SELF-ACTION SUPPRESSION: you never get notified about your own action (liking your
-- own review, commenting on your own review, etc.) — every source trigger no-ops when
-- actor == recipient.
--
-- Forward-only; no applied migration is edited or reordered. Validate on a Supabase
-- DEV BRANCH — DO NOT apply to the production project (real multi-user data).

set search_path = public, extensions;

-- ===========================================================================
-- TABLE: notifications (polymorphic, one row per notifiable event)
-- ===========================================================================
-- COLUMNS:
--  * id            surrogate PK (a notification is its own entity, not an edge —
--                  one actor can like→unlike→like and generate multiple rows; and
--                  the same (actor,recipient,type) can recur on different subjects).
--  * recipient_id  WHO receives it. The RLS scope + the inbox/badge query key.
--  * actor_id      WHO triggered it (the liker / commenter / follower / tagger).
--  * type          'like' | 'comment' | 'follow' | 'tag' (CHECK; not a pg enum,
--                  matching the project's enum-painful posture, data-model §4).
--  * review_id     subject review for like/comment/tag (NULL for follow). FK cascade.
--  * comment_id    subject comment for 'comment' (NULL otherwise). FK cascade.
--  * read_at       NULL = unread; set when the recipient opens/reads. Drives the
--                  TOTAL-unread badge (count where read_at is null and not dismissed).
--  * dismissed_at  SOFT-delete tombstone. NULL = live; set = dismissed (hidden from
--                  the inbox, excluded from the badge). NEVER a row DELETE (locked).
--  * created_at    event time; inbox ordering + keyset cursor.
--
-- PER-TYPE SHAPE INVARIANT (CHECK): the right subject columns are populated for each
-- type so the FE can trust them:
--   like    -> review_id set,  comment_id null
--   comment -> review_id set,  comment_id set
--   follow  -> review_id null, comment_id null   (the subject IS the actor's follow of you)
--   tag     -> review_id set,  comment_id null
--
-- DEDUPE: a UNIQUE partial index collapses re-fired identical events (e.g. a
-- like→unlike→like on the same review by the same actor) into ONE live notification
-- per (recipient, actor, type, subject) while it is not dismissed — so the badge
-- doesn't inflate on toggle churn. The INSERT path uses ON CONFLICT DO NOTHING (the
-- trigger) so re-liking is a no-op. (Dismissed rows are excluded from the unique set,
-- so a fresh like AFTER a dismiss creates a new notification — intended: the recipient
-- dismissed the old one, a new action is genuinely new.)
-- ===========================================================================
create table public.notifications (
  id            uuid primary key default gen_random_uuid(),
  recipient_id  uuid not null references public.profiles(id) on delete cascade,
  actor_id      uuid not null references public.profiles(id) on delete cascade,
  type          text not null,
  review_id     uuid references public.reviews(id)  on delete cascade,
  comment_id    uuid references public.comments(id) on delete cascade,
  read_at       timestamptz,
  dismissed_at  timestamptz,
  created_at    timestamptz not null default now(),
  -- closed type set (CHECK, not a pg enum — data-model §4 posture)
  constraint notifications_type_chk check (type in ('like', 'comment', 'follow', 'tag')),
  -- you are never notified about your own action
  constraint notifications_no_self check (actor_id <> recipient_id),
  -- per-type subject shape invariant (so the FE can trust the columns by type)
  constraint notifications_shape_chk check (
    case type
      when 'like'    then review_id is not null and comment_id is null
      when 'comment' then review_id is not null and comment_id is not null
      when 'follow'  then review_id is null     and comment_id is null
      when 'tag'     then review_id is not null and comment_id is null
    end
  )
);

comment on table public.notifications is
  'Unified in-app notification centre (NOTIF #2). One polymorphic row per notifiable '
  'event (like/comment/follow/tag), inserted by source triggers. dismissed_at = soft-delete; '
  'read_at = read tracking; TOTAL-unread badge = count(read_at is null and dismissed_at is null). Realtime-published.';
comment on column public.notifications.recipient_id is 'WHO receives it. RLS scope + inbox/badge key.';
comment on column public.notifications.actor_id    is 'WHO triggered it (liker/commenter/follower/tagger).';
comment on column public.notifications.read_at     is 'NULL = unread. Drives the total-unread badge.';
comment on column public.notifications.dismissed_at is 'SOFT-delete tombstone (NULL = live). Never a row DELETE.';

-- ---------------------------------------------------------------------------
-- INDEXES
-- ---------------------------------------------------------------------------
-- Inbox: "my live notifications, newest first" (keyset on (created_at, id)).
-- Partial on NOT dismissed: the inbox never shows dismissed rows, so the hot path
-- is the live set only.
create index notifications_inbox_idx
  on public.notifications (recipient_id, created_at desc, id desc)
  where dismissed_at is null;

-- Badge: "my unread count" — partial on the exact predicate (unread AND live) so the
-- count is an index-only scan over a tiny set.
create index notifications_unread_idx
  on public.notifications (recipient_id)
  where read_at is null and dismissed_at is null;

-- DEDUPE: one LIVE notification per (recipient, actor, type, subject). Dismissed rows
-- excluded (a new action after a dismiss is genuinely new). coalesce() folds the
-- nullable subject columns into a stable key per type. The source triggers ON CONFLICT
-- DO NOTHING against this index so toggle churn (like→unlike→like) is a no-op.
create unique index notifications_dedupe_uq
  on public.notifications (
    recipient_id, actor_id, type,
    coalesce(review_id,  '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(comment_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where dismissed_at is null;

-- ===========================================================================
-- SOURCE TRIGGERS — insert a notification on each notifiable event.
-- All SECURITY DEFINER (run as owner: they read recipient ownership across tables
-- and write a recipient-addressed row that the actor's own RLS would not permit).
-- EXECUTE revoked from app roles below (0008 pattern) — trigger-only, never RPC.
-- Every one self-suppresses (no notification when actor == recipient) and uses
-- ON CONFLICT DO NOTHING against notifications_dedupe_uq (idempotent on re-fire).
-- ===========================================================================

-- like: review_likes INSERT -> notify the review's author.
create or replace function public.trg_notify_review_like()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_recipient uuid;
begin
  select reviewer_id into v_recipient from public.reviews where id = new.review_id;
  if v_recipient is null or v_recipient = new.user_id then
    return null;                              -- unknown review or self-like: no notify
  end if;
  insert into public.notifications (recipient_id, actor_id, type, review_id)
  values (v_recipient, new.user_id, 'like', new.review_id)
  on conflict do nothing;
  return null;
end; $$;
create trigger review_likes_notify_ai
  after insert on public.review_likes
  for each row execute function public.trg_notify_review_like();

-- comment: comments INSERT -> notify the review's author.
create or replace function public.trg_notify_comment()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_recipient uuid;
begin
  select reviewer_id into v_recipient from public.reviews where id = new.review_id;
  if v_recipient is null or v_recipient = new.user_id then
    return null;                              -- unknown review or self-comment: no notify
  end if;
  insert into public.notifications (recipient_id, actor_id, type, review_id, comment_id)
  values (v_recipient, new.user_id, 'comment', new.review_id, new.id)
  on conflict do nothing;
  return null;
end; $$;
create trigger comments_notify_ai
  after insert on public.comments
  for each row execute function public.trg_notify_comment();

-- follow: follows INSERT -> notify the followee.
create or replace function public.trg_notify_follow()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  -- follows_no_self already forbids self-follow, but guard anyway.
  if new.follower_id = new.followee_id then
    return null;
  end if;
  insert into public.notifications (recipient_id, actor_id, type)
  values (new.followee_id, new.follower_id, 'follow')
  on conflict do nothing;
  return null;
end; $$;
create trigger follows_notify_ai
  after insert on public.follows
  for each row execute function public.trg_notify_follow();

-- tag: review_tags INSERT -> notify the tagged user. The actor is the tagger
-- (review_tags.tagger_id is authoritatively set by the 0010 guard trigger, which
-- runs BEFORE this AFTER trigger, so tagger_id is populated here).
create or replace function public.trg_notify_review_tag()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.tagger_id = new.tagged_user_id then
    return null;                              -- defensive (no-self CHECK already forbids)
  end if;
  insert into public.notifications (recipient_id, actor_id, type, review_id)
  values (new.tagged_user_id, new.tagger_id, 'tag', new.review_id)
  on conflict do nothing;
  return null;
end; $$;
create trigger review_tags_notify_ai
  after insert on public.review_tags
  for each row execute function public.trg_notify_review_tag();

-- harden (0008 pattern): these never need to be callable RPCs.
revoke execute on function public.trg_notify_review_like() from public, anon, authenticated;
revoke execute on function public.trg_notify_comment()     from public, anon, authenticated;
revoke execute on function public.trg_notify_follow()      from public, anon, authenticated;
revoke execute on function public.trg_notify_review_tag()  from public, anon, authenticated;

-- ===========================================================================
-- RPCs — read/write helpers for the FE (all SECURITY INVOKER so RLS applies).
-- ===========================================================================

-- unread_notification_count(): the TOTAL-unread badge (locked: total, not per-type).
-- Counts the caller's notifications that are unread AND not dismissed. Rides the
-- notifications_unread_idx partial index.
create or replace function public.unread_notification_count()
returns integer
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select count(*)::int
  from public.notifications
  where recipient_id = (select auth.uid())
    and read_at is null
    and dismissed_at is null;
$$;
comment on function public.unread_notification_count() is
  'TOTAL unread badge count for the caller (read_at is null and dismissed_at is null).';

-- dismiss_notification(id): SOFT-delete a single notification (locked: soft, not hard).
-- Stamps dismissed_at; idempotent (already-dismissed stays dismissed). RLS confines it
-- to the caller's own rows (the WHERE recipient_id = auth.uid() is belt-and-braces).
create or replace function public.dismiss_notification(p_id uuid)
returns void
language sql
volatile
security invoker
set search_path = public, extensions
as $$
  update public.notifications
     set dismissed_at = now()
   where id = p_id
     and recipient_id = (select auth.uid())
     and dismissed_at is null;
$$;
comment on function public.dismiss_notification(uuid) is
  'Soft-delete (dismiss) one of the caller''s notifications. Idempotent. Never a row DELETE.';

-- mark_notifications_read(): mark ALL the caller's live notifications as read (clears
-- the badge on opening the inbox). Returns the number marked. Idempotent.
create or replace function public.mark_notifications_read()
returns integer
language plpgsql
volatile
security invoker
set search_path = public, extensions
as $$
declare
  v_n int;
begin
  update public.notifications
     set read_at = now()
   where recipient_id = (select auth.uid())
     and read_at is null
     and dismissed_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end; $$;
comment on function public.mark_notifications_read() is
  'Mark all the caller''s unread, live notifications as read (clears the badge). Returns count.';

-- ===========================================================================
-- RLS — a user sees ONLY their own notifications (deny-by-default).
-- ===========================================================================
-- READ:   recipient only. (Strictly private — a notification is addressed to you.)
-- INSERT: NO end-user INSERT policy. Notifications are created exclusively by the
--         SECURITY DEFINER source triggers (which bypass RLS). Deny-by-default means
--         authenticated/anon cannot forge a notification to another user.
-- UPDATE: recipient only, and only the read/dismiss columns matter. The update guard
--         trigger below pins identity columns immutable so an UPDATE can only touch
--         read_at/dismissed_at — a recipient cannot rewrite who/what/when. (The
--         dismiss/mark-read RPCs are SECURITY INVOKER and go through this policy.)
-- DELETE: NO policy — dismiss is SOFT (dismissed_at), never a hard DELETE (locked).
-- ===========================================================================
alter table public.notifications enable row level security;

create policy notifications_select_own on public.notifications
  for select to authenticated
  using (recipient_id = (select auth.uid()));

create policy notifications_update_own on public.notifications
  for update to authenticated
  using (recipient_id = (select auth.uid()))
  with check (recipient_id = (select auth.uid()));

-- Guard: on UPDATE, identity/content columns are immutable; only read_at/dismissed_at
-- may change. Prevents a recipient from rewriting actor/type/subject via a raw UPDATE.
create or replace function public.trg_notification_update_guard()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  new.id           := old.id;
  new.recipient_id := old.recipient_id;
  new.actor_id     := old.actor_id;
  new.type         := old.type;
  new.review_id    := old.review_id;
  new.comment_id   := old.comment_id;
  new.created_at   := old.created_at;
  return new;
end; $$;
create trigger notifications_update_guard_bu
  before update on public.notifications
  for each row execute function public.trg_notification_update_guard();

revoke execute on function public.trg_notification_update_guard() from public, anon, authenticated;

-- ===========================================================================
-- REALTIME — live delivery of new notifications + read/dismiss state changes.
-- ===========================================================================
-- review_tags (0010) was the first table added to supabase_realtime; this adds the
-- notifications table. RLS-on-broadcast: Realtime runs notifications_select_own on
-- every change, so a subscriber receives ONLY rows where recipient_id = their uid —
-- the SELECT policy IS the per-user filter (no publication-level filter needed).
--
-- REPLICA IDENTITY FULL: so UPDATE events (read_at / dismissed_at transitions) carry
-- the OLD row for RLS-on-old-row routing and the FE gets the full prior+new payload
-- (e.g. to decrement the badge on a read/dismiss without a re-fetch).
-- ===========================================================================
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

alter table public.notifications replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename  = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- ===========================================================================
-- GRANTS — PostgREST exposes the table (read/update only) + the RPCs to
-- authenticated. RLS governs which rows. No INSERT/DELETE grant: rows are created
-- by triggers and removed only by soft-dismiss. anon gets nothing.
-- ===========================================================================
grant select, update on public.notifications to authenticated;
grant execute on function public.unread_notification_count() to authenticated;
grant execute on function public.dismiss_notification(uuid)  to authenticated;
grant execute on function public.mark_notifications_read()   to authenticated;
