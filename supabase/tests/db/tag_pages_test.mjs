// supabase/tests/db/tag_pages_test.mjs — 0057, the category (tag) page: new_to_record and get_entry_feed
// with a tag, and my_taste_tags. Filter on, filter off (= the old call, row for row), signed out.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, receipt } from './fixtures.mjs';

let w, db, as, rows, error;
const D = {};
const E = {};
const DAY = 86_400_000;
const ago = (days) => new Date(Date.now() - days * DAY).toISOString();

// Tags (0053's derivation): Margherita style pizza · Cacio e pepe style pasta · Tiramisu style dessert —
// all cuisine italian (Tipo, Osteria). Ramen style noodles + soup, cuisine thai (Far, Geelong).
// Anchovy toast style seafood + bread, cuisine wine-bar (Marion).
//   alice: Margherita 5 (3d) · Cacio e pepe 4.5 (4d) · Ramen 4 (1d)
//   bob:   Tiramisu 6 (1d) · Ramen 4.5 (2d) · Anchovy toast 3 (2d)
//   cleo:  Margherita 4 (1.5d)
//   dan:   nothing — the reader.
before(async () => {
  w = await world();
  ({ db, as, rows, error } = w);
  let n = 1;
  const v = async (key, who, place, dish, score, days) => {
    E[key] = await w.visit(n++, who, place, receipt([dish, score]), ago(days));
  };
  await v('aMarg', U.alice, P.tipo, 'Margherita', 5, 3);
  await v('aCacio', U.alice, P.osteria, 'Cacio e pepe', 4.5, 4);
  await v('aRamen', U.alice, P.far, 'Ramen', 4, 1);
  await v('bTira', U.bob, P.tipo, 'Tiramisu', 6, 1);
  await v('bRamen', U.bob, P.far, 'Ramen', 4.5, 2);
  await v('bToast', U.bob, P.marion, 'Anchovy toast', 3, 2);
  await v('cMarg', U.cleo, P.tipo, 'Margherita', 4, 1.5);
  for (const [k, name] of Object.entries({ marg: 'Margherita', cacio: 'Cacio e pepe', tira: 'Tiramisu', ramen: 'Ramen', toast: 'Anchovy toast' })) {
    D[k] = (await rows(`select id from public.dishes where name = $1`, [name]))[0].id;
  }
});
after(async () => db?.close());

const K = (dish) => Object.keys(D).find((k) => D[k] === dish) ?? dish;
const EK = (entry) => Object.keys(E).find((k) => E[k] === entry) ?? entry;

// ─── new_to_record ──────────────────────────────────────────────────────────────────────────────
const news = (uid, args) => as(uid, () => rows(`select * from public.new_to_record(p_since => now() - interval '30 days'${args})`));

test('new_to_record: no tag = the old call, row for row', async () => {
  const old = await news(U.dan, '');
  assert.deepEqual(await news(U.dan, `, p_kind => null, p_slug => null`), old);
  assert.deepEqual(old.map((r) => [K(r.dish_id), r.kind]),
    [['tira', 'six'], ['marg', 'five'], ['toast', 'new'], ['ramen', 'new'], ['cacio', 'new']]);
  // positional, the 0055 shape, still binds
  assert.deepEqual(await as(U.dan, () => rows(`select * from public.new_to_record(null, now() - interval '30 days', 6)`)), old);
});

test('new_to_record: a tag keeps only the dishes carrying it — stored kinds, any case', async () => {
  const tagged = async (kind, slug, extra = '') =>
    (await news(U.dan, `, p_kind => '${kind}', p_slug => '${slug}'${extra}`)).map((r) => [K(r.dish_id), r.kind]);
  assert.deepEqual(await tagged('cuisine', 'italian'), [['tira', 'six'], ['marg', 'five'], ['cacio', 'new']]);
  assert.deepEqual(await tagged(' Style ', 'PIZZA'), [['marg', 'five']]);
  assert.deepEqual(await tagged('style', 'noodles'), [['ramen', 'new']]);
  assert.deepEqual(await tagged('style', 'noodles', `, p_city => 'melbourne'`), [], 'the tag and the city both hold');
  assert.deepEqual(await tagged('style', 'no-such-tag'), [], 'an unknown slug is empty, not everything');
});

test('new_to_record: half a tag or an unknown kind is 22023', async () => {
  assert.equal((await error(news(U.dan, `, p_kind => 'style'`)))?.code, '22023');
  assert.equal((await error(news(U.dan, `, p_slug => 'pizza'`)))?.code, '22023');
  assert.equal((await error(news(U.dan, `, p_kind => 'mood', p_slug => 'cosy'`)))?.code, '22023');
});

test('new_to_record: signed out, the browse twin honours the tag (saved false)', async () => {
  await as(U.dan, () => db.query(`select public.save_dish($1)`, [D.marg]));
  try {
    const dan = await news(U.dan, `, p_kind => 'cuisine', p_slug => 'italian'`);
    assert.deepEqual(dan.map((r) => r.saved), [false, true, false]);
    assert.deepEqual(await news(null, `, p_kind => 'cuisine', p_slug => 'italian'`), dan.map((r) => ({ ...r, saved: false })));
    assert.deepEqual(await news(null, ''), (await news(U.dan, '')).map((r) => ({ ...r, saved: false })), 'no tag, signed out: unchanged');
  } finally {
    await as(U.dan, () => db.query(`select public.unsave_dish($1)`, [D.marg]));
  }
});

// ─── get_entry_feed ─────────────────────────────────────────────────────────────────────────────
const feed = async (uid, args = '') =>
  (await as(uid, () => rows(`select id, created_at from public.get_entry_feed(p_page_size => 50${args})`)));

