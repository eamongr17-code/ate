// supabase/functions/sort-entry/same-dish_test.ts
//
//   node --test supabase/functions/sort-entry/same-dish_test.ts
//
// SAME DISH, DIFFERENT WORDS (18 Oct, Eamon): the spelling key (mirrored by public.dish_key, 0071 —
// the db suite reads the same dish-key-cases.json), the gate around the model's same_as, and the way
// validate.ts applies both. A real restaurant has three pastas and three steaks: every refusal below
// is as much the point as every match.

import { test, assert, assertEquals } from './harness.ts';
import { couldBeSame, dishKey, matchKey, sameDishGate } from './same-dish.ts';
import { validateItem, validatePlan } from './validate.ts';
import { planFromResponse } from './model.ts';
import { coerceCachedPlan } from './preview.ts';
import type { SortItem } from './types.ts';
import cases from './dish-key-cases.json' with { type: 'json' };

test('the spelling key: the same dish by spelling alone', () => {
  for (const [a, b] of cases.same) assertEquals(dishKey(a), dishKey(b), `${a} / ${b}`);
});

test('the spelling key never joins names that differ in a word or its order', () => {
  for (const [a, b] of cases.different) assert(dishKey(a) !== dishKey(b), `${a} / ${b}`);
});

test('the spelling key, exactly', () => {
  for (const [name, key] of cases.keys) assertEquals(dishKey(name), key, name);
});

// ---------------------------------------------------------------------------
// couldBeSame — may the words stand for each other at all?
// ---------------------------------------------------------------------------
test('a shorter name whose words all appear in the longer one could be the same', () => {
  assert(couldBeSame('Carbonara', 'Spaghetti Carbonara'));
  assert(couldBeSame('Spaghetti Carbonara', 'carbonara'), 'either way round');
  assert(couldBeSame('spag bol', 'Spaghetti Bolognese'), 'a prefix of 3+ letters');
  assert(couldBeSame('Carbonarra', 'Spaghetti Carbonara'), 'one typo in a long word');
  assert(couldBeSame('Pork Buns', 'Pork Belly Bun'));
});

test('a word the other name lacks, a different word, or a different order is not the same', () => {
  assert(!couldBeSame('Ribeye', 'Sirloin'));
  assert(!couldBeSame('Chicken Katsu', 'Pork Katsu'));
  assert(!couldBeSame('Half Chicken', 'Whole Chicken'));
  assert(!couldBeSame('Wagyu Carbonara', 'Spaghetti Carbonara'), 'wagyu is a distinguishing word');
  assert(!couldBeSame('Chocolate Milk', 'Milk Chocolate Mousse'));
  assert(!couldBeSame('Chips', 'Fries'), 'synonyms are not ours to guess');
});

test('a bare category never stands for a dish: the place may serve several', () => {
  assert(!couldBeSame('Steak', 'Scotch Fillet Steak'));
  assert(!couldBeSame('the pasta', 'Pappardelle Pasta'));
  assert(!couldBeSame('Fried Chicken', 'Korean Fried Chicken'));
  assert(!couldBeSame('Pizza', 'Margherita Pizza'));
  assert(couldBeSame('Margherita', 'Margherita Pizza'), 'but a dish word is not a category');
});

// ---------------------------------------------------------------------------
// sameDishGate — the fence around the model's claim
// ---------------------------------------------------------------------------
const MENU = ['Spaghetti Carbonara', 'Beef Ragu Pappardelle', 'Pork Ragu Gnocchi', 'Cacio e Pepe', 'Scotch Fillet Steak', 'Ribeye Steak'];

test('the gate passes a claim exactly one menu dish fits, in the menu\'s spelling', () => {
  assertEquals(sameDishGate('the carbonara', 'spaghetti carbonara', MENU), 'Spaghetti Carbonara');
  assertEquals(sameDishGate('Pepe', 'Cacio e Pepe', MENU), 'Cacio e Pepe');
});

test('two dishes that could fit is a guess, and a guess stays separate', () => {
  assertEquals(sameDishGate('Ragu', 'Beef Ragu Pappardelle', MENU), null);
  assertEquals(sameDishGate('steak', 'Ribeye Steak', MENU), null, 'and a bare category anyway');
});

test('the gate refuses a target off the menu, the same name, or words that do not fit', () => {
  assertEquals(sameDishGate('Carbonara', 'Fettuccine Carbonara', MENU), null, 'not on the menu');
  assertEquals(sameDishGate('Ribeye', 'Scotch Fillet Steak', MENU), null, 'the model said so; the words do not');
  assertEquals(sameDishGate('Truffle Carbonara', 'Spaghetti Carbonara', MENU), null, 'truffle is not on that dish');
  assertEquals(sameDishGate('Cacio e Pepe', 'Cacio e Pepe', MENU), null, 'already the menu name');
});

test('a rival with the target\'s own spelling key is a duplicate of it, not a second candidate', () => {
  assertEquals(sameDishGate('Carbonara', 'Spaghetti Carbonara', [...MENU, 'Spaghetti Carbonaras']), 'Spaghetti Carbonara');
});

