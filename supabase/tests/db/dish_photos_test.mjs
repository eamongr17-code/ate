// supabase/tests/db/dish_photos_test.mjs — when you ate it, and which photo is which dish (0063).
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, photoUrl, receipt } from './fixtures.mjs';

let w, db, as, asService, rows, error;
after(async () => db?.close());

const code = async (fn) => (await error(fn()))?.code ?? null;
const lines = async (entryId) =>
  rows(`select d.name, r.photo_url, r.photo_picked_at is not null as picked
        from public.reviews r join public.dishes d on d.id = r.dish_id
        where r.entry_id = $1 order by r.entry_position`, [entryId]);
const reviewId = async (entryId, name) =>
  (await rows(`select r.id from public.reviews r join public.dishes d on d.id = r.dish_id
               where r.entry_id = $1 and d.name = $2`, [entryId, name]))[0].id;

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
});

test('set_entry_date: the author moves the day; nobody else, never into the future', async () => {
  const e = await w.visit(1, U.alice, P.tipo, receipt(['Gnocchi', 4.5]), '2026-10-13T09:00:00Z');
  await as(U.alice, () => db.query(`select public.set_entry_date($1, $2)`, [e, '2026-10-11T19:30:00Z']));
  const [row] = await rows(`select created_at from public.entries where id = $1`, [e]);
  assert.equal(new Date(row.created_at).toISOString(), '2026-10-11T19:30:00.000Z');

  assert.equal(await code(() => as(U.bob, () => db.query(`select public.set_entry_date($1, now())`, [e]))), 'P0002');
  assert.equal(await code(() => as(U.alice, () => db.query(
    `select public.set_entry_date($1, now() + interval '3 days')`, [e]))), '22023');
  assert.equal(await code(() => as(null, () => db.query(`select public.set_entry_date($1, now())`, [e]))), '42501');
});

test('apply_photo_matches: each line gets its own photo; a photo not on the entry is ignored', async () => {
  const e = await w.visit(2, U.alice, P.tipo, receipt(['Tagliatelle', 4.5], ['Tiramisu', 3], ['Prawn Spaghetti']),
    undefined, { photos: ['a/1.jpg', 'a/2.jpg', 'a/3.jpg'] });
  const t = await reviewId(e, 'Tagliatelle');
  const s = await reviewId(e, 'Tiramisu');
  const p = await reviewId(e, 'Prawn Spaghetti');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb)`, [e, JSON.stringify([
    { review_id: t, photo_url: photoUrl('a/1.jpg') },
    { review_id: s, photo_url: photoUrl('a/3.jpg') },
    { review_id: p, photo_url: photoUrl('elsewhere.jpg') },
  ])]));
  assert.deepEqual((await lines(e)).map((l) => [l.name, l.photo_url]), [
    ['Tagliatelle', photoUrl('a/1.jpg')],
    ['Tiramisu', photoUrl('a/3.jpg')],
    ['Prawn Spaghetti', null],
  ]);
  const [entry] = await rows(`select photos_matched_at from public.entries where id = $1`, [e]);
  assert.ok(entry.photos_matched_at);

  // The cover read prefers the line's own photo (0026): the tiramisu is no longer the pasta.
  const [cover] = await rows(`select public.dish_cover_url(dish_id) url from public.reviews where id = $1`, [s]);
  assert.equal(cover.url, photoUrl('a/3.jpg'));

  // Not the author's, and not anyone signed in: service role only.
  assert.ok(await code(() => as(U.alice, () => db.query(`select public.apply_photo_matches($1, '[]'::jsonb)`, [e]))));
});

test('set_review_photo: the author pick moves the photo, survives a later match, and No dish clears it', async () => {
  const e = id(2);
  const t = await reviewId(e, 'Tagliatelle');
  const s = await reviewId(e, 'Tiramisu');
  const p = await reviewId(e, 'Prawn Spaghetti');

  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('a/1.jpg'), p]));
  let got = await lines(e);
  assert.deepEqual(got.map((l) => [l.name, l.photo_url, l.picked]), [
    ['Tagliatelle', null, true],
    ['Tiramisu', photoUrl('a/3.jpg'), false],
    ['Prawn Spaghetti', photoUrl('a/1.jpg'), true],
  ]);

  // A later match only moves lines nobody picked, and never hands out a picked photo.
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb)`, [e, JSON.stringify([
    { review_id: t, photo_url: photoUrl('a/2.jpg') },
    { review_id: p, photo_url: photoUrl('a/2.jpg') },
    { review_id: s, photo_url: photoUrl('a/1.jpg') },
  ])]));
  got = await lines(e);
  assert.deepEqual(got.map((l) => [l.name, l.photo_url]), [
    ['Tagliatelle', null],
    ['Tiramisu', null],
    ['Prawn Spaghetti', photoUrl('a/1.jpg')],
  ]);

  // No dish.
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, null)`, [e, photoUrl('a/1.jpg')]));
  assert.equal((await lines(e)).find((l) => l.name === 'Prawn Spaghetti').photo_url, null);

  assert.equal(await code(() => as(U.bob, () => db.query(`select public.set_review_photo($1, $2, $3)`,
    [e, photoUrl('a/2.jpg'), t]))), 'P0002');
  assert.equal(await code(() => as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`,
    [e, photoUrl('nope.jpg'), t]))), '22023');
});

