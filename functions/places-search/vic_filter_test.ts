// supabase/functions/places-search/vic_filter_test.ts
//
// Deno unit test for the VIC border-bleed filter (PH-BE-1+2 peer-review fix).
// Run from the function dir:  deno test --no-check vic_filter_test.ts
//
// This asserts the inverted rule: a result is dropped ONLY when its text
// positively names another AU state/territory; a state-less Melbourne/Fitzroy
// result survives (the locationRestriction box already guarantees it's in VIC).
//
// The regex below MUST stay byte-identical to OTHER_AU_STATE_RE in index.ts.
// (index.ts is a Deno.serve entrypoint that fetches Google on import-side
// constants, so we mirror the predicate here rather than importing it.)

import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';

const OTHER_AU_STATE_RE =
  /\b(?:NSW|QLD|SA|WA|NT|TAS|ACT)\b|\bNew South Wales\b|\bQueensland\b|\bSouth Australia\b|\bWestern Australia\b|\bNorthern Territory\b|\bTasmania\b|\bAustralian Capital Territory\b/i;

function namesOtherAuState(text: string | null | undefined): boolean {
  return OTHER_AU_STATE_RE.test(text ?? '');
}

// A "kept" prediction is one that does NOT name another state.
const kept = (t: string) => !namesOtherAuState(t);

Deno.test('KEEPS state-less VIC venues (Google omits the state token)', () => {
  assertEquals(kept('Melbourne, Australia'), true);
  assertEquals(kept('Fitzroy, Australia'), true);
  assertEquals(kept('123 Smith St, Collingwood, Australia'), true);
  assertEquals(kept('Carlton VIC, Australia'), true); // explicit VIC also kept
});

Deno.test('DROPS clear border-bleed naming another AU state/territory', () => {
  assertEquals(kept('Albury, NSW, Australia'), false);
  assertEquals(kept('Mount Gambier, South Australia'), false);
  assertEquals(kept('Tweed Heads, New South Wales'), false);
  assertEquals(kept('Brisbane QLD, Australia'), false);
  assertEquals(kept('Perth WA'), false);
  assertEquals(kept('Hobart, TAS'), false);
  assertEquals(kept('Canberra ACT'), false);
  assertEquals(kept('Darwin, NT'), false);
});

Deno.test('word boundaries: VIC towns whose names CONTAIN a state abbr are KEPT', () => {
  // "WA" inside WARRNAMBOOL, "SA" inside SALE — both real VIC towns.
  assertEquals(kept('Warrnambool, Australia'), true);
  assertEquals(kept('Sale, Australia'), true);
  assertEquals(kept('Wangaratta, Australia'), true); // contains "ang" not a state
  assertEquals(kept('Bendigo, Australia'), true);
});
