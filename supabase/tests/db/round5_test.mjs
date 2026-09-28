// supabase/tests/db/round5_test.mjs — round 5 (0046–0048) at the SQL level: the city model and the
// city Feed, the score range + city filters on the Journal and Search, and the single-entry read a
// shared link opens.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { actors, boot } from './harness.mjs';

const A = '00000000-0000-4000-8000-00000000000a';
const B = '00000000-0000-4000-8000-00000000000b';
const C = '00000000-0000-4000-8000-00000000000c';
const P = {
  cbd: '00000000-0000-4000-8000-0000000000f1', //       located, Melbourne CBD
  fitzroy: '00000000-0000-4000-8000-0000000000f2', //   located, Fitzroy
  fitzroyHand: '00000000-0000-4000-8000-0000000000f3', // manual, no point, "Fitzroy" → Melbourne by locality
  cbdHand: '00000000-0000-4000-8000-0000000000f4', //   manual, no point, "CBD" → Melbourne by alias
  werribee: '00000000-0000-4000-8000-0000000000f5', //  located between Melbourne and Geelong → Melbourne
  lara: '00000000-0000-4000-8000-0000000000f6', //      located between them, nearer Geelong → Geelong
  sydney: '00000000-0000-4000-8000-0000000000f7', //    located, Surry Hills
  daylesford: '00000000-0000-4000-8000-0000000000f8', // manual, no point, no city
  nullIsland: '00000000-0000-4000-8000-0000000000f9', // Google row stored at 0,0 whose city says Melbourne
};
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const point = (lng, lat) => `extensions.ST_SetSRID(extensions.ST_MakePoint(${lng}, ${lat}), 4326)::geography`;

let db, as, asService, rows, error;

before(async () => {
  db = await boot();
  ({ as, asService, rows, error } = actors(db));
  await db.exec(`
    insert into auth.users (id, email) values ('${A}', 'alice@ate.test'), ('${B}', 'bob@ate.test'), ('${C}', 'cleo@ate.test');
    insert into public.restaurants (id, name, address, city, cuisine, source, location) values
      ('${P.cbd}',         'Tipo 00',     '361 Little Bourke St, Melbourne VIC 3000, Australia', 'Melbourne', 'Italian', 'manual', ${point(144.9631, -37.8136)}),
      ('${P.fitzroy}',     'Marion',      '53 Gertrude St, Fitzroy VIC 3065, Australia', 'Fitzroy', 'Wine bar', 'manual', ${point(144.9820, -37.8060)}),
      ('${P.fitzroyHand}', 'Hand Fitz',   null, 'fitzroy ', 'Cafe', 'manual', null),
      ('${P.cbdHand}',     'Hand CBD',    null, 'CBD', 'Vietnamese', 'manual', null),
      ('${P.werribee}',    'Werribee Pk', null, 'Werribee', 'Cafe', 'manual', ${point(144.6600, -37.9000)}),
      ('${P.lara}',        'Lara Pub',    null, 'Lara', 'Pub', 'manual', ${point(144.4100, -38.0200)}),
      ('${P.sydney}',      'Nomad',       '16 Foster St, Surry Hills NSW 2010, Australia', 'Surry Hills', 'Wine bar', 'manual', ${point(151.2100, -33.8800)}),
      ('${P.daylesford}',  'Lake House',  null, 'Daylesford', 'Modern', 'manual', null),
      ('${P.nullIsland}',  'Null Island', null, 'Melbourne', 'Cafe', 'manual', ${point(0, 0)});
  `);
});
after(async () => db?.close());

const sortAs = (entryId, place, items) =>
  asService(() => db.query(
    `select public.apply_entry_sort(p_entry_id => $1, p_restaurant_id => $2, p_items => $3::jsonb, p_mode => 'stub')`,
    [entryId, place, JSON.stringify(items)],
  ));

async function visit(n, author, place, body, items, when) {
  await as(author, () => db.query(
    `insert into public.entries (id, author_id, body, restaurant_id, created_at) values ($1, $2, $3, $4, $5)`,
    [id(n), author, body, place, when],
  ));
  await sortAs(id(n), place, items);
  return id(n);
}
const scored = (dish, s) => [{ dish_name: dish, score: s, score_evidence: `${dish} ${s}` }];