test('the match key reads "X with Y" as "Y X" (20 Oct: Pad Thai Aree), and nothing else moves', () => {
  assertEquals(matchKey('Pad Thai with Chicken'), matchKey('Chicken Pad Thai'));
  assertEquals(matchKey('Pad Thai w/ Chicken'), matchKey('chicken pad thai'));
  assertEquals(matchKey('Rice with Fried Egg'), matchKey('Fried Egg Rice'));
  assert(matchKey('Milk Chocolate') !== matchKey('Chocolate Milk'), 'no "with": order still counts');
  assert(matchKey('Steak with Fries') !== matchKey('Steak Fries'), 'steak fries are a side');
  assert(matchKey('Pad Thai with Chicken') !== matchKey('Pad Thai with Prawn'));
  assert(matchKey('with Love') === dishKey('with Love') && matchKey('Served with') === dishKey('Served with'), 'nothing on one side: as typed');
  assertEquals(matchKey('Chicken with Rice with Egg'), dishKey('Chicken with Rice with Egg'), 'two "with"s: as typed');
  assert(couldBeSame('Chicken Pad Thai', 'Pad Thai with Chicken'));
  assert(couldBeSame('Chicken Pad Thai', 'Pad Thai with Chicken and Egg'), 'in menu order the words fit');
  assert(!couldBeSame('Chocolate Milk', 'Milk Chocolate Mousse'));
  assertEquals(sameDishGate('Chicken Pad Thai', 'Pad Thai with Chicken', ['Pad Thai with Chicken', 'Pad See Ew']), 'Pad Thai with Chicken');
});

// ---------------------------------------------------------------------------
// validate.ts — where the plan meets the menu
// ---------------------------------------------------------------------------
const line = (over: Partial<SortItem>): SortItem => ({
  dish_name: '', score: null, score_evidence: null, note: null, evidence_offset: null, mention_text: null, mention_offset: null, ...over,
});

test('a same-key menu dish wins with no model: the receipt prints the menu spelling, the words keep theirs', () => {
  const body = 'gnocchis 4.5 here';
  const out = validateItem(line({ dish_name: 'gnocchis', score: 4.5, score_evidence: '4.5' }), { body, knownDishes: ['Gnocchi'] })!;
  assertEquals(out.dish_name, 'Gnocchi');
  assertEquals(out.mention_text, 'gnocchis');
});

test('"Chicken Pad Thai" lands on the menu\'s "Pad Thai with Chicken" with no model', () => {
  const body = 'chicken pad thai 4, so good';
  const out = validateItem(line({ dish_name: 'chicken pad thai', score: 4, score_evidence: '4' }), {
    body, knownDishes: ['Pad Thai with Chicken', 'Pad See Ew'],
  })!;
  assertEquals(out.dish_name, 'Pad Thai with Chicken');
  const prawn = validateItem(line({ dish_name: 'prawn pad thai', score: 4, score_evidence: '4' }), {
    body: 'prawn pad thai 4', knownDishes: ['Pad Thai with Chicken'],
  })!;
  assert(prawn.dish_name !== 'Pad Thai with Chicken', 'another protein is another dish');
});

test('the model\'s same_as names the menu dish only through the gate', () => {
  const body = 'the carbonara 4.5, the ragu 3';
  const plan = validatePlan({
    place_query: null, place_offset: null,
    items: [
      line({ dish_name: 'carbonara', same_as: 'Spaghetti Carbonara', score: 4.5, score_evidence: '4.5' }),
      line({ dish_name: 'ragu', same_as: 'Beef Ragu Pappardelle', score: 3, score_evidence: '3' }),
    ],
  }, { body, knownDishes: MENU });
  assertEquals(plan.items.map((i) => i.dish_name), ['Spaghetti Carbonara', 'Ragu'], 'two ragus at this place: kept separate');
  assertEquals(plan.items[0].mention_text, 'carbonara');
  assert(!('same_as' in plan.items[0]), 'the claim does not leave the gate');
});

test('never onto a dish another line of the same entry names: the diner told them apart', () => {
  const body = 'carbonara 4 and the spaghetti carbonara 3';
  const plan = validatePlan({
    place_query: null, place_offset: null,
    items: [
      line({ dish_name: 'carbonara', same_as: 'Spaghetti Carbonara', score: 4, score_evidence: '4' }),
      line({ dish_name: 'spaghetti carbonara', score: 3, score_evidence: '3' }),
    ],
  }, { body, knownDishes: MENU });
  assertEquals(plan.items.map((i) => i.dish_name), ['Carbonara', 'Spaghetti Carbonara']);
});

test('two spellings of one dish in one entry are one line, as the database would make them', () => {
  const body = 'taco 4 then more tacos 3';
  const plan = validatePlan({
    place_query: null, place_offset: null,
    items: [line({ dish_name: 'taco', score: 4, score_evidence: '4' }), line({ dish_name: 'tacos' })],
  }, { body });
  assertEquals(plan.items.length, 1);
});

test('same_as comes off the model reply and rides the preview cache', () => {
  const plan = planFromResponse({
    content: [{ type: 'tool_use', name: 'sort_entry', input: { items: [{ dish_name: 'carbonara', same_as: 'Spaghetti Carbonara' }] } }],
  })!;
  assertEquals(plan.items[0].same_as, 'Spaghetti Carbonara');
  const cached = coerceCachedPlan(JSON.parse(JSON.stringify(plan)))!;
  assertEquals(cached.items[0].same_as, 'Spaghetti Carbonara');
});
