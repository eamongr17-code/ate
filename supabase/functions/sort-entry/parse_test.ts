// supabase/functions/sort-entry/parse_test.ts
//
//   deno test --no-check supabase/functions/sort-entry/
//   node --test supabase/functions/sort-entry/parse_test.ts
//
// Unit tests for the parser's primitives. The fixture corpus covers whole entries;
// this file pins the individual rules so a failure says WHICH rule broke.

import { test, assert, assertEquals } from './harness.ts';
import {
  findNumbers,
  mentionForPlaceName,
  parseEntry,
  placeCandidates,
  placeCandidateSpans,
  placeNameSpans,
  sentenceBounds,
} from './parse.ts';
import { scalarLength, sliceScalars } from './offsets.ts';

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
  assertEquals(parseEntry({ body: '' }), { place_query: null, place_offset: null, items: [] });
  assertEquals(parseEntry({ body: '   \n ' }), { place_query: null, place_offset: null, items: [] });
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

// ---------------------------------------------------------------------------
// WHERE THINGS ARE — the offsets the client draws its inline tokens from.
// ---------------------------------------------------------------------------
test('every place candidate span points at its own phrase', () => {
  const bodies = [
    'Tipo 00 with Jess for her birthday.',
    'Lunch at Supernormal. The pork bun 4.5.',
    'With Jess at Hardware Societe Flinders Ln, baked eggs 4.',
    'ok so... 🍝 back to Tipo 00, tagliatelle 4.5',
  ];
  for (const body of bodies) {
    for (const c of placeCandidateSpans(body)) {
      assertEquals(
        sliceScalars(body, c.offset, scalarLength(c.phrase)),
        c.phrase,
        `"${c.phrase}" @${c.offset} in ${JSON.stringify(body)}`,
      );
    }
  }
});

test('placeCandidates is still the phrases, in the same order', () => {
  const body = 'Two of us at Hardware Societe, baked eggs.';
  assertEquals(placeCandidates(body), placeCandidateSpans(body).map((c) => c.phrase));
});

test('the dish mention and the score evidence both come back with their offsets', () => {
  const body = 'Kisume 🍣 for one. Salmon roll 4.5, clean and cold.';
  const item = parseEntry({ body, knownDishes: ['Salmon roll'] }).items[0];
  assertEquals(sliceScalars(body, item.evidence_offset!, scalarLength(item.score_evidence!)), '4.5');
  assertEquals(item.mention_text, 'Salmon roll');
  assertEquals(sliceScalars(body, item.mention_offset!, scalarLength(item.mention_text!)), 'Salmon roll');
});

test('the mention is the words\' OWN spelling even when the name comes from the menu', () => {
  const body = 'kisume. salmon roll 4.5';
  const item = parseEntry({ body, knownDishes: ['Salmon roll'] }).items[0];
  assertEquals(item.dish_name, 'Salmon roll', 'the menu spelling is what the receipt prints');
  assertEquals(item.mention_text, 'salmon roll', 'the mention is what they typed');
  assertEquals(sliceScalars(body, item.mention_offset!, scalarLength(item.mention_text!)), 'salmon roll');
});

test('a user-pinned place is matched back to the phrase in the words, or to nothing', () => {
  const body = 'Lunch at Hardware Societe. Baked eggs 4.5.';
  const spans = placeCandidateSpans(body);
  const hit = mentionForPlaceName(spans, 'Hardware Societe');
  assert(hit !== null);
  assertEquals(sliceScalars(body, hit!.offset, scalarLength(hit!.phrase)), 'Hardware Societe');
  // a longer canonical name still matches the phrase that starts it…
  assert(mentionForPlaceName(spans, 'Hardware Societe Flinders Lane') !== null);
  // …but an unrelated venue must not borrow someone else's words.
  assertEquals(mentionForPlaceName(spans, 'Tipo 00'), null);
  assertEquals(mentionForPlaceName(spans, ''), null);
  assertEquals(mentionForPlaceName(spans, null), null);
});

// ---------------------------------------------------------------------------
// FALSE LINE ITEMS — a ranking and a count are not scores, and an unscored candidate
// must have been POINTED AT (menu match, or the user's own determiner).
// ---------------------------------------------------------------------------
test('a ranking idiom and a count never become scores', () => {
  assertEquals(values('is a top five Melbourne pizza'), []);
  assertEquals(values('easily a top 5 pizza'), []);
  assertEquals(values('Order two.'), []);
  assertEquals(values('we got 4 between us'), []);
  assertEquals(values('had 2 of those'), []);
  // …unless the user marked it, which is unambiguous
  assertEquals(values('got 5 stars'), [5]);
  assertEquals(values('got a four'), [4]);
  assertEquals(values('ordered the 4.5'), [4.5]);
});

