// supabase/tests/db/round3_test.mjs — round 3 (0037–0040) at the SQL level, plus the parked-plan path
// that 0040 made impossible to mint from a client.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { actors, boot } from './harness.mjs';

const A = '00000000-0000-4000-8000-00000000000a';
const B = '00000000-0000-4000-8000-00000000000b';
const R1 = '00000000-0000-4000-8000-0000000000f1'; // Melbourne
const R2 = '00000000-0000-4000-8000-0000000000f2'; // Fitzroy
const R3 = '00000000-0000-4000-8000-0000000000f3'; // Fitzroy
const R4 = '00000000-0000-4000-8000-0000000000f4'; // "fitzroy " typed by hand
const R5 = '00000000-0000-4000-8000-0000000000f5'; // Carlton
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const url = (path) => `https://cvoitgoaosofkougmarn.supabase.co/storage/v1/object/public/review-photos/${path}`;
const KEY = (c) => c.repeat(64);

let db, as, asService, rows, error;

before(async () => {
  db = await boot();
  ({ as, asService, rows, error } = actors(db));
  await db.exec(`
    insert into auth.users (id, email) values ('${A}', 'alice@ate.test'), ('${B}', 'bob@ate.test');
    insert into public.restaurants (id, name, address, city, source) values
      ('${R1}', 'Tipo 00', '361 Little Bourke St, Melbourne VIC 3000, Australia', 'Melbourne', 'manual'),
      ('${R2}', 'Poodle', '81 Gertrude St, Fitzroy VIC 3065, Australia', 'Fitzroy', 'manual'),
      ('${R3}', 'Marion', '53 Gertrude St, Fitzroy VIC 3065, Australia', 'Fitzroy', 'manual'),
      ('${R4}', 'Cafe', null, 'fitzroy ', 'manual'),
      ('${R5}', 'Brunetti', '380 Lygon St, Carlton VIC 3053, Australia', 'Carlton', 'manual');
  `);
});
after(async () => db?.close());

/** A pre-0040 placeless entry — the only way one exists now. Superuser, local PGlite only. */
async function legacyPlaceless(entryId, author, body) {
  await db.exec(`alter table public.entries disable trigger entries_place_required;`);
  try {
    await db.query(`insert into public.entries (id, author_id, body) values ($1, $2, $3)`, [entryId, author, body]);
  } finally {
    await db.exec(`alter table public.entries enable trigger entries_place_required;`);
  }
}

const sortAs = (entryId, place, items, meta = null) =>
  asService(() => db.query(
    `select public.apply_entry_sort(p_entry_id => $1, p_restaurant_id => $2, p_items => $3::jsonb, p_mode => 'stub',
       p_place_query => null, p_place_offset => null, p_meta => $4::jsonb)`,
    [entryId, place, JSON.stringify(items), meta && JSON.stringify(meta)],
  ));

// ---------------------------------------------------------------------------------------------------
// 0040 — place required
// ---------------------------------------------------------------------------------------------------
test('0040: a new placeless entry is refused 23502 place_required, burning no order number', async () => {
  const e = await as(A, () => error(db.query(`insert into public.entries (id, author_id, body) values ($1, $2, 'x')`, [id(1), A])));
  assert.equal(e?.code, '23502');
  assert.equal(e?.message, 'place_required');
  assert.equal((await rows(`select entry_seq from public.profiles where id = $1`, [A]))[0].entry_seq, 0);
  const svc = await asService(() => error(db.query(`insert into public.entries (id, author_id, body) values ($1, $2, 'x')`, [id(2), A])));
  assert.equal(svc?.code, '23502', 'service_role too');
});

test('parked plan: a legacy placeless entry stays editable, sorts to a parked plan, and prints when placed', async () => {
  const LEG = id(10);
  await legacyPlaceless(LEG, A, 'Tiramisu 4.0 GF was lovely');
  assert.equal(await as(A, () => error(db.query(`update public.entries set body = body || '!' where id = $1`, [LEG]))), null,
    'a body edit re-runs no insert check');

  await sortAs(LEG, null, [{ dish_name: 'Tiramisu', score: 4, score_evidence: 'Tiramisu 4.0', tags: ['gf'] }]);
  const parked = (await rows(`select sort_status, jsonb_typeof(sort_plan) t, restaurant_id,
      (select count(*)::int from public.reviews where entry_id = e.id) n from public.entries e where id = $1`, [LEG]))[0];
  assert.deepEqual(parked, { sort_status: 'sorted', t: 'array', restaurant_id: null, n: 0 }, 'sorted, no lines, plan parked');

  await as(A, () => db.query(`select public.correct_entry_place($1, $2)`, [LEG, R1]));
  const lines = await rows(`select v.score::float s, v.tags, d.name from public.reviews v join public.dishes d on d.id = v.dish_id
      where v.entry_id = $1`, [LEG]);
  assert.deepEqual(lines, [{ s: 4, tags: ['gf'], name: 'Tiramisu' }], 'the parked plan prints, tags and all');
});

