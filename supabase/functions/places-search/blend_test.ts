// supabase/functions/places-search/blend_test.ts
//
// Deno unit tests for the search-blend's ranking / dedupe / cap.
// Run from the function dir:  deno test --no-check blend_test.ts
//
// These import the REAL blend.ts (not a mirrored copy), so they pin the actual
// shipped behaviour. They exist because migration 0017 widened the DB half from
// "manual rows only" to "every local row", which multiplies how many local
// matches can arrive — the ranking has to keep Places predictions alive.

import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { AUTOCOMPLETE_CAP, blendResults, type LocalMatch, type Prediction } from './blend.ts';

const place = (name: string, distance?: number): Prediction => ({
  google_place_id: `g-${name.toLowerCase().replace(/\W+/g, '-')}`,
  name,
  secondary: `${name} St, Melbourne`,
  ...(distance == null ? {} : { distance_meters: distance }),
});

const local = (name: string, opts: Partial<LocalMatch> = {}): LocalMatch => ({
  id: `row-${name.toLowerCase().replace(/\W+/g, '-')}`,
  name,
  city: 'Melbourne',
  cuisine: null,
  match_score: 0.9,
  strong: true,
  ...opts,
});

const kinds = (rs: ReturnType<typeof blendResults>) => rs.map((r) => r.kind);
const names = (rs: ReturnType<typeof blendResults>) => rs.map((r) => r.name);

// ---------------------------------------------------------------------------
// The fix (b) guarantee: a restaurant we already hold SHADOWS its own Google
// prediction — so selection is a direct row pick, not an op=details resolve.
// This is what closes the duplicate-minting path and saves the paid Details
// call.
// ---------------------------------------------------------------------------
Deno.test('local row shadows the same-named Places prediction (local wins the dedupe)', () => {
  const out = blendResults([place('Chin Chin', 300), place('Tipo 00', 900)], [local('Chin Chin')]);
  assertEquals(names(out), ['Chin Chin', 'Tipo 00']);
  assertEquals(kinds(out), ['manual', 'place']); // NOT two Chin Chins, and ours leads
  const chin = out[0];
  assertEquals(chin.kind === 'manual' ? chin.id : null, 'row-chin-chin'); // a real row id → select directly
});

Deno.test('name dedupe is case/whitespace-insensitive', () => {
  const out = blendResults([place('  CHIN CHIN ')], [local('Chin Chin')]);
  assertEquals(out.length, 1);
  assertEquals(kinds(out), ['manual']);
});

Deno.test('a DIFFERENT local name does not shadow the prediction — both survive', () => {
  const out = blendResults([place('Chin Chin', 300)], [local('Chin Chin Bar')]);
  assertEquals(names(out), ['Chin Chin Bar', 'Chin Chin']);
  assertEquals(kinds(out), ['manual', 'place']);
});

// ---------------------------------------------------------------------------
// Weak-fuzzy crowding: 0017 widens the candidate pool, so a loose trigram query
// can return several WEAK matches. They must stay BEHIND every Places
// prediction and must never push a prediction out of the capped-at-5 list.
// ---------------------------------------------------------------------------
Deno.test('weak local matches never crowd out Places predictions (rank 3 + cap 5)', () => {
  const weakSpray = ['Marg Diner', 'Margo Cafe', 'Margate Grill', 'Marganta Bar', 'Margie Pizza'].map(
    (n, i) => local(n, { strong: false, match_score: 0.5 - i * 0.01 }),
  );
  const predictions = [place('Margaret', 100), place('Margarita Room', 200), place('Marge Kitchen', 300)];

  const out = blendResults(predictions, weakSpray);

  assertEquals(out.length, AUTOCOMPLETE_CAP);
  // All three Places predictions survive, in distance order, ahead of every weak row.
  assertEquals(names(out).slice(0, 3), ['Margaret', 'Margarita Room', 'Marge Kitchen']);
  assertEquals(kinds(out), ['place', 'place', 'place', 'manual', 'manual']);
});

Deno.test('even a full page of weak matches leaves the single prediction in place', () => {
  const weakSpray = Array.from({ length: 8 }, (_, i) =>
    local(`Weak ${i}`, { strong: false, match_score: 0.46 }),
  );
  const out = blendResults([place('Chin Chin', 250)], weakSpray);
  assertEquals(out.length, AUTOCOMPLETE_CAP);
  assertEquals(out[0].kind, 'place');
  assertEquals(out[0].name, 'Chin Chin');
});

// ---------------------------------------------------------------------------
// Strong local matches DO lead — by design (they are directly selectable, free,
// and duplicate-proof). Recorded here because 0017 makes this reachable with
// Places-sourced rows, so a broad query CAN fill the page with local rows.
// Flagged in the PR: acceptable while the catalogue is small; revisit (e.g.
// reserving a Places slot) if breadth ever suffers.
// ---------------------------------------------------------------------------
// NOTE: strongest-first is the RPC's job (`order by match_score desc, name`),
// NOT the blend's — blendResults preserves the order it is handed within each
// tier. So this feeds rows in RPC order and asserts that order survives.
Deno.test('strong local matches lead, in RPC order, and the list stays capped', () => {
  const strongs = [
    local('Baby Pizza', { match_score: 0.9 }),
    local('Pizza Farro', { match_score: 0.8 }),
    local('Pizza Roma', { match_score: 0.7 }),
  ];
  const out = blendResults([place('Pizza Hut', 100)], strongs);
  assertEquals(names(out), ['Baby Pizza', 'Pizza Farro', 'Pizza Roma', 'Pizza Hut']);
  assertEquals(kinds(out), ['manual', 'manual', 'manual', 'place']);
});

Deno.test('the blend does NOT re-sort within a tier — it trusts the RPC ordering', () => {
  const outOfOrder = [local('Zed Bar', { match_score: 0.7 }), local('Alpha Bar', { match_score: 0.95 })];
  assertEquals(names(blendResults([], outOfOrder)), ['Zed Bar', 'Alpha Bar']);
});

// ---------------------------------------------------------------------------
// Unchanged behaviours the blend must not regress.
// ---------------------------------------------------------------------------
Deno.test('predictions sort nearest-first; unmeasured ones trail, order-stable', () => {
  const out = blendResults([place('Far', 900), place('No Distance'), place('Near', 100)], []);
  assertEquals(names(out), ['Near', 'Far', 'No Distance']);
});

Deno.test('no local matches → Places-only, shape unchanged (soft-fail path)', () => {
  const out = blendResults([place('Chin Chin', 300)], []);
  assertEquals(out.length, 1);
  assertEquals(out[0], {
    kind: 'place',
    google_place_id: 'g-chin-chin',
    name: 'Chin Chin',
    secondary: 'Chin Chin St, Melbourne',
    distance_meters: 300,
  });
});

Deno.test('a local match carries the row id + city and omits a null cuisine', () => {
  const out = blendResults([], [local("Nonna's Kitchen (synthetic)", { city: 'Coburg', match_score: 0.66 })]);
  assertEquals(out, [
    {
      kind: 'manual',
      id: 'row-nonna-s-kitchen-synthetic-',
      name: "Nonna's Kitchen (synthetic)",
      city: 'Coburg',
      match_score: 0.66,
    },
  ]);
});
