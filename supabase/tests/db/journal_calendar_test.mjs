// supabase/tests/db/journal_calendar_test.mjs — the Journal's calendar and live count (0053):
// journal_days (one row per local day holding my entries: count, best score, cover) and
// my_entries_count (exactly how many rows my_entries pages out, for the same filters).
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world, U, P, receipt, photoUrl } from './fixtures.mjs';

let w, db, as, rows, error;

before(async () => {
  w = await world();
  ({ db, as, rows, error } = w);
  // Alice: five visits over three Melbourne days, one of them just after local midnight.
  await w.visit(1, U.alice, P.tipo, receipt(['Gnocchi', 4.5], ['Tiramisu', 6]), '2026-09-01T02:00:00Z', { photos: ['a/1.jpg'] });
  await w.visit(2, U.alice, P.marion, receipt(['Anchovy toast', 3, { tags: ['df'] }]), '2026-09-01T09:00:00Z', { photos: ['a/2.jpg', 'a/2b.jpg'] });
  await w.visit(3, U.alice, P.osteria, receipt(['Ragu']), '2026-09-01T15:30:00Z'); //  2 Sep 01:30 in Melbourne
  await w.visit(4, U.alice, P.far, receipt(['Pad thai', 2]), '2026-09-05T03:00:00Z', { photos: ['a/4.jpg'] });
  await w.visit(5, U.alice, P.tipo, receipt(['Gnocchi', 5]), '2026-09-05T08:00:00Z');
  // Someone else's visit on the same days is never in my calendar.
  await w.visit(6, U.bob, P.tipo, receipt(['Gnocchi', 1]), '2026-09-01T03:00:00Z', { photos: ['b/6.jpg'] });
});
after(async () => db?.close());

const days = (uid, args = '') => as(uid, () => rows(
  `select day::text, entries, best_score::float as best, cover_url from public.journal_days(${args || `p_from => '2026-08-01', p_to => '2026-09-30'`})`));

test('journal_days: one row per local day with my entries — count, best score (a 6 is 6), newest cover', async () => {
  assert.deepEqual(await days(U.alice), [
    { day: '2026-09-01', entries: 2, best: 6, cover_url: photoUrl('a/2.jpg') },
    { day: '2026-09-02', entries: 1, best: null, cover_url: null },
    { day: '2026-09-05', entries: 2, best: 5, cover_url: photoUrl('a/4.jpg') },
  ], 'the 15:30Z visit is 2 Sep in Melbourne; the cover is the newest entry WITH a photo, its first photo');
  assert.deepEqual((await days(U.bob)).map((d) => [d.day, d.entries]), [['2026-09-01', 1]], 'only my own');
});

test('journal_days: the window is inclusive local days, in the zone asked', async () => {
  assert.deepEqual((await days(U.alice, `p_from => '2026-09-02', p_to => '2026-09-02'`)).map((d) => d.day), ['2026-09-02']);
  assert.deepEqual((await days(U.alice, `p_from => '2026-09-01', p_to => '2026-09-01', p_tz => 'UTC'`)).map((d) => [d.day, d.entries]),
    [['2026-09-01', 3]], 'in UTC all three 1 Sep visits are one day');
  assert.deepEqual((await days(U.alice, `p_from => null, p_to => '2026-09-01'`)).map((d) => d.day), ['2026-09-01'], 'open start');
  assert.deepEqual(await days(U.alice, `p_from => '2027-01-01', p_to => '2027-01-31'`), []);
});

test('journal_days: my_entries\' filters narrow the calendar the same way (month dividers under a filter)', async () => {
  const f = (args) => days(U.alice, `p_from => '2026-09-01', p_to => '2026-09-30', ${args}`);
  assert.deepEqual((await f(`p_min_score => 4.5`)).map((d) => [d.day, d.entries]), [['2026-09-01', 1], ['2026-09-05', 1]]);
  assert.deepEqual((await f(`p_tag => 'DF'`)).map((d) => [d.day, d.entries]), [['2026-09-01', 1]]);
  assert.deepEqual((await f(`p_city => 'geelong'`)).map((d) => [d.day, d.entries]), [['2026-09-05', 1]]);
  assert.deepEqual((await f(`p_restaurant_id => '${P.tipo}'`)).map((d) => [d.day, d.entries]), [['2026-09-01', 1], ['2026-09-05', 1]]);
});

test('my_entries_count: always the number of rows my_entries pages out, for every filter', async () => {
  const combos = [
    {},
    { p_min_score: 4 },
    { p_min_score: 6 },
    { p_max_score: 4 },
    { p_min_score: 3, p_max_score: 5 },
    { p_city: 'melbourne' },
    { p_city: 'nowhere' },
    { p_tag: 'df' },
    { p_from: '2026-09-02', p_to: '2026-09-05' },
    { p_from: '2026-09-01', p_to: '2026-09-01', p_tz: 'UTC' },
    { p_restaurant_id: P.tipo, p_min_score: 5 },
  ];
  for (const c of combos) {
    const named = Object.keys(c).map((k, i) => `${k} => $${i + 1}`).join(', ');
    const vals = Object.values(c);
    const listed = await w.walk((last) => as(U.alice, () => rows(
      `select id, created_at, best_score from public.my_entries(${[named, `p_limit => 2`,
        `p_cursor_created_at => $${vals.length + 1}`, `p_cursor_id => $${vals.length + 2}`].filter(Boolean).join(', ')})`,
      [...vals, last?.created_at ?? null, last?.id ?? null])));
    const [{ n }] = await as(U.alice, () => rows(`select public.my_entries_count(${named}) n`, vals));
    assert.equal(n, listed.length, JSON.stringify(c));
    // journal_days has no default for its window: pass it open when the combo has none.
    const window = 'p_from' in c ? '' : `p_from => null, p_to => null${named ? ', ' : ''}`;
    const [{ total }] = await as(U.alice, () => rows(
      `select coalesce(sum(entries), 0)::int total from public.journal_days(${window}${named})`, vals));
    assert.equal(total, n, `the calendar sums to the count: ${JSON.stringify(c)}`);
  }
  const [{ n }] = await as(U.bob, () => rows(`select public.my_entries_count() n`));
  assert.equal(n, 1, 'mine only');
});

test('journal_days and my_entries_count: signed-in only', async () => {
  assert.equal((await as(null, () => error(db.query(`select * from public.journal_days('2026-09-01', '2026-09-30')`))))?.code, '42501');
  assert.equal((await as(null, () => error(db.query(`select public.my_entries_count()`))))?.code, '42501');
});
