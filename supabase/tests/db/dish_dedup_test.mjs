// supabase/tests/db/dish_dedup_test.mjs — same dish, different names (0071).
//
//   cd supabase/tests/db && npm ci && node --test
//
// The spelling key against the same table sort-entry's same-dish_test.ts reads, find_or_create_dish's
// new lookups (the key, and merged-away names as aliases), merge_dish carrying everything that points
// at a dish and refusing what it must, unmerge_dish putting it all back, and the proposals path.

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { world, U, P, receipt } from './fixtures.mjs';

const cases = JSON.parse(readFileSync(new URL('../../functions/sort-entry/dish-key-cases.json', import.meta.url), 'utf8'));

let w, db, as, asService, rows, error;
after(async () => db?.close());

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
});

const key = async (name) => (await rows(`select public.dish_key($1) k`, [name]))[0].k;
const find = async (place, name) =>
  (await asService(() => rows(`select public.find_or_create_dish($1, $2) id`, [place, name])))[0].id;
const dishOf = async (entry, name) =>
  (await rows(`select r.id review_id, r.dish_id from public.reviews r join public.dishes d on d.id = r.dish_id
               where r.entry_id = $1 and d.name = $2`, [entry, name]))[0];
const merge = (src, tgt, reason = 'manual') =>
  asService(() => rows(`select public.merge_dish($1, $2, $3) id`, [src, tgt, reason])).then((r) => r[0].id);
const code = async (p) => (await error(p))?.code ?? null;
const live = async (dish) => (await rows(`select merged_into_dish_id is null l from public.dishes where id = $1`, [dish]))[0].l;

test('dish_key is sort-entry\'s dishKey: one table of names pins both', async () => {
  for (const [a, b] of cases.same) assert.equal(await key(a), await key(b), `${a} / ${b}`);
  for (const [a, b] of cases.different) assert.notEqual(await key(a), await key(b), `${a} / ${b}`);
  for (const [name, k] of cases.keys) assert.equal(await key(name), k, name);
});

test('find_or_create_dish: the same dish spelled another way is the existing dish, at that place only', async () => {
  const g = await find(P.tipo, 'Gnocchi');
  assert.equal(await find(P.tipo, 'gnocchis'), g);
  assert.equal(await find(P.tipo, 'GNOCCHI!'), g);
  assert.notEqual(await find(P.marion, 'Gnocchis'), g, 'another place is another dish');
  const mac = await find(P.tipo, 'Mac & Cheese');
  assert.equal(await find(P.tipo, 'mac and cheese'), mac);
  // nothing presumed: a different word is a different dish
  assert.notEqual(await find(P.tipo, 'Gnocchi Sorrentina'), g);
  assert.notEqual(await find(P.tipo, 'Chocolate Milk'), await find(P.tipo, 'Milk Chocolate'));
  // the new dish keeps the display rules
  const [{ name }] = await rows(`select name from public.dishes where id = $1`, [await find(P.tipo, 'pork  and chive dumplings')]);
  assert.equal(name, 'Pork and Chive Dumplings');
});

