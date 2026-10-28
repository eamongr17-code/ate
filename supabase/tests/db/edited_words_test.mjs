// supabase/tests/db/edited_words_test.mjs — 0097: changing an entry's words puts it back to printing,
// and a line never keeps a score its words no longer say (weekly audit, 28 Oct).
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, receipt } from './fixtures.mjs';

let w, db, as, asService, rows;

before(async () => {
  w = await world();
  ({ db, as, asService, rows } = w);
});
after(async () => db?.close());

const entry = async (E) => (await rows(`select sort_status from public.entries where id = $1`, [E]))[0];
const lines = async (E) => rows(
  `select r.score::float8 score, r.score_evidence, r.evidence_offset, r.mention_offset, d.name
     from public.reviews r join public.dishes d on d.id = r.dish_id
    where r.entry_id = $1 order by r.entry_position`, [E]);

test('new words: printing again; a score whose words are gone is dropped, the rest kept', async () => {
  const E = await w.visit(1, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu', 3]), '2026-09-01T09:00:00Z');
  assert.equal((await entry(E)).sort_status, 'sorted');

  // "Gnocchi 4.5. Tiramisu 3" → the Gnocchi score is gone, Tiramisu 3 moved to the front.
  await as(U.alice, () => db.query(`update public.entries set body = 'Tiramisu 3 and the gnocchi was fine' where id = $1`, [E]));
  assert.equal((await entry(E)).sort_status, 'pending', 'the receipt prints again');
  const [gnocchi, tiramisu] = await lines(E);
  assert.equal(gnocchi.score, null, 'no score without its words');
  assert.equal(gnocchi.score_evidence, null);
  assert.equal(gnocchi.evidence_offset, null);
  assert.equal(tiramisu.score, 3, 'still said, still scored');
  assert.equal(tiramisu.score_evidence, 'Tiramisu 3');
  const [{ n }] = await rows(`select count(*)::int n from public.reviews where entry_id = $1 and corrected_at is not null`, [E]);
  assert.equal(n, 0, 'the words dropped it: not a correction, so the next sort may score the line again');

  // The sort that follows prints it, as for a new entry.
  await w.sortAs(E, P.tipo, receipt(['Tiramisu', 3]).items);
  assert.equal((await entry(E)).sort_status, 'sorted');
});

test('a line the author corrected keeps its score; the same words, or a visibility change, change nothing', async () => {
  const E = await w.visit(2, U.bob, P.tipo, receipt(['Pie', 4], ['Salad', 2]), '2026-09-02T09:00:00Z');
  await db.query(`update public.reviews set corrected_at = now() where entry_id = $1 and entry_position = 1`, [E]);

  await as(U.bob, () => db.query(`update public.entries set body = body, visibility = 'private' where id = $1`, [E]));
  assert.equal((await entry(E)).sort_status, 'sorted', 'same words: nothing to reprint');
  assert.deepEqual((await lines(E)).map((l) => l.score), [4, 2]);

  await as(U.bob, () => db.query(`update public.entries set body = 'Just salad today' where id = $1`, [E]));
  const [pie, salad] = await lines(E);
  assert.equal(pie.score, 4, 'corrected by hand: the score is the author\'s');
  assert.equal(salad.score, null);
});

test('only the author, and only client writes', async () => {
  const E = await w.visit(3, U.cleo, P.tipo, receipt(['Pasta', 5]), '2026-09-03T09:00:00Z');

  // Another account can neither rewrite the words nor reach the lines through the helper.
  await as(U.dan, () => db.query(`update public.entries set body = 'nothing' where id = $1`, [E]));
  await as(U.dan, () => db.query(`select public.entry_words_changed($1, 'nothing')`, [E]));
  assert.equal((await entry(E)).sort_status, 'sorted');
  assert.equal((await lines(E))[0].score, 5);

  // The server's own writers (definer RPCs, service role) are not edits.
  await asService(() => db.query(`update public.entries set body = 'rewritten by the server' where id = $1`, [E]));
  assert.equal((await entry(E)).sort_status, 'sorted');
  assert.equal((await lines(E))[0].score, 5);
});
