// supabase/tests/db/lists_test.mjs — custom lists + Journal search (0060): owner-only access, caps,
// reorder integrity, items following / leaving with their dish line, the picker, search_my_entries
// (accents, other people's entries never returned), and account deletion.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, rows, error;
after(async () => db?.close());

const code = async (uid, sql, params) => (await as(uid, () => error(db.query(sql, params))))?.code ?? null;
const one = async (uid, sql, params) => (await as(uid, () => rows(sql, params)))[0];
const create = (uid, name) => one(uid, `select * from public.create_list($1)`, [name]);
const add = (uid, list, entry, dish) => one(uid, `select * from public.add_list_item($1, $2, $3)`, [list, entry, dish]);
const getList = async (uid, list) => (await one(uid, `select public.get_list($1) l`, [list])).l;
const dishOf = async (entry, name) =>
  (await rows(`select r.dish_id, r.id review_id from public.reviews r join public.dishes d on d.id = r.dish_id
               where r.entry_id = $1 and d.name = $2`, [entry, name]))[0];
const names = (l) => l.items.map((i) => i.dish_name);

// Alice: two visits; Bob: one. Built once, tests add their own where they mutate.
let A1, A2, B1;
before(async () => {
  w = await world();
  ({ db, as, rows, error } = w);
  A1 = await w.visit(1, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu', 5], ['Bread']), '2026-09-01T09:00:00Z',
    { photos: ['a/1.jpg'] });
  A2 = await w.visit(2, U.alice, P.osteria, receipt(['Tagliatelle al ragù', 4], ['Burger', 3.5]), '2026-09-02T09:00:00Z');
  B1 = await w.visit(3, U.bob, P.tipo, receipt(['Gnocchi', 2]), '2026-09-03T09:00:00Z');
});

// ---------------------------------------------------------------------------------------------------
test('lists: owner-only — reads, writes, raw table access, anon', async () => {
  const L = await create(U.alice, '  Melbourne\'s best burgers, judged by me ');
  assert.equal(L.name, 'Melbourne\'s best burgers, judged by me', 'trimmed');
  assert.equal(L.visibility, 'private');
  assert.equal(L.item_count, 0);
  const g = await dishOf(A1, 'Gnocchi');
  await add(U.alice, L.list_id, A1, g.dish_id);

  assert.equal((await as(U.alice, () => rows(`select id from public.user_lists where id = $1`, [L.list_id]))).length, 1);
  assert.equal((await as(U.bob, () => rows(`select id from public.user_lists where id = $1`, [L.list_id]))).length, 0);
  assert.equal((await as(U.bob, () => rows(`select id from public.user_list_items where list_id = $1`, [L.list_id]))).length, 0);
  assert.equal(await code(U.bob, `select public.get_list($1)`, [L.list_id]), 'P0002');
  assert.equal(await code(U.bob, `select * from public.rename_list($1, 'mine now')`, [L.list_id]), 'P0002');
  assert.equal(await code(U.bob, `select * from public.add_list_item($1, $2, $3)`, [L.list_id, B1, g.dish_id]), 'P0002');
  assert.equal(await code(U.bob, `select public.reorder_list($1, '{}')`, [L.list_id]), 'P0002');
  assert.equal((await one(U.bob, `select public.delete_list($1) n`, [L.list_id])).n, 0, 'not yours: nothing deleted');
  const item = (await getList(U.alice, L.list_id)).items[0].item_id;
  assert.equal((await one(U.bob, `select public.remove_list_item($1) n`, [item])).n, 0);
  assert.equal((await as(U.bob, () => rows(`select * from public.my_lists()`))).length, 0);
  assert.equal((await as(U.bob, () => rows(`select * from public.my_lists_for_dish_line($1, $2)`, [A1, g.dish_id]))).length, 0);

  for (const write of [
    `insert into public.user_lists (owner_id, name) values ('${U.alice}', 'raw')`,
    `update public.user_lists set name = 'raw'`,
    `delete from public.user_lists`,
    `insert into public.user_list_items (list_id, owner_id, entry_id, dish_id, position) values ('${L.list_id}', '${U.alice}', '${A1}', '${g.dish_id}', 9)`,
    `update public.user_list_items set position = 5`,
    `delete from public.user_list_items`,
  ]) assert.equal(await code(U.alice, write), '42501', `no client write: ${write.slice(0, 40)}`);

  for (const sql of [`select * from public.my_lists()`, `select * from public.create_list('x')`,
    `select * from public.search_my_entries('gnocchi')`, `select * from public.my_scored_dishes()`]) {
    assert.equal(await code(null, sql), '42501', `anon: ${sql}`);
  }
  assert.equal(await code(U.alice, `select * from public.create_list('   ')`), '22023');
  assert.equal(await code(U.alice, `select * from public.create_list($1)`, ['x'.repeat(81)]), '22023');
  const R = await one(U.alice, `select * from public.rename_list($1, ' Burgers ')`, [L.list_id]);
  assert.equal(R.name, 'Burgers');
  assert.equal(R.item_count, 1);
  assert.ok(new Date(R.updated_at) >= new Date(L.updated_at));
  assert.equal((await one(U.alice, `select public.delete_list($1) n`, [L.list_id])).n, 1);
  assert.equal((await rows(`select count(*)::int n from public.user_list_items where list_id = $1`, [L.list_id]))[0].n, 0, 'items go with it');
});

