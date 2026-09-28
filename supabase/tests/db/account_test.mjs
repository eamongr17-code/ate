// supabase/tests/db/account_test.mjs — first run, Settings and account deletion at the SQL level:
// handle_available (0019), handle_new_user's always-a-profile rule and the retired self-deactivation
// (0035), profile writes, delete_account. Ported from the staging suites AccountContractTests and
// AccountClientContractTests (merged: the second asked the first's questions through the client).
// my_blocks lives in social_test.mjs.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, id } from './fixtures.mjs';

let w, db, as, rows, error;

before(async () => {
  w = await world({ places: false });
  ({ db, as, rows, error } = w);
  await db.query(`update public.profiles set username = 'MarcoEats' where id = $1`, [U.bob]);
});
after(async () => db?.close());

const available = async (handle, uid = U.alice) =>
  (await as(uid, () => rows(`select public.handle_available($1) ok`, [handle])))[0].ok;

test('handle_available: a taken handle is taken in any casing and with padding', async () => {
  for (const variant of ['MarcoEats', 'marcoeats', 'MARCOEATS', 'Marcoeats', '  MarcoEats  ']) {
    assert.equal(await available(variant), false, `'${variant}' is taken — citext does not care about case`);
  }
  assert.equal(await available('alice', U.alice), false, 'my own handle does not read as free');
});

test('handle_available: a free handle is free; 1–30 characters after the trim, or never', async () => {
  assert.equal(await available('nobodyhasthis'), true);
  assert.equal(await available('z'.repeat(30)), true, '30 is legal');
  for (const bad of ['', '   ', 'a'.repeat(31)]) assert.equal(await available(bad), false, JSON.stringify(bad));
  assert.ok(await as(null, () => error(db.query(`select public.handle_available('x')`))), 'signed-in only');
});

test('0035: a sign-up asking for a taken handle still gets a profile, under another handle', async () => {
  const P1 = id(501);
  await db.query(`insert into auth.users (id, email, raw_user_meta_data) values ($1, 'probe@ate.test', '{"username":"MarcoEats"}')`, [P1]);
  const got = await rows(`select username from public.profiles where id = $1`, [P1]);
  assert.equal(got.length, 1, 'handle_new_user must ALWAYS leave a profile');
  assert.notEqual(got[0].username.toLowerCase(), 'marcoeats');
  // Apple's private relay never becomes a handle.
  const P2 = id(502);
  await db.query(`insert into auth.users (id, email) values ($1, 'xyz123@privaterelay.appleid.com')`, [P2]);
  assert.match((await rows(`select username from public.profiles where id = $1`, [P2]))[0].username, /^ate[0-9a-f]{8}$/);
});

test('0035: no client can deactivate itself — by RPC or by PATCH — and first-run writes still work', async () => {
  assert.ok(await as(U.cleo, () => error(db.query(`select public.deactivate_account()`))), 'deactivate_account is retired');
  await as(U.cleo, () => error(db.query(`update public.profiles set deleted_at = now() where id = $1`, [U.cleo])));
  assert.equal((await rows(`select deleted_at from public.profiles where id = $1`, [U.cleo]))[0].deleted_at, null,
    'deleted_at is not a client-writable column');
  assert.equal((await as(U.alice, () => rows(`select * from public.profile_summary($1)`, [U.cleo]))).length, 1, 'still live to everyone else');

  assert.equal(await as(U.cleo, () => error(db.query(`update public.profiles set name = 'Probe', username = 'cleo_new' where id = $1`, [U.cleo]))), null);
  assert.deepEqual((await rows(`select name, username from public.profiles where id = $1`, [U.cleo]))[0], { name: 'Probe', username: 'cleo_new' });
  await as(U.alice, () => db.query(`update public.profiles set name = 'Hijack' where id = $1`, [U.cleo]));
  assert.equal((await rows(`select name from public.profiles where id = $1`, [U.cleo]))[0].name, 'Probe', 'only your own row');
  assert.equal(await available('cleo_new'), false);
});

test('0035: delete_account deletes the account and everything personal, and frees the handle', async () => {
  const out = (await as(U.dan, () => rows(`select public.delete_account() r`)))[0].r;
  assert.deepEqual(out, { ok: true, auth_user_deleted: true });
  const left = (await rows(`select
    (select count(*)::int from auth.users where id = $1) u,
    (select count(*)::int from public.profiles where id = $1) p`, [U.dan]))[0];
  assert.deepEqual(left, { u: 0, p: 0 }, 'gone, not deactivated');
  assert.equal(await available('dan'), true, 'a deleted account no longer holds its handle');
});
