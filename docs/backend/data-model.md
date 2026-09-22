# Ate — data model (V1)

**Status:** the schema as `supabase/migrations/0001–0025` define it. Forward-only; applied migrations
are never edited. V1 re-scope landed in **0018–0023**; corrections + offsets in **0024–0025**
(2026-09-22).

The atom the USER creates is an **entry** = one visit. The atom AGGREGATES are built from is still a
per-dish **review** — reviews are now *linked* to an entry, not replaced by it. A **sorter** turns the
words into structure asynchronously (`supabase/functions/sort-entry`).

```
profiles ──< entries ──< entry_photos          entries.restaurant_id → restaurants (nullable)
                └──< reviews >── dishes >── restaurants
profiles ──< saves >── dishes        profiles ──< blocks >── profiles       profiles ──< reports
```

Three design rules are enforced in the database, not just in the app (`docs/DESIGN.md` 7–9):

| Rule | Enforcement |
|---|---|
| 7 — a score is only ever the user's, never inferred | `reviews.score` is NULLABLE; `apply_entry_sort` drops any score whose `score_evidence` is not a literal substring of `entries.body` |
| 8 — a place attaches only when named or tapped | `entries.restaurant_id` nullable + `restaurant_source ∈ (user, sorter)`, CHECKed together; no code path reads location |
| 9 — the words are never rewritten | `entries.body` is written once by the client; UPDATE on entries is column-granted to `(body, visibility)` only, and the sorter writes nowhere near it. Dish notes must be substrings of the body |
| the user's fix outranks the sorter | `reviews.corrected_at` / `entries.place_corrected_at`; `apply_entry_sort` deletes only lines with `corrected_at IS NULL`, so a re-sort (forced or not) cannot overwrite a correction (0024) |

## New in V1

### `entries` — one visit (0018)
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | **client-minted** (offline-first). INSERT, never upsert — see Landmines |
| `author_id` | uuid → profiles | |
| `body` | text NOT NULL, default `''` | the user's words, verbatim. `''` is legal (photos-only entry) |
| `visibility` | text NOT NULL, default `'public'` | `public` \| `private`, per entry |
| `restaurant_id` | uuid → restaurants, NULL | NULL until named/tapped |
| `restaurant_source` | text NULL | `user` \| `sorter`; NULL iff `restaurant_id` is NULL |
| `order_number` | int NOT NULL | "Order #0142". Server-allocated per author; UNIQUE `(author_id, order_number)` |
| `sort_status` | text NOT NULL, default `'pending'` | `pending` \| `sorted` \| `failed` |
| `sort_mode` / `sort_error` / `sorted_at` | text / text / timestamptz | sorter bookkeeping |
| `sort_plan` | jsonb NULL | last validated plan. Internal (re-apply source + eval audit); not on the read view |
| `created_at` | timestamptz | **client-settable** so an offline entry keeps when they ate |
| `updated_at` | timestamptz | trigger-maintained |

| `place_corrected_at` | timestamptz NULL | the author overrode the place (0024); once set, no place mention is recorded again |
| `place_query` / `place_offset` | text / int NULL | the verbatim slice of `body` that named the attached place, and where it starts (0024) |

`order_number` is allocated by `trg_entry_biu` from a row-locked counter (`profiles.entry_seq`), so it
is race-free. It is allocated **on arrival**, so an entry written offline can carry an older
`created_at` than a lower order number — deliberate: "Order #" is the order Ate printed receipts in.

**OFFSETS ARE UNICODE SCALARS.** Every `*_offset` on `reviews`/`entries` is a 0-based code-point offset
into `entries.body`, verified on write by `verified_offset()` (the claimed position must really hold that
text, else the first occurrence, else NULL). Scalars because Postgres `position()`/`substring()`/
`char_length()` count code points; JS and Swift count UTF-16 and must convert. Lengths are
`char_length(score_evidence | mention_text | place_query)` — the view computes them, nothing stores them.

### `entry_photos` (0018)
`(entry_id, position)` composite **PK** (a TOTAL unique — safe upsert target for a retried upload),
`photo_url` NOT NULL, `created_at`. Position 0–23. Separate table because the words save instantly
while uploads are still in flight.

