# Ate — client ↔ server contract (V1)

Everything the app calls, with shapes. Schema lives in `data-model.md`. **Complete enough to build the
Swift client against without asking a question** — if something is missing, that is a bug in this file.
**Environments are law:** Debug → STAGING `cvoitgoaosofkougmarn`, Release → PROD `vyaexmnajnbryimbkgkf`;
migrations reach staging when the lead applies them after QA (until a staging-deploy job exists) and prod only via an explicit CI job. The contract is tested twice: `supabase/tests/db/*.mjs` pins behaviour on the whole migration chain (PGlite, every backend PR), and AteKit's `ContractSmokeTests` decodes one live read per surface from staging as `ci@ate.test` (never a person's account). Auth: Supabase Auth (Apple +
email; see Account below); every call carries the user's token. `anon` has no table access (a raw read →
`[]` or `42501`). **Every entry is public (0033).** **Signed out (0034):** with the publishable key alone, only
`get_entry_feed`, `feed_areas`, `feed_cities`, `resolve_city`, `get_entry_card`, `get_entries_by_author`, `get_entries_at_place`, `place_summary`, `place_dishes`,
`dish_summary`, `get_dish_reviews`, `profile_summary` and `is_dish_saved` answer — same shapes, with
`is_mine`/`is_me`/`saved`/`items[].saved` = `false`, `my_visits` = 0, `my_last_*` = null, scope `mine` = `[]`.
Everything else (the raw `entry_cards` view — use `get_entry_card` — search, stats, every write) needs a session.

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
their own order: `place_dishes` + `dishes_by_tag` `(score, review_count, name, dish_id)`, `feed_areas` `(entry_count, area)`, `statement_months` `month`, Saved
`(saved_at, dish_id)`, Search scopes `(match_tier, review_count|username, name, id)`, Nearby `(distance_m, id)`.

