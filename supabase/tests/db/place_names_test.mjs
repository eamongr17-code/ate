// supabase/tests/db/place_names_test.mjs — 0075: a Google place is stored under its name, not the
// keywords padded onto its listing; the raw listing name is kept in google_name. Manual rows untouched.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world } from './fixtures.mjs';

let w, db, rows;

before(async () => {
  w = await world();
  ({ db, rows } = w);
});
after(async () => db?.close());

const clean = async (raw) => (await rows(`select public.clean_place_name($1) as n`, [raw]))[0].n;
const place = async (gid) =>
  (await rows(`select name, google_name from public.restaurants where google_place_id = $1`, [gid]))[0];
const upsert = (gid, name) =>
  db.query(
    `insert into public.restaurants (google_place_id, name, city, source) values ($1, $2, 'Bangkok', 'places')
     on conflict (google_place_id) where google_place_id is not null do update set name = excluded.name`,
    [gid, name],
  );

// The same cases as functions/places-search/name_test.ts: the two copies of the rule must agree.
test('0075: clean_place_name matches name.ts', async () => {
  const cases = [
    ['VIVIN Suk 22 - café grocery bistro - Local Organic Natural Artisan', 'VIVIN Suk 22'],
    ['Chin Chin | Modern Thai Restaurant Melbourne', 'Chin Chin'],
    ['Mamasita – Mexican Cantina', 'Mamasita'],
    ['Lune — Croissanterie · Fitzroy', 'Lune'],
    ['Pho Hung (Vietnamese Restaurant)', 'Pho Hung'],
    ['Bar Liberty [Fitzroy]', 'Bar Liberty'],
    ['Cafe Bliss|Brunch|Coffee', 'Cafe Bliss'],
    ['Ka-Pow', 'Ka-Pow'],
    ['Tipo 00', 'Tipo 00'],
    ['Cutler & Co', 'Cutler & Co'],
    ['Bread, Wine & Cheese', 'Bread, Wine & Cheese'],
    ['  Small   Wins ', 'Small Wins'],
    ['A - Restaurant', 'A - Restaurant'],
    ['(Untitled)', '(Untitled)'],
  ];
  for (const [raw, want] of cases) assert.equal(await clean(raw), want, raw);
});

test('0075: a Google upsert stores the clean name and keeps the listing in google_name', async () => {
  const raw = 'VIVIN Suk 22 - café grocery bistro - Local Organic Natural Artisan';
  await upsert('g-vivin', raw);
  assert.deepEqual(await place('g-vivin'), { name: 'VIVIN Suk 22', google_name: raw });

  // places-search re-sends the raw name on every pick: still clean, listing still kept.
  await upsert('g-vivin', raw);
  assert.deepEqual(await place('g-vivin'), { name: 'VIVIN Suk 22', google_name: raw });

  // Google renames the place to a clean name: the old listing is no longer held.
  await upsert('g-vivin', 'VIVIN Cafe');
  assert.deepEqual(await place('g-vivin'), { name: 'VIVIN Cafe', google_name: null });

  await upsert('g-plain', 'Tipo 00');
  assert.deepEqual(await place('g-plain'), { name: 'Tipo 00', google_name: null });
});

test('0075: a name typed by hand is never rewritten', async () => {
  const [{ id }] = await rows(
    `insert into public.restaurants (name, city, source) values ('Joe - The Original', 'Melbourne', 'manual') returning id`,
  );
  const [row] = await rows(`select name, google_name from public.restaurants where id = $1`, [id]);
  assert.deepEqual(row, { name: 'Joe - The Original', google_name: null });
});