test('get_entry_feed: no tag = the old call; a tag keeps entries with a line on a tagged dish', async () => {
  const old = await feed(U.dan);
  assert.deepEqual(await feed(U.dan, `, p_kind => null, p_slug => null`), old);
  assert.equal(old.length, 7);
  assert.deepEqual((await feed(U.dan, `, p_kind => 'style', p_slug => 'pizza'`)).map((r) => EK(r.id)), ['cMarg', 'aMarg']);
  assert.deepEqual((await feed(U.dan, `, p_kind => 'cuisine', p_slug => 'italian'`)).map((r) => EK(r.id)),
    ['bTira', 'cMarg', 'aMarg', 'aCacio'], 'newest first, as ever');
  assert.deepEqual((await feed(U.dan, `, p_kind => 'style', p_slug => 'noodles', p_city => 'geelong'`)).map((r) => EK(r.id)),
    ['aRamen', 'bRamen']);
  assert.deepEqual(await feed(U.dan, `, p_kind => 'style', p_slug => 'noodles', p_city => 'melbourne'`), []);
  assert.deepEqual(await feed(U.dan, `, p_kind => 'style', p_slug => 'no-such-tag'`), []);
  assert.equal((await error(feed(U.dan, `, p_kind => 'style'`)))?.code, '22023');
  // own entries follow p_include_own, tag or not
  assert.deepEqual((await feed(U.alice, `, p_kind => 'style', p_slug => 'pizza'`)).map((r) => EK(r.id)), ['cMarg']);
  assert.deepEqual((await feed(U.alice, `, p_kind => 'style', p_slug => 'pizza', p_include_own => true`)).map((r) => EK(r.id)), ['cMarg', 'aMarg']);
});

test('get_entry_feed: the keyset pages a tagged feed exactly as an untagged one', async () => {
  const tag = `, p_kind => 'cuisine', p_slug => 'italian'`;
  const all = await feed(U.dan, tag);
  const seen = [];
  let cursor = '';
  for (;;) {
    const page = await as(U.dan, () => rows(`select id, created_at from public.get_entry_feed(p_page_size => 1${cursor}${tag})`));
    if (!page.length) break;
    seen.push(page[0].id);
    cursor = `, p_cursor_created_at => '${page[0].created_at.toISOString()}', p_cursor_id => '${page[0].id}'`;
  }
  assert.deepEqual(seen, all.map((r) => r.id));
});

test('get_entry_feed: signed out, the browse twin honours the tag', async () => {
  const tag = `, p_kind => 'style', p_slug => 'pizza'`;
  assert.deepEqual((await feed(null, tag)).map((r) => EK(r.id)), ['cMarg', 'aMarg']);
  assert.deepEqual((await feed(null)).map((r) => r.id), (await feed(U.dan)).map((r) => r.id), 'no tag, signed out: unchanged');
  const card = await as(null, () => rows(`select is_mine from public.get_entry_feed(p_page_size => 5${tag})`));
  assert.ok(card.every((c) => c.is_mine === false));
});

// ─── my_taste_tags ──────────────────────────────────────────────────────────────────────────────
const taste = (uid, args = '') => as(uid, () => rows(`select * from public.my_taste_tags(${args})`));

test('my_taste_tags: 4.5+ lines (a 5.0/6 double) and saves, by weight — below 4.5 says nothing', async () => {
  await as(U.alice, () => db.query(`select public.save_dish($1)`, [D.tira]));
  try {
    // Margherita 5 → pizza 2, italian 2 · Cacio 4.5 → pasta 1, italian 1 · saved Tiramisu → dessert 1, italian 1.
    // Ramen 4 counts for nothing.
    assert.deepEqual(await taste(U.alice), [
      { kind: 'cuisine', slug: 'italian', label: 'Italian', weight: 4 },
      { kind: 'style', slug: 'pizza', label: 'pizza', weight: 2 },
      { kind: 'style', slug: 'dessert', label: 'dessert', weight: 1 },
      { kind: 'style', slug: 'pasta', label: 'pasta', weight: 1 },
    ]);
    assert.deepEqual((await taste(U.alice, `p_limit => 1`)).map((r) => r.slug), ['italian']);
    assert.deepEqual(await taste(U.alice, `p_city => 'geelong'`), [], 'the city holds: nothing 4.5+ or saved in Geelong');
  } finally {
    await as(U.alice, () => db.query(`select public.unsave_dish($1)`, [D.tira]));
  }
  // bob: Tiramisu 6 → dessert 2, italian 2 · Ramen 4.5 → noodles, soup, thai 1 · Anchovy toast 3 → nothing
  assert.deepEqual((await taste(U.bob)).map((r) => [r.slug, r.weight]),
    [['dessert', 2], ['italian', 2], ['noodles', 1], ['soup', 1], ['thai', 1]]);
  assert.deepEqual((await taste(U.bob, `p_city => 'geelong'`)).map((r) => r.slug), ['noodles', 'soup', 'thai']);
  assert.deepEqual(await taste(U.dan), [], 'nothing logged, nothing saved');
});

test('my_taste_tags: a tag already followed as a craving is left out', async () => {
  await as(U.bob, () => rows(`select * from public.set_cravings($1::jsonb)`, [JSON.stringify([{ kind: 'cuisine', slug: 'italian' }])]));
  try {
    assert.deepEqual((await taste(U.bob)).map((r) => r.slug), ['dessert', 'noodles', 'soup', 'thai']);
  } finally {
    await as(U.bob, () => rows(`select * from public.set_cravings('[]'::jsonb)`));
  }
});

test('my_taste_tags: signed out is []', async () => {
  assert.deepEqual(await taste(null), []);
});