| Screen | Call | Returns |
|---|---|---|
| Feed | `rpc get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, p_include_own, p_area, p_city, p_kind, p_slug)` | `entry_cards[]` — every entry, blocked users already gone. `p_include_own` defaults **false** (your visits live in Journal). `p_area` (0038): a `feed_areas` `area` (locality match). `p_city` (0046): a city slug → only entries whose place maps to it; unknown → `[]`. Null = everywhere; both compose. `p_kind` + `p_slug` (0057, the tag page): only entries with a line whose dish carries that tag (`dishes_by_tag`'s kinds: style · cuisine · suburb · city · diet); both null = no filter; one alone or an unknown kind → `22023`; unknown slug → `[]`. Same keyset, same filters every page |
| Feed — city picker · near me (0046) | `rpc feed_cities()` · `rpc resolve_city(p_lat, p_lng)` | `{city, name, region, lat, lng, radius_m, entry_count}[]` — cities with food for you, busiest first, unpaged · 0 or 1 such row + `distance_m`, `is_nearby`: the city with food holding the point (true), else the nearest with food (false); no point → busiest (false, `distance_m` null); `[]` = no city has food → `p_city` null. The point is never stored |
| Feed — The Top Ate (0055) | `rpc top_ate(p_city, p_limit)` | `{rank, dish_id, name, restaurant_id, restaurant_name, suburb, score, review_count, cover_url, saved}[]`, rank 1…n. Dishes with a line in the last 7 days (fewer than `p_limit` → 30 days → all time; the widened window ranks as ONE list) by ALL-TIME printed score; scored lines from 2 DIFFERENT people minimum. Within a score: photographed first (tie-break, never a filter), orders, name. Default 8, max 20. Signed out: same rows, `saved` false |
| Feed — Because you loved (0055) | `rpc because_you_loved(p_city, p_limit)` | `{anchor_dish_id, anchor_name, dish_id, name, restaurant_id, restaurant_name, score, review_count, cover_url, saved}[]` — the anchor repeats on every row. Anchor = the dish of your newest line scored 5.0 or 6 (next-newest, up to 5, when one has no rows); rows = `similar_dishes`' rule over dishes in the city you never logged. Default 10, max 30. `[]` (hide the section) signed out or with no 5.0 yet |
| Feed — New to the record (0055) | `rpc new_to_record(p_city, p_since, p_limit, p_kind, p_slug)` | `{dish_id, name, restaurant_name, suburb, kind, cover_url, saved, at}[]`. `kind` `six` · `five` (a line scored 6 / 5.0 after `p_since`) · `new` (the dish's FIRST line is after it) — one row per dish, strongest kind; `at` = that line's time. Others' lines only (yours are not news to you). Order six → five → new, then `at` desc. `p_since` = your last open (null → 7 days; clamped to 90 days back). Default 6, max 20. `p_kind` + `p_slug` (0057): only dishes carrying that tag (same rules as the Feed's). Signed out: `saved` false |
| Feed — taste tags (0057) | `rpc my_taste_tags(p_city, p_limit)` | `{kind, slug, label, weight}[]` — style + cuisine tags on dishes you scored 4.5+ (per line; a 5.0 or 6 counts 2) or saved (1 per dish), minus the cravings you already follow. Seeds Feed shelves without asking: each one's shelf = `dishes_by_tag(kind, slug, …, p_city)`. Order weight desc, label. `p_city` = a city slug (null = everywhere). Default 12, max 50. Signed out `[]` |
| Feed — cravings (0055) | `rpc craving_options()` · `rpc my_cravings()` · `rpc set_cravings(p_cravings)` | Picker: `{kind, slug, label, group}[]` — `group` `dishes` (style tags) then `cuisines` (cuisine tags), busiest first, only tags on logged dishes; `moods` none yet; signed out works. Yours: `{kind, slug, label}[]` in shelf order (signed out `[]`). Set: `p_cravings` = JSON array `[{kind, slug}]` in shelf order — REPLACES the set (`[]` clears; duplicates collapse; max 24); returns the new set. Unknown kind/tag or bad shape → `22023`; signed out → `42501`. A tag you already follow is always accepted back. Each craving's shelf = `dishes_by_tag(kind, slug, …, p_city)` |
| Feed — area picker | `rpc feed_areas(p_limit, p_cursor_entry_count, p_cursor_area)` | `{area, entry_count}[]`, busiest first then A→Z — the localities of what the Feed shows you (your own excluded, so no listed area opens empty). `p_limit` default 30, max 100; keyset `(entry_count, area)` — pass both from the last row |
| Journal · Profile | `rpc get_entries_by_author(p_author_id, cursor…, p_page_size)` | `entry_cards[]` — the same rows whoever asks (a blocked author: `[]`) |
| Journal — filter + sort (0043) | `rpc my_entries(p_sort, p_restaurant_id, p_min_score, p_tag, p_from, p_to, p_limit, p_cursor_created_at, p_cursor_id, p_cursor_best_score, p_tz)` | `{id, created_at, best_score}[]`, YOUR entries only, in order — then read the cards with `entry_cards?id=in.(…)` and keep this order. `p_sort` `newest` (default) · `oldest` · `top` (best line score, unscored last), else `22023`. All filters optional: place; `best_score >= p_min_score`; one tag code; visit dates inclusive in `p_tz` (default `Australia/Melbourne`; pass the device zone). Keyset: pass all three fields of the last row. `p_limit` 30, max 100 |
| Journal · Search — range + city (0047) | `p_max_score`, `p_city` appended to `my_entries`, `search_places`, `search_dishes`, `nearby_places` · pickers `rpc my_entry_cities()` → `{city, name, region, entry_count}[]`, `rpc search_cities()` → `{city, name, region, place_count}[]` | No bound = every row; ANY bound drops unscored; `>= p_min_score`; `<= p_max_score` **unless it is ≥ 6 — the end of the track is open** (0054; before it, ≥ 5). So `[x, 5]` leaves a 6 (and a 5.3 average) out, `[x, 6]` or no ceiling keeps it; "5.0s" = `5, 5`; only 6s = `p_min_score: 6`. `p_restaurant_id` still works. Keysets unchanged |
| Journal — calendar · "Show N entries" (0053) | `rpc journal_days(p_from, p_to, p_tz, [p_min_score, p_max_score, p_city, p_restaurant_id, p_tag])` · `rpc my_entries_count(<same filters as my_entries>)` | `{day (date), entries, best_score, cover_url}[]`, oldest day first, one row per local day (p_tz; pass the device zone) with your entries. p_from/p_to inclusive, null = open (no default: pass them). `best_score` null = nothing scored, may be `6.0`; `cover_url` = the newest entry that day with a photo. **Month dividers = the sum of that month's rows, with the list's filters.** The count is an int — exactly what `my_entries` pages out |
| Journal — place filter | `rpc my_entry_places()` | `{restaurant_id, name, locality, entry_count}[]` — where your entries are, busiest first. Optional keyset `(p_limit, p_cursor_entry_count, p_cursor_name, p_cursor_restaurant_id)`; no args = all |
| Entry · Share link (`ate://entry/<id>`) | `rpc get_entry_card(p_entry_id)` (0048; or `GET /rest/v1/entry_cards?id=eq.<uuid>` signed in) | one `entry_card`, or `[]` = not visible / gone → "unavailable", never an error. **Works signed out** (`is_mine`/`saved` false) |
| Place — header | `rpc place_summary(p_restaurant_id)` | `{restaurant_id, name, address, city, cuisine, cover_url, avg_rating, review_count, people_count, dish_count, my_visits, my_last_visit, locality, entry_count}` — **`locality` is the second chip** (`city` is unreliable, see below); `entry_count` = visits here, `review_count` = receipt lines; every text field is `null`, never `''` |
| Place — what to order | `rpc place_dishes(p_restaurant_id, p_limit, p_cursor_review_count, p_cursor_score, p_cursor_dish_name, p_cursor_dish_id)` | `{dish_id, dish_name, score, people_count, review_count, cover_url, tags}[]` — `tags` = the dish's chips, the `dish_summary.tags` rule (0045). **By rating (0051):** printed `score` DESC (a 6 above every 5), then `review_count` DESC, then name, then id; unscored dishes after every scored one. **Never re-sort it client-side** (AteKit's `DishRanking` is the retired review-count-first rule). A dish with no line at all is not returned. **4-part keyset: pass all four from the last row** (`p_cursor_score` may be null) |
| Place — entries | `rpc get_entries_at_place(p_restaurant_id, p_scope, cursor…)` | `entry_cards[]`; `p_scope ∈ 'all'|'mine'|'others'` |
| Dish — header | `rpc dish_summary(p_dish_id)` | `{dish_id, dish_name, restaurant_id, restaurant_name, restaurant_city, score, review_count, scored_count, people_count, cover_url, saved, my_last_score, photos, restaurant_locality, tags}` — `photos` = `[{url, entry_id}]` newest first for the header stack, `[]` when none, and **`photos[0].url == cover_url`**; `tags` = codes **at least half** of the `review_count` lines carry (and ≥1), `[]` when none |
| Dish — tag chips (0053) | `rpc dish_tags(p_dish_id)` | `{kind, slug, label}[]`: `style` (1–3, lower-case "pasta") → `cuisine` → `suburb` → `city` → `diet` (== `dish_summary.tags`, label `GF`). Slugs are opaque — pass them back to `dishes_by_tag` verbatim (a suburb's is city-qualified) |
| Dish — more like this (0053) | `rpc similar_dishes(p_dish_id, p_limit)` | `{dish_id, name, restaurant_id, restaurant_name, score, review_count, cover_url}[]` — shares a style or the cuisine; weighted overlap (style > cuisine > suburb > city), then score. Default 10, max 50, unpaged |
| Tag results (0053) · craving shelf (0055) | `rpc dishes_by_tag(p_kind, p_slug, p_limit, p_cursor_score, p_cursor_review_count, p_cursor_name, p_cursor_dish_id, p_city)` | the same row + `saved` (0055), best first (`place_dishes`' order: score, a 6 above every 5, unscored last → review_count → name → id). 4-part keyset, pass all four from the last row. `p_kind` ∉ the five → `22023`; unknown slug → `[]`. `p_city` (0055): only dishes whose place is in that city (null = everywhere, unknown → `[]`). Signed in only |
| Dish — reviews | `rpc get_dish_reviews(p_dish_id, p_cursor_mine, p_cursor_created_at, p_cursor_id, p_page_size)` | `{review_id, entry_id, author{…}, score, note, created_at, is_mine, photos[]}[]` — **mine first**, then newest. Keyset is 3-part: pass `is_mine`, `created_at`, `id` from the last row. **`entry_id` is nullable** (a pre-entries line has no entry to open — decode optional, hide the tap); `photos[]` is the review's ENTRY's |
| Saved | `GET /rest/v1/my_saved_dishes?order=saved_at.desc,dish_id.desc&limit=N` | `{dish_id, dish_name, restaurant_id, restaurant_name, restaurant_city, dish_score, dish_cover_url, source_entry_id, source_user_id, source_username, saved_at, cover_url}[]` — keyset below; client groups by restaurant |
| You · Profile header | `rpc profile_summary(p_user_id)` | `{user_id, username, name, avatar_url, bio, city, created_at, orders, places, dishes, scored, avg_score, is_me}` — `orders`/`places` count ENTRIES, `dishes`/`scored`/`avg_score` count receipt LINES (and now agree with `score_histogram`) |
| Ratings histogram | `rpc score_histogram(p_user_id)` | **11 rows** `{score, dish_count, review_count}` for 0.5…5.0 then **6.0** (0041), **zeros included** — draw bars straight from it. The label ("36 dishes") is `dish_count` |
| Ratings bar tap · "Your 5.0s" | `rpc dishes_by_score(p_user_id, p_score, p_limit, p_cursor_created_at, p_cursor_id)` | `{review_id, entry_id, dish_id, dish_name, restaurant_id, restaurant_name, score, note, created_at, cover_url}[]`, newest first, keyset `(created_at, id)`. `cover_url` is the DISH's photo (the tile), `created_at` is the visit's date, `entry_id` is **nullable** |
| Recap picker | `rpc statement_months(p_user_id, p_tz, p_cursor_month, p_limit)` | `{month (date), orders}[]`, newest first; `orders` is that month's ENTRY count. Keyset: pass the last row's `month` |
| Recap | `rpc monthly_statement(p_user_id, p_month, p_tz)` | one jsonb (below) |
| Search — Places | `rpc search_places(p_query, p_limit, p_cursor_match_tier, p_cursor_review_count, p_cursor_name, p_cursor_id)` | `{restaurant_id, name, cuisine, locality, avg_rating, review_count, people_count, dish_count, cover_url, match_tier}[]` |
| Search — Dishes | `rpc search_dishes(p_query, p_limit, p_cursor_match_tier, p_cursor_review_count, p_cursor_dish_name, p_cursor_dish_id)` | `{dish_id, dish_name, restaurant_id, restaurant_name, restaurant_locality, score, review_count, scored_count, people_count, cover_url, match_tier, tags}[]` — the whole row in one call; `tags` as `dish_summary.tags` (0042) |
| Search — People | `rpc search_people(p_query, p_limit, p_cursor_match_tier, p_cursor_username, p_cursor_user_id)` | `{user_id, username, name, avatar_url, city, is_me, match_tier}[]` — handle OR name; you can find yourself (`is_me`) |
| Search — Saved · Saved shelf filtered | `rpc search_saved(p_query, p_limit, p_cursor_saved_at, p_cursor_dish_id, p_min_score, p_max_score, p_city)` · picker `rpc my_saved_cities()` | `my_saved_dishes`' columns + `restaurant_locality`; dish OR place name; **empty/null query = the whole list**. 0049: range on `dish_score` (the Journal's rule: max ≥ 6 is open, 0054) + city · `{city, name, region, dish_count}[]` |
| Search — Nearby (before typing) | `rpc nearby_places(p_lat, p_lng, p_radius_m, p_limit, p_cursor_distance_m, p_cursor_id)` | `{restaurant_id, name, cuisine, locality, avg_rating, review_count, people_count, dish_count, cover_url, distance_m}[]` — places we hold, nearest first; no Google call |
| Search — filter choices | `rpc search_cuisines()` | `{cuisine, place_count}[]`, busiest first — pass `cuisine` back in `p_cuisines` |
| Composer place sheet | `rpc search_all(p_query, p_limit_per_kind)` | `{kind, id, title, subtitle, score, match_rank, detail}[]`, unpaged; the Search TAB uses the scope RPCs |
| Handle availability | `rpc handle_available(p_handle)` | bool, **case-insensitive** (citext; `Eamon` = `eamon`), trims, 1–30 chars; the character set is the client's rule. **Use this, not a `profiles` select** — RLS can make a taken handle look free |
| Settings — blocked | `rpc my_blocks(p_limit, p_cursor_created_at, p_cursor_blocked_id)` | `{blocked_id, username, name, avatar_url, city, created_at}[]`, newest first. **Not** a `blocks` embed: `profiles` RLS nulls exactly these people |

**Date windows (0050):** `search_places`, `search_dishes`, `nearby_places` and `search_saved` take optional trailing `p_from`, `p_to` (dates, inclusive, either open) and `p_tz` (default `Australia/Melbourne`) — `my_entries`' rule. Search: only lines whose VISIT day is in the window count (score/avg_rating and the review/scored/people/dish counts are the window's; a row with none is not a result; `cover_url` and `tags` stay all-time), so a row can print a different number from the page it opens — show the date chip whenever a window is on. Saved: the day it was SAVED.