test('an unscored candidate needs the menu or a determiner, not just a noun run', () => {
  const dishes = (body: string, knownDishes: string[] = []) =>
    parseEntry({ body, knownDishes }).items.map((i) => i.dish_name);

  // prose about the food — no line item
  assertEquals(dishes('had proper leopard spotting on the crust.'), []);
  assertEquals(dishes('the salsa had real heat.'), []);
  assertEquals(dishes('would order twice.'), []);
  // the user pointed at it
  assertEquals(dishes('We also had the chips.'), ['chips']);
  assertEquals(dishes('We shared the pappardelle.'), ['pappardelle']);
  // the menu knows it
  assertEquals(dishes('had proper leopard spotting.', ['Leopard spotting']), ['Leopard spotting']);
  // or they gave it a number, which makes it theirs
  assertEquals(dishes('had proper leopard spotting 4.5.'), ['proper leopard spotting']);
});

test('a number is never the head of a dish name, and never steals a score', () => {
  const plan = parseEntry({ body: 'The pork bun got a four from me.', knownDishes: ['Pork bun'] });
  assertEquals(plan.items.map((i) => `${i.dish_name}=${i.score}`), ['Pork bun=4']);

  const marked = parseEntry({ body: 'Raspberry cake got 5 stars, no notes.', knownDishes: ['Raspberry cake'] });
  assertEquals(marked.items.map((i) => `${i.dish_name}=${i.score}`), ['Raspberry cake=5']);
});

// ---------------------------------------------------------------------------
// UNICODE WORDS — `\w` is ASCII-only, and Melbourne menus are not. Every mention span
// must cover the WHOLE word, and its offset stays a Unicode SCALAR offset.
// ---------------------------------------------------------------------------
test('an accented dish keeps its last letter, and its mention span covers the whole word', () => {
  const cases: Array<[string, string[], string, string]> = [
    // body, knownDishes, expected dish_name, expected mention_text
    ['Tipo 00. The tagliatelle al ragù 4.5.', [], 'tagliatelle al ragù', 'tagliatelle al ragù'],
    ['Beatrix. The crème brûlée 4.5.', [], 'crème brûlée', 'crème brûlée'],
    ['Beatrix. the crème brûlée 4.5.', ['Crème brûlée'], 'Crème brûlée', 'crème brûlée'],
    ['Bánh mì 4 from the truck.', [], 'Bánh mì', 'Bánh mì'],
    ['Jalapeño poppers 3.5, actually hot.', [], 'Jalapeño poppers', 'Jalapeño poppers'],
    ['The açaí bowl 4.', [], 'açaí bowl', 'açaí bowl'],
    ['Pho đặc biệt 4.5.', [], 'Pho đặc biệt', 'Pho đặc biệt'],
    ['The soufflé 5.', [], 'soufflé', 'soufflé'],
  ];
  for (const [body, knownDishes, dish, mention] of cases) {
    const item = parseEntry({ body, knownDishes }).items[0];
    assert(item, `no dish found in ${JSON.stringify(body)}`);
    assertEquals(item.dish_name, dish, `dish_name for ${JSON.stringify(body)}`);
    assertEquals(item.mention_text, mention, `mention for ${JSON.stringify(body)}`);
    assertEquals(
      sliceScalars(body, item.mention_offset!, scalarLength(item.mention_text!)),
      item.mention_text,
      `mention_offset for ${JSON.stringify(body)}`,
    );
  }
});

test('a DECOMPOSED accent is one word too — the combining mark must not end it', () => {
  // The same words, typed on a Mac that hands over NFD: "ragù" is u + U+0300.
  const body = 'Tipo 00. The tagliatelle al ragù 4.5.'.normalize('NFD');
  const item = parseEntry({ body }).items[0];
  assertEquals(item.dish_name, 'tagliatelle al ragù'.normalize('NFD'));
  assertEquals(scalarLength(item.mention_text!), 20, 'the mark is its own scalar — offsets stay scalars');
  assertEquals(sliceScalars(body, item.mention_offset!, 20), item.mention_text);
});

test('a venue whose name starts with a non-ASCII capital is still a candidate', () => {
  assert(placeCandidates('Dinner at Émile. The soufflé 5.').includes('Émile'));
  assert(placeCandidates('Ñoño on Gertrude, tacos 4.').includes('Ñoño'));
  assert(placeCandidates('Back to Étoile for the tart.').includes('Étoile'));
  // and a place phrase's offset still points at the phrase, accents and all
  const body = 'Dinner at Émile. The soufflé 5.';
  for (const c of placeCandidateSpans(body)) {
    assertEquals(sliceScalars(body, c.offset, scalarLength(c.phrase)), c.phrase);
  }
});