test('parked plan: a place cannot be deleted out from under an entry (so no new placeless rows that way either)', async () => {
  const E = id(11);
  await as(A, () => db.query(`insert into public.entries (id, author_id, body, restaurant_id) values ($1, $2, 'x', $3)`, [E, A, R5]));
  const e = await error(db.query(`delete from public.restaurants where id = $1`, [R5]));
  assert.equal(e?.code, '23514', `restaurant delete → SET NULL trips entries_place_provenance_ck: ${e?.message}`);
  await db.query(`delete from public.entries where id = $1`, [E]);
});

// ---------------------------------------------------------------------------------------------------
// 0039 — early sort plumbing
// ---------------------------------------------------------------------------------------------------
test('0039: apply_entry_sort records sort_meta in the sort transaction; one overload; the old call binds', async () => {
  const E = id(20);
  await as(A, () => db.query(`insert into public.entries (id, author_id, body, restaurant_id) values ($1, $2, 'Pappardelle 4.5', $3)`, [E, A, R1]));
  await sortAs(E, R1, [{ dish_name: 'Pappardelle', score: 4.5, score_evidence: 'Pappardelle 4.5' }], { cache_hit: true, model: 'claude-haiku-4-5' });
  const m = (await rows(`select sort_meta, updated_at = sorted_at same from public.entries where id = $1`, [E]))[0];
  assert.deepEqual(m, { sort_meta: { cache_hit: true, model: 'claude-haiku-4-5' }, same: true });
  assert.equal(await asService(() => error(db.query(
    `select public.apply_entry_sort(p_entry_id => $1, p_restaurant_id => $2, p_items => '[]'::jsonb, p_mode => 'stub', p_place_query => null, p_place_offset => null)`,
    [E, R1]))), null);
  assert.equal((await rows(`select count(*)::int n from pg_proc where proname = 'apply_entry_sort'`))[0].n, 1);
  assert.equal((await as(A, () => error(db.query(`update public.entries set sort_meta = '{}' where id = $1`, [E]))))?.code, '42501');
});

test('0039: the cache and rate tables are service_role only', async () => {
  assert.equal((await as(A, () => error(db.query(`select * from public.sort_preview_cache`))))?.code, '42501');
  assert.equal((await as(null, () => error(db.query(`select * from public.sort_preview_rate`))))?.code, '42501');
  for (const fn of [`public.sort_preview_rate_hit('${A}', 600, 12)`, `public.sort_preview_purge_expired(10)`]) {
    assert.equal((await as(A, () => error(db.query(`select ${fn}`))))?.code, '42501', fn);
  }
  // the upsert target is the PK — a total unique
  for (const plan of ['{"items":[]}', '{"items":[1]}']) {
    await asService(() => db.query(`insert into public.sort_preview_cache (author_id, cache_key, plan, model) values ($1, $2, $3, 'm')
      on conflict (author_id, cache_key) do update set plan = excluded.plan`, [A, KEY('a'), plan]));
  }
  assert.equal((await rows(`select count(*)::int n from public.sort_preview_cache`))[0].n, 1);
});

test('0039: 12 previews per window, the 13th refused', async () => {
  const hits = [];
  for (let i = 0; i < 13; i++) hits.push((await asService(() => rows(`select public.sort_preview_rate_hit($1, 600, 12) ok`, [B])))[0].ok);
  assert.deepEqual(hits, [...Array(12).fill(true), false]);
});

test('0039: expired plans are purged — everyone\'s, oldest first, bounded per call', async () => {
  await db.exec(`delete from public.sort_preview_cache;
    insert into public.sort_preview_cache (author_id, cache_key, plan, expires_at) values
      ('${A}', '${KEY('1')}', '{}', now() - interval '3 minutes'),
      ('${B}', '${KEY('2')}', '{}', now() - interval '2 minutes'),
      ('${B}', '${KEY('3')}', '{}', now() - interval '1 minutes'),
      ('${B}', '${KEY('4')}', '{}', now() + interval '10 minutes');`);
  assert.equal((await asService(() => rows(`select public.sort_preview_purge_expired(2) n`)))[0].n, 2);
  assert.deepEqual((await rows(`select cache_key from public.sort_preview_cache order by cache_key`)).map((r) => r.cache_key[0]), ['3', '4'],
    'the two OLDEST expired went first; the live plan is untouched');
  assert.equal((await asService(() => rows(`select public.sort_preview_purge_expired() n`)))[0].n, 1);
  assert.deepEqual((await rows(`select cache_key from public.sort_preview_cache`)).map((r) => r.cache_key[0]), ['4']);
});

