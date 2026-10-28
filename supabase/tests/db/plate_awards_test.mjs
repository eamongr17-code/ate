// supabase/tests/db/plate_awards_test.mjs — plate awards (0098): each award is earned by the write that
// earns it, once, and never taken away; awards_of / mark_awards_seen / award_lines are the only way in;
// blocks, deactivation and signing out hide them; a failing check never fails the write.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, id, receipt } from './fixtures.mjs';

let w, db, as, asService, rows, error;

// Extra people, one per rule, so each test starts from nothing.
const X = Object.fromEntries(
  ['count', 'scores', 'one', 'day', 'place', 'same', 'style', 'country', 'tagger', 'tagged', 'saved', 'quiet', 'gone']
    .map((k, i) => [k, id(9800 + i)]));
const ROMA = id(9890);

before(async () => {
  w = await world();
  ({ db, as, asService, rows, error } = w);
  for (const [k, uid] of Object.entries(X)) {
    await db.query(`insert into auth.users (id, email) values ($1, $2)`, [uid, `award-${k}@ate.test`]);
  }
  await db.query(
    `insert into public.restaurants (id, name, address, city, source) values ($1, 'Roscioli', 'Via dei Giubbonari 21, 00186 Roma RM, Italy', 'Rome', 'manual')`,
    [ROMA]);
});
after(async () => db?.close());

const held = async (uid) =>
  (await rows(`select award from public.user_awards where user_id = $1 order by award`, [uid])).map((r) => r.award);
const award = async (uid, a) =>
  (await rows(`select * from public.user_awards where user_id = $1 and award = $2`, [uid, a]))[0];
const awardsOf = (viewer, uid = null) => as(viewer, () => rows(`select * from public.awards_of($1)`, [uid]));
const lines = (viewer, uid, a, last = null, limit = 60) => as(viewer, () => rows(
  `select * from public.award_lines($1, $2, $3, $4, $5)`, [uid, a, last?.created_at ?? null, last?.review_id ?? null, limit]));
const at = (day, h = 9) => `2026-09-${String(day).padStart(2, '0')}T${String(h).padStart(2, '0')}:00:00Z`;

// ---------------------------------------------------------------------------------------------------
test('dishes logged: the 1st and the 10th line, dated by that line; award_lines walks the first 10', async () => {
  const u = X.count;
  await w.visit(9001, u, P.tipo, receipt(['Gnocchi', 4]), at(1));
  assert.deepEqual(await held(u), ['dishes_1']);
  const names = ['Focaccia', 'Burrata', 'Tiramisu', 'Cacio e Pepe', 'Arancini', 'Negroni', 'Panna Cotta', 'Lasagne', 'Olives'];
  await w.visit(9002, u, P.marion, receipt(...names.slice(0, 4).map((n) => [n])), at(2));
  await w.visit(9003, u, P.osteria, receipt(...names.slice(4).map((n) => [n])), at(3));
  await w.visit(9004, u, P.osteria, receipt(['Bread']), at(4));
  assert.ok((await held(u)).includes('dishes_10'));
  assert.ok(!(await held(u)).includes('dishes_25'));

  const ten = await award(u, 'dishes_10');
  assert.equal(ten.entry_id, id(9003), 'the 10th line is in the third entry');
  assert.equal(new Date(ten.earned_at).toISOString(), new Date(at(3)).toISOString(), 'dated by the line, not today');

  const all = await w.walk((last) => lines(u, null, 'dishes_10', last, 4));
  assert.equal(all.length, 10, 'exactly the first ten, across pages');
  assert.equal(all[0].dish_name, 'Gnocchi');
  assert.equal(all.at(-1).restaurant_name, 'Osteria Ilaria');
  assert.equal(new Set(all.map((r) => r.review_id)).size, 10, 'no repeats across pages');
  assert.equal((await lines(U.alice, u, 'dishes_10')).length, 10, 'others can open it too');
  assert.equal((await lines(U.alice, u, 'dishes_25')).length, 0, 'an award they do not hold opens nothing');
});

