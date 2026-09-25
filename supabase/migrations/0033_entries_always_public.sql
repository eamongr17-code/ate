-- 0033_entries_always_public.sql
-- Ate backend — public/private is REMOVED from the product (CEO decision, 2026-09-25). Every entry
-- is public, including every entry that was private until this migration ran. Eamon made the call
-- knowing his own private entries become visible to everyone.
--
-- !! THIS MIGRATION CHANGES PRODUCTION DATA. !!
-- Section 1 UPDATEs every `entries` row with visibility = 'private' to 'public' — real users'
-- entries, on prod, the moment CI applies it. It is a bulk prod-data operation (AGENTS.md rule 4d):
-- it reaches prod ONLY through the CI job, and only with Eamon's go-ahead on record. It is the ONLY
-- file in this PR that writes a row. (Reversibility: section 1 first records exactly which entries
-- were private, in `entries_private_before_0033`, so the flip can be undone row-for-row if the
-- decision is ever reversed. That table is unreadable by every client role.)
--
-- WHAT CHANGES, AND WHY EACH ONE:
--
--  1. THE DATA. Every private entry becomes public. `updated_at` is deliberately NOT touched by the
--     flip: `updated_at > sorted_at` is the client's "the words were edited after the sort" hint
--     (entry_cards contract), and a bumped `updated_at` would make every flipped entry drop its
--     inline score/place tokens back to plain text. So `entries_biu` is disabled for the one UPDATE
--     and re-enabled immediately — the migration is one transaction, so no other write can slip
--     through the gap, and a failure rolls the whole file back with the trigger enabled.
--
--  2. THE WRITE PATH. A shipped client can still send `visibility: "private"` — on INSERT, or as the
--     "Make private" PATCH. That must neither fail (it would break the client: 23514/42501 at the
--     composer) nor create a private entry. `trg_entry_biu` now pins `visibility = 'public'` on every
--     insert and update, and the CHECK is tightened to `visibility = 'public'` behind it as the
--     invariant. And an UPDATE that changes nothing (a "Make private" tap, once pinned) no longer
--     bumps `updated_at`, for the same token reason as (1).
--
--  3. THE READS. Viewer-relative PRIVACY logic goes away; viewer-relative BLOCK logic stays exactly
--     as 0019 wrote it. Visibility was branched on in exactly three places, and all three are
--     rewritten here:
--       * `entries_select_visible` — own, or not blocked (was: own, or public AND not blocked).
--       * `reviews_select_visible` — own, or not blocked (was: … AND the parent entry is public).
--         Dropping the per-row EXISTS is also the cheapest win in the schema: `dish_stats`,
--         `restaurant_stats`, every cover and every count ran it once per review line.
--       * `get_entry_feed` — the `c.visibility = 'public'` filter is gone.
--     Everything else — `entry_photos`, `dish_stats`, `restaurant_stats`, `dish_cover_url`,
--     `restaurant_cover_url`, `dish_photos`, `place_summary`, `place_dishes`, `dish_summary`,
--     `get_dish_reviews`, `get_entries_by_author`, `get_entries_at_place`, `profile_summary`,
--     `score_histogram`, `dishes_by_score`, `monthly_statement`, `search_*`, `nearby_places`,
--     `save_dish` — never named visibility: they are SECURITY INVOKER (or view `security_invoker`)
--     and inherited it from the two policies above. They are public-everywhere by this file alone,
--     and none needs re-creating.
--
--  4. THE FEED INDEX. `entries_public_idx` was PARTIAL on `visibility = 'public'`; a feed query that
--     no longer states that predicate cannot use it. Replaced by a total `(created_at desc, id desc)`
--     index — the feed's keyset, unchanged.
--
-- WIRE IMPACT (annotated for iOS; sequenced through the lead)
--   NOTHING BREAKS. `entries.visibility` and `entry_cards.visibility` STAY, always 'public', so a
--     shipped decoder with a two-case enum keeps decoding. The column grants still include it, so a
--     shipped INSERT/PATCH that sends it is accepted — and lands public.
--   BEHAVIOURAL: (a) every read returns MORE rows for other viewers — every formerly-private entry
--     and its lines now appear in the feed, on profiles, place and dish pages, in search, and in
--     everyone's aggregates and covers (averages and counts can MOVE); (b) PATCH
--     `{visibility: "private"}` succeeds and changes nothing — the client must stop offering it.
--   FOLLOW-UP (breaking, later, sequenced): once no build in TestFlight reads or writes
--     `visibility`, a later migration drops `entries.visibility`, its CHECK, its column grants, the
--     `entry_cards.visibility` column, the trigger's pin and `entries_private_before_0033`.
--   NOT CHANGED: blocks (both directions, via `blocked_with`), every RPC signature and OUT list,
--     every other policy and grant.

