// supabase/tests/db/round4_test.mjs — round 4 (0041–0043) at the SQL level: the secret 6, the Search
// filters, the Journal's filter and sort.
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { actors, boot } from './harness.mjs';

const A = '00000000-0000-4000-8000-00000000000a';
const B = '00000000-0000-4000-8000-00000000000b';
const R1 = '00000000-0000-4000-8000-0000000000f1'; // Tipo 00 — Italian, Melbourne CBD
const R2 = '00000000-0000-4000-8000-0000000000f2'; // Tipo Pasta Bar — "italian " typed by hand
const R3 = '00000000-0000-4000-8000-0000000000f3'; // Tipo Thai — Thai
const R4 = '00000000-0000-4000-8000-0000000000f4'; // Tipo Far — Thai, 30 km out
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const point = (lng, lat) => `extensions.ST_SetSRID(extensions.ST_MakePoint(${lng}, ${lat}), 4326)::geography`;

let db, as, asService, rows, error;

before(async () => {
  db = await boot();
  ({ as, asService, rows, error } = actors(db));
  await db.exec(`
    insert into auth.users (id, email) values ('${A}', 'alice@ate.test'), ('${B}', 'bob@ate.test');
    insert into public.restaurants (id, name, address, city, cuisine, source, location) values
      ('${R1}', 'Tipo 00', '361 Little Bourke St, Melbourne VIC 3000, Australia', 'Melbourne', 'Italian', 'manual', ${point(144.9631, -37.8136)}),
      ('${R2}', 'Tipo Pasta Bar', null, 'Carlton', 'italian ', 'manual', ${point(144.9671, -37.8000)}),
      ('${R3}', 'Tipo Thai', null, 'Fitzroy', 'Thai', 'manual', ${point(144.9780, -37.7990)}),
      ('${R4}', 'Tipo Far', null, 'Geelong', 'Thai', 'manual', ${point(144.3600, -38.1490)});
  `);
});
after(async () => db?.close());

const sortAs = (entryId, place, items) =>
  asService(() => db.query(
    `select public.apply_entry_sort(p_entry_id => $1, p_restaurant_id => $2, p_items => $3::jsonb, p_mode => 'stub')`,
    [entryId, place, JSON.stringify(items)],
  ));

/** An entry by `author` at `place`, `created_at` = `when`, sorted to `items`. */
async function visit(n, author, place, body, items, when) {
  await as(author, () => db.query(
    `insert into public.entries (id, author_id, body, restaurant_id, created_at) values ($1, $2, $3, $4, $5)`,
    [id(n), author, body, place, when],
  ));
  await sortAs(id(n), place, items);
  return id(n);
}

// ---------------------------------------------------------------------------------------------------
// 0041 — the secret 6
// ---------------------------------------------------------------------------------------------------
test('0041: the CHECK takes 0.5–5.0 in half steps and exactly 6; 5.5 and 6.5 stay illegal', async () => {
  const E = await visit(100, A, R1, 'Gnocchi 4.0', [{ dish_name: 'Gnocchi', score: 4, score_evidence: 'Gnocchi 4.0' }], '2026-09-01T09:00:00Z');
  const line = (await rows(`select id from public.reviews where entry_id = $1`, [E]))[0].id;
  assert.equal(await as(A, () => error(db.query(`update public.reviews set score = 6 where id = $1`, [line]))), null, 'the author may mark a 6');
  for (const bad of [5.5, 6.5, 7, 0]) {
    assert.equal((await as(A, () => error(db.query(`update public.reviews set score = $2 where id = $1`, [line, bad]))))?.code, '23514', `${bad}`);
  }
  assert.equal(await as(A, () => error(db.query(`update public.reviews set score = null where id = $1`, [line]))), null, 'NULL is still legal');
  await db.query(`delete from public.entries where id = $1`, [E]);
});

test('0041: apply_entry_sort keeps a 6 evidenced by a "6", drops one that is not, and still drops 5.5', async () => {
  const E = await visit(101, A, R1, 'Tiramisu 6 and the cannoli 4.5, bread five', [
    { dish_name: 'Tiramisu', score: 6, score_evidence: 'Tiramisu 6', evidence_offset: 0 },
    { dish_name: 'Cannoli', score: 6, score_evidence: 'cannoli 4.5' },
    { dish_name: 'Bread', score: 5.5, score_evidence: 'bread five' },
  ], '2026-09-02T09:00:00Z');
  const got = await rows(`select d.name, v.score::float s, v.score_evidence ev, v.evidence_offset off
    from public.reviews v join public.dishes d on d.id = v.dish_id where v.entry_id = $1 order by v.entry_position`, [E]);
  assert.deepEqual(got, [
    { name: 'Tiramisu', s: 6, ev: 'Tiramisu 6', off: 0 },
    { name: 'Cannoli', s: null, ev: null, off: null },
    { name: 'Bread', s: null, ev: null, off: null },
  ]);
});

