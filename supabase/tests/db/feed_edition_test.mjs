// supabase/tests/db/feed_edition_test.mjs — the round-8 Feed (0055) at the SQL level: The Top Ate,
// Because you loved, New to the record, cravings (the table, the picker, set/read), and dishes_by_tag's
// city filter + saved flag. Signed in and signed out (the browse twins).
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, rows, error;
const D = {}; // dish ids by short name

const DAY = 86_400_000;
const ago = (days) => new Date(Date.now() - days * DAY).toISOString();

// One world, written once; the tests only read it (plus saves, blocks and cravings they undo).
//   A Margherita    @ Tipo (CBD)       alice 5 (3d) · bob 5 (2d)                  → 5.0, recent
//   B Tiramisu      @ Tipo             cleo 6 (1d)                                → one scored line: never ranked
//   C Cacio e pepe  @ Osteria (Carlton) alice 4.5 (4d, photo) · bob 4.5 (4d)      → 4.5, photographed
//   D Bucatini      @ Osteria          alice · bob · cleo 4.5 (5d)                → 4.5, 3 lines, no photo
//   E Anchovy toast @ Marion (Fitzroy) cleo 5 · dan 5 (20d)                       → 5.0, only in 30 days
//   F Pad thai      @ Far (Geelong)    alice 5 · bob 4 (2.5d)                     → 4.5, Geelong
//   G Flat white    @ Corner (Fitzroy) cleo 5 · dan 5 (60d)                       → 5.0, only all time
//   R Ramen         @ Far (Geelong)    bob 4 (1d)                                 → like Pad thai; new
before(async () => {
  w = await world();
  ({ db, as, rows, error } = w);
  let n = 1;
  const v = (who, place, dish, score, days, opts) => w.visit(n++, who, place, receipt([dish, score]), ago(days), opts);
  await v(U.alice, P.tipo, 'Margherita', 5, 3);
  await v(U.bob, P.tipo, 'Margherita', 5, 2);
  await v(U.cleo, P.tipo, 'Tiramisu', 6, 1);
  await v(U.alice, P.osteria, 'Cacio e pepe', 4.5, 4, { photos: ['alice/cacio.jpg'] });
  await v(U.bob, P.osteria, 'Cacio e pepe', 4.5, 4);
  for (const who of [U.alice, U.bob, U.cleo]) await v(who, P.osteria, 'Bucatini', 4.5, 5);
  for (const who of [U.cleo, U.dan]) await v(who, P.marion, 'Anchovy toast', 5, 20);
  await v(U.alice, P.far, 'Pad thai', 5, 2.5);
  await v(U.bob, P.far, 'Pad thai', 4, 2.5);
  for (const who of [U.cleo, U.dan]) await v(who, P.hand, 'Flat white', 5, 60);
  await v(U.bob, P.far, 'Ramen', 4, 1);
  for (const [k, name] of Object.entries({ A: 'Margherita', B: 'Tiramisu', C: 'Cacio e pepe', D: 'Bucatini',
    E: 'Anchovy toast', F: 'Pad thai', G: 'Flat white', R: 'Ramen' })) {
    D[k] = (await rows(`select id from public.dishes where name = $1`, [name]))[0].id;
  }
  assert.equal((await rows(`select score::float s from public.reviews where dish_id = $1`, [D.B]))[0].s, 6);
});
after(async () => db?.close());

const K = (dish) => Object.keys(D).find((k) => D[k] === dish) ?? dish;
const topAte = async (uid, city, limit) =>
  as(uid, () => rows(`select * from public.top_ate(p_city => $1, p_limit => $2)`, [city, limit]));
const loved = async (uid, city, limit = 10) =>
  as(uid, () => rows(`select * from public.because_you_loved(p_city => $1, p_limit => $2)`, [city, limit]));
const news = async (uid, city, since, limit = 6) =>
  as(uid, () => rows(`select * from public.new_to_record(p_city => $1, p_since => $2, p_limit => $3)`, [city, since, limit]));

