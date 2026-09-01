-- 0017_search_local_restaurants.sql
-- Ate backend — make EVERY local restaurants row name-searchable in the
-- "Where did you eat?" blend, not just the user-added (source='manual') subset.
--
-- WHY (the staging seed/Places mismatch, 2026-09-01):
--   `search_manual_restaurants` (0015) filters `source='manual'`, so a
--   Places-SOURCED row we already hold is invisible to the blend. The typed
--   query then only ever matches a Google prediction, and selecting it costs an
--   op=details round-trip (a paid Details call) whose upsert re-derives the row
--   we already had — and, whenever Google's place id differs from the one on our
--   row (every seeded 'stub-…' row; and in prod any row whose place id has since
--   been re-issued), MINTS A DUPLICATE restaurant instead of reusing it. That is
--   how staging ended up with two "Chin Chin" rows.
--
--   Widening the search to all local rows closes it: a restaurant we already
--   hold shadows its own Google prediction in the blend (the blend de-dupes by
--   normalised name, local-first), is selected DIRECTLY by row id, and no
--   Details call and no duplicate row happen at all.
--
-- WHAT: ONE new function, `search_local_restaurants(p_query, p_limit)` — the
-- body of `search_manual_restaurants` with the `source='manual'` predicate
-- removed. Same argument names, same return columns, same thresholds, same
-- ordering, same escaping. It is a strict superset of 0015's result set.
--
-- Deliberately ADDITIVE and forward-only:
--   * 0015's function and its partial index are LEFT IN PLACE, unedited. 0015 is
--     applied; applied migrations are never edited. Anything still calling
--     `search_manual_restaurants` keeps its exact behaviour.
--   * No table, column, constraint, policy or index is changed. Nothing the
--     client reads or writes moves shape — the edge function keeps emitting the
--     SAME `kind:'manual'` discriminator for these rows, whose wire meaning is
--     and always was "this is ALREADY a restaurants row, select it directly, do
--     not resolve" (docs/backend/manual-search-blend-contract.md §2). That is
--     exactly true of a Places-sourced local row, so this is a NON-BREAKING,
--     no-client-change wire widening.
--
-- INDEXES: none added. Dropping the source predicate makes this the *general*
-- name search, which the TOTAL trigram GIN index `restaurants_name_trgm`
-- (migration 0002, `using gin (name gin_trgm_ops)`) already covers for BOTH
-- branches — the ILIKE-substring and the word_similarity (`<%`) operator. 0015's
-- partial `restaurants_manual_name_trgm` stays for 0015's own function.
--
-- SECURITY: identical to 0015 — SECURITY INVOKER, STABLE, read-only. The
-- restaurants SELECT policy is world-readable catalogue data (RLS still applies
-- to the invoker), so no definer escalation is needed or wanted. The edge
-- function calls it service-role; EXECUTE also granted to `authenticated`, anon
-- revoked (restaurant search is JWT-gated at the edge function).
--
-- Re-runnable (create-or-replace).

set search_path = public, extensions;

create or replace function public.search_local_restaurants(
  p_query text,
  p_limit int default 5
)
returns table (
  id          uuid,
  name        text,
  city        text,
  cuisine     text,
  match_score real,
  strong      boolean
)
language sql
stable
security invoker
set search_path = public, extensions
-- Pin the word_similarity operator (`<%`) threshold for THIS function so it is
-- deterministic + index-eligible regardless of the caller's session GUC.
set pg_trgm.word_similarity_threshold = 0.45
as $$
  with q as (
    select
      btrim(coalesce(p_query, '')) as query,
      -- Escape LIKE metacharacters so a literal % / _ / \ in the query matches
      -- literally instead of acting as a wildcard.
      replace(replace(replace(btrim(coalesce(p_query, '')), '\', '\\'), '%', '\%'), '_', '\_') as like_q
  )
  select
    r.id,
    r.name,
    r.city,
    r.cuisine,
    greatest(similarity(r.name, q.query), word_similarity(q.query, r.name))::real as match_score,
    (
      r.name ilike '%' || q.like_q || '%'
      or greatest(similarity(r.name, q.query), word_similarity(q.query, r.name)) >= 0.6
    ) as strong
  from public.restaurants r, q
  where char_length(q.query) >= 2
    and (
      r.name ilike '%' || q.like_q || '%'   -- exact substring (partial typing) — index-eligible
      or q.query <% r.name                  -- word_similarity >= 0.45 (set above) — index-eligible
    )
  order by match_score desc, r.name
  limit greatest(coalesce(p_limit, 5), 0);
$$;

comment on function public.search_local_restaurants(text, int) is
  'Fuzzy (pg_trgm) name search over ALL local restaurants (any source) for the search-blend. Same shape/thresholds as search_manual_restaurants (0015) minus the source filter, so a restaurant we already hold shadows its own Google prediction and is selected directly (no paid Details call, no duplicate row). SECURITY INVOKER, read-only. See migration 0017.';

-- EXECUTE: authenticated (the edge fn uses service_role, which bypasses RLS).
-- anon revoked — restaurant search is JWT-gated at the edge function.
revoke all on function public.search_local_restaurants(text, int) from public, anon;
grant execute on function public.search_local_restaurants(text, int) to authenticated, service_role;
