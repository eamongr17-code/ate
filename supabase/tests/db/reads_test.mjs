// supabase/tests/db/reads_test.mjs — the read surface at the SQL level: entry_cards' shape and offsets,
// the place and dish pages, the You tab's numbers, and every keyset walk those pages use. Ported from
// the staging suites EntryCardsContractTests, DietTagsContractTests, DetailRPCContractTests,
// PlaceDishContractTests, StatsContractTests, YouRPCContractTests and the aggregate half of
// StagingContractTests (dish_stats / restaurant_stats) — on a dataset known row for row, so every
// walk is compared against the whole read exactly.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt, scalars } from './fixtures.mjs';

let w, db, as, rows;
const ZONE = 'Australia/Melbourne';
const PLACE_BODY = 'Dinner at Osteria Ilaria 🍝. Pappardelle al ragù 4.5, crème brûlée was a 4 and the cannoli were lovely.';

before(async () => {
  w = await world();
  ({ db, as, rows } = w);
  const A = U.alice;
  // Alice: three months of visits, a dish scored twice at the same score (sittings), an all-unscored
  // entry, a 6, and a photo.
  await w.visit(1, A, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu', 4], ['Focaccia']), '2026-07-02T09:00:00Z', { photos: [`${A}/${id(1)}-0.jpg`, `${A}/${id(1)}-1.jpg`] });
  await w.visit(2, A, P.tipo, receipt(['Gnocchi', 4.5]), '2026-08-03T09:00:00Z');
  await w.visit(3, A, P.marion, receipt(['Anchovies', 6]), '2026-08-20T09:00:00Z');
  await w.visit(4, A, P.hand, receipt(['Flat white']), '2026-09-01T01:00:00Z');
  await w.visit(5, A, P.tipo, receipt(['Gnocchi', 4], ['Tiramisu', 3.5]), '2026-09-05T09:00:00Z');
  await w.visit(6, A, P.marion, receipt(['Olives', 3.5]), '2026-09-06T09:00:00Z');
  // The accented body with a place offset and three kinds of line — the offsets test.
  const pasta = PLACE_BODY.indexOf('Pappardelle');
  const creme = PLACE_BODY.indexOf('crème');
  const cannoli = PLACE_BODY.indexOf('cannoli');
  const at = (i) => scalars(PLACE_BODY.slice(0, i));
  await w.visit(7, U.bob, P.osteria, {
    body: PLACE_BODY,
    items: [
      { dish_name: 'Pappardelle al ragù', mention_text: 'Pappardelle al ragù', mention_offset: at(pasta), score: 4.5,
        score_evidence: 'Pappardelle al ragù 4.5', evidence_offset: at(pasta), tags: [] },
      { dish_name: 'Crème brûlée', mention_text: 'crème brûlée', mention_offset: at(creme), score: 4,
        score_evidence: 'crème brûlée was a 4', evidence_offset: at(creme), tags: ['gf', 'v'] },
      { dish_name: 'Cannoli', mention_text: 'cannoli', mention_offset: at(cannoli), tags: [] },
    ],
  }, '2026-09-07T09:00:00Z', { placeQuery: 'Osteria Ilaria', placeOffset: at(PLACE_BODY.indexOf('Osteria')) });
  // Other people at Tipo, for the place page scopes and the dish page ordering.
  await w.visit(8, U.bob, P.tipo, receipt(['Gnocchi', 5], ['Tiramisu', 5], ['Tiramisu', 5]), '2026-09-08T09:00:00Z');
  await w.visit(9, U.cleo, P.tipo, receipt(['Gnocchi', 2]), '2026-09-08T09:00:00Z');
  await w.visit(10, U.dan, P.tipo, receipt(['Gnocchi', 3]), '2026-09-09T09:00:00Z');
  // A line written before entries existed: no entry_id, no photos.
  const gnocchi = await dishAt(P.tipo, 'Gnocchi');
  await db.query(`insert into public.reviews (id, reviewer_id, dish_id, score, created_at) values ($1, $2, $3, 4, '2026-06-01T00:00:00Z')`,
    [id(900), U.dan, gnocchi]);
  // A dish on the catalogue nobody has logged.
  await db.query(`insert into public.dishes (id, name, restaurant_id) values ($1, 'Never ordered', $2)`, [id(901), P.tipo]);
  // A pre-0040 placeless entry: a designed state, not an error.
  await w.legacyPlaceless(id(11), U.cleo, 'Somewhere nice, forgot the name', '2026-09-02T09:00:00Z');
});
after(async () => db?.close());

async function dishAt(place, name) {
  return (await rows(`select id from public.dishes where restaurant_id = $1 and name = $2 and merged_into_dish_id is null`, [place, name]))[0].id;
}
const num = (x) => (x == null ? null : Number(x));
const slice = (body, offset, length) => [...body].slice(offset, offset + length).join('');

// ---------------------------------------------------------------------------------------------------
// entry_cards — the one row the whole app renders
// ---------------------------------------------------------------------------------------------------
test('entry_cards: counters agree with their arrays; positions ascend; avg_score is over scored lines only', async () => {
  const cards = await as(U.cleo, () => rows(`select * from public.entry_cards order by created_at desc, id desc`));
  assert.equal(cards.length, 11);
  for (const c of cards) {
    assert.ok(c.order_number > 0);
    assert.equal(c.dish_count, c.items.length);
    assert.equal(c.photo_count, c.photos.length);
    assert.deepEqual(c.photos.map((p) => p.position), c.photos.map((p) => p.position).sort());
    assert.ok(c.items.every((i, k) => i.position >= 1 && (k === 0 || c.items[k - 1].position < i.position)));
    const scores = c.items.map((i) => i.score).filter((s) => s != null).map(Number);
    if (scores.length === 0) assert.equal(c.avg_score, null, 'no numbers is no average, not 0');
    else assert.ok(Math.abs(num(c.avg_score) - scores.reduce((a, b) => a + b, 0) / scores.length) < 0.01);
    if (c.place) {
      assert.equal(c.place.id, c.restaurant_id);
      assert.ok(c.place.name);
    }
    // Tags: an array on every line, never null, of known codes.
    for (const i of c.items) {
      assert.ok(Array.isArray(i.tags), `tags must be an array: ${JSON.stringify(i.tags)}`);
      assert.ok(i.tags.every((t) => ['gf', 'df', 'v', 'vg', 'nf'].includes(t)));
    }
  }
  assert.ok(cards.some((c) => c.items.some((i) => i.score == null)), 'an unscored line decodes');
  const placeless = cards.find((c) => c.id === id(11));
  assert.equal(placeless.place, null, 'no place is a designed state — `place` is nullable');
  assert.equal(placeless.place_offset, null);
  assert.equal(placeless.place_length, null);
  assert.deepEqual(placeless.items, []);
});

test('entry_cards: every offset is a Unicode-scalar offset that still points at what it names', async () => {
  const [c] = await as(null, () => rows(`select * from public.get_entry_card($1)`, [id(7)]));
  assert.equal(slice(c.body, c.place_offset, c.place_length), 'Osteria Ilaria');
  assert.deepEqual(c.items.map((i) => slice(c.body, i.mention_offset, i.mention_length)),
    ['Pappardelle al ragù', 'crème brûlée', 'cannoli']);
  assert.deepEqual(c.items.map((i) => i.evidence_offset == null ? null : slice(c.body, i.evidence_offset, i.evidence_length)),
    ['Pappardelle al ragù 4.5', 'crème brûlée was a 4', null]);
  // The 🍝 is one scalar and two UTF-16 units: the same number read as UTF-16 lands a character early.
  const [third] = c.items.slice(2);
  assert.notEqual(c.body.slice(third.mention_offset, third.mention_offset + third.mention_length), 'cannoli');
  assert.deepEqual(c.items[1].tags, ['gf', 'v']);
});

// ---------------------------------------------------------------------------------------------------
// The place page
// ---------------------------------------------------------------------------------------------------
test('place_summary: the header — visits are the viewer\'s, counts cover everyone, NULL never ""', async () => {
  const [mine] = await as(U.alice, () => rows(`select * from public.place_summary($1)`, [P.tipo]));
  assert.equal(mine.my_visits, 3);
  assert.equal(+mine.my_last_visit, +new Date('2026-09-05T09:00:00Z'));
  assert.equal(mine.entry_count, 6);
  assert.equal(mine.people_count, 4);
  assert.ok(mine.entry_count >= mine.my_visits);
  assert.equal(mine.locality, 'Melbourne');
  assert.ok(!mine.locality.includes(','), 'a locality chip is one place name, not an address');
  const [theirs] = await as(U.cleo, () => rows(`select my_visits, my_last_visit from public.place_summary($1)`, [P.marion]));
  assert.deepEqual(theirs, { my_visits: 0, my_last_visit: null }, 'my_visits > 0 iff my_last_visit');
  for (const place of Object.values(P)) {
    const [h] = await as(U.alice, () => rows(`select * from public.place_summary($1)`, [place]));
    for (const [k, v] of Object.entries(h)) assert.notEqual(v, '', `place_summary.${k} served "" where it means NULL`);
    if (h.avg_rating != null) assert.ok(num(h.avg_rating) > 0 && num(h.avg_rating) <= 6);
  }
});

test('restaurant_stats is the mean of per-dish averages; dish_stats keeps an unrated dish at NULL', async () => {
  const dishes = await rows(`select d.name, s.score from public.dish_stats s join public.dishes d on d.id = s.dish_id
    where s.restaurant_id = $1 order by d.name`, [P.tipo]);
  const byName = Object.fromEntries(dishes.map((d) => [d.name, num(d.score)]));
  assert.equal(byName.Focaccia, null, 'unrated is NULL, not 0');
  // Gnocchi 4.5, 4.5, 4, 5, 2, 3 + the pre-entries 4 → 27/7; Tiramisu 4, 3.5, 5, 5 → 4.4
  assert.equal(byName.Gnocchi, 3.9);
  assert.equal(byName.Tiramisu, 4.4);
  const [{ avg_rating: a }] = await rows(`select avg_rating from public.restaurant_stats where restaurant_id = $1`, [P.tipo]);
  assert.equal(num(a), 4.2, 'mean of the dish means (3.9, 4.4) — never the flat mean of the lines');
});

test('place_dishes drops never-logged dishes and walks its four-part keyset exactly', async () => {
  const page = (last, size) => as(U.alice, () => rows(`select * from public.place_dishes(p_restaurant_id => $1, p_limit => $2,
    p_cursor_review_count => $3, p_cursor_score => $4, p_cursor_dish_name => $5, p_cursor_dish_id => $6)`,
    [P.tipo, size, last?.review_count ?? null, last?.score ?? null, last?.dish_name ?? null, last?.dish_id ?? null]));
  const whole = await page(null, 50);
  assert.deepEqual(whole.map((d) => d.dish_name).sort(), ['Focaccia', 'Gnocchi', 'Tiramisu'], 'the never-ordered dish is not on the menu');
  assert.ok(whole.every((d) => d.review_count > 0 && d.people_count > 0 && d.cover_url !== ''));
  assert.ok(whole.every((d) => d.score == null || num(d.score) > 0), 'unrated is null, never 0');
  assert.deepEqual((await w.walk((last) => page(last, 1))).map((d) => d.dish_id), whole.map((d) => d.dish_id));
});

test('get_entries_at_place: the one shape, scoped mine / others, each scope walked exactly', async () => {
  const page = (scope, last, size) => as(U.alice, () => rows(`select * from public.get_entries_at_place(p_restaurant_id => $1,
    p_scope => $2, p_cursor_created_at => $3, p_cursor_id => $4, p_page_size => $5)`,
    [P.tipo, scope, last?.created_at ?? null, last?.id ?? null, size]));
  const all = await page('all', null, 50);
  assert.deepEqual(all.map((c) => c.id), [id(10), id(9), id(8), id(5), id(2), id(1)], 'created_at DESC, id DESC across the tie');
  assert.ok(all.every((c) => c.restaurant_id === P.tipo && c.place?.id === P.tipo && c.dish_count === c.items.length));
  const mine = await page('mine', null, 50);
  const others = await page('others', null, 50);
  assert.deepEqual(mine.map((c) => c.id), [id(5), id(2), id(1)]);
  assert.ok(mine.every((c) => c.is_mine) && others.every((c) => !c.is_mine));
  for (const [scope, whole] of [['all', all], ['mine', mine], ['others', others]]) {
    assert.deepEqual((await w.walk((last) => page(scope, last, 1))).map((c) => c.id), whole.map((c) => c.id), scope);
  }
});

// ---------------------------------------------------------------------------------------------------
// The dish page
// ---------------------------------------------------------------------------------------------------
test('dish_summary: counts, the score only when someone gave one, the photo stack, my last score', async () => {
  const gnocchi = await dishAt(P.tipo, 'Gnocchi');
  const [d] = await as(U.alice, () => rows(`select * from public.dish_summary($1)`, [gnocchi]));
  assert.equal(d.dish_name, 'Gnocchi');
  assert.equal(d.restaurant_id, P.tipo);
  assert.equal(d.restaurant_name, 'Tipo 00');
  assert.equal(d.review_count, 7);
  assert.equal(d.scored_count, 7);
  assert.equal(d.people_count, 4, 'people are distinct reviewers; lines are not');
  assert.equal(num(d.my_last_score), 4, 'alice\'s latest Gnocchi');
  assert.equal(d.photos[0]?.url, d.cover_url, 'the stack and the thumbnail are one derivation');
  assert.ok(d.photos.every((p) => p.url));
  assert.notEqual(d.restaurant_locality, '');
  const focaccia = await dishAt(P.tipo, 'Focaccia');
  const [f] = await as(U.alice, () => rows(`select * from public.dish_summary($1)`, [focaccia]));
  assert.equal(f.scored_count, 0);
  assert.equal(f.score, null, 'a score nobody gave is an inferred one');
  const [anon] = await as(null, () => rows(`select * from public.dish_summary($1)`, [f.dish_id]));
  assert.equal(anon.my_last_score, null);
});

test('get_dish_reviews: mine first, newest within, walked on its three-part cursor; a pre-entries line decodes', async () => {
  const gnocchi = await dishAt(P.tipo, 'Gnocchi');
  const page = (last, size) => as(U.alice, () => rows(`select * from public.get_dish_reviews(p_dish_id => $1, p_cursor_mine => $2,
    p_cursor_created_at => $3, p_cursor_id => $4, p_page_size => $5)`,
    [gnocchi, last?.is_mine ?? null, last?.created_at ?? null, last?.review_id ?? null, size]));
  const whole = await page(null, 50);
  assert.equal(whole.length, 7);
  assert.deepEqual(whole.map((r) => r.is_mine), [true, true, true, false, false, false, false], 'a stranger\'s line never sits above mine');
  for (const group of [whole.filter((r) => r.is_mine), whole.filter((r) => !r.is_mine)]) {
    assert.ok(group.every((r, i) => i === 0 || group[i - 1].created_at >= r.created_at), 'newest first inside a group');
  }
  assert.ok(whole.every((r) => r.author?.username), 'a line needs a handle');
  assert.deepEqual((await w.walk((last) => page(last, 1))).map((r) => r.review_id), whole.map((r) => r.review_id));
  const old = whole.find((r) => r.review_id === id(900));
  assert.equal(old.entry_id, null, 'entry_id is nullable on the wire');
  assert.deepEqual(old.photos, []);
});

// ---------------------------------------------------------------------------------------------------
// You, Ratings, Recap
// ---------------------------------------------------------------------------------------------------
const histogram = (uid) => as(uid, () => rows(`select score, dish_count, review_count from public.score_histogram($1)`, [uid]));
const profile = async (uid, viewer = uid) => (await as(viewer, () => rows(`select * from public.profile_summary($1)`, [uid])))[0];

test('profile_summary and score_histogram count the same lines — the You/Ratings regression', async () => {
  const p = await profile(U.alice);
  const h = await histogram(U.alice);
  assert.equal(p.is_me, true);
  assert.equal((await profile(U.alice, U.bob)).is_me, false);
  assert.equal(p.username, 'alice');
  assert.equal(p.city, null, 'absent is NULL, not an empty line under the handle');
  assert.deepEqual([p.orders, p.places, p.dishes, p.scored], [6, 3, 9, 7]);
  const scored = h.reduce((t, b) => t + b.review_count, 0);
  assert.equal(p.scored, scored);
  const mean = h.reduce((t, b) => t + num(b.score) * b.review_count, 0) / scored;
  assert.ok(Math.abs(num(p.avg_score) - mean) <= 0.01, 'avg_score is the histogram\'s mean');
  const EVE = id(999);
  await db.query(`insert into auth.users (id, email) values ($1, 'eve@ate.test')`, [EVE]);
  await w.visit(30, EVE, P.hand, receipt(['Flat white']), '2026-09-12T09:00:00Z');
  const eve = await profile(EVE);
  assert.deepEqual([eve.orders, eve.dishes, eve.scored, eve.avg_score], [1, 1, 0, null], 'no scores is no average, not 0');
});

test('score_histogram: ten half steps and the 6, zeros left in, one dish twice is one dish and two lines', async () => {
  const h = await histogram(U.alice);
  assert.deepEqual(h.map((b) => num(b.score)), [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 6]);
  assert.ok(h.every((b) => b.dish_count <= b.review_count));
  assert.ok(h.some((b) => b.review_count === 0), 'a zero bucket still arrives as a row');
  assert.deepEqual(h.find((b) => num(b.score) === 4.5), { score: h.find((b) => num(b.score) === 4.5).score, dish_count: 1, review_count: 2 });
});

test('dishes_by_score: the bar\'s lines, newest first, walked on (created_at, id); an empty bar is empty', async () => {
  const page = (score, last, size) => as(U.alice, () => rows(`select * from public.dishes_by_score(p_user_id => $1, p_score => $2,
    p_limit => $3, p_cursor_created_at => $4, p_cursor_id => $5)`, [U.alice, score, size, last?.created_at ?? null, last?.review_id ?? null]));
  const whole = await page(3.5, null, 100);
  assert.equal(whole.length, 2);
  assert.ok(whole.every((r) => num(r.score) === 3.5 && r.dish_name && r.restaurant_name && r.cover_url !== ''));
  assert.deepEqual(whole.map((r) => r.dish_name), ['Olives', 'Tiramisu'], 'newest first');
  assert.deepEqual((await w.walk((last) => page(3.5, last, 1))).map((r) => r.review_id), whole.map((r) => r.review_id));
  assert.deepEqual(await page(1, null, 10), []);
});

test('statement_months: newest first, only months with something in them, accounts for every entry, walks by month', async () => {
  const page = (last, size, tz = ZONE) => as(U.alice, () => rows(`select * from public.statement_months(p_user_id => $1, p_tz => $2,
    p_cursor_month => $3, p_limit => $4)`, [U.alice, tz, last?.month ?? null, size]));
  const whole = await page(null, 240);
  const months = whole.map((m) => m.month.toISOString().slice(0, 10));
  assert.deepEqual(months, ['2026-09-01', '2026-08-01', '2026-07-01']);
  assert.deepEqual(whole.map((m) => m.orders), [3, 2, 1], 'the 01:00Z entry on 1 Sep is 11am in Melbourne — September');
  assert.equal(whole.reduce((t, m) => t + m.orders, 0), (await profile(U.alice)).orders);
  assert.deepEqual((await w.walk((last) => page(last, 1))).map((m) => +m.month), whole.map((m) => +m.month));
  const la = await page(null, 240, 'America/Los_Angeles');
  assert.deepEqual(la.map((m) => m.orders), [2, 3, 1], 'in LA the same instant is 31 August — month boundaries are local');
});

test('monthly_statement: the receipt Recap prints, for the month asked, and never a habit of one', async () => {
  const st = async (month, tz = ZONE) => (await as(U.alice, () => rows(`select public.monthly_statement(p_user_id => $1, p_month => $2, p_tz => $3) s`,
    [U.alice, month, tz])))[0].s;
  const sep = await st('2026-09-01');
  assert.equal(sep.month, '2026-09-01');
  assert.equal(sep.username, 'alice');
  assert.equal(sep.orders, 3);
  assert.ok(sep.places <= sep.orders && sep.new_places <= sep.places);
  assert.ok(sep.top_dishes.length <= 3);
  assert.deepEqual(sep.top_dishes.map((d) => d.score), [...sep.top_dishes.map((d) => d.score)].sort((a, b) => b - a), 'best first');
  assert.ok(sep.top_dishes.every((d) => d.dish_name && d.restaurant_name && d.score != null));
  assert.ok(sep.average >= 0.5 && sep.average <= 6);
  assert.equal(sep.most_ordered, null, 'once is not a habit: nothing, not "x1"');
  assert.equal(sep.most_visited, null);
  const aug = await st('2026-08-01');
  assert.equal(aug.orders, 2);
  assert.equal((await st('2026-09-01', 'America/Los_Angeles')).month, '2026-09-01', 'the month it answers for is the month asked, in any zone');
  const jul = await st('2026-07-01');
  assert.deepEqual([jul.orders, jul.dishes], [1, 3]);
  // A habit: two visits to Tipo and Gnocchi twice in one month.
  await w.visit(20, U.dan, P.tipo, receipt(['Gnocchi', 4]), '2026-09-10T09:00:00Z');
  await w.visit(21, U.dan, P.tipo, receipt(['Gnocchi', 4.5]), '2026-09-11T09:00:00Z');
  const dan = (await as(U.dan, () => rows(`select public.monthly_statement($1, '2026-09-01') s`, [U.dan])))[0].s;
  assert.equal(dan.most_ordered?.count, 3, 'with the 9 Sep Gnocchi');
  assert.equal(dan.most_visited?.count, 3);
  assert.equal(dan.most_visited?.restaurant_name, 'Tipo 00');
});

test('get_entries_by_author: entry_cards for one author, mine when it is me, walked exactly', async () => {
  const page = (last, size) => as(U.alice, () => rows(`select * from public.get_entries_by_author(p_author_id => $1,
    p_cursor_created_at => $2, p_cursor_id => $3, p_page_size => $4)`, [U.alice, last?.created_at ?? null, last?.id ?? null, size]));
  const whole = await page(null, 50);
  assert.equal(whole.length, 6);
  assert.ok(whole.every((c) => c.author_id === U.alice && c.is_mine && c.visibility === 'public' && c.order_number > 0));
  assert.deepEqual((await w.walk((last) => page(last, 2))).map((c) => c.id), whole.map((c) => c.id));
});
