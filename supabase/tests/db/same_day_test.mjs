// supabase/tests/db/same_day_test.mjs — one place, one day, one entry (0103, 0104): a tag answered by
// someone who already posted there that day goes into their entry; the composer's same-day lookup; the
// one-off fold of entries already posted twice.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt, photoUrl } from './fixtures.mjs';

let w, db, as, asService, rows, error;

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
});
after(async () => db?.close());

const tag = async (tagger, entry, who) =>
  (await as(tagger, () => rows(`select * from public.tag_ate_with($1, $2)`, [entry, who])))[0];
const prefill = async (uid, companion) =>
  (await as(uid, () => rows(`select public.ate_with_prefill($1) p`, [companion])))[0].p;
const respond = async (uid, companion, entry, items, body = '') =>
  (await as(uid, () => rows(
    `select * from public.respond_ate_with(p_companion_id => $1, p_entry_id => $2, p_items => $3::jsonb, p_body => $4)`,
    [companion, entry, JSON.stringify(items), body])))[0];
const lines = async (entryId) =>
  (await rows(`select d.name, r.score::float as score, r.entry_position as pos from public.reviews r
               join public.dishes d on d.id = r.dish_id where r.entry_id = $1 order by r.entry_position`, [entryId]))
    .map((x) => [x.name, x.score]);
const entryCount = async (author, place) =>
  (await rows(`select count(*)::int n from public.entries where author_id = $1 and restaurant_id = $2`, [author, place]))[0].n;
const sameDay = async (uid, place, at) =>
  as(uid, () => rows(`select id from public.my_same_day_entry($1, $2)`, [place, at]));

