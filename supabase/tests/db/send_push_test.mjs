// supabase/tests/db/send_push_test.mjs — 0059: what the push sender may claim. The edge function sends
// exactly what push_claim_ate_with returns, so every "never push X" rule is pinned here, in SQL.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, asService, rows, error;
const TOK = 'ab'.repeat(32);

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
  await as(U.bob, () => db.query(`select public.register_push_token($1, 'sandbox')`, [TOK]));
});
after(async () => db?.close());

const tag = async (uid, entry, who) => (await as(uid, () => rows(`select * from public.tag_ate_with($1, $2)`, [entry, who])))[0];
const claim = () => asService(() => rows(`select * from public.push_claim_ate_with(50)`));
const markSent = (ids) => asService(() => db.query(`select public.push_mark_sent($1::uuid[])`, [ids]));
const notifOf = async (companion) => (await rows(`select * from public.notifications where companion_id = $1`, [companion]))[0];
/** An entry the tagger has written but the sorter has not finished yet. */
async function unsorted(n, author, place) {
  await as(author, () => db.query(`insert into public.entries (id, author_id, body, restaurant_id) values ($1, $2, 'Gnocchi', $3)`,
    [id(n), author, place]));
  return id(n);
}

test('claim: a sorted entry\'s pending tag, with copy, badge and tokens — once', async () => {
  const E = await w.visit(1, U.alice, P.tipo, receipt(['Tagliatelle al ragù', 5], ['Tiramisu'], ['Prawn spaghetti']));
  const t = await tag(U.alice, E, U.bob);
  const got = await claim();
  assert.equal(got.length, 1);
  const [r] = got;
  assert.equal(r.companion_id, t.companion_id);
  assert.equal(r.actor_username, 'alice');
  assert.equal(r.place_name, 'Tipo 00');
  assert.deepEqual(r.dish_names, ['Tagliatelle al ragù', 'Tiramisu', 'Prawn spaghetti']);
  assert.equal(r.badge, 1);
  assert.deepEqual(r.tokens, [{ token: TOK, apns_env: 'sandbox' }]);
  assert.equal((await claim()).length, 0, 'a live claim is not handed out twice');

  await db.query(`update public.notifications set push_claimed_at = now() - interval '3 minutes' where id = $1`, [r.notification_id]);
  assert.equal((await claim()).length, 1, 'a stale claim (a failed send) is retried');
  await markSent([r.notification_id]);
  assert.ok((await notifOf(t.companion_id)).pushed_at);
  assert.equal((await claim()).length, 0, 'pushed: never again');
});

test('claim: no push while the tagger\'s entry is still sorting; ready once it sorts', async () => {
  const E = await unsorted(10, U.alice, P.marion);
  const t = await tag(U.alice, E, U.bob);
  assert.equal((await claim()).length, 0, 'the dishes do not exist yet');
  await w.sortAs(E, P.marion, receipt(['Gnocchi', 4]).items);
  const got = await claim();
  assert.deepEqual(got.map((r) => r.companion_id), [t.companion_id]);
  await markSent(got.map((r) => r.notification_id));
});

test('claim: never a quiet, read, dismissed, declined or blocked one', async () => {
  // quiet (0058: a re-tag after a delivered tag is born read + pushed)
  const Q = await w.visit(20, U.alice, P.osteria, receipt(['Cannoli']));
  const q1 = await tag(U.alice, Q, U.bob);
  await markSent((await claim()).map((r) => r.notification_id));
  await as(U.alice, () => db.query(`select public.untag_ate_with($1, $2)`, [Q, U.bob]));
  const q2 = await tag(U.alice, Q, U.bob);
  assert.notEqual(q2.companion_id, q1.companion_id);
  assert.ok((await notifOf(q2.companion_id)).pushed_at, 'born pushed');

  const D = await w.visit(21, U.cleo, P.tipo, receipt(['Gnocchi']));
  const dismissed = await tag(U.cleo, D, U.bob);
  const dn = (await notifOf(dismissed.companion_id)).id;
  await as(U.bob, () => db.query(`select public.dismiss_notification($1)`, [dn]));

  const R = await w.visit(22, U.dan, P.tipo, receipt(['Gnocchi']));
  const read = await tag(U.dan, R, U.bob);
  await as(U.bob, () => db.query(`select public.ate_with_prefill($1)`, [read.companion_id]));

  const X = await w.visit(23, U.alice, P.marion, receipt(['Olives']));
  const declined = await tag(U.alice, X, U.cleo);
  await as(U.cleo, () => db.query(`select public.decline_ate_with($1)`, [declined.companion_id]));

  const B = await w.visit(24, U.dan, P.osteria, receipt(['Cannoli']));
  const blocked = await tag(U.dan, B, U.cleo);
  // A block that somehow left the pending row (the 0058 trigger normally withdraws it): the claim must still refuse.
  await db.exec(`alter table public.blocks disable trigger blocks_withdraw_ate_with_ai`);
  await db.query(`insert into public.blocks (blocker_id, blocked_id) values ($1, $2)`, [U.cleo, U.dan]);
  await db.exec(`alter table public.blocks enable trigger blocks_withdraw_ate_with_ai`);
  assert.equal((await rows(`select status from public.entry_companions where id = $1`, [blocked.companion_id]))[0].status, 'pending');

  const got = await claim();
  const ids = got.map((r) => r.companion_id);
  for (const [name, t] of Object.entries({ q2, dismissed, read, declined, blocked })) {
    assert.ok(!ids.includes(t.companion_id), `${name} must not be claimed`);
  }
});

test('the sender\'s calls are service_role only; a client can\'t touch the claim columns', async () => {
  for (const sql of [
    `select * from public.push_claim_ate_with(50)`,
    `select public.push_mark_sent('{}'::uuid[])`,
    `select public.push_drop_tokens('{}'::text[])`,
    `select public.push_kick()`,
  ]) {
    assert.equal((await as(U.bob, () => error(db.query(sql))))?.code, '42501', sql);
  }
  const E = await w.visit(30, U.alice, P.tipo, receipt(['Gnocchi']));
  const t = await tag(U.alice, E, U.cleo);
  await as(U.cleo, () => db.query(`update public.notifications set push_claimed_at = now(), push_attempts = 9, pushed_at = now() where companion_id = $1`, [t.companion_id]));
  const n = await notifOf(t.companion_id);
  assert.deepEqual([n.push_claimed_at, n.push_attempts, n.pushed_at], [null, 0, null]);
});

test('push_drop_tokens deletes dead tokens; push_kick is a silent no-op without pg_net/Vault', async () => {
  assert.equal((await asService(() => rows(`select public.push_drop_tokens($1::text[]) n`, [[TOK]])))[0].n, 1);
  assert.equal((await rows(`select count(*)::int n from public.device_push_tokens`))[0].n, 0);
  const E = await w.visit(40, U.alice, P.tipo, receipt(['Gnocchi']));
  await tag(U.alice, E, U.dan);                                  // the insert trigger kicked and did not fail
  assert.equal((await asService(() => rows(`select public.push_kick() k`)))[0].k, false);
});