// ---------------------------------------------------------------------------------------------------
// 0046 — the city model
// ---------------------------------------------------------------------------------------------------
test('0046: place_cities maps by location, then name/alias, then sibling locality; unmapped places are absent', async () => {
  const got = await as(A, () => rows(`select restaurant_id, city, via from public.place_cities order by restaurant_id`));
  assert.deepEqual(got, [
    { restaurant_id: P.cbd, city: 'melbourne', via: 'location' },
    { restaurant_id: P.fitzroy, city: 'melbourne', via: 'location' },
    { restaurant_id: P.fitzroyHand, city: 'melbourne', via: 'locality' },
    { restaurant_id: P.cbdHand, city: 'melbourne', via: 'name' },
    { restaurant_id: P.werribee, city: 'melbourne', via: 'location' },
    { restaurant_id: P.lara, city: 'geelong', via: 'location' },
    { restaurant_id: P.sydney, city: 'sydney', via: 'location' },
    // P.daylesford: in no city
    { restaurant_id: P.nullIsland, city: 'melbourne', via: 'name' },
  ]);
  assert.equal((await as(null, () => error(db.query(`select * from public.place_cities`))))?.code, '42501', 'anon: no view grant');
  assert.equal((await as(null, () => error(db.query(`select * from public.cities`))))?.code, '42501', 'anon: no table grant');
  assert.equal((await as(A, () => error(db.query(`insert into public.cities (id, name, region, center, radius_m) values ('x', 'X', 'VIC', ${point(1, 1)}, 10000)`))))?.code, '42501', 'reference data');
});

