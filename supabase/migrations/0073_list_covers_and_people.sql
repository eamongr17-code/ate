-- 0073_list_covers_and_people.sql
-- Ate backend — LIST COVERS + PEOPLE ON A LIST (Eamon, 18 Oct 2026; design/rebuild/list-cover-edit.html).
--
-- COVERS. A list's cover is automatic (a mosaic of the first four item photos, or the first photo when
--   there are fewer — unchanged, `covers`) until the owner picks one:
--   * a dish photo already in the list → `cover_item_id`. Resolved LIVE through the item, so the cover
--     follows that line's photo, and goes back to automatic when the item leaves the list (no FK: a
--     stale id simply resolves to nothing — items and lists already cascade into each other);
--   * an uploaded photo → `cover_url`, the public URL of the caller's own object at
--     review-photos/<uid>/list-covers/<file> (0007's insert policy already scopes that prefix; the URL is
--     checked here so a cover can never point anywhere else). At most one of the two is set.
--   Reads add `cover_url` = the resolved custom cover (null = automatic).
--
-- PEOPLE. The owner invites people; each invite lands in the invitee's Notifications ("List invites")
--   with a push, and the list joins their Lists view only once they ACCEPT. Declining is silent (the row
--   goes; the owner sees them unticked). Members VIEW (open, share); every write stays the owner's
--   (list_own is unchanged, so a member's write is P0002 exactly like a stranger's). Members can leave.
--   Never yourself, never across a block (either direction — a block hides the list both ways at once,
--   through the visibility helper, without touching rows). ≤ 20 people per list.
--
-- ─── Storage
--   user_lists + cover_item_id uuid, cover_url text (CHECK: not both).
--   user_list_members (list_id, user_id, status invited | accepted, invited_at, accepted_at). PK (list_id,
--     user_id). RLS: SELECT your own rows, or every row of a list you own. No client write grant.
--   notifications + list_id (→ user_lists, cascade), type 'list_invite'. A re-invite within 7 days of an
--     earlier invite notification for the same list is QUIET (born read + pushed: no push, no badge),
--     so ticking someone on and off cannot spam them.
--
-- ─── RPCs (signed in only)
--   set_list_cover(p_list_id, p_item_id, p_photo_url) — both null = automatic. Owner only.
--   list_people(p_list_id) · set_list_people(p_list_id, p_user_ids uuid[]) — the picker's whole set.
--   my_list_invites() · respond_list_invite(p_list_id, p_accept) · leave_list(p_list_id)
--   my_lists(…, p_with_shared default false) — DROPPED + recreated: + cover_url, is_own, owner,
--     shelved_at. Old 3-argument calls answer exactly as before (own lists only, created_at order).
--   get_list — members (invited or accepted) may read; + cover_url, cover_item_id, covers, is_own,
--     membership, owner, people.
--   push_claim_list_invites(p_limit) (service_role) — send-push's second claim.
--
-- WIRE IMPACT: ADDITIVE for every existing caller. my_lists gains trailing columns and an optional
--   parameter (signature change → drop/create, grants restated). unread_notification_count now also
--   counts unanswered list invites.

set search_path = public, extensions;

-- ===========================================================================
-- 1. Tables + columns.
-- ===========================================================================
alter table public.user_lists add column if not exists cover_item_id uuid;
alter table public.user_lists add column if not exists cover_url     text;
alter table public.user_lists drop constraint if exists user_lists_cover_ck;
alter table public.user_lists add constraint user_lists_cover_ck check (cover_item_id is null or cover_url is null);

create table if not exists public.user_list_members (
  list_id     uuid        not null references public.user_lists(id) on delete cascade,
  user_id     uuid        not null references public.profiles(id)   on delete cascade,
  status      text        not null default 'invited',
  invited_at  timestamptz not null default now(),
  accepted_at timestamptz,
  primary key (list_id, user_id),
  constraint user_list_members_status_ck check (status in ('invited', 'accepted')),
  constraint user_list_members_accepted_ck check ((status = 'accepted') = (accepted_at is not null))
);
create index if not exists user_list_members_user_idx on public.user_list_members (user_id, status);

comment on table public.user_list_members is
  'People on a list (0073): invited → accepted (declining deletes the row). Members view; the owner writes. ≤ 20 per list. Own rows + the owner read; written by RPCs.';

