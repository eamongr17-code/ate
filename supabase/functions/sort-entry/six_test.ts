// supabase/functions/sort-entry/six_test.ts
//
//   deno test --no-check supabase/functions/sort-entry/
//   node --test supabase/functions/sort-entry/six_test.ts
//
// THE SECRET 6 (0041). The rule under test: a 6 reaches a line ONLY through a span the client
// marked (`six_tokens`). A typed "6" is not a score — not to the parser, not to a model, not in a
// preview. (That a 6 then counts as a 6 in averages is SQL: supabase/tests/db/round4_test.mjs.)

import { test, assert, assertEquals } from './harness.ts';
import {
  attachSixTokens, carryPriorSixes, parseSixTokens, sixEvidenceOffset, sixMarks, sixSpans, type SixToken,
} from './six.ts';
import { attachTagTokens, tagTokenSpans, type TagToken } from './tags.ts';
import { parseEntry } from './parse.ts';
import { buildRequest } from './model.ts';
import { validatePlan } from './validate.ts';
import { previewCacheKey } from './preview.ts';
import type { SortItem, SortPlan } from './types.ts';

/** Mark the n-th (0-based) occurrence of `text` as the composer's score token would: scalar offsets. */
function mark(body: string, text: string, nth = 0): SixToken {
  let at = -1;
  for (let i = 0; i <= nth; i++) at = body.indexOf(text, at + 1);
  if (at < 0) throw new Error(`"${text}" #${nth} not in body`);
  return { offset: [...body.slice(0, at)].length, length: [...text].length };
}

/** The pipeline as index.ts's planFor runs it: a model plan when given, else the stub parser. */
function sort(body: string, sixTokens: SixToken[], opts: { model?: SortPlan; tags?: TagToken[]; known?: string[] } = {}) {
  const sixes = sixSpans(body, sixTokens);
  const tags = opts.tags ?? [];
  const plan = opts.model ?? parseEntry({
    body,
    knownDishes: opts.known ?? [],
    excludeSpans: tagTokenSpans(body, tags),
    sixSpans: sixes.map((s): [number, number] => [s.start, s.end]),
  });
  const gated = validatePlan(plan, { body, knownDishes: opts.known ?? [], sixSpans: sixes });
  return attachSixTokens(attachTagTokens(gated.items, body, tags, opts.known ?? []), sixes);
}

const line = (items: SortItem[], name: string) => {
  const it = items.find((i) => i.dish_name.toLowerCase() === name.toLowerCase());
  if (!it) throw new Error(`no line "${name}" in ${JSON.stringify(items.map((i) => i.dish_name))}`);
  return it;
};

const modelItem = (dish_name: string, score: number | null, score_evidence: string | null): SortItem => ({
  dish_name, score, score_evidence, note: null, evidence_offset: null, mention_text: null, mention_offset: null,
});

// ---------------------------------------------------------------------------------------------------
// A typed "6" is not a score
// ---------------------------------------------------------------------------------------------------
test('six: a typed "6" is not a score — stub', () => {
  for (const body of ['Tiramisu 6', 'Tiramisu was a 6', 'tiramisu 6/5', 'Gave the tiramisu a 6.0', 'Tiramisu 6 stars']) {
    const items = sort(body, []);
    assert(items.every((i) => i.score !== 6), `${body} → ${JSON.stringify(items)}`);
  }
  // with the dish on the menu, the line prints — unscored
  assertEquals(line(sort('Tiramisu 6', [], { known: ['Tiramisu'] }), 'Tiramisu').score, null);
});

test('six: a typed "6" is not a score — a model that says 6 is overruled', () => {
  const body = 'Tiramisu 6, we were 6 people';
  const model: SortPlan = { place_query: null, place_offset: null, items: [modelItem('Tiramisu', 6, 'Tiramisu 6')] };
  assertEquals(line(sort(body, [], { model }), 'Tiramisu').score, null, 'no marked six at all');
  // a marked six ELSEWHERE does not license this one: the evidence must cover the marked span
  const other: SortPlan = { place_query: null, place_offset: null, items: [modelItem('Tiramisu', 6, 'were 6')] };
  const items = sort(body, [mark(body, '6', 0)], { model: other });
  assertEquals(line(items, 'Tiramisu').score, 6, 'the marked six still lands, on the dish before it');
  assertEquals(line(items, 'Tiramisu').score_evidence, '6');
  assertEquals(line(items, 'Tiramisu').evidence_offset, 9);
});

