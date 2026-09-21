// supabase/functions/sort-entry/fixtures_test.ts
//
//   deno test --no-check supabase/functions/sort-entry/
//   node --test supabase/functions/sort-entry/fixtures_test.ts
//
// Runs the whole eval corpus through the ACTUAL pipeline the function runs
// (parseEntry → validatePlan) and asserts the items. Then re-asserts the two rules
// mechanically across all 40, which is the part that must keep passing when the
// model replaces the parser:
//
//   RULE 7  every non-null score has evidence that is a literal substring of the body
//           AND that evidence really contains that number.
//   RULE 9  every non-null note is a literal substring of the body.

import { test, assert, assertEquals } from './harness.ts';
import { fixtures } from './fixtures.ts';
import { parseEntry, placeCandidates } from './parse.ts';
import { evidenceSupportsScore, validatePlan } from './validate.ts';

const sortOf = (body: string, knownDishes: string[] = []) =>
  validatePlan(parseEntry({ body, knownDishes }), { body, knownDishes });

test('corpus has the ~40 cases the harness promises', () => {
  assert(fixtures.length >= 40, `expected at least 40 fixtures, got ${fixtures.length}`);
  const ids = new Set(fixtures.map((f) => f.id));
  assertEquals(ids.size, fixtures.length, 'fixture ids must be unique');
});

for (const f of fixtures) {
  test(`fixture ${f.id} — ${f.about}`, () => {
    const plan = sortOf(f.body, f.knownDishes ?? []);
    const actual = plan.items.map((i) => ({ dish_name: i.dish_name, score: i.score, note: i.note }));
    assertEquals(actual, f.items, `items for ${f.id}`);

    if (f.place !== null) {
      const candidates = placeCandidates(f.body);
      assert(
        candidates.some((c) => c.toLowerCase() === f.place!.toLowerCase()),
        `expected "${f.place}" among place candidates, got ${JSON.stringify(candidates)}`,
      );
    }
  });
}

test('RULE 7 across the corpus: no score without literal evidence in the words', () => {
  for (const f of fixtures) {
    for (const item of sortOf(f.body, f.knownDishes ?? []).items) {
      if (item.score === null) {
        assertEquals(item.score_evidence, null, `${f.id}: unscored item must carry no evidence`);
        continue;
      }
      assert(item.score_evidence, `${f.id}/${item.dish_name}: scored item must carry evidence`);
      assert(
        f.body.includes(item.score_evidence!),
        `${f.id}/${item.dish_name}: evidence ${JSON.stringify(item.score_evidence)} is not a substring of the body`,
      );
      assert(
        evidenceSupportsScore(item.score_evidence!, item.score),
        `${f.id}/${item.dish_name}: evidence ${JSON.stringify(item.score_evidence)} does not contain ${item.score}`,
      );
    }
  }
});

test('RULE 9 across the corpus: every note is a verbatim substring of the words', () => {
  for (const f of fixtures) {
    for (const item of sortOf(f.body, f.knownDishes ?? []).items) {
      if (item.note === null) continue;
      assert(
        f.body.includes(item.note),
        `${f.id}/${item.dish_name}: note ${JSON.stringify(item.note)} is not a substring of the body`,
      );
    }
  }
});

test('the corpus expectations themselves are verbatim (a typo cannot sneak in as a rewrite)', () => {
  for (const f of fixtures) {
    for (const item of f.items) {
      if (item.note === null) continue;
      assert(f.body.includes(item.note), `${f.id}: expected note is not a substring of the fixture body`);
    }
    for (const item of f.items) {
      if (item.score === null) continue;
      assert(item.score >= 0.5 && item.score <= 5, `${f.id}: expected score out of range`);
      assert(Math.abs(item.score * 2 - Math.round(item.score * 2)) < 1e-9, `${f.id}: expected score not a half step`);
    }
  }
});

test('re-sorting the same words is stable', () => {
  for (const f of fixtures) {
    const a = sortOf(f.body, f.knownDishes ?? []);
    const b = sortOf(f.body, f.knownDishes ?? []);
    assertEquals(a, b, `${f.id} must be deterministic`);
  }
});
