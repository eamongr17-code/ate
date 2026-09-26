# Ate — client ↔ server contract (V1)

Everything the app calls, with shapes. Schema lives in `data-model.md`. **Complete enough to build the
Swift client against without asking a question** — if something is missing, that is a bug in this file.
**Environments are law:** Debug → STAGING `cvoitgoaosofkougmarn`, Release → PROD `vyaexmnajnbryimbkgkf`;
migrations reach staging on merge and prod only via the explicit CI job. Auth: Supabase Auth (Apple +
email; see Account below); every call carries the user's token. `anon` has no table access (a raw read →
`[]` or `42501`). **Every entry is public (0033).** **Signed out (0034):** with the publishable key alone, only
`get_entry_feed`, `feed_areas`, `get_entries_by_author`, `get_entries_at_place`, `place_summary`, `place_dishes`,
`dish_summary`, `get_dish_reviews`, `profile_summary` and `is_dish_saved` answer — same shapes, with
`is_mine`/`is_me`/`saved`/`items[].saved` = `false`, `my_visits` = 0, `my_last_*` = null, scope `mine` = `[]`.
Everything else (the Entry page's `entry_cards` read, search, stats, every write) needs a session.

## The one row shape — `entry_cards`

Journal slip, Feed slip, Entry page and Share receipt are the same data at four densities: ONE row type.

| Field | Type — notes |
|---|---|
| `id` · `author_id` · `created_at` · `updated_at` | uuid · uuid · ts · ts |
| `body` · `visibility` | text — the user's words, verbatim · always `public` (**deprecated**, 0033; dropped later — stop reading it) |
| `restaurant_id` · `restaurant_source` | uuid\|null · `user` \| `sorter` \| null |
| `order_number` · `is_mine` | int — "Order #0142" · bool |
| `sort_status` · `sorted_at` | `pending` \| `sorted` \| `failed` (at `pending`: words, no receipt) · ts\|null |
| `author` | `{id, username, name, avatar_url, city}` |
| `place` | `{id, name, address, city, cuisine, locality}` — **null when unattached**; print `locality` (0035), never `city` |
| `photos` · `photo_count` | `[{url, position}]` ordered, `[]` when none · int |
| `items` | receipt lines, ordered — fields below |
| `dish_count` · `avg_score` | int (every line) · numeric over **scored lines only**, null when none — the receipt footer reads `3 dishes / Avg 3.75` |
| `place_offset` · `place_length` | int\|null — where the PLACE is named in `body` |

`items[]`: `review_id`, `dish_id`, `dish_name` (the menu's spelling), `score` (**null = they gave no number**
→ empty star, no text, DESIGN rule 7), `note` (null = they said nothing; a verbatim clause of `body`, never a
paraphrase), `position` (1-based), `saved` (the viewer's own save state), `cover_url` (the DISH's cover photo,
null when the dish has none — **not** a photo from this entry; `photos[]` is that), `evidence_offset` +
`evidence_length` (where the SCORE is in `body`), `mention_offset` + `mention_length` (where the DISH is
named), `corrected` (the user fixed this line; no re-sort overwrites it), `tags` (0036: dietary codes, a
subset of `gf df v vg nf` in that order, deduped, **`[]` never null** — the dish row's chips). Every
`*_offset`/`*_length` is null when we cannot point at it — then draw no token.

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
row's key — EVERY field of it. `(created_at, id)` DESC on every entry and review list; ranked lists key on
their own order: `place_dishes` `(review_count, score, name, dish_id)`, `feed_areas` `(entry_count, area)`, `statement_months` `month`, Saved
`(saved_at, dish_id)`, Search scopes `(match_tier, review_count|username, name, id)`, Nearby `(distance_m, id)`.

| Screen | Call | Returns |
|---|---|---|
| Feed | `rpc get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, p_include_own, p_area)` | `entry_cards[]` — every entry, blocked users already gone. `p_include_own` defaults **false** (your visits live in Journal). `p_area` (0038): null = everywhere; else a `feed_areas` `area` → only rows whose `place.locality` matches (trimmed, case-insensitive). Same keyset |
| Feed — area picker | `rpc feed_areas(p_limit, p_cursor_entry_count, p_cursor_area)` | `{area, entry_count}[]`, busiest first then A→Z — the localities of what the Feed shows you (your own excluded, so no listed area opens empty). `p_limit` default 30, max 100; keyset `(entry_count, area)` — pass both from the last row |
| Journal · Profile | `rpc get_entries_by_author(p_author_id, cursor…, p_page_size)` | `entry_cards[]` — the same rows whoever asks (a blocked author: `[]`) |
| Entry · Share | `GET /rest/v1/entry_cards?id=eq.<uuid>` | one `entry_card` |
| Place — header | `rpc place_summary(p_restaurant_id)` | `{restaurant_id, name, address, city, cuisine, cover_url, avg_rating, review_count, people_count, dish_count, my_visits, my_last_visit, locality, entry_count}` — **`locality` is the second chip** (`city` is unreliable, see below); `entry_count` = visits here, `review_count` = receipt lines; every text field is `null`, never `''` |
| Place — what to order | `rpc place_dishes(p_restaurant_id, p_limit, p_cursor_review_count, p_cursor_score, p_cursor_dish_name, p_cursor_dish_id)` | `{dish_id, dish_name, score, people_count, review_count, cover_url}[]` — **`review_count` DESC leads**, then `score` DESC (unscored last), then name, then id: the ported `DishRanking` rule, so one 5.0 from one person cannot lead the menu. **Never re-sort it client-side.** A dish with no line at all is not returned. **4-part keyset: pass all four from the last row** (`p_cursor_score` may be null) |
| Place — entries | `rpc get_entries_at_place(p_restaurant_id, p_scope, cursor…)` | `entry_cards[]`; `p_scope ∈ 'all'|'mine'|'others'` |
| Dish — header | `rpc dish_summary(p_dish_id)` | `{dish_id, dish_name, restaurant_id, restaurant_name, restaurant_city, score, review_count, scored_count, people_count, cover_url, saved, my_last_score, photos, restaurant_locality, tags}` — `photos` = `[{url, entry_id}]` newest first for the header stack, `[]` when none, and **`photos[0].url == cover_url`**; `tags` = codes **at least half** of the `review_count` lines carry (and ≥1), `[]` when none |
| Dish — reviews | `rpc get_dish_reviews(p_dish_id, p_cursor_mine, p_cursor_created_at, p_cursor_id, p_page_size)` | `{review_id, entry_id, author{…}, score, note, created_at, is_mine, photos[]}[]` — **mine first**, then newest. Keyset is 3-part: pass `is_mine`, `created_at`, `id` from the last row. **`entry_id` is nullable** (a pre-entries line has no entry to open — decode optional, hide the tap); `photos[]` is the review's ENTRY's |
| Saved | `GET /rest/v1/my_saved_dishes?order=saved_at.desc,dish_id.desc&limit=N` | `{dish_id, dish_name, restaurant_id, restaurant_name, restaurant_city, dish_score, dish_cover_url, source_entry_id, source_user_id, source_username, saved_at, cover_url}[]` — keyset below; client groups by restaurant |
| You · Profile header | `rpc profile_summary(p_user_id)` | `{user_id, username, name, avatar_url, bio, city, created_at, orders, places, dishes, scored, avg_score, is_me}` — `orders`/`places` count ENTRIES, `dishes`/`scored`/`avg_score` count receipt LINES (and now agree with `score_histogram`) |
| Ratings histogram | `rpc score_histogram(p_user_id)` | 10 rows `{score, dish_count, review_count}` for 0.5…5.0, **zeros included** — draw bars straight from it. The label ("36 dishes") is `dish_count` |
| Ratings bar tap · "Your 5.0s" | `rpc dishes_by_score(p_user_id, p_score, p_limit, p_cursor_created_at, p_cursor_id)` | `{review_id, entry_id, dish_id, dish_name, restaurant_id, restaurant_name, score, note, created_at, cover_url}[]`, newest first, keyset `(created_at, id)`. `cover_url` is the DISH's photo (the tile), `created_at` is the visit's date, `entry_id` is **nullable** |
| Recap picker | `rpc statement_months(p_user_id, p_tz, p_cursor_month, p_limit)` | `{month (date), orders}[]`, newest first; `orders` is that month's ENTRY count. Keyset: pass the last row's `month` |
| Recap | `rpc monthly_statement(p_user_id, p_month, p_tz)` | one jsonb (below) |
| Search — Places | `rpc search_places(p_query, p_limit, p_cursor_match_tier, p_cursor_review_count, p_cursor_name, p_cursor_id)` | `{restaurant_id, name, cuisine, locality, avg_rating, review_count, people_count, dish_count, cover_url, match_tier}[]` |
| Search — Dishes | `rpc search_dishes(p_query, p_limit, p_cursor_match_tier, p_cursor_review_count, p_cursor_dish_name, p_cursor_dish_id)` | `{dish_id, dish_name, restaurant_id, restaurant_name, restaurant_locality, score, review_count, scored_count, people_count, cover_url, match_tier}[]` — the whole row in one call |
| Search — People | `rpc search_people(p_query, p_limit, p_cursor_match_tier, p_cursor_username, p_cursor_user_id)` | `{user_id, username, name, avatar_url, city, is_me, match_tier}[]` — handle OR name; you can find yourself (`is_me`) |
| Search — Saved | `rpc search_saved(p_query, p_limit, p_cursor_saved_at, p_cursor_dish_id)` | `my_saved_dishes`' columns + `restaurant_locality`; dish OR place name; **empty/null query = the whole list** |
| Search — Nearby (before typing) | `rpc nearby_places(p_lat, p_lng, p_radius_m, p_limit, p_cursor_distance_m, p_cursor_id)` | `{restaurant_id, name, cuisine, locality, avg_rating, review_count, people_count, dish_count, cover_url, distance_m}[]` — places we hold, nearest first; no Google call |
| Composer place sheet | `rpc search_all(p_query, p_limit_per_kind)` | `{kind, id, title, subtitle, score, match_rank, detail}[]`, unpaged; the Search TAB uses the scope RPCs |
| Handle availability | `rpc handle_available(p_handle)` | bool, **case-insensitive** (citext; `Eamon` = `eamon`), trims, 1–30 chars; the character set is the client's rule. **Use this, not a `profiles` select** — RLS can make a taken handle look free |
| Settings — blocked | `rpc my_blocks(p_limit, p_cursor_created_at, p_cursor_blocked_id)` | `{blocked_id, username, name, avatar_url, city, created_at}[]`, newest first. **Not** a `blocks` embed: `profiles` RLS nulls exactly these people |

**Search scopes (0031):** matching is accent-insensitive (`ragu` finds `ragù`) and needs ≥2 characters
(fewer → `[]`); rows come ranked `match_tier` (0 exact · 1 prefix · 2 word-start · 3 contains) → `review_count`
desc → name → id. **Never re-sort.** Blocked people, and dishes only they logged, are absent. Text is `null`, never `''`.

**A place's label is `locality`, never `city`.** Rows resolved live before 0031's PR hold a mangled
`"<street>, <suburb STATE post>"` in `city`; every `locality`/`restaurant_locality` (place, dish, search rows,
`search_all`'s subtitle) is derived on read and is the only thing safe to print. `null` → draw no chip.

**Saved** next page: `&or=(saved_at.lt.<last>,and(saved_at.eq.<last>,dish_id.lt.<last dish_id>))`. Never order
by `restaurant_name` (no stable cursor; grouping is presentation). `cover_url` == `dish_cover_url`.

`monthly_statement` → `{month, username, orders, places, new_places, dishes, stars, average,
top_dishes:[{dish_id, dish_name, restaurant_name, score}], most_ordered:{dish_name,count}|null,
most_visited:{restaurant_id, restaurant_name, count}|null}`. Months are local to `p_tz` (default
`Australia/Melbourne`; pass the device zone). `average`/`stars` cover scored lines only. `most_ordered`/
`most_visited` are **null below a count of 2** — "Most ordered … x1" is not a habit, so print nothing.

**Printing an aggregate: one decimal, as sent** (`4.6`, never rounded to `4.5` — `ScoreFormat.average`); only
the STAR GLYPHS round to the half. An entry's `avg_score` keeps 2 decimals (`Avg 3.75`); a review prints `4.0`.

## Writes

### Create an entry — the words land first, alone
```
POST /rest/v1/entries
{ "id": <client uuid>, "author_id": <me>, "body": "…",     // no "visibility": deprecated, any value lands public
  "restaurant_id": <uuid>,               // REQUIRED (0040): the place the user tapped
  "created_at": "<when they wrote it>" }  // optional; send it for offline entries
```
- **`restaurant_id` is required (0040).** Without it the insert fails `23502` with message `place_required`
  (the order number is not consumed). Pre-0040 placeless entries keep working (edits, sorts, `correct_entry_place`).
- **INSERT, never upsert.** On `23505` (duplicate key) the entry already landed — treat as success.
- Sending `restaurant_id` stamps `restaurant_source = 'user'`, which the sorter will not overwrite.
- The response carries the server-assigned `order_number` + `sort_status: "pending"`. Never send
  `order_number`/`sort_status`/any `sort_*`/`place_*` — those columns are not grantable to you.

### Photos (as each upload finishes)
Upload to `review-photos/<auth.uid()>/<file>` → public URL → `POST /rest/v1/entry_photos`
`{entry_id, position, photo_url}` with `Prefer: resolution=merge-duplicates` on `(entry_id, position)`. The small
variant goes beside it at `<path minus extension>_t.jpg` (same owner-folder policy; no row of its own).

### Sort it
```
POST /functions/v1/sort-entry     { "entry_id": "<uuid>", "force": false, "dry_run": false,
                                    "tag_tokens": [{ "offset": 23, "length": 2 }] }   // optional, 0036
→ 200 { ok, mode: "stub"|"model", model, entry_id, sort_status, restaurant_id,
        place_query, place_offset, items:[…] }
  401 unauthorized · 403 not your entry · 404 unknown entry · 422 entry_id missing · 500 sort failed
```
Call it right after the insert (and on retry for anything left `pending`/`failed`). Idempotent: an
already-sorted entry returns `{ok: true, skipped: "already sorted"}` unless `force`; `dry_run` returns the
plan without writing. Then refetch `entry_cards?id=eq.<uuid>`. **`force` cannot destroy a correction** —
the rule below is enforced in SQL, not by the caller remembering it. **Tag chips:** the chip prints its word
in `body` ("GF"); send where it sits in `tag_tokens` (UNICODE SCALARS, like every offset). The sorter reads
it (`gf`, `gluten free`, `vegan`, `GF/DF`…) onto the dish it FOLLOWS. Unmarked words never tag; omitting
`tag_tokens` on a re-sort removes nothing.

**Early sort (0039).** While composing, `{ "preview": true, "body": "<draft>", "tag_tokens": […],
"restaurant_id": "<uuid|null>" }` (no `entry_id`) → 200 `{ok, preview: true, cached, mode, model, entry_id: null,
restaurant_id, place_query, place_offset, items}` — the sort's plan shape. **Writes no entry and no line.** 422
bad draft (>10k chars, bad uuid) · 429 `{error, retry_after}` over 12 previews / 10 min (a repeat of a cached
draft is free) — ignore it; Done still sorts. In model mode the model's plan is cached 15 min under (you,
sha256(body), tag_tokens, restaurant_id); **send exactly the body, tokens and place you will INSERT** and the
sort after Done reuses it — no second model call (`entries.sort_meta.cache_hit`) — then deletes it. The plan
holds draft words, so expired rows are purged on every preview and deleting an entry or account purges yours.

### Corrections (the user's, always)
| Action | Call |
|---|---|
| Fix the place | `rpc correct_entry_place(p_entry_id, p_restaurant_id)` → the entry row. Re-resolves every line's dish at the new place, or prints the parked plan if the entry had none. Pins `restaurant_source='user'`, records `place_corrected_at`, clears the place token |
| Fix a line's dish | `rpc correct_entry_dish(p_review_id, p_dish_id, p_dish_name)` → dish uuid. Pass `p_dish_id` for a menu pick, `p_dish_name` to name one. Score and note untouched |
| Set / clear a score | `PATCH /rest/v1/reviews?id=eq.<uuid>` `{ "score": 4.5 }` (or `null`). Half steps 0.5–5.0 |
| Set a line's tags | `PATCH /rest/v1/reviews?id=eq.<uuid>` `{ "tags": ["gf", "v"] }` — the WHOLE set (`[]` clears). Canonicalised server-side; a code outside the five is `23514`; owner only. Not a correction |
| Edit the words | `PATCH /rest/v1/entries?id=eq.<uuid>` `{ "body": "…" }`. (A `{visibility}` PATCH still succeeds and changes nothing — remove the control) |
| Delete a visit | `rpc delete_entry(p_entry_id)` → `{photo_paths: [String]}` (0037), then `storage.from("review-photos").remove(paths: photo_paths)`. Paths are bucket-relative (`<uid>/<file>`), originals + their `_t.jpg`, yours only. Cascades photos rows, lines, their tags; dishes/places stay; aggregates move at once. `42501` not yours · `P0002` already gone (treat as done). A raw `DELETE /rest/v1/entries` still works but leaks the files |

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

Rules 7/9 bound what the SORTER may write, never what the user keeps. Never write `reviews` for a new entry:
the sorter's RPC owns dish creation (select-then-insert on a partial unique index — `data-model.md` Landmines).

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

### Account — Sign in with Apple, and deletion (0032)
- **Sign in:** native only. `ASAuthorizationAppleIDRequest` with `nonce = sha256(raw)`, then
  `auth.signInWithIdToken(.init(provider: .apple, idToken:, nonce: raw))`. Apple usually sends **no name and
  may send no email** (or a private-relay one); the account still gets a profile with a placeholder handle
  (`ate<8 hex>`), so route every new user through the first-run Handle screen (`handle_available`, then PATCH
  `profiles.username`/`name`). If `fullName` arrives on the first credential, PATCH `name` from it.
- **Delete account** (App Store 5.1.1(v)) — in this order: (1) list + delete your objects under
  `review-photos/<uid>/` and `avatars/<uid>/`; (2) `rpc delete_account()` → `{ok, auth_user_deleted}`;
  (3) sign out locally. It returns `{ok: true, auth_user_deleted: true}` or **raises, having deleted
  nothing** (0035) — show an error and let them retry. `deactivate_account` is NOT deletion; do not call it.
  A deactivated profile (and its entries and lines) is hidden from every other viewer, signed in or out.

## The sorter (`supabase/functions/sort-entry`)

Two modes, one contract. **stub** (default, no network). **model**: a forced tool call, **only** with the
`ANTHROPIC_API_KEY` secret set (`ATE_SORTER_MODE=stub` forces stub); a failure degrades to the stub.
`ATE_SORTER_MODEL` = `claude-haiku-4-5` (default) | `claude-sonnet-5`, anything else → default; the response's
`model` names it (null when the stub sorted). **Choose by eval:** from the function dir with the key in env,
`deno run --allow-net --allow-env eval.ts --both` (or `--model <id>`; `node eval.ts` works too) grades each model
on the corpus: per-fixture PASS/CORE(dishes+scores)/FAIL, gate rejections, p50/p95, tokens and dollars.

Both are post-validated identically, in TypeScript and SQL: a **score** survives only if its `score_evidence`
is a literal substring of `body` **and** contains that number; a **note** only if a literal, case-sensitive
substring (Postgres `position()`); a **dish** only if named in the words or on the matched menu; an **offset**
only if the body says that text there, else recomputed from the first occurrence, else null.

A note is the **clause after the dish and its score**, cut at the next dish, glue trimmed (what
`design/v1/Entry` prints). A matched dish keeps the menu's spelling; a new one is capitalised. A score the
sentence marks belongs to the dish before it (`"<dish> was a 4.5"`, `"gave the <dish> a 4"`); `"table for 4"`
never scores. The attached place's own name is never a dish, nor the front half of one.

The place comes from the words alone, matched against restaurants we already hold
(`search_local_restaurants`, 0017) — never Google, never location, never a new row. **No place ⇒ no dish
reviews** (a dish needs a restaurant): the entry is still `sorted`, its findings park in
`entries.sort_plan`, and `correct_entry_place` prints the receipt retroactively. `fixtures.ts` pins every rule
(`modelOnly` entries grade the model, not the stub): `node --test supabase/functions/sort-entry/*_test.ts`.

## `places-search`

`op=autocomplete` (blended `results[]`: `kind:'place'` = resolve on select, `kind:'manual'` = already a row) ·
`op=details` (upserts the row; the only restaurant-create path) · `op=nearby` (PostGIS-first, `restaurants[]`
with `distance_meters`). Verified end-user JWT + per-user rate limit on every op; stub mode when
`GOOGLE_PLACES_API_KEY` is absent. The VIC bounding box is a launch-market constant — when the market
changes, make it config, do not fork the function. `restaurants.city` is written as the bare suburb (0031's
PR, same rule as `place_locality()`); rows written before keep the mangle — read `locality`.

## Wire-change log

**Round 3 — 0037–0040 + sort-entry.** Additive: `delete_entry`, `feed_areas`, `get_entry_feed(p_area)` (default
null = today's feed; drop+create, old calls bind), sort-entry `preview`, `sort_meta` on `correct_entry_place`'s
returned row. **Breaking (sequenced via the lead):** an `entries` INSERT without `restaurant_id` is `23502
place_required` — no build that allows a placeless Done may be live when 0040 lands.

**Additive — 0036.** `reviews.tags`, `entry_cards.items[].tags`, `dish_summary.tags` (+ browse twin),
sort-entry `tag_tokens` in and `items[].tags` out. A re-sort never removes a tag.

**Additive — sort-entry.** `model` (string|null) on sort and dry-run 200s (not on `skipped`). `mode` values unchanged.

**Behavioural — 0035.** `delete_account` raises instead of a partial `ok`; sign-up always creates a profile
(or fails whole); deactivated profiles vanish from every read. `deactivate_account` is retired (not
executable), and a `profiles` PATCH may touch only `username, name, avatar_url, bio, city` (else `42501`). Additive: `entry_cards.place.locality`.

**Additive — 0034.** anon may EXECUTE the nine browse reads above (401/42501 → rows). Signed-in callers: same
parameters, columns and query. Client: drop the `requireCurrentUserID()` guard on those reads when browsing.

**Behavioural — 0033 (2026-09-25): every entry is public.** Every formerly-private entry flips public and
now appears in the feed, on profiles, place/dish pages, search, and everyone's counts, averages and covers
(numbers can move). `visibility` stays on `entries`/`entry_cards`, always `public`, so no decoder breaks;
an insert/PATCH sending `private` succeeds and lands public. **Follow-up (breaking, sequenced):** drop the
column once no TestFlight build reads or writes it.

**Earlier (0018–0032, all additive or sequenced):** entries/photos/saves/blocks/reports and their RPCs; the
correction + offset columns; covers from `entry_photos`; `place_summary.locality`/`entry_count`, `dish_summary`
`photos`; Search scopes (accent-insensitive); `delete_account()`/`my_blocks()`. Behavioural: `place_dishes` is the
`DishRanking` order (`p_cursor_people` → `p_cursor_review_count`); `profile_summary` counts lines by `reviewer_id`;
empty text is `null`; `most_*` null at 1; a report `reason` outside the vocabulary is `23514`.

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
before the entry has a place). `23502 place_required` = an entry insert with no place (0040). `P0002` from
`delete_entry` = already gone. `429` from `places-search` or a sort-entry preview = rate limited.
