// supabase/tests/db/security_hygiene_test.mjs — new objects are closed by default; trigger functions
// are not RPCs; the unindexed foreign keys got indexes (0100).
//
//   cd supabase/tests/db && npm ci && node --test

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { world } from './fixtures.mjs';

let db, rows;
after(async () => db?.close());

before(async () => {
  ({ db, rows } = await world());
});

const can = async (sql, params = []) => (await rows(sql, params))[0].ok;

test('0100: a table or function created after 0100 is granted to nobody until a migration says so', async () => {
  await db.exec(`
    create table public.zz_after_0100 (id int primary key);
    create function public.zz_after_0100_fn() returns int language sql as 'select 1';
  `);
  for (const role of ['anon', 'authenticated']) {
    for (const priv of ['select', 'insert', 'update', 'delete']) {
      assert.equal(await can(`select has_table_privilege($1, 'public.zz_after_0100', $2) as ok`, [role, priv]), false, `${role} ${priv}`);
    }
  }
  for (const role of ['anon', 'authenticated']) {
    assert.equal(await can(`select has_function_privilege($1, 'public.zz_after_0100_fn()', 'execute') as ok`, [role]), false, `${role} execute`);
  }
  // service_role keeps what it had, so edge functions see new tables
  assert.equal(await can(`select has_table_privilege('service_role', 'public.zz_after_0100', 'select') as ok`), true);
  await db.exec(`drop table public.zz_after_0100; drop function public.zz_after_0100_fn();`);
});

test('0100: trigger functions cannot be called through the API', async () => {
  for (const fn of ['entry_photo_left()', 'photo_also_forget()', 'restaurants_clean_name()', 'trg_client_image_url()', 'trg_report_budget()']) {
    for (const role of ['anon', 'authenticated']) {
      assert.equal(await can(`select has_function_privilege($1, $2, 'execute') as ok`, [role, `public.${fn}`]), false, `${role} ${fn}`);
    }
  }
});

test('0100: every single-column foreign key in public has an index', async () => {
  const missing = await rows(`
    select c.conrelid::regclass::text as tbl, a.attname as col
      from pg_constraint c
      join pg_class t on t.oid = c.conrelid
      join pg_namespace n on n.oid = t.relnamespace
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and n.nspname = 'public' and array_length(c.conkey, 1) = 1
       and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1])
     order by 1, 2`);
  assert.deepEqual(missing, []);
});