alter table public.user_list_members enable row level security;
drop policy if exists user_list_members_select on public.user_list_members;
create policy user_list_members_select on public.user_list_members
  for select to authenticated using (
    user_id = (select auth.uid())
    or exists (select 1 from public.user_lists l where l.id = list_id and l.owner_id = (select auth.uid())));
revoke all on public.user_list_members from anon, authenticated;
grant select on public.user_list_members to authenticated;
grant all    on public.user_list_members to service_role;

-- ===========================================================================
-- 2. Who may see a list: its owner, or a member (invited or accepted) with no block either way.
-- DEFINER so the policies below can ask without recursing through user_list_members' own RLS.
-- ===========================================================================
create or replace function public.list_visible(p_list_id uuid)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.user_lists l
    where l.id = p_list_id
      and (l.owner_id = (select auth.uid())
           or (exists (select 1 from public.user_list_members m
                       where m.list_id = l.id and m.user_id = (select auth.uid()))
               and not public.blocked_with(l.owner_id)
               and exists (select 1 from public.profiles o where o.id = l.owner_id and o.deleted_at is null))));
$$;
revoke all on function public.list_visible(uuid) from public, anon;
grant execute on function public.list_visible(uuid) to authenticated, service_role;

drop policy if exists user_lists_select_member on public.user_lists;
create policy user_lists_select_member on public.user_lists
  for select to authenticated using (public.list_visible(id));
drop policy if exists user_list_items_select_member on public.user_list_items;
create policy user_list_items_select_member on public.user_list_items
  for select to authenticated using (public.list_visible(list_id));

-- The custom cover, resolved (null = automatic). An item pick must still be in the list.
create or replace function public.list_cover(p_list_id uuid)
returns text language sql stable security definer set search_path = public, extensions as $$
  select coalesce(l.cover_url,
                  (select public.list_item_photo(i.entry_id, i.dish_id)
                   from public.user_list_items i where i.id = l.cover_item_id and i.list_id = l.id))
  from public.user_lists l where l.id = p_list_id;
$$;

-- The automatic cover: ≤ 4 distinct item photos in list order (0060's rule).
create or replace function public.list_covers(p_list_id uuid)
returns text[] language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select array_agg(u.url order by u.first_pos)
                   from (select ph.url, min(ph.pos) first_pos
                         from (select public.list_item_photo(i.entry_id, i.dish_id) url, i.position pos
                               from public.user_list_items i where i.list_id = p_list_id) ph
                         where ph.url is not null
                         group by ph.url order by min(ph.pos) limit 4) u), '{}'::text[]);
$$;

create or replace function public.list_person(p_user_id uuid)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('id', p.id, 'username', p.username, 'name', p.name, 'avatar_url', p.avatar_url)
  from public.profiles p where p.id = p_user_id;
$$;

revoke all on function public.list_cover(uuid)   from public, anon, authenticated;
revoke all on function public.list_covers(uuid)  from public, anon, authenticated;
revoke all on function public.list_person(uuid)  from public, anon, authenticated;

-- ===========================================================================
-- 3. Notifications: the 'list_invite' type.
-- ===========================================================================
alter table public.notifications add column if not exists list_id uuid references public.user_lists(id) on delete cascade;
create index if not exists notifications_list_idx on public.notifications (list_id) where list_id is not null;

alter table public.notifications drop constraint if exists notifications_type_chk;
alter table public.notifications add constraint notifications_type_chk
  check (type in ('like', 'comment', 'follow', 'tag', 'ate_with', 'list_invite'));
