// supabase/tests/db/harness.mjs
//
// Boots an in-process Postgres (PGlite — real Postgres compiled to WASM) with the four extensions
// 0001 installs, a minimal Supabase shape (./prelude.sql: roles, auth.uid(), storage), and then
// applies EVERY file in supabase/migrations in order. A migration that does not apply fails here,
// before anyone runs it on staging.
//
//   cd supabase/tests/db && npm ci && node --test
//
// It is local and throwaway by construction: nothing here can reach staging or prod.

import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { citext } from '@electric-sql/pglite/contrib/citext';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import { unaccent } from '@electric-sql/pglite/contrib/unaccent';
import { postgis } from '@electric-sql/pglite-postgis';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const MIGRATIONS = fileURLToPath(new URL('../../migrations/', import.meta.url));

export async function boot() {
  const db = await PGlite.create({ extensions: { pgcrypto, citext, pg_trgm, unaccent, postgis } });
  await db.exec(readFileSync(HERE + 'prelude.sql', 'utf8'));
  for (const f of readdirSync(MIGRATIONS).filter((f) => f.endsWith('.sql')).sort()) {
    try {
      await db.exec(readFileSync(MIGRATIONS + f, 'utf8'));
    } catch (e) {
      throw new Error(`migration ${f} failed: ${e.message}`);
    }
  }
  return db;
}

/** Run `fn` as a signed-in user (role authenticated, auth.uid() = uid), or as anon when uid is null. */
export function actors(db) {
  const setClaim = (uid) => `select set_config('request.jwt.claim.sub', '${uid ?? ''}', false);`;
  async function as(uid, fn) {
    await db.exec(`set role ${uid ? 'authenticated' : 'anon'}; ${setClaim(uid)}`);
    try {
      return await fn();
    } finally {
      await db.exec(`reset role; ${setClaim(null)}`);
    }
  }
  async function asService(fn) {
    await db.exec('set role service_role;');
    try {
      return await fn();
    } finally {
      await db.exec('reset role;');
    }
  }
  const rows = async (sql, params) => (await db.query(sql, params)).rows;
  const error = async (promise) => {
    try {
      await promise;
      return null;
    } catch (e) {
      return e;
    }
  };
  return { as, asService, rows, error };
}
