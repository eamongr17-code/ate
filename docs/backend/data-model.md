# Ate — data model (V1)

**Status:** the schema as `supabase/migrations/0001–0060` define it (0060 drafted, not yet applied). Forward-only; applied migrations
are never edited. V1 re-scope **0018–0023**; corrections + offsets **0024–0025**; covers, save toggle,
report vocabulary **0026–0028**; detail + You audit **0029–0030**; Search scopes **0031**; Apple sign-in +
account deletion **0032**; **every entry public 0033**; signed-out browse **0034**; dietary tags **0036**;
round 3 (delete entry, Feed areas, early sort, place required) **0037–0040**; round 4 (secret 6, search filters, journal, six carry, dish-row chips) **0041–0045**; round 5 (cities, range + city filters, share read, saved filters) **0046–0049**; round 6 (date windows, menu by rating) **0050–0051**; read scale **0052**; round 7 (journal calendar, dish tags) **0053**; round 8 (the Feed edition, cravings) **0055**; faster logging **0056**; the tag page **0057**; diet **0074**.

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
| 7 — a score is only ever the user's, never inferred | `reviews.score` is NULLABLE; `apply_entry_sort` drops any score whose `score_evidence` is not a literal substring of `entries.body`. **The secret 6 (0041)** exists only on a span the client marked (`six_tokens`) — a typed "6" is never a score. A re-sort keeps a line's 6 on the rebuilt line matched to it (as tags are) while that line's evidence span — same distance from its mention — still reads a lone 6 (0044) |
| 8 — a place attaches only when named or tapped | `restaurant_source ∈ (user, sorter)`, CHECKed with `restaurant_id`; no code path reads location. **A new entry must carry one** (0040 INSERT trigger → `23502 place_required`); pre-0040 placeless rows stay legal |
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
| `sort_plan` | jsonb NULL | last validated plan, a jsonb ARRAY (the parked plan). Internal; not on the read view |
| `sort_meta` | jsonb NULL | 0039: `{cache_hit, model}` — did the sort reuse a preview's model plan. Internal |
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
unscored is the normal case; `reviews_score_halfstep` passes NULL, 0.5–5.0 in half steps, or **exactly 6** (0041; 5.5 is `23514`). A sorter-written
line inherits the entry's `created_at`, so `reviews.created_at` IS the visit's date.
**Multiple reviews per (user, dish) remain allowed by design** (sittings). No constraint, ever.
**`tags` text[] NOT NULL `{}` (0036, 0084)**: dietary codes, CHECK `reviews_tags_closed_set` (`<@ {gf,df,v,vg,nf,pe,ha,ef,pf,sf}`,
else `23514`), trigger-canonicalised (lower, deduped, list order, NULL → `{}`). The USER'S, never inferred:
the author's PATCH (owner-only RLS; not a correction) or client-marked tag tokens via the sorter. **A re-sort
never removes a tag** — a rebuilt line inherits its predecessor's (R3 matching). Not `review_tags` (people).
**`diet_tags`, `diet_off` text[] NOT NULL `{}` (0074)**, closed set, server-owned (a client write of either is
ignored): `diet_tags` = the codes of `tags` that came from the author's diet (CHECK `⊆ tags`); `diet_off` = diet
codes turned off on this line. `apply_entry_sort` stamps a NEW line with `profiles.diet` less its `items[].diet_off`;
an inherited (T3, now matched against every replaced line) or corrected line is never re-stamped. Trigger
`reviews_tags_diet`: a diet code leaving `tags` moves to `diet_off`, one coming back returns to `diet_tags`.

### `saves` (0020)
`(user_id, dish_id)` **PK** + `source_entry_id` (→ entries, SET NULL), `source_user_id` (→ profiles,
SET NULL), `created_at`. A DISH at its restaurant with provenance ("from @jessw"), private to the saver.

### `blocks` (0019) · `reports` (0019, 0028)
Blocks: `(blocker_id, blocked_id)` PK, no self-block. One-way, enforced **both ways** by `blocked_with(uuid)` (SECURITY DEFINER — it reads `blocks` without recursing through RLS).
Reports: `id`, `reporter_id`, exactly one of `entry_id` / `profile_id` (CHECK), `reason`, `note`,
`status ∈ (open, actioned, dismissed)`. Reporter-visible only; triaged with the service role. 0028 closes
`reason` to `spam | abuse | wrong_place | not_food | other` or **NULL**; the CHECK is `NOT VALID` (new rows
only — real reports are never rewritten to validate it). The RPCs lower-case + trim; anything else is `23514`.