test('0046: feed_cities, the city Feed, and resolve_city', async () => {
  // A: 3 in Melbourne (one by alias place, one by sibling locality), 1 Geelong. B: 2 Sydney, 1 Melbourne.
  // Daylesford (no city): 1 by A.
  await visit(10, A, P.cbd, 'Gnocchi 4', scored('Gnocchi', 4), '2026-09-01T09:00:00Z');
  await visit(11, A, P.fitzroyHand, 'Toast 3', scored('Toast', 3), '2026-09-02T09:00:00Z');
  await visit(12, A, P.cbdHand, 'Pho 5', scored('Pho', 5), '2026-09-03T09:00:00Z');
  await visit(13, A, P.lara, 'Parma 3.5', scored('Parma', 3.5), '2026-09-04T09:00:00Z');
  await visit(14, A, P.daylesford, 'Scones 4', scored('Scones', 4), '2026-09-05T09:00:00Z');
  await visit(20, B, P.sydney, 'Nduja 4.5', scored('Nduja', 4.5), '2026-09-06T09:00:00Z');
  await visit(21, B, P.sydney, 'Fries 2', scored('Fries', 2), '2026-09-07T09:00:00Z');
  await visit(22, B, P.fitzroy, 'Wine 4', scored('Wine', 4), '2026-09-08T09:00:00Z');

  const list = (who) => as(who, () => rows(`select city, name, region, radius_m, entry_count, round(lat::numeric, 4)::float lat, round(lng::numeric, 4)::float lng from public.feed_cities()`));
  assert.deepEqual(await list(null), [
    { city: 'melbourne', name: 'Melbourne', region: 'VIC', radius_m: 65000, entry_count: 4, lat: -37.8136, lng: 144.9631 },
    { city: 'sydney', name: 'Sydney', region: 'NSW', radius_m: 60000, entry_count: 2, lat: -33.8688, lng: 151.2093 },
    { city: 'geelong', name: 'Geelong', region: 'VIC', radius_m: 30000, entry_count: 1, lat: -38.1499, lng: 144.3617 },
  ], 'anon: every public entry, busiest first');
  assert.deepEqual((await list(C)).map((r) => [r.city, r.entry_count]), [['melbourne', 4], ['sydney', 2], ['geelong', 1]]);
  assert.deepEqual((await list(A)).map((r) => [r.city, r.entry_count]), [['sydney', 2], ['melbourne', 1]], 'your own entries are not in your Feed');

  // The Feed by city.
  const feed = (who, args) => as(who, () => rows(`select id from public.get_entry_feed(${args})`)).then((r) => r.map((x) => x.id));
  assert.deepEqual(await feed(C, `p_city => 'melbourne'`), [id(22), id(12), id(11), id(10)]);
  assert.deepEqual(await feed(C, `p_city => ' Sydney '`), [id(21), id(20)], 'trimmed, case-insensitive');
  assert.deepEqual(await feed(C, `p_city => 'atlantis'`), [], 'unknown city → nothing');
  assert.equal((await feed(C, `p_page_size => 50`)).length, 8, 'NULL = everywhere, Daylesford included');
  assert.deepEqual(await feed(C, `p_city => 'melbourne', p_area => 'Fitzroy'`), [id(22), id(11)], 'composes with p_area');
  assert.deepEqual(await feed(null, `p_city => 'melbourne'`), [id(22), id(12), id(11), id(10)], 'anon');
  assert.deepEqual(await feed(A, `p_city => 'melbourne'`), [id(22)], 'own excluded by default');
  const p1 = await as(C, () => rows(`select id, created_at from public.get_entry_feed(p_city => 'melbourne', p_page_size => 2)`));
  const p2 = await as(C, () => rows(`select id from public.get_entry_feed(p_city => 'melbourne', p_page_size => 2, p_cursor_created_at => $1, p_cursor_id => $2)`,
    [p1[1].created_at, p1[1].id]));
  assert.deepEqual([...p1, ...p2].map((r) => r.id), [id(22), id(12), id(11), id(10)], 'keyset paging within a city');
  // Old callers (five named params, or none) still bind.
  assert.equal((await as(C, () => rows(`select count(*)::int n from public.get_entry_feed(null, null, 50, false, null)`)))[0].n, 8);

  // resolve_city
  const near = (who, lat, lng) => as(who, () => rows(
    `select city, is_nearby, entry_count, distance_m is null as no_distance from public.resolve_city(p_lat => $1, p_lng => $2)`, [lat, lng]));
  assert.deepEqual(await near(C, -37.80, 144.98), [{ city: 'melbourne', is_nearby: true, entry_count: 4, no_distance: false }], 'in Melbourne');
  assert.deepEqual((await near(C, -38.02, 144.41)).map((r) => [r.city, r.is_nearby]), [['geelong', true]], 'Lara: Geelong has food');
  assert.deepEqual((await near(C, -37.90, 144.66)).map((r) => [r.city, r.is_nearby]), [['melbourne', true]], 'Werribee: both hold it, Melbourne is nearer');
  assert.deepEqual((await near(C, -27.47, 153.03)).map((r) => [r.city, r.is_nearby]), [['sydney', false]], 'Brisbane has no food → nearest city that does');
  assert.deepEqual((await near(C, -37.35, 144.14)).map((r) => [r.city, r.is_nearby]), [['melbourne', false]], 'Daylesford: in no city → nearest');
  assert.deepEqual(await near(C, null, null), [{ city: 'melbourne', is_nearby: false, entry_count: 4, no_distance: true }], 'no location → busiest');
  assert.deepEqual((await near(C, 200, 500)).map((r) => [r.city, r.is_nearby]), [['melbourne', false]], 'nonsense point → busiest');
  assert.deepEqual((await near(null, -33.87, 151.21)).map((r) => [r.city, r.is_nearby]), [['sydney', true]], 'anon');
  assert.deepEqual((await near(A, -37.80, 144.98)).map((r) => [r.city, r.entry_count]), [['melbourne', 1]], 'counts are what YOUR feed shows');
  // Nothing has food for a caller who sees no entries → no row.
  assert.deepEqual(await asService(() => rows(`select * from public.resolve_city(-37.8, 144.9)`)), []);

  // A block and a deactivation take their entries out of the counts, exactly as out of the Feed.
  await as(C, () => db.query(`select public.block_user($1)`, [B]));
  assert.deepEqual((await list(C)).map((r) => [r.city, r.entry_count]), [['melbourne', 3], ['geelong', 1]]);
  assert.deepEqual((await near(C, -33.87, 151.21)).map((r) => [r.city, r.is_nearby]), [['melbourne', false]], 'blocked Sydney is foodless for C');
  await as(C, () => db.query(`select public.unblock_user($1)`, [B]));
  await db.query(`update public.profiles set deleted_at = now() where id = $1`, [B]);
  assert.deepEqual((await list(null)).map((r) => [r.city, r.entry_count]), [['melbourne', 3], ['geelong', 1]], 'anon: deactivated gone');
  assert.deepEqual((await list(C)).map((r) => [r.city, r.entry_count]), [['melbourne', 3], ['geelong', 1]], 'signed in: deactivated gone');
  await db.query(`update public.profiles set deleted_at = null where id = $1`, [B]);
});

