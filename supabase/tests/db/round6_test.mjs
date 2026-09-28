// supabase/tests/db/round6_test.mjs — round 6 (0050–0051) at the SQL level: the date window on Search
// and Saved, and "What to order" ranked by rating.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { actors, boot } from './harness.mjs';

const A = '00000000-0000-4000-8000-00000000000a';
const B = '00000000-0000-4000-8000-00000000000b';
const R1 = '00000000-0000-4000-8000-0000000000f1'; // Gnocchi Bar, Melbourne
const R2 = '00000000-0000-4000-8000-0000000000f2'; // Menu Hall, Melbourne — the ranking fixture
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const point = (lng, lat) => `extensions.ST_SetSRID(extensions.ST_MakePoint(${lng}, ${lat}), 4326)::geography`;

let db, as, asService, rows, error;

before(async () => {
  db = await boot();
  ({ as, asService, rows, error } = actors(db));
  await db.exec(`
    insert into auth.users (id, email) values ('${A}', 'alice@ate.test'), ('${B}', 'bob@ate.test');
    insert into public.restaurants (id, name, address, city, cuisine, source, location) values
      ('${R1}', 'Gnocchi Bar', '1 Lygon St, Carlton VIC 3053, Australia', 'Carlton', 'Italian', 'manual', ${point(144.9671, -37.8000)}),
      ('${R2}', 'Menu Hall', '2 Smith St, Fitzroy VIC 3065, Australia', 'Fitzroy', 'Modern', 'manual', ${point(144.9830, -37.8010)});
  `);
});
after(async () => db?.close());

async function visit(n, author, place, body, items, when) {
  await as(author, () => db.query(
    `insert into public.entries (id, author_id, body, restaurant_id, created_at) values ($1, $2, $3, $4, $5)`,
    [id(n), author, body, place, when],
  ));
  await asService(() => db.query(
    `select public.apply_entry_sort(p_entry_id => $1, p_restaurant_id => $2, p_items => $3::jsonb, p_mode => 'stub')`,
    [id(n), place, JSON.stringify(items)],
  ));
  return id(n);
}
const line = (dish, s) => (s == null ? { dish_name: dish } : { dish_name: dish, score: s, score_evidence: `${dish} ${s}` });
const body = (...ls) => ls.map(([d, s]) => (s == null ? `${d} was fine` : `${d} ${s}`)).join(', ');
const lines = (...ls) => ls.map(([d, s]) => line(d, s));

test('0050: in_window — inclusive calendar days in the zone, either end open', async () => {
  const at = '2026-06-30T15:00:00Z'; // 1 July 01:00 in Melbourne, still 30 June in UTC
  const w = async (from, to, tz) => (await as(A, () => rows(`select public.in_window($1, $2, $3, $4) ok`, [at, from, to, tz])))[0].ok;
  assert.equal(await w('2026-07-01', '2026-07-01', null), true, 'Melbourne by default');
  assert.equal(await w('2026-07-01', null, 'UTC'), false);
  assert.equal(await w(null, '2026-06-30', 'UTC'), true);
  assert.equal(await w(null, null, null), true, 'no window');
});

test('0050: Search — with a window only its lines count; old calls unchanged', async () => {
  await visit(1, A, R1, body(['Gnocchi', 5]), lines(['Gnocchi', 5]), '2026-01-10T02:00:00Z');
  await visit(2, B, R1, body(['Gnocchi', 3], ['Tiramisu', 4]), lines(['Gnocchi', 3], ['Tiramisu', 4]), '2026-07-10T02:00:00Z');

  const places = (args) => as(A, () => rows(
    `select name, avg_rating::float r, review_count n, people_count p, dish_count d from public.search_places(p_query => 'gnocchi'${args})`));
  assert.deepEqual(await places(''), [{ name: 'Gnocchi Bar', r: 4, n: 3, p: 2, d: 2 }], 'all time');
  assert.deepEqual(await places(`, p_from => '2026-07-01', p_to => '2026-07-31'`), [{ name: 'Gnocchi Bar', r: 3.5, n: 2, p: 1, d: 2 }]);
  assert.deepEqual(await places(`, p_to => '2026-01-31'`), [{ name: 'Gnocchi Bar', r: 5, n: 1, p: 1, d: 1 }], 'open start');
  assert.deepEqual(await places(`, p_from => '2026-03-01', p_to => '2026-04-30'`), [], 'no line in the window → not a result');
  assert.deepEqual(await places(`, p_to => '2026-01-31', p_min_score => 4.5`), [{ name: 'Gnocchi Bar', r: 5, n: 1, p: 1, d: 1 }], 'the range reads the windowed score');
  assert.deepEqual(await places(`, p_from => '2026-07-01', p_min_score => 4.5`), []);
  // A 0049-shaped call binds.
  assert.equal((await as(A, () => rows(`select count(*)::int n from public.search_places(p_query => 'gnocchi', p_limit => 20, p_cursor_match_tier => null,
    p_cursor_review_count => null, p_cursor_name => null, p_cursor_id => null, p_cuisines => null, p_tags => null, p_min_score => null,
    p_max_score => null, p_city => null)`)))[0].n, 1);

  const dishes = (args) => as(A, () => rows(
    `select dish_name, score::float s, review_count n, scored_count sc, people_count p from public.search_dishes(p_query => 'gn'${args})`));
  assert.deepEqual(await dishes(''), [{ dish_name: 'Gnocchi', s: 4, n: 2, sc: 2, p: 2 }]);
  assert.deepEqual(await dishes(`, p_from => '2026-07-01'`), [{ dish_name: 'Gnocchi', s: 3, n: 1, sc: 1, p: 1 }]);
  assert.deepEqual(await dishes(`, p_to => '2026-01-31'`), [{ dish_name: 'Gnocchi', s: 5, n: 1, sc: 1, p: 1 }]);
  assert.deepEqual(await dishes(`, p_from => '2026-03-01', p_to => '2026-04-30'`), []);
  assert.deepEqual((await as(A, () => rows(`select dish_name from public.search_dishes(p_query => 'ti', p_to => '2026-01-31')`))), [], 'Tiramisu was only in July');

  const near = (args) => as(A, () => rows(
    `select name, avg_rating::float r, review_count n from public.nearby_places(p_lat => -37.80, p_lng => 144.967, p_radius_m => 2000${args})`));
  assert.deepEqual(await near(`, p_from => '2026-07-01'`), [{ name: 'Gnocchi Bar', r: 3.5, n: 2 }], 'Menu Hall has no line yet');
  assert.deepEqual(await near(`, p_to => '2025-12-31'`), []);
});

