-- 0001_extensions.sql
-- Ate backend — Wave 0, BE-1: extensions.
--
-- Idempotent. `pgcrypto` (gen_random_uuid) is already present on Supabase; we
-- assert it. PostGIS powers the restaurants.location geography + the "nearby"
-- KNN access pattern (data-model §5). citext gives case-insensitive natural
-- keys (users.username/email — data-model §3). pg_trgm backs the search-screen
-- trigram match on dish/restaurant/user names (data-model §5).
--
-- NOTE: Supabase convention is to install extensions into the dedicated
-- `extensions` schema (not public). gen_random_uuid() and citext/geography
-- types remain reachable because `extensions` is on the database search_path.

create schema if not exists extensions;

create extension if not exists pgcrypto      with schema extensions;
create extension if not exists citext        with schema extensions;
create extension if not exists pg_trgm       with schema extensions;
create extension if not exists postgis       with schema extensions;
