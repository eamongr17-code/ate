// supabase/tests/db/feedback_test.mjs — tester feedback (0082) at the SQL level: send_feedback's
// idempotency, limits and screenshot paths, and that nobody but the service role reads a report.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, id } from './fixtures.mjs';

let w, db, as, asService, rows, error;

before(async () => {
  w = await world({ places: false });
  ({ db, as, asService, rows, error } = w);
});
after(async () => db?.close());

const send = (uid, fid, body, shots = [], screens = []) =>
  as(uid, () => db.query(
    `select public.send_feedback($1, $2, $3::text[], 'Build 162', 'iPhone18,1', 'iOS 26.1', $4::text[]) id`,
    [fid, body, shots, screens],
  ));
const all = () => asService(() => rows(`select * from public.feedback order by created_at, id`));

test('0082: a report lands once, trimmed, with its fingerprint; a retry returns the same row', async () => {
  const F = id(8201);
  const shot = `${U.alice}/${F}/1.jpg`;
  assert.equal((await send(U.alice, F, '  The place sheet froze  ', [shot], ['journal', 'place'])).rows[0].id, F);
  assert.equal((await send(U.alice, F, 'The place sheet froze', [shot])).rows[0].id, F, 'a retry is the same report');
  const [r] = (await all()).filter((x) => x.id === F);
  assert.equal(r.body, 'The place sheet froze');
  assert.deepEqual(r.screenshots, [shot]);
  assert.deepEqual(r.screens, ['journal', 'place']);
  assert.equal(r.status, 'new');
  assert.equal(r.source, 'app');
  assert.equal(r.build, 'Build 162');
  assert.equal((await all()).filter((x) => x.id === F).length, 1);
  assert.equal((await as(U.bob, () => error(send(U.bob, F, 'mine now'))))?.code, '23505', "another tester's id is taken");
});

test('0082: the same words from the same tester share a fingerprint; from someone else they do not', async () => {
  await send(U.bob, id(8202), 'Search is slow');
  await send(U.bob, id(8203), 'search   is SLOW');
  await send(U.cleo, id(8204), 'Search is slow');
  const fp = Object.fromEntries((await all()).map((r) => [r.id, r.fingerprint]));
  assert.equal(fp[id(8202)], fp[id(8203)]);
  assert.notEqual(fp[id(8202)], fp[id(8204)]);
});

test('0082: words are required and capped; three screenshots, each the sender\'s own upload for this report', async () => {
  const F = id(8210);
  for (const body of ['', '   ', 'x'.repeat(4001)]) {
    assert.equal((await error(send(U.dan, F, body)))?.code, '22023', JSON.stringify(body.slice(0, 5)));
  }
  const mine = (n) => `${U.dan}/${F}/${n}.jpg`;
  assert.equal((await error(send(U.dan, F, 'four', [mine(1), mine(2), mine(3), mine(4)])))?.code, '22023', 'four is one too many');
  assert.equal((await error(send(U.dan, F, 'theirs', [`${U.alice}/${F}/1.jpg`])))?.code, '22023', "someone else's folder");
  assert.equal((await error(send(U.dan, F, 'other report', [`${U.dan}/${id(9999)}/1.jpg`])))?.code, '22023', 'another report');
  assert.equal((await error(send(U.dan, F, 'escape', [`${U.dan}/${F}/../x.jpg`])))?.code, '22023', 'no ..');
  assert.equal((await send(U.dan, F, 'ok', [mine(1), mine(2), mine(3)])).rows[0].id, F);
});

test('0082: ten an hour per tester, then feedback_rate', async () => {
  const uid = U.cleo; // has one report from the fingerprint test
  for (let n = 0; n < 9; n++) await send(uid, id(8300 + n), `report ${n}`);
  const e = await error(send(uid, id(8399), 'eleventh'));
  assert.equal(e?.code, '54000');
  assert.match(e.message, /feedback_rate/);
  assert.equal((await send(U.alice, id(8400), 'alice is not limited by cleo')).rows[0].id, id(8400));
});

test('0082: signed out cannot send; nobody but the service role reads or writes the table', async () => {
  assert.equal((await as(null, () => error(db.query(`select public.send_feedback($1, 'x')`, [id(8500)]))))?.code, '42501');
  for (const uid of [U.alice, null]) {
    assert.ok(await as(uid, () => error(db.query(`select * from public.feedback`))), `read as ${uid ?? 'anon'}`);
    assert.ok(await as(uid, () => error(db.query(
      `insert into public.feedback (user_id, body, fingerprint) values ($1, 'x', 'x')`, [U.alice]))), `insert as ${uid ?? 'anon'}`);
  }
});

test('0082: the screenshot bucket is private and takes uploads only under your own uid', async () => {
  const [b] = await rows(`select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'feedback-screenshots'`);
  assert.equal(b.public, false);
  assert.equal(Number(b.file_size_limit), 3 * 1024 * 1024);
  assert.deepEqual(b.allowed_mime_types, ['image/jpeg', 'image/png']);
  await as(U.alice, () => db.query(
    `insert into storage.objects (bucket_id, name) values ('feedback-screenshots', $1)`, [`${U.alice}/${id(1)}/1.jpg`]));
  assert.ok(await as(U.alice, () => error(db.query(
    `insert into storage.objects (bucket_id, name) values ('feedback-screenshots', $1)`, [`${U.bob}/${id(1)}/1.jpg`]))));
  const seen = await as(U.alice, () => rows(`select name from storage.objects where bucket_id = 'feedback-screenshots'`));
  assert.equal(seen.length, 0, 'not even your own: there is no read policy');
});
