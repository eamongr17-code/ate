// supabase/functions/sort-entry/fixtures.ts
//
// THE EVAL CORPUS — realistic entries with their expected sort.
//
// This file has two jobs:
//   1. It pins the deterministic stub parser (fixtures_test.ts asserts every item,
//      except the `modelOnly` entries at the end).
//   2. It is the HARNESS THE REAL MODEL IS JUDGED BY: eval.ts runs the whole corpus
//      through model mode and scores it with the same expectations — nothing about them
//      is stub-specific, because they describe what the USER SAID, not how we found it.
//      The `modelOnly` entries are free-form writing the rule-based stub cannot sort;
//      they exist to measure the model, and only the rule checks run them in CI.
//
// Every expectation obeys the two rules, so a correct sorter of ANY kind passes:
//   * `score` is non-null ONLY where the words contain an explicit number for that
//     dish. Sentiment never earns a score, however strong ("unreal", "the best
//     thing on Little Bourke").
//   * `note` is always an exact substring of `body`. fixtures_test.ts re-checks that
//     mechanically for all of them, so a typo in a note cannot sneak in as a rewrite.
//
// The corpus deliberately includes the numbers that are NOT scores — durations,
// prices, clock times, dates, head counts, ordinals, quantities — because inventing a
// score from one of those is the single worst bug this system can have.

import type { ResolvedPlace } from './parse.ts';

export type FixtureItem = {
  dish_name: string;
  score: number | null;
  note: string | null;
  /**
   * Optional: the expected SCALAR offset of `score_evidence` in `body` (see
   * offsets.ts). Set it where the occurrence matters — a body with a price in it has
   * two "4.5"s and only one of them is the score. Left undefined, fixtures_test still
   * checks mechanically that whatever offset came back really points at the evidence.
   */
  evidence_offset?: number | null;
};

export type Fixture = {
  id: string;
  /** what makes this case interesting */
  about: string;
  body: string;
  /** dish names already on the matched restaurant's menu (empty = no place matched) */
  knownDishes?: string[];
  /**
   * WHAT THE FUNCTION RESOLVED for this entry, in the shape of its own locals: the row it
   * attached and the phrase that led there. fixtures_test runs it through the REAL
   * `fencedPlaceNames()` the function calls, so a fixture proves the whole chain — passing
   * the fence a hand-written list is how the live re-sort of `place-name-bleed` came back
   * with the dish `Pizza` while the fixture was green.
   */
  resolvedPlace?: ResolvedPlace;
  /** a phrase that MUST appear among placeCandidates(body); null = the text names no place */
  place: string | null;
  items: FixtureItem[];
  /**
   * Free-form writing only the model is expected to sort. fixtures_test skips its item
   * assertions (the stub is not graded on it) but still holds the stub to rules 7 and 9
   * on it; eval.ts grades the model on it like any other fixture.
   */
  modelOnly?: true;
};

