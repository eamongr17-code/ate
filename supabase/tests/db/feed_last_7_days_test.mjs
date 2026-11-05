// supabase/tests/db/feed_last_7_days_test.mjs — 0109: the Feed is the last 7 days of entries by when
// they were POSTED, newest posted first; when they were eaten does not move them.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, rows, error;

const ago = (days) => new Date(Date.now() - days * 86_400_000).toISOString();

before(async () => {
  w = await world();
  ({ db, as, rows, error } = w);
  // [n, author, eaten, posted]
  const visits = [
    [10901, U.bob, ago(21), ago(1)], //    eaten three weeks ago, posted yesterday
    [10902, U.cleo, ago(1), ago(3)], //    eaten yesterday, posted three days ago
    [10903, U.bob, ago(10), ago(10)], //   posted ten days ago: out of the window
    [10904, U.cleo, ago(0.1), ago(0.1)], // just now
    [10905, U.alice, ago(2), ago(2)], //   the reader's own
  ];
  for (const [n, who, eaten] of visits) await w.visit(n, who, P.tipo, receipt(['Gnocchi', 4]), eaten);
  // posted_at is the server's; the test sets it as the superuser (no client can, see below).
  for (const [n, , , posted] of visits) {
    await db.query(`update public.entries set posted_at = $2 where id = $1`, [id(n), posted]);
  }
});
after(async () => db?.close());

const feed = (uid, args) => as(uid, () => rows(`select id, posted_at, is_mine from public.get_entry_feed(${args})`));

test('p_within_days: posted in the window only, newest posted first', async () => {
  const got = (await feed(U.alice, 'p_page_size => 50, p_within_days => 7')).map((r) => r.id);
  assert.deepEqual(got, [id(10904), id(10901), id(10902)]);
});

test('p_within_days: the keyset pages on (posted_at, id) and meets every row once', async () => {
  const walked = await w.walk((last) => feed(U.alice,
    last ? `p_page_size => 1, p_within_days => 7, p_cursor_created_at => '${last.posted_at.toISOString()}', p_cursor_id => '${last.id}'`
         : 'p_page_size => 1, p_within_days => 7'));
  assert.deepEqual(walked.map((r) => r.id), [id(10904), id(10901), id(10902)]);
});

test('p_within_days: own entries when asked, and the browse twin for anon', async () => {
  const own = (await feed(U.alice, 'p_page_size => 50, p_within_days => 7, p_include_own => true')).map((r) => r.id);
  assert.deepEqual(own, [id(10904), id(10901), id(10905), id(10902)]);
  const anon = await feed(null, 'p_page_size => 50, p_within_days => 7');
  assert.deepEqual(anon.map((r) => r.id), [id(10904), id(10901), id(10905), id(10902)]);
  assert.ok(anon.every((r) => r.is_mine === false));
});

test('no window = the call as it was: everything, by when it was eaten', async () => {
  const got = (await as(U.alice, () => rows(`select id from public.get_entry_feed(p_page_size => 50)`))).map((r) => r.id);
  assert.deepEqual(got.filter((x) => x.startsWith('00000000-0000-4000-8000-0000000109')),
    [id(10904), id(10902), id(10903), id(10901)]);
});

test('p_within_days out of range is refused', async () => {
  assert.equal((await error(feed(U.alice, 'p_within_days => 0')))?.code, '22023');
  assert.equal((await error(feed(U.alice, 'p_within_days => 366')))?.code, '22023');
});

test('posted_at is the server clock: a client cannot write it, and a new entry gets now()', async () => {
  const denied = await error(as(U.bob, () => db.query(
    `insert into public.entries (id, author_id, body, restaurant_id, created_at, posted_at) values ($1, $2, 'x', $3, $4, $4)`,
    [id(10906), U.bob, P.tipo, ago(30)])));
  assert.equal(denied?.code, '42501');
  await w.visit(10907, U.bob, P.tipo, receipt(['Gnocchi', 4]), ago(30));
  const [{ fresh }] = await rows(`select posted_at > now() - interval '1 minute' fresh from public.entries where id = $1`, [id(10907)]);
  assert.equal(fresh, true, 'dated a month back, posted now');
  const top = await feed(U.alice, 'p_page_size => 1, p_within_days => 7');
  assert.equal(top[0].id, id(10907), 'a back-dated entry posted now tops the Feed');
});