test('add: only your own dish lines; idempotent; legacy-free grain is (entry, dish)', async () => {
  const L = await create(U.alice, 'Picks');
  const g = await dishOf(A1, 'Gnocchi');
  const bobs = await dishOf(B1, 'Gnocchi');
  assert.equal(bobs.dish_id, g.dish_id, 'same catalogue dish');
  assert.equal(await code(U.alice, `select * from public.add_list_item($1, $2, $3)`, [L.list_id, B1, g.dish_id]), 'P0002', 'bob\'s visit');
  const burger = await dishOf(A2, 'Burger');
  assert.equal(await code(U.alice, `select * from public.add_list_item($1, $2, $3)`, [L.list_id, A1, burger.dish_id]), 'P0002', 'not on that visit');
  const first = await add(U.alice, L.list_id, A1, g.dish_id);
  const again = await add(U.alice, L.list_id, A1, g.dish_id);
  assert.equal(again.item_id, first.item_id, 'idempotent');
  assert.equal(first.item_position, 1);
  assert.equal((await add(U.alice, L.list_id, A2, burger.dish_id)).item_position, 2);
  assert.equal((await getList(U.alice, L.list_id)).item_count, 2);
});

test('caps: 50 lists per user, 100 items per list (54000)', async () => {
  const have = (await rows(`select count(*)::int n from public.user_lists where owner_id = $1`, [U.cleo]))[0].n;
  for (let i = have; i < 50; i++) await create(U.cleo, `List ${i}`);
  assert.equal(await code(U.cleo, `select * from public.create_list('one too many')`), '54000');

  const L = await create(U.alice, 'Hundred');
  // 100 items straight in as superuser (local PGlite only), each a distinct dish on one of alice's visits.
  await db.query(`
    insert into public.dishes (id, restaurant_id, name, created_by_user_id)
    select gen_random_uuid(), $1, 'Filler ' || g, $2 from generate_series(1, 100) g`, [P.tipo, U.alice]);
  await db.query(`
    insert into public.user_list_items (list_id, owner_id, entry_id, dish_id, position)
    select $1, $2, $3, d.id, row_number() over (order by d.name) from public.dishes d where d.name like 'Filler %'`,
  [L.list_id, U.alice, A1]);
  const t = await dishOf(A1, 'Tiramisu');
  assert.equal(await code(U.alice, `select * from public.add_list_item($1, $2, $3)`, [L.list_id, A1, t.dish_id]), '54000');
});