test('0041: a 6 counts as 6 — dish average, place average, place_dishes rank, profile, histogram, dishes_by_score', async () => {
  // Bob gives the Tiramisu a 4. Alice (above) gave it a 6. Average 5.0 — not capped, not dropped.
  await visit(102, B, R1, 'Tiramisu 4 and Gnocchi 5', [
    { dish_name: 'Tiramisu', score: 4, score_evidence: 'Tiramisu 4' },
    { dish_name: 'Gnocchi', score: 5, score_evidence: 'Gnocchi 5' },
  ], '2026-09-03T09:00:00Z');
  const dish = await as(A, () => rows(`select d.name, s.score::float s, s.review_count n from public.dish_stats s
    join public.dishes d on d.id = s.dish_id where s.restaurant_id = $1 order by d.name`, [R1]));
  assert.deepEqual(dish.map((r) => [r.name, r.s]), [['Bread', null], ['Cannoli', null], ['Gnocchi', 5], ['Tiramisu', 5]]);

  const place = (await as(A, () => rows(`select avg_rating::float a from public.restaurant_stats where restaurant_id = $1`, [R1])))[0].a;
  assert.equal(place, 5, 'mean of per-dish averages (5, 5)');

  const ranked = await as(A, () => rows(`select dish_name, score::float s from public.place_dishes($1)`, [R1]));
  assert.deepEqual(ranked.slice(0, 2).map((r) => r.dish_name).sort(), ['Gnocchi', 'Tiramisu'], 'review_count still leads');

  const prof = (await as(A, () => rows(`select scored, avg_score::float a from public.profile_summary($1)`, [A])))[0];
  assert.deepEqual(prof, { scored: 1, a: 6 });

  const hist = await as(A, () => rows(`select score::float s, dish_count, review_count from public.score_histogram($1)`, [A]));
  assert.equal(hist.length, 11, 'ten half steps + the 6');
  assert.deepEqual(hist.map((r) => r.s), [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 6]);
  assert.deepEqual(hist.at(-1), { s: 6, dish_count: 1, review_count: 1 });
  assert.equal(hist.slice(0, 10).reduce((t, r) => t + r.review_count, 0), 0);

  const sixes = await as(A, () => rows(`select dish_name, score::float s from public.dishes_by_score($1, 6)`, [A]));
  assert.deepEqual(sixes, [{ dish_name: 'Tiramisu', s: 6 }]);

  const card = (await as(A, () => rows(`select avg_score::float a from public.entry_cards where id = $1`, [id(101)])))[0];
  assert.equal(card.a, 6);
});

// ---------------------------------------------------------------------------------------------------
// 0042 — search filters
// ---------------------------------------------------------------------------------------------------
test('0042: setup — tagged lines at three places', async () => {
  // R2: a GF+V pasta (both chips), R3: a GF curry and a separate V salad, R4 far away: a GF+V soup.
  await visit(110, B, R2, 'Tipo pasta 3.5 GF V', [{ dish_name: 'Tipo pasta', score: 3.5, score_evidence: 'Tipo pasta 3.5', tags: ['gf', 'v'] }], '2026-09-04T09:00:00Z');
  await visit(111, B, R3, 'Tipo curry 4.5 GF, salad 2 V', [
    { dish_name: 'Tipo curry', score: 4.5, score_evidence: 'Tipo curry 4.5', tags: ['gf'] },
    { dish_name: 'Salad', score: 2, score_evidence: 'salad 2', tags: ['v'] },
  ], '2026-09-05T09:00:00Z');
  await visit(112, B, R4, 'Tipo soup 4 GF V', [{ dish_name: 'Tipo soup', score: 4, score_evidence: 'Tipo soup 4', tags: ['gf', 'v'] }], '2026-09-06T09:00:00Z');
});

const places = (args = '') => as(A, () => rows(`select name, cuisine, avg_rating::float a from public.search_places(p_query => 'tipo'${args})`));

