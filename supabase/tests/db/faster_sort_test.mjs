// supabase/tests/db/faster_sort_test.mjs — 0056 (faster logging) at the SQL level: the preview cache's
// pending claims, and the sort's one-trip context read.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { actors, boot } from './harness.mjs';

const A = '00000000-0000-4000-8000-00000000000a';
const B = '00000000-0000-4000-8000-00000000000b';
const R1 = '00000000-0000-4000-8000-0000000000f1';
const R2 = '00000000-0000-4000-8000-0000000000f2';
const E1 = '00000000-0000-4000-8000-000000000e01';
const E2 = '00000000-0000-4000-8000-000000000e02';
const KEY = (c) => c.repeat(64);

let db, as, asService, rows, error;

before(async () => {
  db = await boot();
  ({ as, asService, rows, error } = actors(db));
  await db.exec(`
    insert into auth.users (id, email) values ('${A}', 'alice@ate.test'), ('${B}', 'bob@ate.test');
    insert into public.restaurants (id, name, address, city, source) values
      ('${R1}', 'Tipo 00', '361 Little Bourke St, Melbourne VIC 3000, Australia', 'Melbourne', 'manual'),
      ('${R2}', 'Poodle', '81 Gertrude St, Fitzroy VIC 3065, Australia', 'Fitzroy', 'manual');
  `);
});
after(async () => db?.close());

const claim = (author, key, doClaim = true, pending = 15) =>
  asService(() => rows(`select public.sort_preview_claim($1, $2, 'claude-haiku-4-5', $3, $4) s`, [author, key, doClaim, pending]))
    .then((r) => r[0].s);

test('0056: a preview claims a fresh key; the real sort sees it pending; a second preview does not re-claim', async () => {
  assert.deepEqual(await claim(A, KEY('a')), { state: 'claimed', plan: null });
  const [row] = await rows(`select plan, model from public.sort_preview_cache where author_id = $1 and cache_key = $2`, [A, KEY('a')]);
  assert.deepEqual(row, { plan: null, model: 'claude-haiku-4-5' }, 'a pending claim is a row with no plan');
  assert.deepEqual(await claim(A, KEY('a'), false), { state: 'pending', plan: null }, 'the real sort only reads');
  assert.deepEqual(await claim(A, KEY('a')), { state: 'pending', plan: null }, 'a concurrent preview waits too');
  // per author: the same key under someone else is theirs to claim
  assert.deepEqual(await claim(B, KEY('a'), false), { state: 'none', plan: null });
});

test('0056: once the preview stores its plan, everyone gets a HIT and nobody can re-claim it', async () => {
  await asService(() => db.query(
    `insert into public.sort_preview_cache (author_id, cache_key, plan, model) values ($1, $2, '{"items":[]}', 'm')
       on conflict (author_id, cache_key) do update set plan = excluded.plan`, [A, KEY('a')]));
  assert.deepEqual(await claim(A, KEY('a'), false), { state: 'hit', plan: { items: [] } });
  assert.deepEqual(await claim(A, KEY('a')), { state: 'hit', plan: { items: [] } });
  assert.deepEqual((await rows(`select plan from public.sort_preview_cache where cache_key = $1 and author_id = $2`, [KEY('a'), A]))[0].plan,
    { items: [] }, 'the claim did not wipe a ready plan');
});

test('0056: a stale claim (its preview died) reads as none, and the next preview takes it over', async () => {
  await claim(A, KEY('b'));
  await db.query(`update public.sort_preview_cache set created_at = now() - interval '20 seconds' where cache_key = $1`, [KEY('b')]);
  assert.deepEqual(await claim(A, KEY('b'), false), { state: 'none', plan: null }, 'the real sort does not wait on a dead preview');
  assert.deepEqual(await claim(A, KEY('b')), { state: 'claimed', plan: null });
  assert.deepEqual(await claim(A, KEY('b'), false), { state: 'pending', plan: null }, 'the takeover is fresh');
});

