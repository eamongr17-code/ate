-- 0015_search_manual_restaurants.sql
-- Ate backend — MANUAL-RESTO (search-blend): make manually-added restaurants
-- first-class in restaurant search. Eamon's directive: a manual restaurant must
-- show up ALONGSIDE Google Places predictions in the log-flow "Where" step,
-- matched by FUZZY name search ("even if people closely type the name").
--
-- This migration is the DB half of the blend. The `places-search` edge function
-- (op=autocomplete) calls the RPC below and merges its rows into a unified,
-- capped-at-5, discriminated result list (see docs/backend/manual-search-blend-
-- contract.md). It is PURELY ADDITIVE: no table/column/policy changes, nothing
-- the client already reads/writes moves shape. Two objects only:
--
--   1. A PARTIAL trigram GIN index on the manual subset of `restaurants`. The
--      base `restaurants_name_trgm` (0002) covers ALL names, but a manual-search
--      predicate is always `source='manual' AND <fuzzy name>`; as the catalogue
--      grows (every op=nearby upserts Places rows), a bare manual filter would
--      seq-scan the whole table. This partial index covers exactly the manual
--      rows and is index-eligible for BOTH the ILIKE-substring and the
--      word_similarity (`<%`) branches (verified: BitmapOr on this index).
--
--   2. search_manual_restaurants(p_query, p_limit) — the fuzzy matcher. Returns
--      manual restaurants whose NAME approximately matches p_query, each with a
--      `match_score` (0..1) and a `strong` flag, ordered strongest-first.
--
-- FUZZY SEMANTICS (tuned against real pg_trgm, see the contract doc's proof):
--   * MATCH (surface at all): name ILIKE '%q%'  OR  word_similarity(q, name) >= 0.45.
--     - word_similarity is the recall driver: it scores the BEST matching word-
--       extent of the name against the query, so partial / multi-word / mildly
--       misspelled queries all hit. Proven: "marg", "marg diner", "margs diner",
--       "margs dinner", "marrgs diner", "Margs Diner" all surface "Marg's Diner"
--       (min score 0.529 >= 0.45); "xyzzy" and "50%" surface nothing.
--   * STRONG (lead Places in the blend): exact substring OR combined score >= 0.6.
--     A near-exact typed name leads; an ordinary fuzzy/typo match (e.g.
--     "marrgs diner" @ 0.53) is WEAK and ranks AFTER Places predictions.
--   * The 0.45 word_similarity threshold is pinned on the FUNCTION (so the `<%`
--     operator inside uses it regardless of the session GUC) — deterministic and
--     index-using. LIKE metacharacters in the query are escaped (a literal % / _
--     is matched literally, not as a wildcard).
--
-- SECURITY: SECURITY INVOKER, STABLE, read-only. Manual restaurants are globally-
-- shared catalogue data (the restaurants SELECT policy is world-readable), so a
-- plain invoker read is correct — no definer escalation needed. The edge function
-- calls it via the service-role client; EXECUTE is also granted to `authenticated`
-- so the contract is usable directly (anon revoked — search is JWT-gated upstream).
--
-- Forward-only; re-runnable (create-index-if-not-exists, create-or-replace fn).
-- No applied migration is edited or reordered.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Partial trigram GIN index on the manual subset.
-- ---------------------------------------------------------------------------
create index if not exists restaurants_manual_name_trgm
  on public.restaurants using gin (name extensions.gin_trgm_ops)
  where source = 'manual';

-- ---------------------------------------------------------------------------
-- 2. search_manual_restaurants — fuzzy name matcher over manual rows.
-- ---------------------------------------------------------------------------
create or replace function public.search_manual_restaurants(
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
  where r.source = 'manual'
    and char_length(q.query) >= 2
    and (
      r.name ilike '%' || q.like_q || '%'   -- exact substring (partial typing) — index-eligible
      or q.query <% r.name                  -- word_similarity >= 0.45 (set above) — index-eligible
    )
  order by match_score desc, r.name
  limit greatest(coalesce(p_limit, 5), 0);
$$;

comment on function public.search_manual_restaurants(text, int) is
  'Fuzzy (pg_trgm) name search over source=manual restaurants for the search-blend. Returns id/name/city/cuisine + match_score + strong flag, strongest-first. SECURITY INVOKER, read-only. See migration 0015 / docs/backend/manual-search-blend-contract.md.';

-- EXECUTE: authenticated (the edge fn uses service_role, which bypasses RLS).
-- anon revoked — restaurant search is JWT-gated at the edge function.
revoke all on function public.search_manual_restaurants(text, int) from public, anon;
grant execute on function public.search_manual_restaurants(text, int) to authenticated, service_role;
