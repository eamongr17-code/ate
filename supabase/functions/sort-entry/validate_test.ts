// supabase/functions/sort-entry/validate_test.ts
//
//   deno test --no-check supabase/functions/sort-entry/
//   node --test supabase/functions/sort-entry/validate_test.ts
//
// THE GATE. These tests are written as ATTACKS: each one is a plan a careless model
// could plausibly return, and each must be neutralised. The same checks exist again in
// SQL (apply_entry_sort, migration 0021) — this is the first of the two, not the only
// one, because a bug here must not be able to write a lie.

import { test, assert, assertEquals } from './harness.ts';
import { evidenceSupportsScore, MAX_ITEMS, validateItem, validatePlan } from './validate.ts';
import type { SortItem } from './types.ts';

const BODY = 'Tipo 00. The tagliatelle al ragù 4.5 was unreal. Tiramisu, no number given, but lovely.';
const item = (over: Partial<SortItem> = {}): SortItem => ({
  dish_name: 'Tagliatelle al ragù',
  score: 4.5,
  score_evidence: '4.5',
  note: 'unreal.',
  ...over,
});

// ---------------------------------------------------------------------------
// RULE 7 — the score must be the user's
// ---------------------------------------------------------------------------
test('a score with NO evidence is dropped, the dish survives', () => {
  const out = validateItem(item({ score_evidence: null }), { body: BODY })!;
  assertEquals(out.score, null);
  assertEquals(out.score_evidence, null);
  assertEquals(out.dish_name, 'Tagliatelle al ragù');
});

test('a score whose evidence is not in the words is dropped', () => {
  const out = validateItem(item({ score: 5, score_evidence: '5 stars' }), { body: BODY })!;
  assertEquals(out.score, null);
});

test('a score INFERRED FROM SENTIMENT is dropped — the attack this exists for', () => {
  // A model reads "was unreal", decides that is a 5, and quotes the sentiment as its
  // evidence. The quote IS in the body, so only the number check catches it.
  const out = validateItem(item({ score: 5, score_evidence: 'was unreal' }), { body: BODY })!;
  assertEquals(out.score, null);
  assertEquals(out.score_evidence, null);
});

test('evidence containing a DIFFERENT number does not support the score', () => {
  const out = validateItem(item({ score: 3.5, score_evidence: '4.5' }), { body: BODY })!;
  assertEquals(out.score, null);
});

test('a score off the half-step scale is dropped', () => {
  for (const bad of [4.3, 0, -1, 5.5, 0.25, Number.NaN, Number.POSITIVE_INFINITY]) {
    const out = validateItem(item({ score: bad, score_evidence: '4.5' }), { body: BODY })!;
    assertEquals(out.score, null, `score ${bad} must not survive`);
  }
});

test('a legitimate score and its evidence survive intact', () => {
  const out = validateItem(item(), { body: BODY })!;
  assertEquals(out.score, 4.5);
  assertEquals(out.score_evidence, '4.5');
});

test('evidenceSupportsScore reads the number out of a spoken quote', () => {
  assert(evidenceSupportsScore('four and a half stars', 4.5));
  assert(evidenceSupportsScore('4/5', 4));
  assert(!evidenceSupportsScore('gone in four minutes', 4));
  assert(!evidenceSupportsScore('was unreal', 5));
  assert(!evidenceSupportsScore('', 5));
});

// ---------------------------------------------------------------------------
// RULE 9 — the note must be the user's words
// ---------------------------------------------------------------------------
test('a PARAPHRASED note is dropped, the rest of the line survives', () => {
  const out = validateItem(item({ note: 'Unreal — rich and glossy.' }), { body: BODY })!;
  assertEquals(out.note, null);
  assertEquals(out.score, 4.5);
});

test('a note that differs only in case is dropped, because Postgres position() is case-sensitive', () => {
  const out = validateItem(item({ note: 'Unreal.' }), { body: BODY })!;
  assertEquals(out.note, null, 'a looser test here would silently disagree with the SQL gate');
});

test('a verbatim note survives', () => {
  assertEquals(validateItem(item({ note: 'was unreal.' }), { body: BODY })!.note, 'was unreal.');
});

test('an over-long note is cut from the END only, and must still be verbatim', () => {
  const long = 'x'.repeat(400);
  const body = `Pasta 4.5 ${long} end.`;
  const out = validateItem(item({ dish_name: 'Pasta', note: `${long} end.` }), { body })!;
  assert(out.note !== null);
  assert(out.note!.length <= 240);
  assert(body.includes(out.note!));
});

// ---------------------------------------------------------------------------
// The dish itself
// ---------------------------------------------------------------------------
test('a HALLUCINATED dish — named nowhere in the words and not on the menu — is dropped', () => {
  assertEquals(validateItem(item({ dish_name: 'Lobster thermidor' }), { body: BODY }), null);
});

test('a dish on the menu but spelled differently by the user is kept', () => {
  const out = validateItem(item({ dish_name: 'Tiramisu' }), { body: BODY, knownDishes: ['Tiramisu'] });
  assert(out !== null);
});

test('an empty or absurd dish name is dropped', () => {
  assertEquals(validateItem(item({ dish_name: '   ' }), { body: BODY }), null);
  assertEquals(validateItem(item({ dish_name: 'x'.repeat(200) }), { body: BODY }), null);
});

// ---------------------------------------------------------------------------
// Whole plans
// ---------------------------------------------------------------------------
test('the same dish twice becomes one line, and a later score fills the gap', () => {
  const plan = validatePlan(
    {
      place_query: 'Tipo 00',
      items: [
        item({ score: null, score_evidence: null, note: 'was unreal.' }),
        item({ score: 4.5, score_evidence: '4.5', note: null }),
      ],
    },
    { body: BODY },
  );
  assertEquals(plan.items.length, 1);
  assertEquals(plan.items[0].score, 4.5);
  assertEquals(plan.items[0].note, 'was unreal.');
});

test('a plan is capped, and a blank place_query becomes null', () => {
  const many = Array.from({ length: MAX_ITEMS + 10 }, (_, i) => item({ dish_name: `dish ${i}` }));
  const body = many.map((m) => m.dish_name).join(', ') + ' 4.5';
  const plan = validatePlan({ place_query: ' ', items: many }, { body });
  assertEquals(plan.items.length, MAX_ITEMS);
  assertEquals(plan.place_query, null);
});

test('junk in the items array cannot crash the gate', () => {
  // deno-lint-ignore no-explicit-any
  const junk: any = { place_query: null, items: [null, undefined, 42, 'nope', {}, { dish_name: 7 }] };
  assertEquals(validatePlan(junk, { body: BODY }).items, []);
});
