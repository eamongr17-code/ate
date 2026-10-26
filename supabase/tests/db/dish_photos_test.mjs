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

/** photo_dishes (0081) as [photo path, dish name], by photo. */
const pairs = async (entryId) =>
  (await rows(`select pd.photo_url, d.name
               from public.photo_dishes pd
               join public.reviews r on r.id = pd.review_id
               join public.dishes d on d.id = r.dish_id
               where pd.entry_id = $1 order by pd.photo_url, d.name`, [entryId]))
    .map((x) => [x.photo_url.split('/review-photos/')[1], x.name]);

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

  // A second photo of the same dish is that dish too (0081); a photo leaving the entry drops its pick.
  const c2 = await reviewId(e, 'Cannoli');
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('r/2.jpg'), c2]));
  await as(U.alice, () => db.query(`delete from public.entry_photos where entry_id = $1 and position = 2`, [e]));
  await asService(() => db.query(`select public.restore_photo_picks($1)`, [e]));
  const [kept] = await rows(`select photo_picks from public.entries where id = $1`, [e]);
  assert.deepEqual(kept.photo_picks, { [photoUrl('r/1.jpg')]: 'cannoli', [photoUrl('r/2.jpg')]: 'cannoli' });
  assert.deepEqual(await pairs(e), [['r/1.jpg', 'Cannoli'], ['r/2.jpg', 'Cannoli']]);

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

test('a dish with no photo of its own never shows another dish of the entry (0079)', async () => {
  // Two dishes, one photo, matched to the pad thai: the soup has no photo anywhere.
  const e = await w.visit(20, U.alice, P.tipo, receipt(['Pad Thai', 4], ['Chicken Soup', 5]), undefined,
    { photos: ['n/1.jpg'] });
  const pad = await reviewId(e, 'Pad Thai');
  const soup = await reviewId(e, 'Chicken Soup');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb)`,
    [e, JSON.stringify([{ review_id: pad, photo_url: photoUrl('n/1.jpg') }])]));
  const read = async (rid) => (await as(U.bob, () => db.query(
    `select public.dish_cover_url(dish_id) cover, public.dish_photos(dish_id) photos,
            public.list_item_photo(entry_id, dish_id) item
     from public.reviews where id = $1`, [rid]))).rows[0];
  const soupRead = await read(soup);
  assert.equal(soupRead.cover, null);
  assert.deepEqual(soupRead.photos, []);
  assert.equal(soupRead.item, null);
  assert.equal((await read(pad)).cover, photoUrl('n/1.jpg'));

  // Before any match ran, neither line of a two-dish entry borrows the photo.
  const e2 = await w.visit(21, U.alice, P.tipo, receipt(['Larb', 4], ['Som Tum', 3]), undefined,
    { photos: ['n/2.jpg'] });
  assert.equal((await read(await reviewId(e2, 'Som Tum'))).cover, null);

  // One line, never matched: the entry's photo is that dish's — unless the author said No dish.
  const e3 = await w.visit(22, U.alice, P.tipo, receipt(['Khao Soi', 4.5]), undefined, { photos: ['n/3.jpg'] });
  const k = await reviewId(e3, 'Khao Soi');
  assert.equal((await read(k)).cover, photoUrl('n/3.jpg'));
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, null)`, [e3, photoUrl('n/3.jpg')]));
  assert.equal((await read(k)).cover, null);
});

