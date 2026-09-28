// supabase/tests/db/search_test.mjs — the Search scopes at the SQL level: places, dishes, people,
// nearby and search_all — row shape, order, accent folding and every keyset walk. Ported from the
// staging suites SearchRPCContractTests and SearchScopesContractTests (merged: they asked the same
// questions). Filters live in round4–6_test.mjs; the shelf (search_saved) in social_test.mjs.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, receipt } from './fixtures.mjs';

let w, db, as, rows;

before(async () => {
  w = await world();
  ({ db, as, rows } = w);
  await db.query(`update public.profiles set username = 'tipofan', name = 'Tipo Fan' where id = $1`, [U.dan]);
  await db.query(`update public.profiles set username = 'Tipsy', name = 'Tipsy Cleo', city = 'Fitzroy' where id = $1`, [U.cleo]);
  await w.visit(1, U.alice, P.tipo, receipt(['Tipo pizza', 4.5], ['Gnocchi', 4]), '2026-09-01T09:00:00Z');
  await w.visit(2, U.bob, P.tipo, receipt(['Tipo pizza', 3.5]), '2026-09-02T09:00:00Z');
  await w.visit(3, U.bob, P.osteria, receipt(['Pappardelle al ragù', 4], ['Tipo tiramisù']), '2026-09-03T09:00:00Z');
  await w.visit(4, U.cleo, P.far, receipt(['Tipo curry', 5]), '2026-09-04T09:00:00Z');
  await w.visit(5, U.dan, P.marion, receipt(['Tipo toast', 3]), '2026-09-05T09:00:00Z');
});
after(async () => db?.close());

const noEmptyStrings = (rs, what) => rs.forEach((r) => Object.entries(r).forEach(([k, v]) =>
  assert.notEqual(v, '', `${what}.${k} served "" where it means NULL`)));

test('search_places: tier then review_count; locality not the street; "" never; the four-part cursor walks it', async () => {
  const page = (last, size) => as(U.alice, () => rows(`select * from public.search_places(p_query => 'tipo', p_limit => $1,
    p_cursor_match_tier => $2, p_cursor_review_count => $3, p_cursor_name => $4, p_cursor_id => $5)`,
    [size, last?.match_tier ?? null, last?.review_count ?? null, last?.name ?? null, last?.restaurant_id ?? null]));
  const whole = await page(null, 20);
  assert.deepEqual(whole.map((r) => r.name), ['Tipo 00', 'Tipo Far']);
  noEmptyStrings(whole, 'search_places');
  assert.ok(whole.every((r) => r.match_tier >= 0 && r.match_tier <= 3 && !(r.locality ?? '').includes(',')));
  assert.ok(whole.every((r, i) => i === 0 || whole[i - 1].match_tier < r.match_tier
    || (whole[i - 1].match_tier === r.match_tier && whole[i - 1].review_count >= r.review_count)));
  assert.deepEqual((await w.walk((last) => page(last, 1))).map((r) => r.restaurant_id), whole.map((r) => r.restaurant_id));
});

test('search_dishes: one row per dish with its place, only dishes with a line, walked on its cursor', async () => {
  const page = (last, size) => as(U.alice, () => rows(`select * from public.search_dishes(p_query => 'tipo', p_limit => $1,
    p_cursor_match_tier => $2, p_cursor_review_count => $3, p_cursor_dish_name => $4, p_cursor_dish_id => $5)`,
    [size, last?.match_tier ?? null, last?.review_count ?? null, last?.dish_name ?? null, last?.dish_id ?? null]));
  const whole = await page(null, 20);
  assert.deepEqual(whole.map((r) => r.dish_name).sort(), ['Tipo curry', 'Tipo pizza', 'Tipo tiramisù', 'Tipo toast']);
  noEmptyStrings(whole, 'search_dishes');
  const pizza = whole.find((r) => r.dish_name === 'Tipo pizza');
  assert.deepEqual([pizza.review_count, pizza.scored_count, Number(pizza.score), pizza.restaurant_name], [2, 2, 4, 'Tipo 00']);
  assert.ok(whole.every((r) => r.review_count > 0 && r.scored_count <= r.review_count));
  assert.equal(whole.find((r) => r.dish_name === 'Tipo tiramisù').score, null, 'no scored line, no score');
  assert.deepEqual((await w.walk((last) => page(last, 1))).map((r) => r.dish_id), whole.map((r) => r.dish_id));
});