test('a menu name with regex metacharacters still compiles under /u and still matches', () => {
  // The /u flag makes several escapes hard errors, and menu names are user-generated.
  const cases: Array<[string, string]> = [
    ['Crème brûlée (petit) 4.5, tiny and perfect.', 'Crème brûlée (petit)'],
    ['The pho #1 4, always.', 'Pho #1'],
    ['Half & half 3.5.', 'Half & half'],
    ['Mum’s bánh xèo 5.', 'Mum’s bánh xèo'],
  ];
  for (const [body, dish] of cases) {
    assertEquals(parseEntry({ body, knownDishes: [dish] }).items.map((i) => i.dish_name), [dish]);
  }
});

test('an accented word does not become a score, a unit or a sentence break', () => {
  // the reject vocabularies stay ASCII on purpose; these must behave exactly as before
  assertEquals(parseEntry({ body: 'Crème brûlée, gone in four minutes.' }).items[0]?.score ?? null, null);
  assertEquals(sentenceBounds('Café. Émile is next.', 0), [0, 5], 'a capital after a full stop still ends it');
});

// ---------------------------------------------------------------------------
// NOTES — the CLAUSE after the dish by default (design/v1/Entry prints exactly that),
// the whole sentence on request. Always verbatim either way.
// ---------------------------------------------------------------------------
test('a note is the clause after the dish, and does NOT repeat the dish name or score', () => {
  const body = 'Omakase with the team. The salmon roll 4.5 was the quiet star, clean and cold. Home by nine.';
  const item = parseEntry({ body, knownDishes: ['Salmon roll'] }).items[0];
  assertEquals(item.note, 'the quiet star, clean and cold.');
  assert(!/salmon roll/i.test(item.note!), 'the receipt line above already prints the dish');
  assert(!item.note!.includes('4.5'), 'and the score');
});

test('noteStyle: \'sentence\' is the alternative — it keeps the words before the dish', () => {
  const body = 'Omakase with the team. The salmon roll 4.5 was the quiet star, clean and cold. Home by nine.';
  const item = parseEntry({ body, knownDishes: ['Salmon roll'], noteStyle: 'sentence' }).items[0];
  assertEquals(item.note, 'The salmon roll 4.5 was the quiet star, clean and cold.');
  assert(body.includes(item.note!), 'both styles are verbatim slices');

  // and it starts at the DISH, not at the tail of the sentence before it (quoteStart):
  // sentenceBounds treats ". t" as an abbreviation so the score stays with its dish.
  const messy = 'ok so... Tipo 00 🍝!! tagliatelle al ragù 4.5 — insane?? yes. tiramisu... 3, fine.';
  const second = parseEntry({ body: messy, knownDishes: ['Tagliatelle al ragù', 'Tiramisu'], noteStyle: 'sentence' })
    .items[1];
  assertEquals(second.note, 'tiramisu... 3, fine.');
  assert(messy.includes(second.note!));
});

test('a clause cut at the next dish does not end on a dangling comma', () => {
  const body = 'Kisume. The salmon roll 5.0 was the quiet star, and the wagyu nigiri 4.5 was fine.';
  const items = parseEntry({ body, knownDishes: ['Salmon roll', 'Wagyu nigiri'] }).items;
  assertEquals(items[0].note, 'the quiet star');
  for (const i of items) if (i.note) assert(!/[,;:]$/.test(i.note), `note ends on punctuation glue: ${i.note}`);
});

// ---------------------------------------------------------------------------
// THE SCORE LEAD-IN — "X was a 4.5" used to sort to NOTHING: the number was found, the
// dish was not, because the walk in front of the number stops at a stopword and "was",
// "is", "a" and "solid" all are. (The CEO's own entries, staging 2026-09-24.)
// ---------------------------------------------------------------------------
test('a lead-in between the dish and the number still finds the dish', () => {
  const line = (body: string, knownDishes: string[] = []) =>
    parseEntry({ body, knownDishes }).items.map((i) => `${i.dish_name}=${i.score}`);

  assertEquals(line('The fishbowl margarita was a 4.5 and eliteeeee'), ['fishbowl margarita=4.5']);
  assertEquals(line('The pork bun is a 4.'), ['pork bun=4']);
  assertEquals(line('The tiramisu gets a 3.5.'), ['tiramisu=3.5']);
  assertEquals(line('I gave the kingfish a 4.'), ['kingfish=4']);
  assertEquals(line('The tiramisu, a solid 4, then home.'), ['tiramisu=4']);
  assertEquals(line('The margarita was a four.'), ['margarita=4']);
  // the double space the CEO actually typed
  assertEquals(line('The fishbowl margarita  was a 4.5'), ['fishbowl margarita=4.5']);
  // and the menu spelling still wins
  assertEquals(line('the pork bun was a 4', ['Pork bun']), ['Pork bun=4']);
});