test('six: nothing but a lone "6" or "6.0" can be marked', () => {
  const body = 'Pasta 16, bread 6.5, soup 4, cake 6, pie 6.0';
  const spans = sixSpans(body, [
    mark(body, '6', 0),          // the 6 of "16"
    mark(body, '6', 1),          // the 6 of "6.5"
    mark(body, '4'),             // not a six
    mark(body, '6', 2),          // cake 6 ✓
    mark(body, '6.0'),           // pie 6.0 ✓
    { offset: 999, length: 1 },  // off the end
  ]);
  assertEquals(spans.map((s) => s.text), ['6', '6.0']);
  assertEquals(parseSixTokens([{ offset: 1, length: 1 }, { offset: -1, length: 1 }, { offset: 2 }, 'x', { offset: 3, length: 9 }]),
    [{ offset: 1, length: 1 }]);
  assertEquals(parseSixTokens(undefined), []);
});

// ---------------------------------------------------------------------------------------------------
// A marked 6 is
// ---------------------------------------------------------------------------------------------------
test('six: a marked 6 is a score — stub, found the way a 4.5 is', () => {
  const body = 'Tiramisu 6, the pasta 4.5 and we were 6 people';
  const items = sort(body, [mark(body, '6', 0)]);
  assertEquals(items.map((i) => [i.dish_name, i.score]), [['Tiramisu', 6], ['pasta', 4.5]]);
  assertEquals(line(items, 'Tiramisu').score_evidence, '6');
  assertEquals(line(items, 'Tiramisu').evidence_offset, 9);
  assert(items.every((i) => !/6 people/.test(i.dish_name)), 'the typed 6 made nothing');
});

test('six: a marked "6.0", and a six between two dishes', () => {
  const a = 'The tiramisu was a 6.0 honestly';
  assertEquals(line(sort(a, [mark(a, '6.0')]), 'tiramisu').score, 6);
  const b = 'Tiramisu 6 pasta 4';
  const items = sort(b, [mark(b, '6')]);
  assertEquals(items.map((i) => [i.dish_name, i.score]), [['Tiramisu', 6], ['pasta', 4]], 'the six is not the front of "6 pasta"');
});

test('six: offsets are scalars — an emoji before the six', () => {
  const body = '🍝 Tiramisu 6';
  const tok = mark(body, '6');
  assertEquals(tok, { offset: 11, length: 1 });
  const it = line(sort(body, [tok]), 'Tiramisu');
  assertEquals([it.score, it.evidence_offset], [6, 11]);
});

test('six: a model plan keeps its 6 when the evidence covers the marked span, wherever it first occurs', () => {
  const body = 'We were 6. Tiramisu 6';
  const tok = mark(body, '6', 1);
  const model: SortPlan = { place_query: null, place_offset: null, items: [modelItem('Tiramisu', 6, '6')] };
  const it = line(sort(body, [tok], { model }), 'Tiramisu');
  assertEquals([it.score, it.score_evidence, it.evidence_offset], [6, '6', 20], 'not the first "6" (offset 8)');
  assertEquals(sixEvidenceOffset(body, '6', 8, sixSpans(body, [tok])), 20, 'a claimed offset off the mark is not honoured');
});

test('six: a model that missed a marked six — it goes to the dish before it, only if that line is unscored', () => {
  const body = 'Tiramisu 6, pasta 4.5 6';
  const toks = [mark(body, '6', 0), mark(body, '6', 1)];
  const model: SortPlan = {
    place_query: null, place_offset: null,
    items: [modelItem('Tiramisu', null, null), modelItem('pasta', 4.5, 'pasta 4.5')],
  };
  const items = sort(body, toks, { model });
  assertEquals(items.map((i) => [i.dish_name, i.score]), [['Tiramisu', 6], ['pasta', 4.5]], 'pasta keeps its own 4.5');
});

test('six: the model is told which sixes are marked, and that no other 6 is a score', () => {
  const body = 'Dinner for 6. The tiramisu was a 6';
  const spans = sixSpans(body, [mark(body, '6', 1)]);
  assertEquals(sixMarks(body, spans), ['Dinner for 6. The tiramisu was a 6']);
  const withMark = JSON.parse(buildRequest({ apiKey: 'k', body, sixMarks: sixMarks(body, spans) }).body);
  assert(/MARKED SIXES.*tiramisu was a 6/.test(withMark.messages[0].content), withMark.messages[0].content);
  const without = JSON.parse(buildRequest({ apiKey: 'k', body }).body);
  assert(/a 6 in the text is never a score/.test(without.messages[0].content));
});

test('six: attachSixTokens leaves an already-claimed six alone and never mutates', () => {
  const body = 'Tiramisu 6';
  const spans = sixSpans(body, [mark(body, '6')]);
  const items: SortItem[] = [{ ...modelItem('Tiramisu', 6, 'Tiramisu 6'), evidence_offset: 0, mention_text: 'Tiramisu', mention_offset: 0 }];
  const out = attachSixTokens(items, spans);
  assertEquals(out, items);
  assert(out[0] !== items[0]);
});