test('reorder: the full id array, exactly; positions stay dense 1…n through removals', async () => {
  const L = await create(U.alice, 'Order');
  const ids = [];
  for (const [e, n] of [[A1, 'Gnocchi'], [A1, 'Tiramisu'], [A1, 'Bread'], [A2, 'Burger']]) {
    ids.push((await add(U.alice, L.list_id, e, (await dishOf(e, n)).dish_id)).item_id);
  }
  const rev = [...ids].reverse();
  assert.equal((await one(U.alice, `select public.reorder_list($1, $2::uuid[]) n`, [L.list_id, rev])).n, 4);
  let l = await getList(U.alice, L.list_id);
  assert.deepEqual(names(l), ['Burger', 'Bread', 'Tiramisu', 'Gnocchi']);
  assert.deepEqual(l.items.map((i) => i.position), [1, 2, 3, 4]);

  const bad = [
    ids.slice(0, 3),                       // one missing
    [...ids, ids[0]],                      // a duplicate
    [ids[0], ids[1], ids[2], ids[2]],      // right length, duplicated
    [ids[0], ids[1], ids[2], id(7777)],    // a stranger
  ];
  for (const arr of bad) {
    assert.equal(await code(U.alice, `select public.reorder_list($1, $2::uuid[])`, [L.list_id, arr]), '22023', JSON.stringify(arr));
  }
  assert.equal(await code(U.alice, `select public.reorder_list($1, null)`, [L.list_id]), '22023');
  l = await getList(U.alice, L.list_id);
  assert.deepEqual(names(l), ['Burger', 'Bread', 'Tiramisu', 'Gnocchi'], 'a refused reorder changes nothing');

  assert.equal((await one(U.alice, `select public.remove_list_item($1) n`, [ids[2]])).n, 1); // Bread
  l = await getList(U.alice, L.list_id);
  assert.deepEqual(names(l), ['Burger', 'Tiramisu', 'Gnocchi']);
  assert.deepEqual(l.items.map((i) => i.position), [1, 2, 3]);
  assert.equal((await one(U.alice, `select public.remove_list_item($1) n`, [ids[2]])).n, 0, 'already gone');
});

test('items follow their line: survive a re-sort, follow a correction, leave with the line or the entry', async () => {
  const E = await w.visit(10, U.alice, P.tipo, receipt(['Pizza', 4], ['Salad', 3], ['Soup', 2]), '2026-09-05T09:00:00Z');
  const L = await create(U.alice, 'Follow');
  const pizza = await dishOf(E, 'Pizza');
  for (const n of ['Pizza', 'Salad', 'Soup']) await add(U.alice, L.list_id, E, (await dishOf(E, n)).dish_id);

  // a re-sort deletes and re-inserts every uncorrected line in ONE transaction: items whose dish survives stay
  await w.sortAs(E, P.tipo, receipt(['Pizza', 4], ['Salad', 3], ['Soup', 2]).items);
  assert.notEqual((await dishOf(E, 'Pizza')).review_id, pizza.review_id, 'the review id did change');
  assert.deepEqual(names(await getList(U.alice, L.list_id)), ['Pizza', 'Salad', 'Soup']);
  assert.equal((await getList(U.alice, L.list_id)).items[0].score, 4, 'reads the live line');

  // a re-sort that no longer prints Salad drops that item, and ranks close up
  await w.sortAs(E, P.tipo, receipt(['Pizza', 4], ['Soup', 2]).items);
  let l = await getList(U.alice, L.list_id);
  assert.deepEqual(names(l), ['Pizza', 'Soup']);
  assert.deepEqual(l.items.map((i) => i.position), [1, 2]);

  // the author fixes a line's dish: the item follows it
  const soup = await dishOf(E, 'Soup');
  await as(U.alice, () => db.query(`select public.correct_entry_dish(p_review_id => $1, p_dish_name => 'Minestrone')`, [soup.review_id]));
  assert.deepEqual(names(await getList(U.alice, L.list_id)), ['Pizza', 'Minestrone']);

  // the author deletes the line: the item goes (at commit)
  const p = await dishOf(E, 'Pizza');
  await as(U.alice, () => db.query(`delete from public.reviews where id = $1`, [p.review_id]));
  l = await getList(U.alice, L.list_id);
  assert.deepEqual(names(l), ['Minestrone']);
  assert.equal(l.items[0].position, 1);

  // the entry is deleted: everything from it goes
  await as(U.alice, () => db.query(`select public.delete_entry($1)`, [E]));
  assert.deepEqual((await getList(U.alice, L.list_id)).items, []);
});

