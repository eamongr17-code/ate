-- 0010_review_tags.sql
-- Ate backend — Batch 5, TAGGING (#6): tag dining companions on a review.
--
-- Grounded in docs/specs/tagging-spike.md (model (b) LOCKED by Eamon 2026-06-20:
-- independent reviews linked by a shared dish_id; response-link model B =
-- `responding_review_id` back-link) and the established edge-table / RLS /
-- counter-trigger patterns (0003/0004/0005/0008).
--
-- LOCKED DECISIONS folded in (do not re-litigate):
--   * model (b): independent reviews funnelled onto the canonical dish_id (D-1).
--   * response link = model B back-link `responding_review_id` (D-2).
--   * tag scope = ONLY people you follow (D-6) — enforced in RLS WITH CHECK + a
--     guard-trigger assertion (defence in depth). A user may only tag someone they
--     currently follow.
--   * delivery = LIVE Realtime (D-3) — review_tags is published to supabase_realtime.
--
-- WHAT THIS IS:
--   A `review_tags` EDGE between the TAGGER's review and a TAGGED user. Model (b):
--   each person logs their OWN independent review of the same shared dish_id;
--   tagging adds the LINK and funnels the companion onto the canonical dish_id.
--   When the tagged user responds (logs their own review of the dish), their new
--   review id is written back to `responding_review_id` (model B) — an explicit
--   "Marisa's review <-tagged-> Sam, who responded with THIS review" edge.
--
-- WHAT THIS IS NOT:
--   No ghost/placeholder review row (spike §4) — a pending tag row IS the prompt.
--   No change to `reviews`. The unified notifications table lands in 0011 (a tag
--   INSERT fans out a notification there); review_tags is the source-of-truth edge.
--
-- Forward-only; no applied migration is edited or reordered. Validate on a Supabase
-- DEV BRANCH — DO NOT apply to the production project (it holds real multi-user
-- data: eamon + parisate).

set search_path = public, extensions;

-- ===========================================================================
-- TABLE: review_tags (spike §1.1 + §1.2 model B)
-- ===========================================================================
-- Edge shape mirrors review_likes (composite PK so a double-tag is a no-op /
-- idempotent), with the extra response back-link + a status lifecycle.
--
-- KEY DESIGN POINTS:
--  * PK (review_id, tagged_user_id): one tag per (review, user). A re-tag is a
--    no-op via ON CONFLICT DO NOTHING client-side — matches our idempotent-edge
--    convention (review_likes, follows).
--  * tagger_id is DENORMALISED from reviews.reviewer_id (set authoritatively by a
--    BEFORE trigger, like reviews.restaurant_id in 0005) so RLS read/Realtime
--    filters and "who tagged me" queries don't need to join reviews on every row.
--    It can never drift: the trigger always derives it from the review.
--  * responding_review_id: nullable FK->reviews. The tagged user's OWN response
--    review. Written ONLY by the tagged user (RLS + trigger below). UNIQUE so one
--    review can't be claimed as the response to two different tags (a response is
--    a 1:1 answer to a specific tag).
--  * status: 'pending' | 'rated' | 'dismissed'. CHECK-constrained (no enum type —
--    matches the project's "free text + CHECK, enums are migration-painful"
--    posture, data-model §4 / dishes.category precedent).
-- ===========================================================================
create table public.review_tags (
  review_id            uuid not null references public.reviews(id)  on delete cascade,
  tagged_user_id       uuid not null references public.profiles(id) on delete cascade,
  -- denormalised author of review_id (the person doing the tagging). Authoritative
  -- value is set by the BEFORE trigger below; any client-supplied value is ignored.
  tagger_id            uuid not null references public.profiles(id) on delete cascade,
  -- the tagged user's OWN response review (model B back-link). NULL until they rate.
  responding_review_id uuid references public.reviews(id) on delete set null,
  status               text not null default 'pending',
  created_at           timestamptz not null default now(),
  responded_at         timestamptz,
  primary key (review_id, tagged_user_id),
  -- you cannot tag yourself on your own review (no self-tag — mirrors follows_no_self)
  constraint review_tags_no_self check (tagged_user_id <> tagger_id),
  -- closed status set (data-model §4 enum posture: CHECK, not a pg enum)
  constraint review_tags_status_chk check (status in ('pending', 'rated', 'dismissed')),
  -- a given review can only be the response to ONE tag (1:1 answer)
  constraint review_tags_response_uq unique (responding_review_id)
);

