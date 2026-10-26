// supabase/tests/db/place_map_point_test.mjs — the place header carries where the place is (0095).
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, point } from './fixtures.mjs';

let db, as, rows;
after(async () => db?.close());

const G = {
  google: '00000000-0000-4000-8000-0000000000d1',
  zero: '00000000-0000-4000-8000-0000000000d2',
};

before(async () => {
  const w = await world();
  ({ db, as, rows } = w);
  await db.exec(`
    insert into public.restaurants (id, google_place_id, name, address, city, source, location) values
      ('${G.google}', 'ChIJH8uNX8Rp1moR3B6YRXsiNNc', 'Small Wins', '1203 High St, Armadale VIC 3143, Australia', 'Armadale', 'places', ${point(145.0278178, -37.8562109)}),
      ('${G.zero}',   'g_zero', 'No Point', '1 Nowhere St, Fitzroy VIC 3065, Australia', 'Fitzroy', 'places', ${point(0, 0)});
  `);
});

const summary = (uid, id) => as(uid, () => rows(`select * from public.place_summary($1)`, [id])).then((r) => r[0]);

test('0095: a Google place gives its point and place id, signed in and signed out', async () => {
  for (const uid of [U.alice, null]) {
    const s = await summary(uid, G.google);
    assert.ok(Math.abs(s.lat - -37.8562109) < 1e-6, `lat for ${uid ?? 'anon'}`);
    assert.ok(Math.abs(s.lng - 145.0278178) < 1e-6, `lng for ${uid ?? 'anon'}`);
    assert.equal(s.google_place_id, 'ChIJH8uNX8Rp1moR3B6YRXsiNNc');
  }
});

test('0095: no point is NULL — a hand-added place, and a 0,0 point', async () => {
  const hand = await summary(U.alice, P.hand);
  assert.equal(hand.lat, null);
  assert.equal(hand.lng, null);
  assert.equal(hand.google_place_id, null);
  const zero = await summary(U.alice, G.zero);
  assert.equal(zero.lat, null, '0,0 is where Google sent no location, not a place');
  assert.equal(zero.lng, null);
});