// ---------------------------------------------------------------------------------------------------
// The preview
// ---------------------------------------------------------------------------------------------------
test('six: the preview cache key includes six_tokens; none marked keeps the round-3 key', async () => {
  const base = { body: 'Tiramisu 6', tagTokens: [], restaurantId: null, model: 'claude-haiku-4-5' };
  const plain = await previewCacheKey(base);
  assertEquals(await previewCacheKey({ ...base, sixTokens: [] }), plain);
  const marked = await previewCacheKey({ ...base, sixTokens: [{ offset: 9, length: 1 }] });
  assert(marked !== plain, 'a marked six is a different draft');
  assertEquals(await previewCacheKey({ ...base, sixTokens: [{ offset: 9, length: 1 }, { offset: 9, length: 1 }] }), marked);
});

test('six: a preview runs the same gate — a typed 6 is not a score there either', () => {
  // preview and sort share planFor; this is its pure half on a draft with and without the mark
  const draft = 'Tiramisu 6';
  assertEquals(sort(draft, []).some((i) => i.score === 6), false);
  assertEquals(line(sort(draft, [mark(draft, '6')]), 'Tiramisu').score, 6);
});

// ---------------------------------------------------------------------------------------------------
// 0044 — a re-sort without six_tokens keeps a marked 6 (QA on PR #71)
// ---------------------------------------------------------------------------------------------------
/** What sort-entry does on a re-sort: the plan without tokens, then the stored 6s carried by LINE. */
function resort(body: string, stored: SortItem[], known: string[], tags: TagToken[] = []) {
  const prior = stored.filter((i) => i.score === 6);
  return carryPriorSixes(sort(body, [], { known, tags }), body, prior);
}

test('six carry: a re-sort without six_tokens keeps the 6 (the QA probe)', () => {
  const body = 'Tiramisu 6 and the gnocchi 4 GF';
  const gf: TagToken = { offset: [...body].length - 2, length: 2 };
  const first = sort(body, [mark(body, '6')], { tags: [gf] });
  assertEquals(first.map((i) => [i.dish_name, i.score]), [['Tiramisu', 6], ['gnocchi', 4]]);
  // the tag-only re-sort (Entry edit), "Print it again", the retry: no six_tokens at all
  const again = resort(body, first, ['Tiramisu', 'Gnocchi'], [gf]);
  assertEquals(again.map((i) => [i.dish_name, i.score, i.evidence_offset]), [['Tiramisu', 6, 9], ['Gnocchi', 4, 27]]);
  assertEquals(line(again, 'Gnocchi').tags, ['gf']);
});

test('six carry: a word inserted before the dish keeps the 6, at its new offset', () => {
  const body = 'Tiramisu 6 and the gnocchi 4';
  const first = sort(body, [mark(body, '6')]);
  const edited = '🍝 Honestly the Tiramisu 6 and the gnocchi 4';
  const it = line(resort(edited, first, ['Tiramisu', 'Gnocchi']), 'Tiramisu');
  assertEquals([it.score, it.score_evidence, it.evidence_offset], [6, '6', 24]);
});

test('six carry: the 6 changed to 4 gives 4; the dish removed drops it; a 6 grown into 6.5 drops', () => {
  const body = 'Tiramisu 6 and the gnocchi 4';
  const first = sort(body, [mark(body, '6')]);
  const four = resort('Tiramisu 4 and the gnocchi 4', first, ['Tiramisu', 'Gnocchi']);
  assertEquals(four.map((i) => [i.dish_name, i.score]), [['Tiramisu', 4], ['Gnocchi', 4]]);
  const gone = resort('Just the gnocchi 4 and a 6 of us', first, ['Tiramisu', 'Gnocchi']);
  assertEquals(gone.map((i) => [i.dish_name, i.score]), [['Gnocchi', 4]]);
  assertEquals(line(resort('Tiramisu 6.5 and the gnocchi 4', first, ['Tiramisu', 'Gnocchi']), 'Tiramisu').score, null);
});

test('six carry: a typed "6" is still never a score on a re-sort', () => {
  const body = 'Tiramisu 6 and the gnocchi 6';
  const first = sort(body, [mark(body, '6', 0)], { known: ['Gnocchi'] });
  assertEquals(first.map((i) => [i.dish_name, i.score]), [['Tiramisu', 6], ['Gnocchi', null]]);
  const again = resort(body, first, ['Tiramisu', 'Gnocchi']);
  assertEquals(again.map((i) => [i.dish_name, i.score]), [['Tiramisu', 6], ['Gnocchi', null]]);
  // nothing marked before → nothing to carry, however the words read
  assertEquals(carryPriorSixes(sort(body, [], { known: ['Tiramisu', 'Gnocchi'] }), body, []).some((i) => i.score === 6), false);
});
