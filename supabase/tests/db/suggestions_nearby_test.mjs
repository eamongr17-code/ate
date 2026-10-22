// supabase/tests/db/suggestions_nearby_test.mjs — 0080: dish suggestions come from around you.
// similar_dishes and dishes_by_tag (no city) keep to places within 25 km of the phone's point, else the
// dish's place, else where the caller last ate. A city, or a suburb/city chip, says where on its own.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, receipt } from './fixtures.mjs';

let w, db, as, rows;
let base;

const MELBOURNE = [-37.8136, 144.9631];
const GEELONG = [-38.1490, 144.3600];
const BANGKOK = [13.7563, 100.5018];

// Pasta everywhere: Rigatoni at Tipo (CBD), Linguine at Osteria (Carlton), Penne at the hand-typed
// Corner Cafe (Fitzroy, no point — Melbourne by its locality), Spaghetti at Tipo Far (Geelong, 60 km).
// Bob eats in Geelong last.
before(async () => {
  w = await world();
  ({ db, as, rows } = w);
  base = (await rows(`select dish_id from public.reviews where entry_id = $1`,
    [await w.visit(1, U.alice, P.tipo, receipt(['Rigatoni', 4]), '2026-09-10T09:00:00Z')]))[0].dish_id;
  await w.visit(2, U.cleo, P.osteria, receipt(['Linguine', 5]), '2026-09-10T10:00:00Z');
  await w.visit(3, U.cleo, P.hand, receipt(['Penne', 3]), '2026-09-10T11:00:00Z');
  await w.visit(4, U.bob, P.far, receipt(['Spaghetti', 4]), '2026-09-10T12:00:00Z');
});
after(async () => db?.close());

const names = (r) => r.map((x) => x.name).sort();
const similar = (uid, at) => as(uid, () => rows(
  at ? `select name from public.similar_dishes($1, 50, $2, $3)` : `select name from public.similar_dishes($1, 50)`,
  at ? [base, ...at] : [base]));
const tagged = (uid, args = '') => as(uid, () => rows(`select name from public.dishes_by_tag(p_kind => 'style', p_slug => 'pasta'${args})`));

test('similar_dishes: no point — the dish\'s place is the centre; a hand-typed place counts by its city', async () => {
  assert.deepEqual(names(await similar(U.dan)), ['Linguine', 'Penne']);
});

test('similar_dishes: the phone\'s point wins over the dish\'s place', async () => {
  assert.deepEqual(names(await similar(U.dan, MELBOURNE)), ['Linguine', 'Penne']);
  assert.deepEqual(names(await similar(U.dan, GEELONG)), ['Spaghetti']);
  assert.deepEqual(await similar(U.dan, BANGKOK), [], 'nothing from the other side of the world');
});

test('dishes_by_tag: with a point, only the area', async () => {
  const lat = (p) => `, p_lat => ${p[0]}, p_lng => ${p[1]}`;
  assert.deepEqual(names(await tagged(U.dan, lat(MELBOURNE))), ['Linguine', 'Penne', 'Rigatoni']);
  assert.deepEqual(names(await tagged(U.dan, lat(GEELONG))), ['Spaghetti']);
  assert.deepEqual(await tagged(U.dan, lat(BANGKOK)), []);
});

test('dishes_by_tag: no point — where the caller last ate; nothing known is everywhere', async () => {
  assert.deepEqual(names(await tagged(U.bob)), ['Spaghetti'], 'bob last ate in Geelong');
  assert.deepEqual(names(await tagged(U.cleo)), ['Linguine', 'Penne', 'Rigatoni'], 'cleo last ate at a located Melbourne place');
  assert.deepEqual(names(await tagged(U.dan)), ['Linguine', 'Penne', 'Rigatoni', 'Spaghetti'], 'dan: no entries, no point');
});

test('dishes_by_tag: a city, or a place chip, is its own area', async () => {
  const there = `, p_lat => ${MELBOURNE[0]}, p_lng => ${MELBOURNE[1]}`;
  assert.deepEqual(names(await tagged(U.dan, `, p_city => 'geelong'${there}`)), ['Spaghetti'], 'the Feed\'s city, as before');
  const chip = await as(U.dan, () => rows(`select name from public.dishes_by_tag(p_kind => 'city', p_slug => 'geelong'${there})`));
  assert.deepEqual(names(chip), ['Spaghetti'], 'a Geelong chip opened from Melbourne still shows Geelong');
});

test('one overload each; signed-out callers are refused', async () => {
  for (const f of ['similar_dishes', 'dishes_by_tag']) {
    assert.equal((await rows(`select count(*)::int n from pg_proc where proname = $1 and pronamespace = 'public'::regnamespace`, [f]))[0].n, 1, f);
  }
  await assert.rejects(as(null, () => db.query(`select * from public.similar_dishes($1)`, [base])));
});