test('scores you gave: the first 5.0, 6 and 0.5', async () => {
  const u = X.scores;
  await w.visit(9011, u, P.tipo, receipt(['Gnocchi', 4.5]), at(5));
  assert.deepEqual(await held(u), ['dishes_1']);
  await w.visit(9012, u, P.tipo, receipt(['Steak', 5], ['Burrata', 0.5]), at(6));
  await w.visit(9013, u, P.marion, receipt(['Risotto', 6]), at(7));
  assert.deepEqual(await held(u), ['dishes_1', 'first_5', 'first_6', 'first_half']);
  assert.equal((await award(u, 'first_6')).entry_id, id(9013));
  const six = (await awardsOf(u)).find((a) => a.award === 'first_6');
  assert.deepEqual([six.dish_name, six.restaurant_name, Number(six.score)], ['Risotto', 'Marion', 6], 'what the takeover prints');
  assert.ok((await award(u, 'first_5')).dish_id, 'the dish that earned it');
});

test('five dishes in one entry, three entries in one Melbourne day, five dishes at one place', async () => {
  await w.visit(9021, X.one, P.tipo, receipt(['A1'], ['A2'], ['A3'], ['A4']), at(8));
  assert.ok(!(await held(X.one)).includes('five_in_entry'));
  await w.visit(9022, X.one, P.tipo, receipt(['B1'], ['B2'], ['B3'], ['B4'], ['B5']), at(9));
  assert.equal((await award(X.one, 'five_in_entry')).entry_id, id(9022));
  assert.equal((await lines(X.one, null, 'five_in_entry')).length, 5);
  assert.ok((await held(X.one)).includes('five_at_place'), '9 dishes at Tipo');
  const place = await award(X.one, 'five_at_place');
  assert.equal(place.dish_ids.length, 5);
  assert.equal((await lines(X.one, null, 'five_at_place')).length, 5);

  // 13:00 and 23:00 UTC on the 10th are the 10th and the 11th in Melbourne: not one day.
  await w.visit(9031, X.day, P.tipo, receipt(['Coffee']), '2026-09-10T01:00:00Z');
  await w.visit(9032, X.day, P.marion, receipt(['Toast']), '2026-09-10T05:00:00Z');
  await w.visit(9033, X.day, P.osteria, receipt(['Gelato']), '2026-09-10T15:00:00Z');
  assert.ok(!(await held(X.day)).includes('three_in_day'), 'the third is the next Melbourne day');
  await w.visit(9034, X.day, P.far, receipt(['Pad Thai']), '2026-09-10T08:00:00Z');
  const day = await award(X.day, 'three_in_day');
  assert.deepEqual(day.entry_ids, [id(9031), id(9032), id(9034)]);
  assert.equal(day.entry_id, id(9034));
});

test('the same dish three times; first drink and first dessert, including a style that lands later', async () => {
  for (const n of [9041, 9042, 9043]) await w.visit(n, X.same, P.osteria, receipt(['Ragù']), at(n - 9030));
  const same = await award(X.same, 'same_dish_3');
  assert.ok(same, 'earned on the third');
  assert.deepEqual(same.entry_ids, [id(9041), id(9042), id(9043)]);
  assert.equal((await lines(X.same, null, 'same_dish_3')).length, 3);

  await w.visit(9051, X.style, P.marion, receipt(['House Special'], ['Nonna Plate']), at(20));
  assert.ok(!(await held(X.style)).includes('first_drink'), 'no style guessed from these names');
  const dish = async (name) => (await rows(
    `select rv.dish_id from public.reviews rv join public.dishes d on d.id = rv.dish_id where rv.entry_id = $1 and d.name = $2`,
    [id(9051), name]))[0].dish_id;
  await db.query(`delete from public.dish_tag_links where dish_id = any($1::uuid[]) and kind = 'style'`,
    [[await dish('House Special'), await dish('Nonna Plate')]]);
  await db.query(`insert into public.dish_tag_links (dish_id, kind, slug, label, source) values
    ($1, 'style', 'drinks', 'drinks', 'sorter'), ($2, 'style', 'dessert', 'dessert', 'sorter')`,
    [await dish('House Special'), await dish('Nonna Plate')]);
  assert.equal((await award(X.style, 'first_drink'))?.dish_id, await dish('House Special'));
  assert.equal((await award(X.style, 'first_dessert'))?.dish_id, await dish('Nonna Plate'));
});

