// supabase/tests/db/diet_test.mjs — DIET (0074) at the SQL level: profiles.diet (owner PATCH, canonical,
// closed set), the stamp on NEW lines and never on inherited/corrected ones, turning a code off (in
// Compose via items[].diet_off, and after save via the tags PATCH), and the dish LABEL rule (3 different
// people within 12 months, vg counting as v, df, ef and pe (0084), any diet_off a veto) with diet_counts —
// on dish_summary, place_dishes, and every filter that reads it.
// Where a diet-off token lands in the words is sort-entry's job — functions/sort-entry/tags_test.ts.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, rows, error;

before(async () => {
  w = await world();
  ({ db, as, rows, error } = w);
});
after(async () => db?.close());

const setDiet = (uid, diet) => as(uid, () => db.query(`update public.profiles set diet = $2 where id = $1`, [uid, diet]));
const dietOf = async (uid) => (await rows(`select diet from public.profiles where id = $1`, [uid]))[0].diet;
const lines = async (entry) =>
  rows(`select v.id, d.name, v.dish_id, v.tags, v.diet_tags, v.diet_off from public.reviews v
          join public.dishes d on d.id = v.dish_id where v.entry_id = $1 order by v.entry_position`, [entry]);
const shape = (ls) => ls.map((l) => [l.name, l.tags, l.diet_tags, l.diet_off]);
const patchTags = (uid, review, tags) => as(uid, () => db.query(`update public.reviews set tags = $2 where id = $1`, [review, tags]));
/** receipt() with items[].diet_off set per dish name. */
const withOff = (r, offs) => ({ ...r, items: r.items.map((i) => (offs[i.dish_name] ? { ...i, diet_off: offs[i.dish_name] } : i)) });
const summary = async (dish, uid = U.dan) =>
  (await as(uid, () => rows(`select tags, diet_counts from public.dish_summary($1)`, [dish])))[0];

test('0074: profiles.diet — the owner\'s PATCH, canonical and closed; nobody else can write it', async () => {
  assert.deepEqual(await dietOf(U.alice), [], 'everyone starts with none');
  await setDiet(U.alice, ['NF', ' gf ', 'gf']);
  assert.deepEqual(await dietOf(U.alice), ['gf', 'nf'], 'lower-cased, trimmed, deduped, canonical order');
  assert.equal((await error(setDiet(U.alice, ['keto'])))?.code, '23514', 'a code outside the closed set');
  await as(U.bob, () => db.query(`update public.profiles set diet = '{vg}' where id = $1`, [U.alice]));
  assert.deepEqual(await dietOf(U.alice), ['gf', 'nf'], 'RLS: a stranger cannot set your diet');
  await setDiet(U.alice, ['vg']);
  assert.deepEqual(await dietOf(U.alice), ['vg'], 'vegan is stored as vg alone — nothing adds v or df');
  const [me] = await as(U.alice, () => rows(`select public.my_diet() diet`));
  assert.deepEqual(me.diet, ['vg'], 'the owner reads it back (0094: through my_diet, the column is private)');
  assert.equal((await as(U.bob, () => error(db.query(`select diet from public.profiles where id = $1`, [U.alice]))))?.code, '42501',
    '0094: nobody else reads it');
});

test('0074 D1: a new line is stamped with the diet, less what Compose turned off', async () => {
  const E = await w.visit(1, U.alice, P.tipo,
    withOff(receipt(['Mushroom Bao', 4.5, { tags: ['gf'] }], ['Tofu Larb', 4], ['Prawn Toast', 4]),
      { 'Prawn Toast': ['vg', 'nf'] }),                      // nf is not her diet: ignored
    '2026-10-01T09:00:00Z');
  assert.deepEqual(shape(await lines(E)), [
    ['Mushroom Bao', ['gf', 'vg'], ['vg'], []],
    ['Tofu Larb', ['vg'], ['vg'], []],
    ['Prawn Toast', [], [], ['vg']],
  ]);
  const [card] = await as(U.bob, () => rows(`select items from public.entry_cards where id = $1`, [E]));
  assert.deepEqual(card.items.map((i) => [i.tags, i.diet_tags]),
    [[['gf', 'vg'], ['vg']], [['vg'], ['vg']], [[], []]], 'entry_cards.items[].diet_tags, [] when none');
  const [plan] = await rows(`select sort_plan from public.entries where id = $1`, [E]);
  assert.deepEqual(plan.sort_plan.map((i) => [i.diet_tags, i.diet_off]), [[['vg'], []], [['vg'], []], [[], ['vg']]]);
});

