// supabase/functions/sort-entry/parse_test.ts
//
//   deno test --no-check supabase/functions/sort-entry/
//   node --test supabase/functions/sort-entry/parse_test.ts
//
// Unit tests for the parser's primitives. The fixture corpus covers whole entries;
// this file pins the individual rules so a failure says WHICH rule broke.

import { test, assert, assertEquals } from './harness.ts';
import { findNumbers, parseEntry, placeCandidates, sentenceBounds } from './parse.ts';

const values = (s: string) => findNumbers(s).map((h) => h.value);
const texts = (s: string) => findNumbers(s).map((h) => h.text);

// ---------------------------------------------------------------------------
// NUMBERS THAT ARE NOT SCORES — the dangerous direction.
// ---------------------------------------------------------------------------
test('a duration is not a score', () => {
  assertEquals(values('gone in four minutes'), []);
  assertEquals(values('20 minutes for a table'), []);
  assertEquals(values('waited 2 hours'), []);
});

test('a head count, a price, a clock time, a date and a multiplier are not scores', () => {
  assertEquals(values('two of us'), []);
  assertEquals(values('it was $18'), []);
  assertEquals(values('got there at 5 pm'), []);
  assertEquals(values('out by 8:02'), []);
  assertEquals(values('12 September'), []);
  assertEquals(values('361 Little Bourke St'), []);
  assertEquals(values('pasta x4'), []);
  assertEquals(values('4th time here'), []);
  assertEquals(values('4.25 stars'), [], 'not a half step, and not even a legal number here');
});

test('a bare "half" is not a score — "half the work", "half an hour"', () => {
  assertEquals(values('the room does half the work'), []);
  assertEquals(values('half an hour late'), []);
});

// ---------------------------------------------------------------------------
// NUMBERS THAT ARE SCORES — with their verbatim evidence.
// ---------------------------------------------------------------------------
test('decimals, slashes, stars and spoken forms are all found, with literal evidence', () => {
  assertEquals(values('Margherita 4.5'), [4.5]);
  assertEquals(texts('Margherita 4.5'), ['4.5']);

  assertEquals(values('Margherita 4/5'), [4]);
  assertEquals(texts('Margherita 4/5'), ['4/5']);

  assertEquals(values('5 stars, no notes'), [5]);
  assertEquals(texts('5 stars, no notes'), ['5 stars']);

  assertEquals(values('four and a half stars'), [4.5]);
  assertEquals(texts('four and a half stars'), ['four and a half stars']);

  assertEquals(values('four point five'), [4.5]);
  assertEquals(values('a four out of five'), [4]);
  assertEquals(values('a solid four'), [4]);
  assertEquals(values('is a five'), [5]);
});

test('a score at the end of a sentence survives the full stop', () => {
  assertEquals(values('Kingfish 4.5.'), [4.5], 'the trailing full stop must not eat the number');
  assertEquals(texts('Kingfish 4.5.'), ['4.5']);
});

test('evidence is always a literal slice of the input', () => {
  const body = 'Tiramisu 3.0 a bit flat, kingfish gets four and a half stars.';
  for (const hit of findNumbers(body)) {
    assert(body.includes(hit.text), `${hit.text} is not a substring`);
    assertEquals(body.slice(hit.start, hit.end), hit.text);
  }
});

// ---------------------------------------------------------------------------
// SENTENCES
// ---------------------------------------------------------------------------
test('a decimal point does not end a sentence', () => {
  const body = 'Cheeseburger 1.5, cold in the middle.';
  assertEquals(sentenceBounds(body, 0), [0, body.length]);
});

test('an ellipsis is a pause, not a stop', () => {
  const body = 'ok so... tiramisu 3, fine.';
  assertEquals(sentenceBounds(body, 0), [0, body.length]);
});

test('an abbreviation full stop does not end a sentence, a capital does', () => {
  const abbrev = 'the no. 3 toastie 4.5 was great';
  assertEquals(sentenceBounds(abbrev, 0), [0, abbrev.length]);

  const two = 'Tiramisu 3.0 flat. Kingfish 4.5 not.';
  assertEquals(sentenceBounds(two, 0), [0, 18]);
});

test('a newline ends a sentence', () => {
  const body = 'Chin Chin\nKingfish 4.5';
  assertEquals(sentenceBounds(body, 0), [0, 10]);
});

