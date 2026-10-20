// supabase/tests/db/tags_test.mjs — dietary tags on dish lines (0036) at the SQL level: the per-line
// PATCH (canonical, closed set, owner only, not a correction, survives a re-sort) and the dish's
// consensus. Ported from the staging suites DishTagsContractTests and DietTagsContractTests (merged).
// Where a marked chip lands in the words is sort-entry's job — functions/sort-entry/tags_test.ts.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, rows, error;

before(async () => {
  w = await world();
  ({ db, as, rows, error } = w);
});
after(async () => db?.close());

const line = async (entry, position) =>
  (await rows(`select id, dish_id, tags, corrected_at from public.reviews where entry_id = $1 and entry_position = $2`, [entry, position]))[0];
const patch = (uid, review, tags) => as(uid, () => db.query(`update public.reviews set tags = $2 where id = $1`, [review, tags]));
const consensus = async (dish, uid = U.bob) => (await as(uid, () => rows(`select tags, review_count from public.dish_summary($1)`, [dish])))[0];

test('0036: a PATCHed tag list is canonical, closed, owner-only, and not a correction', async () => {
  const E = await w.visit(1, U.alice, P.tipo, receipt(['Pasta', 4], ['Salad', 3]), '2026-09-01T09:00:00Z');
  const salad = await line(E, 2);
  assert.deepEqual(salad.tags, [], 'no tags is [], never null');

  await patch(U.alice, salad.id, ['VG', 'gf', 'gf', ' v ']);
  const after = await line(E, 2);
  assert.deepEqual(after.tags, ['gf', 'v', 'vg'], 'lowercased, trimmed, deduped, in gf df v vg nf order');
  assert.equal(after.corrected_at, null, 'a tag is not a correction');
  assert.equal((await as(U.alice, () => rows(`select items from public.entry_cards where id = $1`, [E])))[0].items[1].corrected, false);

  assert.equal((await as(U.alice, () => error(patch(U.alice, salad.id, ['xx']))))?.code, '23514', 'a code outside the closed set');
  await as(U.bob, () => error(patch(U.bob, salad.id, ['nf'])));
  assert.deepEqual((await line(E, 2)).tags, ['gf', 'v', 'vg'], 'RLS: a stranger cannot tag your line');
});

test('0036: a re-sort that does not mention a tag keeps it', async () => {
  const E = id(1);
  const salad = await line(E, 2);
  await w.sortAs(E, P.tipo, receipt(['Pasta', 4], ['Salad', 3]).items);
  assert.deepEqual((await line(E, 2)).tags, ['gf', 'v', 'vg']);
  assert.equal((await line(E, 2)).dish_id, salad.dish_id);
});

test('0036 → 0074: dish_summary.tags is the LABEL rule (3 different people), signed in and out alike', async () => {
  // 0036's "half of the lines" rule was replaced by 0074's label; the full rule is diet_test.mjs.
  const E = await w.visit(2, U.bob, P.marion, receipt(['Risotto', 4, { tags: ['gf', 'v'] }]), '2026-10-02T09:00:00Z');
  const dish = (await line(E, 1)).dish_id;
  assert.deepEqual((await consensus(dish)).tags, [], 'one person is not a label');
  await w.visit(3, U.cleo, P.marion, receipt(['Risotto', 3, { tags: ['v'] }]), '2026-10-03T09:00:00Z');
  await w.visit(4, U.dan, P.marion, receipt(['Risotto', 5, { tags: ['v'] }]), '2026-10-04T09:00:00Z');
  assert.deepEqual(await consensus(dish), { tags: ['v'], review_count: 3 }, 'v: three people; gf: one');
  assert.deepEqual((await consensus(dish, null)).tags, ['v'], 'signed out agrees');
  const [menu] = await as(null, () => rows(`select tags, diet_counts from public.place_dishes($1) where dish_id = $2`, [P.marion, dish]));
  assert.deepEqual(menu, { tags: ['v'], diet_counts: { gf: 1 } }, 'the menu row carries the same chips, and the count below');
});
