// supabase/functions/places-search/name_test.ts
//
// The keyword-padding rule for place names. Runs under Node (type stripping):
//   node --test supabase/functions/places-search/name_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cleanPlaceName } from './name.ts';

const cases: [string, string][] = [
  // The listing Eamon saw (20 Oct).
  ['VIVIN Suk 22 - café grocery bistro - Local Organic Natural Artisan', 'VIVIN Suk 22'],
  ['Chin Chin | Modern Thai Restaurant Melbourne', 'Chin Chin'],
  ['Mamasita – Mexican Cantina', 'Mamasita'],
  ['Lune — Croissanterie · Fitzroy', 'Lune'],
  ['Pho Hung (Vietnamese Restaurant)', 'Pho Hung'],
  ['Bar Liberty [Fitzroy]', 'Bar Liberty'],
  ['Cafe Bliss|Brunch|Coffee', 'Cafe Bliss'],
  // Real names stay whole.
  ['Ka-Pow', 'Ka-Pow'],
  ['Tipo 00', 'Tipo 00'],
  ['Cutler & Co', 'Cutler & Co'],
  ['Bread, Wine & Cheese', 'Bread, Wine & Cheese'],
  ['  Small   Wins ', 'Small Wins'],
  // Nothing left after a rule → keep what Google gave.
  ['A - Restaurant', 'A - Restaurant'],
  ['(Untitled)', '(Untitled)'],
];

for (const [raw, want] of cases) {
  test(`${raw} → ${want}`, () => assert.equal(cleanPlaceName(raw), want));
}