test('a lead-in is only stripped for a number that is ALREADY a score', () => {
  const dishes = (body: string) => parseEntry({ body }).items.map((i) => i.dish_name);
  // a count, a head count and a time are not scores, so there is nothing to walk back from
  assertEquals(dishes('We were a party of 4 and it was tight.'), []);
  assertEquals(dishes('Table for 4 at 6.'), []);
  assertEquals(dishes('They gave us a 20 minute wait.'), []);
  // "It" is a stopword: a scored SOMETHING with no name is not a line item
  assertEquals(dishes('It was a 4.'), []);
  // and the rejections the corpus pins keep rejecting
  assertEquals(findNumbers('is a top five Melbourne pizza').length, 0);
  assertEquals(findNumbers('Order two.').length, 0);
  assertEquals(findNumbers('gone in four minutes').length, 0);
});

test('a dish already named in front of the number keeps it — no phantom out of the lead-in', () => {
  // "would" is not a dish: the penne was named first and nothing nearer took its number.
  const penne = parseEntry({
    body: 'Di Stasio. The penne al ragù, I would give it a 4.5 and I do not give those out.',
    knownDishes: ['Penne al ragù'],
  });
  assertEquals(penne.items.map((i) => `${i.dish_name}=${i.score}`), ['Penne al ragù=4.5']);

  // …but a dish whose own number already went elsewhere does NOT block the next one.
  const two = parseEntry({ body: 'The kingfish 4.5 and the pork bun was a 4.' });
  assertEquals(two.items.map((i) => `${i.dish_name}=${i.score}`), ['kingfish=4.5', 'pork bun=4']);
});

test('the lead-in walk never reaches into the sentence before', () => {
  // the venue stands in the previous sentence; "A solid 4.5" belongs to the cake after it
  const plan = parseEntry({
    body: 'Beatrix. A solid 4.5 for the raspberry cake, and nothing else needed saying.',
    knownDishes: ['Raspberry cake'],
  });
  assertEquals(plan.items.map((i) => i.dish_name), ['Raspberry cake']);
});

// ---------------------------------------------------------------------------
// THE PLACE IS NOT THE DISH — placeNames fences the venue's own words off.
// ---------------------------------------------------------------------------
test('the place name is never a dish, nor the front half of one', () => {
  // staging: this minted a dish called "Pizza San Danielle Pizza"
  const bleed = parseEntry({
    body: 'Baby Pizza San Danielle Pizza 3.5 was decent, nothing crazy.',
    placeNames: ['Baby Pizza'],
  });
  assertEquals(bleed.items.map((i) => i.dish_name), ['San Danielle Pizza']);

  // scoring the PLACE prints no receipt line
  assertEquals(parseEntry({ body: 'Baby Pizza was a 4.5.', placeNames: ['Baby Pizza'] }).items, []);

  // a menu dish whose name sits INSIDE the venue name does not match there
  const inside = parseEntry({
    body: 'Baby Pizza San Danielle Pizza 3.5.',
    knownDishes: ['Pizza'],
    placeNames: ['Baby Pizza'],
  });
  assertEquals(inside.items.map((i) => i.mention_offset), [24]);

  // and without a resolved place nothing is fenced — the words are all we have
  const unfenced = parseEntry({ body: 'Baby Pizza San Danielle Pizza 3.5.' });
  assertEquals(unfenced.items.map((i) => i.dish_name), ['Pizza San Danielle Pizza']);
});

test('a place mention is matched past an apostrophe, a capital and extra spaces', () => {
  const body = 'PJ’s Mexican cantina fishbowl margarita  was a 4.5 and eliteeeee';
  assertEquals(placeNameSpans(body, ["PJ's Mexican Cantina"]), [[0, 20]], 'straight vs curly apostrophe, any case');
  assertEquals(placeNameSpans(body, ['pj’s   mexican cantina']), [[0, 20]], 'collapsed whitespace');
  assertEquals(placeNameSpans(body, ['Pizzaiolo', '', null, undefined]), [], 'no match, no span');
  // Unicode-fenced: a venue name is not found inside a longer word
  assertEquals(placeNameSpans('Pizzaiolo on Lygon', ['Pizza']), []);

  const item = parseEntry({ body, placeNames: ["PJ's Mexican cantina"] }).items[0];
  assertEquals(item.dish_name, 'fishbowl margarita');
  assertEquals(item.note, 'eliteeeee');
  assertEquals(sliceScalars(body, item.evidence_offset!, scalarLength(item.score_evidence!)), '4.5');
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
