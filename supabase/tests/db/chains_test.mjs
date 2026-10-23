// supabase/tests/db/chains_test.mjs — chain restaurants are one place for dishes (0085).
//
//   cd supabase/tests/db && npm ci && node --test
//
// Detection (same name key + same website host; a shared social host never links), attaching (the
// locations' dishes merge onto one menu, every entry keeps its own location), every place read
// through place_menu / place_family, new lines at any location landing on the chain's dish, and
// dissolving a chain putting each location's lines back.

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, receipt, point } from './fixtures.mjs';

let w, db, as, asService, rows, error;
after(async () => db?.close());

const G = {
  fitzroy: '00000000-0000-4000-8000-0000000000c1',
  cbd: '00000000-0000-4000-8000-0000000000c2',
  sydney: '00000000-0000-4000-8000-0000000000c3',
  other: '00000000-0000-4000-8000-0000000000c4', //  same name, another business's website
  tiamoA: '00000000-0000-4000-8000-0000000000c5', // same name, both only on instagram
  tiamoB: '00000000-0000-4000-8000-0000000000c6',
};

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
  await db.exec(`
    insert into public.restaurants (id, google_place_id, name, address, city, source, location) values
      ('${G.fitzroy}', 'g_gyg_fitzroy', 'Guzman y Gomez - Fitzroy', '1 Smith St, Fitzroy VIC 3065, Australia', 'Fitzroy', 'places', ${point(144.983, -37.80)}),
      ('${G.cbd}',     'g_gyg_cbd',     'Guzman y Gomez | Melbourne Central', '211 La Trobe St, Melbourne VIC 3000, Australia', 'Melbourne', 'places', ${point(144.963, -37.81)}),
      ('${G.sydney}',  'g_gyg_syd',     'Guzman Y Gomez', '1 George St, Sydney NSW 2000, Australia', 'Sydney', 'places', ${point(151.207, -33.86)}),
      ('${G.other}',   'g_gyg_other',   'Guzman y Gomez', '9 High St, Northcote VIC 3070, Australia', 'Northcote', 'places', ${point(145.0, -37.77)}),
      ('${G.tiamoA}',  'g_tiamo_a',     'Tiamo', '303 Lygon St, Carlton VIC 3053, Australia', 'Carlton', 'places', ${point(144.967, -37.80)}),
      ('${G.tiamoB}',  'g_tiamo_b',     'Tiamo', '1 Main Rd, Ballarat VIC 3350, Australia', 'Ballarat', 'places', ${point(143.85, -37.56)});
  `);
});

const svc = (sql, params) => asService(() => rows(sql, params));
const code = async (p) => (await error(p))?.code ?? null;
const dishAt = async (entry, name) =>
  (await rows(`select r.dish_id, r.restaurant_id from public.reviews r join public.dishes d on d.id = r.dish_id
               where r.entry_id = $1 and public.dish_key(d.name) = public.dish_key($2)`, [entry, name]))[0];
const chainOf = async (place) => (await rows(`select chain_id from public.restaurants where id = $1`, [place]))[0].chain_id;
const menu = async (uid, place) =>
  (await as(uid, () => rows(`select dish_name, review_count from public.place_dishes($1) order by dish_name`, [place])))
    .map((r) => [r.dish_name, Number(r.review_count)]);
const link = (websites, ids) =>
  svc(`select public.chain_record_and_link($1::jsonb, $2::uuid[]) c`, [JSON.stringify(websites), ids]).then((r) => r[0].c);

let e1, e2, e3;

test('candidates: only places whose name repeats, unchecked first', async () => {
  e1 = await w.visit(1, U.alice, G.fitzroy, receipt(['Chicken Burrito', 4], ['Churros', 5]), '2026-10-01T09:00:00Z');
  e2 = await w.visit(2, U.bob, G.cbd, receipt(['Chicken Burritos', 5], ['Nachos', 3]), '2026-10-02T09:00:00Z');
  e3 = await w.visit(3, U.cleo, G.cbd, receipt(['Churros', 3]), '2026-10-03T09:00:00Z');

  const got = await svc(`select restaurant_id, checked from public.chain_candidates($1::uuid[])`, [[G.cbd]]);
  assert.deepEqual(new Set(got.map((r) => r.restaurant_id)), new Set([G.fitzroy, G.cbd, G.sydney, G.other]));
  assert.ok(got.every((r) => r.checked === false));
  assert.deepEqual(await svc(`select * from public.chain_candidates($1::uuid[])`, [['00000000-0000-4000-8000-0000000000f1']]), [],
    'a hand-typed place is never a candidate');
});

test('linking: same name and same website host only; a shared social host proves nothing', async () => {
  await link([
    { id: G.fitzroy, host: 'guzmanygomez.com.au' }, { id: G.cbd, host: 'guzmanygomez.com.au' },
    { id: G.sydney, host: 'guzmanygomez.com.au' }, { id: G.other, host: 'gygnorthcote.com' },
    { id: G.tiamoA, host: 'instagram.com' }, { id: G.tiamoB, host: 'instagram.com' },
  ], [G.cbd, G.other, G.tiamoA]);

  const chain = await chainOf(G.cbd);
  assert.ok(chain);
  assert.equal(await chainOf(G.fitzroy), chain);
  assert.equal(await chainOf(G.sydney), chain, 'every same-name, same-host place joins');
  assert.equal(await chainOf(G.other), null, 'another website is another business');
  assert.equal(await chainOf(G.tiamoA), null);
  assert.equal(await chainOf(G.tiamoB), null);
  const [c] = await svc(`select name, website_host, anchor_restaurant_id from public.chains where id = $1`, [chain]);
  assert.equal(c.anchor_restaurant_id, G.cbd, 'the menu lives where most dishes already were');
  assert.equal(c.name, 'Guzman y Gomez');
  const checked = await rows(`select count(*)::int n from public.restaurants where website_checked_at is not null`);
  assert.equal(checked[0].n, 6, 'each website is recorded, so never fetched twice');
});