test('0056: an expired plan is not a hit and can be claimed again', async () => {
  await db.query(`insert into public.sort_preview_cache (author_id, cache_key, plan, expires_at)
                  values ($1, $2, '{"items":[]}', now() - interval '1 minute')`, [A, KEY('c')]);
  assert.deepEqual(await claim(A, KEY('c'), false), { state: 'none', plan: null });
  assert.deepEqual(await claim(A, KEY('c')), { state: 'claimed', plan: null });
  assert.equal((await rows(`select count(*)::int n from public.sort_preview_cache where cache_key = $1`, [KEY('c')]))[0].n, 1);
});

test('0056: a pending row is purged on expiry like any other', async () => {
  await db.query(`update public.sort_preview_cache set expires_at = now() - interval '1 second' where cache_key = $1`, [KEY('c')]);
  assert.ok((await asService(() => rows(`select public.sort_preview_purge_expired() n`)))[0].n >= 1);
  assert.equal((await rows(`select count(*)::int n from public.sort_preview_cache where cache_key = $1`, [KEY('c')]))[0].n, 0);
});

test('0056: sort_entry_context — the entry, the pinned place\'s name + menu, and the lines holding a 6, in one read', async () => {
  await as(A, () => db.query(
    `insert into public.entries (id, author_id, body, restaurant_id) values ($1, $2, 'Pasta 4.5 and the tiramisu 6', $3)`,
    [E1, A, R1]));
  const [{ id: pasta }] = await rows(`insert into public.dishes (name, restaurant_id) values ('Pasta', $1) returning id`, [R1]);
  const [{ id: tira }] = await rows(`insert into public.dishes (name, restaurant_id) values ('Tiramisu', $1) returning id`, [R1]);
  await rows(`insert into public.dishes (name, restaurant_id) values ('Elsewhere', $1)`, [R2]);
  await db.query(
    `insert into public.reviews (reviewer_id, dish_id, score, entry_id, entry_position, mention_text, mention_offset, score_evidence, evidence_offset)
     values ($1, $2, 4.5, $3, 1, 'Pasta', 0, 'Pasta 4.5', 0), ($1, $4, 6, $3, 2, 'tiramisu', 18, 'tiramisu 6', 18)`,
    [A, pasta, E1, tira]);

  const [{ c }] = await asService(() => rows(`select public.sort_entry_context($1) c`, [E1]));
  assert.deepEqual(c.entry, {
    id: E1, author_id: A, body: 'Pasta 4.5 and the tiramisu 6', restaurant_id: R1, restaurant_source: 'user',
    sort_status: 'pending', sort_plan: null,
  });
  assert.equal(c.place_name, 'Tipo 00');
  assert.deepEqual([...c.known_dishes].sort(), ['Pasta', 'Tiramisu'], 'only this place\'s menu');
  assert.deepEqual(c.prior_sixes, [{
    dish_name: 'Tiramisu', mention_text: 'tiramisu', mention_offset: 18, score_evidence: 'tiramisu 6', evidence_offset: 18,
  }]);

  // a corrected 6 is the user's, not the sorter's: not carried
  await db.query(`update public.reviews set corrected_at = now() where entry_id = $1 and score = 6`, [E1]);
  assert.deepEqual((await asService(() => rows(`select public.sort_entry_context($1) c`, [E1])))[0].c.prior_sixes, []);
});

test('0056: sort_entry_context — a sorter-matched place is not pinned (no name, no menu); unknown entry is null', async () => {
  await as(B, () => db.query(`insert into public.entries (id, author_id, body, restaurant_id) values ($1, $2, 'x', $3)`, [E2, B, R2]));
  await db.query(`update public.entries set restaurant_source = 'sorter' where id = $1`, [E2]);
  const [{ c }] = await asService(() => rows(`select public.sort_entry_context($1) c`, [E2]));
  assert.equal(c.entry.restaurant_source, 'sorter');
  assert.equal(c.place_name, null);
  assert.equal(c.known_dishes, null);
  assert.equal((await asService(() => rows(`select public.sort_entry_context($1) c`, [B])))[0].c, null);
});

test('0056: both helpers are service_role only', async () => {
  for (const fn of [`public.sort_preview_claim('${A}', '${KEY('d')}')`, `public.sort_entry_context('${E1}')`]) {
    assert.equal((await as(A, () => error(db.query(`select ${fn}`))))?.code, '42501', fn);
    assert.equal((await as(null, () => error(db.query(`select ${fn}`))))?.code, '42501', fn);
  }
});
