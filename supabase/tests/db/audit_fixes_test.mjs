// supabase/tests/db/audit_fixes_test.mjs — the independent audit's attacks (26 Oct), each run as a
// real client role and refused by 0094. Before 0094 every "refused" here succeeded.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt, photoUrl } from './fixtures.mjs';

let w, db, as, asService, rows, error;

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
});
after(async () => db?.close());

const code = async (uid, sql, params) => (await as(uid, () => error(db.query(sql, params))))?.code ?? null;

test('1: nobody writes a review line directly: no loose 6s on anyone\'s dish', async () => {
  const E = await w.visit(1, U.alice, P.tipo, receipt(['Margherita', 4.5]), '2026-09-01T09:00:00Z');
  const [{ dish_id: dish }] = await rows(`select dish_id from public.reviews where entry_id = $1`, [E]);

  for (let i = 0; i < 3; i++) {
    assert.equal(await code(U.bob,
      `insert into public.reviews (reviewer_id, dish_id, score, note, created_at) values ($1, $2, 6, 'best ever', '2030-01-01')`,
      [U.bob, dish]), '42501', 'a loose line is refused');
  }
  const B = await w.visit(2, U.bob, P.tipo, receipt(['Salad', 3]), '2026-09-02T09:00:00Z');
  assert.equal(await code(U.bob,
    `insert into public.reviews (reviewer_id, dish_id, score, entry_id) values ($1, $2, 6, $3)`, [U.bob, dish, B]),
    '42501', 'even on your own entry: lines come from the sorter');

  const [{ n }] = await rows(`select count(*)::int n from public.reviews where dish_id = $1`, [dish]);
  assert.equal(n, 1, 'only Alice\'s line is on the dish');
  const [stats] = await rows(`select score::float8 avg from public.dish_stats where dish_id = $1`, [dish]);
  assert.equal(stats.avg, 4.5, 'the score is untouched');

  // What the app does still works: PATCH a line's tags. Nothing else on the line moves.
  const [{ id: line }] = await rows(`select id from public.reviews where entry_id = $1`, [B]);
  assert.equal(await code(U.bob, `update public.reviews set tags = '{vg}' where id = $1`, [line]), null, 'tags still edit');
  assert.equal(await code(U.bob, `update public.reviews set score = 6 where id = $1`, [line]), '42501', 'scores do not');
  assert.equal(await code(U.bob, `update public.reviews set entry_id = null where id = $1`, [line]), '42501');
  assert.equal(await code(U.bob, `delete from public.reviews where id = $1`, [line]), '42501');
});

test('2: nobody plants a dish, so nobody hijacks dish matching with a fake merge pointer', async () => {
  const junk = (await asService(() => rows(
    `select public.find_or_create_dish($1, 'Junk') id`, [P.tipo])))[0].id;
  assert.equal(await code(U.bob,
    `insert into public.dishes (name, restaurant_id, merged_into_dish_id) values ('Margherita Pizza', $1, $2)`, [P.tipo, junk]),
    '42501', 'a dish with a merge pointer is refused');
  assert.equal(await code(U.bob,
    `insert into public.dishes (name, restaurant_id) values ('Anything', $1)`, [P.tipo]), '42501', 'any dish insert is refused');
  assert.equal(await code(U.bob, `update public.dishes set merged_into_dish_id = $1 where restaurant_id = $2`, [junk, P.tipo]),
    '42501', 'and no existing dish can be repointed');
  const got = (await asService(() => rows(`select public.find_or_create_dish($1, 'Margherita Pizza') id`, [P.tipo])))[0].id;
  assert.notEqual(got, junk, 'the matcher still makes its own dish');
});

