// supabase/functions/sort-entry/fixtures_test.ts
//
//   deno test --no-check supabase/functions/sort-entry/
//   node --test supabase/functions/sort-entry/fixtures_test.ts
//
// Runs the whole eval corpus through the ACTUAL pipeline the function runs
// (parseEntry → validatePlan) and asserts the items. Then re-asserts the two rules
// mechanically across the whole corpus, which is the part that must keep passing when the
// model replaces the parser:
//
//   RULE 7  every non-null score has evidence that is a literal substring of the body
//           AND that evidence really contains that number.
//   RULE 9  every non-null note is a literal substring of the body.

import { test, assert, assertEquals } from './harness.ts';
import { fixtures, type Fixture } from './fixtures.ts';
import { parseEntry, placeCandidates } from './parse.ts';
import { scalarLength, sliceScalars } from './offsets.ts';
import { evidenceSupportsScore, validatePlan } from './validate.ts';

/** The pipeline the function runs, with everything a fixture declares. */
const sortOf = (f: Fixture) => {
  const opts = { body: f.body, knownDishes: f.knownDishes ?? [] };
  return validatePlan(parseEntry({ ...opts, placeNames: f.placeNames ?? [] }), opts);
};

test('corpus has the cases the harness promises', () => {
  assert(fixtures.length >= 60, `expected at least 60 fixtures, got ${fixtures.length}`);
  const ids = new Set(fixtures.map((f) => f.id));
  assertEquals(ids.size, fixtures.length, 'fixture ids must be unique');
});

for (const f of fixtures) {
  test(`fixture ${f.id} — ${f.about}`, () => {
    const plan = sortOf(f);
    const declaresOffset = f.items.some((i) => 'evidence_offset' in i);
    const actual = plan.items.map((i) => ({
      dish_name: i.dish_name,
      score: i.score,
      note: i.note,
      ...(declaresOffset ? { evidence_offset: i.evidence_offset } : {}),
    }));
    assertEquals(
      actual,
      f.items.map((i) =>
        declaresOffset
          // same key order, or JSON.stringify equality is a coin toss
          ? { dish_name: i.dish_name, score: i.score, note: i.note, evidence_offset: i.evidence_offset ?? null }
          : i
      ),
      `items for ${f.id}`,
    );

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
    for (const item of sortOf(f).items) {
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
    for (const item of sortOf(f).items) {
      if (item.note === null) continue;
      assert(
        f.body.includes(item.note),
        `${f.id}/${item.dish_name}: note ${JSON.stringify(item.note)} is not a substring of the body`,
      );
    }
  }
});

test('RULE 9 holds for the OTHER note style too, across the corpus', () => {
  // The corpus pins the default ('clause'). 'sentence' is an option the lead can flip, so
  // it has to obey the same law on every entry — verbatim, never a rewrite.
  for (const f of fixtures) {
    const opts = { body: f.body, knownDishes: f.knownDishes ?? [] };
    const plan = parseEntry({ ...opts, placeNames: f.placeNames ?? [], noteStyle: 'sentence' });
    for (const item of validatePlan(plan, opts).items) {
      if (item.note === null) continue;
      assert(f.body.includes(item.note), `${f.id}: sentence-style note is not a substring of the body`);
    }
  }
});

test('OFFSETS across the corpus: every published offset really points at its text', () => {
  for (const f of fixtures) {
    for (const item of sortOf(f).items) {
      if (item.score === null) {
        assertEquals(item.evidence_offset, null, `${f.id}: an unscored line has nowhere to point`);
      } else {
        assert(item.evidence_offset !== null, `${f.id}/${item.dish_name}: a scored line must say WHERE`);
        assertEquals(
          sliceScalars(f.body, item.evidence_offset!, scalarLength(item.score_evidence!)),
          item.score_evidence,
          `${f.id}/${item.dish_name}: evidence_offset ${item.evidence_offset} does not point at the evidence`,
        );
      }
      if (item.mention_text !== null) {
        assert(item.mention_offset !== null, `${f.id}/${item.dish_name}: a mention must say WHERE`);
        assertEquals(
          sliceScalars(f.body, item.mention_offset!, scalarLength(item.mention_text)),
          item.mention_text,
          `${f.id}/${item.dish_name}: mention_offset does not point at the mention`,
        );
        assert(f.body.includes(item.mention_text), `${f.id}: the mention must be verbatim`);
      }
    }
    const plan = sortOf(f);
    if (plan.place_query !== null) {
      assert(plan.place_offset !== null, `${f.id}: a place candidate must say WHERE`);
      assertEquals(
        sliceScalars(f.body, plan.place_offset!, scalarLength(plan.place_query)),
        plan.place_query,
        `${f.id}: place_offset does not point at the place phrase`,
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
    const a = sortOf(f);
    const b = sortOf(f);
    assertEquals(a, b, `${f.id} must be deterministic`);
  }
});