// ─── The Top Ate ─────────────────────────────────────────────────────────────────────────────────
test('top_ate: the last 7 days by all-time score — photographed first within a score, then orders', async () => {
  const top = await topAte(U.dan, null, 3);
  assert.deepEqual(top.map((r) => [r.rank, K(r.dish_id)]), [[1, 'A'], [2, 'C'], [3, 'D']],
    'B (one scored line) is never ranked; C beats D on the photo, D beats F (Geelong, 4.5) on orders');
  const [a, c] = top;
  assert.deepEqual({ ...a, cover_url: undefined }, {
    rank: 1, dish_id: D.A, name: 'Margherita', restaurant_id: P.tipo, restaurant_name: 'Tipo 00', suburb: 'Melbourne',
    score: '5.0', review_count: 2, cover_url: undefined, saved: false,
  });
  assert.equal(a.cover_url, null, 'no photo is null, never a filter');
  assert.match(c.cover_url, /alice\/cacio\.jpg$/);
});

test('top_ate: fewer than p_limit in 7 days widens to 30, then all time — and the window ranks together', async () => {
  const at = async (limit) => (await topAte(U.dan, 'melbourne', limit)).map((r) => K(r.dish_id));
  assert.deepEqual(await at(3), ['A', 'C', 'D'], 'three in the last 7 days: the window stays at 7');
  assert.deepEqual(await at(4), ['E', 'A', 'C', 'D'], 'widened to 30 days: E (20 days ago) ranks with A by score, not below it');
  assert.deepEqual(await at(8), ['E', 'G', 'A', 'C', 'D'], 'still short: all time');
  assert.deepEqual(await at(null), await at(8), 'p_limit defaults to 8');
  assert.deepEqual((await topAte(U.dan, 'Geelong ', 8)).map((r) => K(r.dish_id)), ['F'], 'the city is trimmed and lower-cased');
  assert.deepEqual(await topAte(U.dan, 'atlantis', 8), [], 'an unknown city is empty, not everywhere');
});

test('top_ate: saved is the viewer\'s; signed out reads the same rows with saved false; blocks count', async () => {
  await as(U.bob, () => db.query(`select public.save_dish($1)`, [D.C]));
  try {
    const bob = await topAte(U.bob, 'melbourne', 3);
    assert.deepEqual(bob.map((r) => r.saved), [false, true, false]);
    const anon = await topAte(null, 'melbourne', 3);
    assert.deepEqual(anon, bob.map((r) => ({ ...r, saved: false })), 'signed out: the browse twin');
    assert.deepEqual((await topAte(U.alice, 'melbourne', 3)).map((r) => r.saved), [false, false, false]);
  } finally {
    await as(U.bob, () => db.query(`select public.unsave_dish($1)`, [D.C]));
  }

  await as(U.alice, () => db.query(`select public.block_user($1)`, [U.bob]));
  try {
    // For alice, bob's lines are gone: A and C are one line each, D is two; nothing left in 30 days but D and E.
    assert.deepEqual((await topAte(U.alice, 'melbourne', 3)).map((r) => [K(r.dish_id), r.review_count]),
      [['E', 2], ['G', 2], ['D', 2]]);
  } finally {
    await as(U.alice, () => db.query(`select public.unblock_user($1)`, [U.bob]));
  }
});