test('merge_dish: lines, saves, list items and photo picks follow; the old name becomes an alias', async () => {
  const e1 = await w.visit(1, U.alice, P.osteria, receipt(['Carbonara', 4]), '2026-10-01T09:00:00Z');
  const e2 = await w.visit(2, U.bob, P.osteria, receipt(['Spaghetti Carbonara', 5]), '2026-10-02T09:00:00Z');
  const src = await dishOf(e1, 'Carbonara');
  const tgt = await dishOf(e2, 'Spaghetti Carbonara');
  await db.query(`insert into public.saves (user_id, dish_id) values ($1, $2), ($3, $2), ($3, $4)`,
    [U.cleo, src.dish_id, U.dan, tgt.dish_id]);
  const [{ list_id }] = await as(U.alice, () => rows(`select list_id from public.create_list('Pasta')`));
  await as(U.alice, () => db.query(`select public.add_list_item($1, $2, $3)`, [list_id, e1, src.dish_id]));
  await db.query(`update public.entries set photo_picks = jsonb_build_object('p1', 'carbonara') where id = $1`, [e1]);

  const m = await merge(src.dish_id, tgt.dish_id, 'ai');
  assert.equal(await live(src.dish_id), false);
  assert.equal((await dishOf(e1, 'Spaghetti Carbonara'))?.dish_id, tgt.dish_id, 'the line moved');
  const saves = await rows(`select user_id from public.saves where dish_id = $1 order by user_id`, [tgt.dish_id]);
  assert.deepEqual(saves.map((s) => s.user_id), [U.cleo, U.dan], 'cleo\'s save moved; dan held both and keeps one');
  const [item] = await rows(`select dish_id from public.user_list_items where list_id = $1`, [list_id]);
  assert.equal(item.dish_id, tgt.dish_id, 'the list item followed');
  const [{ photo_picks }] = await rows(`select photo_picks from public.entries where id = $1`, [e1]);
  assert.deepEqual(photo_picks, { p1: 'spaghetti carbonara' });
  const [stats] = await rows(`select review_count from public.dish_stats where dish_id = $1`, [tgt.dish_id]);
  assert.equal(Number(stats.review_count), 2, 'one dish, both lines');

  // a re-sort that prints the old name lands on the survivor, not a new twin
  assert.equal(await find(P.osteria, 'Carbonara'), tgt.dish_id);
  assert.equal(await find(P.osteria, 'carbonaras'), tgt.dish_id, 'the alias by spelling key too');

  // the log says what moved
  const [log] = await rows(`select reason, source_name, target_name, cardinality(moved_review_ids) n from public.dish_merges where id = $1`, [m]);
  assert.deepEqual({ ...log, n: Number(log.n) }, { reason: 'ai', source_name: 'Carbonara', target_name: 'Spaghetti Carbonara', n: 1 });
});

test('unmerge_dish splits it back out, by entry even after a re-sort re-minted the line', async () => {
  const e1 = await w.visit(10, U.alice, P.marion, receipt(['Olives', 3]), '2026-10-03T09:00:00Z');
  const e2 = await w.visit(11, U.bob, P.marion, receipt(['Green Olives', 4]), '2026-10-03T10:00:00Z');
  const src = await dishOf(e1, 'Olives');
  const tgt = await dishOf(e2, 'Green Olives');
  await db.query(`insert into public.saves (user_id, dish_id) values ($1, $2), ($3, $2), ($3, $4)`,
    [U.cleo, src.dish_id, U.dan, tgt.dish_id]);
  const m = await merge(src.dish_id, tgt.dish_id);
  // the author edits; the sorter prints the old name, which resolves to the survivor
  await w.sortAs(e1, P.marion, receipt(['Olives', 3]).items);
  assert.equal((await dishOf(e1, 'Green Olives'))?.dish_id, tgt.dish_id);

  assert.equal((await asService(() => rows(`select public.unmerge_dish($1) id`, [m])))[0].id, src.dish_id);
  assert.equal(await live(src.dish_id), true);
  assert.equal((await dishOf(e1, 'Olives'))?.dish_id, src.dish_id, 'the re-minted line went back');
  assert.equal((await dishOf(e2, 'Green Olives'))?.dish_id, tgt.dish_id, 'the target\'s own line stayed');
  const saves = await rows(`select user_id, dish_id from public.saves where user_id in ($1, $2) and dish_id in ($3, $4) order by user_id, dish_id`,
    [U.cleo, U.dan, src.dish_id, tgt.dish_id]);
  assert.deepEqual(saves.map((s) => [s.user_id, s.dish_id === src.dish_id ? 'src' : 'tgt']).sort(),
    [[U.cleo, 'src'], [U.dan, 'src'], [U.dan, 'tgt']].sort(), 'every save as it was');
  assert.equal(await code(asService(() => rows(`select public.unmerge_dish($1)`, [m]))), '22023', 'once only');
  assert.equal(await find(P.marion, 'Olives'), src.dish_id, 'no longer an alias');
});

