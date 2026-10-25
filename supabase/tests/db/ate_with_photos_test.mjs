// supabase/tests/db/ate_with_photos_test.mjs — answering a tag brings the tagger's photos (0089): the
// photos, which dish each shows (and where), each line's main photo; a removed dish's photos stay
// behind; the dish page shows a shared photo once.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt, photoUrl } from './fixtures.mjs';

let w, db, as, asService, rows;

before(async () => {
  w = await world();
  ({ db, as, asService, rows } = w);
});
after(async () => db?.close());

const tag = async (entry, who) =>
  (await as(U.alice, () => rows(`select * from public.tag_ate_with($1, $2)`, [entry, who])))[0];
const prefill = async (uid, companion) =>
  (await as(uid, () => rows(`select public.ate_with_prefill($1) p`, [companion])))[0].p;
const respond = async (uid, companion, entry, items) =>
  (await as(uid, () => rows(
    `select * from public.respond_ate_with(p_companion_id => $1, p_entry_id => $2, p_items => $3::jsonb)`,
    [companion, entry, JSON.stringify(items)])))[0];
const reviewId = async (entryId, name) =>
  (await rows(`select r.id from public.reviews r join public.dishes d on d.id = r.dish_id
               where r.entry_id = $1 and d.name = $2`, [entryId, name]))[0].id;
const path = (url) => url.split('/review-photos/')[1];
/** photo_dishes as [photo path, dish name, has a box], by photo. */
const pairs = async (entryId) =>
  (await rows(`select pd.photo_url, d.name, pd.box_left is not null as boxed
               from public.photo_dishes pd
               join public.reviews r on r.id = pd.review_id
               join public.dishes d on d.id = r.dish_id
               where pd.entry_id = $1 order by pd.photo_url, d.name`, [entryId]))
    .map((x) => [path(x.photo_url), x.name, x.boxed]);
const mains = async (entryId) =>
  (await rows(`select d.name, r.photo_url from public.reviews r join public.dishes d on d.id = r.dish_id
               where r.entry_id = $1 order by r.entry_position`, [entryId]))
    .map((x) => [x.name, x.photo_url && path(x.photo_url)]);
const stamps = async (entryId) =>
  (await rows(`select photos_matched_at is not null as matched, photos_located_at is not null as located
               from public.entries where id = $1`, [entryId]))[0];

const A = `${U.alice}`;