test('0042: search_places — no filter is today\'s result; each filter narrows; empty/blank lists are off', async () => {
  const all = await places();
  assert.deepEqual(all.map((r) => r.name).sort(), ['Tipo 00', 'Tipo Far', 'Tipo Pasta Bar', 'Tipo Thai']);
  assert.deepEqual(await places(`, p_cuisines => '{}', p_tags => '{" "}'`), all, 'empty and blank = no filter');

  assert.deepEqual((await places(`, p_cuisines => '{ITALIAN}'`)).map((r) => r.name).sort(), ['Tipo 00', 'Tipo Pasta Bar'],
    'case- and space-insensitive: "italian " matches ITALIAN');
  assert.deepEqual((await places(`, p_cuisines => '{Italian,thai}'`)).length, 4, 'any of the cuisines');

  assert.deepEqual((await places(`, p_tags => '{gf}'`)).map((r) => r.name).sort(), ['Tipo Far', 'Tipo Pasta Bar', 'Tipo Thai']);
  assert.deepEqual((await places(`, p_tags => '{GF,v}'`)).map((r) => r.name).sort(), ['Tipo Far', 'Tipo Pasta Bar'],
    'one dish must carry both — Tipo Thai has a GF dish and a V dish, not a GF+V one');
  assert.deepEqual(await places(`, p_tags => '{xx}'`), [], 'an unknown code matches nothing');

  assert.deepEqual((await places(`, p_min_score => 4`)).map((r) => [r.name, r.a]).sort(), [['Tipo 00', 5], ['Tipo Far', 4]]);
  assert.deepEqual((await places(`, p_cuisines => '{thai}', p_tags => '{gf}', p_min_score => 3`)).map((r) => r.name).sort(), ['Tipo Far', 'Tipo Thai']);
});

test('0042: search_places — paging with filters walks exactly the filtered set', async () => {
  const filters = `p_cuisines => '{thai,italian}', p_tags => '{gf}'`;
  const whole = await as(A, () => rows(`select * from public.search_places(p_query => 'tipo', ${filters})`));
  assert.equal(whole.length, 3);
  const walked = [];
  let last = null;
  for (let i = 0; i < 5; i++) {
    const page = await as(A, () => rows(`select * from public.search_places(p_query => 'tipo', p_limit => 1,
      p_cursor_match_tier => $1, p_cursor_review_count => $2, p_cursor_name => $3, p_cursor_id => $4, ${filters})`,
      [last?.match_tier ?? null, last?.review_count ?? null, last?.name ?? null, last?.restaurant_id ?? null]));
    if (!page.length) break;
    walked.push(...page);
    last = page.at(-1);
  }
  assert.deepEqual(walked, whole);
});

test('0042: search_dishes — cuisine of the place, consensus chips carry every code, min score; paging', async () => {
  const dishes = (args = '') => as(A, () => rows(`select dish_name from public.search_dishes(p_query => 'tipo'${args})`));
  assert.deepEqual((await dishes()).map((r) => r.dish_name).sort(), ['Tipo curry', 'Tipo pasta', 'Tipo soup']);
  assert.deepEqual((await dishes(`, p_cuisines => '{Thai}'`)).map((r) => r.dish_name).sort(), ['Tipo curry', 'Tipo soup']);
  assert.deepEqual((await dishes(`, p_tags => '{v,gf}'`)).map((r) => r.dish_name).sort(), ['Tipo pasta', 'Tipo soup']);
  assert.deepEqual((await dishes(`, p_min_score => 4`)).map((r) => r.dish_name).sort(), ['Tipo curry', 'Tipo soup']);

  const f = `p_tags => '{gf}'`;
  const whole = await as(A, () => rows(`select * from public.search_dishes(p_query => 'tipo', ${f})`));
  const p1 = await as(A, () => rows(`select * from public.search_dishes(p_query => 'tipo', p_limit => 2, ${f})`));
  const l = p1.at(-1);
  const p2 = await as(A, () => rows(`select * from public.search_dishes(p_query => 'tipo', p_limit => 2, p_cursor_match_tier => $1,
    p_cursor_review_count => $2, p_cursor_dish_name => $3, p_cursor_dish_id => $4, ${f})`, [l.match_tier, l.review_count, l.dish_name, l.dish_id]));
  assert.deepEqual([...p1, ...p2], whole);
});