// ---------------------------------------------------------------------------------------------------
// 0038 — feed areas
// ---------------------------------------------------------------------------------------------------
test('0038: feed_areas — what the Feed shows you, grouped case-insensitively, keyset-paged', async () => {
  await as(B, () => db.query(`insert into public.entries (id, author_id, body, restaurant_id, created_at) values
    ($1, $5, 'Poodle', $6, now() - interval '3 hours'),
    ($2, $5, 'Marion', $7, now() - interval '2 hours'),
    ($3, $5, 'Tipo',   $8, now() - interval '1 hours'),
    ($4, $5, 'Cafe',   $9, now() - interval '4 hours')`, [id(30), id(31), id(32), id(33), B, R2, R3, R1, R4]));

  const forAlice = await as(A, () => rows(`select * from public.feed_areas()`));
  assert.deepEqual(forAlice, [{ area: 'Fitzroy', entry_count: 3 }, { area: 'Melbourne', entry_count: 1 }],
    'own entries excluded; "fitzroy " joins Fitzroy under the majority spelling');
  const forAnon = await as(null, () => rows(`select * from public.feed_areas()`));
  assert.deepEqual(forAnon, [{ area: 'Fitzroy', entry_count: 3 }, { area: 'Melbourne', entry_count: 3 }], 'anon: everyone');

  // keyset: (entry_count desc, area asc); the tie at 3 breaks on area
  const p1 = await as(null, () => rows(`select * from public.feed_areas(p_limit => 1)`));
  const p2 = await as(null, () => rows(`select * from public.feed_areas(p_limit => 1, p_cursor_entry_count => $1, p_cursor_area => $2)`,
    [p1[0].entry_count, p1[0].area]));
  const p3 = await as(null, () => rows(`select * from public.feed_areas(p_limit => 1, p_cursor_entry_count => $1, p_cursor_area => $2)`,
    [p2[0].entry_count, p2[0].area]));
  assert.deepEqual([...p1, ...p2, ...p3], forAnon);
  const signedInPaged = await as(A, () => rows(`select * from public.feed_areas(p_limit => 1, p_cursor_entry_count => 3, p_cursor_area => 'Fitzroy')`));
  assert.deepEqual(signedInPaged, [{ area: 'Melbourne', entry_count: 1 }]);
  assert.equal((await as(null, () => rows(`select count(*)::int n from public.feed_areas(p_limit => 0)`)))[0].n, 1, 'limit clamps to ≥1');
});

test('0038: get_entry_feed(p_area) filters on the same string; keyset unchanged; old calls bind', async () => {
  const all = await as(A, () => rows(`select id from public.get_entry_feed(p_cursor_created_at => null, p_cursor_id => null, p_page_size => 20, p_include_own => false)`));
  assert.equal(all.length, 4);
  const f1 = await as(A, () => rows(`select id, created_at from public.get_entry_feed(p_page_size => 2, p_area => 'fitzroy ')`));
  const f2 = await as(A, () => rows(`select id from public.get_entry_feed(p_cursor_created_at => $1, p_cursor_id => $2, p_page_size => 2, p_area => 'Fitzroy')`,
    [f1[1].created_at, f1[1].id]));
  assert.deepEqual([...f1.map((r) => r.id), ...f2.map((r) => r.id)], [id(31), id(30), id(33)]);
  const anon = await as(null, () => rows(`select is_mine from public.get_entry_feed(p_area => 'Fitzroy')`));
  assert.equal(anon.length, 3);
  assert.ok(anon.every((r) => r.is_mine === false));
  assert.equal((await rows(`select count(*)::int n from pg_proc where proname = 'get_entry_feed'`))[0].n, 2, 'one public + one browse');
});

