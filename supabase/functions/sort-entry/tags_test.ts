// supabase/functions/sort-entry/tags_test.ts
//
//   deno test --no-check supabase/functions/sort-entry/
//   node --test supabase/functions/sort-entry/tags_test.ts
//
// DIETARY TAGS (0036). The rule under test: a tag reaches a line ONLY through a span the
// client marked, and lands on the dish that span follows. Prose never tags, a model never
// tags, and a marked word is never a dish.

import { test, assert, assertEquals } from './harness.ts';
import {
  attachTagTokens,
  canonicalTags,
  parseTagTokens,
  tagCodesFor,
  tagTokenSpans,
  TAG_CODES,
  type TagToken,
} from './tags.ts';
import { parseEntry } from './parse.ts';
import { validateItem, validatePlan } from './validate.ts';
import type { SortItem } from './types.ts';

/** Mark every whole-word occurrence of each word, the way the composer's chip would. */
function mark(body: string, ...words: string[]): TagToken[] {
  const out: TagToken[] = [];
  for (const w of words) {
    const re = new RegExp(`(?<![\\p{L}\\p{N}])${w}(?![\\p{L}\\p{N}])`, 'gu');
    for (let m = re.exec(body); m; m = re.exec(body)) {
      out.push({ offset: [...body.slice(0, m.index)].length, length: [...w].length });
    }
  }
  return out;
}

/** The whole stub pipeline, as index.ts runs it. */
function sort(body: string, tokens: TagToken[], knownDishes: string[] = []) {
  const plan = parseEntry({ body, knownDishes, excludeSpans: tagTokenSpans(body, tokens) });
  const gated = validatePlan(plan, { body, knownDishes });
  return attachTagTokens(gated.items, body, tokens);
}

const lines = (items: SortItem[]) => items.map((i) => [i.dish_name, i.score, i.tags]);

// ---------------------------------------------------------------------------
// The vocabulary
// ---------------------------------------------------------------------------
test('the closed set is exactly gf, df, v, vg, nf, in that order', () => {
  assertEquals([...TAG_CODES], ['gf', 'df', 'v', 'vg', 'nf']);
});

test('canonical: lower case, deduped, ordered by the list, unknown codes gone', () => {
  assertEquals(canonicalTags(['NF', 'gf', 'vg', 'GF', 'keto', ' v ']), ['gf', 'v', 'vg', 'nf']);
  assertEquals(canonicalTags([]), []);
});

test('a marked token is read in the words people actually write', () => {
  const cases: Array<[string, string[]]> = [
    ['GF', ['gf']], ['gf', ['gf']], ['(GF)', ['gf']], ['gluten free', ['gf']], ['Gluten-Free', ['gf']],
    ['DF', ['df']], ['dairy free', ['df']],
    ['V', ['v']], ['vegetarian', ['v']], ['veggie', ['v']],
    ['VG', ['vg']], ['vegan', ['vg']], ['Vegan!', ['vg']],
    ['NF', ['nf']], ['nut-free', ['nf']],
    ['GF/DF', ['gf', 'df']], ['vegan & nut free', ['vg', 'nf']], ['df, gf', ['gf', 'df']],
  ];
  for (const [text, want] of cases) assertEquals(tagCodesFor(text), want, text);
});

test('a marked token that is not tag vocabulary says nothing', () => {
  for (const text of ['GF pasta', 'keto', 'spicy', '4.5', '', 'very', 'glutenous']) {
    assertEquals(tagCodesFor(text), [], text);
  }
});

test('tag_tokens off the wire: malformed entries are dropped, never coerced', () => {
  assertEquals(parseTagTokens(undefined), []);
  assertEquals(parseTagTokens('gf'), []);
  assertEquals(
    parseTagTokens([
      { offset: 3, length: 2 },
      { offset: -1, length: 2 },
      { offset: 1.5, length: 2 },
      { offset: '3', length: 2 },
      { offset: 3, length: 0 },
      { offset: 3, length: 400 },
      null,
      { offset: 9, length: 5 },
    ]),
    [{ offset: 3, length: 2 }, { offset: 9, length: 5 }],
  );
});

