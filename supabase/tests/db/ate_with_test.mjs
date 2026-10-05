// supabase/tests/db/ate_with_test.mjs — "Ate with" (0058): tagging, the companion's prefill/respond/decline,
// invite links, notifications, blocks, the card's `companions`, push tokens, and account deletion.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, asService, rows, error;
const X = [1, 2, 3, 4, 5, 6].map((n) => id(900 + n)); // six extra people, for the cap
const SPENDER = id(950); // their own day budget, for the rate-limit test
const HOST = id(952);    // their own budget, for the decline-keeps-its-seat test

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
  for (const [i, uid] of X.entries()) {
    await db.query(`insert into auth.users (id, email) values ($1, $2)`, [uid, `extra${i + 1}@ate.test`]);
  }
  await db.query(`insert into auth.users (id, email) values ($1, 'spender@ate.test'), ($2, 'host@ate.test')`, [SPENDER, HOST]);
});
after(async () => db?.close());

const code = async (uid, sql, params) => (await as(uid, () => error(db.query(sql, params))))?.code ?? null;
const tag = (uid, entry, who) => as(uid, () => rows(`select * from public.tag_ate_with($1, $2)`, [entry, who]));
const card = async (uid, entry) => (await as(uid, () => rows(`select * from public.get_entry_card($1)`, [entry])))[0];
const withHandles = (c) => c.companions.map((p) => `${p.username}:${p.status}`);
const inbox = (uid, last = null, limit = 30) => as(uid, () => rows(
  `select * from public.my_notifications(p_limit => $1, p_cursor_created_at => $2, p_cursor_id => $3)`,
  [limit, last?.created_at ?? null, last?.id ?? null]));
const unread = async (uid) => (await as(uid, () => rows(`select public.unread_notification_count() n`)))[0].n;
const prefill = async (uid, companion) => (await as(uid, () => rows(`select public.ate_with_prefill($1) p`, [companion])))[0].p;
const respond = (uid, companion, entry, items, body = '') => as(uid, () => rows(
  `select * from public.respond_ate_with(p_companion_id => $1, p_entry_id => $2, p_items => $3::jsonb, p_body => $4)`,
  [companion, entry, JSON.stringify(items), body]));

