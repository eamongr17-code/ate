// supabase/tests/db/audit_nov4_test.mjs — 0107, the weekly audit of 4 Nov: a re-dated visit moves its
// lines too; save provenance is the server's; handles keep the app's alphabet.
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

const code = async (fn) => (await error(fn()))?.code ?? null;
const dishesOf = async (E) =>
  (await rows(`select dish_id from public.reviews where entry_id = $1 order by entry_position`, [E])).map((r) => r.dish_id);
const save = async (uid, dish) => (await rows(`select * from public.saves where user_id = $1 and dish_id = $2`, [uid, dish]))[0];

test('set_entry_date moves the lines with the entry, and they stay uncorrected', async () => {
  const E = await w.visit(10701, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu', 3]), '2026-09-01T09:00:00Z');
  await as(U.alice, () => db.query(`select public.set_entry_date($1, $2)`, [E, '2026-08-20T19:30:00Z']));

  const [{ at }] = await rows(`select created_at at time zone 'UTC' at from public.entries where id = $1`, [E]);
  const lines = await rows(
    `select created_at at time zone 'UTC' at, corrected_at from public.reviews where entry_id = $1`, [E]);
  assert.equal(lines.length, 2);
  for (const l of lines) {
    assert.equal(l.at.getTime(), at.getTime(), 'the line is on the day the entry says');
    assert.equal(l.corrected_at, null, 'moving the day is not a correction');
  }

  // Someone else still cannot move it, and their lines stay put.
  assert.equal(await code(() => as(U.bob, () => db.query(`select public.set_entry_date($1, now())`, [E]))), 'P0002');
  const after = await rows(`select created_at at time zone 'UTC' at from public.reviews where entry_id = $1`, [E]);
  for (const l of after) assert.equal(l.at.getTime(), at.getTime(), 'a refused move leaves the lines alone');
});

test('saves: a forged source person is replaced by the entry\'s author', async () => {
  const E = await w.visit(10702, U.bob, P.tipo, receipt(['Pie', 4], ['Salad', 2]), '2026-09-02T09:00:00Z');
  const [pie, salad] = await dishesOf(E);

  // Direct insert naming Cleo as the source: the server records Bob, whose entry it is.
  await as(U.alice, () => db.query(
    `insert into public.saves (user_id, dish_id, source_entry_id, source_user_id) values ($1, $2, $3, $4)`,
    [U.alice, pie, E, U.cleo]));
  assert.equal((await save(U.alice, pie)).source_user_id, U.bob);

  // No entry named: no source person, whatever was sent.
  await as(U.dan, () => db.query(
    `insert into public.saves (user_id, dish_id, source_user_id) values ($1, $2, $3)`, [U.dan, salad, U.cleo]));
  const loose = await save(U.dan, salad);
  assert.equal(loose.source_user_id, null);
  assert.equal(loose.source_entry_id, null);

  // An update cannot rewrite the person either.
  await as(U.alice, () => db.query(
    `update public.saves set source_user_id = $3 where user_id = $1 and dish_id = $2`, [U.alice, pie, U.cleo]));
  assert.equal((await save(U.alice, pie)).source_user_id, U.bob);
});

test('saves: an entry that never printed the dish gives no provenance; save_dish and the server are unchanged', async () => {
  const E = await w.visit(10703, U.bob, P.tipo, receipt(['Risotto', 5]), '2026-09-03T09:00:00Z');
  const F = await w.visit(10704, U.cleo, P.marion, receipt(['Olives', 3]), '2026-09-03T10:00:00Z');
  const [risotto] = await dishesOf(E);
  const [olives] = await dishesOf(F);

  await as(U.alice, () => db.query(`select public.save_dish($1, $2)`, [olives, E]));
  const stray = await save(U.alice, olives);
  assert.equal(stray.source_entry_id, null, 'Bob\'s entry did not print the olives');
  assert.equal(stray.source_user_id, null);

  await as(U.alice, () => db.query(`select public.save_dish($1, $2)`, [risotto, E]));
  const real = await save(U.alice, risotto);
  assert.equal(real.source_entry_id, E);
  assert.equal(real.source_user_id, U.bob);

  // Saving again from another entry keeps the first provenance (0020's rule).
  await as(U.alice, () => db.query(`select public.save_dish($1, $2)`, [risotto, F]));
  assert.equal((await save(U.alice, risotto)).source_entry_id, E);

  // The server's own writers are not checked.
  await asService(() => db.query(
    `insert into public.saves (user_id, dish_id, source_user_id) values ($1, $2, $3)`, [U.dan, risotto, U.cleo]));
  assert.equal((await save(U.dan, risotto)).source_user_id, U.cleo);
});

test('handles: the app\'s alphabet for client writes; other columns still save on a legacy handle', async () => {
  for (const bad of ['has space', 'emoji🍝', 'semi;colon', 'a'.repeat(31)]) {
    assert.ok(['23514', '22001'].includes(
      await code(() => as(U.dan, () => db.query(`update public.profiles set username = $2 where id = $1`, [U.dan, bad])))),
    `refused: ${bad}`);
  }
  await as(U.dan, () => db.query(`update public.profiles set username = 'dan_2' where id = $1`, [U.dan]));
  assert.equal((await rows(`select username::text u from public.profiles where id = $1`, [U.dan]))[0].u, 'dan_2');

  // A handle from before the rule does not block the rest of the profile.
  await asService(() => db.query(`update public.profiles set username = 'old handle' where id = $1`, [U.cleo]));
  const cols = (await rows(
    `select column_name from information_schema.column_privileges
      where table_schema = 'public' and table_name = 'profiles' and grantee = 'authenticated'
        and privilege_type = 'UPDATE' and column_name in ('display_name', 'bio')`)).map((r) => r.column_name);
  assert.ok(cols.length, 'some other profile column is client-writable');
  await as(U.cleo, () => db.query(`update public.profiles set ${cols[0]} = 'Cleo' where id = $1`, [U.cleo]));
  assert.equal((await rows(`select ${cols[0]} v from public.profiles where id = $1`, [U.cleo]))[0].v, 'Cleo');
});