// ─── Because you loved ───────────────────────────────────────────────────────────────────────────
test('because_you_loved: the newest 5.0-or-6 dish, and similar dishes the viewer never logged', async () => {
  const all = await loved(U.alice, null);
  assert.deepEqual(all.map((r) => [K(r.anchor_dish_id), r.anchor_name, K(r.dish_id)]), [['F', 'Pad thai', 'R']],
    'anchor = Pad thai (5, 2.5 days ago, newer than Margherita); Ramen shares noodles + Thai');
  assert.deepEqual(Object.keys(all[0]), ['anchor_dish_id', 'anchor_name', 'dish_id', 'name', 'restaurant_id',
    'restaurant_name', 'score', 'review_count', 'cover_url', 'saved']);

  // In Melbourne nothing is like Pad thai: the next-newest anchor (Margherita) takes over. Alice logged
  // Cacio e pepe and Bucatini (Italian too), so only Tiramisu is left.
  const mel = await loved(U.alice, 'melbourne');
  assert.deepEqual(mel.map((r) => [K(r.anchor_dish_id), K(r.dish_id), r.score]), [['A', 'B', '6.0']]);

  // Cleo's newest 5+ is her own 6 (Tiramisu). Margherita (5.0) outranks Cacio e pepe (4.5) at equal weight;
  // Bucatini is hers already.
  assert.deepEqual((await loved(U.cleo, null)).map((r) => [K(r.anchor_dish_id), K(r.dish_id)]), [['B', 'A'], ['B', 'C']]);
  assert.deepEqual((await loved(U.cleo, null, 1)).map((r) => K(r.dish_id)), ['A'], 'p_limit');

  await as(U.cleo, () => db.query(`select public.save_dish($1)`, [D.C]));
  try {
    assert.deepEqual((await loved(U.cleo, null)).map((r) => r.saved), [false, true]);
  } finally {
    await as(U.cleo, () => db.query(`select public.unsave_dish($1)`, [D.C]));
  }
});

test('because_you_loved: signed out, or no 5.0 yet, is empty', async () => {
  assert.deepEqual(await loved(null, null), []);
  const E = id(900);
  await db.query(`insert into auth.users (id, email) values ($1, 'eve@ate.test')`, [E]);
  await w.visit(900, E, P.tipo, receipt(['Margherita', 4.5]), ago(1));
  assert.deepEqual(await loved(E, null), [], 'a 4.5 is not loved');
});

// ─── New to the record ───────────────────────────────────────────────────────────────────────────
test('new_to_record: new 6s, new 5.0s, then first lines — others\' lines only, one row per dish', async () => {
  const since = ago(3.5);
  const dan = await news(U.dan, null, since);
  assert.deepEqual(dan.map((r) => [K(r.dish_id), r.kind]), [['B', 'six'], ['A', 'five'], ['F', 'five'], ['R', 'new']],
    'Margherita\'s 5.0 (2 days) is newer than Pad thai\'s (2.5); Eve\'s 4.5 on Margherita is not news');
  assert.deepEqual(Object.keys(dan[0]), ['dish_id', 'name', 'restaurant_name', 'suburb', 'kind', 'cover_url', 'saved', 'at']);
  assert.ok(Math.abs(new Date(dan[1].at) - new Date(ago(2))) < 60_000, 'at = the newest 5.0\'s time');
  assert.equal(dan[0].restaurant_name, 'Tipo 00');
  assert.equal(dan[0].suburb, 'Melbourne');

  // Alice: her own 5 on Pad thai is not news to her, and she wrote its first line.
  assert.deepEqual((await news(U.alice, null, since)).map((r) => [K(r.dish_id), r.kind]), [['B', 'six'], ['A', 'five'], ['R', 'new']]);
  // Cleo: her own 6 is not news either.
  assert.deepEqual((await news(U.cleo, null, since)).map((r) => [K(r.dish_id), r.kind]), [['A', 'five'], ['F', 'five'], ['R', 'new']]);

  assert.deepEqual((await news(U.dan, 'melbourne', since)).map((r) => K(r.dish_id)), ['B', 'A']);
  assert.deepEqual((await news(U.dan, null, since, 1)).map((r) => K(r.dish_id)), ['B'], 'p_limit');
  assert.deepEqual(await news(U.dan, null, new Date(Date.now() + DAY).toISOString()), [], 'nothing after tomorrow');
});

test('new_to_record: p_since null reads the last 7 days; signed out is the browse twin', async () => {
  const dan = await news(U.dan, null, null, 20);
  assert.deepEqual(dan.map((r) => [K(r.dish_id), r.kind]),
    [['B', 'six'], ['A', 'five'], ['F', 'five'], ['R', 'new'], ['C', 'new'], ['D', 'new']]);
  assert.match(dan.find((r) => r.dish_id === D.C).cover_url, /cacio\.jpg$/);
  await as(U.dan, () => db.query(`select public.save_dish($1)`, [D.A]));
  try {
    const mine = await news(U.dan, null, null, 20);
    assert.equal(mine.find((r) => r.dish_id === D.A).saved, true);
    assert.deepEqual(await news(null, null, null, 20), mine.map((r) => ({ ...r, saved: false })));
  } finally {
    await as(U.dan, () => db.query(`select public.unsave_dish($1)`, [D.A]));
  }
});

