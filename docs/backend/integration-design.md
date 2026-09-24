# Ate — client ↔ server contract (V1)

Everything the app calls, with shapes. Schema lives in `data-model.md`. **Complete enough to build the
Swift client against without asking a question** — if something is missing, that is a bug in this file.
**Environments are law:** Debug → STAGING `cvoitgoaosofkougmarn`, Release → PROD `vyaexmnajnbryimbkgkf`;
migrations reach staging on merge and prod only via the explicit CI job. Auth: Supabase Auth (Apple +
email); every call carries the user's token. `anon` is revoked on all V1 tables (unauthenticated → `[]`).

## The one row shape — `entry_cards`

Journal slip, Feed slip, Entry page and Share receipt are the same data at four densities: ONE row type.

| Field | Type — notes |
|---|---|
| `id` · `author_id` · `created_at` · `updated_at` | uuid · uuid · ts · ts |
| `body` · `visibility` | text — the user's words, verbatim · `public` \| `private` |
| `restaurant_id` · `restaurant_source` | uuid\|null · `user` \| `sorter` \| null |
| `order_number` · `is_mine` | int — "Order #0142" · bool |
| `sort_status` · `sorted_at` | `pending` \| `sorted` \| `failed` (at `pending`: words, no receipt) · ts\|null |
| `author` | `{id, username, name, avatar_url, city}` |
| `place` | `{id, name, address, city, cuisine}` — **null when unattached** |
| `photos` · `photo_count` | `[{url, position}]` ordered, `[]` when none · int |
| `items` | receipt lines, ordered — fields below |
| `dish_count` · `avg_score` | int (every line) · numeric over **scored lines only**, null when none — the receipt footer reads `3 dishes / Avg 3.75` |
| `place_offset` · `place_length` | int\|null — where the PLACE is named in `body` |

`items[]`: `review_id`, `dish_id`, `dish_name` (the menu's spelling), `score` (**null = they gave no number**
→ empty star, no text, DESIGN rule 7), `note` (null = they said nothing; a verbatim clause of `body`, never a
paraphrase), `position` (1-based), `saved` (the viewer's own save state), `cover_url` (the DISH's cover photo,
null when the dish has none — **not** a photo from this entry; `photos[]` is that), `evidence_offset` +
`evidence_length` (where the SCORE is in `body`), `mention_offset` + `mention_length` (where the DISH is
named), `corrected` (the user fixed this line; no re-sort overwrites it). Every `*_offset`/`*_length` is null
when we cannot point at it — then draw no token.

**Inline tokens: place them, never search for them. Every `*_offset` is a 0-based UNICODE SCALAR (code-point)
offset into `body`, and every `*_length` counts UNICODE SCALARS.** Not UTF-16: one emoji earlier in the body
and the two disagree. Scalars because Postgres counts code points, so the DB verifies every offset it stores.
Never rebuild a token by searching — `"Dinner was $14.50"` contains `4.5`, and first.

```swift
let s = body.unicodeScalars
let i = s.index(s.startIndex, offsetBy: item.evidenceOffset), j = s.index(i, offsetBy: item.evidenceLength)
let token = String(s[i..<j])          // "4.5" · NSRange(i..<j, in: body) if you need UTF-16
```

Offsets describe the body **as it was sorted**: after a `body` edit with no re-sort they can go stale
(`updated_at > sorted_at` is the hint; the sure test is that the slice still holds the score's digits). Fall
back to plain text, never to a search.

## Reads

Every list is keyset-paginated; **no OFFSET anywhere.** First page → pass nulls; next page → pass the LAST
row's key. That key is `(created_at, id)` DESC on every entry and review list (feed, journal, place, dish
reviews, `dishes_by_score`); the two ranked/grouped lists key on their own order instead —
`place_dishes` on `(score, people, name, dish_id)`, `statement_months` on `month`. Page sizes are clamped.