// ---------------------------------------------------------------------------------------------------
// 0037 — delete entry
// ---------------------------------------------------------------------------------------------------
test('0037: delete_entry — owner only; paths + thumbnails; cascade; catalogue and saves stay; cache purged', async () => {
  const E = id(40);
  await as(A, () => db.query(`insert into public.entries (id, author_id, body, restaurant_id) values ($1, $2, 'Gnocchi 4.0', $3)`, [E, A, R1]));
  await sortAs(E, R1, [{ dish_name: 'Gnocchi', score: 4, score_evidence: 'Gnocchi 4.0' }]);
  await as(A, () => db.query(`insert into public.entry_photos (entry_id, position, photo_url) values ($1, 0, $2), ($1, 1, $3), ($1, 2, $4)`,
    [E, url(`${A}/${E}-0.jpg`), url(`${A}/${E}-1.jpg`), url(`${B}/not-hers.jpg`)]));
  const dish = (await rows(`select dish_id from public.reviews where entry_id = $1`, [E]))[0].dish_id;
  await as(B, () => db.query(`select public.save_dish($1, $2)`, [dish, E]));
  await as(B, () => db.query(`select public.report_entry($1, 'spam', null)`, [E]));
  await db.exec(`insert into public.sort_preview_cache (author_id, cache_key, plan) values
    ('${A}', '${KEY('b')}', '{"items":[{"dish_name":"draft words"}]}'), ('${B}', '${KEY('c')}', '{}');`);

  const theirsBefore = (await rows(`select count(*)::int n from public.sort_preview_cache where author_id = $1`, [B]))[0].n;
  assert.equal((await as(B, () => error(db.query(`select public.delete_entry($1)`, [E]))))?.code, '42501', 'not yours');
  assert.equal((await as(null, () => error(db.query(`select public.delete_entry($1)`, [E]))))?.code, '42501', 'anon');

  const res = (await as(A, () => rows(`select public.delete_entry($1) r`, [E])))[0].r;
  assert.deepEqual(res, { photo_paths: [`${A}/${E}-0.jpg`, `${A}/${E}-0_t.jpg`, `${A}/${E}-1.jpg`, `${A}/${E}-1_t.jpg`] });

  const left = (await rows(`select
    (select count(*)::int from public.entries where id = $1) e,
    (select count(*)::int from public.reviews where entry_id = $1) r,
    (select count(*)::int from public.entry_photos where entry_id = $1) p,
    (select count(*)::int from public.reports where entry_id = $1) rep,
    (select count(*)::int from public.dishes where id = $2) d,
    (select count(*)::int from public.saves where dish_id = $2 and source_entry_id is null and source_user_id is not null) s,
    (select coalesce(max(review_count), 0)::int from public.dish_stats where dish_id = $2) rc,
    (select count(*)::int from public.sort_preview_cache where author_id = $3) mine,
    (select count(*)::int from public.sort_preview_cache where author_id = $4) theirs`, [E, dish, A, B]))[0];
  assert.deepEqual(left, { e: 0, r: 0, p: 0, rep: 0, d: 1, s: 1, rc: 0, mine: 0, theirs: theirsBefore },
    'gone: entry, lines, photos rows, reports, HER draft plans. Kept: dish, bob\'s save (provenance nulled), bob\'s plans');
  assert.equal((await as(A, () => error(db.query(`select public.delete_entry($1)`, [E]))))?.code, 'P0002');
});

test('0037: a photo URL another entry still prints is not returned for purge', async () => {
  await as(A, () => db.query(`insert into public.entries (id, author_id, body, restaurant_id) values ($1, $3, 'a', $4), ($2, $3, 'b', $4)`, [id(41), id(42), A, R1]));
  await as(A, () => db.query(`insert into public.entry_photos (entry_id, position, photo_url) values ($1, 0, $3), ($2, 0, $3)`, [id(41), id(42), url(`${A}/shared.jpg`)]));
  assert.deepEqual((await as(A, () => rows(`select public.delete_entry($1) r`, [id(41)])))[0].r, { photo_paths: [] });
});

test('0039: a raw DELETE of an entry purges the author\'s preview plans too', async () => {
  await db.exec(`insert into public.sort_preview_cache (author_id, cache_key, plan) values ('${A}', '${KEY('d')}', '{}');`);
  await as(A, () => db.query(`delete from public.entries where id = $1`, [id(42)]));
  assert.equal((await rows(`select count(*)::int n from public.sort_preview_cache where author_id = $1`, [A]))[0].n, 0);
});

test('0039: delete_account purges the author\'s plans and rate rows, and verifies it', async () => {
  await db.exec(`insert into public.sort_preview_cache (author_id, cache_key, plan) values ('${B}', '${KEY('e')}', '{}');`);
  assert.ok((await rows(`select count(*)::int n from public.sort_preview_rate where author_id = $1`, [B]))[0].n > 0);
  const out = (await as(B, () => rows(`select public.delete_account() r`)))[0].r;
  assert.deepEqual(out, { ok: true, auth_user_deleted: true });
  const left = (await rows(`select
    (select count(*)::int from public.sort_preview_cache where author_id = $1) c,
    (select count(*)::int from public.sort_preview_rate where author_id = $1) r`, [B]))[0];
  assert.deepEqual(left, { c: 0, r: 0 });
});