test('0042: nearby_places — the same filters; keyset unchanged', async () => {
  const near = (args = '') => as(A, () => rows(`select name, distance_m from public.nearby_places(p_lat => -37.8136, p_lng => 144.9631, p_radius_m => 5000${args})`));
  assert.deepEqual((await near()).map((r) => r.name), ['Tipo 00', 'Tipo Pasta Bar', 'Tipo Thai'], 'Geelong is out of range');
  assert.deepEqual((await near(`, p_cuisines => '{thai}'`)).map((r) => r.name), ['Tipo Thai']);
  assert.deepEqual((await near(`, p_tags => '{gf,v}'`)).map((r) => r.name), ['Tipo Pasta Bar']);
  assert.deepEqual((await near(`, p_min_score => 4.5`)).map((r) => r.name), ['Tipo 00']);
  const p1 = await as(A, () => rows(`select * from public.nearby_places(-37.8136, 144.9631, 5000, 1, null, null, '{italian}')`));
  const p2 = await as(A, () => rows(`select * from public.nearby_places(-37.8136, 144.9631, 5000, 1, $1, $2, '{italian}')`, [p1[0].distance_m, p1[0].restaurant_id]));
  const p3 = await as(A, () => rows(`select * from public.nearby_places(-37.8136, 144.9631, 5000, 1, $1, $2, '{italian}')`, [p2[0].distance_m, p2[0].restaurant_id]));
  assert.deepEqual([p1, p2, p3].map((p) => p.map((r) => r.name)), [['Tipo 00'], ['Tipo Pasta Bar'], []]);
});

test('0042: search_cuisines — grouped case-insensitively, busiest first; signed-in only; one overload each', async () => {
  const got = await as(A, () => rows(`select * from public.search_cuisines()`));
  assert.deepEqual(got, [{ cuisine: 'Italian', place_count: 2 }, { cuisine: 'Thai', place_count: 2 }]);
  for (const call of [`public.search_cuisines()`, `public.search_places('tipo')`, `public.search_dishes('tipo')`, `public.nearby_places(-37.8, 144.9)`]) {
    assert.equal((await as(null, () => error(db.query(`select * from ${call}`))))?.code, '42501', call);
  }
  const n = await rows(`select proname, count(*)::int n from pg_proc where proname in ('search_places','search_dishes','nearby_places') group by 1 order by 1`);
  assert.deepEqual(n.map((r) => r.n), [1, 1, 1], 'no second overload (landmine 7)');
  // the pre-0042 named call still binds
  assert.equal(await as(A, () => error(db.query(`select * from public.search_places(p_query => 'ti', p_limit => 5, p_cursor_match_tier => null,
    p_cursor_review_count => null, p_cursor_name => null, p_cursor_id => null)`))), null);
});

// ---------------------------------------------------------------------------------------------------
// 0043 — journal filter + sort
// ---------------------------------------------------------------------------------------------------
test('0043: setup — alice\'s journal', async () => {
  // alice so far: id(101) Tipo 00 best 6 (Sept 2). Add: two unscored, two scored, a tagged one.
  await visit(120, A, R3, 'Tipo curry 4.5 GF', [{ dish_name: 'Tipo curry', score: 4.5, score_evidence: 'Tipo curry 4.5', tags: ['gf'] }], '2026-09-10T09:00:00Z');
  await visit(121, A, R3, 'salad again', [{ dish_name: 'Salad' }], '2026-09-11T09:00:00Z');
  await visit(122, A, R2, 'Tipo pasta 4.5', [{ dish_name: 'Tipo pasta', score: 4.5, score_evidence: 'Tipo pasta 4.5' }], '2026-09-12T09:00:00Z');
  await visit(123, A, R2, 'just words', [], '2026-09-13T09:00:00Z');
  // 23:30 UTC on the 13th is the 14th in Melbourne
  await visit(124, A, R1, 'Tiramisu 3', [{ dish_name: 'Tiramisu', score: 3, score_evidence: 'Tiramisu 3' }], '2026-09-13T23:30:00Z');
});

const mine = (args = '', who = A) => as(who, () => rows(`select id, created_at, best_score::float b from public.my_entries(${args})`));

test('0043: my_entries — newest, oldest, top (best score, unscored last); owner-only', async () => {
  const newest = await mine();
  assert.deepEqual(newest.map((r) => r.id), [id(124), id(123), id(122), id(121), id(120), id(101)], 'only alice\'s own');
  assert.deepEqual((await mine(`p_sort => 'oldest'`)).map((r) => r.id), [...newest.map((r) => r.id)].reverse());
  const top = await mine(`p_sort => 'TOP'`);
  assert.deepEqual(top.map((r) => [r.id, r.b]), [
    [id(101), 6], [id(122), 4.5], [id(120), 4.5], [id(124), 3], [id(123), null], [id(121), null],
  ], 'ties on best score break newest first; unscored last, newest first');
  assert.equal((await as(A, () => error(db.query(`select * from public.my_entries(p_sort => 'best')`))))?.code, '22023');
  assert.equal((await as(null, () => error(db.query(`select * from public.my_entries()`))))?.code, '42501');
});

