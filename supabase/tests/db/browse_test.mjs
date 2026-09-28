// supabase/tests/db/browse_test.mjs — signed-out browse (0034), every entry public (0033), the card's
// suburb (0035) and the anon RLS gate, at the SQL level. Ported from the staging suites
// BrowseContractTests, PublicEntriesContractTests, CardLocalityContractTests and the RLS half of
// StagingContractTests, so the behaviour is pinned on every PR without a network.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, rows, error;

before(async () => {
  w = await world();
  ({ db, as, rows, error } = w);
  await w.visit(1, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu']), '2026-09-01T09:00:00Z', {
    photos: [`${U.alice}/${id(1)}-0.jpg`],
  });
  await w.visit(2, U.bob, P.tipo, receipt(['Gnocchi', 4], ['Focaccia', 3.5]), '2026-09-02T09:00:00Z');
  await w.visit(3, U.bob, P.marion, receipt(['Anchovies', 5]), '2026-09-03T09:00:00Z');
  await w.visit(4, U.cleo, P.hand, receipt(['Flat white']), '2026-09-04T09:00:00Z');
  // Same timestamp twice: the id tiebreak is what keeps the keyset honest.
  await w.visit(5, U.cleo, P.osteria, receipt(['Cannoli', 3]), '2026-09-04T09:00:00Z');
});
after(async () => db?.close());

const feed = (uid, args = '') => as(uid, () => rows(`select * from public.get_entry_feed(p_page_size => 50${args})`));
const newestFirst = (rs) => rs.every((r, i) => i === 0
  || rs[i - 1].created_at > r.created_at
  || (+rs[i - 1].created_at === +r.created_at && rs[i - 1].id > r.id));

// ---------------------------------------------------------------------------------------------------
// 0034 — anon reads
// ---------------------------------------------------------------------------------------------------
test('0034: the feed answers anon with every public entry and no viewer-relative truth', async () => {
  const cards = await feed(null);
  assert.equal(cards.length, 5);
  assert.ok(cards.every((c) => c.visibility === 'public'));
  assert.ok(cards.every((c) => c.is_mine === false), 'is_mine is FALSE for anon, never null');
  assert.ok(cards.every((c) => c.items.every((i) => i.saved === false)), 'nothing is saved when nobody is looking');
  assert.ok(cards.every((c) => c.author?.username), 'a slip needs a byline');
  assert.ok(newestFirst(cards), 'created_at DESC, id DESC — the same keyset as signed in');
});

test('0034: a place page reads for anon — header, menu, entries — and no "you" rows', async () => {
  const [summary] = await as(null, () => rows(`select * from public.place_summary($1)`, [P.tipo]));
  assert.equal(summary.my_visits, 0);
  assert.equal(summary.my_last_visit, null);
  const menu = await as(null, () => rows(`select * from public.place_dishes(p_restaurant_id => $1, p_limit => 50)`, [P.tipo]));
  assert.deepEqual(menu.map((d) => d.dish_name).sort(), ['Focaccia', 'Gnocchi', 'Tiramisu']);

  const at = (scope) => as(null, () => rows(`select * from public.get_entries_at_place(p_restaurant_id => $1, p_scope => $2,
    p_cursor_created_at => null, p_cursor_id => null, p_page_size => 20)`, [P.tipo, scope]));
  const all = await at('all');
  assert.deepEqual(all.map((c) => c.id), [id(2), id(1)]);
  assert.ok(all.every((c) => c.is_mine === false && c.restaurant_id === P.tipo));
  assert.deepEqual(await at('mine'), [], 'a signed-out browser has no visits');
  assert.deepEqual((await at('others')).map((c) => c.id), all.map((c) => c.id), 'with no viewer, others is everyone');
});

test('0034: a dish page reads for anon — header, reviews — and it is not saved', async () => {
  const [{ dish_id: dish }] = await rows(`select dish_id from public.reviews where entry_id = $1 and entry_position = 1`, [id(1)]);
  const [summary] = await as(null, () => rows(`select * from public.dish_summary($1)`, [dish]));
  assert.equal(summary.dish_id, dish);
  assert.equal(summary.my_last_score, null);
  assert.equal(summary.saved, false);
  const reviews = await as(null, () => rows(`select * from public.get_dish_reviews(p_dish_id => $1, p_cursor_mine => null,
    p_cursor_created_at => null, p_cursor_id => null, p_page_size => 20)`, [dish]));
  assert.equal(reviews.length, 2, 'alice\'s and bob\'s Gnocchi');
  assert.ok(reviews.every((r) => r.is_mine === false));
  assert.equal((await as(null, () => rows(`select public.is_dish_saved($1) s`, [dish])))[0].s, false);
});