### `sort_preview_cache` · `sort_preview_rate` (0039)
Server-internal (RLS on, no policy, service_role only; cascade from `auth.users`). The cache: the model's RAW
draft plan (verbatim draft text), PK `(author_id, cache_key)` (total — upserted), 15-min `expires_at`; key =
sha256(sha256(body), tag_tokens, restaurant_id, model[, six_tokens when marked]). Rows are DELETED: bounded purge of expired rows on every
preview, the consuming sort deletes its row, an entries-delete trigger purges the author's. Rate: 12 / 10 min. **0056:** `plan` NULL = a pending claim (a preview is calling the model); the sort waits ≤ 3 s for it; stale after 15 s.

### `cities` (0046)
Reference data, seeded and changed by migration only: `id` text slug PK (`melbourne`, `gold-coast`), `name`,
`region` (state code), `country`, `center` geography point, `radius_m`, `aliases` text[] (lower-case localities
that mean this city, e.g. `cbd`). Authenticated SELECT; anon none. **A place's city is derived on read, never
stored** (view `place_cities(restaurant_id, city, via)`): its location (nearest centre whose radius holds it) →
else its `place_locality()` equals a city name/alias → else the city most LOCATED places with that locality
fall in. A place none of these reach is in no city. **Stored since 0052** in `place_city_cache` (loc, geo, city, via), kept
exact by triggers: a place's own row on insert/update/delete plus every place sharing its locality; any change to
`cities` rebuilds it. `place_cities` reads it. Catalogue data only — nothing viewer-relative is cached.
**Any future change to `place_locality()`, `city_at()` or the city rule itself must call `place_city_rebuild()`** in the
same migration — the triggers only notice writes to `restaurants` and `cities`, not a changed function.

### `chains` (0085)
A chain is one place for dishes. `restaurants.chain_id` → `chains` (name, `website_host`, `anchor_restaurant_id`). **A chain's dishes all live at its anchor**, so dish identity, `merge_dish` and `reviews.restaurant_id == dishes.restaurant_id` are unchanged; `entries.restaurant_id` keeps the exact location. **Every place read and dish write goes through `place_menu(place)`** (anchor, else itself); "entries here" / visits use `place_family(place)` (every location). A chain dish shows no suburb (`dish_locality`). Linked automatically: same `dish_key(name)` + same Google website host (a shared social/ordering host never links), via `chain_candidates` → `chain_record_and_link` (places-search in the background; the Prod apply's backfill). `chain_attach` merges a joining location's dishes onto the menu (`dish_merges.reason='chain'`); `chain_detach`/`chain_dissolve` undo it. Service role only.

### `dish_tag_links` (0053)
A dish's chips. PK `(dish_id, kind, slug)` (TOTAL — the ON CONFLICT arbiter the writers use), `label`, `source`, `ord`; index `(kind, slug, dish_id)`.
Catalogue data (authenticated SELECT, no client write). **Diet chips are NOT stored**: `dish_tags` reads `dish_consensus_tags()` live, so they always equal `dish_summary.tags`.
- `cuisine` / `suburb` / `city` (`source='place'`): derived from the dish's restaurant. Triggers keep them exact on dish insert/rename, restaurant `cuisine` change, every `place_city_cache` change and any `cities` change.
  - suburb = `place_locality()`, slug city-qualified (`fitzroy-melbourne`), omitted when it IS the city.
  - city = the 0052 cache's city, label `cities.name`.
- `style`, only from the fixed list of 40 (`dish_style_list()`, 0069; identical to `DISH_STYLES` in `styles.ts`):
  - `source='keyword'` comes from `dish_style_guess(name)`, a fixed keyword map applied on dish insert and in the backfill. No model.
  - `source='sorter'` comes from sort-entry's `items[].styles` through `apply_entry_sort` (and `correct_entry_place` for a parked plan). A dish's first sorter styles replace its keyword ones; later sorts add up to 3 and never remove one.
  - A word not on the list is dropped (`dish_style_clean` via `dish_styles_from_json`, mirrored in `styles.ts`; the model gets the list as a schema enum).
  - **Changing the keyword map means a migration that re-runs `dish_style_keyword_refresh()`.**

### `user_cravings` (0055)
`(user_id, kind, slug)` **PK** (total), `label`, `position` (shelf order), `created_at`; kind ∈ the round-7 tag kinds. The tags a viewer follows — one Feed shelf each. Owner-read under RLS; **no client write grant**: `set_cravings` (DEFINER) replaces the whole set, accepting only a tag a dish carries now (or one already followed — so a re-save never fails). Cascades from `profiles`; `delete_account` verifies it.

