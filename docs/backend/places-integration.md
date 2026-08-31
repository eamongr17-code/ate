# Google Places integration

> **Status: LIVE (E-1 resolved, 2026-06-15).** The repo-durable record of how Ate's Google Places integration is provisioned, what it costs, and what work remains. The board (`docs/COORDINATION.md`) carries the live task items; this file is the stable reference a fresh lead can pick up from.

## What it's for
Restaurants in Ate are **Google-Places-backed**: the only way a `restaurants` row is created is "resolve a Google Place → upsert by `google_place_id`" (`data-model.md §1.2`). Google is touched at **write-time only** — every read (feed, restaurant page, search via `pg_trgm`, nearby via PostGIS KNN) is served from Postgres. The DB is the cache; Google is the resolver.

The single server-side entry point is the edge function **`supabase/functions/places-search/index.ts`** (the only place the API key is used — never the client).

## Provisioning facts (the canonical record)
| Item | Value |
|---|---|
| GCP project | `bamboo-antler-499509-g1` ("My Maps Project"), owner eamongr17@gmail.com |
| Billing | Free Trial billing account ($300 credit, AUD, Individual). **Required even for the free tier.** |
| API enabled | **Places API (New)** (`places.googleapis.com`) — NOT the legacy Places API. Covers Autocomplete, Place Details, and Nearby Search under one enabled API + one key. |
| API key | "Ate Places API (server)" — **API restriction: Places API (New) only**; **application restriction: None** (called server-side from the Supabase edge runtime, which has no stable egress IP) |
| Secret | Supabase Edge Function secret **`GOOGLE_PLACES_API_KEY`** on project `vyaexmnajnbryimbkgkf`. Never in code. |
| Function | `places-search` deployed + ACTIVE (`verify_jwt: true`). Live Google path engages on next cold start after the secret was set. |

> Verification still owed: a real end-to-end `stub:false` round-trip needs a valid user JWT (the function requires auth) → that's the QA-1 gate, not provisioning.

### How it was provisioned
Driven through the lead session via **chrome-devtools-mcp** against Eamon's logged-in browser: enable the API, create + restrict the key, store the secret in the Supabase dashboard. The billing/card step was handed off to Eamon (a financial decision). See `memory/places-api-key-setup-e1.md` for the session-local detail. To rotate the key: GCP Console → APIs & Services → Credentials → regenerate "Ate Places API (server)", then re-save the `GOOGLE_PLACES_API_KEY` secret.

## What the function calls
- **`op=autocomplete`** → `POST places.googleapis.com/v1/places:autocomplete` (predictions while typing; supports `locationBias`).
- **`op=details`** → `GET places.googleapis.com/v1/places/{id}` with an `X-Goog-FieldMask`; upserts the resolved place into `restaurants` by `google_place_id` and returns the row. This is the only restaurant-creation write path.
- (Planned) **`op=nearby`** → `POST places.googleapis.com/v1/places:searchNearby` — see BE-PLACES-2.

Both present paths authenticate with `X-Goog-Api-Key: GOOGLE_PLACES_API_KEY`. If the secret is ever absent, the function transparently falls back to **STUB mode** (3 fixture restaurants behind the identical interface), so the client contract never changes.

## Cost model
Places API (New) bills per request by SKU tier. Pricing seen at provisioning (USD, per 1K requests, then per-month volume):

| Tier | Price /1K | Starting after |
|---|---|---|
| FREE | $0.00 | 0 |
| Tier 1 | $2.83 | 10K/month |
| Tier 2 | $2.27 | 100K/month |
| Tier 3 | $1.70 | 500K/month |

So **~10K calls/month are free**, with the $300 trial credit on top and no auto-charge until Eamon manually upgrades. Autocomplete, Place Details, and Nearby Search are **separate billing SKUs**.

**"Efficient" here means minimizing paid calls, not making them faster.** The levers:
- **DB is the cache** (already true): a Place is fetched from Google once, then lives in `restaurants` forever; all reads come from Postgres.
- **Session tokens** (planned, BE-PLACES-3): tie autocomplete keystrokes + the final Place Details into one billed *session* instead of one charge per keystroke. Highest-impact cost lever.
- **No image data** (decided, BE-PLACES-1): `photos` is dropped from the field mask — it pushes requests into a higher SKU tier and we discard it anyway. No Place Photo calls until Eamon revisits.
- **Known-place short-circuit** (planned, BE-PLACES-4): skip Google on `op=details` when the `google_place_id` is already a row.
- **Client debounce + min length** (planned, FE-PLACES-2): ~250ms debounce, ≥2–3 chars before firing autocomplete.

## Next work (tracked on the board)
See `docs/COORDINATION.md` → "Wave 0 follow-on — Places integration work":
- **BE-PLACES-1** — drop `photos` from the Place Details field mask (no image data). Objective.
- **BE-PLACES-2** — add `op=nearby` for the "near me" picker default. **Decided (E-5): PostGIS-first blend** — serve `restaurants` via PostGIS KNN first, call Google Nearby Search only to fill gaps below a threshold, upsert/dedupe by `google_place_id`. The FE/UX half (FE-PLACES-1) is gated on an Eamon-review of the picker surface.
- **BE-PLACES-3** — session tokens for autocomplete (BE + FE). Objective.
- **BE-PLACES-4** — known-place short-circuit on `op=details`. Objective.
- **FE-PLACES-1** — picker "near me" default + device location permission. ⛔ Eamon-review gate (UX).
- **FE-PLACES-2** — client debounce + min query length. Objective.

BE-PLACES-1/3/4 are objective and batchable into a single `places-search` deploy. None block the backend stand-up Wave 0/1.