test('a one-dish entry\'s photo of the people is not the dish once matched (0096)', async () => {
  // Photo 1 is the table of friends, photo 2 the pasta: the matcher pairs only the pasta.
  const e = await w.visit(38, U.alice, P.tipo, receipt(['Cacio e Pepe', 4.5]), undefined,
    { photos: ['f/1.jpg', 'f/2.jpg'] });
  const c = await reviewId(e, 'Cacio e Pepe');
  const cover = async () => (await as(U.bob, () => db.query(
    `select public.dish_cover_url(dish_id) cover, public.dish_photos(dish_id) photos from public.reviews where id = $1`,
    [c]))).rows[0];
  assert.equal((await cover()).cover, photoUrl('f/1.jpg'), 'before any match, the only line borrows the first photo');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb, true)`,
    [e, JSON.stringify([{ review_id: c, photo_url: photoUrl('f/2.jpg') }])]));
  assert.deepEqual(await pairs(e), [['f/2.jpg', 'Cacio e Pepe']]);
  const read = await cover();
  assert.equal(read.cover, photoUrl('f/2.jpg'));
  assert.deepEqual(read.photos.map((p) => p.url), [photoUrl('f/2.jpg')]);

  // Every photo of people: matched to nothing, so the dish has no photo at all.
  const e2 = await w.visit(39, U.alice, P.tipo, receipt(['Negroni', 4]), undefined, { photos: ['f/3.jpg'] });
  const n = await reviewId(e2, 'Negroni');
  await asService(() => db.query(`select public.apply_photo_matches($1, '[]'::jsonb, true)`, [e2]));
  const [none] = (await as(U.bob, () => db.query(
    `select public.dish_cover_url(dish_id) cover, public.dish_photos(dish_id) photos from public.reviews where id = $1`,
    [n]))).rows;
  assert.equal(none.cover, null);
  assert.deepEqual(none.photos, []);
  // The visit still shows it.
  const [card] = (await as(U.bob, () => db.query(`select photos from public.entry_cards where id = $1`, [e2]))).rows;
  assert.deepEqual(card.photos.map((p) => p.url), [photoUrl('f/3.jpg')]);
});

test('two photos of one dish are both that dish (0081)', async () => {
  // Paris's noodle soup: one dish, two photos. Both are the soup, the first is its cover.
  const e = await w.visit(30, U.alice, P.tipo, receipt(['Egg Noodle Soup', 4.5]), undefined,
    { photos: ['m/1.jpg', 'm/2.jpg'] });
  const soup = await reviewId(e, 'Egg Noodle Soup');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb)`, [e, JSON.stringify([
    { review_id: soup, photo_url: photoUrl('m/2.jpg') },
    { review_id: soup, photo_url: photoUrl('m/1.jpg') },
  ])]));
  assert.deepEqual(await pairs(e), [['m/1.jpg', 'Egg Noodle Soup'], ['m/2.jpg', 'Egg Noodle Soup']]);
  assert.equal((await lines(e))[0].photo_url, photoUrl('m/1.jpg'));

  // Anyone who can see the entry reads the pairs; the dish page shows both, cover first.
  const seen = await as(U.bob, () => db.query(`select photo_url from public.photo_dishes where entry_id = $1`, [e]));
  assert.equal(seen.rows.length, 2);
  const [d] = await as(U.bob, () => db.query(
    `select public.dish_cover_url(dish_id) cover, public.dish_photos(dish_id) photos from public.reviews where id = $1`,
    [soup])).then((r) => r.rows);
  assert.equal(d.cover, photoUrl('m/1.jpg'));
  assert.deepEqual(d.photos.map((p) => p.url), [photoUrl('m/1.jpg'), photoUrl('m/2.jpg')]);

  // Nobody writes the table directly.
  assert.ok(await code(() => as(U.alice, () => db.query(
    `insert into public.photo_dishes (entry_id, photo_url, review_id) values ($1, $2, $3)`,
    [e, photoUrl('m/1.jpg'), soup]))));
});