test('reads: get_list joins, my_lists counts + covers + keyset, my_lists_for_dish_line', async () => {
  const L = await create(U.dan, 'Dan\'s list');
  const D1 = await w.visit(20, U.dan, P.osteria, receipt(['Tagliatelle al ragù', 5], ['Panna cotta']), '2026-09-06T09:00:00Z',
    { photos: ['d/1.jpg', 'd/2.jpg'] });
  const rag = await dishOf(D1, 'Tagliatelle al ragù');
  await add(U.dan, L.list_id, D1, rag.dish_id);
  await add(U.dan, L.list_id, D1, (await dishOf(D1, 'Panna cotta')).dish_id);
  const l = await getList(U.dan, L.list_id);
  const [i0, i1] = l.items;
  assert.equal(i0.entry_id, D1);
  assert.equal(i0.dish_name, 'Tagliatelle al ragù');
  assert.equal(i0.restaurant_name, 'Osteria Ilaria');
  assert.equal(i0.locality, 'Carlton');
  assert.equal(i0.score, 5);
  assert.equal(i1.score, null, 'unscored stays null');
  assert.match(i0.photo_url, /d\/1\.jpg$/, 'the visit\'s first photo');
  assert.equal(new Date(i0.visited_at).toISOString(), '2026-09-06T09:00:00.000Z');

  const second = await create(U.dan, 'Empty');
  const mine = await as(U.dan, () => rows(`select * from public.my_lists()`));
  assert.deepEqual(mine.map((m) => m.list_id), [second.list_id, L.list_id], 'newest first');
  assert.equal(mine[1].item_count, 2);
  assert.equal(mine[1].covers.length, 1, 'distinct covers only (both items show the visit photo)');
  assert.deepEqual(mine[0].covers, []);
  const paged = await w.walk((last) => as(U.dan, () => rows(
    `select * from public.my_lists(p_limit => 1, p_cursor_created_at => $1, p_cursor_id => $2)`,
    [last?.created_at ?? null, last?.list_id ?? null])));
  assert.deepEqual(paged.map((m) => m.list_id), mine.map((m) => m.list_id));
  assert.equal(await code(U.dan, `select * from public.my_lists(p_cursor_id => $1)`, [L.list_id]), '22023');

  const sheet = await as(U.dan, () => rows(`select * from public.my_lists_for_dish_line($1, $2)`, [D1, rag.dish_id]));
  assert.deepEqual(sheet.map((s) => [s.name, s.item_id !== null]), [['Empty', false], ['Dan\'s list', true]]);
  assert.equal(sheet[1].item_id, i0.item_id);
});

test('picker: my_scored_dishes — mine only, scored by default, dish or place name, accents, keyset, in_list', async () => {
  const L = await create(U.alice, 'Picker');
  const all = await w.walk((last) => as(U.alice, () => rows(
    `select * from public.my_scored_dishes(p_limit => 2, p_cursor_visited_at => $1, p_cursor_entry_id => $2, p_cursor_dish_id => $3)`,
    [last?.visited_at ?? null, last?.entry_id ?? null, last?.dish_id ?? null])));
  const unpaged = await as(U.alice, () => rows(`select * from public.my_scored_dishes(p_limit => 100)`));
  assert.deepEqual(all.map((r) => r.entry_id + r.dish_id), unpaged.map((r) => r.entry_id + r.dish_id), 'walk = one page');
  assert.ok(unpaged.every((r) => r.score !== null), 'scored only by default');
  const authors = await rows(`select distinct author_id from public.entries where id = any($1::uuid[])`, [unpaged.map((r) => r.entry_id)]);
  assert.deepEqual(authors.map((a) => a.author_id), [U.alice], 'alice\'s own lines only');
  assert.ok(!unpaged.some((r) => r.dish_name === 'Bread'));
  const withUnscored = await as(U.alice, () => rows(`select * from public.my_scored_dishes(p_scored_only => false, p_limit => 100)`));
  assert.ok(withUnscored.some((r) => r.dish_name === 'Bread'));

  const q = async (s) => (await as(U.alice, () => rows(`select dish_name from public.my_scored_dishes(p_query => $1)`, [s]))).map((r) => r.dish_name);
  assert.deepEqual(await q('RAGU'), ['Tagliatelle al ragù'], 'case- and accent-insensitive');
  assert.deepEqual((await q('osteria')).sort(), ['Burger', 'Tagliatelle al ragù'], 'place name');
  assert.deepEqual(await q('gnoc'), ['Gnocchi'], 'prefix; bob\'s gnocchi absent');

  const burger = await dishOf(A2, 'Burger');
  await add(U.alice, L.list_id, A2, burger.dish_id);
  const marked = await as(U.alice, () => rows(`select dish_name, in_list from public.my_scored_dishes(p_query => 'burg', p_list_id => $1)`, [L.list_id]));
  assert.deepEqual(marked, [{ dish_name: 'Burger', in_list: true }]);
  assert.equal(await code(U.alice, `select * from public.my_scored_dishes(p_cursor_entry_id => $1)`, [A1]), '22023');
});

