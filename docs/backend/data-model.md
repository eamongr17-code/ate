# Ate — data model (V1)

**Status:** the schema as `supabase/migrations/0001–0033` define it. Forward-only; applied migrations
are never edited. V1 re-scope **0018–0023**; corrections + offsets **0024–0025**; covers, save toggle,
report vocabulary **0026–0028**; detail + You audit **0029–0030**; Search scopes **0031**; Apple sign-in +
account deletion **0032**; **every entry public 0033** (2026-09-25: public/private removed from the product).

The atom the USER creates is an **entry** = one visit. The atom AGGREGATES are built from is still a
per-dish **review**, now *linked* to an entry, not replaced by it. A **sorter** turns the words into
structure asynchronously (`supabase/functions/sort-entry`).

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
| `visibility` | text NOT NULL, default `'public'` | **DEPRECATED (0033): always `public`.** The trigger pins it on every write and the CHECK is `= 'public'`; kept only for shipped clients, dropped in a follow-up |
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

`order_number` comes from a row-locked counter (`profiles.entry_seq`, `trg_entry_biu`), allocated **on
arrival** — an offline entry can carry an older `created_at` than a lower number: "Order #" is print order.

**OFFSETS ARE UNICODE SCALARS** — every `*_offset` is a 0-based code-point offset into `entries.body`,
verified on write by `verified_offset()`; JS/Swift count UTF-16 and must convert. Views compute lengths.

### `entry_photos` (0018)
`(entry_id, position)` composite **PK** (a TOTAL unique — safe upsert target for a retried upload),
`photo_url` NOT NULL, `created_at`. Position 0–23. Separate because the words save while uploads fly.

### `reviews` — changed (0018, 0024)
Additive: `entry_id` (→ entries, cascade; **NULL for legacy rows, and they are real user data**),
`entry_position` smallint (receipt line order), `score_evidence` (the literal slice that justified the
score; provenance, never displayed), and 0024's fix-provenance: `corrected_at` (the author fixed this
line — `correct_entry_dish`, or any author UPDATE of `dish_id`/`score`/`note`; monotone, never cleared),
`corrected_from_name` (the name the line carried when first corrected, the key a re-sort matches on),
`evidence_offset`, `mention_text`, `mention_offset`. **Breaking for readers:** `score` is **NULLABLE** —
unscored is the normal case; `reviews_score_halfstep` is untouched (a NULL CHECK passes). A sorter-written
line inherits the entry's `created_at`, so `reviews.created_at` IS the visit's date.
**Multiple reviews per (user, dish) remain allowed by design** (sittings). No constraint, ever.

### `saves` (0020)
`(user_id, dish_id)` **PK** + `source_entry_id` (→ entries, SET NULL), `source_user_id` (→ profiles,
SET NULL), `created_at`. A DISH at its restaurant with provenance ("from @jessw"), private to the saver.

### `blocks` (0019)
`(blocker_id, blocked_id)` PK, no self-block. One-way, enforced **both ways** by `blocked_with(uuid)` (SECURITY DEFINER — it reads `blocks` without recursing through RLS).

### `reports` (0019, 0028)
`id`, `reporter_id`, exactly one of `entry_id` / `profile_id` (CHECK), `reason`, `note`,
`status ∈ (open, actioned, dismissed)`. Reporter-visible only; triaged with the service role. 0028 closes
`reason` to `spam | abuse | wrong_place | not_food | other` or **NULL**; the CHECK is `NOT VALID` (new rows
only — real reports are never rewritten to validate it). The RPCs lower-case + trim; anything else is `23514`.

### `profiles` — changed (0018)
Additive: `entry_seq` int (the order-number counter; never client-writable), `city` text (under the handle on You/Profile). `username` is `citext UNIQUE` — the handle.
`delete_account()` (0032) deletes the auth user; FK cascades take every personal row, the catalogue stays (`dishes.created_by_user_id` → NULL). New users: `handle_new_user` never raises; no usable email ⇒ handle `ate<8 hex>`.

## Unchanged from Wave 0

`restaurants` (Google-Places-backed, `source ∈ (places, manual)`, `google_place_id` partial-unique
`WHERE NOT NULL`, PostGIS `location`; `city` is a bare suburb on stub/manual rows but a mangled
`"<street>, <suburb STATE post>"` on live `op=details` rows — read `place_locality()`, never `city`, for a
label; `places-search` stores a bare suburb from 0031's PR on, forward-only, no backfill) · `dishes` (UGC, identity `(restaurant_id, lower(name))` partial unique
`WHERE merged_into_dish_id IS NULL`, merge tombstones) · storage buckets `review-photos` + `avatars`
(public-read via the **bucket flag**, own-folder write).