// ---------------------------------------------------------------------------------------------------
// 0047 — range + city filters
// ---------------------------------------------------------------------------------------------------
test('0047: score_in_range — no bound keeps all; any bound drops unscored; the top is open at 6 (0054)', async () => {
  const cases = [
    [null, null, null, true], [3, null, null, true],
    [null, 1, null, false], [null, null, 5, false],
    [3, 3, 4, true], [4.5, 3, 4, false], [2.5, 3, 4, false],
    // 0054: the track ends at 6 — a ceiling of 5 leaves a 6 (and a 5.3 average) out; 6 is open
    [6, 0.5, 5, false], [5.3, null, 5, false], [6, 0.5, 6, true], [5.3, null, 6, true],
    [6, null, 4.5, false], [5, null, 4.5, false],
    [6, 6, null, true], [5, 6, null, false], [4, 5, 3, false],
  ];
  for (const [s, lo, hi, want] of cases) {
    const got = (await as(A, () => rows(`select public.score_in_range($1, $2, $3) ok`, [s, lo, hi])))[0].ok;
    assert.equal(got, want, `${s} in [${lo}, ${hi}]`);
  }
});

test('0047: my_entries — score range (6 above 5), city, and the old place filter still works', async () => {
  // C's journal: 3 (Melbourne), 5 (Melbourne), 6 (Sydney), unscored (Geelong).
  await visit(30, C, P.cbd, 'Pasta 3', scored('Pasta', 3), '2026-09-10T09:00:00Z');
  await visit(31, C, P.fitzroy, 'Steak 5', scored('Steak', 5), '2026-09-11T09:00:00Z');
  const six = await visit(32, C, P.sydney, 'Tart 4', scored('Tart', 4), '2026-09-12T09:00:00Z');
  await as(C, () => db.query(`update public.reviews set score = 6 where entry_id = $1`, [six]));
  await visit(33, C, P.lara, 'Chips were fine', [{ dish_name: 'Chips' }], '2026-09-13T09:00:00Z');

  const mine = (args) => as(C, () => rows(`select id from public.my_entries(${args})`)).then((r) => r.map((x) => x.id));
  assert.deepEqual(await mine(``), [id(33), id(32), id(31), id(30)]);
  assert.deepEqual(await mine(`p_max_score => 4.5`), [id(30)], 'unscored drops, 5 and 6 above');
  assert.deepEqual(await mine(`p_min_score => 4, p_max_score => 5`), [id(31)], 'a top of 5 leaves the 6 out (0054)');
  assert.deepEqual(await mine(`p_min_score => 4, p_max_score => 6`), [id(32), id(31)], 'a top of 6 keeps it');
  assert.deepEqual(await mine(`p_min_score => 0.5, p_max_score => 6`), [id(32), id(31), id(30)], 'full slider = every scored entry');
  assert.deepEqual(await mine(`p_min_score => 6`), [id(32)], 'only 6s');
  assert.deepEqual(await mine(`p_min_score => 4.5, p_max_score => 3`), [], 'min > max → nothing');
  assert.deepEqual(await mine(`p_city => 'melbourne'`), [id(31), id(30)]);
  assert.deepEqual(await mine(`p_city => 'sydney', p_min_score => 5`), [id(32)]);
  assert.deepEqual(await mine(`p_city => 'nowhere'`), []);
  assert.deepEqual(await mine(`p_restaurant_id => '${P.fitzroy}'`), [id(31)], '0043 place filter');
  assert.deepEqual(await mine(`p_sort => 'top', p_max_score => 6`), [id(32), id(31), id(30)], 'top sort with the range');
  assert.deepEqual(await mine(`p_sort => 'top', p_max_score => 5`), [id(31), id(30)], 'a ceiling of 5 leaves the 6 out (0054)');
  // A 0043-shaped call (eleven named params) still binds.
  assert.equal((await as(C, () => rows(`select count(*)::int n from public.my_entries(p_sort => 'newest', p_restaurant_id => null, p_min_score => null,
    p_tag => null, p_from => null, p_to => null, p_limit => 30, p_cursor_created_at => null, p_cursor_id => null, p_cursor_best_score => null, p_tz => 'UTC')`)))[0].n, 4);

  assert.deepEqual(await as(C, () => rows(`select city, name, region, entry_count from public.my_entry_cities()`)), [
    { city: 'melbourne', name: 'Melbourne', region: 'VIC', entry_count: 2 },
    { city: 'geelong', name: 'Geelong', region: 'VIC', entry_count: 1 },
    { city: 'sydney', name: 'Sydney', region: 'NSW', entry_count: 1 },
  ]);
  for (const call of [`public.my_entries(p_city => 'melbourne')`, `public.my_entry_cities()`, `public.search_cities()`]) {
    assert.equal((await as(null, () => error(db.query(`select * from ${call}`))))?.code, '42501', call);
  }
});

