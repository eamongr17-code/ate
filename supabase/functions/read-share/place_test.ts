// supabase/functions/read-share/place_test.ts
//
// Rule 8 — a place is never assumed: one clear candidate becomes a place, anything else is null.

import { test, assertEquals } from '../sort-entry/harness.ts';
import { decideGoogle, decideLocal, nameMatch, type LocalRow, type PredictionRow } from './place.ts';

const row = (id: string, name: string, strong: boolean, city: string | null = 'Melbourne'): LocalRow =>
  ({ id, name, city, match_score: strong ? 0.9 : 0.4, strong });
const pred = (id: string, name: string, secondary = 'Flinders Lane, Melbourne VIC, Australia'): PredictionRow =>
  ({ google_place_id: id, name, secondary });

test('nameMatch: same name, a qualified name, or a long prefix', () => {
  assertEquals(nameMatch('Chin Chin', 'Chin Chin'), 'exact');
  assertEquals(nameMatch('chinchin', 'Chin Chin'), 'exact');
  assertEquals(nameMatch('the Cutler and Co', 'Cutler & Co.'), 'exact');
  assertEquals(nameMatch('Chin Chin Melbourne', 'Chin Chin', 'Flinders Lane, Melbourne VIC, Australia'), 'exact');
  assertEquals(nameMatch('Chin Chin Sydney', 'Chin Chin', 'Flinders Lane, Melbourne VIC, Australia'), null);
  assertEquals(nameMatch('Supernormal', 'Supernormal Canteen'), 'prefix');
  assertEquals(nameMatch('Lune', 'Lune Croissanterie'), null, 'too short to be a prefix');
  assertEquals(nameMatch('Tipo', 'Tipo 00'), null);
});

test('local: exactly one strong row is the place', () => {
  assertEquals(decideLocal('Chin Chin', [row('r1', 'Chin Chin', true, '125 Flinders Ln, Melbourne VIC 3000'), row('r2', 'Chin', false)]), {
    kind: 'match',
    place: { restaurant_id: 'r1', google_place_id: null, name: 'Chin Chin', locality: 'Melbourne' },
  });
});

test('local: no strong row → go to Google; several strong rows the query cannot split → stop', () => {
  assertEquals(decideLocal('Chin Chin', [row('r2', 'Chin', false)]), { kind: 'none' });
  assertEquals(decideLocal('Chin Chin', []), { kind: 'none' });
  assertEquals(decideLocal('Lune Croissanterie', [row('a', 'Lune Croissanterie', true, 'Fitzroy'), row('b', 'Lune Croissanterie', true, 'Armadale')]),
    { kind: 'ambiguous' });
  assertEquals(decideLocal('Etta', [row('a', 'Etta', true, 'Brunswick East'), row('b', 'Ettamogah Pub', true)]), {
    kind: 'match', place: { restaurant_id: 'a', google_place_id: null, name: 'Etta', locality: 'Brunswick East' },
  });
  assertEquals(decideLocal('Etta', [row('a', null as unknown as string, true)]), { kind: 'none' });
});

test('google: one prediction named by the query → place with google_place_id + locality', () => {
  assertEquals(decideGoogle('Chin Chin', [pred('g1', 'Chin Chin'), pred('g2', 'Chin Chin Bar Food', 'Richmond VIC, Australia')]), {
    restaurant_id: null, google_place_id: 'g1', name: 'Chin Chin', locality: 'Melbourne',
  });
  assertEquals(decideGoogle('Supernormal', [pred('g1', 'Supernormal Canteen')])?.google_place_id, 'g1');
});

test('google: a chain, nothing named, or nothing at all → null', () => {
  assertEquals(decideGoogle('Lune Croissanterie', [
    pred('g1', 'Lune Croissanterie', 'Rose Street, Fitzroy VIC, Australia'),
    pred('g2', 'Lune Croissanterie', 'Collins Street, Melbourne VIC, Australia'),
  ]), null);
  assertEquals(decideGoogle('Lune', [pred('g1', 'Lune Croissanterie')]), null);
  assertEquals(decideGoogle('Bar Americano', [pred('g1', 'Bar Bambi'), pred('g2', 'Americano Cafe')]), null);
  assertEquals(decideGoogle('Bar Americano', []), null);
  assertEquals(decideGoogle('Bar Americano', [{ google_place_id: '', name: 'Bar Americano' }]), null);
});

test('google: the same place listed twice is still one place', () => {
  assertEquals(decideGoogle('Etta', [pred('g1', 'Etta'), pred('g1', 'Etta')])?.google_place_id, 'g1');
});