### `reviews` — changed (0018, 0024)
Additive: `entry_id` (→ entries, cascade; NULL for legacy rows), `entry_position` smallint (receipt
line order), `score_evidence` text (the literal slice of the body that justified the score;
provenance only, never displayed).
0024 adds the provenance of a USER'S FIX and of WHERE each finding sits in the words:
`corrected_at` (the author fixed this line — dish, score or note; stamped by `correct_entry_dish` and by
the correction trigger on any author UPDATE of `dish_id`/`score`/`note`, monotone, never cleared),
`corrected_from_name` (the dish name the line carried when first corrected = the sorter's proposal, the
key a later re-sort recognises it by), `evidence_offset`, `mention_text`, `mention_offset`.
**Breaking for readers:** `score` is now **NULLABLE** — an unscored dish review is the normal case.
The `reviews_score_halfstep` CHECK is untouched (a NULL CHECK passes), so every non-null score is
still 0.5–5.0 in half steps. Reviews written by the sorter inherit the entry's `created_at`.
**Multiple reviews per (user, dish) remain allowed by design** (sittings). No constraint, ever.

### `saves` (0020)
`(user_id, dish_id)` **PK** + `source_entry_id` (→ entries, SET NULL), `source_user_id` (→ profiles,
SET NULL), `created_at`. A save is a DISH at its restaurant, with provenance ("from @jessw"). Private
to the saver. The old `lists`/`list_dishes` pair is left applied and untouched — V1 does not read it.

### `blocks` (0019)
`(blocker_id, blocked_id)` PK, no self-block. Recorded one-way, enforced **both ways** by
`blocked_with(uuid)` (SECURITY DEFINER, so it reads `blocks` without recursing through RLS).

### `reports` (0019)
`id`, `reporter_id`, exactly one of `entry_id` / `profile_id` (CHECK), `reason`, `note`,
`status ∈ (open, actioned, dismissed)`. Reporter-visible only; triaged manually with the service role.

### `profiles` — changed (0018)
Additive: `entry_seq` int (the order-number counter; never client-writable), `city` text (shown under
the handle on You/Profile). `username` is `citext UNIQUE` — the handle.

## Unchanged from Wave 0

`restaurants` (Google-Places-backed, `source ∈ (places, manual)`, `google_place_id` partial-unique
`WHERE NOT NULL`, PostGIS `location`) · `dishes` (UGC, identity `(restaurant_id, lower(name))` partial
unique `WHERE merged_into_dish_id IS NULL`, merge tombstones) · storage buckets `review-photos` +
`avatars` (public-read via the **bucket flag**, own-folder write).

**Dormant in V1** (applied, unread, untouched): `comments`, `review_likes`, `comment_likes`, `follows`,
`lists`, `list_dishes`, `review_tags`, `notifications`.

## Landmines — do not re-learn

1. **PostgREST upsert needs a TOTAL unique constraint.** A partial index cannot be an `ON CONFLICT`
   arbiter (the 0014/0016 incident). Safe targets: `entry_photos (entry_id, position)`,
   `saves (user_id, dish_id)`, `blocks (blocker_id, blocked_id)`, `entries (author_id, order_number)`.
2. **`dishes_identity_uq` is PARTIAL BY DESIGN.** Dish creation is **select-then-insert** —
   `find_or_create_dish()` (0021), which catches `unique_violation` and re-selects. Never `ON CONFLICT`.
3. **Never upsert `entries`.** The insert trigger consumes an order number; a conflicting upsert would
   burn one. Clients INSERT and treat `23505` as "already accepted" (the id is theirs, so it landed).
4. **Multiple reviews per (user, dish)** are a feature (sittings), not a bug to constrain away.
5. **Storage public-read rides the bucket flag**, not a SELECT policy. Never flip a bucket private
   casually — `0008` removed bucket-wide LIST on purpose and object reads still work.
6. **`entries.body` is never rewritten server-side.** If you find yourself writing UPDATE on it, stop.
7. **Adding a parameter to an RPC means DROP-then-CREATE, not CREATE OR REPLACE.** Two overloads make
   every PostgREST named-argument call ambiguous (`42725 function is not unique`) — a silent break for
   the client, not a warning. 0024 dropped `apply_entry_sort(uuid,uuid,jsonb,text)` before creating the
   six-argument one, in the same migration as its only caller's update.
8. **A correction is user data.** Never re-derive over a row with `corrected_at`/`place_corrected_at`,
   and never "clean up" one. A re-sort replaces the sorter's lines and nothing else.