| Screen | Call | Returns |
|---|---|---|
| Feed | `rpc get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, p_include_own)` | `entry_cards[]` — all public entries, blocked users already gone. `p_include_own` defaults **false** (your visits live in Journal) |
| Journal · Profile | `rpc get_entries_by_author(p_author_id, cursor…, p_page_size)` | `entry_cards[]` — yours includes private; someone else's is public-only (RLS) |
| Entry · Share | `GET /rest/v1/entry_cards?id=eq.<uuid>` | one `entry_card` |
| Place — header | `rpc place_summary(p_restaurant_id)` | `{restaurant_id, name, address, city, cuisine, cover_url, avg_rating, review_count, people_count, dish_count, my_visits, my_last_visit, locality, entry_count}` — **`locality` is the second chip** (`city` is unreliable, see below); `entry_count` = visits here, `review_count` = receipt lines; every text field is `null`, never `''` |
| Place — what to order | `rpc place_dishes(p_restaurant_id, p_limit, p_cursor_review_count, p_cursor_score, p_cursor_dish_name, p_cursor_dish_id)` | `{dish_id, dish_name, score, people_count, review_count, cover_url}[]` — **`review_count` DESC leads**, then `score` DESC (unscored last), then name, then id: the ported `DishRanking` rule, so one 5.0 from one person cannot lead the menu. **Never re-sort it client-side.** A dish with no line at all is not returned. **4-part keyset: pass all four from the last row** (`p_cursor_score` may be null) |
| Place — entries | `rpc get_entries_at_place(p_restaurant_id, p_scope, cursor…)` | `entry_cards[]`; `p_scope ∈ 'all'|'mine'|'others'` |
| Dish — header | `rpc dish_summary(p_dish_id)` | `{dish_id, dish_name, restaurant_id, restaurant_name, restaurant_city, score, review_count, scored_count, people_count, cover_url, saved, my_last_score, photos, restaurant_locality}` — `photos` = `[{url, entry_id}]` newest first for the header stack, `[]` when none, and **`photos[0].url == cover_url`** |
| Dish — reviews | `rpc get_dish_reviews(p_dish_id, p_cursor_mine, p_cursor_created_at, p_cursor_id, p_page_size)` | `{review_id, entry_id, author{…}, score, note, created_at, is_mine, photos[]}[]` — **mine first**, then newest. Keyset is 3-part: pass `is_mine`, `created_at`, `id` from the last row. **`entry_id` is nullable** (a pre-entries line has no entry to open — decode optional, hide the tap); `photos[]` is the review's ENTRY's |
| Saved | `GET /rest/v1/my_saved_dishes?order=saved_at.desc,dish_id.desc&limit=N` | `{dish_id, dish_name, restaurant_id, restaurant_name, restaurant_city, dish_score, dish_cover_url, source_entry_id, source_user_id, source_username, saved_at, cover_url}[]` — keyset below; client groups by restaurant |
| You · Profile header | `rpc profile_summary(p_user_id)` | `{user_id, username, name, avatar_url, bio, city, created_at, orders, places, dishes, scored, avg_score, is_me}` — `orders`/`places` count ENTRIES, `dishes`/`scored`/`avg_score` count receipt LINES (and now agree with `score_histogram`) |
| Ratings histogram | `rpc score_histogram(p_user_id)` | 10 rows `{score, dish_count, review_count}` for 0.5…5.0, **zeros included** — draw bars straight from it. The label ("36 dishes") is `dish_count` |
| Ratings bar tap · "Your 5.0s" | `rpc dishes_by_score(p_user_id, p_score, p_limit, p_cursor_created_at, p_cursor_id)` | `{review_id, entry_id, dish_id, dish_name, restaurant_id, restaurant_name, score, note, created_at, cover_url}[]`, newest first, keyset `(created_at, id)`. `cover_url` is the DISH's photo (the tile), `created_at` is the visit's date, `entry_id` is **nullable** |
| Recap picker | `rpc statement_months(p_user_id, p_tz, p_cursor_month, p_limit)` | `{month (date), orders}[]`, newest first; `orders` is that month's ENTRY count. Keyset: pass the last row's `month` |
| Recap | `rpc monthly_statement(p_user_id, p_month, p_tz)` | one jsonb (below) |
| Search | `rpc search_all(p_query, p_limit_per_kind)` | `{kind, id, title, subtitle, score, match_rank, detail}[]`, `kind ∈ place|dish|person` — split on `kind` for the tabs. Nearby: `places-search?op=nearby` (below) |
| Handle availability | `rpc handle_available(p_handle)` | bool. **Use this, not a `profiles` select** — the block-aware policy can make a taken handle look free |