test('a dish in a new country: a place with no country never counts', async () => {
  const u = X.country;
  await w.visit(9061, u, P.hand, receipt(['Toastie']), at(21));
  await w.visit(9062, u, P.tipo, receipt(['Gnocchi']), at(22));
  assert.ok(!(await held(u)).includes('new_country'));
  await w.visit(9063, u, ROMA, receipt(['Carbonara']), at(23));
  assert.equal((await award(u, 'new_country')).entry_id, id(9063));
  assert.equal((await rows(`select public.place_country($1) c`, ['53 Gertrude St, Fitzroy VIC 3065, Australia']))[0].c, 'australia');
  assert.equal((await rows(`select public.place_country($1) c`, ['Fitzroy VIC 3065']))[0].c, null);
});

test('ate with someone: the tagger at once, the person tagged when they accept', async () => {
  const E = await w.visit(9071, X.tagger, P.tipo, receipt(['Gnocchi', 4]), at(24));
  const [t] = await as(X.tagger, () => rows(`select * from public.tag_ate_with($1, $2)`, [E, X.tagged]));
  const mine = await award(X.tagger, 'ate_with');
  assert.equal(mine.other_user_id, X.tagged);
  assert.equal(mine.entry_id, E);
  assert.equal(await award(X.tagged, 'ate_with'), undefined, 'pending earns the tagged person nothing');

  const gnocchi = (await rows(`select dish_id from public.reviews where entry_id = $1`, [E]))[0].dish_id;
  await as(X.tagged, () => rows(
    `select * from public.respond_ate_with(p_companion_id => $1, p_entry_id => $2, p_items => $3::jsonb, p_body => '')`,
    [t.companion_id, id(9072), JSON.stringify([{ dish_id: gnocchi, score: 4 }])]));
  const theirs = await award(X.tagged, 'ate_with');
  assert.equal(theirs.other_user_id, X.tagger);
  assert.equal(theirs.entry_id, id(9072), 'their own entry');

  assert.ok((await awardsOf(X.tagged)).some((a) => a.award === 'ate_with' && a.other_handle), 'with the other handle');
});

test('saved by someone, then 10 saves from your entries; your own saves never count', async () => {
  const E = await w.visit(9081, X.saved, P.tipo, receipt(['S1'], ['S2'], ['S3'], ['S4']), at(25));
  const dishes = (await rows(`select dish_id from public.reviews where entry_id = $1 order by entry_position`, [E])).map((r) => r.dish_id);
  await as(X.saved, () => db.query(`select public.save_dish($1, $2)`, [dishes[0], E]));
  assert.ok(!(await held(X.saved)).includes('saved_by_someone'), 'saving your own dish is not being saved');

  await as(U.alice, () => db.query(`select public.save_dish($1, $2)`, [dishes[0], E]));
  const first = await award(X.saved, 'saved_by_someone');
  assert.equal(first.other_user_id, U.alice);
  assert.deepEqual(first.dish_ids, [dishes[0]]);
  assert.ok(!(await held(X.saved)).includes('saves_10'));

  for (const who of [U.alice, U.bob, U.cleo]) {
    for (const d of dishes) await as(who, () => db.query(`select public.save_dish($1, $2)`, [d, E]));
  }
  const ten = await award(X.saved, 'saves_10');
  assert.ok(ten, '12 saves made');
  assert.deepEqual([...ten.dish_ids].sort(), [...dishes].sort());
  assert.equal((await lines(X.saved, null, 'saves_10')).length, 4, 'one line per dish');
});

test('never taken away: deleting the entry keeps the award; the check is idempotent; backfill re-dates', async () => {
  const u = X.gone;
  const E = await w.visit(9091, u, P.tipo, receipt(['Gnocchi', 5]), at(26));
  assert.deepEqual(await held(u), ['dishes_1', 'first_5']);
  await as(u, () => db.query(`delete from public.entries where id = $1`, [E]));
  assert.deepEqual(await held(u), ['dishes_1', 'first_5'], 'kept');
  assert.equal((await award(u, 'first_5')).entry_id, null, 'the link goes, the award stays');

  assert.equal((await rows(`select public.award_check($1) n`, [U.alice]))[0].n, 0, 'nothing new on a re-check');
  const before = (await award(X.count, 'dishes_10')).earned_at;
  await db.query(`delete from public.user_awards where user_id = $1`, [X.count]);
  await db.query(`select public.award_check_quiet($1)`, [X.count]);
  assert.ok((await held(X.count)).includes('dishes_10'), 'a backfill earns it again');
  assert.equal((await award(X.count, 'dishes_10')).earned_at.toISOString(), before.toISOString(), 'with the same date');
});