alter table public.notifications drop constraint if exists notifications_shape_chk;
alter table public.notifications add constraint notifications_shape_chk check (
  case type
    when 'like'        then review_id is not null and comment_id is null     and companion_id is null     and list_id is null
    when 'comment'     then review_id is not null and comment_id is not null and companion_id is null     and list_id is null
    when 'follow'      then review_id is null     and comment_id is null     and companion_id is null     and list_id is null
    when 'tag'         then review_id is not null and comment_id is null     and companion_id is null     and list_id is null
    when 'ate_with'    then review_id is null     and comment_id is null     and companion_id is not null and list_id is null
    when 'list_invite' then review_id is null     and comment_id is null     and companion_id is null     and list_id is not null
  end
);
drop index if exists public.notifications_dedupe_uq;
create unique index if not exists notifications_dedupe_uq
  on public.notifications (
    recipient_id, actor_id, type,
    coalesce(review_id,    '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(comment_id,   '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(companion_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(list_id,      '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where dismissed_at is null;
create index if not exists notifications_push_pending_list_idx
  on public.notifications (created_at)
  where type = 'list_invite' and pushed_at is null and read_at is null and dismissed_at is null;

-- 0059's guard, plus list_id: a recipient may change read_at / dismissed_at, nothing else.
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
  new.list_id      := old.list_id;
  new.created_at   := old.created_at;
  if (select auth.uid()) is not null then
    new.pushed_at       := old.pushed_at;
    new.push_claimed_at := old.push_claimed_at;
    new.push_attempts   := old.push_attempts;
  end if;
  return new;
end; $$;
revoke execute on function public.trg_notification_update_guard() from public, anon, authenticated;

-- The bell / app badge for one person: unread "ate with" tags + unanswered list invites.
create or replace function public.notification_badge(p_uid uuid)
returns int language sql stable security definer set search_path = public, extensions as $$
  select (select count(*)::int
          from public.notifications n
          join public.profiles a on a.id = n.actor_id and a.deleted_at is null
          where n.recipient_id = p_uid and n.type = 'ate_with'
            and n.read_at is null and n.dismissed_at is null
            and not exists (select 1 from public.blocks b
                            where (b.blocker_id = p_uid and b.blocked_id = n.actor_id)
                               or (b.blocker_id = n.actor_id and b.blocked_id = p_uid)))
       + (select count(*)::int
          from public.user_list_members m
          join public.user_lists l on l.id = m.list_id
          join public.profiles o   on o.id = l.owner_id and o.deleted_at is null
          where m.user_id = p_uid and m.status = 'invited'
            and not exists (select 1 from public.blocks b
                            where (b.blocker_id = p_uid and b.blocked_id = l.owner_id)
                               or (b.blocker_id = l.owner_id and b.blocked_id = p_uid)));
$$;
revoke all on function public.notification_badge(uuid) from public, anon, authenticated;

-- 0058's badge, same signature: now the count of what the Notifications page shows waiting.
create or replace function public.unread_notification_count()
returns integer language sql stable security definer set search_path = public, extensions as $$
  select case when (select auth.uid()) is null then 0 else public.notification_badge((select auth.uid())) end;
$$;

-- ===========================================================================
-- 4. Covers.
-- ===========================================================================
-- p_item_id: an item of this list whose line has a photo · p_photo_url: your own upload · neither: automatic.
create or replace function public.set_list_cover(p_list_id uuid, p_item_id uuid default null, p_photo_url text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
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
       or v_url !~ ('^https://[A-Za-z0-9.-]+(:[0-9]+)?/storage/v1/object/public/review-photos/'
                    || v_list.owner_id::text || '/list-covers/[A-Za-z0-9._-]+(\?[A-Za-z0-9=&._-]*)?$')) then
    raise exception 'bad_cover_url' using errcode = '22023';
  end if;
  update public.user_lists l set cover_item_id = p_item_id, cover_url = v_url, updated_at = now()
  where l.id = v_list.id;
  return jsonb_build_object('list_id', v_list.id, 'cover_item_id', p_item_id,
                            'cover_url', public.list_cover(v_list.id));
end; $$;

-- ===========================================================================
-- 5. People.
-- ===========================================================================
-- Owner: everyone invited or accepted. Member: the accepted people. Blocked and deactivated people are absent.
create or replace function public.list_people(p_list_id uuid)
returns table (user_id uuid, username text, name text, avatar_url text, status text, invited_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_uid  uuid := (select auth.uid());
  v_list public.user_lists;
begin
  if v_uid is null then
    raise exception 'sign in to use lists' using errcode = '42501';
  end if;
  select * into v_list from public.user_lists l where l.id = p_list_id;
  if not found or not public.list_visible(p_list_id) then
    raise exception 'list_not_found' using errcode = 'P0002';
  end if;
  return query
  select p.id, p.username::text, p.name::text, p.avatar_url::text, m.status, m.invited_at
  from public.user_list_members m
  join public.profiles p on p.id = m.user_id
  where m.list_id = p_list_id
    and p.deleted_at is null
    and not public.blocked_with(m.user_id)
    and (v_list.owner_id = v_uid or m.status = 'accepted')
  order by m.status = 'invited', coalesce(m.accepted_at, m.invited_at), p.username;
end; $$;

-- The picker's commit: p_user_ids is the WHOLE set the owner wants on the list. New people are invited
-- (notified); people left out are taken off (an unanswered invite is withdrawn with its notification).
-- Yourself, unknown, deactivated and blocked ids are skipped. > 20 → 54000 list_people_cap.
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

-- My unanswered invites, newest first (the Notifications page's "List invites").
create or replace function public.my_list_invites()
returns table (list_id uuid, name text, item_count int, covers text[], cover_url text, owner jsonb, invited_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'sign in to use lists' using errcode = '42501';
  end if;
  return query
  select l.id, l.name,
         (select count(*)::int from public.user_list_items i where i.list_id = l.id),
         public.list_covers(l.id), public.list_cover(l.id), public.list_person(l.owner_id), m.invited_at
  from public.user_list_members m
  join public.user_lists l on l.id = m.list_id
  join public.profiles o   on o.id = l.owner_id
  where m.user_id = v_uid and m.status = 'invited'
    and o.deleted_at is null and not public.blocked_with(l.owner_id)
  order by m.invited_at desc, l.id desc;
end; $$;

-- Accept → the list joins your Lists view · decline → the invite goes (the owner is not told).
-- Answers 'accepted' | 'declined'. No invite (withdrawn, already answered no, list gone) → P0002.
create or replace function public.respond_list_invite(p_list_id uuid, p_accept boolean)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
  v_m   public.user_list_members;
begin
  if v_uid is null then
    raise exception 'sign in to use lists' using errcode = '42501';
  end if;
  select * into v_m from public.user_list_members m where m.list_id = p_list_id and m.user_id = v_uid for update;
  if not found or not public.list_visible(p_list_id) then
    raise exception 'invite_not_found' using errcode = 'P0002';
  end if;
  update public.notifications n set read_at = coalesce(n.read_at, now()), dismissed_at = now()
  where n.type = 'list_invite' and n.list_id = p_list_id and n.recipient_id = v_uid and n.dismissed_at is null;
  if coalesce(p_accept, false) then
    if v_m.status = 'invited' then
      update public.user_list_members m set status = 'accepted', accepted_at = now()
      where m.list_id = p_list_id and m.user_id = v_uid;
    end if;
    return 'accepted';
  end if;
  delete from public.user_list_members m where m.list_id = p_list_id and m.user_id = v_uid;
  return 'declined';
end; $$;

-- Off a list someone else owns. 1 left · 0 not on it.
create or replace function public.leave_list(p_list_id uuid)
returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
  v_n   int;
begin
  if v_uid is null then
    raise exception 'sign in to use lists' using errcode = '42501';
  end if;
  delete from public.user_list_members m where m.list_id = p_list_id and m.user_id = v_uid;
  get diagnostics v_n = row_count;
  update public.notifications n set read_at = coalesce(n.read_at, now()), dismissed_at = now()
  where n.type = 'list_invite' and n.list_id = p_list_id and n.recipient_id = v_uid and n.dismissed_at is null;
  return v_n;
end; $$;

-- ===========================================================================
-- 6. Reads: my_lists (+ shared, + cover, + owner) and get_list (members may read).
-- ===========================================================================
drop function if exists public.my_lists(int, timestamptz, uuid);
create or replace function public.my_lists(
  p_limit             int         default 50,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_with_shared       boolean     default false
)
returns table (list_id uuid, name text, visibility text, item_count int, covers text[],
               created_at timestamptz, updated_at timestamptz,
               cover_url text, is_own boolean, owner jsonb, shelved_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'sign in to use lists' using errcode = '42501';
  end if;
  if (p_cursor_created_at is null) <> (p_cursor_id is null) then
    raise exception 'p_cursor_created_at and p_cursor_id go together' using errcode = '22023';
  end if;
  -- The shelf's key is `shelved_at` (own: made; shared: accepted) — p_cursor_created_at carries it.
  return query
  with shelf as (
    select l.*, l.created_at as shelved, true as own
    from public.user_lists l where l.owner_id = v_uid
    union all
    select l.*, m.accepted_at, false
    from public.user_list_members m
    join public.user_lists l on l.id = m.list_id
    where coalesce(p_with_shared, false)
      and m.user_id = v_uid and m.status = 'accepted'
      and public.list_visible(l.id)
  )
  select s.id, s.name, s.visibility,
         (select count(*)::int from public.user_list_items i where i.list_id = s.id),
         public.list_covers(s.id), s.created_at, s.updated_at,
         public.list_cover(s.id), s.own, public.list_person(s.owner_id), s.shelved
  from shelf s
  where p_cursor_created_at is null or (s.shelved, s.id) < (p_cursor_created_at, p_cursor_id)
  order by s.shelved desc, s.id desc
  limit least(greatest(coalesce(p_limit, 50), 1), 50);
end; $$;

-- One list with its items, in order. Yours, or one you are on (invited: a preview before answering).
-- Neither / gone → P0002.
create or replace function public.get_list(p_list_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_uid  uuid := (select auth.uid());
  v_list public.user_lists;
  v_role text;
begin
  if v_uid is null then
    raise exception 'sign in to use lists' using errcode = '42501';
  end if;
  select * into v_list from public.user_lists where id = p_list_id;
  if not found or not public.list_visible(p_list_id) then
    raise exception 'list_not_found' using errcode = 'P0002';
  end if;
  v_role := case when v_list.owner_id = v_uid then 'owner'
                 else (select m.status from public.user_list_members m
                       where m.list_id = v_list.id and m.user_id = v_uid) end;
  if v_role is null then
    raise exception 'list_not_found' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'list_id', v_list.id, 'name', v_list.name, 'visibility', v_list.visibility,
    'created_at', v_list.created_at, 'updated_at', v_list.updated_at,
    'item_count', (select count(*) from public.user_list_items i where i.list_id = v_list.id),
    'covers', to_jsonb(public.list_covers(v_list.id)),
    'cover_url', public.list_cover(v_list.id),
    'cover_item_id', v_list.cover_item_id,
    'is_own', v_role = 'owner',
    'membership', v_role,
    'owner', public.list_person(v_list.owner_id),
    'people', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', p.user_id, 'username', p.username, 'name', p.name, 'avatar_url', p.avatar_url,
                 'status', p.status)) from public.list_people(v_list.id) p), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'item_id', i.id, 'position', i.position, 'entry_id', i.entry_id, 'dish_id', i.dish_id,
               'dish_name', d.name, 'restaurant_id', p.id, 'restaurant_name', p.name,
               'locality', public.place_locality(p.address, p.city),
               'score', public.list_item_score(i.entry_id, i.dish_id),
               'photo_url', public.list_item_photo(i.entry_id, i.dish_id),
               'visited_at', e.created_at, 'added_at', i.added_at)
             order by i.position, i.id)
      from public.user_list_items i
      join public.entries e     on e.id = i.entry_id
      join public.dishes d      on d.id = i.dish_id
      join public.restaurants p on p.id = d.restaurant_id
      where i.list_id = v_list.id), '[]'::jsonb));
end; $$;

-- ===========================================================================
-- 7. Push: list invites ride 0059's sender.
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
      and e.sort_status in ('sorted', 'failed')
      and a.deleted_at is null and r.deleted_at is null
      and not exists (select 1 from public.blocks b
                      where (b.blocker_id = n.actor_id and b.blocked_id = n.recipient_id)
                         or (b.blocker_id = n.recipient_id and b.blocked_id = n.actor_id))
  ) or exists (
    select 1
    from public.notifications n
    join public.user_list_members m on m.list_id = n.list_id and m.user_id = n.recipient_id
    join public.profiles a          on a.id = n.actor_id
    join public.profiles r          on r.id = n.recipient_id
    where n.id = p_id
      and n.type = 'list_invite'
      and n.pushed_at is null and n.read_at is null and n.dismissed_at is null
      and n.created_at > now() - interval '24 hours'
      and n.push_attempts < 5
      and (n.push_claimed_at is null or n.push_claimed_at < now() - interval '2 minutes')
      and m.status = 'invited'
      and a.deleted_at is null and r.deleted_at is null
      and not exists (select 1 from public.blocks b
                      where (b.blocker_id = n.actor_id and b.blocked_id = n.recipient_id)
                         or (b.blocker_id = n.recipient_id and b.blocked_id = n.actor_id))
  );
