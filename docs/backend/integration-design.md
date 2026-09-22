# Ate — client ↔ server contract (V1)

Everything the app calls, with shapes. Schema lives in `data-model.md`. **Complete enough to build the
Swift client against without asking a question** — if something is missing, that is a bug in this file.

**Environments are law.** Debug → STAGING `cvoitgoaosofkougmarn`. Release → PROD `vyaexmnajnbryimbkgkf`.
Migrations reach staging on merge and prod only via the explicit CI job. Auth: Supabase Auth (Apple +
email); every call carries the user's token. `anon` is revoked on all V1 tables (unauthenticated → `[]`).

## The one row shape — `entry_cards`

Journal slip, Feed slip, Entry page and Share receipt are the same data at four densities: ONE row type.

```jsonc
{
  "id": "uuid", "author_id": "uuid",
  "body": "Tipo 00 with Jess…",            // the user's words, verbatim
  "visibility": "public",                   // "public" | "private"
  "restaurant_id": "uuid|null",
  "restaurant_source": "user|sorter|null",
  "order_number": 142,                      // "Order #0142"
  "sort_status": "pending",                 // pending → show words, no receipt
  "sorted_at": "ts|null",
  "created_at": "ts", "updated_at": "ts",
  "is_mine": true,
  "author": { "id", "username", "name", "avatar_url", "city" },
  "place":  { "id", "name", "address", "city", "cuisine" },   // null when unattached
  "photos": [ { "url": "https://…", "position": 0 } ],        // ordered, [] when none
  "photo_count": 3,
  "items": [                                                  // receipt lines, ordered
    { "review_id": "uuid", "dish_id": "uuid", "dish_name": "Tagliatelle al ragù",
      "score": 4.5,                                           // NULL = user gave no number
      "note": "The tagliatelle al ragù 4.5 was unreal…",      // NULL = they said nothing
      "position": 1, "saved": false,                          // `saved` = viewer's own save state
      "evidence_offset": 29, "evidence_length": 3,            // where the SCORE is in `body`
      "mention_offset": 13, "mention_length": 19,             // where the DISH is named in `body`
      "corrected": false }                                    // true = the user fixed this line
  ],
  "dish_count": 3,
  "avg_score": 3.75,     // over SCORED items only; null when none. Matches the receipt footer
  "place_offset": 0, "place_length": 7    // where the PLACE is named in `body`; null if nowhere
}
```

`score: null` renders an empty star and no text (DESIGN rule 7).

### Inline tokens: place them, never search for them

**Every `*_offset` is a 0-based UNICODE SCALAR (code-point) offset into `body`, and every `*_length`
counts UNICODE SCALARS.** Not UTF-16: one emoji earlier in the body and the two disagree. Scalars
because Postgres counts code points, so the database verifies every offset it stores instead of
trusting the sorter. Never rebuild a token by searching — `"Dinner was $14.50"` contains `4.5`, first.

```swift
let s = body.unicodeScalars
let i = s.index(s.startIndex, offsetBy: item.evidenceOffset)
let j = s.index(i, offsetBy: item.evidenceLength)
let token = String(s[i..<j])            // "4.5" — the user's own characters
let range = NSRange(i..<j, in: body)    // if you need UTF-16 for AttributedString
```

