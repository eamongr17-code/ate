// supabase/tests/db/hardening_test.mjs — 0067: lines only on your own entry, the daily AI budget,
// and no future-dated entries from a client insert.
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

test('0067: nobody can hang a line on someone else\'s entry', async () => {
  const E = await w.visit(1, U.alice, P.tipo, receipt(['Pasta', 4]), '2026-09-01T09:00:00Z');
  const [{ dish_id: dish }] = await rows(`select dish_id from public.reviews where entry_id = $1`, [E]);

  const insert = await as(U.bob, () => error(db.query(
    `insert into public.reviews (reviewer_id, dish_id, score, entry_id) values ($1, $2, 6, $3)`, [U.bob, dish, E])));
  assert.equal(insert?.code, '42501', 'insert onto another author\'s entry is refused');

  const B = await w.visit(2, U.bob, P.tipo, receipt(['Salad', 3]), '2026-09-02T09:00:00Z');
  const [{ id: bobLine }] = await rows(`select id from public.reviews where entry_id = $1`, [B]);
  const move = await as(U.bob, () => error(db.query(`update public.reviews set entry_id = $2 where id = $1`, [bobLine, E])));
  assert.equal(move?.code, '42501', 'moving your line onto someone else\'s entry is refused');

  const [card] = await as(U.alice, () => rows(`select items from public.entry_cards where id = $1`, [E]));
  assert.equal(card.items.length, 1, 'Alice\'s receipt still has only her line');

  assert.equal(await as(U.bob, () => error(db.query(`update public.reviews set tags = '{gf}' where id = $1`, [bobLine]))), null,
    'the author still edits their own line\'s tags (0094: the only client-writable column)');
});

test('0067: the AI budget caps each user per kind, and is service-only', async () => {
  const hit = (uid, kind) => asService(() => rows(`select public.ai_budget_hit($1, $2) ok`, [uid, kind])).then((r) => r[0].ok);
  const got = [];
  for (let i = 0; i < 41; i++) got.push(await hit(U.cleo, 'share'));
  assert.equal(got.filter(Boolean).length, 40, '40 share reads a day');
  assert.equal(got.at(-1), false, 'the 41st is refused');
  assert.equal(await hit(U.cleo, 'sort'), true, 'kinds are counted separately');
  assert.equal(await hit(U.dan, 'share'), true, 'users are counted separately');
  assert.equal(await hit(U.dan, 'nope'), false, 'an unknown kind is refused');

  assert.ok(await as(U.cleo, () => error(db.query(`select public.ai_budget_hit($1, 'sort')`, [U.cleo]))), 'users cannot call it');
  assert.ok(await as(U.cleo, () => error(db.query(`select * from public.ai_usage`))), 'users cannot read it');
});

test('0067: the global daily ceiling stops everyone', async () => {
  await asService(() => db.query(
    `insert into public.ai_usage (user_id, day, kind, calls) values ($1, (now() at time zone 'utc')::date, 'match', 5000)
     on conflict (user_id, day, kind) do update set calls = 5000`, [U.alice]));
  const [{ ok }] = await asService(() => rows(`select public.ai_budget_hit($1, 'sort') ok`, [U.bob]));
  assert.equal(ok, false);
  await asService(() => db.query(`delete from public.ai_usage`));
});

test('0067: a client cannot date an entry into the future', async () => {
  await as(U.dan, () => db.query(
    `insert into public.entries (id, author_id, body, restaurant_id, created_at) values ($1, $2, 'Soup 4', $3, '2099-01-01T00:00:00Z')`,
    [id(3), U.dan, P.tipo]));
  const [{ future }] = await rows(`select created_at > now() + interval '1 minute' future from public.entries where id = $1`, [id(3)]);
  assert.equal(future, false, 'clamped to now');

  await as(U.dan, () => db.query(
    `insert into public.entries (id, author_id, body, restaurant_id, created_at) values ($1, $2, 'Soup 4', $3, '2026-08-01T12:00:00Z')`,
    [id(4), U.dan, P.tipo]));
  const [{ created_at }] = await rows(`select created_at from public.entries where id = $1`, [id(4)]);
  assert.equal(new Date(created_at).toISOString(), '2026-08-01T12:00:00.000Z', 'a past date (outbox, backfill) stands');
});
