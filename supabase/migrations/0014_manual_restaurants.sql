-- 0014_manual_restaurants.sql
-- Ate backend — MANUAL-RESTO (BE stream): let users add restaurants that Google
-- Places can't find, ADDITIVELY and without breaking the Places-backed contract.
--
-- Background (data-model §1.2 / Decision 1): restaurants are Google-Places-backed
-- reference data. The natural key is google_place_id (NOT NULL UNIQUE) and the
-- ONLY write path is the service-role "resolve a Place → upsert" edge function.
-- Migration 0008 deliberately DROPPED the end-user INSERT policy so authenticated
-- users cannot mint uncurated restaurant rows (catalogue-fragmentation guard).
--
-- This migration adds a SECOND, narrow source of restaurants — user-entered
-- "manual" rows for places not in Places — while preserving every guarantee above:
--
--   1. source text NOT NULL DEFAULT 'places'  CHECK (source IN ('places','manual'))
--      — existing rows backfill to 'places' (correct: they are all Places-backed).
--   2. google_place_id becomes NULLABLE (manual rows have no Place id).
--   3. The total UNIQUE on google_place_id is replaced by a PARTIAL unique index
--      `WHERE google_place_id IS NOT NULL` — Places rows stay deduped by Place id;
--      many manual rows may share a NULL google_place_id (NULLs don't collide, but
--      the partial predicate makes the intent explicit and keeps the index lean).
--   4. A CHECK enforces the source↔place_id invariant in BOTH directions, so the
--      two row kinds can never be confused regardless of write path:
--        (source='places' AND google_place_id IS NOT NULL)
--         OR (source='manual' AND google_place_id IS NULL)
--   5. The write path for a manual row is the SECURITY DEFINER RPC
--      `add_manual_restaurant(...)` (EXECUTE granted to authenticated only), NOT a
--      broad INSERT policy — see the RPC's header for the rationale (keeps 0008's
--      hardening intact: still no end-user direct INSERT on restaurants).
--
-- UPDATE/DELETE stay admin-only (no end-user policy, unchanged) for manual rows
-- exactly as for Places rows — manual restaurants are GLOBALLY SHARED catalogue
-- data (visible to all users in search), not per-user-owned. Reconciling duplicate
-- manual rows is a future moderation/merge concern (mirrors the dish-merge op, §4),
-- not enforced by a constraint here (multiple manual NULL-place_id rows are allowed
-- by design).
--
-- Contract impact (FE): restaurants.Row gains `source: 'places' | 'manual'` and
-- `google_place_id` widens string → string | null (additive; existing Places reads
-- unbroken — google_place_id is still always present for source='places'). New RPC
-- `add_manual_restaurant`. The schema already covers the E-MANUALR-1 form fields
-- (name + suburb/city + cuisine) using EXISTING columns (name/city/cuisine/address)
-- — no follow-up migration needed whatever Eamon picks.
--
-- Forward-only; idempotent-safe (drop-if-exists before each add). No applied
-- migration is edited or reordered.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. source discriminator (backfills existing rows to 'places')
-- ---------------------------------------------------------------------------
alter table public.restaurants
  add column if not exists source text not null default 'places';

alter table public.restaurants drop constraint if exists restaurants_source_ck;
alter table public.restaurants
  add constraint restaurants_source_ck check (source in ('places', 'manual'));

comment on column public.restaurants.source is
  'Catalogue origin: ''places'' (Google-Places-backed, google_place_id NOT NULL) or ''manual'' (user-entered, google_place_id NULL). See 0014.';

-- ---------------------------------------------------------------------------
-- 2. google_place_id becomes nullable (manual rows have none)
-- ---------------------------------------------------------------------------
alter table public.restaurants alter column google_place_id drop not null;

-- ---------------------------------------------------------------------------
-- 3. total UNIQUE → PARTIAL unique index (Places rows deduped; manual NULLs free)
--    The implicit column-level UNIQUE from 0002 is named restaurants_google_place_id_key.
-- ---------------------------------------------------------------------------
alter table public.restaurants drop constraint if exists restaurants_google_place_id_key;

create unique index if not exists restaurants_google_place_id_uq
  on public.restaurants (google_place_id)
  where google_place_id is not null;

-- ---------------------------------------------------------------------------
-- 4. source↔place_id invariant (enforced on EVERY write path)
-- ---------------------------------------------------------------------------
alter table public.restaurants drop constraint if exists restaurants_source_placeid_ck;
alter table public.restaurants
  add constraint restaurants_source_placeid_ck check (
    (source = 'places' and google_place_id is not null)
    or (source = 'manual' and google_place_id is null)
  );

-- ---------------------------------------------------------------------------
-- 5. add_manual_restaurant — the narrow, server-validated manual write path.
--
-- WHY AN RPC, NOT AN INSERT POLICY (justification, per the task's "your call"):
--   * 0008 removed the end-user INSERT policy on restaurants precisely to stop
--     authenticated users minting uncurated rows. Re-adding ANY INSERT policy —
--     even one constrained to source='manual' — re-opens a direct-insert surface
--     on the table. An RPC keeps RLS deny-by-default for direct inserts (the 0008
--     hardening stands) while exposing exactly ONE narrow path that CANNOT forge a
--     Places row: it hard-sets source='manual', google_place_id=NULL server-side.
--   * It gives the FE a single typed call (name required + optional locality/
--     cuisine/address) and returns the full inserted row for optimistic insertion
--     into the client catalogue cache — no round-trip to re-read.
--   * Consistent with the existing controlled-write pattern (merge_dish 0006,
--     the places-search edge fn): catalogue mutations go through definer functions
--     / service-role paths, never broad table policies.
--
-- SECURITY DEFINER bypasses RLS, so we gate on auth.uid() IS NOT NULL ourselves.
-- Manual restaurants are global catalogue data — NOT attributed to / owned by the
-- caller (no per-user ownership column; consistent with the task).
--
-- city is NOT NULL on the table; the form's locality is OPTIONAL (E-MANUALR-1
-- undecided), so we default a missing locality to '' (empty string) rather than
-- widen the column to nullable — keeping the existing `city: string` contract
-- intact (zero type-widening on city). The FE treats '' as "no locality".
-- ---------------------------------------------------------------------------
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
  v_name text := btrim(coalesce(p_name, ''));
  v_row  public.restaurants;
begin
  if (select auth.uid()) is null then
    raise exception 'must be authenticated to add a restaurant'
      using errcode = '42501';  -- insufficient_privilege
  end if;

  if v_name = '' then
    raise exception 'restaurant name is required'
      using errcode = '22023';  -- invalid_parameter_value
  end if;

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

comment on function public.add_manual_restaurant(text, text, text, text) is
  'Create a user-entered (source=manual, google_place_id NULL) restaurant. SECURITY DEFINER; gated on auth.uid(); returns the inserted row (data-model §1.2, migration 0014).';

-- EXECUTE: authenticated only (anon/public revoked; service_role bypasses RLS anyway).
revoke all on function public.add_manual_restaurant(text, text, text, text) from public, anon;
grant execute on function public.add_manual_restaurant(text, text, text, text) to authenticated;