// ─── Cravings ────────────────────────────────────────────────────────────────────────────────────
test('craving_options: styles (dishes) then cuisines, busiest first, only tags on logged dishes; signed out too', async () => {
  // A dish nobody logged brings its tags nowhere.
  await as(U.dan, () => db.query(`insert into public.dishes (name, restaurant_id, created_by_user_id) values ('Burrito', $1, $2)`, [P.tipo, U.dan]));
  const opts = await as(U.bob, () => rows(`select * from public.craving_options()`));
  assert.deepEqual(Object.keys(opts[0]), ['kind', 'slug', 'label', 'group']);
  assert.deepEqual([...new Set(opts.map((o) => `${o.kind}:${o.group}`))], ['style:dishes', 'cuisine:cuisines']);
  assert.deepEqual(opts.filter((o) => o.kind === 'cuisine').map((o) => [o.slug, o.label]),
    [['italian', 'Italian'], ['thai', 'Thai'], ['wine-bar', 'Wine bar']]);
  const styles = opts.filter((o) => o.kind === 'style').map((o) => o.slug);
  assert.deepEqual(styles.slice(0, 2), ['noodles', 'pasta'], 'two dishes each, then the ones with one');
  assert.ok(!styles.includes('wraps'), 'the unlogged Burrito offers nothing');
  assert.deepEqual(await as(null, () => rows(`select * from public.craving_options()`)), opts, 'signed out: the browse twin');
});

test('set_cravings replaces the set in order; my_cravings reads it back; it is private', async () => {
  const set = (uid, body) => as(uid, () => rows(`select * from public.set_cravings($1::jsonb)`, [JSON.stringify(body)]));
  const mine = (uid) => as(uid, () => rows(`select * from public.my_cravings()`));

  const got = await set(U.alice, [{ kind: 'cuisine', slug: 'italian' }, { kind: ' Style ', slug: 'NOODLES' }, { kind: 'cuisine', slug: 'italian' }]);
  assert.deepEqual(got, [
    { kind: 'cuisine', slug: 'italian', label: 'Italian' },
    { kind: 'style', slug: 'noodles', label: 'noodles' },
  ], 'in the order sent, normalised, duplicates collapsed');
  assert.deepEqual(await mine(U.alice), got);
  assert.deepEqual(await mine(U.bob), [], 'someone else\'s set is theirs');
  assert.deepEqual(await as(U.bob, () => rows(`select * from public.user_cravings`)), [], 'RLS: owner-read');
  assert.equal((await as(U.bob, () => error(db.query(`insert into public.user_cravings (user_id, kind, slug, label) values ($1, 'style', 'pasta', 'pasta')`, [U.bob]))))?.code,
    '42501', 'no client writes: set_cravings is the only writer');

  assert.deepEqual(await set(U.alice, [{ kind: 'diet', slug: 'vg' }, { kind: 'style', slug: 'pasta', label: 'ignored' }]),
    [{ kind: 'diet', slug: 'vg', label: 'VG' }, { kind: 'style', slug: 'pasta', label: 'pasta' }], 'replaced, not merged');
  assert.deepEqual(await set(U.alice, []), [], '[] clears');

  const code = async (uid, body) => (await as(uid, () => error(db.query(`select public.set_cravings($1::jsonb)`, [body]))))?.code;
  assert.equal(await code(U.alice, JSON.stringify([{ kind: 'mood', slug: 'cosy' }])), '22023', 'unknown kind');
  assert.equal(await code(U.alice, JSON.stringify([{ kind: 'style', slug: 'unicorn' }])), '22023', 'a tag no dish carries');
  assert.equal(await code(U.alice, JSON.stringify([{ kind: 'diet', slug: 'keto' }])), '22023', 'diet is the closed set');
  assert.equal(await code(U.alice, JSON.stringify({ kind: 'style', slug: 'pasta' })), '22023', 'not an array');
  assert.equal(await code(U.alice, JSON.stringify(['pasta'])), '22023', 'not {kind, slug}');
  assert.equal(await code(U.alice, 'null'), '22023');
  assert.equal(await code(null, '[]'), '42501', 'signed out cannot set');
  assert.deepEqual(await as(null, () => rows(`select * from public.my_cravings()`)), [], 'signed out reads nothing');
});

