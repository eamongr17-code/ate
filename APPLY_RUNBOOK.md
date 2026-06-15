# Wave 0 — Backend apply runbook

> The backend-engineer **authored** these artifacts; they have NOT been applied (no linked CLI/MCP on the BE side). The **lead** applies them via Supabase MCP, in the exact order below, and relays any errors back to the BE engineer to fix. Project ref host: `vyaexmnajnbryimbkgkf`.

## 1. Apply order

Apply each migration with `apply_migration` (name it after the file), **in order**:

| # | File | Tool | Notes |
|---|------|------|-------|
| 1 | `supabase/migrations/0001_extensions.sql` | `apply_migration` | Installs postgis/citext/pg_trgm/pgcrypto into `extensions` schema. |
| 2 | `supabase/migrations/0002_core_schema.sql` | `apply_migration` | Core tables + indexes + constraints. |
| 3 | `supabase/migrations/0003_edge_tables.sql` | `apply_migration` | Edge/join tables. |
| 4 | `supabase/migrations/0004_rls.sql` | `apply_migration` | RLS on every table. |
| 5 | `supabase/migrations/0005_functions_views.sql` | `apply_migration` | Views, triggers, RPCs (incl. `handle_new_user` on auth.users). |
| 6 | `supabase/migrations/0006_merge_dish.sql` | `apply_migration` | Dish-merge RPC. |
| 7 | `supabase/migrations/0007_storage.sql` | `apply_migration` | Buckets + storage RLS. |
| 8 | `supabase/seed.sql` | `execute_sql` | Seed data. **Run AFTER all migrations** (it depends on the `handle_new_user` trigger from step 5). Not a migration — it inserts data, run it as raw SQL. |
| 9 | `supabase/functions/places-search/index.ts` | `deploy_edge_function` | Deploy with name `places-search`. |

After step 7, run `get_advisors` (security + performance) — expect a **clean security report** (RLS on every table). Relay any advisor finding back to BE.

After step 8, sanity-check with `execute_sql`:
- `select count(*) from public.reviews;` → 8
- `select avg_rating, review_count from public.restaurant_stats;` → Goldee's avg_rating ≈ **4.5** (mean of the 4 per-dish averages: brisket≈4.7, beef-rib 5.0, sausage 4.5, mac 4.0 → ~4.55), review_count 7. Smoke Ring avg_rating 4.5, review_count 1. (This is the mean-of-per-dish-averages, NOT a flat review mean — the flat mean over all 7 Goldee's reviews would differ.)
- `select like_count, comment_count from public.reviews where id = '00000000-0000-4000-8000-0000000000d1';` → like_count 2, comment_count 2 (counter caches populated by triggers).

After step 9, run `generate_typescript_types` and hand the output to the FE wave.

## 2. Env secret the Places function needs

Set BEFORE or AFTER deploy (the function reads it at runtime):

- **`GOOGLE_PLACES_API_KEY`** — set via `supabase secrets set GOOGLE_PLACES_API_KEY=…` (or the MCP equivalent). **While ABSENT, the function runs in STUB mode** and returns fixture restaurants behind the real interface. The moment the key is set, the live Google Places path activates with no code change. (`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected by the Supabase runtime — do not set them manually.)

Tell Eamon: **the only secret to provision is `GOOGLE_PLACES_API_KEY`** (lead E-1). Until then, restaurant search works against the 3 stub places.

## 3. Auth-users-for-seed approach

`profiles.id` references `auth.users(id)`, so seed users need `auth.users` rows. The seed (`seed.sql`) takes the **test-only direct-insert path**:
- It inserts 3 `auth.users` rows with fixed UUIDs, a known bcrypt password (`atedemo123`), and `email_confirmed_at = now()` so they can sign in immediately.
- The `handle_new_user` trigger (step 5) fires on each insert and creates the matching `profiles` row + the system "Saved" list automatically.
- The seed then UPDATEs profile bios and inserts all content (restaurants, dishes, reviews, follows, likes, comments, lists).
- **Idempotent:** re-running deletes the 3 seeded `auth.users` (cascading everything) and re-inserts. **Safe only on a test/seed project** — never run against real user data.

Seed login accounts (email / password `atedemo123`): `eamon@ate.test`, `feastfix@ate.test`, `smokering@ate.test`.

> **Risk to watch:** direct `auth.users` inserts depend on the GoTrue schema. The seed includes the empty-string token columns (`confirmation_token`, etc.) that some GoTrue versions enforce NOT NULL. If step 8 errors on a missing/extra `auth.users` column, relay the exact error to BE — the fix is column-list-only (no logic change).

## 4. If errors come back

Relay the exact SQL error + which step. Likely-first suspects, in order:
1. **search_path / extension schema** — if `geography`/`citext`/`gin_trgm_ops` "type/operator class does not exist", the migration's `set search_path = public, extensions` may not be taking; BE will qualify the type explicitly.
2. **`security_invoker` views** (PG15+) — if unsupported, BE drops the option (views fall back to definer; grants already in place).
3. **auth.users column mismatch** (seed) — see the risk note above.
4. **`raw_user_meta_data ->> 'username'` collision** in `handle_new_user` — the trigger already de-dupes usernames; if a seed username still collides, it's a data issue in the seed, not the trigger.