test('search folds accents in the query, never in the menu\'s spelling', async () => {
  for (const q of ['ragu', 'ragù', 'RAGU']) {
    const got = await as(U.alice, () => rows(`select dish_name from public.search_dishes(p_query => $1)`, [q]));
    assert.deepEqual(got.map((r) => r.dish_name), ['Pappardelle al ragù'], q);
  }
  const all = await as(U.alice, () => rows(`select kind, title from public.search_all(p_query => 'tiramisu', p_limit_per_kind => 8)`));
  assert.deepEqual(all, [{ kind: 'dish', title: 'Tipo tiramisù' }]);
});

test('search_people: handle, name, avatar; case-insensitive; finds me as me; the cursor walks it', async () => {
  const page = (q, last, size) => as(U.dan, () => rows(`select * from public.search_people(p_query => $1, p_limit => $2,
    p_cursor_match_tier => $3, p_cursor_username => $4, p_cursor_user_id => $5)`,
    [q, size, last?.match_tier ?? null, last?.username ?? null, last?.user_id ?? null]));
  const whole = await page('tip', null, 20);
  assert.deepEqual(whole.map((r) => r.username).sort(), ['Tipsy', 'tipofan']);
  assert.equal(whole.find((r) => r.user_id === U.dan).is_me, true);
  assert.equal(whole.find((r) => r.user_id === U.cleo).is_me, false);
  noEmptyStrings(whole, 'search_people');
  assert.deepEqual((await page('TIP', null, 20)).map((r) => r.user_id).sort(), whole.map((r) => r.user_id).sort(), 'case-insensitive');
  assert.deepEqual((await w.walk((last) => page('tip', last, 1))).map((r) => r.user_id), whole.map((r) => r.user_id));
});

test('nearby_places: distance ascending, a suburb for a label, the far place out of range, walked exactly', async () => {
  const page = (last, size) => as(U.alice, () => rows(`select * from public.nearby_places(p_lat => -37.8136, p_lng => 144.9631,
    p_radius_m => 5000, p_limit => $1, p_cursor_distance_m => $2, p_cursor_id => $3)`,
    [size, last?.distance_m ?? null, last?.restaurant_id ?? null]));
  const whole = await page(null, 20);
  assert.deepEqual(whole.map((r) => r.name), ['Tipo 00', 'Osteria Ilaria', 'Marion'], 'Geelong and the unplaced cafe are not near');
  assert.ok(whole.every((r, i) => r.distance_m >= 0 && (i === 0 || whole[i - 1].distance_m <= r.distance_m)));
  assert.ok(whole.every((r) => !(r.locality ?? '').includes(',')), 'locality is a suburb, not an address line');
  noEmptyStrings(whole, 'nearby_places');
  assert.deepEqual((await w.walk((last) => page(last, 1))).map((r) => r.restaurant_id), whole.map((r) => r.restaurant_id));
});

test('search_all keeps its two parameters and seven columns, and a place carries its locality', async () => {
  const got = await as(U.alice, () => rows(`select * from public.search_all(p_query => 'tipo', p_limit_per_kind => 8)`));
  assert.deepEqual(Object.keys(got[0]).sort(), ['detail', 'id', 'kind', 'match_rank', 'score', 'subtitle', 'title']);
  assert.ok(got.every((r) => ['place', 'dish', 'person'].includes(r.kind)));
  const place = got.find((r) => r.kind === 'place' && r.title === 'Tipo 00');
  assert.equal(place.detail.locality, 'Melbourne');
  assert.ok(!(place.subtitle ?? '').includes(' VIC '), 'never the mangled city');
  assert.ok(got.some((r) => r.kind === 'person' && r.title === 'tipofan'));
});