test('0074 D2: a re-sort never re-stamps — a changed diet reaches only dishes logged afterwards', async () => {
  const E = id(1);
  await setDiet(U.alice, ['gf']);
  await w.sortAs(E, P.tipo, receipt(['Mushroom Bao', 4.5], ['Tofu Larb', 4], ['Prawn Toast', 4], ['Dumplings', 5]).items);
  assert.deepEqual(shape(await lines(E)), [
    ['Mushroom Bao', ['gf', 'vg'], ['vg'], []],
    ['Tofu Larb', ['vg'], ['vg'], []],
    ['Prawn Toast', [], [], ['vg']],
    ['Dumplings', ['gf'], ['gf'], []],                     // the one new dish: today's diet
  ]);

  // a line logged before the author had any diet stays unstamped through every edit
  await setDiet(U.bob, []);
  const B = await w.visit(2, U.bob, P.tipo, receipt(['Gnocchi', 4]), '2026-10-02T09:00:00Z');
  await setDiet(U.bob, ['df']);
  await w.sortAs(B, P.tipo, receipt(['Gnocchi', 4], ['Tiramisu', 3]).items);
  assert.deepEqual(shape(await lines(B)), [['Gnocchi', [], [], []], ['Tiramisu', ['df'], ['df'], []]]);
  await setDiet(U.bob, []);
  await setDiet(U.alice, ['vg']);
});

test('0074 D2: turning a code off on an edit removes the diet\'s tag from that line only', async () => {
  const E = id(1);
  await w.sortAs(E, P.tipo, withOff(
    receipt(['Mushroom Bao', 4.5], ['Tofu Larb', 4], ['Prawn Toast', 4], ['Dumplings', 5]),
    { 'Tofu Larb': ['vg'] }).items);
  assert.deepEqual(shape(await lines(E))[1], ['Tofu Larb', [], [], ['vg']]);
  assert.deepEqual(shape(await lines(E))[0], ['Mushroom Bao', ['gf', 'vg'], ['vg'], []], 'the others keep theirs');
});

test('0074 D3: removing a diet tag by PATCH turns it off; adding it back restores it; the columns are server-owned', async () => {
  const E = id(1);
  const bao = (await lines(E))[0];
  await patchTags(U.alice, bao.id, ['gf']);
  assert.deepEqual(shape([{ ...(await lines(E))[0] }])[0], ['Mushroom Bao', ['gf'], [], ['vg']], 'vg → diet_off');
  await patchTags(U.alice, bao.id, ['gf', 'vg']);
  assert.deepEqual(shape(await lines(E))[0], ['Mushroom Bao', ['gf', 'vg'], ['vg'], []], 'back on: the diet\'s again');
  await patchTags(U.alice, bao.id, ['vg']);
  assert.deepEqual(shape(await lines(E))[0], ['Mushroom Bao', ['vg'], ['vg'], []], 'a non-diet tag leaving changes nothing else');

  const refused = async (sql, params) => (await as(U.alice, () => error(db.query(sql, params))))?.code;
  assert.equal(await refused(`update public.reviews set diet_off = '{gf,v}', diet_tags = '{}' where id = $1`, [bao.id]), '42501',
    'a client cannot write diet_tags / diet_off (0094: only tags is client-writable)');
  assert.deepEqual(shape(await lines(E))[0], ['Mushroom Bao', ['vg'], ['vg'], []]);
  assert.equal(await refused(`insert into public.reviews (reviewer_id, dish_id, entry_id) values ($1, $2, $3)`,
    [U.alice, bao.dish_id, E]), '42501', '…nor insert a line at all (0094)');
});

