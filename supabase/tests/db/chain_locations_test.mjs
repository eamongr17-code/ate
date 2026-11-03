// supabase/tests/db/chain_locations_test.mjs — 0106: a chain's dishes at every location.
//
//   cd supabase/tests/db && npm ci && node --test
//
// One rated Guzman y Gomez; Google's answer (as places-search/chains.ts hands it over) adds the other
// locations with the same name key and website host, links them into one chain, and the map pins
// every one of them with the chain's dish. A place is asked once; a shared host, another website or
// another name links nothing; a place we already hold keeps its own name and address.

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, receipt, point } from './fixtures.mjs';

let w, db, as, asService, rows, error;
after(async () => db?.close());

const G = {
  fitzroy: '00000000-0000-4000-8000-0000000001c1',
  held: '00000000-0000-4000-8000-0000000001c2',     // a location we already hold, not yet in a chain
  noDish: '00000000-0000-4000-8000-0000000001c3',   // a place with no dish: never due
  tiamo: '00000000-0000-4000-8000-0000000001c4',    // only on instagram
};

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
  await db.exec(`
    insert into public.restaurants (id, google_place_id, name, address, city, source, location) values
      ('${G.fitzroy}', 'g_fitz', 'Guzman y Gomez - Fitzroy', '1 Smith St, Fitzroy VIC 3065, Australia', 'Fitzroy', 'places', ${point(144.983, -37.80)}),
      ('${G.held}',    'g_held', 'Guzman y Gomez', 'Our own address, Carlton VIC 3053, Australia', 'Carlton', 'places', ${point(144.967, -37.80)}),
      ('${G.noDish}',  'g_nodish', 'Small Wins', '1 Gertrude St, Fitzroy VIC 3065, Australia', 'Fitzroy', 'places', ${point(144.98, -37.805)}),
      ('${G.tiamo}',   'g_tiamo', 'Tiamo', '303 Lygon St, Carlton VIC 3053, Australia', 'Carlton', 'places', ${point(144.967, -37.80)});
  `);
  await w.visit(1, U.alice, G.fitzroy, receipt(['Chicken Burrito', 4.5]), '2026-11-01T09:00:00Z');
  await w.visit(2, U.bob, G.tiamo, receipt(['Lasagne', 4]), '2026-11-01T10:00:00Z');
});

const svc = (sql, params) => asService(() => rows(sql, params));
const due = (ids) => svc(`select restaurant_id, google_place_id, name, latitude, longitude, website_checked
                          from public.chain_locations_due($1::uuid[])`, [ids]);
const add = (place, host, places) =>
  svc(`select public.chain_add_locations($1, $2, $3::jsonb) c`, [place, host, JSON.stringify(places)]).then((r) => r[0].c);
const found = (id, name, lng, lat, host, address = `${id} St, Melbourne VIC 3000, Australia`) =>
  ({ google_place_id: id, name, address, city: 'Melbourne', lat, lng, cuisine: 'Mexican restaurant', host });

test('due: a Google place with a dish, never asked; not one without a dish; the backfill sees all', async () => {
  const got = await due([G.fitzroy, G.noDish]);
  assert.deepEqual(got.map((r) => r.restaurant_id), [G.fitzroy]);
  assert.equal(got[0].google_place_id, 'g_fitz');
  assert.ok(Math.abs(got[0].latitude + 37.8) < 1e-6 && Math.abs(got[0].longitude - 144.983) < 1e-6);
  const all = await due(null);
  assert.deepEqual(new Set(all.map((r) => r.restaurant_id)), new Set([G.fitzroy, G.tiamo]));
  assert.equal(await (async () => { try { await as(U.alice, () => rows(`select * from public.chain_locations_due(null)`)); return 'ran'; } catch (e) { return e.code; } })(),
    '42501', 'service role only');
});

