// supabase/tests/db/dish_map_test.mjs — 0088: the dish map's pins (map_places) and sheet (map_dishes).
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, receipt, photoUrl } from './fixtures.mjs';

let w, db, as, rows;

// The inner north, around Fitzroy/Carlton/CBD; Geelong sits 60 km out.
const BOX = { minLat: -37.83, minLng: 144.94, maxLat: -37.79, maxLng: 144.99 };
const FITZROY = [-37.8060, 144.9780];

before(async () => {
  w = await world();
  ({ db, as, rows } = w);
  await w.visit(1, U.alice, P.tipo, receipt(['Rigatoni', 4], ['Tiramisu', 5]), '2026-09-10T09:00:00Z', { photos: ['t/1.jpg'] });
  await w.visit(2, U.bob, P.tipo, receipt(['Rigatoni', 5]), '2026-09-11T09:00:00Z');
  await w.visit(3, U.cleo, P.osteria, receipt(['Ragù', 3]), '2026-09-10T10:00:00Z', { photos: ['o/1.jpg'] });
  await w.visit(4, U.bob, P.far, receipt(['Pad Thai', 5]), '2026-09-10T12:00:00Z');
  await w.visit(5, U.cleo, P.marion, receipt(['Anchovies']), '2026-09-10T13:00:00Z');
});
after(async () => db?.close());

const places = (uid, args) => as(uid, () => rows(`select * from public.map_places(${args})`));
const boxArgs = (b = BOX) => `${b.minLat}, ${b.minLng}, ${b.maxLat}, ${b.maxLng}`;
const dishes = (uid, args) => as(uid, () => rows(`select * from public.map_dishes(${args})`));

test('map_places: the places in the box with a dish, each with its best dish', async () => {
  const got = await places(U.dan, `${boxArgs()}, ${FITZROY[0]}, ${FITZROY[1]}`);
  assert.deepEqual(got.map((p) => p.name).sort(), ['Marion', 'Osteria Ilaria', 'Tipo 00'], 'Geelong is out of view, Corner Cafe has no point');
  const tipo = got.find((p) => p.name === 'Tipo 00');
  // Tiramisu 5 (1 review) and Rigatoni 4.5 (2 reviews): the score wins.
  assert.equal(tipo.top_dish_name, 'Tiramisu');
  assert.equal(Number(tipo.top_score), 5);
  assert.equal(tipo.dish_count, 2);
  assert.equal(tipo.locality, 'Melbourne');
  assert.ok(Math.abs(tipo.latitude - -37.8136) < 1e-6 && Math.abs(tipo.longitude - 144.9631) < 1e-6);
  assert.ok(tipo.distance_m > 1000 && tipo.distance_m < 2000, `about 1.5 km from Fitzroy, got ${tipo.distance_m}`);
  const marion = got.find((p) => p.name === 'Marion');
  assert.equal(marion.top_score, null, 'nobody scored it: no score, never inferred');
  assert.equal(marion.second_cover_url, null);
});

test('map_places: the stacked photo is the best OTHER dish with a photo, never the pin\'s own', async () => {
  const got = await places(U.dan, boxArgs());
  const tipo = got.find((p) => p.name === 'Tipo 00');
  const osteria = got.find((p) => p.name === 'Osteria Ilaria');
  assert.equal(osteria.top_cover_url, photoUrl('o/1.jpg'), 'one dish, one photo: its own');
  assert.equal(osteria.second_cover_url, null, 'one dish: nothing stacked');
  assert.notEqual(tipo.second_cover_url ?? 'none', tipo.top_cover_url ?? 'none-top');
});

test('map_places: no box answers the nearest places to the point, however far', async () => {
  const geelong = await places(U.dan, `p_lat => -38.149, p_lng => 144.36, p_limit => 2`);
  assert.equal(geelong.length, 2);
  assert.equal(geelong[0].name, 'Tipo Far', 'nearest first');
  const busiest = await places(U.dan, `p_limit => 1`);
  assert.equal(busiest[0].name, 'Tipo 00', 'no box and no point: around the place most written about');
});

test('map_dishes: every dish at the places in view, best first, keyset-paged without gaps', async () => {
  const all = await dishes(U.alice, `${boxArgs()}, ${FITZROY[0]}, ${FITZROY[1]}, 50`);
  assert.deepEqual(all.map((d) => d.dish_name), ['Tiramisu', 'Rigatoni', 'Ragù', 'Anchovies']);
  assert.equal(all[0].place_name, 'Tipo 00');
  assert.ok(all.every((d) => d.distance_m != null));

  const walked = await w.walk((last) => dishes(U.alice, last
    ? `${boxArgs()}, p_limit => 1, p_cursor_score => ${last.score ?? 'null'}, p_cursor_review_count => ${last.review_count}, p_cursor_dish_id => '${last.dish_id}'`
    : `${boxArgs()}, p_limit => 1`));
  assert.deepEqual(walked.map((d) => d.dish_name), all.map((d) => d.dish_name));
  assert.equal(walked[0].distance_m, null, 'no point: no distance');
});

test('signed out is refused; a bad box is refused', async () => {
  await assert.rejects(as(null, () => db.query(`select * from public.map_places(${boxArgs()})`)));
  await assert.rejects(as(null, () => db.query(`select * from public.map_dishes(${boxArgs()})`)));
  await assert.rejects(places(U.dan, `-37.7, 144.94, -37.8, 144.99`), /bad_box/);
});