**Search filters (0042):** `search_places`, `search_dishes`, `nearby_places` take optional trailing `p_cuisines text[]`
(any, case-insensitive), `p_tags text[]` (`gf df v vg nf`; a dish's chips carry EVERY code — one plate that is
both; a place matches when one of its dishes does; an unknown code matches nothing) and `p_min_score numeric`
(`avg_rating`/`score` ≥). NULL or `[]` = off. Keysets unchanged — **send the same filters on every page**.

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
                                    "tag_tokens": [{ "offset": 23, "length": 2 }],    // optional, 0036
                                    "six_tokens": [{ "offset": 9, "length": 1 }] }    // optional, 0041
→ 200 { ok, mode: "stub"|"model", model, entry_id, sort_status, restaurant_id,
        place_query, place_offset, items:[…], entry_card }      // entry_card: 0056
  401 unauthorized · 403 not your entry · 404 unknown entry · 422 entry_id missing · 500 sort failed
```
Call it right after the insert (and on retry for anything left `pending`/`failed`). Idempotent: an
already-sorted entry returns `{ok: true, skipped: "already sorted"}` unless `force`; `dry_run` returns the
plan without writing. **`entry_card` (0056)** is the sorted `entry_cards` row exactly as `get_entry_card`
returns it to you (also on the `skipped` reply): render it, no refetch. It is `null` if that read failed —
then refetch `entry_cards?id=eq.<uuid>` as before. **Warm-up:** `{ "health": true }` → `200 {ok, health}`,
touches nothing; fire it when the composer opens so Done does not pay a cold start. **`force` cannot destroy a correction** —
the rule below is enforced in SQL, not by the caller remembering it. **Tag chips:** the chip prints its word
in `body` ("GF"); send where it sits in `tag_tokens` (UNICODE SCALARS, like every offset). The sorter reads
it (`gf`, `gluten free`, `vegan`, `GF/DF`…) onto the dish it FOLLOWS. Unmarked words never tag; omitting
`tag_tokens` on a re-sort removes nothing. **The secret 6 (0041):** a 6 exists only where the composer marked
it — send each marked `6`/`6.0` in `six_tokens` (scalars). It scores the dish it follows; a typed "6" never does. A re-sort without `six_tokens` keeps a 6 on its LINE
(0044): wherever the dish now sits, if its score span still reads a lone 6. Changed to a 4 → 4; dish removed → gone.

**Early sort (0039).** While composing, `{ "preview": true, "body": "<draft>", "tag_tokens": […], "six_tokens": […],
"restaurant_id": "<uuid|null>" }` (no `entry_id`) → 200 `{ok, preview: true, cached, mode, model, entry_id: null,
restaurant_id, place_query, place_offset, items}` — the sort's plan shape. **Writes no entry and no line.** 422
bad draft (>10k chars, bad uuid) · 429 `{error, retry_after}` over 12 previews / 10 min (a repeat of a cached
draft is free) — ignore it; Done still sorts. In model mode the model's plan is cached 15 min under (you,
sha256(body), tag_tokens, six_tokens, restaurant_id); **send exactly the body, tokens and place you will INSERT** and the
sort after Done reuses it — no second model call; if that preview is still running at Done the sort waits
for it (≤ 3 s, 0056) rather than calling the model again (`entries.sort_meta.cache_hit`) — then deletes it. The plan
holds draft words, so expired rows are purged on every preview and deleting an entry or account purges yours.

### Corrections (the user's, always)
| Action | Call |
|---|---|
| Fix the place | `rpc correct_entry_place(p_entry_id, p_restaurant_id)` → the entry row. Re-resolves every line's dish at the new place, or prints the parked plan if the entry had none. Pins `restaurant_source='user'`, records `place_corrected_at`, clears the place token |
| Fix a line's dish | `rpc correct_entry_dish(p_review_id, p_dish_id, p_dish_name)` → dish uuid. Pass `p_dish_id` for a menu pick, `p_dish_name` to name one. Score and note untouched |
| Set / clear a score | `PATCH /rest/v1/reviews?id=eq.<uuid>` `{ "score": 4.5 }` (or `null`). Half steps 0.5–5.0, or `6` (0041); else `23514` |
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
`ATE_SORTER_MODEL` = `claude-haiku-4-5` (default) | `claude-haiku-5-5` | `claude-sonnet-5`, anything else → default; the response's
`model` names it (null when the stub sorted). **Choose by eval:** from the function dir with the key in env,
`deno run --allow-net --allow-env eval.ts --all` (or `--model <id>`; `node eval.ts` works too) grades each model
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

**Tag page — 0057.** Additive: trailing optional `p_kind`, `p_slug` on `get_entry_feed` and `new_to_record` (+ browse twins; drop+create, old calls bind unchanged and return the same rows); new `my_taste_tags`. Nothing existing changes meaning.

**Faster logging — 0056 + sort-entry.** Additive: the sort reply (and its `skipped` reply) carries `entry_card`
(nullable); `{health: true}` request. Behavioural, invisible to the client: a sort waits ≤ 3 s for a running
preview of the same draft; the model times out at 5 s (was 20) and falls back to the stub. Old clients ignore
the new key and keep refetching.

**Round 8 — 0055.** Additive: `top_ate`, `because_you_loved`, `new_to_record`, `craving_options`, `my_cravings`, `set_cravings` (+ table `user_cravings`); `dishes_by_tag` gains a trailing `p_city` param and a trailing `saved` column (drop+create; round-7 calls bind unchanged). Nothing existing changes meaning.

**Round 7 fix — 0054.** Behavioural, for `p_max_score` in [5, 6) only: that ceiling now excludes a 6 (it was open). Every range read (`my_entries`, `my_entries_count`, `journal_days`, `search_places`, `search_dishes`, `nearby_places`, `search_saved`). Shipped clients send no ceiling at the top of the track, so they are unaffected.

**Round 7 — 0053 + sort-entry.** Additive: `journal_days`, `my_entries_count`, `dish_tags`, `similar_dishes`, `dishes_by_tag`; sort-entry items may carry `styles` (model mode; absent when none). Nothing existing changes shape or behaviour.

**Round 6 — 0050–0051.** Additive: `p_from`/`p_to`/`p_tz` on `search_places`, `search_dishes`, `nearby_places`, `search_saved` (drop+create, old calls bind). **Behavioural:** `place_dishes` rows arrive in rating order (same params, same OUT shape, same 4 cursor fields).

**Round 5 — 0046–0049.** All additive: `p_min_score`/`p_max_score`/`p_city` on `search_saved` + `my_saved_cities` (0049); `p_city` on `get_entry_feed` (+ browse); `p_max_score`/`p_city` on `my_entries`,
`search_places`, `search_dishes`, `nearby_places` (drop+create, old calls bind); `feed_cities`, `resolve_city`, `my_entry_cities`,
`search_cities`, `get_entry_card`; table `cities`, view `place_cities`. Nothing existing changes shape or behaviour.

**Round 4 — 0041–0045 + sort-entry.** Additive: `six_tokens` (sort + preview); `tags` on `place_dishes` (+ browse) and `search_dishes` rows; a `score` may be `6.0` anywhere a
score or aggregate is read; filter params on `search_places`/`search_dishes`/`nearby_places` (drop+create, old
calls bind); `search_cuisines`, `my_entries`, `my_entry_places`. **Behavioural:** `score_histogram` returns 11 rows.

**Round 3 — 0037–0040 + sort-entry.** Additive: `delete_entry`, `feed_areas`, `get_entry_feed(p_area)` (default
null = today's feed; drop+create, old calls bind), sort-entry `preview`, `sort_meta` on `correct_entry_place`'s
returned row. **Breaking (sequenced via the lead):** an `entries` INSERT without `restaurant_id` is `23502
place_required` — no build that allows a placeless Done may be live when 0040 lands.

**Earlier (0018–0036, all additive or sequenced):** entries/photos/saves/blocks/reports and their RPCs; the
correction + offset columns; covers from `entry_photos`; Search scopes; `delete_account()`/`my_blocks()`; the anon
browse reads (0034); `reviews.tags` + `tag_tokens` (0036); sort-entry `model`. Behavioural: **every entry public**
(0033 — `visibility` pinned `public`; dropping the column is a sequenced follow-up); `delete_account` raises rather
than half-deletes, deactivated profiles vanish, a `profiles` PATCH is column-limited (0035); `place_dishes` is the
`DishRanking` order; `profile_summary` counts lines by `reviewer_id`; empty text is `null`; `most_*` null at 1; a
report `reason` outside the vocabulary is `23514`.

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

## Ate with — tagging companions (0058, on staging)

The author tags people on their OWN entry (pick from `search_people`; send the `user_id`) or mints an invite
link. The tagged person posts their own linked entry or declines. All RPCs signed in only; anon → `42501`.
**Pending tags follow the live entry, they don't snapshot:** a tag is made before the sorter has printed a
line, so the prefill reads the original's lines when opened; once the companion posts, their lines are
theirs. The original deleted before a response withdraws the tag (prefill → `P0002` = "no longer available").

| Call | Returns · errors |
|---|---|
| `tag_ate_with(p_entry_id, p_user_id)` | `{companion_id, entry_id, user_id, status, created_at}` — idempotent (the existing row, any status; a decline comes back `declined`, no second notification). `42501` not your entry / blocked either way · `22023` yourself, or a placeless entry · `P0002` unknown entry or person · `54000` `ate_with_cap` (6 seats = every tag, a decline included, + live invites) or `ate_with_rate_limited` (40 tags + invites / rolling day, counted from a ledger untag/revoke never erase). Re-tagging the same person on the same entry within a day is quiet (lands read, no push) only if the untagged tag had reached them (pushed or read); otherwise it notifies normally |
| `untag_ate_with(p_entry_id, p_user_id)` | int removed. Pending or accepted → gone (their entry stays theirs, unlinked); a decline is sticky and keeps its seat (0). Frees no budget |
| `create_ate_with_invite(p_entry_id)` | `{invite_id, token, expires_at}` — the token exists ONLY in this reply (32 chars base64url; stored hashed). Link `ate://invite/<token>`. 14 days, single use, takes a seat. Errors as `tag_ate_with` |
| `revoke_ate_with_invite(p_invite_id)` | int (1 revoked, 0 not yours / already used). Your invites: `GET entry_invites?entry_id=eq.<id>` |
| `redeem_ate_with_invite(p_token)` | `{companion_id, entry_id, status}` → open the prefill. Call right after sign-up/sign-in. The same person again → same row. `P0002` unknown/revoked · `22023` expired or your own · `23505` used by someone else · `42501` blocked |
| `my_notifications(p_limit, p_cursor_created_at, p_cursor_id)` | `{id, type, created_at, read_at, actor{id,username,name,avatar_url}, companion_id, companion_status, entry_id, place{id,name,locality}, visited_at}[]`, newest first, keyset `(created_at, id)` — pass BOTH from the last row or neither (one alone → `22023`); default 30, max 100. `type` is `ate_with` (render nothing else). Blocked/deactivated actors absent |
| `unread_notification_count()` | int — the badge; counts exactly the unread rows `my_notifications` can show |
| `dismiss_notification(p_id)` · `mark_notifications_read()` | void · int (0011, unchanged). Answering a tag dismisses its row itself |
| `ate_with_prefill(p_companion_id)` | jsonb `{companion_id, status, response_entry_id, entry_id, visited_at, sort_status, tagger{…}, place{id,name,address,locality}, dishes:[{dish_id, dish_name, position}]}` — one row per dish. `sort_status: pending` = dishes still on their way (retry), not "none". `status: accepted` → open `response_entry_id` instead. Marks the notification read. `P0002` not yours / withdrawn / blocked |
| `respond_ate_with(p_companion_id, p_entry_id, p_items, p_body)` | `entry_cards[]` (one row: YOUR new entry — render it). `p_entry_id` client-minted (a retry with it returns the same card); `p_items` = `[{dish_id, score?, tags?}]` in receipt order, dishes at that place (omit = didn't have it; duplicates collapse); `p_body` optional words, default `''`. Same place + visit time as the original; `sort_status: sorted`; lines are `corrected` (a later `sort-entry` with `force` keeps them and adds what the words name). `22023` bad items / `dish_not_at_place` / `nothing_to_post` / declined · `23514` bad score · `23505` already answered with another id · `P0002` |
| `decline_ate_with(p_companion_id)` | `'declined'`. Pending or accepted; an accepted entry stays theirs, unlinked. `P0002` not yours |
| `register_push_token(p_token, p_apns_env)` · `unregister_push_token(p_token)` | void. Hex APNs token; `p_apns_env` `sandbox` (Xcode-installed builds) \| `production` (TestFlight + App Store; the default when omitted or null, 0059) — from the build's `aps-environment`, not from Debug/Release: a Beta build on staging is `production`. Register on every launch with permission (moves the token to whoever is signed in); unregister on sign-out. `22023` bad token/env |

**`entry_cards.companions`** (new trailing key, `[]` never null): `[{user_id, username, name, avatar_url, status,
entry_id}]` — print "with @jess". An original lists accepted companions whose entry still stands (+ `pending`
ones, only to the author and that companion); a response lists the original's author + its other accepted
companions. `entry_id` = that person's entry for the visit (tap → `get_entry_card`), null while pending. Blocked
and deactivated people are absent. Raw `entry_companions` rows (incl. `declined`) are readable by the two parties only.

**Push delivery (0059 + `supabase/functions/send-push`; built, not deployed).** The app receives
`{aps: {alert: {title: "@eamon ate with you at Tipo 00", body: "Tagliatelle al ragù, tiramisu, prawn spaghetti"},
badge: <unread ate_with count>, sound: "default", "thread-id": "ate-with"}, type: "ate_with", companion_id,
notification_id, entry_id}` (no `body` when the entry has no dishes; `apns-collapse-id` = `companion_id`). Tap →
`ate_with_prefill(companion_id)`; `P0002` = withdrawn, show nothing. Sent once, only for a pending, unread,
undismissed, unblocked tag whose original has SORTED (so the dishes exist), within 24 h of the tag; a quiet re-tag never pushes.
**Function secrets** (`supabase secrets set`, per project): `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`
(the .p8's full PEM text); absent → the function is a no-op. The host is PER TOKEN (`apns_env`: sandbox → api.sandbox,
production → api.push), since a TestFlight build on staging holds a production token; one key serves both.
**One-time setup per project (no key is ever copied):** (1) merge → CI applies 0059 (pg_net, pg_cron, the minute
drain); (2) `supabase secrets set APNS_KEY_ID=… APNS_TEAM_ID=… APNS_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"`; (3) deploy
`send-push` (`verify_jwt = false` is in config.toml — it checks its own bearer); (4) as service role,
`select push_configure('https://<ref>.supabase.co/functions/v1/send-push')` — stores the URL and has the DATABASE
generate the kick secret (Vault `send_push_url`, `send_push_kick_secret`; never returned). Pushes start. Do (4) only
after (2)+(3): unconfigured, the function answers `{configured: false}`. Kill switch: delete `send_push_url` from Vault.

**Wire change — 0059.** None for the app: two `notifications` columns it never reads, service-role-only functions, the push payload above.

**Wire change — 0058.** Additive: the RPCs above, three tables, `notifications.companion_id`/`pushed_at`, and a
trailing `companions` key on every `entry_cards` row. Behavioural on a dormant RPC only: `unread_notification_count` counts `ate_with` alone.

## Lists + Journal search (0060, draft — not applied)

A list = a name + the owner's own dish lines in hand order. **Private** (`visibility` is always `private`;
a public flag later is additive). Item grain = **(entry_id, dish_id)**, not a review id: it survives a re-sort,
follows a dish correction/merge, and is removed (ranks close up) when that visit no longer prints the dish
or the entry is deleted. Pre-entries lines can't be listed. Signed in only (anon → `42501`); no table writes.