comment on table public.review_tags is
  'Tag dining companions on a review (spike model b). Edge: tagger''s review -> tagged user. '
  'Scope: tagged_user_id must be someone the tagger FOLLOWS (D-6). '
  'responding_review_id is the tagged user''s own response review (model B). '
  'A pending row IS the prompt; a tag INSERT also fans out a notification (0011). Realtime-published.';
comment on column public.review_tags.tagger_id is
  'Denormalised reviews.reviewer_id of review_id (set by trigger, never client). Powers RLS + Realtime filter without a join.';
comment on column public.review_tags.responding_review_id is
  'The tagged user''s OWN response review (model B back-link). NULL until they rate. Writable only by the tagged user (RLS).';
comment on column public.review_tags.status is
  'pending (awaiting response) | rated (responded) | dismissed. CHECK-constrained, not a pg enum.';

-- ---------------------------------------------------------------------------
-- INDEXES (spike §3 item 2)
-- ---------------------------------------------------------------------------
-- "My pending prompts", newest-first — the inbox / Realtime catch-up query:
--   select * from review_tags where tagged_user_id = me [and status = 'pending']
--   order by created_at desc
create index review_tags_tagged_user_idx
  on public.review_tags (tagged_user_id, created_at desc);

-- "tags on this review" is served by the composite PK (review_id, tagged_user_id)
-- as a left-prefix lookup — no separate review_id index needed.