// ---------------------------------------------------------------------------------------------------
test('tag: the two parties see the row and the pending "with"; nobody else does', async () => {
  const E = await w.visit(1, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu']), '2026-09-01T09:00:00Z');
  const [t] = await tag(U.alice, E, U.bob);
  assert.equal(t.status, 'pending');
  assert.equal(t.user_id, U.bob);
  assert.deepEqual((await tag(U.alice, E, U.bob)).map((r) => r.companion_id), [t.companion_id], 'idempotent');

  const raw = (uid) => as(uid, () => rows(`select id from public.entry_companions where entry_id = $1`, [E]));
  assert.equal((await raw(U.alice)).length, 1, 'tagger sees it');
  assert.equal((await raw(U.bob)).length, 1, 'companion sees it');
  assert.equal((await raw(U.cleo)).length, 0, 'a third person does not');
  assert.equal((await as(null, () => error(db.query(`select id from public.entry_companions`))))?.code, '42501', 'anon: no grant');
  for (const write of [
    `insert into public.entry_companions (entry_id, tagger_id, companion_id) values ('${E}', '${U.alice}', '${U.cleo}')`,
    `update public.entry_companions set status = 'accepted'`,
    `delete from public.entry_companions`,
  ]) assert.equal(await code(U.alice, write), '42501', `no client write: ${write.slice(0, 30)}`);

  assert.deepEqual(withHandles(await card(U.alice, E)), ['bob:pending']);
  assert.deepEqual(withHandles(await card(U.bob, E)), ['bob:pending']);
  assert.deepEqual((await card(U.cleo, E)).companions, [], 'pending is private to the two of them');
  assert.deepEqual((await as(null, () => rows(`select * from public.get_entry_card($1)`, [E])))[0].companions, [], 'signed out too');

  const n = await inbox(U.bob);
  assert.equal(n.length, 1);
  assert.equal(n[0].type, 'ate_with');
  assert.equal(n[0].actor.username, 'alice');
  assert.equal(n[0].companion_id, t.companion_id);
  assert.equal(n[0].place.name, 'Tipo 00');
  assert.equal(await unread(U.bob), 1);
  assert.equal((await inbox(U.alice)).length, 0, 'the tagger is not notified about their own act');
});

test('tag: only on your own entry, never yourself, never an unknown person', async () => {
  const E = await w.visit(2, U.alice, P.marion, receipt(['Olives']), '2026-09-02T09:00:00Z');
  assert.equal(await code(U.bob, `select * from public.tag_ate_with($1, $2)`, [E, U.cleo]), '42501');
  assert.equal(await code(U.alice, `select * from public.tag_ate_with($1, $2)`, [E, U.alice]), '22023');
  assert.equal(await code(U.alice, `select * from public.tag_ate_with($1, $2)`, [E, id(999)]), 'P0002');
  assert.equal(await code(U.alice, `select * from public.tag_ate_with($1, $2)`, [id(998), U.bob]), 'P0002');
  assert.equal(await code(null, `select * from public.tag_ate_with($1, $2)`, [E, U.bob]), '42501');
});

test('blocks: no tag across a block in either direction, and a new block withdraws pending tags', async () => {
  const E = await w.visit(3, U.cleo, P.osteria, receipt(['Cannoli', 3]), '2026-09-03T09:00:00Z');
  await as(U.dan, () => db.query(`select public.block_user($1)`, [U.cleo]));      // dan blocked cleo
  assert.equal(await code(U.cleo, `select * from public.tag_ate_with($1, $2)`, [E, U.dan]), '42501', 'blocked by them');
  const D = await w.visit(4, U.dan, P.osteria, receipt(['Cannoli', 4]), '2026-09-03T10:00:00Z');
  assert.equal(await code(U.dan, `select * from public.tag_ate_with($1, $2)`, [D, U.cleo]), '42501', 'blocked by me');
  await as(U.dan, () => db.query(`select public.unblock_user($1)`, [U.cleo]));

  const [t] = await tag(U.cleo, E, U.dan);
  assert.equal((await inbox(U.dan)).length, 1);
  await as(U.dan, () => db.query(`select public.block_user($1)`, [U.cleo]));
  assert.equal((await rows(`select count(*)::int n from public.entry_companions where id = $1`, [t.companion_id]))[0].n, 0, 'withdrawn');
  assert.equal((await inbox(U.dan)).length, 0, 'and its notification with it');
  assert.equal(await code(U.dan, `select public.ate_with_prefill($1)`, [t.companion_id]), 'P0002');
  await as(U.dan, () => db.query(`select public.unblock_user($1)`, [U.cleo]));
});

test('prefill follows the live entry; respond makes the companion\'s OWN linked entry', async () => {
  const E = await w.visit(10, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu']), '2026-09-05T09:00:00Z');
  const [t] = await tag(U.alice, E, U.bob);

  let pf = await prefill(U.bob, t.companion_id);
  assert.equal(pf.status, 'pending');
  assert.equal(pf.tagger.username, 'alice');
  assert.equal(pf.place.id, P.tipo);
  assert.equal(pf.sort_status, 'sorted');
  assert.deepEqual(pf.dishes.map((d) => d.dish_name), ['Gnocchi', 'Tiramisu']);
  assert.equal(await code(U.cleo, `select public.ate_with_prefill($1)`, [t.companion_id]), 'P0002', 'not theirs');
  const n = (await inbox(U.bob)).find((x) => x.companion_id === t.companion_id);
  assert.ok(n.read_at, 'opening the prefill marks the notification read');

  // The tagger edits the receipt before Bob answers: the prefill follows.
  await w.sortAs(E, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu'], ['Focaccia']).items);
  pf = await prefill(U.bob, t.companion_id);
  assert.deepEqual(pf.dishes.map((d) => d.dish_name), ['Gnocchi', 'Tiramisu', 'Focaccia']);

  const [gnocchi, , focaccia] = pf.dishes.map((d) => d.dish_id);
  assert.equal(await code(U.bob, `select * from public.respond_ate_with($1, $2, $3::jsonb)`,
    [t.companion_id, id(11), JSON.stringify([{ dish_id: (await rows(`select id from public.dishes where restaurant_id = $1 limit 1`, [P.marion]))[0]?.id ?? id(997) }])]), '22023', 'a dish from another place');
  assert.equal(await code(U.bob, `select * from public.respond_ate_with($1, $2, $3::jsonb)`,
    [t.companion_id, id(11), JSON.stringify([{ dish_id: gnocchi, score: 5.5 }])]), '23514', 'the score CHECK still rules');
  assert.equal(await code(U.bob, `select * from public.respond_ate_with($1, $2, '[]'::jsonb, '')`, [t.companion_id, id(11)]), '22023', 'nothing to post');

  const [mine] = await respond(U.bob, t.companion_id, id(11), [{ dish_id: gnocchi, score: 4 }, { dish_id: focaccia }, { dish_id: gnocchi, score: 1 }]);
  assert.equal(mine.id, id(11));
  assert.equal(mine.author_id, U.bob, 'owned by the responder');
  assert.equal(mine.is_mine, true);
  assert.equal(mine.restaurant_id, P.tipo, 'same place');
  assert.equal(new Date(mine.created_at).toISOString(), '2026-09-05T09:00:00.000Z', 'same visit');
  assert.equal(mine.sort_status, 'sorted');
  assert.deepEqual(mine.items.map((i) => [i.dish_name, i.score == null ? null : Number(i.score)]), [['Gnocchi', 4], ['Focaccia', null]],
    'Bob\'s own scores, one line per dish, Tiramisu left out');
  assert.ok(mine.items.every((i) => i.corrected), 'the user\'s lines: no re-sort replaces them');
  assert.deepEqual(withHandles(mine), ['alice:accepted']);
  assert.equal(mine.companions[0].entry_id, E, 'links back to the original');
  const lines = await rows(`select reviewer_id from public.reviews where entry_id = $1`, [id(11)]);
  assert.ok(lines.every((l) => l.reviewer_id === U.bob));
  assert.ok((await rows(`select order_number from public.entries where id = $1`, [id(11)]))[0].order_number > 0);

  const orig = await card(U.cleo, E);
  assert.deepEqual(withHandles(orig), ['bob:accepted'], 'a third person sees the accepted "with"');
  assert.equal(orig.companions[0].entry_id, id(11));
  assert.deepEqual(withHandles(await card(U.cleo, id(11))), ['alice:accepted']);
  assert.ok(!(await inbox(U.bob)).some((x) => x.companion_id === t.companion_id), 'answered = gone from the inbox');

  const [again] = await respond(U.bob, t.companion_id, id(11), [{ dish_id: gnocchi, score: 4 }]);
  assert.equal(again.id, id(11), 'a retry with the same id returns the same card');
  assert.equal(await code(U.bob, `select * from public.respond_ate_with($1, $2, $3::jsonb)`, [t.companion_id, id(12), '[]']), '23505');

  // The tagger's later edit never touches Bob's entry.
  await w.sortAs(E, P.tipo, receipt(['Negroni']).items);
  assert.deepEqual((await card(U.bob, id(11))).items.map((i) => i.dish_name), ['Gnocchi', 'Focaccia']);
});

test('decline: hidden from the cards, sticky against untag-and-retag, dismissed from the inbox', async () => {
  const E = await w.visit(20, U.alice, P.marion, receipt(['Anchovies', 5]), '2026-09-06T09:00:00Z');
  const [t] = await tag(U.alice, E, U.cleo);
  assert.equal((await as(U.cleo, () => rows(`select public.decline_ate_with($1) s`, [t.companion_id])))[0].s, 'declined');
  assert.equal(await code(U.bob, `select public.decline_ate_with($1)`, [t.companion_id]), 'P0002', 'only the companion declines');
  assert.deepEqual((await card(U.alice, E)).companions, []);
  assert.ok(!(await inbox(U.cleo)).some((x) => x.companion_id === t.companion_id));
  assert.equal(await code(U.cleo, `select * from public.respond_ate_with($1, $2, $3::jsonb, 'hi')`, [t.companion_id, id(21), '[]']), '22023');

  assert.equal((await as(U.alice, () => rows(`select public.untag_ate_with($1, $2) n`, [E, U.cleo])))[0].n, 0, 'untag leaves a decline');
  const [re] = await tag(U.alice, E, U.cleo);
  assert.equal(re.status, 'declined', 're-tagging returns the decline …');
  assert.equal((await rows(`select count(*)::int n from public.notifications where companion_id = $1`, [t.companion_id]))[0].n, 1, '… and no second notification');
});

test('untag: a pending tag is withdrawn, its notification with it', async () => {
  const E = await w.visit(25, U.alice, P.osteria, receipt(['Cannoli']), '2026-09-06T10:00:00Z');
  const [t] = await tag(U.alice, E, U.dan);
  assert.equal((await as(U.alice, () => rows(`select public.untag_ate_with($1, $2) n`, [E, U.dan])))[0].n, 1);
  assert.equal((await rows(`select count(*)::int n from public.notifications where companion_id = $1`, [t.companion_id]))[0].n, 0);
});

test('the original deleted before a response withdraws the tag', async () => {
  const E = await w.visit(30, U.bob, P.tipo, receipt(['Gnocchi', 4]), '2026-09-07T09:00:00Z');
  const [t] = await tag(U.bob, E, U.cleo);
  await as(U.bob, () => db.query(`select public.delete_entry($1)`, [E]));
  assert.equal(await code(U.cleo, `select public.ate_with_prefill($1)`, [t.companion_id]), 'P0002');
  assert.ok(!(await inbox(U.cleo)).some((x) => x.companion_id === t.companion_id));
});

test('cap: six seats per entry (tags + live invites); a seventh is 54000', async () => {
  const E = await w.visit(40, U.dan, P.marion, receipt(['Olives', 4]), '2026-09-08T09:00:00Z');
  for (const uid of X.slice(0, 5)) await tag(U.dan, E, uid);
  await as(U.dan, () => rows(`select * from public.create_ate_with_invite($1)`, [E]));
  assert.equal(await code(U.dan, `select * from public.tag_ate_with($1, $2)`, [E, X[5]]), '54000');
  assert.equal(await code(U.dan, `select * from public.create_ate_with_invite($1)`, [E]), '54000');
  await as(U.dan, () => db.query(`select public.untag_ate_with($1, $2)`, [E, X[0]]));
  assert.equal((await tag(U.dan, E, X[5]))[0].status, 'pending', 'a freed seat can be used');
});

test('invite: a token once, hashed at rest; single use; expiry; redeemed into a pending tag', async () => {
  const E = await w.visit(50, U.alice, P.osteria, receipt(['Cannoli', 3.5]), '2026-09-09T09:00:00Z');
  const [inv] = await as(U.alice, () => rows(`select * from public.create_ate_with_invite($1)`, [E]));
  assert.match(inv.token, /^[A-Za-z0-9_-]{32}$/);
  const stored = await rows(`select token_hash from public.entry_invites where id = $1`, [inv.invite_id]);
  assert.notEqual(stored[0].token_hash, inv.token, 'only the hash is stored');
  assert.equal((await as(U.bob, () => rows(`select id from public.entry_invites`))).length, 0, 'inviter-only read');

  assert.equal(await code(U.alice, `select * from public.redeem_ate_with_invite($1)`, [inv.token]), '22023', 'not your own');
  assert.equal(await code(U.dan, `select * from public.redeem_ate_with_invite($1)`, ['nope']), 'P0002');
  const [r] = await as(U.dan, () => rows(`select * from public.redeem_ate_with_invite($1)`, [inv.token]));
  assert.equal(r.entry_id, E);
  assert.equal(r.status, 'pending');
  assert.ok((await inbox(U.dan)).some((x) => x.companion_id === r.companion_id));
  assert.deepEqual((await as(U.dan, () => rows(`select * from public.redeem_ate_with_invite($1)`, [inv.token]))).map((x) => x.companion_id),
    [r.companion_id], 'the redeemer again: same row');
  assert.equal(await code(U.cleo, `select * from public.redeem_ate_with_invite($1)`, [inv.token]), '23505', 'single use');

  const [old] = await as(U.alice, () => rows(`select * from public.create_ate_with_invite($1)`, [E]));
  await db.query(`update public.entry_invites set expires_at = now() - interval '1 second' where id = $1`, [old.invite_id]);
  assert.equal(await code(U.cleo, `select * from public.redeem_ate_with_invite($1)`, [old.token]), '22023', 'expired');
  const [gone] = await as(U.alice, () => rows(`select * from public.create_ate_with_invite($1)`, [E]));
  assert.equal((await as(U.alice, () => rows(`select public.revoke_ate_with_invite($1) n`, [gone.invite_id])))[0].n, 1);
  assert.equal(await code(U.cleo, `select * from public.redeem_ate_with_invite($1)`, [gone.token]), 'P0002', 'revoked');
});

test('my_notifications: keyset walk without a repeat or a gap; blocked actors vanish; dismiss', async () => {
  const ids = [];
  for (const [i, uid] of X.entries()) {
    const E = await w.visit(60 + i, uid, P.tipo, receipt(['Gnocchi']), `2026-09-1${i}T09:00:00Z`);
    ids.push((await tag(uid, E, U.cleo))[0].companion_id);
  }
  const whole = await inbox(U.cleo);
  const walked = await w.walk((last) => inbox(U.cleo, last, 2));
  assert.deepEqual(walked.map((n) => n.id), whole.map((n) => n.id));
  assert.ok(ids.every((c) => whole.some((n) => n.companion_id === c)));

  await as(U.cleo, () => db.query(`select public.dismiss_notification($1)`, [whole[0].id]));
  assert.equal((await inbox(U.cleo)).length, whole.length - 1);
  // A block in the other direction (they blocked cleo) withdraws theirs too.
  await as(X[1], () => db.query(`select public.block_user($1)`, [U.cleo]));
  assert.ok(!(await inbox(U.cleo)).some((n) => n.companion_id === ids[1]));
  const before = await unread(U.cleo);
  assert.equal(before, (await inbox(U.cleo)).filter((n) => n.read_at == null).length, 'the badge counts what the inbox shows');
});

test('push tokens: register, move between accounts on one device, unregister; owner-only', async () => {
  const tok = 'ab'.repeat(32);
  await as(U.alice, () => db.query(`select public.register_push_token($1, 'sandbox')`, [tok.toUpperCase()]));
  assert.deepEqual(await as(U.alice, () => rows(`select token, apns_env from public.device_push_tokens`)), [{ token: tok, apns_env: 'sandbox' }]);
  assert.equal(await code(U.alice, `select public.register_push_token('xyz', 'sandbox')`), '22023');
  assert.equal(await code(U.alice, `select public.register_push_token($1, 'dev')`, [tok]), '22023');
  await as(U.bob, () => db.query(`select public.register_push_token($1, 'production')`, [tok]));
  assert.equal((await as(U.alice, () => rows(`select token from public.device_push_tokens`))).length, 0, 'the device moved to bob');
  assert.equal((await as(U.bob, () => rows(`select token from public.device_push_tokens`))).length, 1);
  assert.equal(await code(U.bob, `insert into public.device_push_tokens (token, user_id, apns_env) values ($1, $2, 'sandbox')`, ['cd'.repeat(32), U.bob]), '42501');
  await as(U.bob, () => db.query(`select public.unregister_push_token($1)`, [tok]));
  assert.equal((await rows(`select count(*)::int n from public.device_push_tokens`))[0].n, 0);
});

test('rate limit: 40 a day from the ledger — untag-then-retag and mint-then-revoke both still spend', async () => {
  const E = await w.visit(90, SPENDER, P.tipo, receipt(['Gnocchi', 4]), '2026-09-21T09:00:00Z');
  const ledger = async () => (await rows(`select count(*)::int n from public.ate_with_ledger where actor_id = $1`, [SPENDER]))[0].n;
  for (let i = 0; i < 20; i++) {
    await tag(SPENDER, E, U.cleo);
    await as(SPENDER, () => db.query(`select public.untag_ate_with($1, $2)`, [E, U.cleo]));
  }
  assert.equal(await ledger(), 20, 'every tag spent one, though every row was untagged');
  for (let i = 0; i < 19; i++) {
    const [inv] = await as(SPENDER, () => rows(`select * from public.create_ate_with_invite($1)`, [E]));
    await as(SPENDER, () => db.query(`select public.revoke_ate_with_invite($1)`, [inv.invite_id]));
  }
  assert.equal(await ledger(), 39, 'every invite spent one, though every invite was revoked');
  assert.equal((await tag(SPENDER, E, U.cleo))[0].status, 'pending', 'the 40th goes through');
  assert.equal(await code(SPENDER, `select * from public.tag_ate_with($1, $2)`, [E, U.dan]), '54000', 'the 41st is ate_with_rate_limited');
  assert.equal(await code(SPENDER, `select * from public.create_ate_with_invite($1)`, [E]), '54000');
  assert.equal(await code(SPENDER, `select * from public.ate_with_ledger`), '42501', 'no client read of the ledger');

  // 21 tags of cleo on this entry, none untagged after delivery: one live row, and it is loud
  // (quiet needs an earlier tag that reached her — see the quiet re-tag test).
  const live = (await inbox(U.cleo)).filter((n) => n.entry_id === E);
  assert.equal(live.length, 1, 'one live notification row at a time');
  assert.equal(live[0].read_at, null);
});

test('seats: a declined tag keeps its seat', async () => {
  const E = await w.visit(92, HOST, P.marion, receipt(['Olives']), '2026-09-22T09:00:00Z');
  const people = [U.alice, U.bob, U.cleo, U.dan, X[0], X[1]];
  const tags = [];
  for (const uid of people) tags.push((await tag(HOST, E, uid))[0]);
  await as(X[0], () => db.query(`select public.decline_ate_with($1)`, [tags[4].companion_id]));
  assert.equal(await code(HOST, `select * from public.tag_ate_with($1, $2)`, [E, X[3]]), '54000', 'six seats, one of them a decline');
  assert.equal((await as(HOST, () => rows(`select public.untag_ate_with($1, $2) n`, [E, X[0]])))[0].n, 0, 'untag cannot free it');
  assert.equal(await code(HOST, `select * from public.create_ate_with_invite($1)`, [E]), '54000');
});

test('entry_with_people called directly applies the entries rule: blocked by the author reads []', async () => {
  const direct = async (uid, entry) => (await as(uid, () => rows(`select public.entry_with_people($1) p`, [entry])))[0].p;
  assert.deepEqual((await direct(U.cleo, id(10))).map((p) => p.username), ['bob'], 'an unblocked viewer sees the accepted "with"');
  await as(U.alice, () => db.query(`select public.block_user($1)`, [U.dan]));
  assert.deepEqual(await direct(U.dan, id(10)), [], 'blocked by the author: nothing');
  assert.deepEqual(await direct(U.dan, id(11)), [], 'and the response entry no longer names the author either');
  assert.deepEqual((await direct(U.alice, id(10))).map((p) => p.username), ['bob'], 'the author still sees their own');
  assert.equal(await code(null, `select public.entry_with_people($1)`, [id(10)]), '42501', 'anon: no grant');
  await as(U.alice, () => db.query(`select public.unblock_user($1)`, [U.dan]));
});

test('my_notifications: a half cursor is 22023', async () => {
  assert.equal(await code(U.cleo, `select * from public.my_notifications(30, now(), null)`), '22023');
  assert.equal(await code(U.cleo, `select * from public.my_notifications(30, null, $1)`, [id(1)]), '22023');
});

test('quiet re-tag only after a delivered tag: immediate untag → loud; delivered → quiet; others loud', async () => {
  const E = await w.visit(94, HOST, P.osteria, receipt(['Cannoli']), '2026-09-23T09:00:00Z');
  const F = await w.visit(95, HOST, P.tipo, receipt(['Gnocchi']), '2026-09-23T10:00:00Z');
  const loud = async (entry, who) => (await rows(`select n.read_at is null and n.pushed_at is null loud
    from public.notifications n join public.entry_companions c on c.id = n.companion_id
    where c.entry_id = $1 and c.companion_id = $2 and n.dismissed_at is null`, [entry, who]))[0]?.loud;
  const untag = (entry, who) => as(HOST, () => db.query(`select public.untag_ate_with($1, $2)`, [entry, who]));

  // (a) tag → untag before anything was delivered → re-tag is LOUD
  await tag(HOST, E, X[4]);
  await untag(E, X[4]);
  await tag(HOST, E, X[4]);
  assert.equal(await loud(E, X[4]), true, 'nothing reached them, so the re-tag must');

  // (b) tag delivered (pushed by the sender) → untag → re-tag is QUIET
  await asService(() => db.query(`update public.notifications n set pushed_at = now() from public.entry_companions c
    where c.id = n.companion_id and c.entry_id = $1 and c.companion_id = $2`, [E, X[4]]));
  await untag(E, X[4]);
  await tag(HOST, E, X[4]);
  assert.equal(await loud(E, X[4]), false, 'already alerted once today: quiet');
  // …and delivered by being READ counts too
  await tag(HOST, E, X[5]);
  await prefill(X[5], (await inbox(X[5])).find((n) => n.entry_id === E).companion_id);
  await untag(E, X[5]);
  await tag(HOST, E, X[5]);
  assert.equal(await loud(E, X[5]), false, 'read counts as delivered');

  // (c) a different person on the same entry, and the same person on a different entry, stay loud
  await tag(HOST, E, X[3]);
  assert.equal(await loud(E, X[3]), true, 'a different person');
  await tag(HOST, F, X[4]);
  assert.equal(await loud(F, X[4]), true, 'a different entry');
});

test('delete_account: tags on both sides and tokens cascade; the other party keeps their own entry', async () => {
  const E = await w.visit(80, X[2], P.tipo, receipt(['Gnocchi', 4]), '2026-09-20T09:00:00Z');
  const [t] = await tag(X[2], E, X[3]);
  const g = (await prefill(X[3], t.companion_id)).dishes[0].dish_id;
  await respond(X[3], t.companion_id, id(81), [{ dish_id: g, score: 3.5 }]);
  await as(X[2], () => db.query(`select public.register_push_token($1, 'production')`, ['ef'.repeat(32)]));
  const out = (await as(X[2], () => rows(`select public.delete_account() r`)))[0].r;
  assert.deepEqual(out, { ok: true, auth_user_deleted: true });
  const c = await card(X[3], id(81));
  assert.equal(c.author_id, X[3], 'the responder\'s entry is theirs and survives');
  assert.deepEqual(c.companions, [], 'the link went with the deleted account');
});
