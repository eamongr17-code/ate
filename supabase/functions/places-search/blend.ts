// supabase/functions/places-search/blend.ts
//
// The search-blend's PURE half: ranking, de-duplication and the top-5 cap for
// `op=autocomplete`'s unified `results` list. Extracted from index.ts (which is a
// Deno.serve entrypoint that reads secrets on import, so it can't be imported by
// a test) so blend_test.ts can exercise the REAL implementation instead of a
// mirrored copy of it.
//
// Contract: docs/backend/manual-search-blend-contract.md.

// Result cap (PH-E3): a typed autocomplete never returns more than 5 rows. Lives
// here because both index.ts and the blend enforce it — one source of truth.
export const AUTOCOMPLETE_CAP = 5;

// A Places prediction (the shape returned by google/stub Autocomplete).
export type Prediction = {
  google_place_id: string;
  name: string;
  secondary?: string;
  distance_meters?: number;
};

// A row we ALREADY hold in `restaurants`, fuzzy-matched by name via the
// search_local_restaurants RPC (migration 0017; formerly the manual-only
// search_manual_restaurants, 0015).
export type LocalMatch = {
  id: string;
  name: string;
  city: string | null;
  cuisine: string | null;
  match_score: number;
  strong: boolean;
};

// The unified, discriminated search result the FE consumes (op=autocomplete
// `results`). `kind` tells the two apart: a 'place' resolves on select via
// op=details (has google_place_id), a 'manual' IS already a restaurants row
// (has the real `id`) and is selected directly — no resolve.
//
// NOTE on the tag: `kind:'manual'` is kept BYTE-IDENTICAL after 0017 widened the
// DB search from manual-only to all local rows, because its wire meaning has
// always been "already a row, select directly" (contract §2) — which is equally
// true of a Places-sourced local row. Renaming the tag would be a BREAKING wire
// change for zero client benefit (AteKit decodes `"manual"` → ManualRestaurantMatch
// → RestaurantSelection.restaurant(id:), which is exactly right here).
export type SearchResult =
  | { kind: 'place'; google_place_id: string; name: string; secondary?: string; distance_meters?: number }
  | { kind: 'manual'; id: string; name: string; city: string; cuisine?: string; match_score: number };

// Comparator mirroring the FE byDistanceAsc: nearest first, unmeasured rows
// last, stable for ties (so Google's relevance order is preserved within a
// distance tie / the trailing no-distance block).
export function byDistanceAsc(a: Prediction, b: Prediction): number {
  const da = a.distance_meters;
  const db = b.distance_meters;
  const aMissing = da == null || !Number.isFinite(da);
  const bMissing = db == null || !Number.isFinite(db);
  if (aMissing && bMissing) return 0;
  if (aMissing) return 1;
  if (bMissing) return -1;
  return (da as number) - (db as number);
}

// Merge Places predictions + fuzzy local matches into ONE ranked, capped-at-5,
// discriminated list. Ranking (justified in the contract doc):
//   1. STRONG local matches (near-exact typed name; strongest-first) — a
//      restaurant we already hold whose name closely matches the query. It leads
//      because it is directly selectable: no op=details round-trip, no paid
//      Google Details call, and no risk of minting a duplicate row.
//   2. Places predictions — distance-sorted (nearest first) to preserve the
//      existing "where did you eat?" UX; Google relevance order when no origin.
//   3. WEAK local matches (ordinary fuzzy / typo) — after Places, so a spray of
//      loose trigram hits can never starve the Google predictions.
// De-duped by normalised name (first wins → strong-local > place > weak-local),
// so a local row SHADOWS a same-named Places prediction. Capped at
// AUTOCOMPLETE_CAP.
export function blendResults(predictions: Prediction[], local: LocalMatch[]): SearchResult[] {
  const toLocal = (m: LocalMatch): SearchResult => ({
    kind: 'manual',
    id: m.id,
    name: m.name,
    city: m.city ?? '',
    ...(m.cuisine ? { cuisine: m.cuisine } : {}),
    match_score: m.match_score,
  });
  const toPlace = (p: Prediction): SearchResult => ({
    kind: 'place',
    google_place_id: p.google_place_id,
    name: p.name,
    ...(p.secondary ? { secondary: p.secondary } : {}),
    ...(Number.isFinite(p.distance_meters) ? { distance_meters: p.distance_meters as number } : {}),
  });

  const strong = local.filter((m) => m.strong).map(toLocal);
  const weak = local.filter((m) => !m.strong).map(toLocal);
  const places = [...predictions].sort(byDistanceAsc).map(toPlace);

  const ordered = [...strong, ...places, ...weak];
  const seen = new Set<string>();
  const out: SearchResult[] = [];
  for (const r of ordered) {
    const key = r.name.trim().toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(r);
  }
  return out.slice(0, AUTOCOMPLETE_CAP);
}