`null` offsets mean "we cannot point at it" — draw no token. Offsets describe the body **as it was
sorted**: after a `body` edit with no re-sort they can go stale (`updated_at > sorted_at` is the cheap
hint; the certain test is that the slice still contains the score's digits). Fall back to plain text.

## Reads

Every list is keyset-paginated. **Cursor contract:** first page → pass nulls; next page → pass the LAST
row's `created_at` **and** `id`. Ordering is always `created_at DESC, id DESC`. Page size is clamped
(feeds 50, lists 200–500). No OFFSET anywhere.

| Screen | Call | Returns |
|---|---|---|
| Feed | `rpc get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, p_include_own)` | `entry_cards[]` — all public entries, blocked users already gone. `p_include_own` defaults **false** (your visits live in Journal) |
| Journal · Profile | `rpc get_entries_by_author(p_author_id, cursor…, p_page_size)` | `entry_cards[]` — yours includes private; someone else's is public-only (RLS) |
| Entry · Share | `GET /rest/v1/entry_cards?id=eq.<uuid>` | one `entry_card` |
| Place — header | `rpc place_summary(p_restaurant_id)` | `{restaurant_id, name, address, city, cuisine, cover_url, avg_rating, review_count, people_count, dish_count, my_visits, my_last_visit}` |
| Place — what to order | `rpc place_dishes(p_restaurant_id, p_limit)` | `{dish_id, dish_name, score, people_count, review_count, cover_url}[]` — score DESC, unscored last |
| Place — entries | `rpc get_entries_at_place(p_restaurant_id, p_scope, cursor…)` | `entry_cards[]`; `p_scope ∈ 'all'|'mine'|'others'` |
| Dish — header | `rpc dish_summary(p_dish_id)` | `{dish_id, dish_name, restaurant_id, restaurant_name, restaurant_city, score, review_count, scored_count, people_count, cover_url, saved, my_last_score}` |
| Dish — reviews | `rpc get_dish_reviews(p_dish_id, p_cursor_mine, p_cursor_created_at, p_cursor_id, p_page_size)` | `{review_id, entry_id, author{…}, score, note, created_at, is_mine, photos[]}[]` — **mine first**, then newest. Keyset is 3-part: pass `is_mine`, `created_at`, `id` from the last row |
| Saved | `GET /rest/v1/my_saved_dishes?order=restaurant_name.asc,saved_at.desc` | `{dish_id, dish_name, restaurant_id, restaurant_name, restaurant_city, dish_score, dish_cover_url, source_entry_id, source_user_id, source_username, saved_at}[]` — client groups by restaurant |
| You · Profile header | `rpc profile_summary(p_user_id)` | `{user_id, username, name, avatar_url, bio, city, created_at, orders, places, dishes, scored, avg_score, is_me}` |
| Ratings histogram | `rpc score_histogram(p_user_id)` | 10 rows `{score, dish_count, review_count}` for 0.5…5.0, **zeros included** — draw bars straight from it. The label ("36 dishes") is `dish_count` |
| Ratings bar tap · "Your 5.0s" | `rpc dishes_by_score(p_user_id, p_score, p_limit)` | `{review_id, entry_id, dish_id, dish_name, restaurant_id, restaurant_name, score, note, created_at}[]`, newest first |
| Recap picker | `rpc statement_months(p_user_id, p_tz)` | `{month (date), orders}[]`, newest first |
| Recap | `rpc monthly_statement(p_user_id, p_month, p_tz)` | one jsonb (below) |
| Search | `rpc search_all(p_query, p_limit_per_kind)` | `{kind, id, title, subtitle, score, match_rank, detail}[]`, `kind ∈ place|dish|person` — split on `kind` for the tabs. Nearby: `places-search?op=nearby` (below) |
| Handle availability | `rpc handle_available(p_handle)` | bool. **Use this, not a `profiles` select** — the block-aware policy can make a taken handle look free |

`monthly_statement` → `{month, orders, places, new_places, dishes, stars, average, top_dishes:[{dish_id,
dish_name, restaurant_name, score}], most_ordered:{dish_name,count}|null, most_visited:{restaurant_id,
restaurant_name, count}|null}`. Months are local to `p_tz` (default `Australia/Melbourne`; pass the
device zone). `average`/`stars` cover scored lines only. Aggregate scores come back at 1 decimal —
**round to the nearest half for display** (DESIGN rule 7).

## Writes

### Create an entry — the words land first, alone
```
POST /rest/v1/entries
{ "id": <client uuid>, "author_id": <me>, "body": "…", "visibility": "public",
  "restaurant_id": <uuid|null>,          // only if the user TAPPED a place in the composer
  "created_at": "<when they wrote it>" }  // optional; send it for offline entries
```
- **INSERT, never upsert.** On `23505` (duplicate key) the entry already landed — treat as success.
- Sending `restaurant_id` stamps `restaurant_source = 'user'`, which the sorter will not overwrite.
- The response carries the server-assigned `order_number` + `sort_status: "pending"`. Do not send
  `order_number` / `sort_status` / any `sort_*` / `place_*` — those columns are not grantable to you.

### Photos (as each upload finishes)
Upload to `review-photos/<auth.uid()>/<file>` → public URL → `POST /rest/v1/entry_photos`
`{entry_id, position, photo_url}` with `Prefer: resolution=merge-duplicates` on `(entry_id, position)`.

### Sort it
```
POST /functions/v1/sort-entry     { "entry_id": "<uuid>", "force": false, "dry_run": false }
→ 200 { ok, mode: "stub"|"model", entry_id, sort_status, restaurant_id,
        place_query, place_offset, items:[…] }
  401 unauthorized · 403 not your entry · 404 unknown entry · 422 entry_id missing · 500 sort failed
```
Call it right after the insert (and again on retry for anything left `pending`/`failed`). Idempotent: an
already-sorted entry returns `{ ok: true, skipped: "already sorted" }` unless `force`; `dry_run` returns
the plan without writing. Then refetch `entry_cards?id=eq.<uuid>`. **`force` cannot destroy a
correction** — the rule below is enforced in SQL, not by the caller remembering.

### Corrections (the user's, always)
| Action | Call |
|---|---|
| Fix the place | `rpc correct_entry_place(p_entry_id, p_restaurant_id)` → the entry row. Re-resolves every line's dish at the new place, or prints the parked plan if the entry had none. Pins `restaurant_source='user'`, records `place_corrected_at`, clears the place token |
| Fix a line's dish | `rpc correct_entry_dish(p_review_id, p_dish_id, p_dish_name)` → dish uuid. Pass `p_dish_id` for a menu pick, `p_dish_name` to name one. Score and note untouched |
| Set / clear a score | `PATCH /rest/v1/reviews?id=eq.<uuid>` `{ "score": 4.5 }` (or `null`). Half steps 0.5–5.0 |
| Edit the words / flip visibility | `PATCH /rest/v1/entries?id=eq.<uuid>` `{ "body": "…" }` / `{ "visibility": "private" }` |
| Delete a visit | `DELETE /rest/v1/entries?id=eq.<uuid>` (cascades photos + its reviews) |

Any of the first three marks the line `corrected` (`reviews.corrected_at`; a bare `score`/`note` PATCH by
the author counts). **A corrected line is the user's, and a re-sort — forced or not — preserves it:**

1. It is never deleted; only lines with `corrected_at IS NULL` are replaced.
2. Its `dish_id`, `score`, `score_evidence` and `note` are never modified — only `position` and the
   offsets, and the offsets only while they still point at the same text.
3. A parsed item is matched to a corrected line (so no duplicate line appears) when, in order: (a) its
   `dish_name` case-insensitively equals the name that line carried when first corrected; (b) it equals
   the line's current `dish_name`; (c) its `score_evidence` is identical. First unclaimed line wins.
4. A corrected line matching no item survives anyway, appended after the parsed lines.
5. A corrected line pins the place: a fresh sorter match cannot move the entry and orphan it.

Rules 7 and 9 are re-asserted on every sorter-proposed line, never on a preserved one — they bound what
the sorter may write, not what the user may keep. Editing the words does not delete their fix. Never
write `reviews` rows directly for a new entry: the sorter's RPC owns dish creation (select-then-insert
against a partial unique index; see `data-model.md` Landmines).

