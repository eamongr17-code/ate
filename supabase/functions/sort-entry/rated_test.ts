// supabase/functions/sort-entry/rated_test.ts
//
//   node --test supabase/functions/sort-entry/rated_test.ts
//
// ONLY RATED DISHES (17 Oct): an unrated line is dropped, and with `score_tokens` only a pill's
// number is a rating.

import { test, assertEquals } from './harness.ts';
import { attachScoreTokens, keepRated, parseScoreTokens, printable } from './rated.ts';
import { scalarOffset } from './offsets.ts';
import { parseEntry } from './parse.ts';
import { validatePlan } from './validate.ts';
import type { SortItem, SortPlan } from './types.ts';

function line(body: string, dish: string, evidence: string | null, score: number | null): SortItem {
  const at = evidence ? scalarOffset(body, body.lastIndexOf(evidence)) : null;
  return {
    dish_name: dish, score, score_evidence: evidence, note: null, evidence_offset: at,
    mention_text: dish, mention_offset: scalarOffset(body, body.indexOf(dish)),
  };
}

test('an unrated line is a description, not a dish', () => {
  const body = 'Pad thai with crispy pork belly 4.5';
  const items = [line(body, 'Pad thai', '4.5', 4.5), line(body, 'crispy pork belly', null, null)];
  assertEquals(keepRated(items, null, body).map((i) => i.dish_name), ['Pad thai']);
});

test('without score_tokens, a prose score still counts (older clients)', () => {
  const body = 'The ragù was a solid four';
  assertEquals(keepRated([line(body, 'ragù', 'a solid four', 4)], null, body).length, 1);
});

test('with score_tokens, only a pill is a rating', () => {
  const body = 'Waited 4 minutes. Ragù 4.5, tiramisu a solid four';
  const pill = { offset: scalarOffset(body, body.indexOf('4.5')), length: 3 };
  const items = [line(body, 'Ragù', '4.5', 4.5), line(body, 'tiramisu', 'a solid four', 4)];
  assertEquals(keepRated(items, [pill], body).map((i) => i.dish_name), ['Ragù']);
});

test('a pill inside a longer evidence phrase counts', () => {
  const body = 'Gnocchi 4 out of 5';
  const pill = { offset: body.indexOf('4'), length: 1 };
  assertEquals(keepRated([line(body, 'Gnocchi', '4 out of 5', 4)], [pill], body).length, 1);
});

test('an empty score_tokens list means no ratings, so no dishes', () => {
  const body = 'Margherita 4.5';
  assertEquals(keepRated([line(body, 'Margherita', '4.5', 4.5)], [], body), []);
});

test('evidence the model pointed at prose moves onto the pill', () => {
  const body = 'Waited 4.5 hrs. Brisket 4.5';
  const pillAt = body.lastIndexOf('4.5');
  const item = { ...line(body, 'Brisket', '4.5', 4.5), evidence_offset: body.indexOf('4.5') };
  const kept = keepRated([item], [{ offset: pillAt, length: 3 }], body);
  assertEquals(kept.map((i) => i.evidence_offset), [pillAt]);
});

test('score_tokens: absent is null, malformed spans dropped', () => {
  assertEquals(parseScoreTokens(undefined), null);
  assertEquals(parseScoreTokens('x'), null);
  assertEquals(parseScoreTokens([{ offset: 3, length: 3 }, { offset: -1, length: 1 }]), [{ offset: 3, length: 3 }]);
});

test('a pill nobody claimed scores the dish named just before it', () => {
  const body = 'Batch Brew, did the job 3.0 hard to really blow my mind here.';
  const pill = { offset: body.indexOf('3.0'), length: 3 };
  const attached = attachScoreTokens([line(body, 'Batch Brew', null, null)], [pill], body);
  const kept = keepRated(attached, [pill], body);
  assertEquals(kept.map((i) => [i.dish_name, i.score, i.score_evidence, i.evidence_offset]), [['Batch Brew', 3, '3.0', pill.offset]]);
});

test('a claimed pill or an already-scored line is left alone', () => {
  const body = 'Ragù 4.5 and 3.0';
  const marks = [{ offset: 5, length: 3 }, { offset: 13, length: 3 }];
  const out = attachScoreTokens([line(body, 'Ragù', '4.5', 4.5)], marks, body);
  assertEquals(out.map((i) => [i.score, i.evidence_offset]), [[4.5, 5]]);
});

test('the model reading a dish as the venue prints nothing; the parser prints the dish (prod, 27 Oct)', () => {
  const body = 'Beach Mezze 3.0, everything was fresh and tasty, but I was hoping for more (better) pita bread tbh V';
  const pill = { offset: 12, length: 3 };
  // What the model returned at a picked place: the dish taken as place_query, an unscored pita bread.
  const model: SortPlan = {
    place_query: 'Beach Mezze 3.0', place_offset: null,
    items: [{ ...line(body, 'pita bread', null, null), mention_offset: null }],
  };
  assertEquals(printable(model, [pill], body), 0);
  const parsed = validatePlan(parseEntry({ body, knownDishes: [], placeNames: ['The Lazy Coconut'] }), {
    body, knownDishes: [], sixSpans: [],
  });
  assertEquals(printable(parsed, [pill], body), 1);
  assertEquals(keepRated(parsed.items, [pill], body).map((i) => [i.dish_name, i.score]), [['Beach Mezze', 3]]);
  // With no pill at all there is nothing to print either way: a number typed as words is not a score.
  assertEquals(printable(parsed, [], body), 0);
});