### Ate with — `entry_companions` · `entry_invites` · `device_push_tokens` (0058)
`entry_companions`: a person the author tagged on their entry; `status` pending → accepted (`response_entry_id` = the companion's OWN linked entry, UNIQUE, SET NULL if they delete it) | declined (sticky). UNIQUE `(entry_id, companion_id)` (total). Parties-only SELECT. `entry_invites`: sha256(token) only (UNIQUE, total), 14-day `expires_at`, single use → a companions row; inviter-only SELECT. `device_push_tokens`: `token` PK (total, the register upsert target), `apns_env` sandbox | production; owner SELECT/DELETE. No client write grant on any — RPCs only. `notifications` (0011) gains type `ate_with` + `companion_id` (cascade) + `pushed_at`. Cap 6 seats/entry (a decline keeps its seat); 40 tags+invites/day spent from `ate_with_ledger` (append-only, server-internal, serialised per actor; a same-day re-tag is quiet only when the untagged tag had been pushed or read — `ate_with_ledger.delivered`, set by untag); a new block withdraws pending tags. `entry_cards.companions` is the public projection (`entry_with_people`, DEFINER, viewer-relative).

### Lists — `user_lists` · `user_list_items` (0060)
`user_lists` (owner, name trimmed 1–80, `visibility` CHECK = `private` — a public flag is additive; ≤ 50/owner). `user_list_items` (list, owner, `entry_id`, `dish_id`, dense `position` 1…n, ≤ 100/list; UNIQUE `(list_id, entry_id, dish_id)` total). The grain is a visit's dish line, not `reviews.id` (a re-sort re-mints those): a trigger carries items across a dish change; a DEFERRED constraint trigger drops them at commit when the entry no longer prints that dish. Owner SELECT; no client write — RPCs only. The legacy `lists`/`list_dishes` stay dormant (`lists` still gets a system row per sign-up); 0060 made their SELECT owner-only (was `using (true)`).

### `user_awards` — plate awards (0098)
`(user_id, award)` **PK** (total) — each award once, never revoked (deleting the entry only nulls its links). `award` CHECK = the 20 ids (`dishes_1…500`, `first_5`/`first_6`/`first_half`, `first_drink`, `first_dessert`, `new_country`, `ate_with`, `saved_by_someone`, `saves_10`, `same_dish_3`, `five_in_entry`, `three_in_day`, `five_at_place`). `earned_at` = the earning line/entry/save's time, not the check's. What earned it: `entry_id`, `dish_id` (SET NULL), `entry_ids[]`/`dish_ids[]` (group awards), `other_user_id` (ate with / saved by). `seen_at` null = the takeover owes it (partial index). RLS on, **no client grant at all**; `award_check(user)` (DEFINER, idempotent) earns from the person's own rows, fired by statement/row triggers on reviews, entries, saves, entry_companions, dish_tag_links via `award_check_quiet` (a failure is a WARNING, never the write's error). "3 in a day" counts Melbourne days; "new country" = the last comma part of the place's address. Cascades from `profiles`; `delete_account` verifies it.

### `profiles` — changed (0018)
Additive: `entry_seq` int (the order-number counter; never client-writable), `city` text (under the handle on You/Profile). `username` is `citext UNIQUE` — the handle.
`delete_account()` deletes the auth user; FK cascades take every personal row (verified, else it RAISES — 0035), the catalogue stays. `handle_new_user` always leaves a profile (handle `ate<hex>` when no usable email). `deleted_at` hides a profile from everyone but its owner (0035).
**`diet` text[] NOT NULL `{}` (0074)**: what the person always eats, closed set, canonical, stored as picked (vegan = `{vg}`); owner PATCH.

## Unchanged from Wave 0

`restaurants` (Google-Places-backed, `source ∈ (places, manual)`, `google_place_id` partial-unique
`WHERE NOT NULL`, PostGIS `location`; `city` may be a mangled `"<street>, <suburb STATE post>"` on rows
resolved before 0031's PR — read `place_locality()`, never `city`) · `dishes` (UGC, identity `(restaurant_id, lower(name))` partial unique
`WHERE merged_into_dish_id IS NULL`, merge tombstones) · storage buckets `review-photos` + `avatars`
(public-read via the **bucket flag**, own-folder write — any name under `<uid>/`, so round 3's `_t.jpg`
thumbnails need no policy). **Dormant in V1:** `comments`, `review_likes`, `comment_likes`, `follows`, `lists`, `list_dishes`, `review_tags`, `notifications`.

**Staging dummy data (round 6)** lives outside the chain in `supabase/staging-seed/` (generator, `setup.sql` registry + guard, `remove.sql`): staging only, every row it made listed in `staging_seed.registry` by batch (`r6` = the dataset; `ci` = the read-only contract-test account `ci@ate.test`, `seed.mjs --ci-account`).

## Landmines — do not re-learn