test('a check that fails never fails the write that fired it', async () => {
  const [{ def }] = await rows(`select pg_get_functiondef('public.award_check(uuid)'::regprocedure) def`);
  await db.exec(`create or replace function public.award_check(p_user uuid) returns int language plpgsql as $$
    begin raise exception 'boom'; end; $$;`);
  try {
    const E = await w.visit(9095, X.quiet, P.tipo, receipt(['Gnocchi', 5]), at(27));
    assert.equal((await rows(`select count(*)::int n from public.reviews where entry_id = $1`, [E]))[0].n, 1, 'the line landed');
    assert.deepEqual(await held(X.quiet), []);
  } finally {
    await db.exec(def);
  }
  await db.query(`select public.award_check_quiet($1)`, [X.quiet]);
  assert.deepEqual(await held(X.quiet), ['dishes_1', 'first_5'], 'and the next check catches up');
});

test('reads: your own with seen; others always seen; blocks, deactivation and signed out hide them', async () => {
  const u = X.scores;
  const mine = await awardsOf(u);
  assert.equal(mine.length, 4);
  assert.ok(mine.every((a) => a.seen === false), 'unseen until the takeover shows them');
  assert.deepEqual(mine.map((a) => a.award).slice(0, 1), ['first_6'], 'newest first');

  assert.equal((await as(u, () => rows(`select public.mark_awards_seen($1) n`, [['first_5']])))[0].n, 1);
  assert.equal((await awardsOf(u)).filter((a) => a.seen).length, 1);
  assert.equal((await as(U.alice, () => rows(`select public.mark_awards_seen() n`)))[0].n, 0, 'marks only your own');
  assert.equal((await awardsOf(u)).filter((a) => a.seen).length, 1);
  assert.equal((await as(u, () => rows(`select public.mark_awards_seen() n`)))[0].n, 3);

  const theirs = await awardsOf(U.bob, X.count);
  assert.ok(theirs.length >= 2 && theirs.every((a) => a.seen), 'someone else\'s read as seen');
  assert.equal((await as(null, () => error(db.query(`select * from public.awards_of(null)`))))?.code, '42501', 'anon: no grant');

  await as(U.bob, () => db.query(`select public.block_user($1)`, [X.count]));
  assert.equal((await awardsOf(U.bob, X.count)).length, 0, 'through a block: nothing');
  assert.equal((await lines(U.bob, X.count, 'dishes_10')).length, 0, 'nor its lines');
  assert.ok((await awardsOf(X.count)).length >= 2, 'the blocked person still sees their own');
  await as(U.bob, () => db.query(`select public.unblock_user($1)`, [X.count]));

  await db.query(`update public.profiles set deleted_at = now() where id = $1`, [X.count]);
  assert.equal((await awardsOf(U.bob, X.count)).length, 0, 'deactivated: nothing');
  await db.query(`update public.profiles set deleted_at = null where id = $1`, [X.count]);
});

test('no client reads or writes the table; delete_account takes the awards with it', async () => {
  for (const sql of [
    `select * from public.user_awards`,
    `insert into public.user_awards (user_id, award, earned_at) values ('${U.alice}', 'dishes_500', now())`,
    `update public.user_awards set seen_at = now()`,
    `delete from public.user_awards`,
    `select public.award_check('${U.alice}')`,
    `select public.award_put('${U.alice}', 'dishes_500', now())`,
  ]) {
    assert.equal((await as(U.alice, () => error(db.query(sql))))?.code, '42501', `refused: ${sql.slice(0, 40)}`);
  }
  assert.ok((await held(X.gone)).length > 0);
  const out = (await as(X.gone, () => rows(`select public.delete_account() r`)))[0].r;
  assert.equal(out.ok, true);
  assert.deepEqual(await held(X.gone), []);
});