test('0047: Search — p_city and the score range on places, dishes and nearby; search_cities', async () => {
  const names = (sql) => as(C, () => rows(sql)).then((r) => r.map((x) => x.name));
  // Place averages as C sees them: Tipo 00 (4, 3) = 3.5, Marion (4, 5) = 4.5, Nomad (4.5, 2, 6) = 4.2, Lara 3.5.
  assert.deepEqual(await names(`select name from public.search_places(p_query => 'a', p_limit => 50)`), [], 'the 2-char rule stands');
  const all = await names(`select name from public.search_places(p_query => 'ma', p_limit => 50)`);
  assert.ok(all.includes('Marion') && all.includes('Nomad'), `${all}`);
  assert.deepEqual(await names(`select name from public.search_places(p_query => 'ma', p_limit => 50, p_city => 'sydney')`), ['Nomad']);
  assert.deepEqual(await names(`select name from public.search_places(p_query => 'ma', p_limit => 50, p_city => 'melbourne')`), ['Marion']);
  assert.deepEqual(await names(`select name from public.search_places(p_query => 'ma', p_limit => 50, p_max_score => 4.4)`), ['Nomad']);
  assert.deepEqual(await names(`select name from public.search_places(p_query => 'ma', p_limit => 50, p_min_score => 4.3, p_max_score => 5)`), ['Marion']);

  const dishes = (q, args) => as(C, () => rows(`select dish_name from public.search_dishes(p_query => '${q}', p_limit => 50${args})`)).then((r) => r.map((x) => x.dish_name));
  assert.deepEqual(await dishes('ta', ''), ['Tart', 'Pasta']);
  assert.deepEqual(await dishes('ta', `, p_city => 'melbourne'`), ['Pasta']);
  assert.deepEqual(await dishes('ta', `, p_min_score => 5, p_max_score => 5`), [], 'a 6 is outside [5, 5] (0054)');
  assert.deepEqual(await dishes('ta', `, p_min_score => 5, p_max_score => 6`), ['Tart'], 'and inside [5, 6]');
  assert.deepEqual(await dishes('ta', `, p_max_score => 4.5`), ['Pasta']);
  assert.deepEqual(await dishes('st', `, p_min_score => 5, p_max_score => 5`), ['Steak'], 'and so is a 5');

  const near = (args) => as(C, () => rows(`select name from public.nearby_places(p_lat => -37.8136, p_lng => 144.9631, p_radius_m => 50000${args})`)).then((r) => r.map((x) => x.name));
  assert.deepEqual(await near(''), ['Tipo 00', 'Marion', 'Werribee Pk'], 'Lara is 54 km out, past the 50 km clamp');
  assert.deepEqual(await near(`, p_city => 'geelong'`), []);
  assert.deepEqual(await near(`, p_city => 'melbourne', p_max_score => 3.5`), ['Tipo 00']);
  assert.deepEqual(await near(`, p_city => 'melbourne', p_min_score => 4`), ['Marion']);
  // A 0042-shaped call still binds.
  assert.equal((await as(C, () => rows(`select count(*)::int n from public.nearby_places(p_lat => -37.8136, p_lng => 144.9631, p_radius_m => 50000,
    p_cuisines => null, p_tags => null, p_min_score => null)`)))[0].n, 3);

  assert.deepEqual(await as(C, () => rows(`select city, place_count from public.search_cities()`)), [
    { city: 'melbourne', place_count: 6 }, { city: 'geelong', place_count: 1 }, { city: 'sydney', place_count: 1 },
  ]);
});