test('set_cravings: a followed tag that empties can be re-saved under its label; delete_account takes the set', async () => {
  const E = id(900); // Eve, from above
  await as(E, () => db.query(`select public.set_cravings($1::jsonb)`, [JSON.stringify([{ kind: 'style', slug: 'coffee' }])]));
  // The only coffee dish is renamed (a merge or a fix): no dish carries "coffee" any more.
  await db.exec(`update public.dishes set name = 'Batch filter' where id = '${D.G}'`);
  assert.equal((await rows(`select count(*)::int n from public.dish_tag_links where kind = 'style' and slug = 'coffee'`))[0].n, 0);
  const again = await as(E, () => rows(`select * from public.set_cravings($1::jsonb)`, [JSON.stringify([{ kind: 'style', slug: 'coffee' }])]));
  assert.deepEqual(again, [{ kind: 'style', slug: 'coffee', label: 'coffee' }]);
  await db.exec(`update public.dishes set name = 'Flat white' where id = '${D.G}'`);

  const [{ ok }] = await as(E, () => rows(`select (public.delete_account() ->> 'ok')::boolean ok`));
  assert.equal(ok, true);
  assert.equal((await rows(`select count(*)::int n from public.user_cravings where user_id = $1`, [E]))[0].n, 0);
});

// ─── dishes_by_tag + p_city, + saved ─────────────────────────────────────────────────────────────
test('dishes_by_tag: p_city keeps a tag to one city; rows carry saved; one overload', async () => {
  const byTag = (uid, kind, slug, city) =>
    as(uid, () => rows(`select * from public.dishes_by_tag(p_kind => $1, p_slug => $2, p_city => $3)`, [kind, slug, city]));
  assert.deepEqual((await byTag(U.bob, 'cuisine', 'italian', 'melbourne')).map((r) => K(r.dish_id)), ['B', 'A', 'D', 'C']);
  assert.deepEqual(await byTag(U.bob, 'cuisine', 'italian', 'geelong'), []);
  assert.deepEqual((await byTag(U.bob, 'style', 'noodles', 'geelong')).map((r) => K(r.dish_id)), ['F', 'R']);
  assert.deepEqual(await byTag(U.bob, 'style', 'noodles', 'melbourne'), []);
  assert.deepEqual((await byTag(U.bob, 'style', 'noodles', null)).map((r) => K(r.dish_id)), ['F', 'R'], 'NULL = everywhere');

  // The round-7 call (no p_city) still binds, and each row says whether the viewer saved it.
  await as(U.bob, () => db.query(`select public.save_dish($1)`, [D.R]));
  try {
    const old = await as(U.bob, () => rows(`select dish_id, saved from public.dishes_by_tag(p_kind => 'style', p_slug => 'noodles', p_limit => 30)`));
    assert.deepEqual(old.map((r) => [K(r.dish_id), r.saved]), [['F', false], ['R', true]]);
  } finally {
    await as(U.bob, () => db.query(`select public.unsave_dish($1)`, [D.R]));
  }
  assert.equal((await rows(`select count(*)::int n from pg_proc where proname = 'dishes_by_tag' and pronamespace = 'public'::regnamespace`))[0].n, 1,
    'landmine 7: no second overload');
  assert.equal((await as(null, () => error(db.query(`select * from public.dishes_by_tag('style', 'noodles')`))))?.code, '42501',
    'still signed-in only');
});
