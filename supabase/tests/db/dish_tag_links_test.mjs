// supabase/tests/db/dish_tag_links_test.mjs — dish tags (0053) at the SQL level: what a dish is tagged
// with (keyword styles, the sorter's styles, cuisine / suburb / city from its place, live diet chips),
// how the tags follow their sources, and the three reads — dish_tags, similar_dishes, dishes_by_tag.
// What sort-entry sends as items[].styles is pinned in functions/sort-entry/styles_test.ts.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, asService, rows, error;

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
});
after(async () => db?.close());

const dishAt = async (entry, position) =>
  (await rows(`select dish_id from public.reviews where entry_id = $1 and entry_position = $2`, [entry, position]))[0].dish_id;
const tags = async (dish, uid = U.bob) =>
  (await as(uid, () => rows(`select kind, slug, label from public.dish_tags($1)`, [dish]))).map((t) => `${t.kind}:${t.slug}:${t.label}`);
const withStyles = (r, ...styles) => ({ ...r, items: r.items.map((it, i) => (styles[i] ? { ...it, styles: styles[i] } : it)) });

test('a new dish is tagged from its name and its place — style → cuisine → suburb → city', async () => {
  const E = await w.visit(1, U.alice, P.tipo, receipt(['Potato gnocchi', 4.5], ['Tiramisu', 4]), '2026-09-01T09:00:00Z');
  assert.deepEqual(await tags(await dishAt(E, 1)), [
    'style:pasta:pasta', 'style:potatoes:potatoes', 'cuisine:italian:Italian', 'city:melbourne:Melbourne',
  ], 'Melbourne CBD is the city itself: no separate suburb chip');

  const F = await w.visit(2, U.bob, P.marion, receipt(['Anchovy toast', 4]), '2026-09-02T09:00:00Z');
  assert.deepEqual(await tags(await dishAt(F, 1)), [
    'style:bread:bread', 'style:seafood:seafood', 'cuisine:wine-bar:Wine bar', 'suburb:fitzroy-melbourne:Fitzroy', 'city:melbourne:Melbourne',
  ], 'a suburb slug is qualified by its city: suburb names repeat across cities');

  // The hand-typed place (no address, no point) takes Fitzroy's city from its located namesake (0046).
  const G = await w.visit(3, U.cleo, P.hand, receipt(['Flat white', 4]), '2026-09-03T09:00:00Z');
  assert.deepEqual(await tags(await dishAt(G, 1)), ['style:coffee:coffee', 'suburb:fitzroy-melbourne:Fitzroy', 'city:melbourne:Melbourne'],
    'no cuisine on the place → no cuisine chip');

  // A dish a CLIENT inserts (the composer's "add a new dish") is tagged the same way.
  const [{ id: added }] = await as(U.dan, () => rows(
    `insert into public.dishes (name, restaurant_id, created_by_user_id) values ('Garlic bread', $1, $2) returning id`, [P.osteria, U.dan]));
  assert.deepEqual(await tags(added), ['style:bread:bread', 'cuisine:italian:Italian', 'suburb:carlton-melbourne:Carlton', 'city:melbourne:Melbourne']);
});

test('the sorter\'s styles replace the keyword guess, are cleaned, skip the cuisine, and cap at 3; a stub sort keeps them', async () => {
  const r = withStyles(receipt(['Cacio e pepe', 5]), [' Comfort  Food ', 'PASTA', 'vegan', 'Italian', '4.5', 'x']);
  const E = await w.visit(4, U.alice, P.osteria, r, '2026-09-04T09:00:00Z');
  const dish = await dishAt(E, 1);
  assert.deepEqual((await tags(dish)).filter((t) => t.startsWith('style')), ['style:comfort-food:comfort food', 'style:pasta:pasta'],
    'lower-cased and trimmed; a diet word, the cuisine, a number and a stub are dropped; the keyword guess is gone');
  const [{ plan }] = await rows(`select sort_plan plan from public.entries where id = $1`, [E]);
  assert.deepEqual(plan[0].styles, ['comfort food', 'pasta', 'italian'], 'the plan records what the sorter proposed (validated)');

  // A later sort of the same dish adds, never removes, up to three.
  await w.visit(5, U.bob, P.osteria, withStyles(receipt(['Cacio e pepe', 4]), ['cheese', 'peppery', 'noodles']), '2026-09-05T09:00:00Z');
  assert.deepEqual((await tags(dish)).filter((t) => t.startsWith('style')).map((t) => t.split(':')[1]), ['comfort-food', 'pasta', 'cheese']);

  // A stub sort (no styles) of the same entry changes nothing.
  await w.sortAs(E, P.osteria, receipt(['Cacio e pepe', 5]).items);
  assert.deepEqual((await tags(dish)).filter((t) => t.startsWith('style')).length, 3);
});