| Call | Returns · errors |
|---|---|
| `create_list(p_name)` · `rename_list(p_list_id, p_name)` | `{list_id, name, visibility, item_count, created_at, updated_at}`. Name trimmed, 1–80 chars, duplicates allowed. `22023 bad_list_name` · `54000 list_cap` (50 lists) · `P0002 list_not_found` (gone or not yours — indistinguishable) |
| `delete_list(p_list_id)` | int: 1, or 0 = already gone (treat as done). Items go with it |
| `add_list_item(p_list_id, p_entry_id, p_dish_id)` | `{item_id, list_id, entry_id, dish_id, item_position, added_at}` — appended last; idempotent (the same line again = the same item). `P0002 dish_line_not_found` (not your entry / dish not on it) · `54000 list_item_cap` (100) |
| `remove_list_item(p_item_id)` | int 1 · 0 already gone. Later items move up one |
| `reorder_list(p_list_id, p_item_ids uuid[])` | int count. The FULL ordered array of the list's item ids, each once; positions become 1…n in array order. Anything else → `22023 reorder_mismatch` (refetch `get_list`, reapply the drag) |
| `my_lists(p_limit, p_cursor_created_at, p_cursor_id)` | `{list_id, name, visibility, item_count, covers text[], created_at, updated_at}[]`, newest created first; keyset `(created_at, list_id)` — both or neither (`22023`). `covers` = ≤ 4 distinct item photos in list order, `[]` none. Default/max 50 |
| `get_list(p_list_id)` | jsonb `{list_id, name, visibility, item_count, created_at, updated_at, items:[{item_id, position, entry_id, dish_id, dish_name, restaurant_id, restaurant_name, locality, score, photo_url, visited_at, added_at}]}`, items in order (`position` 1…n), unpaged (≤ 100). `score` = that visit's line (null = unscored); `photo_url` = the line's photo, else the visit's first photo (may show another dish of that visit), else null. `P0002` |
| `my_lists_for_dish_line(p_entry_id, p_dish_id)` | `{list_id, name, item_count, item_id}[]` — every list (my_lists' order); `item_id` non-null = this line is in it (pass it to `remove_list_item` to untick) |
| `my_scored_dishes(p_query, p_scored_only, p_list_id, p_limit, p_cursor_visited_at, p_cursor_entry_id, p_cursor_dish_id)` | the picker: `{entry_id, dish_id, dish_name, restaurant_id, restaurant_name, locality, score, photo_url, visited_at, in_list}[]`, one row per (visit, dish), newest visit first. `p_query` matches dish OR place name (accent-folded substring; trimmed; < 2 chars = no filter; > 100 → `22023`). `p_scored_only` default true. `in_list` vs `p_list_id` (false when null). 3-part keyset, all or none (`22023`). Default 30, max 100 |
| `search_my_entries(p_query, p_limit, p_cursor_created_at, p_cursor_id)` | `entry_cards[]` — YOUR entries whose words, place name or a line's dish name contain the query (the Search tab's `search_key` rule: case- and accent-insensitive substring, so prefixes work; `%`/`_` literal; trimmed; < 2 chars → `[]`; > 100 → `22023`). Journal order `(created_at, id)` DESC, keyset both or neither (`22023`). Default 20, max 50. Never another person's entry |