set search_path = public, extensions;

-- ===========================================================================
-- 1. THE DATA FLIP — the one write in this PR.
-- ===========================================================================

-- The receipt of what was private, so the flip is reversible row-for-row. Service-role only: RLS on
-- with NO policy, and every client role revoked. `on delete cascade` so a deleted entry (or a
-- deleted account, delete_account 0032) takes its row with it — this table never outlives the data.
create table if not exists public.entries_private_before_0033 (
  entry_id   uuid primary key references public.entries(id) on delete cascade,
  flipped_at timestamptz not null default now()
);

comment on table public.entries_private_before_0033 is
  'Which entries were private when 0033 made every entry public — the undo list, and nothing else. Service-role only. Dropped with entries.visibility in the follow-up.';

alter table public.entries_private_before_0033 enable row level security;
revoke all on public.entries_private_before_0033 from public, anon, authenticated;
grant all on public.entries_private_before_0033 to service_role;

insert into public.entries_private_before_0033 (entry_id)
select id from public.entries where visibility <> 'public'
on conflict (entry_id) do nothing;

-- `entries_biu` would stamp updated_at = now() on every flipped row (see finding 1). It is the ONLY
-- trigger on entries. One transaction: disabled, one UPDATE, enabled.
alter table public.entries disable trigger entries_biu;

update public.entries
   set visibility = 'public'
 where visibility <> 'public';

alter table public.entries enable trigger entries_biu;

-- ===========================================================================
-- 2. THE WRITE PATH — public is the only value there is.
-- ===========================================================================
alter table public.entries alter column visibility set default 'public';

alter table public.entries drop constraint if exists entries_visibility_ck;
alter table public.entries add constraint entries_visibility_ck check (visibility = 'public');

comment on column public.entries.visibility is
  'DEPRECATED (0033): always ''public''. Kept only so shipped clients that send or decode it do not break; the trigger pins it. Dropped in a follow-up.';

-- 0018's trigger, plus two lines: the pin, and "no change, no bump". The INSERT branch is otherwise
-- verbatim.
create or replace function public.trg_entry_biu()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_seq integer;
begin
  -- Every entry is public (0033). A shipped client that still sends 'private' lands public instead
  -- of failing at the composer.
  new.visibility := 'public';

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
  elsif new is distinct from old then
    -- A no-op UPDATE (e.g. a pinned "Make private") leaves updated_at alone, so it cannot trip the
    -- client's `updated_at > sorted_at` stale-offsets hint.
    new.updated_at := now();
  end if;
  return new;
end; $$;

-- 0008's rule: trigger functions must not be reachable as RPCs.
revoke execute on function public.trg_entry_biu() from public, anon, authenticated;

-- ===========================================================================
-- 3. THE READS — privacy branching removed; the block filter is untouched.
-- DROP + CREATE (forward-only; 0019 created both).
-- ===========================================================================
drop policy if exists entries_select_visible on public.entries;
create policy entries_select_visible on public.entries
  for select to authenticated
  using (
    author_id = (select auth.uid())
    or not public.blocked_with(author_id)
  );

-- A line's reviewer IS its entry's author (every sorter/correction insert writes
-- `reviewer_id = entry.author_id`), so the reviewer's block status is the entry's.
drop policy if exists reviews_select_visible on public.reviews;
create policy reviews_select_visible on public.reviews
  for select to authenticated
  using (
    reviewer_id = (select auth.uid())
    or not public.blocked_with(reviewer_id)
  );

-- Same signature, same return type: create-or-replace is legal and the grants survive.
create or replace function public.get_entry_feed(
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20,
  p_include_own       boolean     default false
)
returns setof public.entry_cards
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select c.*
  from public.entry_cards c
  where (p_include_own or c.author_id <> (select auth.uid()))
    and (
      p_cursor_created_at is null
      or (c.created_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(p_page_size, 1), 50);
$$;

comment on function public.get_entry_feed(timestamptz, uuid, int, boolean) is
  'Global feed: every entry (all entries are public, 0033), newest first, keyset (created_at, id) desc. Blocked users excluded by RLS, both ways. p_include_own=false by default.';

comment on function public.get_entries_by_author(uuid, timestamptz, uuid, int) is
  'One author''s entries as `entry_cards` — the ONE entry shape, never review rows. Every entry is public (0033), so yours and a stranger''s read the same; a blocked author reads empty (RLS). Keyset (created_at, id) desc.';

comment on column public.entry_cards.visibility is
  'DEPRECATED (0033): always ''public''. Kept for shipped decoders; dropped in a follow-up.';

-- ===========================================================================
-- 4. THE FEED INDEX — total, because the feed no longer states a visibility predicate.
-- ===========================================================================
create index if not exists entries_feed_idx on public.entries (created_at desc, id desc);
drop index if exists public.entries_public_idx;