test('0074: a corrected line is never re-stamped, and still takes a code turned off', async () => {
  await setDiet(U.cleo, ['v']);
  const E = await w.visit(3, U.cleo, P.tipo, receipt(['Margherita', 4]), '2026-10-03T09:00:00Z');
  const [m] = await lines(E);
  // 0094: no client writes a score any more; a corrected line is stamped as the correction RPCs do.
  await db.query(`update public.reviews set score = 4.5, corrected_at = now() where id = $1`, [m.id]);
  await setDiet(U.cleo, ['v', 'gf']);
  await w.sortAs(E, P.tipo, receipt(['Margherita', 4]).items);
  assert.deepEqual(shape(await lines(E)), [['Margherita', ['v'], ['v'], []]], 'gf (new diet) not stamped on it');
  await w.sortAs(E, P.tipo, withOff(receipt(['Margherita', 4]), { Margherita: ['v', 'gf'] }).items);
  assert.deepEqual(shape(await lines(E)), [['Margherita', [], [], ['gf', 'v']]],
    'v leaves its tags; gf (diet, never stamped here) is recorded as turned off');
  await setDiet(U.cleo, []);
});

test('0074: a parked plan carries its stamp to the place it is printed at', async () => {
  await setDiet(U.dan, ['nf']);
  const E = id(4);
  const r = withOff(receipt(['Satay', 4], ['Rice', 3]), { Satay: ['nf'] });
  await w.legacyPlaceless(E, U.dan, r.body, '2026-10-04T09:00:00Z');
  await w.sortAs(E, null, r.items);
  await setDiet(U.dan, ['gf']);                              // changed before the place is attached
  await as(U.dan, () => db.query(`select public.correct_entry_place($1, $2)`, [E, P.far]));
  assert.deepEqual(shape(await lines(E)), [['Satay', [], [], ['nf']], ['Rice', ['nf'], ['nf'], []]]);
  await setDiet(U.dan, []);
});

test('0074 + 0084 LABEL: 3 different people within 12 months; vg counts as v, df, ef, pe; one diet_off vetoes', async () => {
  const at = P.osteria;
  const r = (tags) => receipt(['Eggplant Curry', 4, { tags }]);
  const E1 = await w.visit(11, U.alice, at, r(['vg']), '2026-10-05T09:00:00Z');   // alice's diet stamps vg too
  const dish = (await lines(E1))[0].dish_id;
  assert.deepEqual(await summary(dish), { tags: [], diet_counts: { df: 1, v: 1, vg: 1, pe: 1, ef: 1 } }, 'one person: counts, no label');

  await w.visit(12, U.alice, at, r(['vg']), '2026-10-06T09:00:00Z');
  assert.deepEqual((await summary(dish)).diet_counts, { df: 1, v: 1, vg: 1, pe: 1, ef: 1 }, 'the same person twice is one person');

  await w.visit(13, U.bob, at, r(['v']), '2026-10-07T09:00:00Z');
  await w.visit(14, U.cleo, at, r(['vg', 'gf']), '2026-10-08T09:00:00Z');
  assert.deepEqual(await summary(dish), { tags: ['v', 'pe'], diet_counts: { gf: 1, df: 2, v: 3, vg: 2, pe: 3, ef: 2 } },
    'v and pe: alice (vg), bob (v), cleo (vg) = 3 → labelled; every counted code carries its count (0084)');

  await w.visit(15, U.dan, at, r(['vg']), '2025-09-01T09:00:00Z');                   // 13+ months ago
  assert.deepEqual((await summary(dish)).tags, ['v', 'pe'], 'a line outside the window counts for nothing');
  await w.visit(16, U.dan, at, r(['vg']), '2026-10-09T09:00:00Z');
  assert.deepEqual(await summary(dish), { tags: ['df', 'v', 'vg', 'pe', 'ef'], diet_counts: { gf: 1, df: 3, v: 4, vg: 3, pe: 4, ef: 3 } }, 'dan makes 3 vegans');
  assert.deepEqual(await summary(dish, null), { tags: ['df', 'v', 'vg', 'pe', 'ef'], diet_counts: { gf: 1, df: 3, v: 4, vg: 3, pe: 4, ef: 3 } }, 'signed out agrees');
  const [menu] = await as(U.bob, () => rows(`select tags, diet_counts from public.place_dishes($1) where dish_id = $2`, [at, dish]));
  assert.deepEqual(menu, { tags: ['df', 'v', 'vg', 'pe', 'ef'], diet_counts: { gf: 1, df: 3, v: 4, vg: 3, pe: 4, ef: 3 } }, 'the place page row agrees');

  // the filters find a v dish whose lines say only vg
  const [f] = await as(U.bob, () => rows(
    `select public.place_has_tagged_dish($1, '{v,df}') as place, $2 = any(public.tag_dish_ids('diet', 'v')) as tag_page,
            exists (select 1 from public.dishes_by_tag('diet', 'df') d where d.dish_id = $2) as chip`, [at, dish]));
  assert.deepEqual(f, { place: true, tag_page: true, chip: true });

  // one vegan turning vg off on their line vetoes vg — not v or df
  const [aliceLine] = await lines(E1);
  await patchTags(U.alice, aliceLine.id, []);
  assert.deepEqual((await lines(E1))[0].diet_off, ['vg']);
  assert.deepEqual(await summary(dish), { tags: ['df', 'v', 'pe', 'ef'], diet_counts: { gf: 1, df: 3, v: 4, pe: 4, ef: 3 } },
    'vg vetoed (and so not counted either); v, df, pe and ef stand');
});

