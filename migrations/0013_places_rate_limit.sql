-- 0013_places_rate_limit.sql
-- Ate backend — TIDY-BE-2: per-user rate limiting for the places-search edge fn.
--
-- Purely additive. Adds ONE new table (`places_rate_limit`) + ONE atomic RPC
-- (`places_rate_hit`) that the places-search edge function calls once per
-- billable request to enforce a per-user ceiling. Nothing the client
-- reads/writes changes shape — this is a server-internal abuse guard, invoked
-- only by the edge function's service-role client. No DROP, no ALTER of
-- existing objects.
--
-- WHY: places-search's op=details / op=nearby / op=autocomplete each trigger
-- billable Google Places calls + (details/nearby) service-role upserts into
-- `restaurants`. The companion edge-fn change requires a verified end-user JWT
-- (the must-have gate); this table is the secondary layer — it caps how many
-- billable calls a single authenticated user can make per window, so one
-- compromised/abusive session can't run up the Google bill.
--
-- DESIGN — fixed-window counter (atomic, race-free):
--   * One row per (user_id, window_start). window_start is the request time
--     floored to the window size (default 60s), so all calls in the same minute
--     collapse onto one row.
--   * The increment is a single `insert ... on conflict do update ... returning`
--     statement — atomic under concurrency (no read-then-write race; Postgres
--     serialises the upsert on the PK). The function returns the post-increment
--     hit count so the caller can compare against its limit.
--   * A fixed window (not a true sliding window) is the pragmatic choice here:
--     the worst case is a 2x burst across a window boundary, which is harmless
--     for an abuse ceiling sized well above normal use. Simpler + cheaper than a
--     per-call log table, and fully atomic.
--   * Opportunistic GC: each call deletes this user's expired windows, so the
--     table self-prunes to ~1 active row per active user (no cron needed).
--
-- ACCESS: the table has RLS enabled with NO policies — it is invisible to anon
-- and authenticated (deny-by-default). Only the service-role edge-fn client
-- (which bypasses RLS) and the SECURITY DEFINER RPC touch it. The RPC's EXECUTE
-- is revoked from app roles (0008/0011 pattern) — it is service-role-only,
-- never a client RPC.

-- ---------------------------------------------------------------------------
-- Table: places_rate_limit
-- ---------------------------------------------------------------------------
create table public.places_rate_limit (
  -- the authenticated caller (JWT subject). references auth.users so a deleted
  -- user's counters cascade away; ON DELETE CASCADE keeps the table tidy.
  user_id       uuid        not null references auth.users(id) on delete cascade,
  -- request time floored to the window size; all hits in a window share this.
  window_start  timestamptz not null,
  -- number of billable calls this user made in this window.
  hits          integer     not null default 0,
  primary key (user_id, window_start)
);

comment on table public.places_rate_limit is
  'TIDY-BE-2: per-user fixed-window counter for places-search billable calls. '
  'Server-internal (service-role + SECURITY DEFINER RPC only); RLS-locked, '
  'self-pruning. Not part of the client contract.';

alter table public.places_rate_limit enable row level security;
-- No policies → deny-by-default for anon + authenticated. Service role bypasses
-- RLS; the RPC below is SECURITY DEFINER. The client never reads this table.

-- ---------------------------------------------------------------------------
-- RPC: places_rate_hit(p_user_id, p_window_seconds, p_limit)
--   Atomically records one hit for p_user_id in the current window and returns
--   TRUE when the post-increment count is within p_limit (request allowed),
--   FALSE when it exceeds it (caller should 429). SECURITY DEFINER so it runs
--   with the owner's rights regardless of caller; in practice only the
--   service-role edge-fn client invokes it.
-- ---------------------------------------------------------------------------
create or replace function public.places_rate_hit(
  p_user_id        uuid,
  p_window_seconds integer,
  p_limit          integer
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_window timestamptz;
  v_hits   integer;
begin
  -- floor now() to the window boundary (epoch-based, window-size aligned)
  v_window := to_timestamp(
    floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds
  );

  -- atomic increment: single upsert, returns the new count. No read-then-write
  -- race — concurrent calls serialise on the (user_id, window_start) PK.
  insert into public.places_rate_limit (user_id, window_start, hits)
    values (p_user_id, v_window, 1)
    on conflict (user_id, window_start)
    do update set hits = public.places_rate_limit.hits + 1
    returning hits into v_hits;

  -- opportunistic GC: drop this user's expired windows (keeps the table to ~1
  -- live row per active user; no cron required).
  delete from public.places_rate_limit
    where user_id = p_user_id
      and window_start < v_window - make_interval(secs => p_window_seconds);

  -- allowed when within the ceiling
  return v_hits <= p_limit;
end;
$$;

comment on function public.places_rate_hit(uuid, integer, integer) is
  'TIDY-BE-2: atomic per-user fixed-window rate check for places-search. '
  'Records one hit and returns true when within p_limit, false to 429. '
  'Service-role-only (EXECUTE revoked from app roles).';

-- service-role-only: never callable by anon/authenticated clients (0008/0011
-- pattern). The edge fn invokes it through its service-role client.
revoke execute on function public.places_rate_hit(uuid, integer, integer)
  from public, anon, authenticated;
