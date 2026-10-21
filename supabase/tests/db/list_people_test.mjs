// supabase/tests/db/list_people_test.mjs — list covers + people on a list (0073): custom covers (dish
// photo or own upload, back to automatic when the item leaves), invites (notification, push claim, quiet
// re-invite), accept / decline / leave, members read but never write, the shared shelf, and blocks.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, receipt, photoUrl } from './fixtures.mjs';

let w, db, as, asService, rows, error;
after(async () => db?.close());

const code = async (uid, sql, params) => (await as(uid, () => error(db.query(sql, params))))?.code ?? null;
const one = async (uid, sql, params) => (await as(uid, () => rows(sql, params)))[0];
const create = (uid, name) => one(uid, `select * from public.create_list($1)`, [name]);
const add = (uid, list, entry, dish) => one(uid, `select * from public.add_list_item($1, $2, $3)`, [list, entry, dish]);
const getList = async (uid, list) => (await one(uid, `select public.get_list($1) l`, [list])).l;
const people = (uid, list, ids) => as(uid, () => rows(`select * from public.set_list_people($1, $2::uuid[])`, [list, ids]));
const invites = (uid) => as(uid, () => rows(`select * from public.my_list_invites()`));
const respond = async (uid, list, yes) => (await one(uid, `select public.respond_list_invite($1, $2) r`, [list, yes])).r;
const shelf = (uid, shared = true) => as(uid, () => rows(`select * from public.my_lists(p_with_shared => $1)`, [shared]));
const unread = async (uid) => (await one(uid, `select public.unread_notification_count() n`)).n;
const claim = () => asService(() => rows(`select * from public.push_claim_list_invites(50)`));
const dishOf = async (entry, name) =>
  (await rows(`select r.dish_id from public.reviews r join public.dishes d on d.id = r.dish_id
               where r.entry_id = $1 and d.name = $2`, [entry, name]))[0].dish_id;
const coverUrl = (uid, file) => photoUrl(`${uid}/list-covers/${file}`);