test('0043: my_entries — every sort walks page by page to the whole list, across the unscored tail', async () => {
  for (const sort of ['newest', 'oldest', 'top']) {
    const whole = await mine(`p_sort => '${sort}'`);
    const walked = [];
    let last = null;
    for (let i = 0; i < 10; i++) {
      const page = await as(A, () => rows(`select id, created_at, best_score::float b from public.my_entries(p_sort => $1, p_limit => 1,
        p_cursor_created_at => $2, p_cursor_id => $3, p_cursor_best_score => $4)`, [sort, last?.created_at ?? null, last?.id ?? null, last?.b ?? null]));
      if (!page.length) break;
      walked.push(...page);
      last = page.at(-1);
    }
    assert.deepEqual(walked, whole, sort);
  }
});

test('0043: my_entries — place, min score, tag, dates (inclusive, in the zone)', async () => {
  assert.deepEqual((await mine(`p_restaurant_id => '${R2}'`)).map((r) => r.id), [id(123), id(122)]);
  assert.deepEqual((await mine(`p_min_score => 4.5`)).map((r) => r.id), [id(122), id(120), id(101)]);
  assert.deepEqual((await mine(`p_tag => ' GF '`)).map((r) => r.id), [id(120)]);
  assert.deepEqual(await mine(`p_tag => 'xx'`), []);
  assert.deepEqual((await mine(`p_from => '2026-09-11', p_to => '2026-09-13'`)).map((r) => r.id), [id(123), id(122), id(121)],
    'inclusive; 23:30Z on the 13th is the 14th in Melbourne');
  assert.deepEqual((await mine(`p_from => '2026-09-11', p_to => '2026-09-13', p_tz => 'UTC'`)).map((r) => r.id), [id(124), id(123), id(122), id(121)]);
  assert.deepEqual((await mine(`p_sort => 'top', p_restaurant_id => '${R3}'`)).map((r) => [r.id, r.b]), [[id(120), 4.5], [id(121), null]]);
});

test('0043: my_entry_places — the caller\'s places, busiest first; paged; owner-only', async () => {
  const all = await as(A, () => rows(`select * from public.my_entry_places()`));
  assert.deepEqual(all.map((r) => [r.name, r.entry_count, r.locality]), [
    ['Tipo 00', 2, 'Melbourne'], ['Tipo Pasta Bar', 2, 'Carlton'], ['Tipo Thai', 2, 'Fitzroy'],
  ]);
  const p1 = await as(A, () => rows(`select * from public.my_entry_places(p_limit => 2)`));
  const l = p1.at(-1);
  const p2 = await as(A, () => rows(`select * from public.my_entry_places(p_limit => 2, p_cursor_entry_count => $1, p_cursor_name => $2,
    p_cursor_restaurant_id => $3)`, [l.entry_count, l.name, l.restaurant_id]));
  assert.deepEqual([...p1, ...p2], all);
  assert.deepEqual((await as(B, () => rows(`select name from public.my_entry_places()`))).map((r) => r.name).sort(),
    ['Tipo 00', 'Tipo Far', 'Tipo Pasta Bar', 'Tipo Thai'], 'bob sees his own');
  assert.equal((await as(null, () => error(db.query(`select * from public.my_entry_places()`))))?.code, '42501');
});

// ---------------------------------------------------------------------------------------------------
// 0044 — a re-sort without six_tokens keeps a marked 6 (QA on PR #71). Runs last: it adds entries.
// ---------------------------------------------------------------------------------------------------
const lines = (entry) => rows(`select d.name, v.score::float s, v.score_evidence ev, v.evidence_offset off, v.tags
  from public.reviews v join public.dishes d on d.id = v.dish_id where v.entry_id = $1 order by v.entry_position`, [entry]);
const edit = (entry, body) => as(A, () => db.query(`update public.entries set body = $2 where id = $1`, [entry, body]));