test('0084: the five new codes — closed set, nut free counts as peanut free, filters follow', async () => {
  await setDiet(U.alice, ['ha', 'PF', 'sf']);
  assert.deepEqual(await dietOf(U.alice), ['ha', 'pf', 'sf'], 'accepted, canonical');
  await setDiet(U.alice, []);
  const at = P.tipo;
  const r = (tags) => receipt(['Satay Chicken', 4, { tags }]);
  const E1 = await w.visit(41, U.alice, at, r(['nf', 'ha']), '2026-10-10T09:00:00Z');
  const dish = (await lines(E1))[0].dish_id;
  await w.visit(42, U.bob, at, r(['pf', 'ha']), '2026-10-11T09:00:00Z');
  await w.visit(43, U.cleo, at, r(['pf', 'ef', 'sf']), '2026-10-12T09:00:00Z');
  assert.deepEqual(await summary(dish), { tags: ['pf'], diet_counts: { nf: 1, ha: 2, ef: 1, pf: 3, sf: 1 } },
    'pf: alice (nf), bob, cleo = 3 → labelled; pf never counts toward nf');
  const [f] = await as(U.bob, () => rows(
    `select public.place_has_tagged_dish($1, '{pf}') as place, $2 = any(public.tag_dish_ids('diet', 'pf')) as tag_page`, [at, dish]));
  assert.deepEqual(f, { place: true, tag_page: true });
  assert.deepEqual((await rows(`select public.diet_tags_implied('{v}') as v, public.diet_tags_implied('{vg,nf}') as vgnf`))[0],
    { v: ['v', 'pe'], vgnf: ['df', 'v', 'vg', 'nf', 'pe', 'ef', 'pf'] });
});

test('0074 T3: with every replaced line a candidate, the strongest match wins (QA repro: untagged lines must not steal)', async () => {
  await setDiet(U.bob, []);
  const item = (body, name, mention, extra = {}) => ({
    dish_name: name, mention_text: mention, mention_offset: [...body.slice(0, body.indexOf(mention))].length,
    score: 4, score_evidence: 'both 4', ...extra,
  });
  const b1 = 'Fries and burger, both 4';
  const E = await w.visit(40, U.bob, P.marion,
    { body: b1, items: [item(b1, 'Fries', 'Fries'), item(b1, 'Burger', 'burger', { tags: ['gf'] })] },
    '2026-10-10T09:00:00Z');
  const tagsOf = async () => (await lines(E)).map((l) => ({ [l.name]: l.tags }));
  assert.deepEqual(await tagsOf(), [{ Fries: [] }, { Burger: ['gf'] }]);

  const b2 = 'Burger and fries, both 4';
  await as(U.bob, () => db.query(`update public.entries set body = $2 where id = $1`, [E, b2]));
  await w.sortAs(E, P.marion, [item(b2, 'Burger', 'Burger'), item(b2, 'Fries', 'fries')]);
  assert.deepEqual(await tagsOf(), [{ Burger: ['gf'] }, { Fries: [] }], 'a name match beats an earlier evidence match');

  // a renamed dish matched only by evidence passes over the line another item names outright
  const b3 = 'Chips and burger, both 4';
  await as(U.bob, () => db.query(`update public.entries set body = $2 where id = $1`, [E, b3]));
  await w.sortAs(E, P.marion, [item(b3, 'Chips', 'Chips'), item(b3, 'Burger', 'burger')]);
  assert.deepEqual(await tagsOf(), [{ Chips: [] }, { Burger: ['gf'] }]);
});