// ---------------------------------------------------------------------------
// PLACE CANDIDATES — pointing only; the DB decides (DESIGN rule 8).
// ---------------------------------------------------------------------------
test('a venue name is offered whether it opens the entry or follows "at"', () => {
  assert(placeCandidates('Tipo 00 with Jess for her birthday.').includes('Tipo 00'));
  assert(placeCandidates('Lunch at Supernormal. The pork bun 4.5.').includes('Supernormal'));
  assert(placeCandidates('Two of us at Hardware Societe, baked eggs.').includes('Hardware Societe'));
  assert(placeCandidates('400 Gradi. Margherita 4.5.').includes('400 Gradi'));
  assert(placeCandidates('New place called Petal & Pan.').includes('Petal & Pan'));
});

test('a candidate never runs across a full stop into the next sentence', () => {
  for (const c of placeCandidates('Chin Chin. The kingfish sashimi 4.5.')) {
    assert(!c.includes('.'), `candidate "${c}" crossed a sentence boundary`);
  }
});

test('a candidate never ends in glue', () => {
  const candidates = placeCandidates('THE CHEESEBURGER AT BUTCHERS DINER IS A 5.');
  assert(candidates.includes('BUTCHERS DINER'), JSON.stringify(candidates));
});

test('an unnamed place offers nothing that looks like a venue', () => {
  // "the place near work" is lower case: the capitalised-run and "at"-prefix rules
  // both decline it, so there is nothing to look up and the entry stays placeless.
  const candidates = placeCandidates('Dumplings at the place near work, no idea what it\'s called.');
  assert(!candidates.some((c) => /place|work/i.test(c)), JSON.stringify(candidates));
});

// ---------------------------------------------------------------------------
// WHOLE-PLAN BEHAVIOUR not already covered by the corpus
// ---------------------------------------------------------------------------
test('empty and whitespace-only words sort to nothing', () => {
  assertEquals(parseEntry({ body: '' }), { place_query: null, items: [] });
  assertEquals(parseEntry({ body: '   \n ' }), { place_query: null, items: [] });
});

test('sentiment alone never earns a score', () => {
  const plan = parseEntry({
    body: 'Tipo 00. The tagliatelle al ragù was the single best plate of pasta in Melbourne.',
    knownDishes: ['Tagliatelle al ragù'],
  });
  assertEquals(plan.items.length, 1);
  assertEquals(plan.items[0].score, null);
  assertEquals(plan.items[0].score_evidence, null);
});

test('the menu spelling wins over the user\'s casing', () => {
  const plan = parseEntry({ body: 'kisume. salmon roll 4.5', knownDishes: ['Salmon roll'] });
  assertEquals(plan.items[0].dish_name, 'Salmon roll');
});

test('a longer menu name is preferred over the shorter one inside it', () => {
  const plan = parseEntry({
    body: 'The beef rib roll 4.5 was the one.',
    knownDishes: ['Beef rib', 'Beef rib roll'],
  });
  assertEquals(plan.items.map((i) => i.dish_name), ['Beef rib roll']);
});

test('items come out in the order the dishes appear in the words', () => {
  const plan = parseEntry({
    body: 'Kisume. Wagyu nigiri 4, then the salmon roll 5, then uni 3.5.',
    knownDishes: ['Salmon roll', 'Wagyu nigiri', 'Uni'],
  });
  assertEquals(plan.items.map((i) => i.dish_name), ['Wagyu nigiri', 'Salmon roll', 'Uni']);
});

test('every note the parser emits is a substring of the words', () => {
  const bodies = [
    'Tipo 00 with Jess. The tagliatelle al ragù 4.5 was unreal — rich, glossy; gone.',
    'ok so...   Chin Chin!!  kingfish 4.5  —  clean\nand cold',
    'Butchers Diner. Cheeseburger 1.5, cold in the middle. Fries 2, sad.',
  ];
  for (const body of bodies) {
    for (const item of parseEntry({ body, knownDishes: ['Tagliatelle al ragù', 'Kingfish', 'Cheeseburger', 'Fries'] }).items) {
      if (item.note !== null) assert(body.includes(item.note), `note ${JSON.stringify(item.note)} not verbatim`);
      if (item.score_evidence !== null) assert(body.includes(item.score_evidence), 'evidence not verbatim');
    }
  }
});