test('0044: a re-sort without six_tokens keeps the 6 (the QA probe), tags and all', async () => {
  const E = await visit(130, A, R1, 'Tiramisu 6 and the gnocchi 4 GF', [
    { dish_name: 'Tiramisu', score: 6, score_evidence: '6', evidence_offset: 9 },
    { dish_name: 'Gnocchi', score: 4, score_evidence: 'gnocchi 4', tags: ['gf'] },
  ], '2026-09-20T09:00:00Z');
  // the tag-only re-sort / "Print it again" / retry: the plan arrives with no 6 on the tiramisu
  await sortAs(E, R1, [{ dish_name: 'Tiramisu' }, { dish_name: 'Gnocchi', score: 4, score_evidence: 'gnocchi 4' }]);
  assert.deepEqual(await lines(E), [
    { name: 'Tiramisu', s: 6, ev: '6', off: 9, tags: [] },
    { name: 'Gnocchi', s: 4, ev: 'gnocchi 4', off: 19, tags: ['gf'] },
  ]);
  await sortAs(E, R1, [{ dish_name: 'Tiramisu' }, { dish_name: 'Gnocchi' }]);
  assert.equal((await lines(E))[0].s, 6, 'and again — the carried 6 carries');
});

test('0044: the 6 edited out of the words drops; so does one an edit moved', async () => {
  const E = id(130);
  await edit(E, 'Honestly: Tiramisu 6 and the gnocchi 4 GF');
  await sortAs(E, R1, [{ dish_name: 'Tiramisu' }]);
  assert.deepEqual((await lines(E)).map((l) => [l.name, l.s, l.ev]), [['Tiramisu', null, null]], 'moved: not at its span');

  const F = await visit(131, A, R1, 'Tiramisu 6 and the gnocchi 4', [
    { dish_name: 'Tiramisu', score: 6, score_evidence: '6', evidence_offset: 9 },
  ], '2026-09-21T09:00:00Z');
  await edit(F, 'Tiramisu 5 and the gnocchi 4');
  await sortAs(F, R1, [{ dish_name: 'Tiramisu', score: 5, score_evidence: 'Tiramisu 5' }]);
  assert.deepEqual((await lines(F)).map((l) => [l.name, l.s]), [['Tiramisu', 5]]);
  await edit(F, 'Tiramisu and the gnocchi 4');
  await sortAs(F, R1, [{ dish_name: 'Tiramisu' }]);
  assert.deepEqual((await lines(F)).map((l) => [l.name, l.s]), [['Tiramisu', null]]);
});

test('0044: a typed "6" is still never a score — only the line that held a marked 6 carries one', async () => {
  const E = await visit(132, A, R1, 'Tiramisu 6 and the gnocchi 6', [
    { dish_name: 'Tiramisu', score: 6, score_evidence: '6', evidence_offset: 9 },
    { dish_name: 'Gnocchi' },
  ], '2026-09-22T09:00:00Z');
  await sortAs(E, R1, [{ dish_name: 'Gnocchi' }, { dish_name: 'Tiramisu' }]);
  assert.deepEqual((await lines(E)).map((l) => [l.name, l.s, l.off]), [['Gnocchi', null, null], ['Tiramisu', 6, 9]],
    'the 6 follows its line by match, not by position');
  // an unscored plan whose prior line was scored 4 (not 6) carries nothing
  const F = await visit(133, A, R1, 'Gnocchi 4 then 6 of us left', [{ dish_name: 'Gnocchi', score: 4, score_evidence: 'Gnocchi 4' }],
    '2026-09-23T09:00:00Z');
  await sortAs(F, R1, [{ dish_name: 'Gnocchi' }]);
  assert.deepEqual((await lines(F)).map((l) => [l.name, l.s]), [['Gnocchi', null]]);
});

test('0044: a placeless entry\'s parked plan carries its 6 the same way', async () => {
  const P = id(134);
  await db.exec(`alter table public.entries disable trigger entries_place_required;`);
  try {
    await db.query(`insert into public.entries (id, author_id, body) values ($1, $2, 'Tiramisu 6 was it')`, [P, A]);
  } finally {
    await db.exec(`alter table public.entries enable trigger entries_place_required;`);
  }
  await sortAs(P, null, [{ dish_name: 'Tiramisu', score: 6, score_evidence: '6', evidence_offset: 9 }]);
  await sortAs(P, null, [{ dish_name: 'Tiramisu' }]);
  const plan = (await rows(`select sort_plan from public.entries where id = $1`, [P]))[0].sort_plan;
  assert.deepEqual(plan.map((i) => [i.dish_name, i.score, i.evidence_offset]), [['Tiramisu', 6, 9]]);
});