**A place's label is `locality`, never `city`.** `restaurants.city` is a bare suburb on stub and manual rows
but, on anything resolved live through `places-search op=details`, it is the mangled
`"<street>, <suburb STATE post>"` that function's address split produces. `place_summary.locality` and
`dish_summary.restaurant_locality` are derived on read from the address and are the only ones safe to
print; `null` means we cannot honestly name one — draw no chip. (`search_all`'s place `subtitle` still
falls back to `city` for a place with no cuisine: the one caller not yet moved over.)

**Saved is keyset-paged on `(saved_at desc, dish_id desc)`** — next page:
`&or=(saved_at.lt.<last saved_at>,and(saved_at.eq.<last saved_at>,dish_id.lt.<last dish_id>))`.
**Never order by `restaurant_name`**: grouping by place is presentation (the client groups the page it has),
and a name-ordered list has no stable cursor. `cover_url` == `dish_cover_url`; prefer `cover_url`.

`monthly_statement` → `{month, username, orders, places, new_places, dishes, stars, average,
top_dishes:[{dish_id, dish_name, restaurant_name, score}], most_ordered:{dish_name,count}|null,
most_visited:{restaurant_id, restaurant_name, count}|null}`. Months are local to `p_tz` (default
`Australia/Melbourne`; pass the device zone). `average`/`stars` cover scored lines only. `most_ordered`/
`most_visited` are **null below a count of 2** — "Most ordered … x1" is not a habit, so print nothing.

**Printing an aggregate: one decimal, as sent.** `place_summary.avg_rating`, `dish_summary.score`,
`place_dishes.score` and `monthly_statement.average` are averages, not scores: print `4.6`, never rounded
to `4.5` (`ScoreFormat.average`). Only the STAR GLYPHS round to the nearest half (DESIGN: "aggregates show
to the nearest half" is about the stars). An entry's own `avg_score` keeps its 2 decimals — the receipt
footer reads `Avg 3.75`. A single review's score is a half-step and prints one decimal always (`4.0`).

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
- The response carries the server-assigned `order_number` + `sort_status: "pending"`. Never send
  `order_number`/`sort_status`/any `sort_*`/`place_*` — those columns are not grantable to you.

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
Call it right after the insert (and on retry for anything left `pending`/`failed`). Idempotent: an
already-sorted entry returns `{ok: true, skipped: "already sorted"}` unless `force`; `dry_run` returns the
plan without writing. Then refetch `entry_cards?id=eq.<uuid>`. **`force` cannot destroy a correction** —
the rule below is enforced in SQL, not by the caller remembering it.

### Corrections (the user's, always)
| Action | Call |
|---|---|
| Fix the place | `rpc correct_entry_place(p_entry_id, p_restaurant_id)` → the entry row. Re-resolves every line's dish at the new place, or prints the parked plan if the entry had none. Pins `restaurant_source='user'`, records `place_corrected_at`, clears the place token |
| Fix a line's dish | `rpc correct_entry_dish(p_review_id, p_dish_id, p_dish_name)` → dish uuid. Pass `p_dish_id` for a menu pick, `p_dish_name` to name one. Score and note untouched |
| Set / clear a score | `PATCH /rest/v1/reviews?id=eq.<uuid>` `{ "score": 4.5 }` (or `null`). Half steps 0.5–5.0 |
| Edit the words / flip visibility | `PATCH /rest/v1/entries?id=eq.<uuid>` `{ "body": "…" }` / `{ "visibility": "private" }` |
| Delete a visit | `DELETE /rest/v1/entries?id=eq.<uuid>` (cascades photos + its reviews) |

Any of the first three marks the line `corrected` (`reviews.corrected_at`; a bare `score`/`note` PATCH by the
author counts). **A corrected line is the user's, and a re-sort — forced or not — preserves it:**

1. It is never deleted; only lines with `corrected_at IS NULL` are replaced.
2. Its `dish_id`, `score`, `score_evidence` and `note` are never modified — only `position` and the
   offsets, and the offsets only while they still point at the same text.
3. A parsed item is matched to a corrected line (so no duplicate appears) when, in order: (a) its
   `dish_name` case-insensitively equals the name that line carried when first corrected; (b) it equals
   the line's current `dish_name`; (c) its `score_evidence` is identical. First unclaimed line wins.
4. A corrected line matching no item survives anyway, appended after the parsed lines.
5. A corrected line pins the place: a fresh sorter match cannot move the entry and orphan it.

Rules 7 and 9 are re-asserted on every sorter-proposed line, never on a preserved one — they bound what the
sorter may write, not what the user may keep; editing the words does not delete their fix. Never write
`reviews` rows directly for a new entry: the sorter's RPC owns dish creation (select-then-insert against a
partial unique index; see `data-model.md` Landmines).

