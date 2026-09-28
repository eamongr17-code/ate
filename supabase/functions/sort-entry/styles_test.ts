// supabase/functions/sort-entry/styles_test.ts
//
//   node --test supabase/functions/sort-entry/styles_test.ts
//
// STYLE TAGS (0053): what the model may propose as a dish's style words, and that every path a plan
// takes — the model reply, the gate, the dedupe, the preview cache — keeps them cleaned and nothing
// else. The database re-validates the same rule (dish_styles_from_json, supabase/tests/db/dish_tag_links_test.mjs).

import { test, assert, assertEquals } from './harness.ts';
import { cleanStyle, cleanStyles, MAX_STYLES } from './styles.ts';
import { buildRequest, planFromResponse } from './model.ts';
import { validateItem, validatePlan } from './validate.ts';
import { coerceCachedPlan } from './preview.ts';
import type { SortItem } from './types.ts';

test('cleanStyle: lower-case a–z words, accent-folded, 3–24 chars, no diet words or filler', () => {
  assertEquals(cleanStyle('  Fried   Chicken '), 'fried chicken');
  assertEquals(cleanStyle('Crème brûlée'), 'creme brulee');
  assertEquals(cleanStyle('dim-sum'), 'dim-sum');
  for (const bad of ['vegan', 'Gluten free', 'food', 'x', 'ab', '4.5', 'pasta!', 'a very long style name for a dish', 42, null, ['pasta']]) {
    assertEquals(cleanStyle(bad), null, `${JSON.stringify(bad)} is not a style`);
  }
});

test('cleanStyles: distinct, first mention first, at most 3, never throws', () => {
  assertEquals(cleanStyles(['Pasta', 'pasta', 'vegan', 'comfort food', 'cheese', 'dessert']), ['pasta', 'comfort food', 'cheese']);
  assertEquals(MAX_STYLES, 3);
  assertEquals(cleanStyles('pasta'), []);
  assertEquals(cleanStyles(undefined), []);
  assertEquals(cleanStyles([{}, 7, 'noodles']), ['noodles']);
});

test('the model is asked for styles, and its reply\'s styles are cleaned on the way in', () => {
  const req = JSON.parse(buildRequest({ apiKey: 'k', body: 'Pasta 4' }).body);
  const props = req.tools[0].input_schema.properties.items.items.properties;
  assertEquals(props.styles.type, 'array');
  assertEquals(props.styles.maxItems, 3);
  assert(String(req.system).includes('styles'), 'the system prompt explains styles');

  const plan = planFromResponse({
    content: [{ type: 'tool_use', name: 'sort_entry', input: { items: [
      { dish_name: 'Pasta', styles: ['PASTA', 'vegan', 'comfort food'] },
      { dish_name: 'Tiramisu', styles: 'dessert' },
      { dish_name: 'Salad' },
    ] } }],
  })!;
  assertEquals(plan.items.map((i) => i.styles ?? null), [['pasta', 'comfort food'], null, null]);
});

test('the gate keeps a line\'s styles (cleaned), and they never rescue a dish that is not in the words', () => {
  const body = 'Pasta 4 and the tiramisu';
  const item = (over: Partial<SortItem>): SortItem => ({
    dish_name: 'Pasta', score: 4, score_evidence: 'Pasta 4', note: null,
    evidence_offset: null, mention_text: null, mention_offset: null, ...over,
  });
  assertEquals(validateItem(item({ styles: [' Pasta ', 'x'] }), { body })!.styles, ['pasta']);
  assertEquals('styles' in validateItem(item({}), { body })!, false, 'absent, not [], when there are none');
  assertEquals(validateItem(item({ dish_name: 'Lasagne', styles: ['pasta'] }), { body }), null);

  // same dish twice: the first line wins, and takes the styles it lacked
  const plan = validatePlan({
    place_query: null, place_offset: null,
    items: [item({}), item({ score: null, score_evidence: null, styles: ['pasta'] })],
  }, { body });
  assertEquals(plan.items.length, 1);
  assertEquals(plan.items[0].styles, ['pasta']);
  assertEquals(plan.items[0].score, 4);
});

test('a cached preview plan keeps its styles, re-cleaned', () => {
  const plan = coerceCachedPlan({
    place_query: null, place_offset: null,
    items: [{ dish_name: 'Pasta', score: null, styles: ['Pasta', 'vegan'] }, { dish_name: 'Salad', styles: 'x' }],
  })!;
  assertEquals(plan.items.map((i) => i.styles ?? null), [['pasta'], null]);
});