**Dormant in V1** (applied, unread, untouched): `comments`, `review_likes`, `comment_likes`, `follows`, `lists`, `list_dishes`, `review_tags`, `notifications`.

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
7. **Changing an RPC's parameters OR its OUT columns means DROP-then-CREATE** (then re-grant). `create or
   replace` on a new parameter silently leaves a SECOND overload → every named-argument call is `42725`.
8. **A correction is user data.** Never re-derive over a row with `corrected_at`/`place_corrected_at`,
   and never "clean up" one. A re-sort replaces the sorter's lines and nothing else.

## Derived reads (never stored)

| View | Columns | Notes |
|---|---|---|
| `dish_stats` | `dish_id, restaurant_id, score, review_count, cover_url, scored_count, people_count` | `score` = avg of non-null scores (NULL = nobody scored it); `people_count` = distinct reviewers |
| `restaurant_stats` | `restaurant_id, avg_rating, review_count, cover_url, people_count, dish_count` | `avg_rating` = **mean of per-dish averages**, null-score dishes excluded |
| `entry_cards` | the one entry shape (see `integration-design.md`) | Journal slip / Feed slip / Entry page / Share receipt are all this row; carries the token offsets + `items[].corrected` + `items[].cover_url` |
| `my_saved_dishes` | saved dish + place + dish aggregate + provenance handle | caller-scoped; page on the keyset `(saved_at desc, dish_id desc)`. `cover_url` == the older `dish_cover_url` |

**`cover_url` comes from the photos we actually have (0026).** `dish_cover_url(dish)` /
`restaurant_cover_url(restaurant)` are the single derivation, live (nothing stored, so nothing stale): the
newest visible review that HAS a photo, where a photo is `coalesce(reviews.photo_url, the first
entry_photo of that review's entry)`. `dish_photos(dish)` (0029) is the same ranking as a list, so
`photos[0].url` == `cover_url`. An entry with photos but no dish lines covers nothing: no review row.

All are `security_invoker = true`, so **aggregates are viewer-relative — through blocks only**: every entry
is public (0033), so the one thing RLS hides is a blocked author (either direction), whose lines count in
nobody's numbers or covers but their own.

**The read RPCs, and what each number COUNTS** (wire shapes + cursors: `integration-design.md`). All are
SECURITY INVOKER, so every count is viewer-relative and a NULL score is never a zero. Revised in 0029
except where noted; **entries = visits, reviews = receipt lines, and they are not interchangeable**:

| RPC | What it returns / counts |
|---|---|
| `place_summary(place)` | the header in one call. `entry_count` = VISITS here, `review_count` = LINES (18 lines from 8 visits at Tipo 00 — printing the wrong one is a lie); `my_visits`/`my_last_visit` = the "Your N visits" row; `locality` = `place_locality(address, city)`; `avg_rating` = mean of per-dish averages; empty text arrives as NULL, never `''` |
| `place_dishes(place, …)` | "what to order", and the order is the ported `DishRanking` rule (0030): `review_count` desc → `score` desc (unscored last) → name → id. **Review count LEADS** — one 5.0 from one person must not lead a menu. A dish with NO line is excluded (an abandoned "add a new dish" shell); an unscored dish WITH a line stays. 4-part keyset |
| `dish_summary(dish)` | dish + place + aggregates + `photos` (`photos[0].url` == `cover_url`) + the viewer's `saved` / `my_last_score`. A dish's "orders" IS `review_count`: one entry prints one line per dish |
| `get_dish_reviews(dish, …)` | one row per LINE, the caller's own first then newest (3-part keyset). `entry_id` is **NULL on a pre-entries line**; `photos[]` is the review's ENTRY's, so it can hold another dish's photo |
| `get_entries_at_place(place, scope, …)` | `setof entry_cards` — the ONE entry shape, never review rows. `scope ∈ mine\|others\|all` |
| `get_entries_by_author(author, …)` | `setof entry_cards`. Every entry is public (0033): yours and a stranger's read the same; a blocked author reads empty |
| `profile_summary(user)` | `orders`/`places` count ENTRIES (visits, distinct places). `dishes`/`scored`/`avg_score` count LINES **by `reviewer_id`**, pre-entries lines included — so You and Ratings can no longer disagree (they did: 40 vs 60) |
| `score_histogram(user)` | ten half-step buckets, zeros included, by `reviewer_id`. `dish_count` = distinct dishes at that score (the "36 dishes" label), `review_count` = times given. Unchanged |
| `dishes_by_score(user, score, …)` | one row per LINE at exactly that score, newest first, + the dish's `cover_url` for the tile. `created_at` is the VISIT's date. Keyset `(created_at, id)` |
| `statement_months(user, tz, …)` | the months that have a statement, newest first, + each month's ENTRY count. Keyset on `month` |
| `monthly_statement(user, month, tz)` | one jsonb. orders/places/new_places count ENTRIES; dishes/stars/average cover scored LINES; `most_ordered`/`most_visited` are **NULL below a count of 2** — once is not a habit |
| `is_dish_saved(dish)` | the caller's own save state. The same answer as `dish_summary.saved` and `entry_cards.items[].saved`; unchanged |
| `search_places` · `search_dishes` · `search_people` (0031) | the Search tab's scopes. Match = `search_key()` (trimmed, **accent-folded**, lower) substring, ≥2 chars; ranked by `match_tier` (0 exact · 1 prefix · 2 word-start · 3 contains), then `review_count` desc (people: handle). A dish needs ≥1 line the viewer can see. Keysets are 4/4/3-part |
| `search_saved(query, …)` · `nearby_places(lat, lng, …)` (0031) | Saved scope = `my_saved_dishes`' row + `restaurant_locality`, empty query = the whole list, keyset `(saved_at, dish_id)`. Nearby = places we hold + viewer-relative score, PostGIS only, keyset `(distance_m, restaurant_id)` |
| `my_blocks(…)` (0032) | whom the caller blocked, with handle/name/avatar. DEFINER: `profiles` RLS hides exactly these people |

## RLS

Enabled on every table. Reads are authenticated-only; `anon` is revoked on all V1 tables.

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `entries` | own, or not blocked (0033) | self | self (cols `body, visibility` only) | self |
| `entry_photos` | parent entry visible | parent entry is own | own | own |
| `reviews` | own, or not blocked (0033) | author | author | author |
| `profiles` | self, or not blocked | self | self | — (`delete_account()` RPC, 0032) |
| `saves` | own | own | own | own |
| `blocks` | rows you created | self as blocker | — | self as blocker |
| `reports` | own | self | — | — |
| `restaurants` / `dishes` | all | dishes: authed (self-attributed); restaurants: none (RPC/service role) | none | none |

The block filter is expressed **once**, in `blocked_with()`, applied in the SELECT policies of `profiles`,
`entries` and `reviews` — so blocked users vanish from feed, journal, profile, place and dish reads in both
directions without any query having to remember.

**Column privileges do what RLS cannot:** `authenticated` may INSERT only
`(id, author_id, body, visibility, restaurant_id, created_at)` on `entries` and UPDATE only
`(body, visibility)`. `order_number`, every `sort_*`, `restaurant_source` and 0024's `place_*` are
unwritable by clients on every path — the trigger and the 0021/0024 RPCs are their only writers.
`restaurant_id` is insertable (the composer's pick) but not updatable: place corrections go through
`correct_entry_place`, which re-resolves the dishes. `reviews` has no column grants, so an author can PATCH
their own `score`/`note` — the sanctioned path, recorded by the correction trigger. Nothing beyond those.

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
| 0024–0025 | `corrections_and_offsets.sql` · `entry_cards_offsets.sql` | correction provenance + the preservation rule in `apply_entry_sort` (dropped/recreated with `p_place_query`/`p_place_offset`); `verified_offset`; the correction trigger; dish display-name normalisation; `entry_cards` + `place_offset`/`place_length` + `items[].evidence_*`/`mention_*`/`corrected` |
| 0026–0027 | `entry_photo_covers.sql` · `unsave_entry_dishes.sql` | `dish_cover_url`/`restaurant_cover_url` (covers now see `entry_photos`); `my_saved_dishes` + `cover_url`; `entry_cards.items[]` + `cover_url`; `unsave_entry_dishes` + the Saved keyset index |
| 0028 | `report_reason.sql` | `reports_reason_ck` (NOT VALID) + reason normalisation in `report_entry`/`report_profile` |
| 0029 | `detail_you_reads.sql` | the Place/Dish/You/Ratings/Recap audit: `place_locality`, `dish_photos`; `place_summary` + `locality`/`entry_count`; `dish_summary` + `photos`/`restaurant_locality`; `dishes_by_score` + `cover_url` + cursor; cursors on `place_dishes`/`statement_months`; `profile_summary` counts lines by `reviewer_id`; `monthly_statement` + `username`, no x1 "most ordered" |
| 0030 | `place_dishes_order.sql` | "what to order" becomes the ported `DishRanking` order (review_count desc → score desc nulls last → name → id), never-logged dishes excluded, keyset rewritten to match (`p_cursor_people` → `p_cursor_review_count`) |
| 0031 | `search_scopes.sql` | `unaccent` + `search_key`/`search_pattern`/`search_tier` + folded-name trigram indexes; `search_places`/`search_dishes`/`search_people`/`search_saved`/`nearby_places`; `search_all` accent-folded, place subtitle via `place_locality` |
| 0032 | `apple_auth_account_blocks.sql` | `handle_new_user` Apple-safe (NULL email, relay address, never raises); `delete_account()` (App Store 5.1.1(v)); `my_blocks()` |
| 0033 | `entries_always_public.sql` | **flips every private entry public (prod data)**, undo list in `entries_private_before_0033`; trigger pins `public`; `entries`/`reviews` SELECT = own or not blocked; feed drops its filter; total feed index |