// ---------------------------------------------------------------------------------------------------
// 0048 — the single-entry read a shared link opens
// ---------------------------------------------------------------------------------------------------
test('0048: get_entry_card — anon reads a public entry; RLS decides for the signed in; blocked/deactivated/unknown → []', async () => {
  const E = id(20); // B's Sydney entry
  const dish = (await rows(`select dish_id from public.reviews where entry_id = $1`, [E]))[0].dish_id;
  await as(C, () => db.query(`select public.save_dish($1, $2)`, [dish, E]));

  const card = (who, entry = E) => as(who, () => rows(`select id, is_mine, items->0->>'saved' saved, place->>'locality' loc from public.get_entry_card($1)`, [entry]));
  assert.deepEqual(await card(null), [{ id: E, is_mine: false, saved: 'false', loc: 'Surry Hills' }], 'anon');
  assert.deepEqual(await card(C), [{ id: E, is_mine: false, saved: 'true', loc: 'Surry Hills' }], 'signed in: the viewer\'s own save state');
  assert.deepEqual((await card(B)).map((r) => r.is_mine), [true], 'the author');
  // The same row as the direct view read.
  const direct = await as(C, () => rows(`select * from public.entry_cards where id = $1`, [E]));
  const viaRpc = await as(C, () => rows(`select * from public.get_entry_card($1)`, [E]));
  assert.deepEqual(viaRpc, direct);
  assert.deepEqual(await card(null, id(999)), [], 'unknown id');
  assert.equal((await as(null, () => error(db.query(`select * from public.entry_cards where id = $1`, [E]))))?.code, '42501', 'anon still has no view grant');

  // A block, either direction, hides it from the two people and nobody else.
  await as(C, () => db.query(`select public.block_user($1)`, [B]));
  assert.deepEqual(await card(C), [], 'blocker');
  assert.deepEqual((await card(B)).length, 1, 'the author always sees their own');
  assert.deepEqual((await as(B, () => rows(`select id from public.get_entry_card($1)`, [id(30)]))), [], 'blocked: the blocker\'s entry');
  assert.equal((await card(A)).length, 1, 'bystander');
  await as(C, () => db.query(`select public.unblock_user($1)`, [B]));

  // A deactivated author vanishes for everyone but themselves.
  await db.query(`update public.profiles set deleted_at = now() where id = $1`, [B]);
  assert.deepEqual(await card(null), [], 'anon');
  assert.deepEqual(await card(C), [], 'signed in');
  assert.equal((await card(B)).length, 1, 'owner');
  await db.query(`update public.profiles set deleted_at = null where id = $1`, [B]);

  // anon reaches the twin only through the public read.
  assert.equal((await as(null, () => error(db.query(`select * from browse.get_entry_card($1)`, [E]))))?.code ?? 'ok', 'ok',
    'the twin is callable by anon inside browse (the schema is not exposed by PostgREST)');
});