test('4: a 6 moved onto an entry is counted against the two-sixes allowance', async () => {
  // The client path is closed by 1; this is the trigger itself, written as the server would.
  const A = await w.visit(3, U.cleo, P.tipo, receipt(['Gnocchi', 6]), '2026-10-20T09:00:00Z');
  const B = await w.visit(4, U.cleo, P.marion, receipt(['Risotto', 6]), '2026-10-21T09:00:00Z');
  const C = await w.visit(5, U.cleo, P.osteria, receipt(['Ragu', 4]), '2026-10-22T09:00:00Z');
  const [{ dish_id: dish }] = await rows(`select dish_id from public.reviews where entry_id = $1`, [C]);
  const [{ id: loose }] = await rows(
    `insert into public.reviews (reviewer_id, dish_id, score) values ($1, $2, 6) returning id`, [U.cleo, dish]);
  await db.query(`update public.reviews set entry_id = $2 where id = $1`, [loose, C]);
  const [{ s }] = await rows(`select score::float8 s from public.reviews where id = $1`, [loose]);
  assert.equal(s, 5, 'the third 6 lands as a 5.0, moved or not');
  assert.ok(A && B);
});

test('5: delete_account queues the account\'s storage for the purge', async () => {
  await as(U.dan, () => rows(`select public.delete_account()`));
  const q = await rows(`select user_id from public.storage_purge_queue`);
  assert.deepEqual(q.map((r) => r.user_id), [U.dan]);
  assert.ok(await code(U.alice, `select * from public.storage_purge_queue`), 'clients cannot read the queue');
});

test('9: list invites spend the day budget', async () => {
  // 40 a rolling day across tags, invites and list invites. Fill it from the ledger, then invite.
  await asService(() => db.query(
    `insert into public.ate_with_ledger (actor_id, kind, entry_id) select $1, 'tag', gen_random_uuid() from generate_series(1, 40)`,
    [U.alice]));
  const [list] = await as(U.alice, () => rows(`select * from public.create_list('Spam')`));
  const c = await code(U.alice, `select * from public.set_list_people($1, $2::uuid[])`, [list.list_id, [U.bob]]);
  assert.equal(c, '54000', 'over budget: refused');
  const [{ n }] = await rows(`select count(*)::int n from public.notifications where recipient_id = $1 and type = 'list_invite'`, [U.bob]);
  assert.equal(n, 0, 'and no notification reached Bob');
  await asService(() => db.query(`delete from public.ate_with_ledger where actor_id = $1`, [U.alice]));
  assert.equal(await code(U.alice, `select * from public.set_list_people($1, $2::uuid[])`, [list.list_id, [U.bob]]), null,
    'within budget it works, and is spent');
  const [{ k }] = await rows(`select count(*)::int k from public.ate_with_ledger where actor_id = $1 and kind = 'list'`, [U.alice]);
  assert.equal(k, 1);
});

test('13: photo and avatar URLs must be this project\'s storage', async () => {
  const E = await w.visit(6, U.bob, P.tipo, receipt(['Pie', 4]), '2026-09-03T09:00:00Z');
  for (const bad of ['https://evil.example/track.gif', 'https://abcdefgh.supabase.co/storage/v1/object/public/review-photos/x.jpg',
    photoUrl('../avatars/x.jpg'), 'javascript:alert(1)']) {
    assert.equal(await code(U.bob, `insert into public.entry_photos (entry_id, position, photo_url) values ($1, 5, $2)`, [E, bad]),
      '22023', bad);
  }
  assert.equal(await code(U.bob, `insert into public.entry_photos (entry_id, position, photo_url) values ($1, 5, $2)`,
    [E, photoUrl(`${U.bob}/6-5.jpg`)]), null, 'our own storage is fine');

  const avatar = (u) => `https://vyaexmnajnbryimbkgkf.supabase.co/storage/v1/object/public/avatars/${u}/avatar.jpg?v=123`;
  assert.equal(await code(U.bob, `update public.profiles set avatar_url = 'https://evil.example/a.png' where id = $1`, [U.bob]), '22023');
  assert.equal(await code(U.bob, `update public.profiles set avatar_url = $2 where id = $1`, [U.bob, avatar(U.bob)]), null);
  assert.equal(await code(U.bob, `update public.profiles set avatar_url = null where id = $1`, [U.bob]), null, 'removing it is fine');
  assert.equal(await code(U.bob, `update public.profiles set name = 'Bob B' where id = $1`, [U.bob]), null, 'other edits untouched');
});