test('0050: Saved — by the day it was saved', async () => {
  const gnocchi = (await rows(`select id from public.dishes where name = 'Gnocchi'`))[0].id;
  const tiramisu = (await rows(`select id from public.dishes where name = 'Tiramisu'`))[0].id;
  await as(A, () => db.query(`select public.save_dish($1, $2)`, [gnocchi, id(2)]));
  await as(A, () => db.query(`select public.save_dish($1, $2)`, [tiramisu, id(2)]));
  await db.query(`update public.saves set created_at = '2026-02-03T01:00:00Z' where dish_id = $1`, [gnocchi]);
  await db.query(`update public.saves set created_at = '2026-08-03T01:00:00Z' where dish_id = $1`, [tiramisu]);
  const shelf = (args) => as(A, () => rows(`select dish_name from public.search_saved(p_limit => 50${args})`)).then((r) => r.map((x) => x.dish_name));
  assert.deepEqual(await shelf(''), ['Tiramisu', 'Gnocchi']);
  assert.deepEqual(await shelf(`, p_from => '2026-08-01'`), ['Tiramisu']);
  assert.deepEqual(await shelf(`, p_from => '2026-02-03', p_to => '2026-02-03'`), ['Gnocchi'], 'inclusive single day');
  assert.deepEqual(await shelf(`, p_from => '2026-03-01', p_to => '2026-07-31'`), []);
  assert.deepEqual(await shelf(`, p_from => '2026-01-01', p_min_score => 4`), ['Tiramisu', 'Gnocchi'], 'composes with the range');
  for (const call of [`public.search_saved(p_from => '2026-01-01')`, `public.search_places(p_query => 'gn', p_from => '2026-01-01')`]) {
    assert.equal((await as(null, () => error(db.query(`select * from ${call}`))))?.code, '42501', call);
  }
});

test('0051: place_dishes ranks by the printed score, then orders, then name; unscored last; the keyset walks it', async () => {
  // Menu Hall: Pie 6 (x1) · Soup 5 (x1) · Bun 4.5 (x3) · Cake 4.5 (x1) · Dal unscored (x4) · Egg unscored (x1).
  const at = (d) => `2026-09-${String(d).padStart(2, '0')}T02:00:00Z`;
  await visit(10, A, R2, 'Bun 4.5, Dal was fine, Soup 5', lines(['Bun', 4.5], ['Dal', null], ['Soup', 5]), at(1));
  await visit(11, B, R2, 'Bun 4.5, Dal was fine, Cake 4.5', lines(['Bun', 4.5], ['Dal', null], ['Cake', 4.5]), at(2));
  await visit(12, A, R2, 'Bun 4.5, Dal was fine, Egg was fine', lines(['Bun', 4.5], ['Dal', null], ['Egg', null]), at(3));
  await visit(13, B, R2, 'Dal was fine, Pie 6', lines(['Dal', null], ['Pie', 6]), at(4));

  const want = ['Pie', 'Soup', 'Bun', 'Cake', 'Dal', 'Egg'];
  for (const who of [A, null]) {
    const menu = await as(who, () => rows(`select dish_name from public.place_dishes($1)`, [R2]));
    assert.deepEqual(menu.map((r) => r.dish_name), want, who ? 'signed in' : 'anon');
  }
  const walked = [];
  let last = null;
  for (let i = 0; i < 10; i++) {
    const page = await as(A, () => rows(
      `select dish_id, dish_name, score, review_count from public.place_dishes(p_restaurant_id => $1, p_limit => 2,
         p_cursor_review_count => $2, p_cursor_score => $3, p_cursor_dish_name => $4, p_cursor_dish_id => $5)`,
      [R2, last?.review_count ?? null, last?.score ?? null, last?.dish_name ?? null, last?.dish_id ?? null]));
    walked.push(...page.map((r) => r.dish_name));
    if (page.length < 2) break;
    last = page[page.length - 1];
  }
  assert.deepEqual(walked, want, 'pages of two, the same order, nothing twice');
});