// ---------------------------------------------------------------------------------------------------
// 0049 — the Saved shelf's filters
// ---------------------------------------------------------------------------------------------------
test('0049: search_saved — dish_score range (open top), city, old calls bind; my_saved_cities', async () => {
  const dishOf = async (name) => (await rows(`select id from public.dishes where name = $1`, [name]))[0].id;
  // C already saved Nduja (Sydney, 4.5) in the 0048 test; add Pasta (Melbourne, 3), Tart (Sydney, 6),
  // Chips (Geelong, unscored).
  for (const [dish, entry] of [['Pasta', id(30)], ['Tart', id(32)], ['Chips', id(33)]]) {
    const dishId = await dishOf(dish);
    await as(C, () => db.query(`select public.save_dish($1, $2)`, [dishId, entry]));
  }
  const shelf = (args) => as(C, () => rows(`select dish_name from public.search_saved(${args})`))
    .then((r) => r.map((x) => x.dish_name).sort());
  assert.deepEqual(await shelf(`p_limit => 50`), ['Chips', 'Nduja', 'Pasta', 'Tart']);
  assert.deepEqual(await shelf(`p_query => null, p_limit => 50, p_max_score => 4.5`), ['Nduja', 'Pasta'], 'unscored drops, the 6 is above 4.5');
  assert.deepEqual(await shelf(`p_limit => 50, p_min_score => 4.5, p_max_score => 5`), ['Nduja'], 'a top of 5 leaves the 6 out (0054)');
  assert.deepEqual(await shelf(`p_limit => 50, p_min_score => 4.5, p_max_score => 6`), ['Nduja', 'Tart'], 'a top of 6 keeps it');
  assert.deepEqual(await shelf(`p_limit => 50, p_min_score => 6`), ['Tart']);
  assert.deepEqual(await shelf(`p_limit => 50, p_city => 'sydney'`), ['Nduja', 'Tart']);
  assert.deepEqual(await shelf(`p_limit => 50, p_city => 'geelong'`), ['Chips']);
  assert.deepEqual(await shelf(`p_limit => 50, p_city => 'atlantis'`), []);
  assert.deepEqual(await shelf(`p_query => 'ta', p_limit => 50, p_city => 'melbourne'`), ['Pasta'], 'composes with the query');
  // Paged with a filter: pages of one walk the filtered set in shelf order.
  const whole = await as(C, () => rows(`select dish_id, saved_at from public.search_saved(p_limit => 50, p_city => 'sydney')`));
  const p1 = await as(C, () => rows(`select dish_id, saved_at from public.search_saved(p_limit => 1, p_city => 'sydney')`));
  const p2 = await as(C, () => rows(`select dish_id from public.search_saved(p_limit => 1, p_city => 'sydney', p_cursor_saved_at => $1, p_cursor_dish_id => $2)`,
    [p1[0].saved_at, p1[0].dish_id]));
  assert.deepEqual([...p1, ...p2].map((r) => r.dish_id), whole.map((r) => r.dish_id));
  // A 0031-shaped call binds, and the unfiltered shelf is my_saved_dishes' rows in its order.
  const old = await as(C, () => rows(`select dish_id from public.search_saved(p_query => '', p_limit => 50, p_cursor_saved_at => null, p_cursor_dish_id => null)`));
  const view = await as(C, () => rows(`select dish_id from public.my_saved_dishes order by saved_at desc, dish_id desc`));
  assert.deepEqual(old, view);

  assert.deepEqual(await as(C, () => rows(`select city, name, region, dish_count from public.my_saved_cities()`)), [
    { city: 'sydney', name: 'Sydney', region: 'NSW', dish_count: 2 },
    { city: 'geelong', name: 'Geelong', region: 'VIC', dish_count: 1 },
    { city: 'melbourne', name: 'Melbourne', region: 'VIC', dish_count: 1 },
  ]);
  for (const call of [`public.search_saved(p_city => 'sydney')`, `public.my_saved_cities()`]) {
    assert.equal((await as(null, () => error(db.query(`select * from ${call}`))))?.code, '42501', call);
  }
});