test('0034: someone\'s profile reads for anon — header and entries — and it is never "me"', async () => {
  const [summary] = await as(null, () => rows(`select * from public.profile_summary($1)`, [U.bob]));
  assert.equal(summary.user_id, U.bob);
  assert.equal(summary.is_me, false);
  assert.equal(summary.username, 'bob');
  const theirs = await as(null, () => rows(`select * from public.get_entries_by_author(p_author_id => $1,
    p_cursor_created_at => null, p_cursor_id => null, p_page_size => 20)`, [U.bob]));
  assert.deepEqual(theirs.map((c) => c.id), [id(3), id(2)]);
  assert.ok(theirs.every((c) => c.author_id === U.bob && c.is_mine === false));
});

test('RLS gate: anon reads nothing raw, and every write and search is refused', async () => {
  // The CI curl gate in SQL: a raw restaurants read is an empty 200, never an error and never rows.
  assert.deepEqual(await as(null, () => rows(`select id from public.restaurants limit 1`)), []);
  for (const t of ['entries', 'profiles', 'reviews', 'entry_cards']) {
    const got = await as(null, () => rows(`select id from public.${t} limit 1`).catch(() => []));
    assert.deepEqual(got, [], `anon must not read ${t} directly`);
  }
  const refused = async (sql, params, what) => {
    const e = await as(null, () => error(db.query(sql, params)));
    assert.ok(e, `${what} must be refused`);
  };
  await refused(`insert into public.entries (id, author_id, body, restaurant_id) values ($1, $2, 'x', $3)`, [id(90), U.bob, P.tipo], 'an anon insert');
  const [{ dish_id: dish }] = await rows(`select dish_id from public.reviews where entry_id = $1 limit 1`, [id(2)]);
  await refused(`select public.save_dish($1, $2)`, [dish, id(2)], 'an anon save');
  await refused(`select public.delete_account()`, [], 'an anon delete_account');
  await refused(`select * from public.search_places(p_query => 'tipo')`, [], 'an anon search');
  await refused(`select * from public.search_saved(p_query => null)`, [], 'an anon shelf');
});

// ---------------------------------------------------------------------------------------------------
// 0033 — every entry is public
// ---------------------------------------------------------------------------------------------------
test('0033: a shipped client\'s "Make private" PATCH succeeds, lands public, and leaves updated_at alone', async () => {
  const [before] = await rows(`select updated_at from public.entries where id = $1`, [id(1)]);
  assert.equal(await as(U.alice, () => error(db.query(`update public.entries set visibility = 'private' where id = $1`, [id(1)]))), null,
    'a 23514 here is a broken client');
  const [after] = await rows(`select visibility, updated_at from public.entries where id = $1`, [id(1)]);
  assert.equal(after.visibility, 'public', 'the trigger pins every entry public');
  assert.equal(+after.updated_at, +before.updated_at, 'a PATCH that changes nothing must not bump updated_at (the stale-offsets hint)');
  assert.equal((await as(U.alice, () => rows(`select count(*)::int n from public.entries where visibility <> 'public'`)))[0].n, 0);
});

test('0033: everything in my journal is in the global feed read with p_include_own', async () => {
  const mine = await as(U.bob, () => rows(`select id from public.get_entries_by_author(p_author_id => $1, p_page_size => 50)`, [U.bob]));
  const everyone = await feed(U.bob, ', p_include_own => true');
  assert.ok(mine.length > 0);
  assert.deepEqual(mine.filter((m) => !everyone.some((c) => c.id === m.id)), []);
  assert.ok(everyone.filter((c) => c.author_id === U.bob).every((c) => c.is_mine === true));
});

// ---------------------------------------------------------------------------------------------------
// 0035 — the card's suburb is the header's suburb
// ---------------------------------------------------------------------------------------------------
test('0035: entry_cards.place.locality is null or a suburb, never "", and equals place_summary.locality', async () => {
  for (const viewer of [U.alice, null]) {
    const cards = (await feed(viewer, ', p_include_own => true')).filter((c) => c.place);
    assert.equal(cards.length, 5);
    for (const { place } of cards) {
      assert.notEqual(place.locality, '');
      if (/ (VIC|NSW|QLD|SA|WA|TAS|NT|ACT) /.test(place.address ?? '')) assert.ok(place.locality, `${place.address} names a suburb`);
      const [header] = await as(viewer, () => rows(`select locality from public.place_summary($1)`, [place.id]));
      assert.equal(header.locality, place.locality, `${place.name}: card and header disagree`);
    }
  }
  const [hand] = await as(null, () => rows(`select * from public.place_summary($1)`, [P.hand]));
  assert.equal(hand.address, null, 'absent is NULL, never ""');
  assert.equal(hand.cuisine, null);
  assert.equal(hand.locality, 'Fitzroy', 'no address: the typed suburb is the locality');
});