let A1, L, items;
before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
  A1 = await w.visit(1, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu', 5]), '2026-09-01T09:00:00Z',
    { photos: ['a/1.jpg'] });
  // The photo is the tiramisu's (0079: a two-dish visit's photo is no dish's until matched).
  const [tiramisu] = await rows(`select r.id from public.reviews r join public.dishes d on d.id = r.dish_id
                                 where r.entry_id = $1 and d.name = 'Tiramisu'`, [A1]);
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb)`,
    [A1, JSON.stringify([{ review_id: tiramisu.id, photo_url: photoUrl('a/1.jpg') }])]));
  L = await create(U.alice, 'Date night');
  await add(U.alice, L.list_id, A1, await dishOf(A1, 'Gnocchi'));
  await add(U.alice, L.list_id, A1, await dishOf(A1, 'Tiramisu'));
  items = (await getList(U.alice, L.list_id)).items;
});

// ---------------------------------------------------------------------------------------------------
test('covers: automatic by default, a dish photo, an upload, back to automatic', async () => {
  let g = await getList(U.alice, L.list_id);
  assert.equal(g.cover_url, null, 'automatic');
  assert.deepEqual(g.covers, [photoUrl('a/1.jpg')]);

  const pick = await one(U.alice, `select public.set_list_cover($1, $2) c`, [L.list_id, items[1].item_id]);
  assert.equal(pick.c.cover_url, photoUrl('a/1.jpg'));
  g = await getList(U.alice, L.list_id);
  assert.equal(g.cover_item_id, items[1].item_id);
  assert.equal((await shelf(U.alice)).find((r) => r.list_id === L.list_id).cover_url, photoUrl('a/1.jpg'));

  const url = coverUrl(U.alice, `${L.list_id}.jpg`) + '?v=1760000000';
  await one(U.alice, `select public.set_list_cover($1, null, $2) c`, [L.list_id, url]);
  g = await getList(U.alice, L.list_id);
  assert.equal(g.cover_url, url);
  assert.equal(g.cover_item_id, null, 'one cover at a time');

  for (const bad of [
    coverUrl(U.bob, 'x.jpg'),                                               // someone else's folder
    photoUrl(`${U.alice}/x.jpg`),                                           // not under list-covers/
    'https://evil.example/storage/v1/object/public/review-photos/x.jpg',
    'http://' + coverUrl(U.alice, 'x.jpg').slice(8),                        // not https
    coverUrl(U.alice, '../x.jpg'),
  ]) assert.equal(await code(U.alice, `select public.set_list_cover($1, null, $2)`, [L.list_id, bad]), '22023', bad);
  assert.equal(await code(U.alice, `select public.set_list_cover($1, $2, $3)`, [L.list_id, items[0].item_id, url]), '22023');
  assert.equal(await code(U.alice, `select public.set_list_cover($1, $2)`, [L.list_id, '00000000-0000-4000-8000-000000000999']), 'P0002');
  assert.equal(await code(U.bob, `select public.set_list_cover($1)`, [L.list_id]), 'P0002', 'not yours');

  // Item pick, then the item leaves the list → automatic again.
  await one(U.alice, `select public.set_list_cover($1, $2) c`, [L.list_id, items[1].item_id]);
  await one(U.alice, `select public.remove_list_item($1) n`, [items[1].item_id]);
  g = await getList(U.alice, L.list_id);
  assert.equal(g.cover_url, null, 'its item left: automatic');
  await add(U.alice, L.list_id, A1, await dishOf(A1, 'Tiramisu'));
  items = (await getList(U.alice, L.list_id)).items;

  await one(U.alice, `select public.set_list_cover($1) c`, [L.list_id]);
  assert.equal((await getList(U.alice, L.list_id)).cover_url, null, 'neither = automatic');
});

test('people: invite → notification, push claim, accept → shared shelf; members never write', async () => {
  assert.deepEqual(await shelf(U.bob), [], 'nothing before an invite');
  assert.equal(await code(U.bob, `select public.get_list($1)`, [L.list_id]), 'P0002');

  const after = await people(U.alice, L.list_id, [U.bob, U.cleo, U.alice]);
  assert.deepEqual(after.map((p) => p.status).sort(), ['invited', 'invited'], 'yourself skipped');

  const inv = await invites(U.bob);
  assert.equal(inv.length, 1);
  assert.equal(inv[0].name, 'Date night');
  assert.equal(inv[0].item_count, 2);
  assert.equal(inv[0].owner.id, U.alice);
  assert.equal(await unread(U.bob), 1, 'the bell counts it');

  const pushes = await claim();
  assert.deepEqual(pushes.map((p) => p.recipient_id).sort(), [U.bob, U.cleo].sort());
  const bobPush = pushes.find((p) => p.recipient_id === U.bob);
  assert.equal(bobPush.list_name, 'Date night');
  assert.equal(bobPush.badge, 1);
  assert.equal((await claim()).length, 0, 'claimed once');

  // Invited: a preview, not on the shelf yet.
  const preview = await getList(U.bob, L.list_id);
  assert.equal(preview.membership, 'invited');
  assert.equal(preview.is_own, false);
  assert.equal(preview.items.length, 2);
  assert.equal(preview.owner.id, U.alice);
  assert.deepEqual(await shelf(U.bob), []);

  assert.equal(await respond(U.bob, L.list_id, true), 'accepted');
  assert.deepEqual(await invites(U.bob), []);
  assert.equal(await unread(U.bob), 0);
  const s = await shelf(U.bob);
  assert.equal(s.length, 1);
  assert.equal(s[0].is_own, false);
  assert.equal(s[0].owner.id, U.alice);
  assert.equal((await shelf(U.bob, false)).length, 0, 'old callers: own lists only');
  assert.equal((await getList(U.bob, L.list_id)).membership, 'accepted');

  // The owner's people: bob accepted, cleo invited. Bob sees only the accepted.
  const owners = await as(U.alice, () => rows(`select * from public.list_people($1)`, [L.list_id]));
  assert.deepEqual(owners.map((p) => `${p.user_id}:${p.status}`), [`${U.bob}:accepted`, `${U.cleo}:invited`]);
  const bobs = await as(U.bob, () => rows(`select * from public.list_people($1)`, [L.list_id]));
  assert.deepEqual(bobs.map((p) => p.user_id), [U.bob]);

  // Members view; every write is the owner's.
  for (const sql of [
    [`select * from public.rename_list($1, 'mine')`, [L.list_id]],
    [`select * from public.add_list_item($1, $2, $3)`, [L.list_id, A1, items[0].dish_id]],
    [`select public.reorder_list($1, $2::uuid[])`, [L.list_id, items.map((i) => i.item_id)]],
    [`select public.set_list_cover($1)`, [L.list_id]],
    [`select * from public.set_list_people($1, '{}')`, [L.list_id]],
  ]) assert.equal(await code(U.bob, sql[0], sql[1]), 'P0002', sql[0]);
  assert.equal((await one(U.bob, `select public.remove_list_item($1) n`, [items[0].item_id])).n, 0);
  assert.equal((await one(U.bob, `select public.delete_list($1) n`, [L.list_id])).n, 0);
  assert.equal(await code(U.bob, `update public.user_list_members set status = 'invited'`), '42501');
  assert.equal(await code(U.bob, `insert into public.user_list_members (list_id, user_id) values ($1, $2)`, [L.list_id, U.dan]), '42501');

  // Dan, not on it, still sees nothing.
  assert.equal(await code(U.dan, `select public.get_list($1)`, [L.list_id]), 'P0002');
  assert.equal((await as(U.dan, () => rows(`select id from public.user_list_items where list_id = $1`, [L.list_id]))).length, 0);
});

test('decline is silent; untick withdraws; a quick re-invite is quiet; leave', async () => {
  assert.equal(await respond(U.cleo, L.list_id, false), 'declined');
  assert.deepEqual(await invites(U.cleo), []);
  assert.equal(await unread(U.cleo), 0);
  const owners = await as(U.alice, () => rows(`select * from public.list_people($1)`, [L.list_id]));
  assert.deepEqual(owners.map((p) => p.user_id), [U.bob], 'cleo simply gone');
  assert.equal(await code(U.cleo, `select public.respond_list_invite($1, true)`, [L.list_id]), 'P0002', 'no second answer');

  // Re-invited within the week: the row is back, but no push and no badge.
  await people(U.alice, L.list_id, [U.bob, U.cleo]);
  assert.equal((await invites(U.cleo)).length, 1);
  assert.equal(await unread(U.cleo), 1, 'still waiting on her');
  assert.equal((await claim()).length, 0, 'quiet: no second push');

  // Untick dan's fresh invite: withdrawn with its notification.
  await people(U.alice, L.list_id, [U.bob, U.cleo, U.dan]);
  assert.equal((await invites(U.dan)).length, 1);
  await people(U.alice, L.list_id, [U.bob, U.cleo]);
  assert.deepEqual(await invites(U.dan), []);
  assert.equal(await unread(U.dan), 0);
  assert.equal((await claim()).filter((p) => p.recipient_id === U.dan).length, 0, 'withdrawn before the push');

  // Bob leaves.
  assert.equal((await one(U.bob, `select public.leave_list($1) n`, [L.list_id])).n, 1);
  assert.deepEqual(await shelf(U.bob), []);
  assert.equal(await code(U.bob, `select public.get_list($1)`, [L.list_id]), 'P0002');
});

test('blocks hide a shared list both ways; caps; delete cascades', async () => {
  const B = await create(U.alice, 'Block test');
  await people(U.alice, B.list_id, [U.dan]);
  assert.equal(await respond(U.dan, B.list_id, true), 'accepted');
  await as(U.dan, () => db.query(`select public.block_user($1)`, [U.alice]));
  assert.equal(await code(U.dan, `select public.get_list($1)`, [B.list_id]), 'P0002');
  assert.equal((await shelf(U.dan)).filter((r) => r.list_id === B.list_id).length, 0);
  assert.deepEqual((await as(U.alice, () => rows(`select * from public.list_people($1)`, [B.list_id]))), []);
  assert.equal((await people(U.alice, B.list_id, [U.dan])).length, 0, 'cannot re-invite across a block');
  await as(U.dan, () => db.query(`select public.unblock_user($1)`, [U.alice]));

  const many = Array.from({ length: 21 }, (_, i) => `00000000-0000-4000-8000-${String(800 + i).padStart(12, '0')}`);
  for (const [i, uid] of many.entries()) {
    await db.query(`insert into auth.users (id, email) values ($1, $2)`, [uid, `cap${i}@ate.test`]);
  }
  assert.equal(await code(U.alice, `select * from public.set_list_people($1, $2::uuid[])`, [B.list_id, many]), '54000');

  await people(U.alice, B.list_id, [U.bob]);
  assert.equal((await one(U.alice, `select public.delete_list($1) n`, [B.list_id])).n, 1);
  assert.deepEqual(await invites(U.bob), []);
  assert.equal((await rows(`select count(*)::int n from public.notifications where list_id = $1`, [B.list_id]))[0].n, 0);
});