test('kept every dish: every photo, in order, each still naming its dish', async () => {
  const E = await w.visit(1, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu', 4]), '2026-10-20T09:00:00Z',
    { photos: [`${A}/1-g.jpg`, `${A}/1-both.jpg`, `${A}/1-room.jpg`] });
  const g = await reviewId(E, 'Gnocchi');
  const t = await reviewId(E, 'Tiramisu');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb, true)`, [E, JSON.stringify([
    { review_id: g, photo_url: photoUrl(`${A}/1-g.jpg`) },
    { review_id: g, photo_url: photoUrl(`${A}/1-both.jpg`), box: [0, 0, 0.5, 1] },
    { review_id: t, photo_url: photoUrl(`${A}/1-both.jpg`), box: [0.5, 0, 1, 1] },
  ])]));

  const c = await tag(E, U.bob);
  const dishes = (await prefill(U.bob, c.companion_id)).dishes.map((d) => d.dish_id);
  const card = await respond(U.bob, c.companion_id, id(11), [{ dish_id: dishes[0], score: 4 }, { dish_id: dishes[1] }]);

  assert.deepEqual(card.photos.map((p) => [path(p.url), p.position]),
    [[`${A}/1-g.jpg`, 0], [`${A}/1-both.jpg`, 1], [`${A}/1-room.jpg`, 2]], 'the returned card carries them');
  assert.deepEqual(await pairs(id(11)), [
    [`${A}/1-both.jpg`, 'Gnocchi', true], [`${A}/1-both.jpg`, 'Tiramisu', true], [`${A}/1-g.jpg`, 'Gnocchi', false],
  ]);
  assert.deepEqual(await mains(id(11)), [['Gnocchi', `${A}/1-g.jpg`], ['Tiramisu', `${A}/1-both.jpg`]]);
  assert.deepEqual(await stamps(id(11)), { matched: true, located: true }, 'not matched again');

  // The dish page shows each photo once, from the tagger's line.
  const [gnocchiPage] = await as(U.cleo, () => rows(
    `select public.dish_photos(dish_id) photos from public.reviews where id = $1`, [g]));
  assert.deepEqual(gnocchiPage.photos.map((p) => [path(p.url), p.entry_id]),
    [[`${A}/1-g.jpg`, E], [`${A}/1-both.jpg`, E]]);
  assert.ok(gnocchiPage.photos[1].box, 'the shared plate still crops onto the dish');

  // The tagger's later edits never touch the answer.
  await as(U.alice, () => db.query(`delete from public.entry_photos where entry_id = $1 and position = 0`, [E]));
  assert.equal((await rows(`select count(*)::int n from public.entry_photos where entry_id = $1`, [id(11)]))[0].n, 3);
});

test('a removed dish keeps its photos; the kept dish brings its own', async () => {
  const E = await w.visit(2, U.alice, P.tipo, receipt(['Ragu', 4], ['Panna Cotta', 3]), '2026-10-21T09:00:00Z',
    { photos: [`${A}/2-r.jpg`, `${A}/2-p.jpg`, `${A}/2-room.jpg`] });
  const r = await reviewId(E, 'Ragu');
  const p = await reviewId(E, 'Panna Cotta');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb, true)`, [E, JSON.stringify([
    { review_id: r, photo_url: photoUrl(`${A}/2-r.jpg`) },
    { review_id: p, photo_url: photoUrl(`${A}/2-p.jpg`) },
  ])]));
  const c = await tag(E, U.cleo);
  const [ragu] = (await prefill(U.cleo, c.companion_id)).dishes.map((d) => d.dish_id);
  const card = await respond(U.cleo, c.companion_id, id(21), [{ dish_id: ragu, score: 5 }]);
  assert.deepEqual(card.photos.map((p) => [path(p.url), p.position]), [[`${A}/2-r.jpg`, 0]]);
  assert.deepEqual(await mains(id(21)), [['Ragu', `${A}/2-r.jpg`]]);
});

test('photos never matched all come, left to be matched when opened', async () => {
  const E = await w.visit(3, U.alice, P.tipo, receipt(['Focaccia'], ['Burrata', 4]), '2026-10-22T09:00:00Z',
    { photos: [`${A}/3-a.jpg`, `${A}/3-b.jpg`] });
  const c = await tag(E, U.dan);
  const [focaccia] = (await prefill(U.dan, c.companion_id)).dishes.map((d) => d.dish_id);
  const card = await respond(U.dan, c.companion_id, id(31), [{ dish_id: focaccia, score: 3 }]);
  assert.deepEqual(card.photos.map((p) => path(p.url)), [`${A}/3-a.jpg`, `${A}/3-b.jpg`]);
  assert.deepEqual(await pairs(id(31)), []);
  assert.deepEqual(await stamps(id(31)), { matched: false, located: false });
});

test('no photos: none, and nothing stamped', async () => {
  const E = await w.visit(4, U.alice, P.marion, receipt(['Olives', 4]), '2026-10-23T09:00:00Z');
  const c = await tag(E, U.bob);
  const [olives] = (await prefill(U.bob, c.companion_id)).dishes.map((d) => d.dish_id);
  const card = await respond(U.bob, c.companion_id, id(41), [{ dish_id: olives, score: 4 }]);
  assert.deepEqual(card.photos, []);
  assert.deepEqual(await stamps(id(41)), { matched: false, located: false });
});

test('the answer\'s delete leaves the tagger\'s files alone', async () => {
  const out = (await as(U.bob, () => rows(`select public.delete_entry($1) r`, [id(11)])))[0].r;
  assert.deepEqual(out.photo_paths, [], 'not Bob\'s folder, and still on Alice\'s entry');
});