// ---------------------------------------------------------------------------
// Never inferred
// ---------------------------------------------------------------------------
test('PROSE NEVER TAGS: "gluten free" and "vegan" in unmarked words tag no line', () => {
  const body = 'Margherita 4.5, the waiter said it was gluten free. Vegan lasagne 4 was fine too.';
  const items = sort(body, []);
  assert(items.length === 2, `two lines, got ${JSON.stringify(lines(items))}`);
  for (const it of items) assertEquals(it.tags, [], it.dish_name);
});

test('a model that invents tags is overruled: validateItem drops them, only tokens set them', () => {
  const body = 'Margherita 4.5 was great.';
  const invented = { dish_name: 'Margherita', score: 4.5, score_evidence: '4.5', note: null,
    evidence_offset: null, mention_text: null, mention_offset: null, tags: ['gf', 'vg'] } as SortItem;
  const gated = validateItem(invented, { body })!;
  assertEquals(gated.tags, undefined);
  assertEquals(attachTagTokens([gated], body, [])[0].tags, []);
});

test('every line carries tags, [] when none — never absent after the tag step', () => {
  const items = sort('Margherita 4.5 and the tiramisu 4.', []);
  assertEquals(items.map((i) => i.tags), [[], []]);
});

// ---------------------------------------------------------------------------
// Marked tokens land on the dish they follow
// ---------------------------------------------------------------------------
test('a marked tag lands on the dish it follows', () => {
  const body = 'Margherita 4.5 GF and the tiramisu 4 DF, loved it';
  assertEquals(lines(sort(body, mark(body, 'GF', 'DF'))), [
    ['Margherita', 4.5, ['gf']],
    ['tiramisu', 4, ['df']],
  ]);
});

test('several tags on one line, deduped and in canonical order', () => {
  const body = 'Pasta 4.5 VG GF vegan. Salad 3.5';
  assertEquals(lines(sort(body, mark(body, 'VG', 'GF', 'vegan'))), [
    ['Pasta', 4.5, ['gf', 'vg']],
    ['Salad', 3.5, []],
  ]);
});

test('a marked tag word is never a dish, nor the front half of one', () => {
  const body = 'Pasta 4.5 GF V Salad 3.5 VG';
  const unmarked = sort(body, []);
  assert(unmarked.some((i) => /\bGF\b/.test(i.dish_name)),
    `precondition: unmarked, the parser swallows a tag word into a dish (${JSON.stringify(lines(unmarked))})`);
  assertEquals(lines(sort(body, mark(body, 'GF', 'V', 'VG'))), [
    ['Pasta', 4.5, ['gf', 'v']],
    ['Salad', 3.5, ['vg']],
  ]);
});

test('a note that opens with the marked tag does not repeat it', () => {
  const body = 'Tiramisu 4 DF, loved it';
  const [line] = sort(body, mark(body, 'DF'));
  assertEquals(line.tags, ['df']);
  assert(line.note === null || !line.note.startsWith('DF'), `note still opens with the tag: ${line.note}`);
  if (line.note) assert(body.includes(line.note), 'the trimmed note is still a verbatim slice (rule 9)');
});

test('a marked tag before any dish has no line to go on, and is dropped', () => {
  const body = 'GF night. Pasta 4.5';
  assertEquals(lines(sort(body, mark(body, 'GF'))), [['Pasta', 4.5, []]]);
});

test('a token that points past the body, or at non-tag words, tags nothing', () => {
  const body = 'Pasta 4.5 GF';
  assertEquals(sort(body, [{ offset: 40, length: 2 }])[0].tags, []);
  const words = 'Pasta 4.5 was lovely';
  assertEquals(sort(words, mark(words, 'lovely'))[0].tags, []);
});

test('offsets are UNICODE SCALARS: an emoji before the token does not shift it', () => {
  const body = '🍝 Pasta 4.5 GF';
  const tokens = mark(body, 'GF');
  assertEquals(tokens, [{ offset: 12, length: 2 }]); // 12 scalars, 13 UTF-16 units
  assertEquals(lines(sort(body, tokens)), [['Pasta', 4.5, ['gf']]]);
});

test('a menu dish keeps its spelling and still takes the tag', () => {
  const body = 'the margherita 4.5 gf';
  assertEquals(lines(sort(body, mark(body, 'gf'), ['Margherita'])), [['Margherita', 4.5, ['gf']]]);
});
