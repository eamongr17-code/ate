-- 0004_rls.sql
-- Ate backend — Wave 0, BE-4: Row-Level Security on EVERY table.
-- data-model §5 / integration-design "Row-Level Security". RLS is deny-by-default
-- once enabled; every table gets explicit policies for each of select/insert/
-- update/delete it needs. No table is left unprotected (security advisor + QA
-- will flag any gap). Allow AND deny are both intended below.
--
-- Read model: the app is a social product — content (profiles, restaurants,
-- dishes, reviews, comments, lists, edges) is publicly readable to AUTHENTICATED
-- users. Writes are scoped to the acting user (auth.uid()).
--
-- Reference data (restaurants, dishes) is created via authenticated paths but is
-- NOT user-deletable (data-model §4) — dishes change only via merge (an admin
-- RPC, 0006, which runs as definer and bypasses these policies).

set search_path = public, extensions;

-- ===========================================================================
-- profiles
-- ===========================================================================
alter table public.profiles enable row level security;

create policy profiles_select_all on public.profiles
  for select to authenticated using (true);

-- INSERT is normally done by the new-user trigger (0005, security definer).
-- This policy lets a user create/repair only their OWN row.
create policy profiles_insert_self on public.profiles
  for insert to authenticated with check (id = (select auth.uid()));

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- No DELETE policy: accounts are SOFT-deleted (data-model §9.C) via the
-- deactivate_account RPC (0005), not row DELETE. Deny-by-default = no hard delete.

-- ===========================================================================
-- restaurants — public read; authed insert (Places-resolve path); no user U/D.
-- ===========================================================================
alter table public.restaurants enable row level security;

create policy restaurants_select_all on public.restaurants
  for select to authenticated using (true);

-- Authenticated users may create restaurants (the "resolve a Place → upsert" path
-- runs client- or function-side). The places-search edge function uses the
-- service role and bypasses RLS for its server-side upsert; this policy covers
-- any direct authed insert.
create policy restaurants_insert_authed on public.restaurants
  for insert to authenticated with check (true);

-- Intentionally NO update/delete policy for end users: restaurants are
-- Places-backed reference data, curated via the resolve/upsert path only.

-- ===========================================================================
-- dishes — public read; authed insert (add-dish); no user U/D (merge-only).
-- ===========================================================================
alter table public.dishes enable row level security;

create policy dishes_select_all on public.dishes
  for select to authenticated using (true);

-- A user may add a dish, attributed to themselves.
create policy dishes_insert_authed on public.dishes
  for insert to authenticated
  with check (created_by_user_id = (select auth.uid()));

-- Intentionally NO update/delete for end users: dishes are shared UGC catalogue
-- data; they change only via the merge RPC (0006, security definer).

-- ===========================================================================
-- reviews — public read; author writes own.
-- ===========================================================================
alter table public.reviews enable row level security;

create policy reviews_select_all on public.reviews
  for select to authenticated using (true);

create policy reviews_insert_author on public.reviews
  for insert to authenticated with check (reviewer_id = (select auth.uid()));

create policy reviews_update_author on public.reviews
  for update to authenticated
  using (reviewer_id = (select auth.uid()))
  with check (reviewer_id = (select auth.uid()));

create policy reviews_delete_author on public.reviews
  for delete to authenticated using (reviewer_id = (select auth.uid()));

-- ===========================================================================
-- comments — public read; author writes own.
-- ===========================================================================
alter table public.comments enable row level security;

create policy comments_select_all on public.comments
  for select to authenticated using (true);

create policy comments_insert_author on public.comments
  for insert to authenticated with check (user_id = (select auth.uid()));

create policy comments_update_author on public.comments
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy comments_delete_author on public.comments
  for delete to authenticated using (user_id = (select auth.uid()));

-- ===========================================================================
-- lists — readable (shareable); owner writes own.
-- ===========================================================================
alter table public.lists enable row level security;

create policy lists_select_all on public.lists
  for select to authenticated using (true);

create policy lists_insert_owner on public.lists
  for insert to authenticated with check (owner_id = (select auth.uid()));

create policy lists_update_owner on public.lists
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create policy lists_delete_owner on public.lists
  for delete to authenticated using (owner_id = (select auth.uid()));

-- ===========================================================================
-- follows — public read; the acting user (follower) writes own edges.
-- ===========================================================================
alter table public.follows enable row level security;

create policy follows_select_all on public.follows
  for select to authenticated using (true);

create policy follows_insert_self on public.follows
  for insert to authenticated with check (follower_id = (select auth.uid()));

create policy follows_delete_self on public.follows
  for delete to authenticated using (follower_id = (select auth.uid()));

-- ===========================================================================
-- review_likes — public read; the acting user writes own likes.
-- ===========================================================================
alter table public.review_likes enable row level security;

create policy review_likes_select_all on public.review_likes
  for select to authenticated using (true);

create policy review_likes_insert_self on public.review_likes
  for insert to authenticated with check (user_id = (select auth.uid()));

create policy review_likes_delete_self on public.review_likes
  for delete to authenticated using (user_id = (select auth.uid()));

-- ===========================================================================
-- comment_likes — public read; the acting user writes own likes.
-- ===========================================================================
alter table public.comment_likes enable row level security;

create policy comment_likes_select_all on public.comment_likes
  for select to authenticated using (true);

create policy comment_likes_insert_self on public.comment_likes
  for insert to authenticated with check (user_id = (select auth.uid()));

create policy comment_likes_delete_self on public.comment_likes
  for delete to authenticated using (user_id = (select auth.uid()));

-- ===========================================================================
-- list_dishes — readable; only the LIST OWNER mutates membership.
-- Ownership is checked via a subquery against lists (the row references list_id).
-- ===========================================================================
alter table public.list_dishes enable row level security;

create policy list_dishes_select_all on public.list_dishes
  for select to authenticated using (true);

create policy list_dishes_insert_owner on public.list_dishes
  for insert to authenticated
  with check (exists (
    select 1 from public.lists l
    where l.id = list_id and l.owner_id = (select auth.uid())
  ));

create policy list_dishes_update_owner on public.list_dishes
  for update to authenticated
  using (exists (
    select 1 from public.lists l
    where l.id = list_id and l.owner_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.lists l
    where l.id = list_id and l.owner_id = (select auth.uid())
  ));

create policy list_dishes_delete_owner on public.list_dishes
  for delete to authenticated
  using (exists (
    select 1 from public.lists l
    where l.id = list_id and l.owner_id = (select auth.uid())
  ));