test('a parked plan\'s styles land when the place is attached (correct_entry_place)', async () => {
  const E = id(20);
  const r = withStyles(receipt(['Mystery bowl', 4]), ['rice', 'spicy']);
  await w.legacyPlaceless(E, U.alice, r.body, '2026-09-06T09:00:00Z');
  await w.sortAs(E, null, r.items);
  assert.equal((await rows(`select count(*)::int n from public.reviews where entry_id = $1`, [E]))[0].n, 0, 'parked, no lines');
  await as(U.alice, () => db.query(`select public.correct_entry_place($1, $2)`, [E, P.far]));
  assert.deepEqual(await tags(await dishAt(E, 1)), ['style:rice:rice', 'style:spicy:spicy', 'cuisine:thai:Thai', 'city:geelong:Geelong'],
    'Geelong is its own city, and "Geelong" the suburb is that city');
});

test('place tags follow the place: a cuisine change, a move, a new city alias', async () => {
  const dish = await dishAt(id(2), 1); // Anchovy toast @ Marion, Fitzroy
  await db.exec(`update public.restaurants set cuisine = 'Italian' where id = '${P.marion}'`);
  assert.ok((await tags(dish)).includes('cuisine:italian:Italian'));
  await db.exec(`update public.restaurants set cuisine = null where id = '${P.marion}'`);
  assert.ok(!(await tags(dish)).some((t) => t.startsWith('cuisine')), 'no cuisine → no chip');
  await db.exec(`update public.restaurants set address = '9 Smith St, Collingwood VIC 3066, Australia', city = 'Collingwood' where id = '${P.marion}'`);
  assert.ok((await tags(dish)).includes('suburb:collingwood-melbourne:Collingwood'));
  assert.ok(!(await tags(dish)).some((t) => t.includes('fitzroy')));
  // The hand place's city came from Marion (Fitzroy's only located place): Marion left, so it has none.
  const coffee = await dishAt(id(3), 1);
  assert.deepEqual(await tags(coffee), ['style:coffee:coffee', 'suburb:fitzroy:Fitzroy'], 'city-less: an unqualified suburb slug');
  await db.exec(`update public.cities set aliases = aliases || '{fitzroy}' where id = 'melbourne'`);
  assert.deepEqual(await tags(coffee), ['style:coffee:coffee', 'city:melbourne:Melbourne'], 'a cities change re-derives every dish');
  await db.exec(`update public.cities set aliases = array_remove(aliases, 'fitzroy') where id = 'melbourne'`);
  await db.exec(`update public.restaurants set address = '53 Gertrude St, Fitzroy VIC 3065, Australia', city = 'Fitzroy', cuisine = 'Wine bar' where id = '${P.marion}'`);
  assert.deepEqual(await tags(coffee), ['style:coffee:coffee', 'suburb:fitzroy-melbourne:Fitzroy', 'city:melbourne:Melbourne']);
});

test('diet chips in dish_tags are dish_summary.tags, live', async () => {
  const E = await w.visit(6, U.alice, P.tipo, receipt(['Burrata', 4, { tags: ['v', 'gf'] }]), '2026-09-07T09:00:00Z');
  const dish = await dishAt(E, 1);
  assert.deepEqual((await tags(dish)).filter((t) => t.startsWith('diet')), ['diet:gf:GF', 'diet:v:V']);
  await w.visit(7, U.bob, P.tipo, receipt(['Burrata', 5]), '2026-09-08T09:00:00Z');
  await w.visit(8, U.cleo, P.tipo, receipt(['Burrata', 3, { tags: ['v'] }]), '2026-09-09T09:00:00Z');
  const [{ tags: summary }] = await as(U.dan, () => rows(`select tags from public.dish_summary($1)`, [dish]));
  assert.deepEqual(summary, ['v']);
  assert.deepEqual((await tags(dish, U.dan)).filter((t) => t.startsWith('diet')), ['diet:v:V'], '1 of 3 is not a consensus');
  const byDiet = await as(U.dan, () => rows(`select name from public.dishes_by_tag('diet', 'v')`));
  assert.ok(byDiet.some((r) => r.name === 'Burrata'));
  assert.ok(!(await as(U.dan, () => rows(`select name from public.dishes_by_tag('diet', 'gf')`))).some((r) => r.name === 'Burrata'));
});

test('similar_dishes: a shared style outranks a shared cuisine outranks the suburb; the dish itself and unrelated food never appear', async () => {
  // Pasta at Tipo (Italian, CBD). Candidates: another pasta in Geelong (style only), a pasta at Osteria
  // (style + cuisine), a pizza at Osteria (cuisine), a coffee at a cuisine-less Fitzroy café (suburb + city only — not similar).
  const base = await dishAt(await w.visit(30, U.alice, P.tipo, receipt(['Rigatoni', 4]), '2026-09-10T09:00:00Z'), 1);
  await w.visit(31, U.bob, P.far, receipt(['Spaghetti', 3]), '2026-09-10T10:00:00Z');
  await w.visit(32, U.bob, P.osteria, receipt(['Linguine', 2], ['Margherita', 5]), '2026-09-10T11:00:00Z');
  await w.visit(33, U.bob, P.hand, receipt(['Espresso', 5]), '2026-09-10T12:00:00Z');
  await asService(() => db.query(`select public.find_or_create_dish($1, 'Pappardelle', $2)`, [P.osteria, U.bob])); // never logged

  const got = await as(U.dan, () => rows(`select name, restaurant_name, score::float, review_count from public.similar_dishes($1, 50)`, [base]));
  const names = got.map((r) => r.name);
  assert.ok(!names.includes('Rigatoni') && !names.includes('Espresso') && !names.includes('Pappardelle'), JSON.stringify(names));
  const at = (n) => names.indexOf(n);
  assert.ok(at('Linguine') < at('Spaghetti'), 'style + cuisine (12) before style alone (8)');
  assert.ok(at('Spaghetti') < at('Margherita'), 'style alone (8) before cuisine alone (4) — even at a lower score');
  assert.ok(names.includes('Potato gnocchi') && at('Potato gnocchi') < at('Linguine'), 'same restaurant pasta: style + cuisine + city (13)');
  assert.deepEqual((await as(U.dan, () => rows(`select * from public.similar_dishes($1, 2)`, [base]))).length, 2, 'p_limit');
});