### Save · block · report
| Action | Call |
|---|---|
| Save a dish | `rpc save_dish(p_dish_id, p_source_entry_id)` — idempotent; first provenance wins |
| "Save this place" on an entry | `rpc save_entry_dishes(p_entry_id)` → count. Saves every line, provenance = that entry |
| Unsave | `rpc unsave_dish(p_dish_id)` · check: `rpc is_dish_saved(p_dish_id)` (or `items[].saved`) |
| Block / unblock | `rpc block_user(p_user_id)` / `rpc unblock_user(p_user_id)` |
| Report | `rpc report_entry(p_entry_id, p_reason, p_note)` / `rpc report_profile(p_user_id, …)` → report uuid |

After a block, **refetch open lists**: the blocked user's entries and profile stop existing in every read,
both directions. Render a missing author/place as unavailable rather than crashing on a nil join.

## The sorter (`supabase/functions/sort-entry`)

Two modes, one contract. **stub** (default, CEO decision — no AI spend): a deterministic rule-based
parser, no network, no key. **model**: `claude-haiku-4-5-20251001` via a forced tool call, reachable
**only** when `ANTHROPIC_API_KEY` is in the function's secrets; `ATE_SORTER_MODE=stub` forces stub even
with a key, and a model failure degrades to the stub rather than failing the sort.