### Save · block · report
| Action | Call |
|---|---|
| Save a dish | `rpc save_dish(p_dish_id, p_source_entry_id)` — idempotent; first provenance wins |
| "Save this place" on an entry | `rpc save_entry_dishes(p_entry_id)` → count. Saves every line, provenance = that entry |
| …and toggle it back off | `rpc unsave_entry_dishes(p_entry_id)` → count removed. Drops the save for **every dish this entry printed, whatever entry it was saved from** — the toggle's off state has to mean "no line reads saved". Returns 0 (never an error) when the entry is gone or not visible |
| Unsave | `rpc unsave_dish(p_dish_id)` · check: `rpc is_dish_saved(p_dish_id)` (or `items[].saved`) |
| Block / unblock | `rpc block_user(p_user_id)` / `rpc unblock_user(p_user_id)` |
| Report | `rpc report_entry(p_entry_id, p_reason, p_note)` / `rpc report_profile(p_user_id, …)` → report uuid. `p_reason ∈ (spam, abuse, wrong_place, not_food, other)` **or null** ("no reason given" — what a one-tap report sends); lower-cased + trimmed server-side, anything else is `23514`. `p_note` is free text, kept verbatim |

After a block, **refetch open lists** (that user vanishes from every read, both directions) and render a
missing author/place as unavailable rather than crashing on a nil join.

## The sorter (`supabase/functions/sort-entry`)

Two modes, one contract. **stub** (default, CEO decision — no AI spend): a deterministic rule-based parser,
no network, no key. **model**: `claude-haiku-4-5-20251001` via a forced tool call, reachable **only** when
`ANTHROPIC_API_KEY` is in the function's secrets; `ATE_SORTER_MODE=stub` forces stub even with a key, and a
model failure degrades to the stub rather than failing the sort.

Both are post-validated identically, in TypeScript and again in SQL: a **score** survives only if its
`score_evidence` is a literal substring of `body` **and** contains that number (sentiment can never become
a score); a **note** only if it is a literal substring, case-sensitively, matching Postgres `position()`
(quote, never paraphrase); a **dish** only if its name is in the words or already on the matched menu; an
**offset** only if the body says that text there, else it is recomputed from the first occurrence, else null.

A note is the **clause after the dish and its score**, cut at the next dish, with dangling glue and
punctuation trimmed off its ends ("the quiet star," → "the quiet star") — what `design/v1/Entry` prints,
never repeating the dish name or score the line above already shows. A dish name keeps the menu's spelling
on any case-insensitive match; a new one is capitalised on create (so prose stops printing "salmon roll").

