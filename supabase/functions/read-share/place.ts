// supabase/functions/read-share/place.ts
//
// place_query → a place, ONLY when unambiguous (design rule 8: places are never assumed).
// PURE: index.ts fetches the candidates; these functions only decide.
//
//   1. LOCAL FIRST — rows we already hold, from search_local_restaurants (0017), as sort-entry does.
//      Exactly one STRONG row → that restaurant (restaurant_id set). Several strong rows that the
//      query cannot tell apart (a chain, two "Lune"s) → AMBIGUOUS: stop, no Google call either.
//   2. ELSE GOOGLE — places-search op=autocomplete's Google `predictions` (VIC-fenced, food/bev).
//      Exactly one prediction named by the query → { google_place_id, name, locality }, and the app
//      resolves it through its usual pick path (op=details), which creates or reuses the row.
//   Anything else → null. place_query is still returned, so the card can open the place sheet on it.
//
// "Named by the query": the same name (case, accents, punctuation, "&"/"and", a leading "The" and
// spaces all ignored), or the name plus words found in its own address ("Chin Chin Melbourne").
// Failing any exact match, a unique prefix ("Supernormal" → "Supernormal Canteen") is accepted.

import { localityFromAddress } from '../places-search/locality.ts';
import { normalise } from './model.ts';

export type SharePlace = {
  restaurant_id: string | null;
  google_place_id: string | null;
  name: string;
  locality: string | null;
};

/** A search_local_restaurants row (0017). */
export type LocalRow = { id: string; name: string; city: string | null; match_score: number; strong: boolean };
/** A places-search op=autocomplete `predictions[]` item. */
export type PredictionRow = { google_place_id: string; name: string; secondary?: string };

export type LocalDecision = { kind: 'match'; place: SharePlace } | { kind: 'ambiguous' } | { kind: 'none' };

const core = (s: string) => normalise(s).replace(/^the /, '');
const compact = (s: string) => core(s).replace(/ /g, '');

/** 'exact' | 'prefix' | null — how strongly `query` names a venue called `name` at `where`. */
export function nameMatch(query: string, name: string, where?: string | null): 'exact' | 'prefix' | null {
  const q = core(query);
  const n = core(name);
  if (!q || !n) return null;
  if (q === n || compact(query) === compact(name)) return 'exact';
  // "Chin Chin Melbourne": the whole name, then only words from its own address.
  if (q.startsWith(`${n} `)) {
    const rest = q.slice(n.length + 1).split(' ');
    const addr = new Set(normalise(where ?? '').split(' ').filter(Boolean));
    if (rest.every((w) => addr.has(w))) return 'exact';
    return null;
  }
  if (q.length >= 5 && n.startsWith(`${q} `)) return 'prefix';
  return null;
}

const localityOrNull = (s: string | null | undefined) => localityFromAddress(s) || null;

/** One unique best match from a tiered list, or 'ambiguous' / 'none'. */
function pickUnique<T>(rows: T[], tier: (r: T) => 'exact' | 'prefix' | null, key: (r: T) => string) {
  for (const t of ['exact', 'prefix'] as const) {
    const hits = rows.filter((r) => tier(r) === t);
    const distinct = new Map(hits.map((r) => [key(r), r]));
    if (distinct.size === 1) return { kind: 'one' as const, row: [...distinct.values()][0] };
    if (distinct.size > 1) return { kind: 'ambiguous' as const };
  }
  return { kind: 'none' as const };
}

export function decideLocal(query: string, rows: LocalRow[]): LocalDecision {
  const strong = rows.filter((r) => r && r.strong && typeof r.id === 'string' && typeof r.name === 'string');
  if (!strong.length) return { kind: 'none' };
  const toPlace = (r: LocalRow): SharePlace => ({
    restaurant_id: r.id,
    google_place_id: null,
    name: r.name,
    locality: localityOrNull(r.city),
  });
  if (strong.length === 1) return { kind: 'match', place: toPlace(strong[0]) };
  const pick = pickUnique(strong, (r) => nameMatch(query, r.name, r.city), (r) => r.id);
  if (pick.kind === 'one') return { kind: 'match', place: toPlace(pick.row) };
  return { kind: 'ambiguous' };
}

export function decideGoogle(query: string, predictions: PredictionRow[]): SharePlace | null {
  const usable = predictions.filter((p) => p && typeof p.google_place_id === 'string' && p.google_place_id &&
    typeof p.name === 'string' && p.name.trim());
  const pick = pickUnique(usable, (p) => nameMatch(query, p.name, p.secondary), (p) => p.google_place_id);
  if (pick.kind !== 'one') return null;
  return {
    restaurant_id: null,
    google_place_id: pick.row.google_place_id,
    name: pick.row.name.trim(),
    locality: localityOrNull(pick.row.secondary),
  };
}
