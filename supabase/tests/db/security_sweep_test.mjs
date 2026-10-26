// supabase/tests/db/security_sweep_test.mjs — 0093: client writes only where the app writes, text caps,
// the daily Places budget, is_service_role().
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, receipt } from './fixtures.mjs';

let w, db, as, asService, rows, error;

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
});
after(async () => db?.close());

test('0093: signed out writes nothing; unused tables take no client writes', async () => {
  const anonWrite = await as(null, () => error(db.query(
    `insert into public.restaurants (source, name, city) values ('manual', 'Fake', 'Nowhere')`)));
  assert.equal(anonWrite?.code, '42501', 'anon cannot insert');
  assert.equal(await as(null, () => error(db.query(`select id from public.restaurants limit 1`))), null,
    'anon can still read (the keep-alive does), RLS answers with no rows');

  for (const sql of [
    `insert into public.restaurants (source, name, city) values ('manual', 'Fake', 'Nowhere')`,
    `insert into public.follows (follower_id, followee_id) values ('${U.alice}', '${U.bob}')`,
    `update public.restaurants set name = 'Hacked'`,
    `insert into public.profiles (id, username, name) values ('${U.alice}', 'dupe', 'Dupe')`,
  ]) {
    const e = await as(U.alice, () => error(db.query(sql)));
    assert.equal(e?.code, '42501', sql);
  }
});

test('0093: the app\'s own writes still work', async () => {
  const E = await w.visit(1, U.alice, P.tipo, receipt(['Pasta', 4]), '2026-09-01T09:00:00Z');
  assert.equal(await as(U.alice, () => error(db.query(`update public.entries set body = body || ' more' where id = $1`, [E]))), null);
  assert.equal(await as(U.alice, () => error(db.query(`update public.profiles set bio = 'hi', city = 'Fitzroy' where id = $1`, [U.alice]))), null);
  assert.equal(await as(U.alice, () => error(db.query(`update public.reviews set tags = '{gf}' where entry_id = $1`, [E]))), null);
});

test('0093: text caps on client-written columns', async () => {
  const E = await w.visit(2, U.bob, P.tipo, receipt(['Salad', 3]), '2026-09-02T09:00:00Z');
  const long = await as(U.bob, () => error(db.query(`update public.entries set body = repeat('a', 20001) where id = $1`, [E])));
  assert.equal(long?.code, '23514', 'a 20,001-character entry is refused');
  const bio = await as(U.bob, () => error(db.query(`update public.profiles set bio = repeat('a', 1001) where id = $1`, [U.bob])));
  assert.equal(bio?.code, '23514', 'a 1,001-character bio is refused');
});

test('0093: the Places budget caps each user a day, and everyone together; service only', async () => {
  const hit = (uid) => asService(() => rows(`select public.places_budget_hit($1) ok`, [uid])).then((r) => r[0].ok);
  await asService(() => db.query(
    `insert into public.places_usage (user_id, day, calls) values ($1, (now() at time zone 'utc')::date, 399)`, [U.cleo]));
  assert.equal(await hit(U.cleo), true, 'the 400th call is allowed');
  assert.equal(await hit(U.cleo), false, 'the 401st is refused');
  assert.equal(await hit(U.dan), true, 'users are counted separately');

  await asService(() => db.query(
    `update public.places_usage set calls = 4000 where user_id = $1`, [U.cleo]));
  assert.equal(await hit(U.bob), false, 'the global ceiling stops everyone');
  await asService(() => db.query(`delete from public.places_usage`));

  assert.ok(await as(U.cleo, () => error(db.query(`select public.places_budget_hit($1)`, [U.cleo]))), 'users cannot call it');
  assert.ok(await as(U.cleo, () => error(db.query(`select * from public.places_usage`))), 'users cannot read it');
});

test('0093: is_service_role is true only for the service role', async () => {
  const ask = (fn) => fn(() => rows(`select public.is_service_role() ok`)).then((r) => r[0].ok);
  assert.equal(await ask((f) => as(null, f)), false);
  assert.equal(await ask((f) => as(U.alice, f)), false);
  assert.equal(await ask(asService), true);
});