**A score the sentence itself marks belongs to the dish in front of it**: `"<dish> was a 4.5"`,
`"<dish> is a 4"`, `"<dish> gets a 3.5"`, `"gave the <dish> a 4"`, `"<dish>, a solid 4"` all print a scored
line (the CEO's `…fishbowl margarita  was a 4.5 and eliteeeee` printed nothing before this). Only a number
that has already proved it is a score is read that way, so `"a party of 4"`, `"table for 4"`, `"top five"`
and `"Order two."` still print nothing. **The attached place's own name is never a dish, nor the front half
of one** — `"Baby Pizza San Danielle Pizza 3.5"` is the `San Danielle Pizza`.

The place comes from the words alone, matched against restaurants we already hold
(`search_local_restaurants`, 0017) — never Google, never location, never a new row. **No place ⇒ no dish
reviews** (a dish needs a restaurant): the entry is still `sorted`, its findings park in
`entries.sort_plan`, and `correct_entry_place` prints the receipt retroactively. ~50 fixtures pin every rule
here: `node --test supabase/functions/sort-entry/*_test.ts` (also the eval harness for model mode).

## `places-search` — unchanged

`op=autocomplete` (blended `results[]`: `kind:'place'` = resolve on select, `kind:'manual'` = already a row) ·
`op=details` (upserts the row; the only restaurant-create path) · `op=nearby` (PostGIS-first, `restaurants[]`
with `distance_meters`). Verified end-user JWT + per-user rate limit on every op; stub mode when
`GOOGLE_PLACES_API_KEY` is absent. The VIC bounding box is a launch-market constant — when the market
changes, make it config, do not fork the function.

## Wire-change log

**Behavioural — 0030 (2026-09-24).** `place_dishes` returns the product's order now, which is the
ported-and-tested `DishRanking` rule: `review_count` desc → `score` desc (unscored last) → name → id.
Score-first was wrong on this screen — a 4.4 from three people outranked a 4.2 from four, and a lonely
5.0 would lead the menu. Same columns, different order, **fewer rows**: a dish with no line is an
abandoned "add a new dish" shell and is gone, while an UNSCORED dish with a line stays. The keyset
follows the order, so `p_cursor_people` becomes `p_cursor_review_count` — **breaking on that parameter
alone**, which nothing shipped sends (the app calls `place_dishes(p_restaurant_id, p_limit)`).

**Additive — 0029 (2026-09-24), the detail + You read audit.** `place_summary` + `locality`/`entry_count`;
`dish_summary` + `photos`/`restaurant_locality`; `dishes_by_score` + `cover_url`; new cursor parameters on
`place_dishes` (4-part), `dishes_by_score` and `statement_months`; `monthly_statement` + `"username"`; new
`place_locality(address, city)` / `dish_photos(dish, limit)`. Every column is appended LAST and every
parameter defaults to null, so an existing call keeps working untouched. Behaviour, not shape — the four
things to KNOW: (1) `profile_summary.dishes`/`scored`/`avg_score` now count by `reviewer_id`, so a user
with pre-entries reviews sees HIGHER numbers that finally match `score_histogram` (staging: 40 → 60
scored); (2) `place_summary.address`/`city`/`cuisine`/`cover_url` and `dish_summary.restaurant_city` are
`null` instead of `''` — a `""` cover was a broken image request; (3) `monthly_statement.most_ordered`/
`most_visited` are `null` when the count is 1; (4) `get_dish_reviews.entry_id` and
`dishes_by_score.entry_id` were ALWAYS nullable on real rows — now documented, decode optional.

**Additive — 0018–0028.** Everything 0018–0023 introduced (the tables, columns, RPCs and views above);
0024/0025's correction + offset columns (`reviews.corrected_at`/`corrected_from_name`/`evidence_offset`/
`mention_text`/`mention_offset`, `entries.place_corrected_at`/`place_query`/`place_offset`,
`entry_cards.place_offset`/`place_length` and `items[].evidence_*`/`mention_*`/`corrected`, `place_offset`
on the `sort-entry` response); 0026–0028's `entry_cards.items[].cover_url`, `my_saved_dishes.cover_url` and
`unsave_entry_dishes(p_entry_id)`. Behaviour, not shape: every `cover_url` **stops reading null** once a
dish's entries carry photos (covers see `entry_photos`, not only the legacy `reviews.photo_url`); the
sorter reads `"<dish> was a 4.5"` scores, keeps the venue's name out of dish names, capitalises a new dish
and trims a clause note's dangling comma; a report `reason` outside the five-word vocabulary is `23514`.

**Breaking — sequenced with iOS through the lead:** (1) `reviews.score` NOT NULL → **NULLABLE**, decode as
optional (V1 Swift is written against this from the start, so nothing shipped is broken today); (2) SELECT
on `profiles`/`entries`/`reviews` **returns fewer rows** once a block exists — no column moved, the rows
are simply not there, so tolerate an absent author; (3) `authenticated` may write only
`(id, author_id, body, visibility, restaurant_id, created_at)` on an `entries` insert and
`(body, visibility)` on update (column grants) — anything else is `42501`.

## Errors worth handling

`23505` on an entry insert = already accepted. `42501` = RLS/grant refusal (not yours, or a column you may not
write). `23503` = missing FK (unknown dish/restaurant). `23514` = a CHECK refused the value (e.g. a report
`reason` outside the five-word vocabulary). `22023` = bad RPC argument (e.g. `correct_entry_dish`
before the entry has a place). `429` from `places-search` = rate limited.
