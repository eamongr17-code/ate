-- 0077_rls_block_set.sql
-- Ate backend — the block check in RLS runs once per query, not once per row.
--
-- Found by the load test (supabase/tests/load): the SELECT policies on entries, reviews and profiles
-- called blocked_with(author) for EVERY row a query touched — a lookup in `blocks` per row. Any read
-- that aggregates lines (Top Ate, Feed cities, search counts, a place's dishes) paid it across the
-- whole table: at 1M review lines that is ~8 s of the request on its own, past the API's statement
-- timeout. Now the policy asks for the viewer's block set once (blocked_ids(), wrapped in a scalar
-- subquery so Postgres evaluates it a single time per statement) and each row is an array test.
--
-- Same rule, same rows: blocked_with(x) is "a block either way between the viewer and x", and
-- blocked_ids() is exactly the set of such x. Policies are dropped and recreated with the same names,
-- roles and commands. blocked_with stays for the functions that check one person.

create or replace function public.blocked_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(array_agg(x), '{}')
  from (
    select b.blocked_id as x from public.blocks b where b.blocker_id = (select auth.uid())
    union
    select b.blocker_id from public.blocks b where b.blocked_id = (select auth.uid())
  ) s;
$$;

revoke all on function public.blocked_ids() from public, anon;
grant execute on function public.blocked_ids() to authenticated, service_role;

comment on function public.blocked_ids() is
  'Everyone the viewer has blocked or been blocked by (0077). RLS reads it once per statement: (select public.blocked_ids()).';

drop policy if exists entries_select_visible on public.entries;
create policy entries_select_visible on public.entries
  for select to authenticated
  using (
    author_id = (select auth.uid())
    or not (author_id = any ((select public.blocked_ids())::uuid[]))
  );

drop policy if exists reviews_select_visible on public.reviews;
create policy reviews_select_visible on public.reviews
  for select to authenticated
  using (
    reviewer_id = (select auth.uid())
    or not (reviewer_id = any ((select public.blocked_ids())::uuid[]))
  );

drop policy if exists profiles_select_visible on public.profiles;
create policy profiles_select_visible on public.profiles
  for select to authenticated
  using (
    id = (select auth.uid())
    or (deleted_at is null and not (id = any ((select public.blocked_ids())::uuid[])))
  );