1. **PostgREST upsert needs a TOTAL unique constraint.** A partial index cannot be an `ON CONFLICT`
   arbiter (the 0014/0016 incident). Safe targets: `entry_photos (entry_id, position)`,
   `saves (user_id, dish_id)`, `blocks (blocker_id, blocked_id)`, `entries (author_id, order_number)`.
2. **`dishes_identity_uq` is PARTIAL BY DESIGN.** Dish creation is **select-then-insert** —
   `find_or_create_dish()` (0021), which catches `unique_violation` and re-selects. Never `ON CONFLICT`.
   **0071:** it resolves exact name → a merged-away name (alias of its survivor) → the same `dish_key()`
   (spelling key, mirrored by sort-entry `same-dish.ts`) → new. Model matching lives only in sort-entry
   (`same_as`, behind `sameDishGate`), and merges only through `merge_dish` (logged, `unmerge_dish` undoes).
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
| `entry_cards` | the one entry shape (see `integration-design.md`) | Journal slip / Feed slip / Entry page / Share receipt are all this row; carries the token offsets + `items[].corrected` / `cover_url` / `tags` |
| `my_saved_dishes` | saved dish + place + dish aggregate + provenance handle | caller-scoped; page on the keyset `(saved_at desc, dish_id desc)`. `cover_url` == the older `dish_cover_url` |

**`cover_url` comes from the photos we actually have (0026).** `dish_cover_url`/`restaurant_cover_url` derive it
live: the newest visible review with a photo (`review_photo_url`, 0079: the line's own photo; its entry's first photo
only when it is the entry's only line; never another dish's).
`dish_photos(dish)` (0029) is the same ranking as a list (`photos[0].url` == `cover_url`).