test('one dish per chain: the same burrito at two locations is one dish with both lines', async () => {
  const a = await dishAt(e1, 'Chicken Burrito');
  const b = await dishAt(e2, 'Chicken Burrito');
  assert.ok(a && b);
  assert.equal(a.dish_id, b.dish_id);
  const [s] = await rows(`select review_count from public.dish_stats where dish_id = $1`, [a.dish_id]);
  assert.equal(Number(s.review_count), 2);
  const [{ reason }] = await rows(`select reason from public.dish_merges where target_dish_id = $1`, [a.dish_id]);
  assert.equal(reason, 'chain', 'logged, so unmerge_dish can undo it');

  // every entry keeps its own location
  const places = await rows(`select id, restaurant_id from public.entries where id = any($1::uuid[]) order by id`, [[e1, e2]]);
  assert.deepEqual(places.map((p) => p.restaurant_id), [G.fitzroy, G.cbd]);
});

test('every location shows the chain\'s menu, numbers and entries', async () => {
  const want = [['Chicken Burritos', 2], ['Churros', 2], ['Nachos', 1]];   // the menu's own spelling
  for (const place of [G.fitzroy, G.cbd, G.sydney]) {
    assert.deepEqual(await menu(U.dan, place), want, place);
    assert.deepEqual(await menu(null, place), want, `${place}, signed out`);
  }
  const sum = async (place) => (await as(U.alice, () => rows(
    `select name, address, review_count, people_count, dish_count, entry_count, my_visits from public.place_summary($1)`, [place])))[0];
  const f = await sum(G.fitzroy);
  const s = await sum(G.sydney);
  assert.equal(f.address, '1 Smith St, Fitzroy VIC 3065, Australia', 'a location keeps its own address');
  for (const k of ['review_count', 'people_count', 'dish_count', 'entry_count', 'my_visits']) assert.equal(s[k], f[k], k);
  assert.deepEqual([f.review_count, f.people_count, f.dish_count, f.entry_count, f.my_visits], [5, 3, 3, 3, 1]);

  const at = await as(U.dan, () => rows(`select id from public.get_entries_at_place($1)`, [G.sydney]));
  assert.equal(at.length, 3, 'the entries at any location of the chain');
  const [n] = await as(U.dan, () => rows(`select review_count from public.place_numbers($1, null, null)`, [G.fitzroy]));
  assert.equal(n.review_count, 5, 'Search and nearby numbers too');
  assert.equal((await chainOf(G.other)), null);
  assert.deepEqual(await menu(U.dan, G.other), [], 'the unrelated namesake has its own (empty) menu');
});

test('new lines at any location land on the chain\'s dish; a chain dish shows no suburb', async () => {
  const e4 = await w.visit(4, U.dan, G.sydney, receipt(['chicken burrito', 5]), '2026-10-04T09:00:00Z');
  const first = await dishAt(e1, 'Chicken Burrito');
  assert.equal((await dishAt(e4, 'Chicken Burrito')).dish_id, first.dish_id);
  const [{ id: viaFind }] = await svc(`select public.find_or_create_dish($1, 'Chicken Burrito') id`, [G.fitzroy]);
  assert.equal(viaFind, first.dish_id);

  const [d] = await as(U.alice, () => rows(`select restaurant_locality, review_count from public.dish_summary($1)`, [first.dish_id]));
  assert.equal(d.restaurant_locality, null);
  assert.equal(d.review_count, 3);
  const [{ known_dishes }] = await svc(`select public.sort_entry_context($1) -> 'known_dishes' known_dishes`, [e1]);
  assert.ok(known_dishes.includes('Nachos'), 'the sorter at Fitzroy knows the whole menu');
});

test('dissolving a chain gives each location its own lines back', async () => {
  const chain = await chainOf(G.cbd);
  await svc(`select public.chain_dissolve($1)`, [chain]);
  for (const p of [G.fitzroy, G.cbd, G.sydney]) assert.equal(await chainOf(p), null);
  assert.equal((await svc(`select count(*)::int n from public.chains`))[0].n, 0);
  assert.deepEqual(await menu(U.dan, G.fitzroy), [['Chicken Burrito', 1], ['Churros', 1]]);
  assert.deepEqual(await menu(U.dan, G.sydney), [['Chicken Burritos', 1]], 'a line written since keeps the menu\'s name');
  assert.deepEqual(await menu(U.dan, G.cbd), [['Chicken Burritos', 1], ['Churros', 1], ['Nachos', 1]]);
  const a = await dishAt(e1, 'Chicken Burrito');
  assert.equal(a.restaurant_id, G.fitzroy);
});

test('the chain functions are service-role only', async () => {
  assert.equal(await code(as(U.alice, () => rows(`select public.chain_attach($1, $1)`, [G.cbd]))), '42501');
  assert.equal(await code(as(U.alice, () => rows(`select * from public.chain_candidates(null)`))), '42501');
  assert.equal(await code(as(U.alice, () => rows(`select * from public.chains`))), '42501');
});
