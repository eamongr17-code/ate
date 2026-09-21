// supabase/functions/sort-entry/fixtures.ts
//
// THE EVAL CORPUS — 40 realistic entries with their expected sort.
//
// This file has two jobs:
//   1. It pins the deterministic stub parser (fixtures_test.ts asserts every item).
//   2. It is the HARNESS THE REAL MODEL WILL BE JUDGED BY. When ANTHROPIC_API_KEY
//      lands, run the same corpus through model mode and compare with the same
//      assertions — nothing about the expectations is stub-specific, because they
//      describe what the USER SAID, not how we found it.
//
// Every expectation obeys the two rules, so a correct sorter of ANY kind passes:
//   * `score` is non-null ONLY where the words contain an explicit number for that
//     dish. Sentiment never earns a score, however strong ("unreal", "the best
//     thing on Little Bourke").
//   * `note` is always an exact substring of `body`. fixtures_test.ts re-checks that
//     mechanically for all 40, so a typo in a note cannot sneak in as a rewrite.
//
// The corpus deliberately includes the numbers that are NOT scores — durations,
// prices, clock times, dates, head counts, ordinals, quantities — because inventing a
// score from one of those is the single worst bug this system can have.

export type FixtureItem = {
  dish_name: string;
  score: number | null;
  note: string | null;
};

export type Fixture = {
  id: string;
  /** what makes this case interesting */
  about: string;
  body: string;
  /** dish names already on the matched restaurant's menu (empty = no place matched) */
  knownDishes?: string[];
  /** a phrase that MUST appear among placeCandidates(body); null = the text names no place */
  place: string | null;
  items: FixtureItem[];
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
];

export const FIXTURE_COUNT = fixtures.length;