The share image is rendered on the phone from `get_list`; no server call.

**Notifications badge (C).** `unread_notification_count()` (0058) is sufficient for the "ate with" half: it counts
exactly the unread, undismissed `ate_with` rows `my_notifications` can show (blocked/deactivated actors excluded).
Badge = that int + the phone's own photo count. No server change.

**Nearby places for a photo (D, proposal — nothing built).** `places-search op=nearby` takes `{lat, lng, radius?}`
(default 2000 m, clamped 100–50 000) and returns ≤ 10 `restaurants[]` with `distance_meters`: PostGIS
`restaurants_nearby` first; only when it finds < 5 does it call Google `searchNearby` (Pro-tier field mask, no
photos — roughly US$0.03 a call) and upsert those places. Each call = one edge invocation + JWT check + one
`places_rate_hit` (90/min/user, shared with autocomplete, fails open). ~20 clusters → 20 calls: inside the rate
limit, but a burst that also collides with typing could `429`, and in a thin area it's up to 20 paid Google calls
per import. Acceptable for a first cut if the phone runs them sequentially (or 4 at a time) and skips clusters
within ~150 m of one already asked. If it ships widely, the batched variant is `op=nearby_batch {points: [{lat,
lng}] ≤ 25}` → `{results: [{index, restaurants[]}]}`: one auth + one rate hit, one SQL call taking all points
(`unnest` + LATERAL over the GIST index), Google only for points under the threshold, capped at ~5 Google calls
per request. Rule 8 stands either way: these are suggestions the user taps, never an attached place; no point is stored.

**Wire change — 0060.** Additive: two tables (owner SELECT only), the RPCs above. `delete_account` also verifies the
list tables are empty (same reply). Behavioural, dormant tables only: legacy `lists`/`list_dishes` become owner-read (were readable by all).
