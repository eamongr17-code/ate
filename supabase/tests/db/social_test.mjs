// supabase/tests/db/social_test.mjs — the feed, saves, blocks and reports at the SQL level. Ported from
// the staging suites SocialContractTests, EntryCardsContractTests (feed + saved), the blocks half of
// AccountContractTests/AccountClientContractTests, and SearchRPCContractTests' save round trip.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, rows, error;

before(async () => {
  w = await world();
  ({ db, as, rows, error } = w);
  await db.query(`update public.profiles set name = 'Bob Builder', city = 'Melbourne', avatar_url = 'https://i.pravatar.cc/300?img=2' where id = $1`, [U.bob]);
  await w.visit(1, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu']), '2026-09-01T09:00:00Z');
  await w.visit(2, U.bob, P.tipo, receipt(['Gnocchi', 4], ['Focaccia', 3.5], ['Negroni']), '2026-09-02T09:00:00Z');
  await w.visit(3, U.bob, P.marion, receipt(['Anchovies', 5]), '2026-09-03T09:00:00Z');
  await w.visit(4, U.cleo, P.osteria, receipt(['Cannoli', 3]), '2026-09-04T09:00:00Z');
  await w.visit(5, U.cleo, P.osteria, receipt(['Cannoli', 3.5]), '2026-09-04T09:00:00Z'); // a tie on created_at
  await w.visit(6, U.dan, P.marion, receipt(['Olives', 4]), '2026-09-05T09:00:00Z');
});
after(async () => db?.close());

const feedPage = (uid, last, size, own = false) => as(uid, () => rows(`select * from public.get_entry_feed(
  p_cursor_created_at => $1, p_cursor_id => $2, p_page_size => $3, p_include_own => $4)`,
  [last?.created_at ?? null, last?.id ?? null, size, own]));
const dishOf = async (entry, position = 1) =>
  (await rows(`select dish_id from public.reviews where entry_id = $1 and entry_position = $2`, [entry, position]))[0].dish_id;
const shelf = (uid) => as(uid, () => rows(`select * from public.my_saved_dishes order by saved_at desc, dish_id desc`));
const card = async (uid, entry) => (await as(uid, () => rows(`select * from public.entry_cards where id = $1`, [entry])))[0];

// ---------------------------------------------------------------------------------------------------
// The feed
// ---------------------------------------------------------------------------------------------------
test('feed: other people\'s entries, newest first, walked in pages of 2 without a repeat or a gap', async () => {
  const whole = await feedPage(U.alice, null, 50);
  assert.deepEqual(whole.map((c) => c.id), [id(6), id(5), id(4), id(3), id(2)], 'p_include_own defaults false; id breaks the tie');
  assert.ok(whole.every((c) => c.is_mine === false && c.author_id !== U.alice));
  assert.ok(whole.every((c) => c.visibility === 'public' && c.author?.username));
  const walked = await w.walk((last) => feedPage(U.alice, last, 2));
  assert.deepEqual(walked.map((c) => c.id), whole.map((c) => c.id));
  const own = await feedPage(U.alice, null, 50, true);
  assert.equal(own.length, 6);
  assert.equal(own.find((c) => c.id === id(1)).is_mine, true);
});

test('feed: a row carries the author, the place, the dish count and the viewer\'s own save flag', async () => {
  const [c] = (await feedPage(U.alice, null, 50)).filter((x) => x.id === id(2));
  assert.equal(c.author.username, 'bob');
  assert.equal(c.place.name, 'Tipo 00');
  assert.equal(c.dish_count, c.items.length);
  assert.ok(c.items.every((i) => typeof i.saved === 'boolean'));
});

// ---------------------------------------------------------------------------------------------------
// Saves
// ---------------------------------------------------------------------------------------------------
test('save_dish lands on the shelf with its provenance, is idempotent, shows on the card, and unsave takes it off', async () => {
  const dish = await dishOf(id(2), 2); // bob's Focaccia
  await as(U.alice, () => db.query(`select public.save_dish($1, $2)`, [dish, id(2)]));
  let mine = (await shelf(U.alice)).filter((s) => s.dish_id === dish);
  assert.equal(mine.length, 1);
  assert.equal(mine[0].dish_name, 'Focaccia');
  assert.equal(mine[0].restaurant_name, 'Tipo 00');
  assert.equal(mine[0].source_entry_id, id(2), 'first provenance wins, and it is this entry');
  assert.equal(mine[0].source_user_id, U.bob);
  assert.equal(mine[0].source_username, 'bob');

  await as(U.alice, () => db.query(`select public.save_dish($1, null)`, [dish]));
  mine = (await shelf(U.alice)).filter((s) => s.dish_id === dish);
  assert.equal(mine.length, 1, 'saving again is not an error and not a second row');
  assert.equal(mine[0].source_entry_id, id(2), '…and does not move the provenance');

  assert.equal((await card(U.alice, id(2))).items.find((i) => i.dish_id === dish).saved, true);
  assert.equal((await card(U.cleo, id(2))).items.find((i) => i.dish_id === dish).saved, false, 'saved is the VIEWER\'s flag');
  assert.equal((await as(U.alice, () => rows(`select public.is_dish_saved($1) s`, [dish])))[0].s, true);
  assert.equal((await as(U.alice, () => rows(`select saved from public.dish_summary($1)`, [dish])))[0].saved, true,
    'dish_summary.saved and is_dish_saved agree');

  await as(U.alice, () => db.query(`select public.unsave_dish($1)`, [dish]));
  assert.equal((await shelf(U.alice)).some((s) => s.dish_id === dish), false);
  assert.equal((await as(U.alice, () => rows(`select public.is_dish_saved($1) s`, [dish])))[0].s, false);
});

test('save_entry_dishes saves the whole visit; unsaving each line leaves exactly what was there before', async () => {
  const first = await dishOf(id(2), 1);
  await as(U.cleo, () => db.query(`select public.save_dish($1, $2)`, [first, id(2)]));
  const n = (await as(U.cleo, () => rows(`select public.save_entry_dishes($1) n`, [id(2)])))[0].n;
  assert.equal(n, 3, 'every line of the visit (rows touched — the one already saved keeps its provenance)');
  assert.ok((await card(U.cleo, id(2))).items.every((i) => i.saved));
  const added = (await card(U.cleo, id(2))).items.map((i) => i.dish_id).filter((d) => d !== first);
  for (const d of added) await as(U.cleo, () => db.query(`select public.unsave_dish($1)`, [d]));
  assert.deepEqual((await card(U.cleo, id(2))).items.filter((i) => i.saved).map((i) => i.dish_id), [first]);
  await as(U.cleo, () => db.query(`select public.unsave_dish($1)`, [first]));
});

test('the shelf pages on (saved_at, dish_id) — search_saved walked by one is the whole list, newest first', async () => {
  const dishes = [await dishOf(id(3)), await dishOf(id(4)), await dishOf(id(6)), await dishOf(id(2), 3)];
  for (const [k, d] of dishes.entries()) {
    await as(U.alice, () => db.query(`select public.save_dish($1, null)`, [d]));
    // Two saves in one instant: dish_id breaks the tie.
    await db.query(`update public.saves set created_at = $3 where user_id = $1 and dish_id = $2`,
      [U.alice, d, k < 2 ? '2026-09-10T00:00:00Z' : `2026-09-1${k}T00:00:00Z`]);
  }
  const page = (last, size) => as(U.alice, () => rows(`select * from public.search_saved(p_query => null, p_limit => $1,
    p_cursor_saved_at => $2, p_cursor_dish_id => $3)`, [size, last?.saved_at ?? null, last?.dish_id ?? null]));
  const whole = await page(null, 50);
  assert.equal(whole.length, 4);
  assert.ok(whole.every((r, i) => i === 0 || whole[i - 1].saved_at > r.saved_at
    || (+whole[i - 1].saved_at === +r.saved_at && whole[i - 1].dish_id > r.dish_id)), 'saved_at DESC, dish_id DESC');
  assert.ok(whole.every((r) => r.cover_url === r.dish_cover_url), 'cover_url IS dish_cover_url');
  assert.deepEqual((await w.walk((last) => page(last, 1))).map((r) => r.dish_id), whole.map((r) => r.dish_id));

  const byDish = await as(U.alice, () => rows(`select dish_id from public.search_saved(p_query => 'anch')`));
  assert.deepEqual(byDish.map((r) => r.dish_id), [dishes[0]], 'a dish name narrows it');
  const byPlace = await as(U.alice, () => rows(`select restaurant_name from public.search_saved(p_query => 'osteria')`));
  assert.deepEqual(byPlace.map((r) => r.restaurant_name), ['Osteria Ilaria'], '…and so does the place it was saved at');
  for (const d of dishes) await as(U.alice, () => db.query(`select public.unsave_dish($1)`, [d]));
  assert.deepEqual(await page(null, 50), []);
});

// ---------------------------------------------------------------------------------------------------
// Reports and blocks
// ---------------------------------------------------------------------------------------------------
test('report_entry and report_profile are accepted from the signed in, refused for anon', async () => {
  const e = (await as(U.alice, () => rows(`select public.report_entry($1, 'other', null) r`, [id(3)])))[0].r;
  const p = (await as(U.alice, () => rows(`select public.report_profile($1, 'other', null) r`, [U.bob])))[0].r;
  assert.ok(e && p);
  assert.ok(await as(null, () => error(db.query(`select public.report_entry($1, 'other', null)`, [id(3)]))));
});

test('block_user removes that person from every read, both ways, until they are unblocked', async () => {
  const bobIn = async (viewer) => (await feedPage(viewer, null, 50)).some((c) => c.author_id === U.bob);
  assert.equal(await bobIn(U.alice), true);
  await as(U.alice, () => db.query(`select public.block_user($1)`, [U.bob]));

  assert.equal(await bobIn(U.alice), false, 'gone from the feed — the client never filters, it refetches');
  assert.deepEqual(await as(U.alice, () => rows(`select * from public.profile_summary($1)`, [U.bob])), [], 'no profile row');
  assert.deepEqual(await as(U.alice, () => rows(`select id from public.get_entries_by_author(p_author_id => $1)`, [U.bob])), []);
  assert.deepEqual(await as(U.alice, () => rows(`select id from public.get_entries_at_place(p_restaurant_id => $1)`, [P.tipo])),
    [{ id: id(1) }], 'bob\'s visit at Tipo is gone from the place page; alice\'s own stays');
  const gnocchi = await dishOf(id(2));
  const reviews = await as(U.alice, () => rows(`select author from public.get_dish_reviews(p_dish_id => $1)`, [gnocchi]));
  assert.ok(reviews.every((r) => r.author.id !== U.bob), 'his lines are gone from the dish page');
  assert.equal((await feedPage(U.bob, null, 50)).some((c) => c.author_id === U.alice), false, 'both ways');

  const blocks = await as(U.alice, () => rows(`select * from public.my_blocks(p_limit => 50)`));
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].blocked_id, U.bob);
  assert.equal(blocks[0].username, 'bob', 'Settings cannot draw a list of UUIDs — my_blocks names who the policy hides');
  assert.equal(blocks[0].name, 'Bob Builder');
  assert.equal(blocks[0].city, 'Melbourne');
  assert.ok(blocks[0].avatar_url);

  await as(U.alice, () => db.query(`select public.unblock_user($1)`, [U.bob]));
  assert.equal(await bobIn(U.alice), true, 'and they come back');
  assert.deepEqual(await as(U.alice, () => rows(`select * from public.my_blocks()`)), [], 'unblock removes the row');
});

test('my_blocks pages newest first on (created_at, blocked_id)', async () => {
  for (const u of [U.bob, U.cleo, U.dan]) await as(U.alice, () => db.query(`select public.block_user($1)`, [u]));
  await db.query(`update public.blocks set created_at = '2026-09-20T00:00:00Z' where blocker_id = $1 and blocked_id in ($2, $3)`, [U.alice, U.bob, U.cleo]);
  await db.query(`update public.blocks set created_at = '2026-09-21T00:00:00Z' where blocker_id = $1 and blocked_id = $2`, [U.alice, U.dan]);
  const page = (last) => as(U.alice, () => rows(`select * from public.my_blocks(p_limit => 1, p_cursor_created_at => $1, p_cursor_blocked_id => $2)`,
    [last?.created_at ?? null, last?.blocked_id ?? null]));
  const walked = await w.walk(page);
  assert.deepEqual(walked.map((b) => b.blocked_id), [U.dan, U.cleo, U.bob]);
  assert.ok(walked.every((b) => b.username));
  for (const u of [U.bob, U.cleo, U.dan]) await as(U.alice, () => db.query(`select public.unblock_user($1)`, [u]));
});