## Derived reads (never stored)

| View | Columns | Notes |
|---|---|---|
| `dish_stats` | `dish_id, restaurant_id, score, review_count, cover_url, scored_count, people_count` | `score` = avg of non-null scores (NULL = nobody scored it); `people_count` = distinct reviewers |
| `restaurant_stats` | `restaurant_id, avg_rating, review_count, cover_url, people_count, dish_count` | `avg_rating` = **mean of per-dish averages**, null-score dishes excluded |
| `entry_cards` | the one entry shape (see `integration-design.md`) | Journal slip / Feed slip / Entry page / Share receipt are all this row; carries the token offsets + `items[].corrected` |
| `my_saved_dishes` | saved dish + place + dish aggregate + provenance handle | caller-scoped |

All are `security_invoker = true`, so **aggregates are viewer-relative**: a private entry's dish
reviews are hidden by RLS and therefore count towards nobody's averages but their author's. The
alternative leaks a score as soon as a dish has one reviewer. (Flagged as a product-visible choice.)

## RLS

Enabled on every table. Reads are authenticated-only; `anon` is revoked on all V1 tables.

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `entries` | own, or `public` AND not blocked | self | self (cols `body, visibility` only) | self |
| `entry_photos` | parent entry visible | parent entry is own | own | own |
| `reviews` | own, or (not blocked AND (`entry_id IS NULL` OR its entry is `public`)) | author | author | author |
| `profiles` | self, or not blocked | self | self | — (soft-delete RPC) |
| `saves` | own | own | own | own |
| `blocks` | rows you created | self as blocker | — | self as blocker |
| `reports` | own | self | — | — |
| `restaurants` / `dishes` | all | dishes: authed (self-attributed); restaurants: none (RPC/service role) | none | none |

The block filter is expressed **once**, in `blocked_with()`, and applied in the SELECT policies of
`profiles`, `entries` and `reviews` — so blocked users vanish from feed, journal, profile, place and
dish reads in both directions without any query having to remember.

**Column privileges do what RLS cannot:** `authenticated` may INSERT only
`(id, author_id, body, visibility, restaurant_id, created_at)` on `entries` and UPDATE only
`(body, visibility)`. `order_number`, `sort_status`, `sort_mode`, `sort_error`, `sorted_at`,
`sort_plan`, `restaurant_source` and 0024's `place_*` are unwritable by clients on every path — the
trigger and the 0021/0024 RPCs are their only writers. `restaurant_id` is insertable (the composer's
place pick) but not updatable: place corrections go through `correct_entry_place`, which also re-resolves
the dishes. `reviews` has no column grants, so an author can PATCH their own `score`/`note` — that is the
sanctioned path and the correction trigger records it. Anything beyond `score`/`note` is unsupported.

## Migration index

| # | File | What |
|---|---|---|
| 0001–0017 | — | Wave 0 core, RLS, views, storage, Places, manual restaurants, search blend |
| 0018 | `entries.sql` | entries + entry_photos; reviews.entry_id/entry_position/score_evidence; score nullable; profiles.entry_seq/city; order-number trigger; RLS + column grants |
| 0019 | `moderation.sql` | blocks + reports; `blocked_with`; block-aware SELECT policies; `handle_available`; block/report RPCs |
| 0020 | `saves.sql` | saves + `my_saved_dishes` + save/unsave RPCs |
| 0021 | `sort_write_path.sql` | `find_or_create_dish`, `apply_entry_sort`, `mark_entry_sort_failed`, `correct_entry_place`, `correct_entry_dish` |
| 0022 | `entry_reads.sql` | `entry_cards`; feed/journal/place readers; `place_dishes`, `place_summary`, `dish_summary`, `get_dish_reviews`; dish/restaurant stat columns |
| 0023 | `stats_search.sql` | `profile_summary`, `score_histogram`, `dishes_by_score`, `statement_months`, `monthly_statement`, `search_all` |
| 0024 | `corrections_and_offsets.sql` | correction provenance + the preservation rule in `apply_entry_sort` (dropped/recreated with `p_place_query`/`p_place_offset`); `verified_offset`; the correction trigger; dish display-name normalisation in `find_or_create_dish` |
| 0025 | `entry_cards_offsets.sql` | `entry_cards` + `place_offset`/`place_length` and `items[].evidence_*`/`mention_*`/`corrected` |