$$;

-- 0059's claim, its badge now the whole bell (notification_badge).
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
         public.notification_badge(n.recipient_id),
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

create or replace function public.push_claim_list_invites(p_limit int default 50)
returns table (
  notification_id uuid,
  list_id         uuid,
  recipient_id    uuid,
  actor_username  text,
  list_name       text,
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
    where n.type = 'list_invite' and n.pushed_at is null and n.read_at is null and n.dismissed_at is null
      and n.created_at > now() - interval '24 hours'
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
  select n.id, l.id, n.recipient_id, a.username::text, l.name,
         public.notification_badge(n.recipient_id),
         coalesce((select jsonb_agg(jsonb_build_object('token', t.token, 'apns_env', t.apns_env)
                                    order by t.last_seen_at desc)
                   from public.device_push_tokens t where t.user_id = n.recipient_id), '[]'::jsonb)
  from public.notifications n
  join public.user_lists l on l.id = n.list_id
  join public.profiles a   on a.id = n.actor_id
  where n.id = any(v_ids)
  order by n.created_at;
end; $$;

create or replace function public.push_kick()
returns boolean language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_url text;
  v_key text;
begin
  if not exists (
    select 1 from public.notifications n
    where n.type in ('ate_with', 'list_invite')
      and n.pushed_at is null and n.read_at is null and n.dismissed_at is null
      and n.created_at > now() - interval '24 hours'
      and public.push_is_ready(n.id)
  ) then
    return false;
  end if;
  execute $q$select (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_url'),
                    (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_kick_secret')$q$
    into v_url, v_key;
  if v_url is null or v_key is null then
    return false;
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
  if new.type in ('ate_with', 'list_invite') and new.pushed_at is null and new.read_at is null then
    perform public.push_kick();
  end if;
  return null;
exception when others then
  return null;
end; $$;

-- ===========================================================================
-- 8. Grants.
-- ===========================================================================
revoke all on function public.set_list_cover(uuid, uuid, text)                 from public, anon;
revoke all on function public.list_people(uuid)                                from public, anon;
revoke all on function public.set_list_people(uuid, uuid[])                    from public, anon;
revoke all on function public.my_list_invites()                                from public, anon;
revoke all on function public.respond_list_invite(uuid, boolean)               from public, anon;
revoke all on function public.leave_list(uuid)                                 from public, anon;
revoke all on function public.my_lists(int, timestamptz, uuid, boolean)        from public, anon;
revoke all on function public.get_list(uuid)                                   from public, anon;
revoke all on function public.unread_notification_count()                      from public, anon;
grant execute on function public.set_list_cover(uuid, uuid, text)              to authenticated, service_role;
grant execute on function public.list_people(uuid)                             to authenticated, service_role;
grant execute on function public.set_list_people(uuid, uuid[])                 to authenticated, service_role;
grant execute on function public.my_list_invites()                             to authenticated, service_role;
grant execute on function public.respond_list_invite(uuid, boolean)            to authenticated, service_role;
grant execute on function public.leave_list(uuid)                              to authenticated, service_role;
grant execute on function public.my_lists(int, timestamptz, uuid, boolean)     to authenticated, service_role;
grant execute on function public.get_list(uuid)                                to authenticated, service_role;
grant execute on function public.unread_notification_count()                   to authenticated, service_role;

revoke all on function public.push_is_ready(uuid)            from public, anon, authenticated;
revoke all on function public.push_claim_ate_with(int)       from public, anon, authenticated;
revoke all on function public.push_claim_list_invites(int)   from public, anon, authenticated;
revoke all on function public.push_kick()                    from public, anon, authenticated;
revoke all on function public.trg_push_kick_on_notification() from public, anon, authenticated;
grant execute on function public.push_claim_ate_with(int)     to service_role;
grant execute on function public.push_claim_list_invites(int) to service_role;