test('a photo removed from the entry leaves the line that had it, open to matching again', async () => {
  const e = await w.visit(3, U.alice, P.tipo, receipt(['Gnocchi', 4], ['Cannoli']), undefined,
    { photos: ['b/1.jpg', 'b/2.jpg'] });
  const c = await reviewId(e, 'Cannoli');
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('b/2.jpg'), c]));
  await as(U.alice, () => db.query(`delete from public.entry_photos where entry_id = $1 and position = 1`, [e]));
  const cannoli = (await lines(e)).find((l) => l.name === 'Cannoli');
  assert.equal(cannoli.photo_url, null);
  assert.equal(cannoli.picked, false);
});

test('reordering photos keeps every pairing; a photo overwritten in place is pruned', async () => {
  const e = await w.visit(4, U.alice, P.tipo, receipt(['Gnocchi', 4], ['Cannoli']), undefined,
    { photos: ['s/1.jpg', 's/2.jpg'] });
  const c = await reviewId(e, 'Cannoli');
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('s/1.jpg'), c]));
  // The edit's own order: position 0 takes s/2, then position 1 takes s/1 — two requests.
  const put = (pos, path) => as(U.alice, () => db.query(
    `update public.entry_photos set photo_url = $2 where entry_id = $1 and position = $3`, [e, photoUrl(path), pos]));
  await put(0, 's/2.jpg');
  await put(1, 's/1.jpg');
  let cannoli = (await lines(e)).find((l) => l.name === 'Cannoli');
  assert.equal(cannoli.photo_url, photoUrl('s/1.jpg'));
  assert.equal(cannoli.picked, true);

  // s/1 replaced outright by s/3: the sweep clears the line and opens it to matching again.
  await put(1, 's/3.jpg');
  assert.equal(await asService(() => db.query(`select public.prune_photo_pairs($1)`, [e])).then(() => 1), 1);
  cannoli = (await lines(e)).find((l) => l.name === 'Cannoli');
  assert.equal(cannoli.photo_url, null);
  assert.equal(cannoli.picked, false);
  assert.ok(await code(() => as(U.alice, () => db.query(`select public.prune_photo_pairs($1)`, [e]))));
});


