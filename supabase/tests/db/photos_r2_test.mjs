// supabase/tests/db/photos_r2_test.mjs — 0103: photos on Cloudflare R2. The switch, the URL checks,
// delete_entry's paths, and the row move that only touches files the setup script verified.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, receipt } from './fixtures.mjs';

let w, db, as, asService, rows, error;
before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
});
after(async () => db?.close());

const SB = 'https://cvoitgoaosofkougmarn.supabase.co/storage/v1/object/public/';
const R2 = 'https://photos.chewsfood.app/';
const code = async (uid, sql, params) => (await as(uid, () => error(db.query(sql, params))))?.code ?? null;
const setBase = (base) => asService(() => db.query(`select public.photo_storage_set($1)`, [base]));
const config = async (uid) => (await as(uid, () => rows(`select public.photo_storage_config() c`)))[0].c;

test('the switch: off by default, readable by the apps, set only by the service role', async () => {
  assert.deepEqual(await config(null), { base: null });
  assert.deepEqual(await config(U.alice), { base: null });
  assert.equal(await code(U.alice, `select public.photo_storage_set('https://evil.example/')`), '42501');
  assert.equal(await code(U.alice, `update public.photo_storage set base = 'https://evil.example/'`), '42501');
  assert.ok(await error(asService(() => db.query(`select public.photo_storage_set('http://photos.x.app/')`))), 'https only');
  assert.ok(await error(asService(() => db.query(`select public.photo_storage_set('https://photos.x.app')`))), 'trailing slash');
  await setBase(R2);
  assert.deepEqual(await config(U.bob), { base: R2 });
  await setBase(null);
  assert.deepEqual(await config(U.bob), { base: null });
});

test('client image URLs: Supabase always; R2 only once switched on, only our host, only safe paths', async () => {
  const E = await w.visit(1, U.alice, P.tipo, receipt(['Margherita', 4.5]), '2026-09-01T09:00:00Z');
  const put = (pos, url) => code(U.alice,
    `insert into public.entry_photos (entry_id, position, photo_url) values ($1, $2, $3)`, [E, pos, url]);

  assert.equal(await put(0, `${SB}review-photos/${U.alice}/e-0.jpg`), null);
  assert.equal(await put(1, `${R2}review-photos/${U.alice}/e-1.jpg`), '22023', 'R2 is refused while off');
  await setBase(R2);
  assert.equal(await put(1, `${R2}review-photos/${U.alice}/e-1.jpg`), null);
  assert.equal(await put(2, `${R2}avatars/${U.alice}/a.jpg`), '22023', 'wrong bucket');
  assert.equal(await put(2, `https://photos.chewsfood.app.evil.com/review-photos/${U.alice}/e.jpg`), '22023');
  assert.equal(await put(2, `${R2}review-photos/${U.alice}/../x.jpg`), '22023');
  assert.equal(await put(2, `${R2}review-photos/${U.alice}/x.jpg"onerror=1`), '22023');
  assert.equal(await put(2, `https://evil.example/storage/v1/object/public/review-photos/${U.alice}/e.jpg`), '22023');
  assert.equal(await put(2, `${SB}review-photos/${U.alice}/e-2.jpg`), null, 'old builds keep uploading to Supabase');

  assert.equal(await code(U.alice, `update public.profiles set avatar_url = $1 where id = $2`,
    [`${R2}avatars/${U.alice}/avatar.jpg?v=17`, U.alice]), null);
  assert.equal(await code(U.alice, `update public.profiles set avatar_url = $1 where id = $2`,
    [`${R2}review-photos/${U.alice}/avatar.jpg`, U.alice]), '22023');
  await setBase(null);
});

test('list covers: the owner\'s list-covers folder, on Supabase or R2, never another host', async () => {
  await setBase(R2);
  const [list] = await as(U.bob, () => rows(`select * from public.create_list('Pasta')`));
  const cover = (url) => code(U.bob, `select public.set_list_cover($1, null, $2)`, [list.list_id ?? list.id, url]);
  assert.equal(await cover(`${R2}review-photos/${U.bob}/list-covers/l.jpg?v=3`), null);
  assert.equal(await cover(`${SB}review-photos/${U.bob}/list-covers/l.jpg?v=3`), null);
  assert.equal(await cover(`${R2}review-photos/${U.alice}/list-covers/l.jpg`), '22023', 'someone else\'s folder');
  assert.equal(await cover(`${R2}review-photos/${U.bob}/e-1.jpg`), '22023', 'not a cover');
  assert.equal(await cover(`https://evil.example/storage/v1/object/public/review-photos/${U.bob}/list-covers/l.jpg`),
    '22023', 'any host passed before 0103');
  await setBase(null);
});