test('15: hand-added places are capped per day; a repeat report returns the first', async () => {
  for (let i = 0; i < 20; i++) {
    assert.equal(await code(U.bob, `select * from public.add_manual_restaurant($1)`, [`Place ${i}`]), null);
  }
  assert.equal(await code(U.bob, `select * from public.add_manual_restaurant('One more')`), '54000', 'the 21st is refused');
  assert.equal(await code(U.alice, `select * from public.add_manual_restaurant($1)`, ['x'.repeat(201)]), '22001', 'name length');

  const E = await w.visit(7, U.alice, P.tipo, receipt(['Toast', 3]), '2026-09-04T09:00:00Z');
  const r1 = (await as(U.bob, () => rows(`select public.report_entry($1, 'spam') id`, [E])))[0].id;
  const r2 = (await as(U.bob, () => rows(`select public.report_entry($1, 'spam') id`, [E])))[0].id;
  assert.equal(r1, r2, 'the same open report');
  const [{ n }] = await rows(`select count(*)::int n from public.reports where entry_id = $1`, [E]);
  assert.equal(n, 1);
  await db.query(`insert into public.reports (reporter_id, profile_id, created_at)
                  select $1, $2, now() from generate_series(1, 29)`, [U.bob, U.cleo]);
  assert.equal(await code(U.bob, `insert into public.reports (reporter_id, profile_id) values ($1, $2)`, [U.bob, U.alice]), '54000',
    'the 31st report of the day is refused');
});

test('16: nobody reads someone else\'s diet; you read your own', async () => {
  await as(U.alice, () => db.query(`update public.profiles set diet = '{vg}' where id = $1`, [U.alice]));
  assert.equal(await code(U.bob, `select diet from public.profiles where id = $1`, [U.alice]), '42501');
  assert.equal(await code(null, `select diet from public.profiles where id = $1`, [U.alice]), '42501', 'nor signed out');
  assert.equal(await code(U.bob, `select id, username, name, avatar_url, city from public.profiles where id = $1`, [U.alice]), null,
    'the rest of the profile reads as before');
  const [{ d }] = await as(U.alice, () => rows(`select public.my_diet() d`));
  assert.deepEqual(d, ['vg']);
});

test('17: a live push token stays with its owner', async () => {
  const token = 'a'.repeat(64);
  await as(U.alice, () => db.query(`select public.register_push_token($1, 'production')`, [token]));
  await as(U.bob, () => db.query(`select public.register_push_token($1, 'production')`, [token]));
  const [{ user_id }] = await rows(`select user_id from public.device_push_tokens where token = $1`, [token]);
  assert.equal(user_id, U.alice, 'not taken over');
  await db.query(`update public.device_push_tokens set last_seen_at = now() - interval '8 days' where token = $1`, [token]);
  await as(U.bob, () => db.query(`select public.register_push_token($1, 'production')`, [token]));
  assert.equal((await rows(`select user_id from public.device_push_tokens where token = $1`, [token]))[0].user_id, U.bob,
    'a stale row moves');
});

test('28: the unused social tables are not readable', async () => {
  for (const t of ['comments', 'follows', 'review_likes', 'comment_likes', 'review_tags', 'lists', 'list_dishes']) {
    assert.equal(await code(U.alice, `select 1 from public.${t} limit 1`), '42501', t);
  }
});

test('27: dish names and review notes have caps', async () => {
  assert.ok(await asService(() => error(db.query(`select public.find_or_create_dish($1, $2)`, [P.tipo, 'x'.repeat(250)]))));
  assert.ok(id(1));
});