test('merge_dish refuses two places, one entry naming both, and a client caller', async () => {
  const a = await find(P.tipo, 'Ribeye');
  const b = await find(P.marion, 'Ribeye Steak');
  assert.equal(await code(merge(a, b)), '22023', 'different places');

  const e = await w.visit(20, U.alice, P.tipo, receipt(['Pappardelle', 4], ['Pappardelle Ragu', 3]), '2026-10-04T09:00:00Z');
  const x = await dishOf(e, 'Pappardelle');
  const y = await dishOf(e, 'Pappardelle Ragu');
  assert.equal(await code(merge(x.dish_id, y.dish_id)), '22023', 'the diner told them apart');

  assert.equal(await code(as(U.alice, () => rows(`select public.merge_dish($1, $2)`, [x.dish_id, a]))), '42501');
  assert.equal(await code(as(U.alice, () => rows(`select * from public.dish_merges`))), '42501');
  assert.equal(await code(as(U.alice, () => rows(`select * from public.dish_merge_proposals`))), '42501');
});

test('the scan\'s read and the approved merge: stale proposals are marked, never forced', async () => {
  const e1 = await w.visit(30, U.cleo, P.far, receipt(['Pad Thai', 4]), '2026-10-05T09:00:00Z');
  const e2 = await w.visit(31, U.dan, P.far, receipt(['Pad Thai Chicken', 3], ['Green Curry', 4]), '2026-10-05T10:00:00Z');
  const e3 = await w.visit(32, U.dan, P.far, receipt(['Massaman', 4], ['Massaman Curry', 3]), '2026-10-05T11:00:00Z');
  const places = await asService(() => rows(`select * from public.dish_scan_places() where restaurant_id = $1`, [P.far]));
  assert.equal(places.length, 1);
  assert.deepEqual(places[0].dishes.map((d) => d.name).sort(), ['Green Curry', 'Massaman', 'Massaman Curry', 'Pad Thai', 'Pad Thai Chicken']);
  const m1 = await dishOf(e3, 'Massaman');
  const m2 = await dishOf(e3, 'Massaman Curry');
  const pair = [m1.dish_id, m2.dish_id].sort();
  assert.ok(places[0].shared_pairs.some((p) => p[0] === pair[0] && p[1] === pair[1]), 'the pair one entry names is listed');

  const p1 = await dishOf(e1, 'Pad Thai');
  const p2 = await dishOf(e2, 'Pad Thai Chicken');
  const [{ ok }, { bad }] = await asService(async () => [
    (await rows(`insert into public.dish_merge_proposals (restaurant_id, source_dish_id, target_dish_id, source_name, target_name, reason)
                 values ($1, $2, $3, 'Pad Thai', 'Pad Thai Chicken', 'ai') returning id ok`, [P.far, p1.dish_id, p2.dish_id]))[0],
    (await rows(`insert into public.dish_merge_proposals (restaurant_id, source_dish_id, target_dish_id, source_name, target_name, reason)
                 values ($1, $2, $3, 'Massaman', 'Massaman Curry', 'ai') returning id bad`, [P.far, m1.dish_id, m2.dish_id]))[0],
  ]);
  const out = await asService(() => rows(`select * from public.merge_dish_proposals($1::bigint[])`, [[ok, bad]]));
  assert.deepEqual(out.map((r) => [Number(r.proposal_id), r.status]), [[Number(ok), 'merged'], [Number(bad), 'stale']]);
  assert.match(out[1].note, /dishes_share_an_entry/);
  assert.equal(await live(p1.dish_id), false);
  assert.equal(await live(m1.dish_id), true, 'a refused merge changes nothing');
  assert.deepEqual(await asService(() => rows(`select * from public.merge_dish_proposals()`)), [], 'nothing left open');
});

test('a merged dish id still resolves to its survivor, for old links', async () => {
  const [{ id: d }] = await rows(`select id from public.dishes where name = 'Carbonara' and restaurant_id = $1`, [P.osteria]);
  const [{ r }] = await rows(`select public.resolve_dish($1) r`, [d]);
  const [{ t }] = await rows(`select id t from public.dishes where name = 'Spaghetti Carbonara' and restaurant_id = $1`, [P.osteria]);
  assert.equal(r, t);
});
