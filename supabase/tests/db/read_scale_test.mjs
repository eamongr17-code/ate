// supabase/tests/db/read_scale_test.mjs — 0052: the stored city of a place stays exactly 0046's rule
// through every kind of write. (That the reads return the same rows as before 0052 was checked against
// the full seeded dataset, before vs after, when 0052 was written; the round 3–6 suites pin the
// semantics row by row.)
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { boot } from './harness.mjs';

const point = (lng, lat) => `extensions.ST_SetSRID(extensions.ST_MakePoint(${lng}, ${lat}), 4326)::geography`;
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
let db;

// 0046's rule, derived live from the catalogue — what place_cities returned before 0052.
const DERIVED = `
  with located as (select r.id, lower(btrim(public.place_locality(r.address, r.city))) as loc, public.city_at(r.location) as geo
                   from public.restaurants r),
  by_locality as (select l.loc, mode() within group (order by l.geo) as city from located l
                  where l.geo is not null and l.loc is not null group by l.loc)
  select * from (
    select l.id as restaurant_id, coalesce(l.geo, a.id, b.city) as city,
           case when l.geo is not null then 'location' when a.id is not null then 'name' when b.city is not null then 'locality' end as via
    from located l
    left join lateral (select c.id from public.cities c where l.loc is not null and (l.loc = lower(c.name) or l.loc = any(c.aliases))
                       order by c.id limit 1) a on true
    left join by_locality b on b.loc = l.loc) m
  where m.city is not null order by restaurant_id`;
const STORED = `select restaurant_id, city, via from public.place_cities order by restaurant_id`;

async function exact(label) {
  const [a, b] = [(await db.query(STORED)).rows, (await db.query(DERIVED)).rows];
  assert.deepEqual(a, b, label);
  return a;
}

before(async () => {
  db = await boot();
});
after(async () => db?.close());

test('0052: place_city_cache follows 0046 through inserts, locality and location changes, deletes and a cities change', async () => {
  await db.exec(`insert into public.restaurants (id, name, address, city, source, location) values
    ('${id(1)}', 'Hand Thornbury', null, 'Thornbury', 'manual', null),
    ('${id(2)}', 'Hand CBD', null, 'CBD', 'manual', null),
    ('${id(3)}', 'Nowhere', null, 'Daylesford', 'manual', null)`);
  assert.deepEqual((await exact('hand-added only')).map((r) => [r.restaurant_id, r.city, r.via]), [[id(2), 'melbourne', 'name']]);

  // A located Thornbury place arrives (another statement): the hand-added one is re-homed by it.
  await db.exec(`insert into public.restaurants (id, name, address, city, source, location) values
    ('${id(4)}', 'Google Thornbury', '1 High St, Thornbury VIC 3071, Australia', 'Thornbury', 'manual', ${point(145.005, -37.755)})`);
  const rows = await exact('sibling locality');
  assert.equal(rows.find((r) => r.restaurant_id === id(1))?.via, 'locality');

  // Its locality changes, then its point moves to Sydney, then it goes: the namesake follows each time.
  await db.exec(`update public.restaurants set address = '1 High St, Northcote VIC 3070, Australia' where id = '${id(4)}'`);
  assert.equal((await exact('locality moved')).find((r) => r.restaurant_id === id(1)), undefined);
  await db.exec(`update public.restaurants set address = null, city = 'Thornbury', location = ${point(151.2, -33.87)} where id = '${id(4)}'`);
  assert.equal((await exact('point moved')).find((r) => r.restaurant_id === id(1))?.city, 'sydney');
  await db.exec(`delete from public.restaurants where id = '${id(4)}'`);
  assert.equal((await exact('deleted')).find((r) => r.restaurant_id === id(1)), undefined);

  // A change to the cities themselves (a migration's job) rebuilds everything.
  await db.exec(`insert into public.restaurants (id, name, city, source, location) values ('${id(5)}', 'Edge', 'Somewhere', 'manual', ${point(145.6, -37.9)})`);
  await exact('before the radius change');
  await db.exec(`update public.cities set radius_m = 30000 where id = 'melbourne'`);
  await exact('after the radius change');
  await db.exec(`update public.cities set aliases = aliases || '{daylesford}' where id = 'ballarat'`);
  assert.equal((await exact('a new alias')).find((r) => r.restaurant_id === id(3))?.city, 'ballarat');
});

test('0052: clients cannot write the cache', async () => {
  await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${id(9)}', false);`);
  try {
    await assert.rejects(db.query(`delete from public.place_city_cache`), { code: '42501' });
    await assert.rejects(db.query(`select public.place_city_rebuild()`), { code: '42501' });
  } finally {
    await db.exec(`reset role;`);
  }
});