test('a tag at a place you already posted that day goes into that entry', async () => {
  // Bob had lunch at Tipo 00 (Melbourne 1 Oct, 12:00 = 02:00Z) and posted two dishes.
  const mine = await w.visit(10, U.bob, P.tipo, receipt(['Gnocchi', 4], ['Tiramisu', 3.5]), '2026-10-01T02:00:00Z',
    { photos: ['b/10-mine.jpg'] });
  // Alice posted the same lunch with four, and tags Bob.
  const hers = await w.visit(11, U.alice, P.tipo,
    receipt(['Gnocchi', 4.5], ['Tiramisu', 4], ['Prawn Spaghetti', 4.5], ['Burrata', 4]), '2026-10-01T02:30:00Z',
    { photos: ['a/11-prawns.jpg', 'a/11-room.jpg'] });
  const prawns = (await rows(`select id from public.reviews where entry_id = $1 and entry_position = 3`, [hers]))[0].id;
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb, true)`, [hers, JSON.stringify([
    { review_id: prawns, photo_url: photoUrl('a/11-prawns.jpg') },
  ])]));
  const c = await tag(U.alice, hers, U.bob);

  const p = await prefill(U.bob, c.companion_id);
  assert.equal(p.my_entry_id, mine, 'the prefill names his entry that day');
  const byName = Object.fromEntries(p.dishes.map((d) => [d.dish_name, d.dish_id]));
  assert.deepEqual([...p.my_dish_ids].sort(), [byName.Gnocchi, byName.Tiramisu].sort(), 'and the dishes already on it');

  // An older build still sends every dish: the ones he has are skipped, the new ones join his receipt.
  const card = await respond(U.bob, c.companion_id, id(12), [
    { dish_id: byName.Gnocchi, score: 5 }, { dish_id: byName['Prawn Spaghetti'], score: 4.5 }, { dish_id: byName.Burrata },
  ], 'Prawns were the best');
  assert.equal(card.id, mine, 'the returned card is his same-day entry');
  assert.deepEqual(await lines(mine),
    [['Gnocchi', 4], ['Tiramisu', 3.5], ['Prawn Spaghetti', 4.5], ['Burrata', null]], 'his scores kept, new under them');
  assert.equal(card.body, 'Gnocchi 4. Tiramisu 3.5\n\nPrawns were the best', 'his words, then the new ones');
  assert.deepEqual(card.photos.map((x) => [x.url.split('/review-photos/')[1], x.position]),
    [['b/10-mine.jpg', 0], ['a/11-prawns.jpg', 1]], 'only the photo of a dish he added comes, after his');
  assert.equal(await entryCount(U.bob, P.tipo), 1, 'no second entry');
  assert.deepEqual(card.companions.map((x) => x.username), ['alice'], 'with @alice');

  // A retry with the same id returns the same card.
  const again = await respond(U.bob, c.companion_id, id(12), [], '');
  assert.equal(again.id, mine);
});

test('with every dish already scored, an empty answer links the two', async () => {
  const mine = await w.visit(20, U.cleo, P.marion, receipt(['Anchovies', 4]), '2026-10-02T09:00:00Z');
  const his = await w.visit(21, U.dan, P.marion, receipt(['Anchovies', 3]), '2026-10-02T10:00:00Z');
  const c = await tag(U.dan, his, U.cleo);
  const p = await prefill(U.cleo, c.companion_id);
  assert.equal(p.my_dish_ids.length, p.dishes.length, 'everything is already hers');
  const card = await respond(U.cleo, c.companion_id, id(22), []);
  assert.equal(card.id, mine);
  assert.deepEqual(await lines(mine), [['Anchovies', 4]]);
  assert.deepEqual(card.companions.map((x) => x.username), ['dan']);
});

test('two people tag you at one dinner: one entry answers both', async () => {
  const mine = await w.visit(30, U.dan, P.osteria, receipt(['Carbonara', 4]), '2026-10-03T09:00:00Z');
  const a = await w.visit(31, U.alice, P.osteria, receipt(['Carbonara', 4], ['Cannoli', 5]), '2026-10-03T09:30:00Z');
  const b = await w.visit(32, U.bob, P.osteria, receipt(['Negroni', 4]), '2026-10-03T09:40:00Z');
  const ca = await tag(U.alice, a, U.dan);
  const cb = await tag(U.bob, b, U.dan);
  const pa = await prefill(U.dan, ca.companion_id);
  await respond(U.dan, ca.companion_id, id(33), [{ dish_id: pa.dishes.find((d) => d.dish_name === 'Cannoli').dish_id, score: 4.5 }]);
  const pb = await prefill(U.dan, cb.companion_id);
  const card = await respond(U.dan, cb.companion_id, id(34), [{ dish_id: pb.dishes[0].dish_id, score: 3.5 }]);
  assert.equal(card.id, mine);
  assert.deepEqual(await lines(mine), [['Carbonara', 4], ['Cannoli', 4.5], ['Negroni', 3.5]]);
  assert.deepEqual(card.companions.map((x) => x.username).sort(), ['alice', 'bob'], 'with both, each once');
});

test('no entry that day: a new entry, as before; another day is another entry', async () => {
  await w.visit(40, U.cleo, P.tipo, receipt(['Gnocchi', 4]), '2026-10-04T02:00:00Z');
  // Melbourne 6 Oct is a different day from 5 Oct, though both are 5 Oct in UTC.
  const hers = await w.visit(41, U.alice, P.tipo, receipt(['Gnocchi', 4]), '2026-10-05T14:30:00Z');
  const c = await tag(U.alice, hers, U.cleo);
  const p = await prefill(U.cleo, c.companion_id);
  assert.equal(p.my_entry_id, null);
  assert.deepEqual(p.my_dish_ids, []);
  const card = await respond(U.cleo, c.companion_id, id(42), [{ dish_id: p.dishes[0].dish_id, score: 3 }]);
  assert.equal(card.id, id(42));
});

test('my_same_day_entry: the caller\'s first entry there that Melbourne day, never someone else\'s', async () => {
  const first = await w.visit(50, U.bob, P.marion, receipt(['Oysters', 4]), '2026-10-07T01:00:00Z');   // 12:00 Melb
  assert.deepEqual((await sameDay(U.bob, P.marion, '2026-10-07T12:00:00Z')).map((x) => x.id), [first], '23:00 Melb');
  assert.deepEqual(await sameDay(U.bob, P.marion, '2026-10-07T13:30:00Z'), [], 'past midnight in Melbourne');
  assert.deepEqual(await sameDay(U.bob, P.tipo, '2026-10-07T01:00:00Z'), [], 'another place');
  assert.deepEqual(await sameDay(U.alice, P.marion, '2026-10-07T01:00:00Z'), [], 'another person');
  const [g] = await rows(`select has_function_privilege('anon', 'public.my_same_day_entry(uuid, timestamptz)', 'execute') a`);
  assert.equal(g.a, false, 'anon may not call it');
});

test('fold: a second post the same day becomes part of the first', async () => {
  const into = await w.visit(60, U.alice, P.marion, receipt(['Oysters', 4], ['Bread', 3]), '2026-10-08T02:00:00Z',
    { photos: ['a/60-oysters.jpg'] });
  const from = await w.visit(61, U.alice, P.marion, receipt(['Bread', 4.5], ['Cannoli', 5]), '2026-10-08T06:00:00Z',
    { photos: ['a/61-cannoli.jpg', 'a/60-oysters.jpg'] });
  const cannoli = (await rows(`select r.id from public.reviews r join public.dishes d on d.id = r.dish_id
                               where r.entry_id = $1 and d.name = 'Cannoli'`, [from]))[0].id;
  await asService(() => db.query(`select public.apply_photo_matches($1, $2::jsonb, true)`, [from, JSON.stringify([
    { review_id: cannoli, photo_url: photoUrl('a/61-cannoli.jpg') },
  ])]));
  const c = await tag(U.alice, from, U.cleo);
  await as(U.bob, () => db.query(`insert into public.saves (user_id, dish_id, source_entry_id)
                                 select $1, dish_id, entry_id from public.reviews where id = $2`, [U.bob, cannoli]));

  const [{ ok }] = await asService(() => rows(`select public.fold_same_day_entry($1, $2) ok`, [from, into]));
  assert.equal(ok, true);
  assert.deepEqual(await lines(into), [['Oysters', 4], ['Bread', 4.5], ['Cannoli', 5]], 'the later score replaces');
  const [e] = await rows(`select body from public.entries where id = $1`, [into]);
  assert.equal(e.body, 'Oysters 4. Bread 3\n\nBread 4.5. Cannoli 5');
  // The moved line's offsets still point at its words.
  const [m] = await rows(`select mention_offset, evidence_offset, score_evidence from public.reviews
                          where id = $1`, [cannoli]);
  assert.equal([...e.body].slice(m.mention_offset, m.mention_offset + 'Cannoli'.length).join(''), 'Cannoli');
  assert.equal([...e.body].slice(m.evidence_offset, m.evidence_offset + m.score_evidence.length).join(''), m.score_evidence);
  const [bread] = await rows(`select r.evidence_offset, r.score_evidence from public.reviews r join public.dishes d
                              on d.id = r.dish_id where r.entry_id = $1 and d.name = 'Bread'`, [into]);
  assert.equal([...e.body].slice(bread.evidence_offset, bread.evidence_offset + bread.score_evidence.length).join(''),
    'Bread 4.5', 'the replacing score carries its own words');
  assert.deepEqual((await rows(`select photo_url, position from public.entry_photos where entry_id = $1 order by position`, [into]))
    .map((x) => [x.photo_url.split('/review-photos/')[1], x.position]),
    [['a/60-oysters.jpg', 0], ['a/61-cannoli.jpg', 1]], 'each photo once, after the first entry\'s');
  assert.equal((await rows(`select count(*)::int n from public.photo_dishes where entry_id = $1 and review_id = $2`,
    [into, cannoli]))[0].n, 1, 'the pairing came along');
  assert.equal((await rows(`select entry_id from public.entry_companions where id = $1`, [c.companion_id]))[0].entry_id, into);
  assert.equal((await rows(`select source_entry_id from public.saves where user_id = $1`, [U.bob]))[0].source_entry_id, into);
  assert.equal((await rows(`select count(*)::int n from public.entries where id = $1`, [from]))[0].n, 0, 'the second is gone');
});

test('fold refuses what would overflow, and anyone but the service', async () => {
  const photos = (n, k) => Array.from({ length: k }, (_, i) => `b/${n}-${i}.jpg`);
  const into = await w.visit(70, U.bob, P.osteria, receipt(['Carbonara', 4]), '2026-10-09T02:00:00Z', { photos: photos(70, 20) });
  const from = await w.visit(71, U.bob, P.osteria, receipt(['Cannoli', 4]), '2026-10-09T04:00:00Z', { photos: photos(71, 5) });
  const [{ ok }] = await asService(() => rows(`select public.fold_same_day_entry($1, $2) ok`, [from, into]));
  assert.equal(ok, false, '25 photos would not fit');
  assert.equal((await rows(`select count(*)::int n from public.entries where id in ($1, $2)`, [from, into]))[0].n, 2, 'both kept');
  const denied = await as(U.bob, () => error(db.query(`select public.fold_same_day_entry($1, $2)`, [from, into])));
  assert.equal(denied?.code, '42501');
});