test('search_my_entries: words, dish and place names; accents; never another person\'s entry; keyset', async () => {
  await w.visit(30, U.alice, P.marion, { body: 'Crème brûlée at the bar, 100% worth it', items: [] }, '2026-09-07T09:00:00Z');
  await w.visit(31, U.bob, P.osteria, receipt(['Tagliatelle al ragù', 5]), '2026-09-08T09:00:00Z');
  await w.visit(32, U.bob, P.marion, { body: 'creme brulee for me too', items: [] }, '2026-09-08T10:00:00Z');
  const s = async (query, uid = U.alice) =>
    (await as(uid, () => rows(`select id from public.search_my_entries($1)`, [query]))).map((r) => r.id);

  assert.deepEqual(await s('creme brulee'), [id(30)], 'accent-folded words; bob\'s matching entry absent');
  assert.deepEqual(await s('BRÛLÉE'), [id(30)], 'case-insensitive, accents either side');
  assert.deepEqual(await s('ragu'), [A2], 'a dish name (the body says ragù)');
  assert.deepEqual(await s('tiram'), [A1], 'prefix of a dish name');
  assert.deepEqual(await s('ilaria'), [A2], 'the place name');
  assert.deepEqual(await s('100%'), [id(30)], '% is literal');
  assert.deepEqual(await s('1%0'), [], '…not a wildcard');
  assert.deepEqual(await s('g'), [], 'under 2 characters → []');
  assert.deepEqual(await s('ragu', U.bob), [id(31)], 'bob sees only his own');

  const tipo = await s('tipo');
  assert.ok(tipo.includes(A1) && !tipo.includes(B1), 'Tipo 00 — alice\'s visit, never bob\'s');
  const [card] = await as(U.alice, () => rows(`select * from public.search_my_entries('gnocchi')`));
  assert.equal(card.is_mine, true);
  assert.equal(card.items.length, 3, 'the full entry_cards row');

  // keyset in the Journal's order
  const every = await s('o');
  assert.deepEqual(every, []);
  const big = await as(U.alice, () => rows(`select id, created_at from public.search_my_entries('a', 50)`));
  assert.deepEqual(big, [], 'one char is still under 2');
  const allA = await as(U.alice, () => rows(`select id from public.search_my_entries('at', 50)`));
  const walked = await w.walk((last) => as(U.alice, () => rows(
    `select id, created_at from public.search_my_entries('at', 1, $1, $2)`, [last?.created_at ?? null, last?.id ?? null])));
  assert.ok(allA.length >= 2, 'several hits');
  assert.deepEqual(walked.map((r) => r.id), allA.map((r) => r.id));
  assert.equal(await code(U.alice, `select * from public.search_my_entries('at', 20, null, $1)`, [A1]), '22023');
});

test('delete_account: lists and items leave nothing behind', async () => {
  const X = id(990);
  await db.query(`insert into auth.users (id, email) values ($1, 'lists@ate.test')`, [X]);
  const E = await w.visit(40, X, P.tipo, receipt(['Gnocchi', 4]), '2026-09-09T09:00:00Z');
  const L = await create(X, 'Gone soon');
  await add(X, L.list_id, E, (await dishOf(E, 'Gnocchi')).dish_id);
  const out = (await as(X, () => rows(`select public.delete_account() r`)))[0].r;
  assert.deepEqual(out, { ok: true, auth_user_deleted: true });
  assert.equal((await rows(`select count(*)::int n from public.user_lists where owner_id = $1`, [X]))[0].n, 0);
  assert.equal((await rows(`select count(*)::int n from public.user_list_items where owner_id = $1`, [X]))[0].n, 0);
});

