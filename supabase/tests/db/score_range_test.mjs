// supabase/tests/db/score_range_test.mjs — the score range's ceiling (0054): the track ends at 6, so a
// top of 5.0 is a real ceiling ("5.0s" = exactly 5.0, no secret 6); only a top of 6 (or none) is open.
// Every read that filters on a score range goes through score_in_range — each is checked here.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, receipt } from './fixtures.mjs';

let w, db, as, rows;
const E = {};

before(async () => {
  w = await world();
  ({ db, as, rows } = w);
  E.six = await w.visit(1, U.alice, P.tipo, receipt(['Pasta sei', 6]), '2026-09-01T09:00:00Z');
  E.five = await w.visit(2, U.alice, P.marion, receipt(['Pasta cinque', 5]), '2026-09-02T09:00:00Z');
  E.three = await w.visit(3, U.alice, P.osteria, receipt(['Pasta tre', 3]), '2026-09-03T09:00:00Z');
  await w.visit(4, U.alice, P.tipo, receipt(['Pasta niente']), '2026-09-04T09:00:00Z'); // unscored
  for (const e of [E.six, E.five, E.three]) await as(U.alice, () => db.query(`select public.save_entry_dishes($1)`, [e]));
});
after(async () => db?.close());

const named = (min, max) => `p_min_score => ${min ?? 'null'}::numeric, p_max_score => ${max ?? 'null'}::numeric`;
const sorted = (xs) => [...xs].sort();

async function everyRead(min, max) {
  const r = (sql) => as(U.alice, () => rows(sql));
  const f = named(min, max);
  return {
    my_entries: sorted((await r(`select best_score::float s from public.my_entries(${f})`)).map((x) => x.s)),
    my_entries_count: (await r(`select public.my_entries_count(${f}) n`))[0].n,
    journal_days: (await r(`select coalesce(sum(entries), 0)::int n from public.journal_days(null, null, null, ${f})`))[0].n,
    search_dishes: sorted((await r(`select score::float s from public.search_dishes(p_query => 'pasta', ${f})`)).map((x) => x.s)),
    search_places: sorted((await r(`select avg_rating::float s from public.search_places(p_query => 'ri', ${f})`)).map((x) => x.s)),
    nearby_places: sorted((await r(`select avg_rating::float s from public.nearby_places(p_lat => -37.8136, p_lng => 144.9631, p_radius_m => 20000, ${f})`)).map((x) => x.s)),
    search_saved: sorted((await r(`select dish_score::float s from public.search_saved(p_query => null, ${f})`)).map((x) => x.s)),
  };
}

const expect = (scores, { places = scores.filter((s) => s !== 6) } = {}) => ({
  my_entries: sorted(scores),
  my_entries_count: scores.length,
  journal_days: scores.length,
  search_dishes: sorted(scores),
  search_places: sorted(places), //   Marion (5) and Osteria Ilaria (3) match "ri"; Tipo 00 (6) does not
  nearby_places: sorted(scores),
  search_saved: sorted(scores),
});

test('0054: score_in_range — the top opens only at 6', async () => {
  const ok = async (s, min, max) => (await as(U.alice, () => rows(`select public.score_in_range($1, $2, $3) ok`, [s, min, max])))[0].ok;
  assert.equal(await ok(6, 5, 5), false, '"5.0s" leaves a 6 out');
  assert.equal(await ok(5.3, 3, 5), false, 'an average a 6 lifted past 5 is above a ceiling of 5');
  assert.equal(await ok(6, 5, 6), true);
  assert.equal(await ok(6, 5, null), true, 'no ceiling is open');
  assert.equal(await ok(5.3, null, 5.5), true);
  assert.equal(await ok(null, null, null), true, 'no bound keeps the unscored');
  assert.equal(await ok(null, 0.5, 6), false, 'any bound drops the unscored');
});

test('0054: "5.0s" (5–5) leaves a 6 out, on every read', async () => {
  assert.deepEqual(await everyRead(5, 5), expect([5]));
});

test('0054: 3.0–5.0 leaves 6s out, on every read', async () => {
  assert.deepEqual(await everyRead(3, 5), expect([3, 5]));
});

test('0054: 5–6 (and 5 with no ceiling) keeps the 6s, on every read', async () => {
  assert.deepEqual(await everyRead(5, 6), expect([5, 6]));
  assert.deepEqual(await everyRead(5, null), expect([5, 6]));
  assert.deepEqual(await everyRead(6, 6), expect([6]), 'only 6s');
});

test('0054: no range is still everything, the unscored included', async () => {
  const all = await everyRead(null, null);
  assert.equal(all.my_entries_count, 4);
  assert.equal(all.journal_days, 4);
  assert.deepEqual(all.my_entries, sorted([6, 5, 3, null]));
});