Both are post-validated identically, in TypeScript and again in SQL: a **score** survives only if its
`score_evidence` is a literal substring of `body` **and** contains that number (sentiment can never
become a score); a **note** only if it is a literal substring, case-sensitively, matching Postgres
`position()` (quote, never paraphrase); a **dish** only if its name is in the words or already on the
matched menu; an **offset** only if the body says that text there, else it is recomputed from the first
occurrence, else null.

A note is the whole **sentence** the dish sits in, trimmed only of surrounding whitespace and a trailing
comma — read as written, not as a shred ("the quiet star,"); two dishes sharing a sentence keep their own
clauses instead. A dish name keeps the menu's spelling on any case-insensitive match; a new dish is
created trimmed, whitespace-collapsed and first-letter-capitalised, so prose stops printing as "salmon
roll". An existing dish's name is never rewritten.

The place comes from the words alone, matched against restaurants we already hold
(`search_local_restaurants`, 0017) — never Google, never location, never a new restaurant row. **No place
⇒ no dish reviews** (a dish needs a restaurant): the entry is still `sorted`, its findings park in
`entries.sort_plan`, and `correct_entry_place` prints the receipt retroactively. ~45 fixtures pin every
rule here: `node --test supabase/functions/sort-entry/*_test.ts` (also the eval harness for model mode).

## `places-search` — unchanged

`op=autocomplete` (blended `results[]`: `kind:'place'` = resolve on select, `kind:'manual'` = already a
row) · `op=details` (upserts the row; the only restaurant-create path) · `op=nearby` (PostGIS-first,
`restaurants[]` with `distance_meters`). Verified end-user JWT + per-user rate limit on every op; stub
mode when `GOOGLE_PLACES_API_KEY` is absent. The VIC bounding box is a launch-market constant — when the
market changes, make it config, do not fork the function.

## Wire-change log

**Additive** — everything 0018–0023 introduced (the tables, columns, RPCs and views above), plus
**0024/0025**: `reviews.corrected_at`/`corrected_from_name`/`evidence_offset`/`mention_text`/
`mention_offset`, `entries.place_corrected_at`/`place_query`/`place_offset`, `entry_cards.place_offset`/
`place_length` (appended last), `items[].evidence_offset`/`evidence_length`/`mention_offset`/
`mention_length`/`corrected`, and `place_offset` on the `sort-entry` response. Behaviour, not shape:
notes are now sentences and new dish names are capitalised, so both READ differently than before.
(`apply_entry_sort` also gained two parameters — service_role only, no client call site.)

**Breaking — sequenced with iOS through the lead:**
1. `reviews.score` NOT NULL → **NULLABLE**. Decode as optional. (V1 Swift is written against this from the
   start, so nothing shipped is broken today.)
2. SELECT on `profiles`, `entries`, `reviews` **returns fewer rows** once a block exists — no column
   moved, the rows are simply not there. Tolerate an absent author.
3. `authenticated` may write only `(id, author_id, body, visibility, restaurant_id, created_at)` on an
   `entries` insert and `(body, visibility)` on update (column grants); anything else is `42501`.

## Errors worth handling

`23505` on an entry insert = already accepted. `42501` = RLS/grant refusal (not yours, or a column you may
not write). `23503` = missing FK (unknown dish/restaurant). `22023` = bad argument to an RPC (e.g.
`correct_entry_dish` before the entry has a place). `429` from `places-search` = rate limited.