test('multi-dish: a dish takes several photos; No dish and a deleted photo leave (0081)', async () => {
  const e = await w.visit(31, U.alice, P.tipo, receipt(['Larb', 4], ['Som Tum', 3]), undefined,
    { photos: ['k/1.jpg', 'k/2.jpg', 'k/3.jpg'] });
  const larb = await reviewId(e, 'Larb');
  const som = await reviewId(e, 'Som Tum');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb)`, [e, JSON.stringify([
    { review_id: larb, photo_url: photoUrl('k/1.jpg') },
    { review_id: som, photo_url: photoUrl('k/2.jpg') },
    { review_id: larb, photo_url: photoUrl('k/3.jpg') },
    { review_id: som, photo_url: photoUrl('k/3.jpg') }, // k/3 shows both (0083)
  ])]));
  assert.deepEqual(await pairs(e), [['k/1.jpg', 'Larb'], ['k/2.jpg', 'Som Tum'], ['k/3.jpg', 'Larb'], ['k/3.jpg', 'Som Tum']]);

  // The author says k/1 is No dish: the larb keeps k/3 and shows it.
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, null)`, [e, photoUrl('k/1.jpg')]));
  assert.deepEqual(await pairs(e), [['k/2.jpg', 'Som Tum'], ['k/3.jpg', 'Larb'], ['k/3.jpg', 'Som Tum']]);
  assert.equal((await lines(e)).find((l) => l.name === 'Larb').photo_url, photoUrl('k/3.jpg'));

  // A later match never hands back the No-dish photo, and leaves the picked larb alone.
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb)`, [e, JSON.stringify([
    { review_id: som, photo_url: photoUrl('k/1.jpg') },
    { review_id: som, photo_url: photoUrl('k/2.jpg') },
  ])]));
  assert.deepEqual(await pairs(e), [['k/2.jpg', 'Som Tum'], ['k/3.jpg', 'Larb']]);

  // A photo deleted from the entry leaves its dish.
  await as(U.alice, () => db.query(`delete from public.entry_photos where entry_id = $1 and position = 1`, [e]));
  assert.deepEqual(await pairs(e), [['k/3.jpg', 'Larb']]);
});

test('a re-sort keeps both hand-picked photos of one dish (0081)', async () => {
  const r = receipt(['Gnocchi', 4], ['Cannoli']);
  const e = await w.visit(32, U.alice, P.tipo, r, undefined, { photos: ['q/1.jpg', 'q/2.jpg'] });
  const c = await reviewId(e, 'Cannoli');
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('q/1.jpg'), c]));
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('q/2.jpg'), c]));
  assert.deepEqual(await pairs(e), [['q/1.jpg', 'Cannoli'], ['q/2.jpg', 'Cannoli']]);

  await w.sortAs(e, P.tipo, r.items);
  await asService(() => db.query(`select public.prune_photo_pairs($1)`, [e]));
  await asService(() => db.query(`select public.restore_photo_picks($1)`, [e]));
  assert.deepEqual(await pairs(e), [['q/1.jpg', 'Cannoli'], ['q/2.jpg', 'Cannoli']]);
  assert.ok((await lines(e)).find((l) => l.name === 'Cannoli').photo_url);
});

test('one photo, several dishes, each placed; the dish page crops onto its own (0083)', async () => {
  // Eamon's City Beach plate: a club sandwich, its fries and a long black in one photo, and a
  // second photo of the sandwich alone.
  const e = await w.visit(33, U.alice, P.tipo, receipt(['Club Sandwich', 4], ['Fries', 3.5], ['Long Black']), undefined,
    { photos: ['c/1.jpg', 'c/2.jpg'] });
  const club = await reviewId(e, 'Club Sandwich');
  const fries = await reviewId(e, 'Fries');
  const coffee = await reviewId(e, 'Long Black');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb, true)`, [e, JSON.stringify([
    { review_id: club, photo_url: photoUrl('c/1.jpg'), box: [0.4, 0.55, 1, 1] },
    { review_id: fries, photo_url: photoUrl('c/1.jpg'), box: [0, 0.58, 0.48, 1] },
    { review_id: coffee, photo_url: photoUrl('c/1.jpg'), box: [0.3, 0, 0.1, 0.34] }, // right of its left: no box
    { review_id: club, photo_url: photoUrl('c/2.jpg'), box: [0.1, 0.1, 0.9, 0.9] },
  ])]));
  assert.deepEqual(await pairs(e), [
    ['c/1.jpg', 'Club Sandwich'], ['c/1.jpg', 'Fries'], ['c/1.jpg', 'Long Black'], ['c/2.jpg', 'Club Sandwich'],
  ]);
  const boxes = await rows(`select review_id, box_left, box_bottom from public.photo_dishes where entry_id = $1 and photo_url = $2`,
    [e, photoUrl('c/1.jpg')]);
  assert.equal(boxes.find((b) => b.review_id === fries).box_bottom, 1);
  assert.equal(boxes.find((b) => b.review_id === coffee).box_left, null);

  // Main photos: the sandwich on its own beats the shared plate, though it came second.
  const byName = Object.fromEntries((await lines(e)).map((l) => [l.name, l.photo_url]));
  assert.equal(byName['Club Sandwich'], photoUrl('c/2.jpg'));
  assert.equal(byName['Fries'], photoUrl('c/1.jpg'));
  const [entry] = await rows(`select photos_located_at from public.entries where id = $1`, [e]);
  assert.ok(entry.photos_located_at);

  // The dish page: the shared photo says where the dish sits; a photo of it alone does not; an
  // unplaced dish's shared photo has no box (shown whole).
  const photosOf = async (rid) => (await as(U.bob, () => db.query(
    `select public.dish_photos(dish_id) photos from public.reviews where id = $1`, [rid]))).rows[0].photos;
  const clubPhotos = await photosOf(club);
  assert.deepEqual(clubPhotos.map((p) => [p.url, p.box ?? null]), [
    [photoUrl('c/2.jpg'), null],
    [photoUrl('c/1.jpg'), [0.4, 0.55, 1, 1]],
  ]);
  const friesPhotos = await photosOf(fries);
  assert.equal(friesPhotos.length, 1);
  assert.equal(friesPhotos[0].box.length, 4);
  assert.equal((await photosOf(coffee))[0].box, undefined);

  // The author names the shared photo one dish by hand: it is that dish alone, and a re-match keeps it.
  await as(U.alice, () => db.query(`select public.set_review_photo($1, $2, $3)`, [e, photoUrl('c/1.jpg'), fries]));
  assert.deepEqual(await pairs(e), [['c/1.jpg', 'Fries'], ['c/2.jpg', 'Club Sandwich']]);
  await asService(() => db.query(`select public.restore_photo_picks($1)`, [e]));
  assert.deepEqual(await pairs(e), [['c/1.jpg', 'Fries'], ['c/2.jpg', 'Club Sandwich']]);
});

