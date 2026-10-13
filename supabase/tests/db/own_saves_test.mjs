// supabase/tests/db/own_saves_test.mjs — your own saved dishes (0061): owner-only, no raw writes, the
// place must be real, input is trimmed and checked, and nothing reaches the dish catalogue.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id } from './fixtures.mjs';

let w, db, as, rows, error;
after(async () => db?.close());

const code = async (uid, sql, params) => (await as(uid, () => error(db.query(sql, params))))?.code ?? null;
const one = async (uid, sql, params) => (await as(uid, () => rows(sql, params)))[0];
const add = (uid, name, place, source = 'manual', url = null, author = null, caption = null) =>
  one(uid, `select public.add_own_save($1, $2, $3, $4, $5, $6) id`, [name, place, source, url, author, caption]);
const mine = (uid) => as(uid, () => rows(`select * from public.my_own_saves order by created_at desc, id desc`));

before(async () => {
  w = await world();
  ({ db, as, rows, error } = w);
});

test('own saves: added, read back with the place, private to the owner', async () => {
  const dishesBefore = (await rows(`select count(*)::int n from public.dishes`))[0].n;
  const a = await add(U.alice, '  Crab fried rice ', P.tipo, 'tiktok', 'https://www.tiktok.com/@x/video/1', '@x', 'So good');
  assert.ok(a.id);
  const [row] = await mine(U.alice);
  assert.equal(row.dish_name, 'Crab Fried Rice', 'trimmed');
  assert.equal(row.restaurant_id, P.tipo);
  assert.equal(row.restaurant_name, 'Tipo 00');
  assert.equal(row.restaurant_city, 'Melbourne');
  assert.equal(row.source, 'tiktok');
  assert.equal(row.source_url, 'https://www.tiktok.com/@x/video/1');
  assert.equal(row.source_author, '@x');
  assert.equal(row.source_caption, 'So good');
  assert.equal((await rows(`select count(*)::int n from public.dishes`))[0].n, dishesBefore, 'no dish is minted');

  assert.equal((await mine(U.bob)).length, 0, 'not visible to anyone else');
  assert.equal((await as(U.bob, () => rows(`select id from public.own_saves`))).length, 0);
  assert.equal((await one(U.bob, `select public.remove_own_save($1) n`, [a.id])).n, 0, 'not yours: nothing removed');
  assert.equal((await mine(U.alice)).length, 1);

  assert.equal((await one(U.alice, `select public.remove_own_save($1) n`, [a.id])).n, 1);
  assert.equal((await one(U.alice, `select public.remove_own_save($1) n`, [a.id])).n, 0, 'already gone');
  assert.equal((await mine(U.alice)).length, 0);
});

test('own saves: no raw writes, no anon', async () => {
  for (const write of [
    `insert into public.own_saves (user_id, dish_name, restaurant_id) values ('${U.alice}', 'raw', '${P.tipo}')`,
    `update public.own_saves set dish_name = 'raw'`,
    `delete from public.own_saves`,
  ]) {
    assert.equal(await code(U.alice, write), '42501', write);
  }
  assert.equal(await code(null, `select public.add_own_save('x', $1)`, [P.tipo]), '42501');
  assert.equal(await code(null, `select * from public.my_own_saves`), '42501');
});

test('own saves: the place must exist, and the input is checked', async () => {
  assert.equal(await code(U.alice, `select public.add_own_save('Pho', $1)`, [id(999)]), 'P0002');
  assert.equal(await code(U.alice, `select public.add_own_save('   ', $1)`, [P.tipo]), '22023');
  assert.equal(await code(U.alice, `select public.add_own_save($1, $2)`, ['x'.repeat(121), P.tipo]), '22023');
  assert.equal(await code(U.alice, `select public.add_own_save('Pho', $1, 'youtube')`, [P.tipo]), '23514');
  assert.equal(await code(U.alice, `select public.add_own_save('Pho', $1, 'link', 'http://plain.example')`, [P.tipo]), '23514');
  const b = await add(U.alice, 'Pho', P.hand);
  const [row] = (await mine(U.alice)).filter((r) => r.id === b.id);
  assert.equal(row.source, 'manual', 'the default');
  assert.equal(row.source_url, null);
});

test('own saves: they go with the account', async () => {
  await add(U.dan, 'Burger', P.tipo);
  await rows(`delete from public.profiles where id = $1`, [U.dan]);
  assert.equal((await rows(`select count(*)::int n from public.own_saves where user_id = $1`, [U.dan]))[0].n, 0);
});

test('own saves: the dish name is printed in title case, own capitals kept (0062, 0065)', async () => {
  const a = await add(U.alice, '  margherita   pizza ', P.tipo);
  const b = await add(U.alice, 'big Mac', P.tipo);
  const names = new Map((await mine(U.alice)).map((r) => [r.id, r.dish_name]));
  assert.equal(names.get(a.id), 'Margherita Pizza');
  assert.equal(names.get(b.id), 'Big Mac');
  await one(U.alice, `select public.remove_own_save($1) n`, [a.id]);
  await one(U.alice, `select public.remove_own_save($1) n`, [b.id]);
});

test('dish_title (0065): title case, small words lower, own capitals kept, case only', async () => {
  const cases = [
    ['Fish stir fry', 'Fish Stir Fry'],
    ['CHICKEN PARMA', 'Chicken Parma'],
    ['BBQ pork bun', 'BBQ Pork Bun'],
    ['McFlurry with oreo', 'McFlurry with Oreo'],
    ['cacio e pepe', 'Cacio e Pepe'],
    ['fish & chips', 'Fish & Chips'],
    ['the works burger', 'The Works Burger'],
    ['prawn stir-fry', 'Prawn Stir-Fry'],
    ["chef's special", "Chef's Special"],
    ['', ''],
  ];
  for (const [input, want] of cases) {
    assert.equal((await rows(`select public.dish_title($1) t`, [input]))[0].t, want, input);
  }
  const [{ n }] = await rows(`select count(*)::int n from public.dishes where name <> public.dish_title(name)`);
  assert.equal(n, 0, 'every stored dish already prints in title case');
});
