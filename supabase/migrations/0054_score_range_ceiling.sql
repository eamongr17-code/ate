-- 0054_score_range_ceiling.sql
-- Ate backend — round 7 fix (QA on #102): THE SCORE TRACK ENDS AT 6. The Journal's range slider now
-- runs 0.5 … 5.0 … 6, so a top thumb on 5.0 is a real ceiling: "5.0s" (5–5) means exactly 5.0 and must
-- leave a secret 6 out. 0047's score_in_range opened the top at p_max_score >= 5, so score_in_range(6,
-- 5, 5) was true. Now the top opens only at p_max_score >= 6 (the end of the track); below that every
-- number above the ceiling — a 6, or an average a 6 lifted past 5 (5.3) — is out.
--
--   no bound set  → kept (unscored too)                                    (unchanged)
--   any bound set → score is not null, >= p_min_score, and (p_max_score >= 6 or score <= p_max_score)
--
-- EVERY CALLER goes through this one function, so all of them move together: my_entries (0047),
-- my_entries_count + journal_days (0053, via my_entries_filtered), search_places / search_dishes /
-- nearby_places / search_saved (0052). Nothing else compares against a ceiling.
--
-- WIRE IMPACT: BEHAVIOURAL, and only for p_max_score in [5, 6). No shipped client sends one: AteKit's
-- ScoreBand (Journal, Search, Saved) sends NO ceiling while the top thumb is on its end, and any
-- ceiling below 5 reads identically under both rules. A client that wants the open top sends null or
-- a value >= 6. Same signature ⇒ create or replace; grants survive.

set search_path = public, extensions;

create or replace function public.score_in_range(p_score numeric, p_min numeric, p_max numeric)
returns boolean
language sql
immutable
set search_path = public, extensions
as $$
  select (p_min is null and p_max is null)
      or (p_score is not null
          and (p_min is null or p_score >= p_min)
          and (p_max is null or p_max >= 6 or p_score <= p_max));
$$;

comment on function public.score_in_range(numeric, numeric, numeric) is
  'Score range filter (0047, ceiling 0054): true with no bound; else the score is set, >= min, and <= max unless max >= 6 (the end of the track, where the top is open). A ceiling of 5 leaves a secret 6 — and any average above 5 — out; 5–6 or an open top keeps them.';
