-- 0018_entries.sql
-- Ate backend — V1 RETHINK (CEO re-scope 2026-09-22): the ENTRY becomes the atom
-- the user creates. docs/DESIGN.md rules 7-9 are the law this migration encodes:
--
--   rule 9  "The user's words are saved instantly and never rewritten."
--           → `entries.body` is written by ONE client insert, with no dependency on
--             photos, place, dishes or the sorter. Nothing server-side ever edits it.
--   rule 8  "A place is only attached when the user names it or taps it."
--           → `entries.restaurant_id` is NULLABLE and carries a provenance column
--             (`restaurant_source`) that records which of the two happened. There is
--             no code path anywhere that derives it from device location.
--   rule 7  "Scores are only ever the user's. Never inferred."
--           → `reviews.score` becomes NULLABLE (an unscored dish review is the
--             normal case: "empty star, no text"), and gains `score_evidence` — the
--             literal slice of the user's words that justified the number. 0021's
--             apply_entry_sort REFUSES to store a score whose evidence is not a
--             substring of the entry body, so no sorter (stub or model) can ever
--             invent one. `dish_stats` already ignores NULL scores (avg() skips
--             NULLs) — 0022 adds the explicit scored/people counts beside it.
--
-- SHAPE:  entry (1) ──< entry_photos          (photos land as uploads finish)
--         entry (1) ──< reviews (entry_id)    (the sorter's dish reviews)
--
-- The per-dish `reviews` row STAYS the aggregate atom — it is LINKED to an entry,
-- not replaced. Legacy reviews (entry_id IS NULL) keep working untouched.
--
-- Multiple reviews per (user, dish) remain allowed BY DESIGN (sittings). No unique
-- constraint is added on (reviewer_id, dish_id) — ever.
--
-- WIRE IMPACT (annotated per the contract rule):
--   ADDITIVE : tables `entries`, `entry_photos`; columns `reviews.entry_id`,
--              `reviews.entry_position`, `reviews.score_evidence`,
--              `profiles.entry_seq`, `profiles.city`.
--   BREAKING : `reviews.score` numeric NOT NULL → NULLABLE. Any reader that decodes
--              it as a non-optional number breaks. Sequenced with iOS through the
--              lead; the Swift V1 client is being written against this from the
--              start, so nothing shipped is broken today.
--
-- Forward-only, re-runnable where sensible. No applied migration is edited.

set search_path = public, extensions;

-- ===========================================================================
-- profiles — two additive columns.
--   entry_seq : the per-user order-number counter. NOT the truth of anything the
--               user sees on its own; it exists so allocation is a single row-
--               locked UPDATE (see trg_entry_biu) instead of a racy max()+1.
--   city      : shown under the handle on You/Profile (design/v1/You.dc.html).
-- ===========================================================================
alter table public.profiles add column if not exists entry_seq integer not null default 0;
alter table public.profiles add column if not exists city      text;

comment on column public.profiles.entry_seq is
  'Per-user order-number high-water mark. Allocated by trg_entry_biu under a row lock; never client-writable.';
comment on column public.profiles.city is 'Optional home city shown under the handle (design/v1/You).';

-- ===========================================================================
-- entries — ONE VISIT. The thing the user creates.
--
-- created_at is CLIENT-SETTABLE (see the column grants below) so an entry written
-- offline keeps the instant the user wrote it, not the instant it reached us. The
-- order number is allocated on ARRIVAL, so an offline entry can carry an older
-- created_at than a lower order number. That is deliberate and honest: "Order #"
-- is the sequence in which Ate printed receipts, created_at is when you ate.
-- ===========================================================================
create table public.entries (
  id                uuid primary key default gen_random_uuid(),
  author_id         uuid not null references public.profiles(id) on delete cascade,

  -- The user's words, verbatim. May be '' for a photos-only entry. NEVER rewritten
  -- by any server path (rule 9) — the sorter reads it and writes elsewhere.
  body              text not null default '',

  -- public BY DEFAULT (CEO re-scope). Per-entry, not per-account.
  visibility        text not null default 'public',

  -- rule 8: NULL until the user names it in the words (sorter match) or taps it.
  restaurant_id     uuid references public.restaurants(id) on delete set null,
  restaurant_source text,

  -- "Order #0142" — per-user sequential, server-allocated (never client-supplied).
  order_number      integer not null,

  -- so the app can show words immediately and the receipt when it exists
  sort_status       text not null default 'pending',
  sort_mode         text,
  sort_error        text,
  sorted_at         timestamptz,
  -- the sorter's last VALIDATED plan, verbatim. Kept for two reasons: it lets
  -- correct_entry_place re-apply dish findings for an entry that was sorted with no
  -- place (no restaurant ⇒ no dishes can exist yet), and it is the audit trail for
  -- the stub-vs-model eval harness. Internal/debug — not on the entry_cards read.
  sort_plan         jsonb,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint entries_visibility_ck  check (visibility in ('public', 'private')),
  constraint entries_sort_status_ck check (sort_status in ('pending', 'sorted', 'failed')),
  constraint entries_restaurant_source_ck check (
    restaurant_source is null or restaurant_source in ('user', 'sorter')
  ),
  -- a place attached at all must carry its provenance, and vice versa (rule 8,
  -- enforced on every write path rather than trusted to callers)
  constraint entries_place_provenance_ck check (
    (restaurant_id is null and restaurant_source is null)
    or (restaurant_id is not null and restaurant_source is not null)
  ),
  constraint entries_order_number_ck check (order_number > 0)
);

comment on table public.entries is
  'One visit: the user''s verbatim words + photos + visibility + optional place + per-user order number. The atom the user creates (V1 re-scope 2026-09-22).';
comment on column public.entries.body is 'The user''s words, verbatim. Never rewritten server-side (DESIGN rule 9).';
comment on column public.entries.restaurant_source is
  '''user'' = named/tapped by the user · ''sorter'' = matched from the words. NEVER from location (DESIGN rule 8).';
comment on column public.entries.sort_status is 'pending → sorted | failed. Words render at pending; the receipt renders at sorted.';
comment on column public.entries.sort_plan is 'Last validated sorter plan (jsonb). Internal: re-apply source + eval audit trail.';

-- keyset (created_at, id) everywhere, matching the proven get_feed pagination.
create index entries_author_idx  on public.entries (author_id, created_at desc, id desc);
create index entries_public_idx  on public.entries (created_at desc, id desc) where visibility = 'public';
create index entries_place_idx   on public.entries (restaurant_id, created_at desc) where restaurant_id is not null;
create index entries_unsorted_idx on public.entries (created_at) where sort_status <> 'sorted';
-- TOTAL unique (not partial): the order number is a user-visible identity and a
-- legitimate ON CONFLICT target. (The 0014/0016 lesson: anything PostgREST might
-- upsert against needs a TOTAL unique constraint.)
create unique index entries_author_order_uq on public.entries (author_id, order_number);

-- ===========================================================================
-- entry_photos — one row per photo, ordered.
--
-- WHY A TABLE, NOT text[] ON entries: the words are saved INSTANTLY (rule 9) while
-- uploads are still in flight. Photos therefore arrive one at a time, after the
-- entry exists. PK (entry_id, position) is TOTAL unique, so the client can safely
-- `upsert(onConflict: 'entry_id,position')` a retried upload — no partial index in
-- this path (the 0014/0016 landmine).
-- ===========================================================================
create table public.entry_photos (
  entry_id   uuid not null references public.entries(id) on delete cascade,
  position   smallint not null,
  photo_url  text not null,
  created_at timestamptz not null default now(),
  primary key (entry_id, position),
  constraint entry_photos_position_ck check (position >= 0 and position < 24),
  constraint entry_photos_url_ck      check (length(btrim(photo_url)) > 0)
);

comment on table public.entry_photos is
  'Ordered photos for an entry. PK (entry_id, position) is TOTAL unique — safe upsert target for retried uploads.';

create index entry_photos_entry_idx on public.entry_photos (entry_id, position);

-- ===========================================================================
-- reviews — link to the entry; allow the unscored review; record score provenance.
-- ===========================================================================
alter table public.reviews
  add column if not exists entry_id       uuid references public.entries(id) on delete cascade,
  add column if not exists entry_position smallint,
  add column if not exists score_evidence text;

-- BREAKING (readers): score may now be NULL = "the user did not give a number".
-- The existing reviews_score_halfstep CHECK already tolerates NULL (a NULL CHECK
-- evaluates to NULL, which passes), so the half-step range stays enforced for every
-- non-null score and no constraint is touched.
alter table public.reviews alter column score drop not null;

comment on column public.reviews.entry_id is
  'The visit this dish review was sorted out of. NULL for legacy (pre-entries) reviews.';
comment on column public.reviews.entry_position is
  'Receipt line-item order within the entry (1-based). Ordering is (entry_position nulls last, created_at, id).';
comment on column public.reviews.score is
  'The USER''S score, 0.5-5.0 in half steps, or NULL when they never gave a number (DESIGN rule 7 — never inferred).';
comment on column public.reviews.score_evidence is
  'The literal slice of entries.body that justified `score`. apply_entry_sort (0021) refuses a score whose evidence is not a substring of the body. Provenance only — never displayed.';

-- no unique index on (entry_id, entry_position): ordering is advisory and a
-- re-sort rewrites the whole set, so a constraint here would only add a collision
-- window with no integrity gain. Deliberate.
create index reviews_entry_idx on public.reviews (entry_id, entry_position) where entry_id is not null;
-- "my reviews of this dish, mine first" + histogram/statement scans
create index reviews_reviewer_score_idx on public.reviews (reviewer_id, score) where score is not null;

-- ===========================================================================
-- TRIGGERS
--   BEFORE INSERT: allocate the order number under a per-author row lock, and
--                  stamp place provenance from the fact a place was supplied.
--   BEFORE UPDATE: bump updated_at. `body` is NEVER touched here (rule 9).
--
-- The order-number UPDATE on profiles serialises concurrent inserts by the SAME
-- author and shares the insert's transaction, so a failed insert gives the number
-- back. A DUPLICATE insert of the same client-minted id fails on the PK before
-- commit, which also rolls the counter back — so clients must INSERT entries (and
-- treat 23505 as "already accepted"), NEVER upsert them.
-- ===========================================================================
create or replace function public.trg_entry_biu()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_seq integer;
begin
  if tg_op = 'INSERT' then
    update public.profiles
       set entry_seq = entry_seq + 1
     where id = new.author_id
    returning entry_seq into v_seq;

    if v_seq is null then
      raise exception 'unknown author_id %', new.author_id using errcode = '23503';
    end if;

    new.order_number      := v_seq;                -- authoritative, ignores any client value
    new.restaurant_source := case when new.restaurant_id is not null then 'user' end;
    new.updated_at        := new.created_at;
  else
    new.updated_at := now();
  end if;
  return new;
end; $$;

create trigger entries_biu
  before insert or update on public.entries
  for each row execute function public.trg_entry_biu();

-- 0008's rule: trigger functions must not be reachable as RPCs.
revoke execute on function public.trg_entry_biu() from public, anon, authenticated;

-- ===========================================================================
-- RLS
--   entries      : own always · others' only when public. (0019 adds the block
--                  filter on top — blocks don't exist yet at this point.)
--   entry_photos : follows the parent entry's visibility via EXISTS, so it needs
--                  no visibility logic of its own and can never drift from it.
-- ===========================================================================
alter table public.entries       enable row level security;
alter table public.entry_photos  enable row level security;

create policy entries_select_visible on public.entries
  for select to authenticated
  using (author_id = (select auth.uid()) or visibility = 'public');

create policy entries_insert_self on public.entries
  for insert to authenticated with check (author_id = (select auth.uid()));

create policy entries_update_self on public.entries
  for update to authenticated
  using (author_id = (select auth.uid()))
  with check (author_id = (select auth.uid()));

create policy entries_delete_self on public.entries
  for delete to authenticated using (author_id = (select auth.uid()));

create policy entry_photos_select_visible on public.entry_photos
  for select to authenticated
  using (exists (select 1 from public.entries e where e.id = entry_id));

create policy entry_photos_write_own on public.entry_photos
  for insert to authenticated
  with check (exists (
    select 1 from public.entries e where e.id = entry_id and e.author_id = (select auth.uid())
  ));

create policy entry_photos_update_own on public.entry_photos
  for update to authenticated
  using (exists (
    select 1 from public.entries e where e.id = entry_id and e.author_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.entries e where e.id = entry_id and e.author_id = (select auth.uid())
  ));

create policy entry_photos_delete_own on public.entry_photos
  for delete to authenticated
  using (exists (
    select 1 from public.entries e where e.id = entry_id and e.author_id = (select auth.uid())
  ));

-- ===========================================================================
-- COLUMN PRIVILEGES — the server owns the structure, the user owns the words.
--
-- RLS cannot express "you may write these COLUMNS"; column grants can, and
-- PostgREST honours them. So: the client may insert its own words/visibility/
-- place/created_at and may later edit only `body` + `visibility`. order_number,
-- sort_status, sort_mode, sort_error, sorted_at, sort_plan and restaurant_source
-- are UNWRITABLE by the client on every path — the trigger and the 0021 RPCs are
-- the only writers. restaurant_id is insertable (the user tapped a place in the
-- composer) but NOT updatable — place corrections go through correct_entry_place,
-- which also re-resolves the dishes to the new restaurant.
-- ===========================================================================
revoke all on public.entries      from anon;
revoke all on public.entry_photos from anon;

revoke insert, update on public.entries from authenticated;
grant  select, delete on public.entries to authenticated;
grant  insert (id, author_id, body, visibility, restaurant_id, created_at)
       on public.entries to authenticated;
grant  update (body, visibility) on public.entries to authenticated;

grant select, insert, update, delete on public.entry_photos to authenticated;

grant all on public.entries      to service_role;
grant all on public.entry_photos to service_role;