test('delete_entry names R2 photos by the same bucket path', async () => {
  await setBase(R2);
  const E = await w.visit(2, U.cleo, P.marion, receipt(['Gnocchi', 4]), '2026-09-02T09:00:00Z');
  for (const [i, url] of [`${R2}review-photos/${U.cleo}/e2-0.jpg`, `${SB}review-photos/${U.cleo}/e2-1.jpg`].entries()) {
    await as(U.cleo, () => db.query(`insert into public.entry_photos (entry_id, position, photo_url) values ($1, $2, $3)`, [E, i, url]));
  }
  const [{ r }] = await as(U.cleo, () => rows(`select public.delete_entry($1) r`, [E]));
  assert.deepEqual(r.photo_paths, [
    `${U.cleo}/e2-0.jpg`, `${U.cleo}/e2-0_t.jpg`, `${U.cleo}/e2-1.jpg`, `${U.cleo}/e2-1_t.jpg`,
  ]);
  await setBase(null);
});

test('move_photo_urls: only verified keys move, every column at once, nothing else stamped', async () => {
  const E = await w.visit(3, U.dan, P.tipo, receipt(['Cacio e Pepe', 5], ['Tiramisu', 4]), '2026-09-03T09:00:00Z',
    { photos: [`${U.dan}/e3-0.jpg`, `${U.dan}/e3-1.jpg`] });
  const p0 = `${SB}review-photos/${U.dan}/e3-0.jpg`;
  const p1 = `${SB}review-photos/${U.dan}/e3-1.jpg`;
  const lines = await rows(`select id from public.reviews where entry_id = $1 order by id`, [E]);
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb)`, [E, JSON.stringify([
    { review_id: lines[0].id, photo_url: p0 }, { review_id: lines[1].id, photo_url: p1 },
  ])]));
  await as(U.dan, () => db.query(`select public.set_review_photo($1, $2, $3)`, [E, p0, lines[0].id]));
  await as(U.dan, () => db.query(`update public.profiles set avatar_url = $1 where id = $2`,
    [`${SB}avatars/${U.dan}/avatar.jpg?v=9`, U.dan]));
  const before = (await rows(`select updated_at, photo_picks from public.entries where id = $1`, [E]))[0];
  const lineStamps = await rows(`select id, updated_at from public.reviews where entry_id = $1 order by id`, [E]);

  // nothing happens until the base is set
  assert.ok(await error(asService(() => db.query(`select public.move_photo_urls($1, $2)`, [SB, [`review-photos/${U.dan}/e3-0.jpg`]]))));
  await setBase(R2);
  assert.equal(await code(U.dan, `select public.move_photo_urls($1, $2)`, [SB, [`review-photos/${U.dan}/e3-0.jpg`]]), '42501');
  assert.ok(await error(asService(() => db.query(`select public.move_photo_urls('https://x/', $1)`, [['a']]))));

  const keys = (await asService(() => rows(`select k from public.photo_keys_on_supabase($1) k order by k`, [SB]))).map((x) => x.k);
  assert.ok(keys.includes(`review-photos/${U.dan}/e3-0.jpg`) && keys.includes(`avatars/${U.dan}/avatar.jpg`));

  // e3-1 was "not copied": it keeps its Supabase URL everywhere
  const [{ m }] = await asService(() => rows(`select public.move_photo_urls($1, $2) m`,
    [SB, [`review-photos/${U.dan}/e3-0.jpg`, `avatars/${U.dan}/avatar.jpg`]]));
  assert.equal(m.entry_photos, 1);
  assert.equal(m.profiles, 1);
  const n0 = `${R2}review-photos/${U.dan}/e3-0.jpg`;
  assert.deepEqual((await rows(`select photo_url from public.entry_photos where entry_id = $1 order by position`, [E])).map((x) => x.photo_url), [n0, p1]);
  assert.deepEqual((await rows(`select photo_url from public.photo_dishes where entry_id = $1 order by photo_url`, [E])).map((x) => x.photo_url).sort(), [n0, p1].sort());
  assert.deepEqual((await rows(`select photo_url from public.reviews where entry_id = $1 order by id`, [E])).map((x) => x.photo_url), [n0, p1]);
  assert.equal((await rows(`select avatar_url from public.profiles where id = $1`, [U.dan]))[0].avatar_url,
    `${R2}avatars/${U.dan}/avatar.jpg?v=9`, 'the cache buster survives');

  const after = (await rows(`select updated_at, photo_picks from public.entries where id = $1`, [E]))[0];
  assert.deepEqual(Object.keys(after.photo_picks), [n0], 'the pick is keyed by the new URL');
  assert.deepEqual(Object.values(after.photo_picks), Object.values(before.photo_picks));
  assert.equal(after.updated_at.getTime(), before.updated_at.getTime(), 'the entry is not "edited"');
  assert.deepEqual(await rows(`select id, updated_at from public.reviews where entry_id = $1 order by id`, [E]), lineStamps);

  // the triggers are back on, and a second run moves nothing
  const [{ m: again }] = await asService(() => rows(`select public.move_photo_urls($1, $2) m`, [SB, [`review-photos/${U.dan}/e3-0.jpg`]]));
  assert.deepEqual(again, {});
  await as(U.dan, () => db.query(`update public.entries set body = body || ' ' where id = $1`, [E]));
  assert.ok((await rows(`select updated_at from public.entries where id = $1`, [E]))[0].updated_at > after.updated_at);
  await setBase(null);
});