Since 0052 `dish_stats`/`restaurant_stats` are **per-row LATERAL** views (same columns and values): a join computes only the
rows it needs. The Search reads compute numbers per hit (`place_numbers`/`dish_numbers`, optional `[start, end)`) and covers
per returned page only; a date window is a timestamp range from `window_bounds()` (in_window's day rule).

All are `security_invoker = true`, so **aggregates are viewer-relative — through blocks only** (every entry is
public, 0033): a blocked author's lines count in nobody's numbers or covers but their own.

**The read RPCs, and what each number COUNTS** (wire shapes + cursors: `integration-design.md`). All are
SECURITY INVOKER, so every count is viewer-relative and a NULL score is never a zero. Revised in 0029
except where noted; **entries = visits, reviews = receipt lines, and they are not interchangeable**:

| RPC | What it returns / counts |
|---|---|
| `place_summary(place)` | the header in one call. `entry_count` = VISITS here, `review_count` = LINES (18 lines from 8 visits at Tipo 00 — printing the wrong one is a lie); `my_visits`/`my_last_visit` = the "Your N visits" row; `locality` = `place_locality(address, city)`; `avg_rating` = mean of per-dish averages; empty text arrives as NULL, never `''`; `lat`/`lng`/`google_place_id` for Maps (0095), NULL with no point |
| `place_dishes(place, …)` | "what to order", ranked **by rating (0051, Eamon)**: printed `score` desc (a 6 above every 5) → `review_count` desc → name → id; unscored after every scored dish. A single 5.0 now leads (0030's review-count-first `DishRanking` rule is retired). A dish with NO line is excluded (an abandoned "add a new dish" shell); an unscored dish WITH a line stays. 4-part keyset. `tags` (0045) = the `dish_summary.tags` rule; `search_dishes` rows carry it too (0042); `diet_counts` (0074) as `dish_summary` |
| `dish_summary(dish)` | dish + place + aggregates + `photos` (`photos[0].url` == `cover_url`) + the viewer's `saved` / `my_last_score`. A dish's "orders" IS `review_count`: one entry prints one line per dish. **`tags`** = the diet LABELS (`dish_consensus_tags`, 0074; 0036's half-of-lines rule is retired): code c when ≥ `dish_label_min_people()` (3) different people's visible lines from the last `dish_label_window()` (12 months) carry it — `vg` also counts as `v` and `df` — and no such line has c in `diet_off`. **`diet_counts`** jsonb (0074) = `{c: people}` for 0 < people < 3 |
| `get_dish_reviews(dish, …)` | one row per LINE, the caller's own first then newest (3-part keyset). `entry_id` is **NULL on a pre-entries line**; `photos[]` is the review's ENTRY's, so it can hold another dish's photo |
| `get_entries_at_place(place, scope, …)` | `setof entry_cards` — the ONE entry shape, never review rows. `scope ∈ mine\|others\|all` |
| `get_entries_by_author(author, …)` | `setof entry_cards`. Every entry is public (0033): yours and a stranger's read the same; a blocked author reads empty |
| `profile_summary(user)` | `orders`/`places` count ENTRIES (visits, distinct places). `dishes`/`scored`/`avg_score` count LINES **by `reviewer_id`**, pre-entries lines included — so You and Ratings can no longer disagree (they did: 40 vs 60) |
| `score_histogram(user)` | **eleven** buckets — ten half steps, then 6.0 (0041) — zeros included, by `reviewer_id`. `dish_count` = distinct dishes at that score (the "36 dishes" label), `review_count` = times given. A 6 counts as 6 in every average and ranking; nothing caps at 5 |
| `dishes_by_score(user, score, …)` | one row per LINE at exactly that score, newest first, + the dish's `cover_url` for the tile. `created_at` is the VISIT's date. Keyset `(created_at, id)` |
| `statement_months(user, tz, …)` | the months that have a statement, newest first, + each month's ENTRY count. Keyset on `month` |
| `monthly_statement(user, month, tz)` | one jsonb. orders/places/new_places count ENTRIES; dishes/stars/average cover scored LINES; `most_ordered`/`most_visited` are **NULL below a count of 2** — once is not a habit |
| `is_dish_saved(dish)` | the caller's own save state. The same answer as `dish_summary.saved` and `entry_cards.items[].saved`; unchanged |
| `search_places` · `search_dishes` · `search_people` (0031) | the Search tab's scopes. Match = `search_key()` (trimmed, **accent-folded**, lower) substring, ≥2 chars; ranked by `match_tier` (0 exact · 1 prefix · 2 word-start · 3 contains), then `review_count` desc (people: handle). A dish needs ≥1 line the viewer can see. Keysets are 4/4/3-part. **Filters (0042)** on places/dishes/`nearby_places`: `p_cuisines` (any, case-insensitive), `p_tags` (a DISH's consensus chips carry every code; a PLACE matches if one of its dishes does), `p_min_score` (the printed aggregate); NULL/empty = off, keysets unchanged. `search_cuisines()` = the choices |
| `search_saved(query, …)` · `nearby_places(lat, lng, …)` (0031) | Saved scope = `my_saved_dishes`' row + `restaurant_locality`, empty query = the whole list, keyset `(saved_at, dish_id)`. Nearby = places we hold + viewer-relative score, PostGIS only, keyset `(distance_m, restaurant_id)` |
| `my_blocks(…)` (0032) | whom the caller blocked, with handle/name/avatar. DEFINER: `profiles` RLS hides exactly these people |
| `feed_areas(limit, cursor…)` (0038) | `place_locality()` of the entries the Feed shows you (own excluded), grouped case-insensitively; keyset `(entry_count desc, area)`, 30 a page. `get_entry_feed(…, p_area)` filters on the same string |
| `feed_cities()` · `resolve_city(lat, lng)` (0046) | cities the Feed has entries in for you (feed_areas' counting), busiest first · "near me": the city with food holding the point (`is_nearby`), else nearest with food, else (no point) busiest; no row when no city has food. `get_entry_feed(…, p_city)` filters on `place_cities` |
| range + city filters (0047) | `p_max_score` + `p_city` on `my_entries`/`search_places`/`search_dishes`/`nearby_places`. `score_in_range`: no bound = all; any bound drops unscored; **max ≥ 6 is open** (0054: the track ends at 6 — a ceiling of 5 leaves a 6, or a 5.3 average, out). `my_entry_cities()` · `search_cities()` = the pickers. **0049:** the same on `search_saved` (on `dish_score`) + `my_saved_cities()` |
| date windows (0050) | `p_from`/`p_to`/`p_tz` on `search_places`/`search_dishes`/`nearby_places` (only lines whose visit day is in the window count toward the row's numbers; a row with none drops out; cover + chips stay all-time) and `search_saved` (the save's day). my_entries' rule, `in_window()` |
| `get_entry_card(entry)` (0048) | one `entry_cards` row or `[]`; signed in = the view under RLS, anon = browse twin (public, live author) — the share-link read |
| `my_entries(sort, filters…)` · `my_entry_places()` (0043) | the caller's OWN entry ids (filtered by `author_id = auth.uid()`, not just RLS): `newest`/`oldest` keyset `(created_at, id)`, `top` = `best_score` (max line score) desc NULLS LAST, then `(created_at, id)` desc. Filters: place, min best score, one tag, visit dates in `p_tz`. Places = where your entries are, busiest first |
| `journal_days(from, to, tz, …)` · `my_entries_count(…)` (0053) | the calendar: per local day with the caller's entries, `entries` (ENTRY count), `best_score` (max line score, a 6 is 6), `cover_url` (newest entry that day with a photo). The count = rows `my_entries` pages out. Both take `my_entries`' filters (`my_entries_filtered`, one definition) |
| `dish_tags(dish)` · `similar_dishes(dish)` · `dishes_by_tag(kind, slug, …)` (0053) | chips style → cuisine → suburb → city → diet · dishes sharing a style or the cuisine, by weight (style 8 · cuisine 4 · suburb 2 · city 1) then score · a tag's dishes in `place_dishes`' order + 4-part keyset. Numbers = lines the viewer can see; never-logged and merged dishes excluded |
| `top_ate` · `because_you_loved` · `new_to_record` · `craving_options` (0055) | the Feed edition. Top Ate: dishes with a line in 7 days (→ 30 → all time when short; one ranked list) by ALL-TIME printed score, scored by ≥ 2 DIFFERENT people, photo only a tie-break. Loved: anchor = your newest 5.0/6 dish, rows = `similar_dishes`' rule in the city minus dishes you logged. New: others' lines after `p_since` (≤ 90 days back) — a 6, a 5.0, or a dish's first line. Options: style + cuisine tags on logged dishes. `dishes_by_tag` + `p_city`, + `saved`. The city is `city_places()` (0052's cache) once per call; covers only for rows that can make the page |
| `delete_entry(entry)` (0037) | owner-only, DEFINER. FK cascades take photos rows, lines (+ tags, likes, comments, notifications), reports; saves keep the dish (`source_entry_id` → NULL); catalogue stays. Returns the files to purge |

## RLS

Enabled on every table. Table reads are authenticated-only; `anon` has NO table grant. Signed-out browse (0034) is
nine RPCs (+ `feed_areas`, `feed_cities`, `get_entry_card`, 0055's `top_ate`, `new_to_record`, `craving_options`; `resolve_city` rides `feed_cities`) that dispatch on `current_user = 'anon'` to DEFINER twins in the unexposed `browse` schema.

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `entries` | own, or not blocked (0033) | self, `restaurant_id` required (0040) | self (cols `body, visibility` only) | self (or `delete_entry`) |
| `entry_photos` | parent entry visible | parent entry is own | own | own |
| `reviews` | own, or not blocked (0033) | none (sorter / RPCs, 0094) | author, col `tags` only (0094) | none (0094) |
| `profiles` | self, or (not deactivated AND not blocked); every column but `diet` (own via `my_diet()`, 0094) | none (`handle_new_user`) | self (cols `username, name, avatar_url, bio, city`, `diet` 0074) | — (`delete-account` function → `delete_account()`) |
| `saves` | own | own | own | own |
| `blocks` | rows you created | self as blocker | — | self as blocker |
| `reports` | own | self | — | — |
| `cities` (0046) | all (authenticated) | none | none | none |
| `user_cravings` (0055) | own | none (`set_cravings`) | none | none (`set_cravings`) |
| `user_lists` · `user_list_items` (0060) | own | none (RPCs) | none | none (RPCs) |
| `restaurants` / `dishes` | all | none: `find_or_create_dish` / `add_manual_restaurant` (≤ 20 a day) / service role (0094) | none | none |

The block filter is expressed **once**, in `blocked_with()`, applied in the SELECT policies of `profiles`,
`entries` and `reviews` — so blocked users vanish from feed, journal, profile, place and dish reads in both
directions without any query having to remember.

**Column privileges do what RLS cannot:** `authenticated` may INSERT only
`(id, author_id, body, visibility, restaurant_id, created_at)` on `entries` and UPDATE only
`(body, visibility)`. `order_number`, every `sort_*`, `restaurant_source` and 0024's `place_*` are
unwritable by clients on every path — the trigger and the 0021/0024 RPCs are their only writers.
`restaurant_id` is insertable, not updatable (`correct_entry_place` re-resolves the dishes). `reviews` has
no column grants: an author PATCHes their own `score`/`note`/`tags` — the sanctioned path (`diet_tags`/`diet_off` follow `tags` by trigger, 0074).

## Migration index

| # | File | What |
|---|---|---|
| 0001–0017 | — | Wave 0 core, RLS, views, storage, Places, manual restaurants, search blend |
| 0018 | `entries.sql` | entries + entry_photos; reviews.entry_id/entry_position/score_evidence; score nullable; profiles.entry_seq/city; order-number trigger; RLS + column grants |
| 0019–0021 | `moderation` · `saves` · `sort_write_path` | blocks + reports, `blocked_with`, block-aware SELECT · saves + `my_saved_dishes` · `find_or_create_dish`, `apply_entry_sort`, `mark_entry_sort_failed`, `correct_entry_place`/`_dish` |
| 0022–0025 | `entry_reads` · `stats_search` · `corrections_and_offsets` · `entry_cards_offsets` | `entry_cards` + readers; `profile_summary`, histogram, statements, `search_all` · correction provenance + preservation rule; `verified_offset`; token offsets + `corrected` |
| 0026–0029 | `entry_photo_covers` · `unsave_entry_dishes` · `report_reason` · `detail_you_reads` | covers see `entry_photos` · `unsave_entry_dishes` · `reports_reason_ck` (NOT VALID) · the Place/Dish/You audit: `place_locality`, `dish_photos`, cursors, `profile_summary` by `reviewer_id` |
| 0030–0033 | `place_dishes_order` · `search_scopes` · `apple_auth_account_blocks` · `entries_always_public` | `DishRanking` order · Search scopes, `nearby_places` · Apple-safe sign-up, `delete_account()`, `my_blocks()` · **every entry public (prod data flip; undo list `entries_private_before_0033`)** |
| 0034–0035 | `signed_out_browse` · `account_integrity` | anon EXECUTE on the browse reads via plpgsql dispatch → `browse.*` DEFINER, no table grant · `delete_account` atomic + verified; always a profile; deactivated hidden; `entry_cards.place.locality` |
| 0036 | `dish_tags.sql` | `reviews.tags` + closed-set CHECK + canonicalising trigger; `apply_entry_sort` takes/keeps tags; `correct_entry_place` prints parked tags; `items[].tags`; `dish_summary.tags` (drop+create, browse twin too) |
| 0037–0040 | `delete_entry` · `feed_areas` · `sort_preview_cache` · `place_required` | `delete_entry()` · `feed_areas()` + `get_entry_feed(p_area)` (drop+create, browse twin too) · preview cache + rate tables, purge fn + entries-delete trigger, `entries.sort_meta`, `apply_entry_sort(p_meta)` (drop+create), `delete_account` checks both · INSERT-only place trigger |
| 0041–0045 | `secret_six` · `search_filters` · `journal_filters` · `six_carry` · `place_dishes_tags` | CHECK admits 6, histogram 11 rows, `apply_entry_sort` admits an evidenced 6 · filter params (drop+create) + `search_cuisines`, `place_has_tagged_dish` · `my_entries`, `my_entry_places` · a re-sort carries a marked 6 by line (T3, like tags) · `place_dishes.tags` (drop+create, browse twin too); `search_dishes.tags` rides 0042 |
| 0046–0049 | `cities` · `range_and_city_filters` · `entry_card_read` · `saved_filters` | `cities` + `city_at` + `place_cities` view, `feed_cities`, `resolve_city`, `get_entry_feed(p_city)` (drop+create, browse twin too) · `score_in_range`; `p_max_score`/`p_city` on my_entries + three search reads (drop+create), `my_entry_cities`, `search_cities` · `get_entry_card` + browse twin · `search_saved` range + city (drop+create), `my_saved_cities` |
| 0050–0051 | `date_windows` · `what_to_order_by_rating` | `in_window`; `p_from`/`p_to`/`p_tz` on the three search reads + `search_saved` (drop+create) · `place_dishes` ordered by rating (create or replace, browse twin too) |
| 0052 | `read_scale` | lateral `dish_stats`/`restaurant_stats`; `place_city_cache` + triggers behind `place_cities`; `place_numbers`, `dish_numbers`, `window_bounds`; the four Search reads rebuilt in place (same signatures) — no wire change |
| 0053 | `journal_days_and_dish_tags` | `dish_tag_links` + keyword map + triggers + backfill; `apply_entry_sort`/`correct_entry_place` take `items[].styles` (create or replace, same signatures); `my_entries_filtered`, `my_entries_count`, `journal_days`, `dish_tags`, `similar_dishes`, `dishes_by_tag` |
| 0054 | `score_range_ceiling` | `score_in_range` opens the top at 6, not 5 (create or replace) — every range read follows |
| 0055 | `feed_edition` | `user_cravings`; `top_ate`, `new_to_record`, `craving_options` (+ browse twins), `because_you_loved`, `my_cravings`, `set_cravings`; `dishes_by_tag` + `p_city` + `saved` (drop+create); helpers `city_places`, `tag_label`; `delete_account` checks `user_cravings` |
| 0056 | `faster_sort` | `sort_preview_cache.plan` nullable (null = a pending claim); `sort_preview_claim` (hit/pending/claimed/none, atomic on the PK), `sort_entry_context` (the sort's pre-model reads in one trip) — both service_role only |
| 0057 | `tag_pages` | `p_kind`/`p_slug` on `get_entry_feed` + `new_to_record` (drop+create, browse twins too); `my_taste_tags`; helper `tag_dish_ids` |
| 0058 | `ate_with` | `entry_companions`, `entry_invites`, `device_push_tokens`, `ate_with_ledger`; notifications `ate_with` type; tag/untag/invite/redeem/prefill/respond/decline + `my_notifications`, push-token RPCs; `entry_cards.companions` (create or replace, trailing column); `delete_account` checks the new tables |
| 0059 | `send_push` | notifications `push_claimed_at`/`push_attempts`; `push_is_ready`, `push_claim_ate_with`, `push_mark_sent`, `push_drop_tokens` (service_role); `push_kick` (pg_net → send-push, Vault-gated) on tag insert, on sort, and every minute (pg_cron); keyless setup `push_configure(url)` + `push_kick_secret()` (DB-generated bearer, service_role only); `register_push_token` env defaults to `production` |
| 0060 | `lists_and_journal_search` | `user_lists`, `user_list_items` + item-follows-line triggers; list RPCs, `my_scored_dishes`; `search_my_entries` (author-index bounded, no new index); legacy `lists`/`list_dishes` SELECT owner-only; `delete_account` checks the list tables |
| 0069 | `fixed_dish_styles` | `dish_style_list()`; `dish_style_clean`/`dish_styles_from_json` keep only listed styles (create or replace); data: off-list style links and style cravings deleted, emptied dishes re-guessed |
| 0071 | `dish_dedup` | `dish_key()` + index; `find_or_create_dish` key/alias lookups; `merge_dish(src, tgt, reason, detail)` (same place, never two dishes one entry names; carries saves, legacy list rows, photo picks; logs `dish_merges`) + `unmerge_dish`; `dish_merge_proposals`, `dish_scan_places()`, `merge_dish_proposals()` for the dish-dedup scan (service role only) |
| 0073 | `list_covers_and_people` | `user_lists.cover_item_id`/`cover_url`; `user_list_members` (invited → accepted, ≤ 20, owner writes via RPC); notifications `list_id` + `list_invite` type; `set_list_cover`, `set_list_people`, `list_people`, `my_list_invites`, `respond_list_invite`, `leave_list`; `my_lists`/`get_list` rebuilt as definer with shared lists; `push_claim_list_invites` + send-push sends invites |
| 0074 | `diet` | `profiles.diet` (+ column grant); `reviews.diet_tags`/`diet_off` + trigger `reviews_tags_diet`; `apply_entry_sort` stamps new lines, `correct_entry_place` prints the plan's stamp (create or replace); `entry_cards.items[].diet_tags`; `dish_consensus_tags` = the label rule (constants `dish_label_min_people`, `dish_label_window`), `dish_diet_counts`; `dish_summary`/`place_dishes` + `diet_counts` (drop+create, browse twins too); vg-aware pre-filters in `place_has_tagged_dish`, `tag_dish_ids`, `dishes_by_tag` |
| 0080 | `suggestions_nearby` | `suggestion_area`/`in_suggestion_area`/`suggestion_radius_m` (25 km); `similar_dishes` + `p_lat`/`p_lng` and `dishes_by_tag` + `p_lat`/`p_lng` (drop+create): suggestions only from places near the phone, else the dish's place, else your last located entry; `p_city` and suburb/city chips keep their own area |
| 0084 | `more_diet_options` | five codes (`pe` pescatarian, `ha` halal, `ef`, `pf`, `sf`) in every closed set; `diet_tags_implied`: vg ⇒ v, df, ef, pe; v ⇒ pe; nf ⇒ pf; `dish_diet_counts` holds every counted, unvetoed code (the app's "?" popover) |
| 0086 | `ate_with_copy` | `ate_with_prefill` + `body` and `dishes[].score` (the tagger's words and first-line scores) for "Copy their review"; additive |
| 0090 | `new_to_record_score` | `new_to_record` + trailing `score` (the dish's average, `dish_stats`) so "New in" rows print a rating, never a "New" pill (drop+create, browse twin too); additive |
| 0094 | `audit_fixes` | independent audit 26 Oct: no client review/dish writes (reviews: PATCH `tags` only); two-sixes on `entry_id` moves; `storage_purge_queue` + `delete-account` function; list invites spend `ate_with_spend('list')`; client photo/avatar URLs pinned to our storage; manual places 20/day, one open report per target, 30 reports/day; `diet` column private + `my_diet()`; live push tokens not taken over; `dish_pair_verdicts`; `entries.photos_match_tried_at`; text caps; legacy social tables unreadable |
| 0098 | `plate_awards` | `user_awards` + `award_check` (triggers on reviews, entries, saves, entry_companions, dish_tag_links; backfill, unseen); `awards_of`, `mark_awards_seen`, `award_lines`; helpers `place_country`, `award_day_zone`; `delete_account` checks `user_awards` |