test('a hand pick outlives a re-sort; a No-dish photo stays out of matching (0064)', async () => {
  const r = receipt(['Gnocchi', 4], ['Cannoli'], ['Spritz']);
  const e = await w.visit(5, U.alice, P.tipo, r, undefined, { photos: ['r/1.jpg', 'r/2.jpg', 'r/3.jpg'] });
  const c = await reviewId(e, 'Cannoli');
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('r/1.jpg'), c]));
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, null)`, [e, photoUrl('r/3.jpg')]));
  const [entry] = await rows(`select photo_picks from public.entries where id = $1`, [e]);
  assert.deepEqual(entry.photo_picks, { [photoUrl('r/1.jpg')]: 'cannoli', [photoUrl('r/3.jpg')]: null });

  // The words are edited and re-sorted: every line is rebuilt, the pick with it.
  await w.sortAs(e, P.tipo, r.items);
  assert.equal((await lines(e)).find((l) => l.name === 'Cannoli').photo_url, null);

  // A stale match gave the pick's photo to another dish; match-photos restores before it asks.
  const g = await reviewId(e, 'Gnocchi');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb)`, [e, JSON.stringify([
    { review_id: g, photo_url: photoUrl('r/1.jpg') },
  ])]));
  await asService(() => db.query(`select public.restore_photo_picks($1)`, [e]));
  const got = await lines(e);
  assert.deepEqual(got.map((l) => [l.name, l.photo_url, l.picked]), [
    ['Gnocchi', null, false],
    ['Cannoli', photoUrl('r/1.jpg'), true],
    ['Spritz', null, false],
  ]);

  // Picking the same dish again moves the pick; a photo leaving the entry drops its pick.
  const c2 = await reviewId(e, 'Cannoli');
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('r/2.jpg'), c2]));
  await as(U.alice, () => db.query(`delete from public.entry_photos where entry_id = $1 and position = 2`, [e]));
  await asService(() => db.query(`select public.restore_photo_picks($1)`, [e]));
  const [kept] = await rows(`select photo_picks from public.entries where id = $1`, [e]);
  assert.deepEqual(kept.photo_picks, { [photoUrl('r/2.jpg')]: 'cannoli' });

  assert.ok(await code(() => as(U.alice, () => db.query(`select public.restore_photo_picks($1)`, [e]))));
});

test('restore keeps one photo per line: two lines with one dish name, and a renamed picked line (QA, #155)', async () => {
  // Two lines that end up with the same dish each keep the photo picked for them.
  const r = receipt(['Gnocchi', 4], ['Spritz']);
  const e = await w.visit(6, U.alice, P.tipo, r, undefined, { photos: ['d/1.jpg', 'd/2.jpg'] });
  const first = await reviewId(e, 'Gnocchi');
  const second = await reviewId(e, 'Spritz');
  await as(U.alice, () => db.query(`select public.correct_entry_dish(p_review_id => $1, p_dish_name => 'Gnocchi')`,
    [second]));
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('d/1.jpg'), first]));
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('d/2.jpg'), second]));
  await asService(() => db.query(`select public.restore_photo_picks($1)`, [e]));
  const held = await rows(`select id, photo_url from public.reviews where entry_id = $1`, [e]);
  assert.equal(held.find((x) => x.id === first).photo_url, photoUrl('d/1.jpg'));
  assert.equal(held.find((x) => x.id === second).photo_url, photoUrl('d/2.jpg'));

  // A picked line renamed by the author keeps its photo through a re-sort; the rebuilt line under
  // the old name does not get it too.
  const r2 = receipt(['Cannoli'], ['Gnocchi', 4]);
  const e2 = await w.visit(7, U.alice, P.tipo, r2, undefined, { photos: ['t/1.jpg', 't/2.jpg'] });
  const cannoli = await reviewId(e2, 'Cannoli');
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e2, photoUrl('t/1.jpg'), cannoli]));
  await as(U.alice, () => db.query(`select public.correct_entry_dish(p_review_id => $1, p_dish_name => 'Tiramisu')`,
    [cannoli]));
  const resorted = receipt(['Tiramisu'], ['Cannoli'], ['Gnocchi', 4]);
  await w.sortAs(e2, P.tipo, resorted.items);
  await asService(() => db.query(`select public.restore_photo_picks($1)`, [e2]));
  const got = await lines(e2);
  assert.deepEqual(got.filter((l) => l.photo_url === photoUrl('t/1.jpg')).map((l) => l.name), ['Tiramisu']);
});
