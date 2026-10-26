// supabase/tests/db/two_sixes_test.mjs — at most two 6s in any two months (0091): the third is saved
// as 5.0, a re-sort keeps an entry's own 6s, deleting an entry gives its 6s back, and six_allowance
// says how many are left and when the next comes back.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, rows;

before(async () => {
  w = await world();
  ({ db, as, rows } = w);
});
after(async () => db?.close());

const scores = async (entry) =>
  (await rows(`select score::float8 as s from public.reviews where entry_id = $1 order by entry_position`, [entry])).map((r) => r.s);
const allowance = async (uid, entry = null) =>
  (await as(uid, () => rows(`select sixes_left, next_at from public.six_allowance($1)`, [entry])))[0];

test('0091: two 6s go through, the third is a 5.0, and the allowance says when the next comes back', async () => {
  assert.equal((await allowance(U.dan)).sixes_left, 2);
  const A = await w.visit(9101, U.dan, P.tipo, receipt(['Tiramisu', 6]));
  const B = await w.visit(9102, U.dan, P.marion, receipt(['Risotto', 6]));
  assert.deepEqual(await scores(A), [6]);
  assert.deepEqual(await scores(B), [6]);
  const now = await allowance(U.dan);
  assert.equal(now.sixes_left, 0);
  assert.ok(now.next_at, 'a date when none are left');

  const C = await w.visit(9103, U.dan, P.tipo, receipt(['Gnocchi', 6]));
  assert.deepEqual(await scores(C), [5], 'the third 6 is saved as 5.0');
});

test('0091: a re-sort keeps an entry\'s own 6, and editing that entry has its 6 to spend', async () => {
  const A = id(9101);
  await w.sortAs(A, P.tipo, receipt(['Tiramisu', 6]).items);
  assert.deepEqual(await scores(A), [6], 'a carry, not a third 6');
  assert.equal((await allowance(U.dan, A)).sixes_left, 1);
});

test('0091: deleting an entry gives its 6 back; a direct write of a 6 is held to the same rule (0094: server-side only)', async () => {
  const C = id(9103);
  const [line] = await rows(`select id from public.reviews where entry_id = $1`, [C]);
  await assert.rejects(as(U.dan, () => db.query(`update public.reviews set score = 6 where id = $1`, [line.id])),
    /permission denied/, '0094: no client PATCH of a score');
  await db.query(`update public.reviews set score = 6 where id = $1`, [line.id]);
  assert.deepEqual(await scores(C), [5], 'still two in the window');

  await as(U.dan, () => db.query(`delete from public.entries where id = $1`, [id(9102)]));
  assert.equal((await allowance(U.dan)).sixes_left, 1);
  await db.query(`update public.reviews set score = 6 where id = $1`, [line.id]);
  assert.deepEqual(await scores(C), [6]);
});

test('0091: nobody can read or reset the grants', async () => {
  await assert.rejects(as(U.dan, () => rows(`select * from public.six_grants`)));
  await assert.rejects(allowance(null), 'signed out has no allowance');
});