test('a box the database cannot hold is refused at the table (0083)', async () => {
  const e = await w.visit(34, U.alice, P.tipo, receipt(['Pho', 4], ['Banh Mi', 4]), undefined, { photos: ['v/1.jpg'] });
  const pho = await reviewId(e, 'Pho');
  assert.ok(await code(() => asService(() => db.query(
    `insert into public.photo_dishes (entry_id, photo_url, review_id, box_left, box_top, box_right, box_bottom)
     values ($1, $2, $3, 0.5, 0, 0.2, 1)`, [e, photoUrl('v/1.jpg'), pho]))));
  // Old two-argument callers still work (default p_located false).
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb)`, [e, JSON.stringify([
    { review_id: pho, photo_url: photoUrl('v/1.jpg') },
  ])]));
  const [entry] = await rows(`select photos_located_at from public.entries where id = $1`, [e]);
  assert.equal(entry.photos_located_at, null);
});

test('set_photo_dishes: the author ticks every dish a photo shows; boxes stay; it outlives a re-sort (0083)', async () => {
  const r = receipt(['Chicken Soup', 4], ['Dumplings', 4.5], ['Bao']);
  const e = await w.visit(35, U.alice, P.tipo, r, undefined, { photos: ['s/1.jpg', 's/2.jpg'] });
  const soup = await reviewId(e, 'Chicken Soup');
  const dumplings = await reviewId(e, 'Dumplings');
  const bao = await reviewId(e, 'Bao');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb, true)`, [e, JSON.stringify([
    { review_id: soup, photo_url: photoUrl('s/1.jpg'), box: [0, 0.2, 0.5, 0.8] },
    { review_id: bao, photo_url: photoUrl('s/2.jpg') },
  ])]));

  // The dumplings were in s/1 too: the author ticks both.
  await as(U.alice, () => db.query(`select public.set_photo_dishes($1, $2, $3::uuid[])`,
    [e, photoUrl('s/1.jpg'), [dumplings, soup]]));
  assert.deepEqual(await pairs(e), [['s/1.jpg', 'Chicken Soup'], ['s/1.jpg', 'Dumplings'], ['s/2.jpg', 'Bao']]);
  const [kept] = await rows(`select box_left, box_right from public.photo_dishes where entry_id = $1 and review_id = $2`, [e, soup]);
  assert.equal(kept.box_right, 0.5);
  assert.equal((await lines(e)).find((l) => l.name === 'Dumplings').photo_url, photoUrl('s/1.jpg'));

  // A re-sort and a re-match keep the author's ticks.
  await w.sortAs(e, P.tipo, r.items);
  await asService(() => db.query(`select public.prune_photo_pairs($1)`, [e]));
  await asService(() => db.query(`select public.restore_photo_picks($1)`, [e]));
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb, true)`, [e, JSON.stringify([])]));
  assert.deepEqual((await pairs(e)).filter(([u]) => u === 's/1.jpg'), [['s/1.jpg', 'Chicken Soup'], ['s/1.jpg', 'Dumplings']]);
  assert.equal((await lines(e)).find((l) => l.name === 'Dumplings').photo_url, photoUrl('s/1.jpg'));

  // Down to one, then none (a re-sort rebuilds the lines: their ids are new).
  const soupNow = await reviewId(e, 'Chicken Soup');
  await as(U.alice, () => db.query(`select public.set_photo_dishes($1, $2, $3::uuid[])`, [e, photoUrl('s/1.jpg'), [soupNow]]));
  assert.deepEqual((await pairs(e)).filter(([u]) => u === 's/1.jpg'), [['s/1.jpg', 'Chicken Soup']]);
  await asService(() => db.query(`select public.restore_photo_picks($1)`, [e]));
  assert.deepEqual((await pairs(e)).filter(([u]) => u === 's/1.jpg'), [['s/1.jpg', 'Chicken Soup']]);
  await as(U.alice, () => db.query(`select public.set_photo_dishes($1, $2, $3::uuid[])`, [e, photoUrl('s/1.jpg'), []]));
  assert.deepEqual((await pairs(e)).filter(([u]) => u === 's/1.jpg'), []);

  // Nobody else, and only this entry's lines.
  assert.equal(await code(() => as(U.bob, () => db.query(`select public.set_photo_dishes($1, $2, $3::uuid[])`,
    [e, photoUrl('s/1.jpg'), [soupNow]]))), 'P0002');
  const other = await w.visit(36, U.alice, P.tipo, receipt(['Pho', 4]), undefined, { photos: ['t/1.jpg'] });
  const pho = await reviewId(other, 'Pho');
  assert.equal(await code(() => as(U.alice, () => db.query(`select public.set_photo_dishes($1, $2, $3::uuid[])`,
    [e, photoUrl('s/1.jpg'), [soupNow, pho]]))), '22023');
});

test('dish_photos names the other placed dishes on a shared photo (0083)', async () => {
  const e = await w.visit(37, U.alice, P.tipo, receipt(['Chicken Soup', 4], ['Dumplings', 4.5]), undefined,
    { photos: ['u/1.jpg'] });
  const soup = await reviewId(e, 'Chicken Soup');
  const dumplings = await reviewId(e, 'Dumplings');
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb, true)`, [e, JSON.stringify([
    { review_id: soup, photo_url: photoUrl('u/1.jpg'), box: [0, 0.2, 0.5, 0.8] },
    { review_id: dumplings, photo_url: photoUrl('u/1.jpg'), box: [0.5, 0.3, 1, 0.9] },
  ])]));
  const [d] = (await as(U.bob, () => db.query(
    `select public.dish_photos(dish_id) photos from public.reviews where id = $1`, [soup]))).rows;
  assert.deepEqual(d.photos[0].box, [0, 0.2, 0.5, 0.8]);
  assert.deepEqual(d.photos[0].with.map((x) => x.name), ['Dumplings']);
  assert.equal(d.photos[0].with[0].box.length, 4);
});