-- "tags I created" (the tagger's outgoing tags, e.g. notify-tagger-back later):
create index review_tags_tagger_idx
  on public.review_tags (tagger_id, created_at desc);

-- responding_review_id is already covered by the UNIQUE constraint's implicit
-- index (for "is this review a response to a tag?" lookups).

-- ===========================================================================
-- TRIGGER: derive + enforce tagger_id; enforce follows-only scope; guard the
-- response-write lifecycle.
-- ===========================================================================
-- (a) On INSERT: tagger_id := reviews.reviewer_id of review_id (authoritative —
--     ignore any client value), exactly like trg_review_set_restaurant (0005).
--     This means a user can ONLY create tags on a review whose author the row
--     resolves to; combined with the RLS WITH CHECK (tagger_id = auth.uid()), a
--     user can only tag on their OWN reviews. We derive tagger_id server-side so
--     the RLS check can't be satisfied by spoofing tagger_id to match auth.uid()
--     while pointing review_id at someone else's review.
--     ALSO enforces FOLLOWS-ONLY scope (D-6): the tagger must currently follow the
--     tagged user (a follows row (tagger_id -> tagged_user_id) must exist). This is
--     belt-and-braces with the RLS WITH CHECK below — the trigger guarantees it
--     even for service-role / future RPC writers that bypass RLS.
-- (b) On UPDATE: identity columns (review_id, tagged_user_id, tagger_id) are made
--     IMMUTABLE (re-pinned to OLD). If responding_review_id transitions NULL->set,
--     stamp responded_at and flip status to 'rated' (unless dismissed). The
--     response review MUST be authored by the tagged user AND be for the same dish
--     as the tagged review (the integrity funnel, spike §5) — enforced here so a
--     malformed back-link can't link an unrelated review.
-- SECURITY DEFINER (runs as owner) so it can read reviews/follows regardless of
-- caller; EXECUTE revoked from app roles (0008 pattern) below.
-- ===========================================================================
create or replace function public.trg_review_tag_guard()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_author      uuid;
  v_tagged_dish uuid;
  v_resp_author uuid;
  v_resp_dish   uuid;
begin
  if tg_op = 'INSERT' then
    -- derive the authoritative tagger (author of the tagged review)
    select reviewer_id into v_author
      from public.reviews where id = new.review_id;
    if v_author is null then
      raise exception 'review_tag references unknown review_id %', new.review_id;
    end if;
    new.tagger_id := v_author;             -- authoritative; ignore client value

    -- FOLLOWS-ONLY scope (D-6): the tagger must currently follow the tagged user.
    if not exists (
      select 1 from public.follows
       where follower_id = new.tagger_id
         and followee_id = new.tagged_user_id
    ) then
      raise exception 'tag scope violation: you can only tag people you follow (% does not follow %)',
        new.tagger_id, new.tagged_user_id
        using errcode = 'check_violation';
    end if;

    -- (the no-self CHECK + RLS WITH CHECK handle the rest)
    return new;
  end if;

  if tg_op = 'UPDATE' then
    -- identity of the edge is immutable post-insert
    new.tagger_id      := old.tagger_id;
    new.review_id      := old.review_id;
    new.tagged_user_id := old.tagged_user_id;

    -- response back-link transition NULL -> set: validate + stamp
    if old.responding_review_id is null and new.responding_review_id is not null then
      select reviewer_id, dish_id into v_resp_author, v_resp_dish
        from public.reviews where id = new.responding_review_id;
      if v_resp_author is null then
        raise exception 'responding_review_id % does not exist', new.responding_review_id;
      end if;
      -- the response must be authored BY the tagged user
      if v_resp_author <> new.tagged_user_id then
        raise exception 'responding review must be authored by the tagged user';
      end if;
      -- the response must be for the SAME dish as the tagged review (integrity funnel)
      select dish_id into v_tagged_dish from public.reviews where id = new.review_id;
      if v_resp_dish is distinct from v_tagged_dish then
        raise exception 'responding review must be for the same dish as the tagged review';
      end if;
      -- stamp the lifecycle (don't resurrect a dismissed tag)
      if new.status <> 'dismissed' then
        new.status := 'rated';
      end if;
      if new.responded_at is null then
        new.responded_at := now();
      end if;
    end if;

    -- a dismiss stamps responded_at if not already set
    if new.status = 'dismissed' and old.status <> 'dismissed' and new.responded_at is null then
      new.responded_at := now();
    end if;

    return new;
  end if;

  return new;
end; $$;

create trigger review_tags_guard_biu
  before insert or update on public.review_tags
  for each row execute function public.trg_review_tag_guard();

-- harden (0008 pattern): trigger fn never needs to be a callable RPC.
revoke execute on function public.trg_review_tag_guard() from public, anon, authenticated;

-- ===========================================================================
-- RLS (deny-by-default; allow AND deny both intended) — spike §6 RLS posture.
-- ===========================================================================
-- READ:   the tagger AND the tagged user can read a tag row. (Not fully public:
--         being tagged is semi-private — a tag is between the two parties. This is
--         STRICTER than the public-read posture of review_likes/follows, on
--         purpose: "who you ate with" is more sensitive than "who liked a post".)
--         A "with @sam, @lena" affordance on a review (visible to others) is a
--         SEPARATE, deferred product/privacy decision — if Eamon later wants tags
--         publicly visible on a review, widen this SELECT then.
-- INSERT: only the AUTHOR of review_id may create tags (tagger_id = auth.uid()),
--         AND only for someone they FOLLOW (D-6). tagger_id is trigger-derived from
--         the review, so the author check also guarantees the review is the
--         inserter's own. The follows-only EXISTS is duplicated here (RLS) and in
--         the guard trigger (defence in depth).
-- UPDATE: only the TAGGED user may update their own tag row (to dismiss or to set
--         the response back-link). The tagger does NOT update tag rows. Column
--         intent (status/responding_review_id/responded_at only) is enforced by the
--         guard trigger making tagger_id/review_id/tagged_user_id immutable.
-- DELETE: only the TAGGER may remove a tag (untag) — symmetric with insert. The
--         tagged user dismisses (UPDATE status), they don't delete the row.
-- ===========================================================================
alter table public.review_tags enable row level security;

-- READ: both parties only (NOT public).
create policy review_tags_select_party on public.review_tags
  for select to authenticated
  using (
    tagged_user_id = (select auth.uid())
    or tagger_id   = (select auth.uid())
  );

-- INSERT: only the author of the review, AND only tagging someone they follow.
-- WITH CHECK runs AFTER the BEFORE trigger sets tagger_id, so comparing the now-
-- authoritative tagger_id to auth.uid() correctly enforces "tag only on your own
-- review". The follows EXISTS enforces the scope at the RLS layer too.
create policy review_tags_insert_author on public.review_tags
  for insert to authenticated
  with check (
    tagger_id = (select auth.uid())
    and exists (
      select 1 from public.follows f
       where f.follower_id = (select auth.uid())
         and f.followee_id = tagged_user_id
    )
  );

-- UPDATE: only the tagged user (dismiss / set response link).
create policy review_tags_update_tagged on public.review_tags
  for update to authenticated
  using (tagged_user_id = (select auth.uid()))
  with check (tagged_user_id = (select auth.uid()));

-- DELETE: only the tagger (untag).
create policy review_tags_delete_tagger on public.review_tags
  for delete to authenticated
  using (tagger_id = (select auth.uid()));

-- ===========================================================================
-- REALTIME — the project's FIRST Supabase Realtime publication wiring.
-- ===========================================================================
-- Supabase ships a default publication `supabase_realtime` that the Realtime
-- server reads. A table only emits change events once it is ADDED to that
-- publication. No publication had been touched in this project before this
-- migration (grep: zero publication statements in 0001-0009) — so we (a) ensure
-- the publication exists (it does on a standard Supabase project; we create it
-- defensively for a bare/local Postgres where it may not), and (b) add the table.
--
-- RLS + REALTIME: Supabase Realtime enforces the table's RLS SELECT policy on
-- every broadcast change — a subscriber only receives a row if their JWT would be
-- allowed to SELECT it. Because review_tags_select_party restricts SELECT to the
-- tagger OR the tagged user, a tagged user subscribed to review_tags receives ONLY
-- the tag rows addressed to (or created by) them. No extra publication filter is
-- needed — the RLS policy IS the filter. (This is why the SELECT policy is the
-- load-bearing piece for "subscribe to tags addressed to me".)
--
-- REPLICA IDENTITY: for UPDATE/DELETE events Realtime needs the old row to route
-- the event + run RLS on the OLD row. The PK (review_id, tagged_user_id) gives a
-- default replica identity covering the PK, sufficient to ROUTE. We set REPLICA
-- IDENTITY FULL so the OLD row carries tagger_id/tagged_user_id (the RLS columns)
-- AND the full prior state on UPDATE/DELETE — required so Realtime can evaluate
-- review_tags_select_party against the old row, and so the FE inbox receives the
-- full payload of a status flip (pending->rated) or dismiss, not just the PK.
-- ===========================================================================

-- (a) ensure the publication exists (no-op on standard Supabase; safety for bare PG)
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

-- (b) full old-row in UPDATE/DELETE payloads + RLS-on-old-row (status flips, dismiss)
alter table public.review_tags replica identity full;

-- (c) add review_tags to the realtime publication (idempotent guard)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename  = 'review_tags'
  ) then
    alter publication supabase_realtime add table public.review_tags;
  end if;
end $$;

-- ===========================================================================
-- GRANTS — PostgREST exposes the table to authenticated for the tag/respond API.
-- RLS still governs which rows. anon gets nothing (tagging requires a session).
-- ===========================================================================
grant select, insert, update, delete on public.review_tags to authenticated;