test('add: same name and website become one chain; another site, another name and a shared host do not', async () => {
  const chain = await add(G.fitzroy, 'guzmanygomez.com.au', [
    found('g_fitz', 'Guzman y Gomez - Fitzroy', 144.983, -37.80, 'guzmanygomez.com.au'),     // itself
    found('g_cbd', 'Guzman y Gomez | Melbourne Central', 144.963, -37.81, 'guzmanygomez.com.au'),
    found('g_syarra', 'Guzman Y Gomez', 144.99, -37.84, 'guzmanygomez.com.au'),
    found('g_held', 'Guzman y Gomez Carlton (new listing name)', 144.967, -37.80, 'guzmanygomez.com.au'),
    found('g_fake', 'Guzman y Gomez', 145.0, -37.77, 'gygnorthcote.com'),                     // another business
    found('g_taco', 'Taco Bell', 144.96, -37.81, 'guzmanygomez.com.au'),                      // another name
    found('g_zero', 'Guzman y Gomez', 0, 0, 'guzmanygomez.com.au'),                           // no point
  ]);
  assert.ok(chain);
  const inChain = await rows(`select google_place_id from public.restaurants where chain_id = $1 order by google_place_id`, [chain]);
  assert.deepEqual(inChain.map((r) => r.google_place_id), ['g_cbd', 'g_fitz', 'g_syarra']);
  assert.deepEqual(await rows(`select google_place_id from public.restaurants where google_place_id in ('g_fake','g_taco','g_zero')`), [],
    'nothing unrelated is stored');

  const [held] = await rows(`select name, address, chain_id from public.restaurants where id = $1`, [G.held]);
  assert.equal(held.name, 'Guzman y Gomez', 'a place we hold keeps its own name');
  assert.equal(held.address, 'Our own address, Carlton VIC 3053, Australia');
  assert.equal(held.chain_id, null, 'its listing name no longer matches, so it is not linked');

  const [cbd] = await rows(`select name, city, source, website_host, locations_checked_at is not null asked
                            from public.restaurants where google_place_id = 'g_cbd'`);
  assert.equal(cbd.name, 'Guzman y Gomez', 'stored names are cleaned (0075)');
  assert.equal(cbd.source, 'places');
  assert.equal(cbd.website_host, 'guzmanygomez.com.au');
  assert.equal(cbd.asked, true, 'a found location is not searched again');
  assert.deepEqual(await due(null).then((r) => r.map((x) => x.restaurant_id)), [G.tiamo], 'Fitzroy is never asked again');
});

test('the map pins every location with the chain\'s dish; Near me lists it once', async () => {
  const box = `-37.9, 144.9, -37.7, 145.1`;
  const pins = await as(U.dan, () => rows(
    `select name, top_dish_name, top_score from public.map_places(${box}, -37.80, 144.98, 150) where top_dish_name = 'Chicken Burrito'`));
  assert.equal(pins.length, 3, 'Fitzroy, Melbourne Central and South Yarra');
  assert.ok(pins.every((p) => Number(p.top_score) === 4.5));
  const sheet = await as(U.dan, () => rows(
    `select dish_name, distance_m from public.map_dishes(${box}, -37.80, 144.98, 20) where dish_name = 'Chicken Burrito'`));
  assert.equal(sheet.length, 1);
  const menu = await as(U.dan, () => rows(`select dish_name from public.place_dishes((select id from public.restaurants where google_place_id = 'g_syarra'))`));
  assert.deepEqual(menu.map((r) => r.dish_name), ['Chicken Burrito'], 'a location nobody rated shows the chain\'s menu');
});

test('a shared host or no website links nothing, but the place is recorded as asked', async () => {
  assert.equal(await add(G.tiamo, 'instagram.com', [found('g_tiamo2', 'Tiamo', 144.97, -37.79, 'instagram.com')]), null);
  assert.deepEqual(await rows(`select 1 from public.restaurants where google_place_id = 'g_tiamo2'`), []);
  const [t] = await rows(`select website_host, locations_checked_at is not null asked from public.restaurants where id = $1`, [G.tiamo]);
  assert.deepEqual([t.website_host, t.asked], ['instagram.com', true]);
  assert.deepEqual(await due(null), [], 'nothing left to ask');
  assert.equal(await add(G.noDish, null, []), null);
});

test('a later search from a chain location adds new locations to the same chain', async () => {
  const [{ chain_id: chain }] = await rows(`select chain_id from public.restaurants where id = $1`, [G.fitzroy]);
  await svc(`update public.restaurants set locations_checked_at = null where google_place_id = 'g_cbd'`);
  const got = await add(
    (await rows(`select id from public.restaurants where google_place_id = 'g_cbd'`))[0].id,
    'guzmanygomez.com.au',
    [found('g_docklands', 'Guzman y Gomez', 144.94, -37.815, 'guzmanygomez.com.au')]);
  assert.equal(got, chain);
  const [d] = await rows(`select chain_id from public.restaurants where google_place_id = 'g_docklands'`);
  assert.equal(d.chain_id, chain);
});
