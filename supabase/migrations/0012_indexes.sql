-- 0012_indexes.sql
-- Ate backend — Tidy Run (2026-06-27): advisor-driven additive indexes.
--
-- Purely additive. Every statement is `create index if not exists` — no DROP,
-- no ALTER, no data movement, nothing the client reads/writes changes shape.
-- Safe to apply at any time; re-runnable.
--
-- Two motivations, both from the Supabase performance advisor + data-model:
--
-- (A) Unindexed foreign keys. The advisor flagged 5 FK columns with no covering
--     index — every cascade delete / "rows referencing this parent" lookup on
--     them is a seq scan. We add the standard covering b-tree per FK, named with
--     the existing `<table>_<col>_idx` convention (cf. dishes_restaurant_idx,
--     lists_owner_idx in 0002). Columns/constraints verified against the live
--     schema (0002 core, 0011 notifications):
--       comments.user_id            -> comments_user_id_fkey
--       dishes.created_by_user_id    -> dishes_created_by_user_id_fkey
--       notifications.actor_id       -> notifications_actor_id_fkey
--       notifications.comment_id     -> notifications_comment_id_fkey
--       notifications.review_id      -> notifications_review_id_fkey
--
-- (B) People-search trigram (data-model §5). §5 specified a username trigram for
--     the search screen that was never created — people-search currently seq-scans
--     profiles. We add GIN trigram on username AND name, matching the exact pattern
--     used for restaurants_name_trgm / dishes_name_trgm in 0002
--     (`using gin (<expr> extensions.gin_trgm_ops)`).
--     NOTE: profiles.username is citext, which has no default gin_trgm_ops operator
--     class, so it is cast to text in the index expression. Search predicates that
--     should hit this index must reference `username::text` (e.g.
--     `username::text ilike '%term%'`); profiles.name is plain text and needs no cast.

set search_path = public, extensions;

-- (A) Covering indexes for the advisor-flagged unindexed foreign keys ----------

create index if not exists comments_user_id_idx
  on public.comments (user_id);

create index if not exists dishes_created_by_user_id_idx
  on public.dishes (created_by_user_id);

create index if not exists notifications_actor_id_idx
  on public.notifications (actor_id);

create index if not exists notifications_comment_id_idx
  on public.notifications (comment_id);

create index if not exists notifications_review_id_idx
  on public.notifications (review_id);

-- (B) People-search trigram indexes (data-model §5) ---------------------------
-- username is citext -> cast to text for the gin_trgm_ops operator class.
create index if not exists profiles_username_trgm
  on public.profiles using gin ((username::text) extensions.gin_trgm_ops);

create index if not exists profiles_name_trgm
  on public.profiles using gin (name extensions.gin_trgm_ops);