export const fixtures: Fixture[] = [
  {
    id: 'design-entry',
    about: 'the design\'s own entry: half score, a plain score, an unscored dish, and "four minutes" which is not a score',
    body:
      'Tipo 00 with Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, glossy, gone in four minutes. Tiramisu 3.0 a bit flat after that. Jess\'s prawn spaghetti looked the business.',
    knownDishes: ['Tagliatelle al ragù', 'Tiramisu', 'Prawn spaghetti'],
    place: 'Tipo 00',
    items: [
      { dish_name: 'Tagliatelle al ragù', score: 4.5, note: 'unreal, rich, glossy, gone in four minutes.' },
      { dish_name: 'Tiramisu', score: 3.0, note: 'a bit flat after that.' },
      { dish_name: 'Prawn spaghetti', score: null, note: 'looked the business.' },
    ],
  },
  {
    id: 'feed-jessw',
    about: 'two dishes, second one scored in a fragment',
    body:
      'Birthday pasta. The prawn spaghetti 5.0 is still the best thing on Little Bourke, fight me. Tiramisu 4.0, as always.',
    knownDishes: ['Prawn spaghetti', 'Tiramisu'],
    place: null,
    items: [
      { dish_name: 'Prawn spaghetti', score: 5.0, note: 'still the best thing on Little Bourke, fight me.' },
      { dish_name: 'Tiramisu', score: 4.0, note: 'as always.' },
    ],
  },
  {
    id: 'butchers-new-dish',
    about: 'dish not on the menu yet (score-anchored), with a "forty minutes" duration nearby',
    body: 'Queued forty minutes for this cheeseburger 4.5 and would queue again.',
    knownDishes: [],
    place: null,
    items: [{ dish_name: 'cheeseburger', score: 4.5, note: 'would queue again.' }],
  },
  {
    id: 'no-place-list',
    about: 'no place named at all; two dishes in one list sentence, so neither owns the sentence as a note',
    body: 'Dumplings at the place near work, no idea what it\'s called. Pork and chive 4, prawn 3.5.',
    knownDishes: [],
    place: null,
    items: [
      { dish_name: 'Pork and chive', score: 4, note: null },
      { dish_name: 'prawn', score: 3.5, note: null },
    ],
  },
  {
    id: 'spoken-half-stars',
    about: 'spoken score with "and a half stars"',
    body: 'Chin Chin. The kingfish sashimi gets four and a half stars from me, clean and cold.',
    knownDishes: ['Kingfish sashimi'],
    place: 'Chin Chin',
    items: [{ dish_name: 'Kingfish sashimi', score: 4.5, note: 'from me, clean and cold.' }],
  },
  {
    id: 'out-of-five',
    about: '"a four out of five" spoken form',
    body: 'Supernormal. Pork bun is a four out of five, the lobster roll is a five.',
    knownDishes: ['Pork bun', 'Lobster roll'],
    place: 'Supernormal',
    items: [
      { dish_name: 'Pork bun', score: 4, note: null },
      { dish_name: 'Lobster roll', score: 5, note: null },
    ],
  },
  {
    id: 'slash-five',
    about: '4/5 notation',
    body: 'Margherita 4/5 at 400 Gradi. Crust was perfect, base a bit wet in the middle.',
    knownDishes: ['Margherita'],
    place: '400 Gradi',
    items: [{ dish_name: 'Margherita', score: 4, note: null }],
  },
  {
    id: 'price-trap',
    about: 'a price must never become a score',
    body: 'Beatrix. Raspberry cake was $18 and worth every cent.',
    knownDishes: ['Raspberry cake'],
    place: 'Beatrix',
    items: [{ dish_name: 'Raspberry cake', score: null, note: '$18 and worth every cent.' }],
  },
  {
    id: 'clock-trap',
    about: 'clock times must never become scores',
    body: 'Got to Kisume at 5 pm, out by 8:02. Salmon roll still the best thing here.',
    knownDishes: ['Salmon roll'],
    place: 'Kisume',
    items: [{ dish_name: 'Salmon roll', score: null, note: 'still the best thing here.' }],
  },
  {
    id: 'date-trap',
    about: 'a date must never become a score',
    body: 'Di Stasio, 12 September. Penne al ragù 4.5, the room does half the work.',
    knownDishes: ['Penne al ragù'],
    place: 'Di Stasio',
    items: [{ dish_name: 'Penne al ragù', score: 4.5, note: 'the room does half the work.' }],
  },
  {
    id: 'headcount-trap',
    about: '"two of us" and "x4" are not scores',
    body: 'Two of us at Hardware Societe, baked eggs x4 between us. Baked eggs 4.5.',
    knownDishes: ['Baked eggs'],
    place: 'Hardware Societe',
    items: [{ dish_name: 'Baked eggs', score: 4.5, note: 'x4 between us.' }],
  },
  {
    id: 'ordinal-trap',
    about: '"4th time" is not a score',
    body: '4th time at Osteria Ilaria this year. The pappardelle never misses.',
    knownDishes: ['Pappardelle'],
    place: 'Osteria Ilaria',
    items: [{ dish_name: 'Pappardelle', score: null, note: 'never misses.' }],
  },
  {
    id: 'three-dishes-prose',
    about: 'three dishes across three sentences, one unscored',
    body:
      'Long lunch at Kirk\'s Wine Bar. The steak tartare 4.5 was the best thing on the table. Sardines 3.5, a bit heavy on the vinegar. We also had the chips and I have nothing to report.',
    knownDishes: ['Steak tartare', 'Sardines', 'Chips'],
    place: 'Kirk\'s Wine Bar',
    items: [
      { dish_name: 'Steak tartare', score: 4.5, note: 'the best thing on the table.' },
      { dish_name: 'Sardines', score: 3.5, note: 'a bit heavy on the vinegar.' },
      { dish_name: 'Chips', score: null, note: 'I have nothing to report.' },
    ],
  },
  {
    id: 'dish-mentioned-twice',
    about: 'the same dish twice in one entry is one line item',
    body: 'Tipo 00 again. Tagliatelle al ragù 4.5. Honestly the tagliatelle al ragù is the only reason I come.',
    knownDishes: ['Tagliatelle al ragù'],
    place: 'Tipo 00',
    items: [{ dish_name: 'Tagliatelle al ragù', score: 4.5, note: 'the only reason I come.' }],
  },
  {
    id: 'score-before-dish',
    about: 'the number comes before the dish',
    body: 'Beatrix. A solid 4.5 for the raspberry cake, and nothing else needed saying.',
    knownDishes: ['Raspberry cake'],
    place: 'Beatrix',
    items: [{ dish_name: 'Raspberry cake', score: 4.5, note: 'nothing else needed saying.' }],
  },
  {
    id: 'lowercase-after-at',
    about: 'place introduced by "at" with ordinary capitalisation',
    body: 'Lunch at Supernormal. The pork bun 4.5, the kingfish 4.',
    knownDishes: ['Pork bun', 'Kingfish'],
    place: 'Supernormal',
    items: [
      { dish_name: 'Pork bun', score: 4.5, note: null },
      { dish_name: 'Kingfish', score: 4, note: null },
    ],
  },
  {
    id: 'line-breaks',
    about: 'newlines are sentence boundaries',
    body: 'Chin Chin\nKingfish sashimi 4.5 — the only thing I wanted\nSon in law eggs 3.5, too sweet',
    knownDishes: ['Kingfish sashimi', 'Son in law eggs'],
    place: 'Chin Chin',
    items: [
      { dish_name: 'Kingfish sashimi', score: 4.5, note: 'the only thing I wanted' },
      { dish_name: 'Son in law eggs', score: 3.5, note: 'too sweet' },
    ],
  },
  {
    id: 'messy-punctuation',
    about: 'emoji, ellipses, double punctuation',
    body: 'ok so... Tipo 00 🍝!! tagliatelle al ragù 4.5 — insane?? yes. tiramisu... 3, fine.',
    knownDishes: ['Tagliatelle al ragù', 'Tiramisu'],
    place: 'Tipo 00',
    items: [
      { dish_name: 'Tagliatelle al ragù', score: 4.5, note: 'insane??' },
      { dish_name: 'Tiramisu', score: 3, note: 'fine.' },
    ],
  },
  {
    id: 'no-dishes',
    about: 'a visit with no dish named — words only, no receipt items',
    body: 'Beautiful room, terrible service, I will not be back. Two hours for a table we booked.',
    knownDishes: [],
    place: null,
    items: [],
  },
  {
    id: 'empty-body',
    about: 'a photos-only entry: nothing to sort',
    body: '',
    knownDishes: [],
    place: null,
    items: [],
  },
  {
    id: 'shouting',
    about: 'all caps still parses',
    body: 'THE CHEESEBURGER AT BUTCHERS DINER IS A 5. THAT IS ALL.',
    knownDishes: ['Cheeseburger'],
    place: 'BUTCHERS DINER',
    items: [{ dish_name: 'Cheeseburger', score: 5, note: null }],
  },
  {
    id: 'five-dishes',
    about: 'a long omakase list, mixed scores',
    body:
      'Kisume omakase. Salmon roll 5, wagyu nigiri 4.5, kingfish 4, uni 3.5, and the tamago which I could take or leave.',
    knownDishes: ['Salmon roll', 'Wagyu nigiri', 'Kingfish', 'Uni', 'Tamago'],
    place: 'Kisume',
    items: [
      { dish_name: 'Salmon roll', score: 5, note: null },
      { dish_name: 'Wagyu nigiri', score: 4.5, note: null },
      { dish_name: 'Kingfish', score: 4, note: null },
      { dish_name: 'Uni', score: 3.5, note: null },
      { dish_name: 'Tamago', score: null, note: 'I could take or leave.' },
    ],
  },
  {
    id: 'long-note-unscored',
    about: 'a dish with plenty to say and no number at all',
    body:
      'Supernormal. The lobster roll is the reason this place has a queue out the door on a Tuesday, and I resent how good it is.',
    knownDishes: ['Lobster roll'],
    place: 'Supernormal',
    items: [
      {
        dish_name: 'Lobster roll',
        score: null,
        note: 'the reason this place has a queue out the door on a Tuesday, and I resent how good it is.',
      },
    ],
  },
  {
    id: 'a-solid-four',
    about: '"a solid four" — pre-marked spoken integer',
    body: '400 Gradi. Margherita is a solid four, the calzone is not.',
    knownDishes: ['Margherita', 'Calzone'],
    place: '400 Gradi',
    items: [
      { dish_name: 'Margherita', score: 4, note: null },
      { dish_name: 'Calzone', score: null, note: null },
    ],
  },
  {
    id: 'give-it-a',
    about: '"I would give it a 4.5"',
    body: 'Di Stasio. The penne al ragù, I would give it a 4.5 and I do not give those out.',
    knownDishes: ['Penne al ragù'],
    place: 'Di Stasio',
    items: [{ dish_name: 'Penne al ragù', score: 4.5, note: 'I do not give those out.' }],
  },
  {
    id: 'apostrophe-dish',
    about: 'a dish name with an apostrophe',
    body: 'Butchers Diner. Grandma\'s meatballs 4, better than they need to be at 2am.',
    knownDishes: ['Grandma\'s meatballs'],
    place: 'Butchers Diner',
    items: [{ dish_name: 'Grandma\'s meatballs', score: 4, note: 'better than they need to be at 2am.' }],
  },
  {
    id: 'numeric-dish-name',
    about: 'a dish whose name contains a number',
    body: 'Hardware Societe. The no. 3 toastie 4.5, the coffee 3.5.',
    knownDishes: ['No. 3 toastie', 'Coffee'],
    place: 'Hardware Societe',
    items: [
      { dish_name: 'No. 3 toastie', score: 4.5, note: null },
      { dish_name: 'Coffee', score: 3.5, note: null },
    ],
  },
  {
    id: 'three-and-a-half',
    about: 'spoken "three and a half" without the word stars',
    body: 'Chin Chin. Son in law eggs, three and a half, too sweet for me.',
    knownDishes: ['Son in law eggs'],
    place: 'Chin Chin',
    items: [{ dish_name: 'Son in law eggs', score: 3.5, note: 'too sweet for me.' }],
  },
  {
    id: 'point-five',
    about: 'spoken "four point five"',
    body: 'Tipo 00. Tagliatelle al ragù, four point five, obviously.',
    knownDishes: ['Tagliatelle al ragù'],
    place: 'Tipo 00',
    items: [{ dish_name: 'Tagliatelle al ragù', score: 4.5, note: null }],
  },
  {
    id: 'case-mismatch',
    about: 'the user\'s casing differs from the menu\'s; the menu spelling wins for the dish name',
    body: 'kisume. salmon roll 4.5, wagyu nigiri 4.',
    knownDishes: ['Salmon roll', 'Wagyu nigiri'],
    place: null,
    items: [
      { dish_name: 'Salmon roll', score: 4.5, note: null },
      { dish_name: 'Wagyu nigiri', score: 4, note: null },
    ],
  },
  {
    id: 'longest-name-wins',
    about: 'a menu with overlapping names: the longer one must win',
    body: 'Smoke Ring Co. The beef rib roll 4.5, gone before the table sat down.',
    knownDishes: ['Beef rib', 'Beef rib roll'],
    place: 'Smoke Ring Co',
    items: [{ dish_name: 'Beef rib roll', score: 4.5, note: 'gone before the table sat down.' }],
  },
  {
    id: 'very-short',
    about: 'the shortest useful entry',
    body: 'Chin Chin. Kingfish 4.5.',
    knownDishes: ['Kingfish'],
    place: 'Chin Chin',
    items: [{ dish_name: 'Kingfish', score: 4.5, note: null }],
  },
  {
    id: 'suburb-not-venue',
    about: 'a suburb is named but no venue is — the place must come from a real match, never from a location word',
    body: 'Somewhere in Fitzroy, did not catch the name. Bolognese 3.5, bread 4.',
    knownDishes: [],
    place: null,
    items: [
      { dish_name: 'Bolognese', score: 3.5, note: null },
      { dish_name: 'bread', score: 4, note: null },
    ],
  },
  {
    id: 'bare-integer-far-away',
    about: 'a bare integer that is not beside a dish and carries no marker is NOT a score',
    body: 'Tipo 00. The tiramisu, honestly, 3. Make of that what you will.',
    knownDishes: ['Tiramisu'],
    place: 'Tipo 00',
    items: [{ dish_name: 'Tiramisu', score: null, note: null }],
  },
  {
    id: 'two-scores-one-sentence',
    about: 'two dishes and two scores inside one sentence',
    body: 'Supernormal: pork bun 4.5 and lobster roll 5, in that order.',
    knownDishes: ['Pork bun', 'Lobster roll'],
    place: 'Supernormal',
    items: [
      { dish_name: 'Pork bun', score: 4.5, note: null },
      { dish_name: 'Lobster roll', score: 5, note: 'in that order.' },
    ],
  },
  {
    id: 'stars-plural',
    about: '"5 stars" with the marker word',
    body: 'Beatrix. Raspberry cake, 5 stars, no notes.',
    knownDishes: ['Raspberry cake'],
    place: 'Beatrix',
    items: [{ dish_name: 'Raspberry cake', score: 5, note: 'no notes.' }],
  },
  {
    id: 'duration-and-real-score',
    about: 'a duration and a real score in the same sentence',
    body: 'Kisume. The salmon roll 4.5 was gone in five minutes flat.',
    knownDishes: ['Salmon roll'],
    place: 'Kisume',
    items: [{ dish_name: 'Salmon roll', score: 4.5, note: 'gone in five minutes flat.' }],
  },
  {
    id: 'shared-no-score',
    about: 'verb-anchored dish with no number anywhere',
    body: 'Osteria Ilaria. We shared the pappardelle and then we shared a second pappardelle.',
    knownDishes: [],
    place: 'Osteria Ilaria',
    items: [{ dish_name: 'pappardelle', score: null, note: 'then we shared a second pappardelle.' }],
  },
  {
    id: 'low-score',
    about: 'a bad visit — low scores are scores too',
    body: 'Butchers Diner. Cheeseburger 1.5, cold in the middle. Fries 2, sad.',
    knownDishes: ['Cheeseburger', 'Fries'],
    place: 'Butchers Diner',
    items: [
      { dish_name: 'Cheeseburger', score: 1.5, note: 'cold in the middle.' },
      { dish_name: 'Fries', score: 2, note: 'sad.' },
    ],
  },
  {
    id: 'unknown-venue-named',
    about: 'the user names a venue we do not hold: the phrase is still a candidate, the DB lookup decides',
    body: 'New place on Gertrude called Petal & Pan. The sourdough focaccia 4.5, worth the walk.',
    knownDishes: [],
    place: 'Petal & Pan',
    items: [{ dish_name: 'sourdough focaccia', score: 4.5, note: 'worth the walk.' }],
  },

  // -------------------------------------------------------------------------
  // NOTES ARE CLAUSES (what design/v1/Entry prints: `"A bit flat after that."`)
  //
  // The note is what they said AFTER the dish and its score. It never repeats the dish
  // name or the score, because the receipt line above it already prints both. The
  // 'sentence' alternative is pinned in parse_test.ts, not here — the corpus asserts the
  // DEFAULT, which is what ships.
  // -------------------------------------------------------------------------
  {
    id: 'note-is-the-clause-after-the-score',
    about: 'the note starts after the dish and its score — "was" and other lead-in glue are trimmed off',
    body:
      'Omakase with the team. The salmon roll 4.5 was the quiet star, clean and cold and gone too fast. Could have skipped the second round of sake.',
    knownDishes: ['Salmon roll'],
    place: null,
    items: [{ dish_name: 'Salmon roll', score: 4.5, note: 'the quiet star, clean and cold and gone too fast.' }],
  },
  {
    id: 'note-shared-sentence-no-dangling-comma',
    about: 'two dishes in one sentence: each keeps its own clause, and neither ends on a dangling comma',
    body: 'Kisume. The salmon roll 5.0 was the quiet star, and the wagyu nigiri 4.5 was fine.',
    knownDishes: ['Salmon roll', 'Wagyu nigiri'],
    place: 'Kisume',
    items: [
      // "was the quiet star, and the" → the stopword trim exposes a comma, which is then
      // stripped. THE bug this fixture exists for.
      { dish_name: 'Salmon roll', score: 5.0, note: 'the quiet star' },
      { dish_name: 'Wagyu nigiri', score: 4.5, note: 'fine.' },
    ],
  },
  {
    id: 'note-clause-drops-the-lead-in',
    about: 'words BEFORE the dish are not in the note — they are still in `body`, which the slip prints above it',
    body: 'Butchers Diner. Stood in the rain twenty minutes for the cheeseburger 4 and I would do it again.',
    knownDishes: ['Cheeseburger'],
    place: 'Butchers Diner',
    items: [{ dish_name: 'Cheeseburger', score: 4, note: 'I would do it again.' }],
  },

  // -------------------------------------------------------------------------
  // WHERE THE SCORE IS — the offsets the client rebuilds its tokens from
  // -------------------------------------------------------------------------
  {
    id: 'offset-price-before-score',
    about:
      'a price contains the same digits as the score: searching the body for "4.5" finds $14.50 FIRST, so the offset must come from the sorter',
    body: 'Tipo 00. The tagliatelle was $14.50 and worth it. Tiramisu 4.5, better than it looks.',
    knownDishes: ['Tagliatelle', 'Tiramisu'],
    place: 'Tipo 00',
    items: [
      { dish_name: 'Tagliatelle', score: null, note: '$14.50 and worth it.' },
      // "4.5" also sits inside "$14.50" at scalar 31 — a naive search finds THAT one.
      // The score's own evidence is at 59.
      { dish_name: 'Tiramisu', score: 4.5, note: 'better than it looks.', evidence_offset: 59 },
    ],
  },
  {
    id: 'offset-after-an-emoji',
    about: 'an emoji is TWO UTF-16 code units but ONE scalar: the published offset is in scalars (31 vs 30)',
    body: 'Kisume 🍣 for one. Salmon roll 4.5, clean and cold.',
    knownDishes: ['Salmon roll'],
    place: 'Kisume',
    items: [
      { dish_name: 'Salmon roll', score: 4.5, note: 'clean and cold.', evidence_offset: 30 },
    ],
  },
  {
    id: 'lowercase-prose-dish-no-menu',
    about:
      'no place matched, so no menu: the name stays exactly as they wrote it and the DISPLAY name is normalised by find_or_create_dish on create, never here',
    body: 'salmon roll 4.5, wagyu nigiri 4.',
    knownDishes: [],
    place: null,
    items: [
      { dish_name: 'salmon roll', score: 4.5, note: null },
      { dish_name: 'wagyu nigiri', score: 4, note: null },
    ],
  },

  // -------------------------------------------------------------------------
  // MELBOURNE SPELLS THINGS WITH ACCENTS
  //
  // JavaScript's `\w` is ASCII-only, so every one of these entries was mis-sorted on
  // staging: "ragù" became the dish "Tagliatelle al rag", "crème brûlée" lost its first
  // word, "Bánh mì 4" produced no dish at all, and "at Émile" attached to "Dinner".
  // A dish mention must cover the WHOLE word, whichever alphabet it is written in.
  // -------------------------------------------------------------------------
  {
    id: 'accent-ragu-from-prose',
    about: 'THE staging bug: a new dish taken from the words must keep its last letter ("ragù", not "rag")',
    body: 'Tipo 00. The tagliatelle al ragù 4.5 was rich, glossy, gone in four minutes.',
    knownDishes: [],
    place: 'Tipo 00',
    items: [{ dish_name: 'tagliatelle al ragù', score: 4.5, note: 'rich, glossy, gone in four minutes.' }],
  },
  {
    id: 'accent-creme-brulee-on-the-menu',
    about: 'two accented words in one menu name — the name fence must not break inside "crème"',
    body: 'Beatrix. The crème brûlée 4.5, cracked properly.',
    knownDishes: ['Crème brûlée'],
    place: 'Beatrix',
    items: [{ dish_name: 'Crème brûlée', score: 4.5, note: 'cracked properly.' }],
  },
  {
    id: 'accent-banh-mi-opens-the-entry',
    about: 'diacritics on both words, sentence-initial: the dish used to vanish entirely',
    body: 'Bánh mì 4 from the truck near work, still warm.',
    knownDishes: [],
    place: null,
    items: [{ dish_name: 'Bánh mì', score: 4, note: 'from the truck near work, still warm.' }],
  },
  {
    id: 'accent-jalapeno-mid-word',
    about: 'ñ inside the first word of a two-word dish',
    body: 'Butchers Diner. Jalapeño poppers 3.5, actually hot.',
    knownDishes: [],
    place: 'Butchers Diner',
    items: [{ dish_name: 'Jalapeño poppers', score: 3.5, note: 'actually hot.' }],
  },
  {
    id: 'accent-venue-name',
    about: 'a venue whose name opens with a non-ASCII capital — "at Émile" used to offer "Dinner" instead',
    body: 'Dinner at Émile. The soufflé 5.',
    knownDishes: [],
    place: 'Émile',
    items: [{ dish_name: 'soufflé', score: 5, note: null }],
  },

  // -------------------------------------------------------------------------
  // FALSE LINE ITEMS — the five the 32-entry staging seed surfaced, two of them
  // false SCORES (a rule-7 breach: the number was the user's, but not about a dish).
  //
  // The first two are killed at the NUMBER: a ranking idiom and a count are not scores,
  // so no number means no score-anchored dish either ("Top", "Order" vanish with them).
  // The last three are killed by THE ANCHOR RULE: an unscored candidate must be on the
  // menu or introduced by a determiner. A noun run mined out of prose is a description.
  // -------------------------------------------------------------------------
  {
    id: 'false-top-five-is-a-ranking',
    about: '"a top five Melbourne pizza" gave the dish "Top" a score of 5.0 — a ranking idiom is never a score',
    body: '400 Gradi. Margherita 4.5 — is a top five Melbourne pizza.',
    knownDishes: ['Margherita'],
    place: '400 Gradi',
    // the ranking survives as the margherita's NOTE, which is where it belongs
    items: [{ dish_name: 'Margherita', score: 4.5, note: 'a top five Melbourne pizza.' }],
  },
  {
    id: 'false-top-5-digits',
    about: 'the same idiom written with a digit',
    body: '400 Gradi. Margherita 4.5, easily a top 5 pizza in this city.',
    knownDishes: ['Margherita'],
    place: '400 Gradi',
    items: [{ dish_name: 'Margherita', score: 4.5, note: 'easily a top 5 pizza in this city.' }],
  },
  {
    id: 'false-order-two-is-a-count',
    about: '"Order two." gave the dish "Order" a score of 2.0 — an imperative + number is how many',
    body: 'Tipo 00. Tagliatelle al ragù 4.5, glossy, peppery, tiny. Order two.',
    knownDishes: ['Tagliatelle al ragù'],
    place: 'Tipo 00',
    items: [{ dish_name: 'Tagliatelle al ragù', score: 4.5, note: 'glossy, peppery, tiny.' }],
  },
  {
    id: 'false-order-twice',
    about: '"would order twice" became a dish called "Twice" — an adverb after a verb is not a dish',
    body: 'Lune. Focaccia came warm, would order twice.',
    knownDishes: ['Focaccia'],
    place: 'Lune',
    items: [{ dish_name: 'Focaccia', score: null, note: 'came warm, would order twice.' }],
  },
  {
    id: 'false-leopard-spotting',
    about: 'an unscored noun run out of prose ("proper leopard spotting") is a description, not an order',
    body: '400 Gradi. The margherita 4.5 had proper leopard spotting on the crust.',
    knownDishes: ['Margherita'],
    place: '400 Gradi',
    items: [{ dish_name: 'Margherita', score: 4.5, note: 'had proper leopard spotting on the crust.' }],
  },
  {
    id: 'false-real-heat',
    about: 'same class: "the salsa had real heat" is about the food, and "Real heat" is not a line item',
    body: 'Mamasita. The tacos 4, and the salsa had real heat.',
    knownDishes: ['Tacos'],
    place: 'Mamasita',
    // and because the phantom is dropped BEFORE the note windows are cut, the tacos keep
    // the whole clause instead of quoting "the salsa" and stopping.
    items: [{ dish_name: 'Tacos', score: 4, note: 'the salsa had real heat.' }],
  },
  {
    id: 'count-after-a-verb-no-longer-steals-the-score',
    about:
      'found while fixing the above: "got a four" minted a dish "four" AND left the pork bun unscored — a number is never the head of a dish name',
    body: 'Supernormal. The pork bun got a four from me.',
    knownDishes: ['Pork bun'],
    place: 'Supernormal',
    // no note: "from me." is nothing but glue (hasOpinion), so the line prints bare
    items: [{ dish_name: 'Pork bun', score: 4, note: null }],
  },
  {
    id: 'marked-score-after-a-verb-survives',
    about:
      'and "got 5 stars" minted a dish "5 stars": an explicit marker still makes it a score, and it belongs to the cake',
    body: 'Beatrix. Raspberry cake got 5 stars, no notes.',
    knownDishes: ['Raspberry cake'],
    place: 'Beatrix',
    items: [{ dish_name: 'Raspberry cake', score: 5, note: 'no notes.' }],
  },
  {
    id: 'roti-for-the-curry',
    about: 'the shape that must keep working: a bare integer beside the dish, with a clause after it',
    body: 'Roti 4 for the curry, obviously.',
    knownDishes: [],
    place: null,
    items: [{ dish_name: 'Roti', score: 4, note: 'for the curry, obviously.' }],
  },

  // -------------------------------------------------------------------------
  // THE SCORE LEAD-IN — "X was a 4.5" scored NOTHING (the CEO's own entries,
  // staging 2026-09-24). The number was always found; the DISH was not, because the
  // walk in front of the number stops at a stopword and "was", "is", "a" and "solid"
  // are all stopwords. Every phrasing below is a user scoring a dish.
  // -------------------------------------------------------------------------
  {
    id: 'ceo-fishbowl-margarita',
    about:
      'THE ENTRY THAT SORTED TO NOTHING: "<dish> was a <n>", with the double space the CEO typed and slang after the score',
    body: 'PJ’s Mexican cantina fishbowl margarita  was a 4.5 and eliteeeee',
    knownDishes: [],
    // the place resolved, so the ROW NAME is off limits to the dish hunt — otherwise the
    // dish is "Mexican cantina fishbowl margarita". The candidate phrase that found the row
    // is only part of the name here, and is fenced by nothing.
    resolvedPlace: { matchedName: 'PJ\'s Mexican cantina', candidatePhrase: 'PJ’s Mexican' },
    place: 'PJ’s Mexican',
    items: [{ dish_name: 'fishbowl margarita', score: 4.5, note: 'eliteeeee', evidence_offset: 47 }],
  },
  {
    id: 'lead-in-is-a-and-gets-a',
    about: '"<dish> is a <n>" and "<dish> gets a <n>" in one breath, both on the menu',
    body: 'Chin Chin. The kingfish is a 4.5 and the pork bun gets a 3.5.',
    knownDishes: ['Kingfish', 'Pork bun'],
    resolvedPlace: { matchedName: 'Chin Chin', candidatePhrase: 'Chin Chin' },
    place: 'Chin Chin',
    items: [
      { dish_name: 'Kingfish', score: 4.5, note: null },
      { dish_name: 'Pork bun', score: 3.5, note: null },
    ],
  },
  {
    id: 'lead-in-new-dish',
    about: 'the same phrasing for a dish not on the menu yet — the lead-in is what finds the name',
    body: 'Supernormal. The lobster roll was a 4.5, the best thing all week.',
    knownDishes: [],
    resolvedPlace: { matchedName: 'Supernormal', candidatePhrase: 'Supernormal' },
    place: 'Supernormal',
    items: [{ dish_name: 'lobster roll', score: 4.5, note: 'the best thing all week.' }],
  },
  {
    id: 'lead-in-gave-the-dish-a',
    about: '"gave the <dish> a <n>" — the verb names the dish and the article carries the number',
    body: 'Beatrix. I gave the raspberry cake a 4.5 and would again.',
    knownDishes: [],
    resolvedPlace: { matchedName: 'Beatrix', candidatePhrase: 'Beatrix' },
    place: 'Beatrix',
    items: [{ dish_name: 'raspberry cake', score: 4.5, note: 'would again.' }],
  },
  {
    id: 'lead-in-a-solid',
    about: '"<dish>, a solid <n>" — the pre-marker adjective sits between the dish and its score',
    body: 'Tipo 00. The tiramisu, a solid 3.5, then home.',
    knownDishes: [],
    resolvedPlace: { matchedName: 'Tipo 00', candidatePhrase: 'Tipo 00' },
    place: 'Tipo 00',
    items: [{ dish_name: 'tiramisu', score: 3.5, note: 'home.' }],
  },

  // -------------------------------------------------------------------------
  // THE PLACE IS NOT THE DISH — and not the front half of one.
  // -------------------------------------------------------------------------
  {
    id: 'place-name-bleed',
    about:
      'staging: "Baby Pizza San Danielle Pizza 3.5" minted a dish called "Pizza San Danielle Pizza" — the walk ate the venue\'s last word',
    body: 'Baby Pizza San Danielle Pizza 3.5 was decent, nothing crazy.',
    knownDishes: [],
    // THE LIVE INPUTS, not a tidied version of them: the candidate run that found this row
    // is "Baby Pizza San Danielle" (placeCandidates offers it first, longest-capitalised-run
    // first), and fencing THAT is what made the dish come back as `Pizza` on the re-sort.
    // Only the row name may be fenced; the rest of the run is dish territory.
    resolvedPlace: {
      matchedName: 'Baby Pizza',
      candidatePhrase: 'Baby Pizza San Danielle',
      mentionPhrase: 'Baby Pizza San Danielle',
    },
    place: 'Baby Pizza',
    items: [{ dish_name: 'San Danielle Pizza', score: 3.5, note: 'decent, nothing crazy.' }],
  },
  {
    id: 'place-scored-is-not-a-dish',
    about: 'scoring the PLACE is not scoring a dish: "Baby Pizza was a 4.5" prints no receipt line',
    body: 'Baby Pizza was a 4.5. Everything we ordered worked.',
    knownDishes: [],
    resolvedPlace: { matchedName: 'Baby Pizza', candidatePhrase: 'Baby Pizza' },
    place: 'Baby Pizza',
    items: [],
  },

  // -------------------------------------------------------------------------
  // MODEL-ONLY — how people actually type: run-ons, scores in words, the place
  // mid-sentence, lowercase, double spaces, unscored dishes. No known menu and no
  // resolved place, so nothing but the words to go on. The stub is not graded here.
  // -------------------------------------------------------------------------
  {
    id: 'model-venue-run-on',
    about: 'venue, three dishes and three scores in one breath, no punctuation',
    body: 'Baby Pizza San Danielle Pizza 3.5 cacio e pepe pizza 4 and the tiramisu was a 3 kinda dry',
    place: 'Baby Pizza',
    modelOnly: true,
    items: [
      { dish_name: 'San Danielle Pizza', score: 3.5, note: null },
      { dish_name: 'cacio e pepe pizza', score: 4, note: null },
      { dish_name: 'tiramisu', score: 3, note: 'kinda dry' },
    ],
  },
  {
    id: 'model-scores-in-words',
    about: 'every score spelled out, hedged ("honestly", "a solid", "maybe")',
    body:
      'Tipo 00 with Jess again, the pappardelle was honestly a four, the burnt butter gnocchi a solid three and a half and the tiramisu maybe a three',
    place: 'Tipo 00',
    modelOnly: true,
    items: [
      { dish_name: 'pappardelle', score: 4, note: null },
      { dish_name: 'burnt butter gnocchi', score: 3.5, note: null },
      { dish_name: 'tiramisu', score: 3, note: null },
    ],
  },
  {
    id: 'model-place-mid-sentence',
    about: 'the place is named halfway through a run-on, after the night out',
    body:
      "had the best night then ended up at Hector's Deli on the way home and the reuben was a 4.5 easily the best sandwich this year",
    place: "Hector's Deli",
    modelOnly: true,
    items: [{ dish_name: 'reuben', score: 4.5, note: 'easily the best sandwich this year' }],
  },
  {
    id: 'model-unscored-then-scored',
    about: 'a raved-about dish with no number (stays unscored) beside a scored one',
    body: 'Lune on a Sunday, the plain croissant was so flaky it shattered everywhere and the twice baked almond 4 bit too sweet',
    place: 'Lune',
    modelOnly: true,
    items: [
      { dish_name: 'plain croissant', score: null, note: 'so flaky it shattered everywhere' },
      { dish_name: 'twice baked almond', score: 4, note: 'bit too sweet' },
    ],
  },
  {
    id: 'model-sentiment-only',
    about: 'superlatives everywhere and not one number: nothing is scored',
    body: "Florentino Grill with dad, the veal cutlet was genuinely perfect and the chips were the best I've had in years",
    place: 'Florentino Grill',
    modelOnly: true,
    items: [
      { dish_name: 'veal cutlet', score: null, note: 'genuinely perfect' },
      { dish_name: 'chips', score: null, note: "the best I've had in years" },
    ],
  },
  {
    id: 'model-counts-are-not-scores',
    about: '"3 plates", "2 of us" are counts; only the 4 beside the potato is a score',
    body: 'Shared 3 plates at Bar Liberty between 2 of us, smoked potato 4 crispy and salty, the flatbread a bit stale',
    place: 'Bar Liberty',
    modelOnly: true,
    items: [
      { dish_name: 'smoked potato', score: 4, note: 'crispy and salty' },
      { dish_name: 'flatbread', score: null, note: 'a bit stale' },
    ],
  },
  {
    id: 'model-self-correction',
    about: 'the user corrects their own score mid-sentence; the second number is the score',
    body: 'Hochi Mama bao 4 no actually a 3.5 the bun was a bit doughy',
    place: 'Hochi Mama',
    modelOnly: true,
    items: [{ dish_name: 'bao', score: 3.5, note: 'the bun was a bit doughy' }],
  },
  {
    id: 'model-spoken-halves',
    about: '"three point five" and "four and a half", no punctuation between dishes',
    body: "Supernormal the lobster roll three point five tbh overhyped, peanut butter parfait four and a half I'd go back just for it",
    place: 'Supernormal',
    modelOnly: true,
    items: [
      { dish_name: 'lobster roll', score: 3.5, note: 'tbh overhyped' },
      { dish_name: 'peanut butter parfait', score: 4.5, note: "I'd go back just for it" },
    ],
  },
  {
    id: 'model-lowercase-dish-first',
    about: 'all lowercase, dish before the place, and the rest of the sentence is about the user',
    body: 'spicy rigatoni 4.5 from tipo 00 again because I have zero self control',
    place: 'tipo 00',
    modelOnly: true,
    items: [{ dish_name: 'spicy rigatoni', score: 4.5, note: null }],
  },
  {
    id: 'model-price-time-run-on',
    about: 'a clock time and a price in the same run-on as two real scores and an unscored dish',
    body: 'Got to Kisume at 5 the omakase was $185 a head and worth it, toro nigiri a five, uni a 4 bit metallic tho',
    place: 'Kisume',
    modelOnly: true,
    items: [
      { dish_name: 'omakase', score: null, note: '$185 a head and worth it' },
      { dish_name: 'toro nigiri', score: 5, note: null },
      { dish_name: 'uni', score: 4, note: 'bit metallic tho' },
    ],
  },
  {
    id: 'model-double-spaces-slang',
    about: 'double spaces, "w", slang, and a dish rated in slang but not in numbers',
    body: 'Mamasita w the girls  fish tacos were a 4, the elote 4.5 messy but elite and the frozen marg  eliteeeee',
    place: 'Mamasita',
    modelOnly: true,
    items: [
      { dish_name: 'fish tacos', score: 4, note: null },
      { dish_name: 'elote', score: 4.5, note: 'messy but elite' },
      { dish_name: 'frozen marg', score: null, note: 'eliteeeee' },
    ],
  },
];

export const FIXTURE_COUNT = fixtures.length;
