# Manual-restaurant search blend — contract (MANUAL-RESTO search-blend)

> **Status:** BUILT (BE), pending prod apply + edge-fn deploy (lead's MCP step) and the FE consuming stream.
> **Owner:** backend-engineer. **Consumers:** the log-flow "Where did you eat?" step (`usePlacesSearch` → `useDishPicker` → `pick.tsx`).
> **Migration:** `0015_search_manual_restaurants.sql`. **Edge fn:** `places-search` (`op=autocomplete`).

Eamon's directive (verbatim): *"manually added places should show up alongside google places search results based off fuzzy match searching. So if people even closely type in the name then it should come up."*

So the "Where" step now blends (a) Google Places predictions and (b) `source='manual'` restaurants from our DB whose **name fuzzy-matches** the query (approximate spelling included). The "Add restaurant" affordance still appears only when **neither** source matches.

---

## 1. Where the blend happens — SERVER-SIDE (justified)

In the `places-search` edge function's `op=autocomplete` branch. Rationale: it keeps ranking, the top-5 cap, and the VIC/food-bev Places logic in **one place** and hands the FE a single ranked list. On a query the edge fn now:
1. fetches Places predictions (unchanged: VIC-restricted, food/bev, capped 5), AND
2. calls `search_manual_restaurants(input, 5)` (migration 0015) for fuzzy manual matches,
3. merges them into a unified, ranked, capped-at-5, **discriminated** `results` list.

Manual search is **soft-fail**: any error (RPC not yet applied, transient DB error) → it returns `[]` and the response is Places-only. The core Places autocomplete can never be broken by the blend.

---

## 2. The wire contract — `op=autocomplete` response (ADDITIVE)

```jsonc
{
  "stub": false,
  "predictions": [ /* UNCHANGED — Places-only, back-compat */
    { "google_place_id": "ChIJ…", "name": "Chin Chin", "secondary": "Flinders Ln, Melbourne", "distance_meters": 540 }
  ],
  "results": [ /* NEW — unified, ranked, capped at 5, discriminated */
    { "kind": "manual", "id": "8e7…uuid", "name": "Marg's Diner", "city": "Fitzroy", "cuisine": null, "match_score": 0.85 },
    { "kind": "place",  "google_place_id": "ChIJ…", "name": "Chin Chin", "secondary": "Flinders Ln, Melbourne", "distance_meters": 540 }
  ]
}
```

- **`predictions` is unchanged** (Places-only). Existing/older clients keep working and ignore `results`. Nothing the client already reads moves shape — fully back-compat.
- **`results`** is the new field the FE migrates to. Discriminator is the `kind` tag:

```ts
type SearchResult =
  // a Google Places prediction — RESOLVE on select (op=details), has google_place_id, NO real row id yet
  | { kind: 'place';  google_place_id: string; name: string; secondary?: string; distance_meters?: number }
  // a user-added restaurant — ALREADY a restaurants row, has the real `id`, SELECT DIRECTLY (no resolve)
  | { kind: 'manual'; id: string; name: string; city: string; cuisine?: string; match_score: number };
```

Manual rows carry **no `distance_meters`** (`add_manual_restaurant` never sets `location`), so they render name-only — consistent with the existing "no distance → name only" row behaviour.

The `search_manual_restaurants` RPC is also added to `src/data/supabase-types.ts` (`Functions.search_manual_restaurants`) for direct typed access if ever needed.

---

## 3. Ranking + cap (justified)

The server produces the FINAL order of `results`; **the FE renders it as-is** (see §5 — drop the `byDistanceAsc` re-sort for this list):
1. **STRONG manual matches** (near-exact typed name; strongest-first by `match_score`). These are places this app's users explicitly added AND the query matches closely — highest intent, so they lead.
2. **Places predictions** — distance-sorted nearest-first (mirrors the existing FB2 `byDistanceAsc`: unmeasured rows last, stable for ties → Google relevance order when no origin). Preserves today's "Where" UX.
3. **WEAK manual matches** (ordinary fuzzy / typo) — after Places.

De-duped by normalised (trim+lowercase) name, first-occurrence-wins → **strong-manual > place > weak-manual**. So a manual row beats a same-named Places prediction (it's directly selectable, no resolve round-trip). Then **capped at 5**.

This guarantees the blend: strong manual matches are never starved by Places (they lead), and Places is never starved by a flood of weak fuzzy manual matches (those trail). Manual rows are a small, deliberately-added subset, so a flood is unlikely anyway.

---

## 4. The fuzzy matcher — `search_manual_restaurants(p_query, p_limit)` (migration 0015)

`pg_trgm` over the **manual subset** of `restaurants` (a new partial GIN trigram index `restaurants_manual_name_trgm WHERE source='manual'` keeps it index-eligible as the catalogue grows). Returns `id, name, city, cuisine, match_score (0..1), strong (bool)`, strongest-first.

- **MATCH (surface at all):** `name ILIKE '%q%'  OR  word_similarity(q, name) >= 0.45`.
  `word_similarity` is the recall driver — it scores the best matching word-extent of the name against the query, catching partial / multi-word / mildly-misspelled queries.
- **STRONG (leads Places):** exact substring OR `greatest(similarity, word_similarity) >= 0.6`.
- The 0.45 word_similarity threshold is pinned on the function (`SET pg_trgm.word_similarity_threshold = 0.45`) so the `<%` operator is deterministic and index-using. LIKE metacharacters in the query are escaped.

### Proof (real pg_trgm, Postgres 16, against a `restaurants`-shaped table + 5000 Places noise rows)

Row present: `('manual', NULL, "Marg's Diner", 'Fitzroy')`. The required acceptance queries all surface it:

| query | match | match_score | strong? |
|---|---|---|---|
| `marg` | Marg's Diner | 1.000 | yes |
| `marg diner` | Marg's Diner | 0.846 | yes |
| `margs diner` | Marg's Diner | 0.667 | yes |
| `Margs Diner` | Marg's Diner | 0.667 | yes |
| `margs dinner` (typo) | Marg's Diner | 0.529 | no (weak → after Places) |
| `marrgs diner` (typo) | Marg's Diner | 0.529 | no (weak → after Places) |

No false positives: `xyzzy` → none; `50%` → none (metacharacter escaped, no wildcard explosion); a `source='places'` row named "Margaret" is NOT returned for `margaret` (source filter). `EXPLAIN` confirms a `BitmapOr` on `restaurants_manual_name_trgm` (both the ILIKE and `<%` branches index-eligible).

---

## 5. The exact FE delta (the consuming stream, serialized AFTER this)

The blend is on the wire; the FE wires it up. Minimal, bounded changes — **no new visual** (manual rows reuse the existing `RestaurantRow` master).

1. **`src/data/api/restaurantsApi.ts`** — add a blended search that reads `results`. Either extend `searchPlaces` to also return `results`, or add `searchRestaurants(input, sessionToken?, origin?): Promise<SearchResult[]>`. Map the snake_case wire (`google_place_id`, `match_score`, `distance_meters`) to camelCase client fields, mirroring the existing `mapPlaceRow` style. Add the `SearchResult` discriminated union to `src/data/api/types.ts`:
   ```ts
   export type SearchResult =
     | { kind: 'place';  googlePlaceId: string; name: string; secondary?: string; distanceMeters?: number }
     | { kind: 'manual'; id: string; name: string; city: string; cuisine?: string; matchScore: number };
   ```
2. **`src/hooks/usePlacesSearch.ts`** — return `results: SearchResult[]` (alongside or instead of `predictions`). The debounce / session-token / stale-guard / per-session cache machinery is unchanged (cache the `results` array instead of `predictions`).
3. **`src/hooks/useDishPicker.ts`** —
   - Render `results` directly. **DROP the `byDistanceAsc` re-sort** for this list — the server already ranks (manual rows have no distance and would wrongly sort last under `byDistanceAsc`). Keep `formatDistanceKm(item.distanceMeters)` for the meta (manual rows pass `undefined` → name only).
   - `renderItem`: branch on `item.kind`. `kind === 'place'` → existing `pickPlace(p)` (resolve via `op=details`). `kind === 'manual'` → a new `pickManual(m)` that just calls `goWhat(m.name)` — exactly like `pickNearby` (the row already exists in `restaurants`; the store's `ensureRestaurantByName` fast-paths the existing exact name on log, no edge-fn call, no `RestaurantNotFoundError`).
   - **"Add restaurant" affordance:** gate on `results.length === 0` (was `sortedPredictions`/`predictions` empty). It now appears only when NEITHER Places NOR a manual fuzzy-match returned anything — exactly the desired behaviour.
4. **`src/app/log/pick.tsx`** — the where-step `FlatList` consumes `results`; `keyExtractor` must handle both kinds (e.g. `item.kind === 'manual' ? 'm:'+item.id : 'p:'+item.googlePlaceId`). Same `RestaurantRow` rendering for both kinds.

No change to `op=details`, `op=nearby`, the store's log/resolve path, or any visual. tsc stays clean throughout (the wire change is additive; only the FE that opts into `results` changes).

---

## 6. Eamon-gate

**No gate needed.** This is backend + contract only. Manual matches render with the EXISTING `RestaurantRow` treatment — no component look, nav chrome, type-colour hierarchy, or brand-layout change. Whether to VISUALLY distinguish a manual result from a Places result (e.g. a subtle "added by you/community" marker) would be a design/Eamon call — **flagged, not built.** Default ships with no visual distinction (they look identical), per Eamon's directive that manual places "show up alongside" Places results.