test('items follow a dish merge, and collapse when the list already holds the new dish', async () => {
  const E = await w.visit(50, U.alice, P.marion, receipt(['Fries', 4], ['Chips', 3], ['Olives', 2]), '2026-09-10T09:00:00Z');
  const fries = await dishOf(E, 'Fries');
  const chips = await dishOf(E, 'Chips');
  const olives = await dishOf(E, 'Olives');
  const merged = await create(U.alice, 'Merge');
  await add(U.alice, merged.list_id, E, olives.dish_id);
  const other = await w.visit(51, U.bob, P.marion, receipt(['Green olives', 5]), '2026-09-10T10:00:00Z');
  const green = await dishOf(other, 'Green olives');
  await db.query(`select public.merge_dish($1, $2)`, [olives.dish_id, green.dish_id]); // service path, superuser here
  let l = await getList(U.alice, merged.list_id);
  assert.deepEqual(names(l), ['Green olives'], 'the item followed the merge');
  assert.equal(l.items[0].dish_id, green.dish_id);

  // collapse: the list holds (E, Fries) and (E, Chips); the Fries line is corrected to Chips
  const L = await create(U.alice, 'Collapse');
  await add(U.alice, L.list_id, E, fries.dish_id);
  await add(U.alice, L.list_id, E, chips.dish_id);
  await add(U.alice, L.list_id, E, green.dish_id);
  await as(U.alice, () => db.query(`select public.correct_entry_dish(p_review_id => $1, p_dish_id => $2)`, [fries.review_id, chips.dish_id]));
  l = await getList(U.alice, L.list_id);
  assert.deepEqual(names(l), ['Chips', 'Green olives'], 'the duplicate went; no unique violation');
  assert.deepEqual(l.items.map((i) => i.position), [1, 2], 'ranks closed up');
});

test('search queries are trimmed and capped at 100 characters', async () => {
  const long = 'x'.repeat(101);
  assert.equal(await code(U.alice, `select * from public.search_my_entries($1)`, [long]), '22023');
  assert.equal(await code(U.alice, `select * from public.my_scored_dishes(p_query => $1)`, [long]), '22023');
  assert.deepEqual(await as(U.alice, () => rows(`select id from public.search_my_entries($1)`, ['x'.repeat(100)])), []);
  const padded = (await as(U.alice, () => rows(`select id from public.search_my_entries($1)`, ['   tiram   ']))).map((r) => r.id);
  assert.deepEqual(padded, [A1], 'trimmed');
});

test('legacy lists/list_dishes (0004) are owner-read now: B cannot read A\'s rows', async () => {
  const [sys] = await rows(`select id from public.lists where owner_id = $1 and is_system`, [U.alice]);
  assert.ok(sys, 'sign-up still makes the system list (rows are real; nothing dropped)');
  const g = await dishOf(A1, 'Gnocchi');
  await db.query(`insert into public.list_dishes (list_id, dish_id, position) values ($1, $2, 1) on conflict do nothing`, [sys.id, g.dish_id]);
  const read = (uid, sql) => as(uid, () => rows(sql, [U.alice]));
  assert.equal((await read(U.bob, `select id from public.lists where owner_id = $1`)).length, 0);
  assert.equal((await read(U.bob, `select ld.dish_id from public.list_dishes ld join public.lists l on l.id = ld.list_id where l.owner_id = $1`)).length, 0);
  assert.equal((await as(U.bob, () => rows(`select * from public.list_dishes where list_id = $1`, [sys.id]))).length, 0);
  assert.equal((await read(U.alice, `select id from public.lists where owner_id = $1`)).length, 1, 'the owner still reads hers');
  assert.equal((await as(U.alice, () => rows(`select * from public.list_dishes where list_id = $1`, [sys.id]))).length, 1);
});

test('0060 is idempotent: re-applying it on a populated database changes nothing', async () => {
  const before = (await rows(`select (select count(*) from public.user_lists)::int l, (select count(*) from public.user_list_items)::int i`))[0];
  await db.exec(readFileSync(new URL('../../migrations/0060_lists_and_journal_search.sql', import.meta.url), 'utf8'));
  await db.exec('grant usage on schema extensions to anon, authenticated, service_role;');
  assert.deepEqual((await rows(`select (select count(*) from public.user_lists)::int l, (select count(*) from public.user_list_items)::int i`))[0], before);
  assert.ok((await as(U.alice, () => rows(`select * from public.my_lists()`))).length > 0);
});