test('dishes_by_tag: best first (a 6 above every 5, unscored last), one gap-free keyset walk', async () => {
  await w.visit(40, U.cleo, P.osteria, receipt(['Pici', 6]), '2026-09-11T09:00:00Z');
  await w.visit(41, U.dan, P.osteria, receipt(['Tagliatelle']), '2026-09-11T10:00:00Z');
  const all = await as(U.alice, () => rows(`select dish_id, name, score::float, review_count from public.dishes_by_tag('style', 'pasta', 100)`));
  assert.equal(all[0].name, 'Pici', 'the 6 leads');
  assert.equal(all.at(-1).name, 'Tagliatelle', 'unscored last');
  const scores = all.map((r) => r.score ?? -1);
  assert.deepEqual(scores, [...scores].sort((a, b) => b - a));
  const walked = await w.walk((last) => as(U.alice, () => rows(
    `select dish_id, name, score, review_count from public.dishes_by_tag('style', 'pasta', 2, $1, $2, $3, $4)`,
    [last?.score ?? null, last?.review_count ?? null, last?.name ?? null, last?.dish_id ?? null])));
  assert.deepEqual(walked.map((r) => r.dish_id), all.map((r) => r.dish_id));
  assert.ok((await as(U.alice, () => rows(`select * from public.dishes_by_tag('city', 'melbourne', 100)`))).length > all.length - 2);
  assert.deepEqual(await as(U.alice, () => rows(`select * from public.dishes_by_tag('style', 'no-such-tag')`)), []);
  assert.equal((await as(U.alice, () => error(db.query(`select * from public.dishes_by_tag('colour', 'red')`))))?.code, '22023');
});

test('numbers are the viewer\'s: a blocked author\'s lines count for nobody else', async () => {
  const pici = (uid) => as(uid, () => rows(`select score::float, review_count from public.dishes_by_tag('style', 'pasta', 100) where name = 'Pici'`));
  assert.deepEqual(await pici(U.alice), [{ score: 6, review_count: 1 }]);
  await as(U.alice, () => db.query(`select public.block_user($1)`, [U.cleo]));
  assert.deepEqual(await pici(U.alice), [], 'only cleo logged it: not a result for alice');
  assert.deepEqual(await pici(U.bob), [{ score: 6, review_count: 1 }]);
  await as(U.alice, () => db.query(`select public.unblock_user($1)`, [U.cleo]));
});

test('dish tags are read-only to clients, and the reads are signed-in only', async () => {
  const dish = await dishAt(id(1), 1);
  assert.equal((await as(U.alice, () => error(db.query(
    `insert into public.dish_tag_links (dish_id, kind, slug, label, source) values ($1, 'style', 'x-y', 'x y', 'sorter')`, [dish]))))?.code, '42501');
  assert.equal((await as(U.alice, () => error(db.query(`delete from public.dish_tag_links`))))?.code, '42501');
  assert.equal((await as(U.alice, () => error(db.query(`select public.dish_apply_sorter_styles($1, '{pizza}')`, [dish]))))?.code, '42501');
  for (const sql of [`select * from public.dish_tags('${dish}')`, `select * from public.similar_dishes('${dish}')`,
    `select * from public.dishes_by_tag('style', 'pasta')`]) {
    assert.equal((await as(null, () => error(db.query(sql))))?.code, '42501', sql);
  }
});

test('the backfill: dishes that existed before 0053 get the same tags a new one would', async () => {
  // Re-run the migration's backfill over everything and compare with what the triggers wrote.
  const before = await rows(`select dish_id, kind, slug, label, source from public.dish_tag_links order by 1, 2, 3`);
  await asService(() => db.query(`select public.dish_place_tags_refresh(array(select id from public.dishes))`));
  await asService(() => db.query(`select public.dish_style_keyword_refresh(array(select id from public.dishes))`));
  const again = await rows(`select dish_id, kind, slug, label, source from public.dish_tag_links order by 1, 2, 3`);
  assert.deepEqual(again, before, 'idempotent, and the sorter\'s styles survive it');
});
