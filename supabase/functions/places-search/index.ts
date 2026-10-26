// supabase/functions/places-search/index.ts
//
// Ate backend — Google Places proxy (data-model §1.2, §5 "nearby").
//
// Three operations, switched by `?op=`:
//   - op=autocomplete  body: { input: string, lat?, lng?, session_token? }
//       → returns place predictions [{ google_place_id, name, secondary,
//         distance_meters? }] — worldwide (ranked near the caller), food/bev-only, capped at 5
//         (PH-BE-1). FB2-BE-1: when BOTH lat+lng are sent, `origin` is forwarded
//         to Google and each prediction carries `distance_meters` (metres from the
//         origin); omitted otherwise (additive, back-compat). The wire field is
//         snake_case `distance_meters` to match the FE consumer + the existing
//         wire convention (google_place_id, cover_url, secondary).
//       SEARCH-BLEND: ALSO returns `results` — a unified, ranked, capped-at-5,
//         discriminated list merging the Places predictions with fuzzy-matched
//         restaurants WE ALREADY HOLD (via the search_local_restaurants RPC,
//         migration 0017 — any source, widened from 0015's manual-only search).
//         Each item is tagged `kind:'place'` (resolve-on-select, has
//         google_place_id) or `kind:'manual'` (already a restaurants row, has the
//         real `id`, select directly — no resolve). A local row SHADOWS a
//         same-named Places prediction, which is what stops a known restaurant
//         being re-resolved into a duplicate row (and saves the paid Details
//         call). `predictions` stays Places-only for back-compat; the FE reads
//         `results`. See docs/backend/manual-search-blend-contract.md.
//   - op=details       body: { google_place_id: string, session_token? }
//       → resolves a Place to full detail AND UPSERTS a restaurants row by
//         google_place_id, returning the restaurant row (the "resolve Place → row"
//         write path). This is the only way restaurants are created.
//   - op=nearby        body: { lat: number, lng: number, radius?: number }
//       → PostGIS-first KNN against our restaurants table (free, GIST-indexed,
//         via the restaurants_nearby RPC); falls back to Google searchNearby
//         ONLY when DB matches are below threshold, upserting the Google results.
//         Food/bev-only, capped at 10 (PH-BE-2).
//         Returns { stub, source, restaurants: [{ id, google_place_id, name,
//         address, city, cuisine, cover_url, distance_meters? }] }. FB2-BE-1:
//         distance_meters = the restaurants_nearby RPC's distance_m (DB rows) or a
//         haversine from the query origin (Google-fallback rows), in metres.
//
// Places hardening (PH-BE-1 / PH-BE-2, Eamon-locked 2026-06-16):
//   - WORLDWIDE, RANKED NEAR YOU (0066, 2026-10-15 — replaces the VIC fence). The old hard
//     VIC rectangle + region 'au' + other-state drop made every place outside Victoria
//     unfindable, which broke the app the moment anyone travelled (Eamon, Thailand). Autocomplete
//     now sends a `locationBias` circle — a ranking, never an exclusion — around, in order:
//     the phone's location (the app sends it once the place sheet has it), else where this
//     person last ate (places_bias_point, 0066), else nothing (Google's global ranking).
//     Nearby was always a circle around the phone; it just loses the AU-state drop.
//   - Food/bev types: autocomplete keeps the 5 includedPrimaryTypes — Places API
//     (New) autocomplete CAPS includedPrimaryTypes at 5 (PH-E2 RESOLVED). Nearby
//     uses the broader food/bev includedTypes set (searchNearby allows up to 50).
//     All type strings verified against the live Places API (New) Table-A docs
//     (developers.google.com/maps/documentation/places/web-service/place-types).
//   - Caps: typed autocomplete → 5 predictions; nearby default list → 10 (PH-E3
//     RESOLVED). Enforced server-side; the FE belt-and-suspenders slices too.
//
// `city` IS A SUBURB AGAIN (M3-BE, 2026-09-24). The live Google path's formatted-address split
// stored "<street>, <suburb STATE post>" in `restaurants.city` — the column every screen prints as
// the suburb chip, and the reason 0029 had to add `place_locality()` to undo it on read. Both sites
// (op=details and the searchNearby fallback) now call `localityFromAddress` (./locality.ts), which
// mirrors `place_locality()` rule for rule, so the write and the read agree and a new row stores
// "Melbourne". FORWARD-ONLY: existing rows keep their mangled city and are NOT rewritten — the read
// derivation already handles them, and a bulk update of real rows to fix a display string is not
// something this team does. The STUB fixtures were always bare suburbs ('Melbourne', 'Fitzroy'), so
// this is also what makes stub and live agree for the first time.
//
// STUB MODE (lead decision E-1): when GOOGLE_PLACES_API_KEY is ABSENT, this
// function serves deterministic FIXTURE data behind the SAME interface — so the
// client builds against the real contract and it goes live unchanged the moment
// the key lands. When the secret is PRESENT, the real Google path runs. (The key
// is provisioned now, so production runs the live path; stub mode survives for
// local/offline dev and to keep the contract honest if the key is ever pulled.)
//
// AUTH GATE + RATE LIMIT (TIDY-BE-2, 2026-06-27):
//   Every op here triggers a billable Google Places call (autocomplete/details/
//   nearby) and details/nearby also service-role-upsert into `restaurants`. The
//   app's anon/publishable key is extractable from the JS bundle, and Supabase's
//   platform-level JWT verification ACCEPTS the bare anon key (it's a valid
//   project JWT with role=anon) — so without an in-function check the endpoint is
//   invokable by anyone holding the public key. This function therefore:
//     (1) requires a VERIFIED END-USER JWT — `auth.getUser(token)` against an
//         anon-key client. The anon key alone resolves to NO user → 401. Only a
//         real signed-in user's access token passes. Applied to ALL ops.
//     (2) enforces a per-user rate limit (places_rate_hit RPC, migration 0013)
//         → 429 when a user exceeds the per-window ceiling. The limit fails OPEN
//         (allows the request) on any infra error so a missing/failed limiter
//         can't take down search — the JWT gate is the must-have, the limit is
//         the secondary layer.
//     (3) a DAILY budget (places_budget_hit, migration 0093): 400 Google calls per user and 4,000
//         across everyone per UTC day, counted only when Google is about to be called. Over it,
//         autocomplete answers from our own rows, details is a 429, nearby returns the DB rows.
//         Fails CLOSED, unlike the per-minute limit: it exists to bound the bill.
//   The client already calls via `supabase.functions.invoke()`, which attaches
//   the logged-in user's session access token as `Authorization: Bearer <jwt>`,
//   and the app gates to the auth screen when signed out — so authed users are
//   unaffected (the contract is preserved). Only the *gate* is new.
//
// Secrets this function reads (set via `supabase secrets set`):
//   - GOOGLE_PLACES_API_KEY   (absent → stub mode; present → live Google calls)
//   - SUPABASE_URL            (auto-injected in the Supabase runtime)
//   - SUPABASE_SERVICE_ROLE_KEY (auto-injected; used for the server-side upsert)
//   - SUPABASE_ANON_KEY       (auto-injected; used ONLY to validate caller JWTs)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
// The blend's pure half (ranking, name-dedupe, top-5 cap) — see ./blend.ts. Kept
// in its own module so blend_test.ts can test the real code rather than a copy.
import { AUTOCOMPLETE_CAP, blendResults, type LocalMatch, type Prediction } from './blend.ts';
// The suburb out of a Google formattedAddress. Its own module for the same reason as the blend's:
// index.ts cannot be imported by a test, and this rule now has to match place_locality() exactly.
import { localityFromAddress } from './locality.ts';
// A place's name without the keywords padded onto its listing; mirrors clean_place_name() (0075).
import { cleanPlaceName } from './name.ts';
// Chains (0085): which places are one chain, by name + website host. Runtime-free, tested under Node.
import { googleWebsite, linkChains } from './chains.ts';

const GOOGLE_KEY = Deno.env.get('GOOGLE_PLACES_API_KEY') ?? '';
const STUB = GOOGLE_KEY.trim() === '';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

// Rate-limit policy (TIDY-BE-2). A per-user fixed-window ceiling enforced by the
// places_rate_hit RPC (migration 0013). Sized to be invisible to normal use and
// hard-cap scripted abuse: the highest-frequency op is autocomplete (debounced
// ~250ms typing, session-token-billed as ONE Google session), so the window must
// clear a human typing a restaurant name; 90/min does (a typed search is a
// handful of debounced calls), while op=details/op=nearby fire far less often.
// One ceiling across all ops keeps it simple; tune here if needed.
const RATE_LIMIT_WINDOW_S = 60;
const RATE_LIMIT_MAX = 90;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

// ---------------------------------------------------------------------------
// Places hardening constants (PH-BE-1 / PH-BE-2, Eamon-locked 2026-06-16).
// ---------------------------------------------------------------------------

// The autocomplete bias circle. 50 km is the Places API (New) maximum for a circle bias: a metro
// area, so a search in Bangkok ranks Bangkok first while a famous place elsewhere still appears.
const BIAS_RADIUS_M = 50000;

// Names and addresses in English wherever Google has them, so a Bangkok receipt reads like the
// rest of the app. Google falls back to the local name when it has no English one.
const LANGUAGE = 'en';

// Autocomplete primary types (PH-E2): Places API (New) autocomplete caps
// includedPrimaryTypes at 5 — keep exactly these 5 food/bev venue types.
const AUTOCOMPLETE_PRIMARY_TYPES = ['restaurant', 'cafe', 'bar', 'bakery', 'meal_takeaway'];

// Nearby included types (PH-E2): searchNearby allows up to 50 includedTypes, so
// we use the broader food/bev set. Every string below is a verified Places API
// (New) Table-A "Food and Drink" type. No invented names.
const NEARBY_INCLUDED_TYPES = [
  'restaurant',
  'cafe',
  'bar',
  'bakery',
  'meal_takeaway',
  'meal_delivery',
  'food_court',
  'ice_cream_shop',
  'fast_food_restaurant',
  'pub',
  'wine_bar',
  'coffee_shop',
  'sandwich_shop',
  'breakfast_restaurant',
  'brunch_restaurant',
  'dessert_shop',
  'diner',
  'deli',
  'steak_house',
  'pizza_restaurant',
  'hamburger_restaurant',
  'bar_and_grill',
  'tea_house',
  'juice_shop',
];

// Result caps (PH-E3). AUTOCOMPLETE_CAP is imported from ./blend.ts (single
// source of truth — the blend enforces the same 5).
const NEARBY_CAP = 10;

// Nearby radius (metres). Default to a walkable/short-drive radius; clamp to a
// sane range so a malformed client value can't blow out the search.
const NEARBY_DEFAULT_RADIUS_M = 2000;
const NEARBY_MIN_RADIUS_M = 100;
const NEARBY_MAX_RADIUS_M = 50000;

// PostGIS-first threshold (PH-BE-2): if the DB returns at least this many
// nearby rows, serve from DB and skip the paid Google call entirely.
const DB_NEARBY_THRESHOLD = 5;

// ---------------------------------------------------------------------------
// Fixture data (stub mode) — real Melbourne venues and coordinates.
// ---------------------------------------------------------------------------
type StubPlace = {
  google_place_id: string;
  name: string;
  address: string;
  city: string;
  lat: number;
  lng: number;
  cuisine: string;
  cover_url: string;
};

// THE FIXTURES ARE THE SEED. Every entry below is a byte-for-byte copy of a row
// in `supabase/seed.sql` §2 — same google_place_id ('stub-…'), name, address,
// city, coords (seed writes ST_MakePoint(LNG, LAT); lat/lng are un-swapped here),
// cuisine and cover_url.
//
// This alignment is LOAD-BEARING, not cosmetic (staging seed/Places mismatch,
// 2026-09-01). The previous fixtures were three invented venues with
// 'seed_place_…' ids that matched NOTHING in the database, so on a stub-mode
// stack: autocomplete surfaced places that did not exist as rows; selecting one
// missed the op=details known-place short-circuit (no row carries
// 'seed_place_chintamani'); and the upsert MINTED A SECOND restaurant next to
// the seeded one — which is exactly how staging got two "Chin Chin" rows.
//
// Because the ids now match the seeded rows, op=details short-circuits onto the
// seeded row (BE-PLACES-4) and never inserts, and — with migration 0017 — the
// blend surfaces the seeded row itself, so the prediction is shadowed before a
// resolve is even attempted.
//
// The seed's 9th restaurant ("Nonna's Kitchen (synthetic)") is deliberately
// ABSENT: it is source='manual' with google_place_id NULL, so it is not a Place
// and must never be one. It reaches search through the local-search RPC, which
// is precisely the path this fixture set must not fake.
//
// If seed.sql changes, change this list with it.
const STUB_PLACES: StubPlace[] = [
  {
    google_place_id: 'stub-chin-chin',
    name: 'Chin Chin',
    address: '125 Flinders Ln',
    city: 'Melbourne',
    lat: -37.8163,
    lng: 144.9695,
    cuisine: 'Thai',
    cover_url: 'https://images.unsplash.com/photo-1414235077428-338989a2e8c0?auto=format&fit=crop&w=800&q=70',
  },
  {
    google_place_id: 'stub-supernormal',
    name: 'Supernormal',
    address: '180 Flinders Ln',
    city: 'Melbourne',
    lat: -37.8157,
    lng: 144.9707,
    cuisine: 'Asian',
    cover_url: 'https://images.unsplash.com/photo-1552332386-f8dd00dc2f85?auto=format&fit=crop&w=800&q=70',
  },
  {
    google_place_id: 'stub-tipo-00',
    name: 'Tipo 00',
    address: '361 Little Bourke St',
    city: 'Melbourne',
    lat: -37.8134,
    lng: 144.9617,
    cuisine: 'Italian',
    cover_url: 'https://images.unsplash.com/photo-1551782450-a2132b4ba21d?auto=format&fit=crop&w=800&q=70',
  },
  {
    google_place_id: 'stub-gimlet',
    name: 'Gimlet at Cavendish House',
    address: '33 Russell St',
    city: 'Melbourne',
    lat: -37.8143,
    lng: 144.9695,
    cuisine: 'European',
    cover_url: 'https://images.unsplash.com/photo-1414235077428-338989a2e8c0?auto=format&fit=crop&w=800&q=70',
  },
  {
    google_place_id: 'stub-cutler-and-co',
    name: 'Cutler & Co',
    address: '55-57 Gertrude St',
    city: 'Fitzroy',
    lat: -37.8063,
    lng: 144.9787,
    cuisine: 'Modern Australian',
    cover_url: 'https://images.unsplash.com/photo-1481931098730-318b6f776db0?auto=format&fit=crop&w=800&q=70',
  },
  {
    google_place_id: 'stub-lune-fitzroy',
    name: 'Lune Croissanterie',
    address: '119 Rose St',
    city: 'Fitzroy',
    lat: -37.7986,
    lng: 144.9803,
    cuisine: 'Bakery',
    cover_url: 'https://images.unsplash.com/photo-1509440159596-0249088772ff?auto=format&fit=crop&w=800&q=70',
  },
  {
    google_place_id: 'stub-baby-pizza',
    name: 'Baby Pizza',
    address: '631 Church St',
    city: 'Richmond',
    lat: -37.8288,
    lng: 144.9955,
    cuisine: 'Pizza',
    cover_url: 'https://images.unsplash.com/photo-1565299624946-b28f40a0ae38?auto=format&fit=crop&w=800&q=70',
  },
  {
    google_place_id: 'stub-etta',
    name: 'Etta',
    address: '60 Lygon St',
    city: 'Brunswick East',
    lat: -37.7717,
    lng: 144.9761,
    cuisine: 'Modern Australian',
    cover_url: 'https://images.unsplash.com/photo-1476224203421-9ac39bcb3327?auto=format&fit=crop&w=800&q=70',
  },
];

function stubAutocomplete(input: string, lat?: number, lng?: number) {
  // FB2-BE-1: mirror the live contract — when a finite origin is supplied,
  // surface a computed distance_meters; otherwise omit it (back-compat).
  const hasOrigin = Number.isFinite(lat) && Number.isFinite(lng);
  const q = input.trim().toLowerCase();
  const matches = q === '' ? STUB_PLACES : STUB_PLACES.filter((p) => p.name.toLowerCase().includes(q));
  return matches
    .map((p) => ({
      google_place_id: p.google_place_id,
      name: p.name,
      secondary: `${p.address}, ${p.city}`,
      ...(hasOrigin ? { distance_meters: haversineM(lat as number, lng as number, p.lat, p.lng) } : {}),
    }))
    .slice(0, AUTOCOMPLETE_CAP);
}

function stubDetails(placeId: string): StubPlace | null {
  return STUB_PLACES.find((p) => p.google_place_id === placeId) ?? null;
}

// Stub nearby: proximity-filter STUB_PLACES by a crude great-circle distance and
// return the closest, capped. Shape matches the live nearby return.
function stubNearby(lat: number, lng: number, radiusM: number) {
  const withDist = STUB_PLACES.map((p) => ({ p, d: haversineM(lat, lng, p.lat, p.lng) }))
    .filter((x) => x.d <= radiusM)
    .sort((a, b) => a.d - b.d)
    .slice(0, NEARBY_CAP);
  return withDist.map(({ p, d }) => ({
    id: p.google_place_id, // stub has no UUID; the place id stands in for the row id
    google_place_id: p.google_place_id,
    name: p.name,
    address: p.address,
    city: p.city,
    cuisine: p.cuisine,
    cover_url: p.cover_url,
    // FB2-BE-1: stub mirrors the live contract — surface the computed distance.
    distance_meters: d,
  }));
}

function haversineM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

// ---------------------------------------------------------------------------
// Live Google path (active only when GOOGLE_PLACES_API_KEY is present).
// Uses the Places API (New): Autocomplete + Place Details + Nearby Search.
// ---------------------------------------------------------------------------
// Google answers a bad key, a disabled API or missing billing with a non-2xx and an error body.
// The callers still return nothing (search must not break), but the reason is logged so it shows in
// the function's logs instead of disappearing.
async function logGoogleFailure(what: string, res: Response): Promise<void> {
  let reason = '';
  try {
    const body = await res.json();
    reason = `${body?.error?.status ?? ''} ${body?.error?.message ?? ''}`.trim();
  } catch {
    // no JSON body; the status says enough
  }
  console.error(`Google Places ${what} failed: HTTP ${res.status} ${reason}`);
}

async function googleAutocomplete(
  input: string,
  lat?: number,
  lng?: number,
  sessionToken?: string,
  bias?: { lat: number; lng: number } | null,
) {
  // FB2-BE-1: when BOTH origin coords are present + finite, send `origin` so the
  // Places API (New) returns `distanceMeters` on each placePrediction. Omitted
  // when no origin → predictions carry no distance (back-compat, ranking + shape
  // otherwise unchanged).
  const hasOrigin = Number.isFinite(lat) && Number.isFinite(lng);
  const res = await fetch('https://places.googleapis.com/v1/places:autocomplete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': GOOGLE_KEY },
    body: JSON.stringify({
      input,
      // PH-E2: 5 food/bev primary types (the New API autocomplete cap). Surfaces
      // venues, not cities/regions, for "where did you eat?".
      includedPrimaryTypes: AUTOCOMPLETE_PRIMARY_TYPES,
      // 0066: rank near the caller, never fence. No bias point → Google's own ranking.
      ...(bias
        ? { locationBias: { circle: { center: { latitude: bias.lat, longitude: bias.lng }, radius: BIAS_RADIUS_M } } }
        : {}),
      languageCode: LANGUAGE,
      // FB2-BE-1: origin → Google returns distanceMeters per suggestion. Only
      // sent when both coords are finite (additive).
      ...(hasOrigin ? { origin: { latitude: lat as number, longitude: lng as number } } : {}),
      // BE-PLACES-3: when a session token is supplied, bill the autocomplete
      // keystrokes + the eventual Place Details as ONE session. Omitted → each
      // request bills standalone (back-compat).
      ...(sessionToken ? { sessionToken } : {}),
    }),
  });
  if (!res.ok) {
    await logGoogleFailure('autocomplete', res);
    return [];
  }
  const data = await res.json();
  const suggestions = (data.suggestions ?? []) as any[];
  return suggestions
    .filter((s) => s.placePrediction)
    .map((s) => {
      // FB2-BE-1: surface Google's distanceMeters when present (Google only
      // returns it when an origin was sent). Omit the field entirely otherwise.
      const dm = s.placePrediction.distanceMeters;
      return {
        google_place_id: s.placePrediction.placeId as string,
        // Stored rows are cleaned by the restaurants trigger (0075); a prediction isn't stored yet,
        // so it gets the same rule here and reads the same as the row it becomes.
        name: cleanPlaceName((s.placePrediction.structuredFormat?.mainText?.text ?? s.placePrediction.text?.text) as string),
        secondary: (s.placePrediction.structuredFormat?.secondaryText?.text ?? '') as string,
        ...(Number.isFinite(dm) ? { distance_meters: dm as number } : {}),
      };
    })
    // PH-E3: cap typed predictions at 5.
    .slice(0, AUTOCOMPLETE_CAP);
}

async function googleDetails(placeId: string, sessionToken?: string): Promise<StubPlace | null> {
  // BE-PLACES-3: sessionToken is a GET query param on Place Details (it closes
  // the autocomplete session opened above). Omitted → standalone Details call.
  const detailsUrl = new URL(`https://places.googleapis.com/v1/places/${placeId}`);
  if (sessionToken) detailsUrl.searchParams.set('sessionToken', sessionToken);
  detailsUrl.searchParams.set('languageCode', LANGUAGE);
  const res = await fetch(detailsUrl.toString(), {
    headers: {
      'X-Goog-Api-Key': GOOGLE_KEY,
      // BE-PLACES-1: `photos` dropped from the field mask — it pushes the request
      // into a higher SKU tier and we discard it (cover_url stays ''). No Place
      // Photo calls until Eamon revisits.
      'X-Goog-FieldMask':
        // addressComponents (an Essentials field, same tier) names the town outside Australia.
        'id,displayName,formattedAddress,addressComponents,location,types,primaryTypeDisplayName',
    },
  });
  if (!res.ok) {
    await logGoogleFailure('details', res);
    return null;
  }
  const p = await res.json();
  if (!p.id) return null;
  // The SUBURB, not a street line: localityFromAddress mirrors place_locality() (0029). See
  // ./locality.ts for the mangle this replaced. Forward-only — existing rows are not rewritten.
  const city = localityFromAddress(p.formattedAddress, p.addressComponents);
  return {
    google_place_id: p.id,
    name: p.displayName?.text ?? 'Unknown',
    address: p.formattedAddress ?? '',
    city,
    lat: p.location?.latitude ?? 0,
    lng: p.location?.longitude ?? 0,
    cuisine: p.primaryTypeDisplayName?.text ?? '',
    cover_url: '', // photo resolution requires a second authenticated photo call; deferred.
  };
}

// PH-BE-2: Google Nearby Search (places:searchNearby) — fallback discovery when
// the DB is thin. Returns StubPlace-shaped detail rows (used for upsert).
async function googleNearby(lat: number, lng: number, radiusM: number): Promise<StubPlace[]> {
  const res = await fetch('https://places.googleapis.com/v1/places:searchNearby', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': GOOGLE_KEY,
      // BE-PLACES-1: no photos in the field mask (preserve the lower SKU tier).
      // `places.` prefix is required on the searchNearby field mask.
      'X-Goog-FieldMask':
        'places.id,places.displayName,places.formattedAddress,places.addressComponents,places.location,places.types,places.primaryTypeDisplayName',
    },
    body: JSON.stringify({
      // PH-E2: broad food/bev type set (searchNearby allows up to 50).
      includedTypes: NEARBY_INCLUDED_TYPES,
      // PH-E3: ask Google for up to the cap (max 20 allowed by the API; 10 is well within).
      maxResultCount: NEARBY_CAP,
      // A circle around the phone, wherever it is.
      locationRestriction: {
        circle: { center: { latitude: lat, longitude: lng }, radius: radiusM },
      },
      // Bias the ranking toward distance (closest first) for a "near me" list.
      rankPreference: 'DISTANCE',
      languageCode: LANGUAGE,
    }),
  });
  if (!res.ok) {
    await logGoogleFailure('nearby', res);
    return [];
  }
  const data = await res.json();
  const places = (data.places ?? []) as any[];
  return places
    .filter((p) => p.id)
    .map((p) => {
      // Same derivation as op=details — one implementation, in ./locality.ts.
      const city = localityFromAddress(p.formattedAddress, p.addressComponents);
      return {
        google_place_id: p.id as string,
        name: p.displayName?.text ?? 'Unknown',
        address: p.formattedAddress ?? '',
        city,
        lat: p.location?.latitude ?? 0,
        lng: p.location?.longitude ?? 0,
        cuisine: p.primaryTypeDisplayName?.text ?? '',
        cover_url: '',
      } as StubPlace;
    });
}

// ---------------------------------------------------------------------------
// Service-role client (server-side reads/writes that bypass RLS). One per
// request lifecycle — cheap to construct, no session persistence.
// ---------------------------------------------------------------------------
function adminClient() {
  return createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });
}

// ---------------------------------------------------------------------------
// AUTH GATE (TIDY-BE-2). Validate the caller's `Authorization: Bearer <jwt>`
// against Supabase Auth and require a REAL end user. The anon/publishable key is
// itself a valid project JWT (role=anon) and is extractable from the JS bundle —
// platform-level verify_jwt accepts it — so we must additionally require that
// the token resolves to a USER. `auth.getUser(token)` returns the user only for
// a genuine signed-in access token; the bare anon key resolves to no user.
//
// Returns the user id on success, or null on any failure (missing/anon-only/
// invalid/expired token). The gate NEVER fails open — null → the caller 401s.
async function authedUserId(req: Request): Promise<string | null> {
  const header = req.headers.get('Authorization') ?? '';
  const token = header.replace(/^Bearer\s+/i, '').trim();
  if (!token) return null;
  try {
    // anon-key client purely to validate the supplied token. We do NOT trust the
    // header's identity for anything but this check; all DB work stays on the
    // service-role client below.
    const authClient = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
    const { data, error } = await authClient.auth.getUser(token);
    if (error || !data?.user?.id) return null;
    return data.user.id;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// RATE LIMIT (TIDY-BE-2). One atomic per-user fixed-window check via the
// places_rate_hit RPC (migration 0013). Returns true when the request is within
// the ceiling, false when it should be rejected with 429.
//
// FAILS OPEN: any infra error (RPC/table missing, transient DB error) returns
// true (allow). The JWT gate is the must-have abuse guard; the rate limiter is a
// secondary layer and must never take down restaurant search if 0013 hasn't been
// applied yet or the DB hiccups. A genuine over-limit (the RPC returning false)
// is the ONLY path that denies.
async function withinRateLimit(userId: string): Promise<boolean> {
  try {
    const admin = adminClient();
    const { data, error } = await admin.rpc('places_rate_hit', {
      p_user_id: userId,
      p_window_seconds: RATE_LIMIT_WINDOW_S,
      p_limit: RATE_LIMIT_MAX,
    });
    if (error) {
      console.error('places_rate_hit failed (failing open):', error.message);
      return true; // fail open — never block search on a limiter error
    }
    return data === true; // RPC returns boolean: true = allowed, false = over limit
  } catch (e) {
    console.error('places_rate_hit threw (failing open):', e);
    return true;
  }
}

// DAILY BUDGET (0093). The per-minute limit above still lets one account make ~130k billable calls a
// day; this caps each person at 400 Google calls a day and everyone at 4,000. Counted only when Google
// is about to be called (a place we already hold costs nothing). FAILS CLOSED: no answer from the
// budget, no Google call — the caller gets our own rows, as in stub mode for a place we hold.
async function placesBudgetAllows(userId: string): Promise<boolean> {
  try {
    const { data, error } = await adminClient().rpc('places_budget_hit', { p_user_id: userId });
    if (error) console.error('places_budget_hit failed (failing closed):', error.message);
    return !error && data === true;
  } catch (e) {
    console.error('places_budget_hit threw (failing closed):', e);
    return false;
  }
}

/** Longer than any place name anyone types: autocomplete input past this is cut, not sent. */
const AUTOCOMPLETE_MAX_INPUT = 120;

const RESTAURANT_COLS = 'id, google_place_id, name, address, city, cuisine, cover_url';

type RestaurantRow = {
  id: string;
  google_place_id: string | null;
  name: string;
  address: string | null;
  city: string | null;
  cuisine: string | null;
  cover_url: string | null;
  // FB2-BE-1: distance from the nearby query origin, in metres. Only set on
  // `op=nearby` rows (from the restaurants_nearby RPC's distance_m or computed
  // from the Google-fallback location). Optional — additive, omitted elsewhere.
  distance_meters?: number;
};

// BE-PLACES-4: known-place short-circuit. If this google_place_id is already a
// restaurants row, return it WITHOUT touching Google (saves a paid Details call).
async function findRestaurantByPlaceId(placeId: string) {
  const admin = adminClient();
  const { data, error } = await admin
    .from('restaurants')
    .select(RESTAURANT_COLS)
    .eq('google_place_id', placeId)
    .maybeSingle();
  if (error) throw error;
  return data; // null when absent
}

// ---------------------------------------------------------------------------
// SEARCH-BLEND (MANUAL-RESTO, widened 2026-09-01). Fuzzy-match restaurants we
// ALREADY HOLD by name so they surface ALONGSIDE Places predictions in the
// "Where did you eat?" step. The DB half is the search_local_restaurants RPC
// (migration 0017): pg_trgm word_similarity + ILIKE-substring over ALL local
// rows, returning a match_score (0..1) and a `strong` flag, strongest-first.
//
// WIDENED FROM MANUAL-ONLY: this used to call search_manual_restaurants (0015),
// which filtered source='manual' — so a Places-SOURCED row we already had was
// invisible to search. The typed query then matched only Google's prediction,
// and selecting it cost a paid op=details Details call whose upsert re-derived a
// row we already held — minting a DUPLICATE whenever Google's place id differed
// from the one on our row (the staging "two Chin Chins" incident; the same path
// is live in prod). 0017's RPC is 0015's body minus the source filter, so a
// known restaurant now shadows its own Google prediction (blendResults de-dupes
// by normalised name, local-first), is selected directly by row id, and neither
// the Details call nor the duplicate ever happens.
//
// WIRE: unchanged. These rows still ride the `kind:'manual'` discriminator,
// whose contract meaning is "already a restaurants row, select directly, do not
// resolve" — true of a Places-sourced local row too. NO client change; additive
// in effect (more rows are directly selectable), nothing moves shape.
//
// SOFT-FAIL: any failure here returns [] so the core Places autocomplete is
// NEVER broken by a local-search hiccup (an unapplied RPC, a transient DB
// error). Blending is additive; Places-only is always a valid result. Note this
// covers the deploy ordering too: if the function ships before 0017 applies, the
// RPC 404s, this returns [], and search degrades to Places-only rather than
// breaking.
// ---------------------------------------------------------------------------
async function searchLocalRestaurants(query: string, limit = AUTOCOMPLETE_CAP): Promise<LocalMatch[]> {
  const q = query.trim();
  if (q.length < 2) return []; // mirror the FE ≥2-char autocomplete gate
  try {
    const admin = adminClient();
    const { data, error } = await admin.rpc('search_local_restaurants', {
      p_query: q,
      p_limit: limit,
    });
    if (error) {
      console.error('search_local_restaurants failed (soft-fail to Places-only):', error.message);
      return [];
    }
    return (data ?? []) as LocalMatch[];
  } catch (e) {
    console.error('search_local_restaurants threw (soft-fail to Places-only):', e);
    return [];
  }
}

// 0066: where to rank a typed search around when the app sent no location — where this person
// last ate. Soft-fail: no row, an unapplied 0066 or a DB hiccup all mean "no bias", never an error.
async function lastPlacePoint(userId: string): Promise<{ lat: number; lng: number } | null> {
  try {
    const { data, error } = await adminClient().rpc('places_bias_point', { p_user_id: userId });
    if (error) {
      console.error('places_bias_point failed (no bias):', error.message);
      return null;
    }
    const row = Array.isArray(data) ? data[0] : data;
    const lat = Number(row?.lat);
    const lng = Number(row?.lng);
    return row && Number.isFinite(lat) && Number.isFinite(lng) ? { lat, lng } : null;
  } catch (e) {
    console.error('places_bias_point threw (no bias):', e);
    return null;
  }
}

// RANKING / DEDUPE / CAP for the blended `results` list now lives in ./blend.ts
// (byDistanceAsc + blendResults + the SearchResult union), imported at the top of
// this file. It was extracted verbatim so blend_test.ts can test the REAL
// implementation — index.ts is a Deno.serve entrypoint that reads secrets on
// import and cannot be imported by a test.

// PH-BE-2: PostGIS-first nearby. Calls the GIST-indexed restaurants_nearby RPC
// (data-model §5; defined in migration 0005). KNN-ordered by distance.
// FB2-BE-1: surfaces the RPC's distance_m as `distance_meters` on each row.
async function dbNearby(lat: number, lng: number, radiusM: number): Promise<RestaurantRow[]> {
  const admin = adminClient();
  const { data, error } = await admin.rpc('restaurants_nearby', {
    p_lat: lat,
    p_lng: lng,
    p_radius_m: radiusM,
    page_size: NEARBY_CAP,
  });
  if (error) throw error;
  return ((data ?? []) as any[]).map((r) => ({
    id: r.id,
    google_place_id: r.google_place_id,
    name: r.name,
    address: r.address,
    city: r.city,
    cuisine: r.cuisine,
    cover_url: r.cover_url,
    // FB2-BE-1: the RPC returns distance_m (metres from the query point). Surface
    // it as distance_meters; omit if somehow null.
    ...(Number.isFinite(r.distance_m) ? { distance_meters: r.distance_m as number } : {}),
  }));
}

// Chains (0085): once places are handed back, link any whose name repeats into their chain. In the
// background, so no answer waits on it; live Google path only (the website is a Details call, made only
// for a repeated name and once per place). Each website lookup is charged to the caller's daily budget
// like any other Google call (audit 26 Oct, finding 14); over it, the place is simply checked later.
function linkChainsLater(ids: (string | null | undefined)[], userId: string): void {
  if (STUB) return;
  const list = [...new Set(ids.filter((x): x is string => !!x))];
  if (list.length === 0) return;
  const website = async (placeId: string) =>
    (await placesBudgetAllows(userId)) ? googleWebsite(GOOGLE_KEY, placeId) : { ok: false, host: null };
  const work = linkChains(adminClient(), list, website)
    .catch((e) => console.error('chains:', e instanceof Error ? e.message : e));
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(work);
}

// ---------------------------------------------------------------------------
// Upsert the resolved place into restaurants by google_place_id (service role).
// ---------------------------------------------------------------------------
async function upsertRestaurant(place: StubPlace): Promise<RestaurantRow> {
  const admin = adminClient();
  const { data, error } = await admin
    .from('restaurants')
    .upsert(
      {
        google_place_id: place.google_place_id,
        name: place.name,
        address: place.address,
        city: place.city,
        // PostGIS geography accepts the WKT EWKT form on insert via PostgREST.
        location: `SRID=4326;POINT(${place.lng} ${place.lat})`,
        cuisine: place.cuisine || null,
        cover_url: place.cover_url || null,
      },
      { onConflict: 'google_place_id' },
    )
    .select(RESTAURANT_COLS)
    .single();
  if (error) throw error;
  return data as RestaurantRow;
}

// PH-BE-2: upsert a batch of Google nearby results, returning the persisted rows
// (so they carry our UUID `id`).
// FB2-BE-1: given the query origin (originLat/originLng), compute each row's
// distance_meters from the place's own lat/lng via haversineM — the upserted
// RestaurantRow no longer carries coords, so we derive distance here, before the
// StubPlace shape is dropped.
//
// PERF: this was up to NEARBY_CAP (10) SEQUENTIAL single-row upserts — 10 DB
// round-trips on the Google-fallback path. It is now ONE bulk upsert (a single
// round-trip via PostgREST's array upsert on the restaurants_google_place_id_key
// TOTAL unique constraint restored in 0016, which ON CONFLICT (google_place_id)
// targets). Contract-identical output: the returned rows are emitted in the SAME
// order as `places` (Google's DISTANCE ranking), each carrying its computed
// distance_meters, so the caller's merge/ordering is unchanged.
//
// SAFETY: a single bulk upsert statement cannot affect the same conflict target
// row twice, so we DEDUPE the batch by google_place_id first (the prior per-row
// loop tolerated intra-batch dupes because each was its own statement). Google
// searchNearby does not normally return duplicate place ids, but the dedupe makes
// the bulk statement robust regardless. ON CONFLICT still handles cross-request
// races (another request upserting the same place concurrently).
async function upsertNearbyBatch(
  places: StubPlace[],
  originLat: number,
  originLng: number,
): Promise<RestaurantRow[]> {
  if (places.length === 0) return [];

  // Dedupe by google_place_id, first-occurrence wins (preserves Google's order).
  const uniqueByPlaceId = new Map<string, StubPlace>();
  for (const p of places) {
    if (!uniqueByPlaceId.has(p.google_place_id)) uniqueByPlaceId.set(p.google_place_id, p);
  }

  const admin = adminClient();
  const { data, error } = await admin
    .from('restaurants')
    .upsert(
      [...uniqueByPlaceId.values()].map((place) => ({
        google_place_id: place.google_place_id,
        name: place.name,
        address: place.address,
        city: place.city,
        // PostGIS geography accepts the WKT EWKT form on insert via PostgREST.
        location: `SRID=4326;POINT(${place.lng} ${place.lat})`,
        cuisine: place.cuisine || null,
        cover_url: place.cover_url || null,
      })),
      { onConflict: 'google_place_id' },
    )
    .select(RESTAURANT_COLS);
  if (error) throw error;

  // PostgREST does NOT guarantee the returned rows are in input order, so map
  // persisted rows by google_place_id, then emit in the ORIGINAL `places` order
  // (Google's DISTANCE ranking) with each row's computed distance_meters — an
  // output identical in shape AND order to the prior sequential implementation.
  const persistedByPlaceId = new Map<string, RestaurantRow>();
  for (const row of ((data ?? []) as RestaurantRow[])) {
    if (row.google_place_id) persistedByPlaceId.set(row.google_place_id, row);
  }

  const rows: RestaurantRow[] = [];
  const emitted = new Set<string>();
  for (const place of places) {
    if (emitted.has(place.google_place_id)) continue;
    emitted.add(place.google_place_id);
    const row = persistedByPlaceId.get(place.google_place_id);
    if (!row) continue; // defensively skip any row that failed to persist
    rows.push({ ...row, distance_meters: haversineM(originLat, originLng, place.lat, place.lng) });
  }
  return rows;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const url = new URL(req.url);
  const op = url.searchParams.get('op') ?? 'autocomplete';

  // TIDY-BE-2 — AUTH GATE: require a verified end-user JWT for ALL ops. The bare
  // anon key (extractable from the bundle) resolves to no user → 401. This runs
  // before any billable work or DB write. The service-role client below still
  // does the actual upserts; only the gate is new.
  //
  // PERF: the JWT verify (a GoTrue round-trip) and reading the request body are
  // INDEPENDENT, so overlap them with Promise.all — shaving the body-parse off
  // the critical path. This does NOT weaken the cost invariant: the rate limit
  // still runs AFTER auth resolves a userId and BEFORE any billable Google call,
  // so a rate-limited (or unauthenticated) caller never triggers a Google request.
  let body: any = {};
  const [userId, parsedBody] = await Promise.all([
    authedUserId(req),
    req.json().then((b) => b ?? {}).catch(() => ({})),
  ]);
  body = parsedBody;
  if (!userId) return json({ error: 'unauthorized' }, 401);

  // TIDY-BE-2 — RATE LIMIT: per-user ceiling (fails open on infra error). A real
  // over-limit → 429; everything else proceeds. Still strictly before any Google
  // API call (cost control: never call Google for a rate-limited user).
  if (!(await withinRateLimit(userId))) {
    return json({ error: 'rate limit exceeded' }, 429);
  }

  // BE-PLACES-3: optional, additive. Present in either op body → forwarded to
  // Google to bill the autocomplete + details as one session. Absent → unchanged.
  const sessionToken = body.session_token ? String(body.session_token) : undefined;

  try {
    if (op === 'autocomplete') {
      const input = String(body.input ?? '').slice(0, AUTOCOMPLETE_MAX_INPUT);
      // FB2-BE-1: optional origin → distance_meters on predictions. Coerce to
      // Number so a string "lat" from the body still works; non-finite → omitted.
      const acLat = body.lat == null ? undefined : Number(body.lat);
      const acLng = body.lng == null ? undefined : Number(body.lng);
      // SEARCH-BLEND: fetch Places predictions AND fuzzy matches against the
      // restaurants we already hold, in parallel, then merge into a unified
      // `results` list. Local search is soft-fail (returns [] on any error) so it
      // can never break the core Places autocomplete. The DB call works in stub
      // mode too (the local catalogue is independent of the Google key).
      const hasOrigin = Number.isFinite(acLat) && Number.isFinite(acLng);
      const [predictions, local] = await Promise.all([
        STUB
          ? Promise.resolve(stubAutocomplete(input, acLat, acLng))
          : placesBudgetAllows(userId).then((allowed) =>
            !allowed
              ? [] // over today's budget: our own rows only
              : (hasOrigin
                ? Promise.resolve({ lat: acLat as number, lng: acLng as number })
                : lastPlacePoint(userId)
              ).then((bias) => googleAutocomplete(input, acLat, acLng, sessionToken, bias))
          ),
        searchLocalRestaurants(input),
      ]);
      const results = blendResults(predictions as Prediction[], local as LocalMatch[]);
      // `predictions` (Places-only) is UNCHANGED for back-compat (existing
      // clients ignore `results`); `results` is the new unified, ranked,
      // capped-at-5, discriminated list the FE migrates to.
      return json({ stub: STUB, predictions, results });
    }

    if (op === 'details') {
      const placeId = String(body.google_place_id ?? '');
      if (!placeId) return json({ error: 'google_place_id required' }, 400);

      // BE-PLACES-4: if we already have this place as a row, return it and skip
      // the paid Google Details call entirely (works in stub mode too).
      const known = await findRestaurantByPlaceId(placeId);
      if (known) {
        linkChainsLater([known.id], userId);
        return json({ stub: STUB, restaurant: known });
      }

      if (!STUB && !(await placesBudgetAllows(userId))) return json({ error: 'daily places budget reached' }, 429);
      const place = STUB ? stubDetails(placeId) : await googleDetails(placeId, sessionToken);
      if (!place) return json({ error: 'place not found' }, 404);
      const restaurant = await upsertRestaurant(place);
      linkChainsLater([restaurant.id], userId);
      return json({ stub: STUB, restaurant });
    }

    // PH-BE-2: device-location nearby. PostGIS-first KNN, Google-fallback.
    if (op === 'nearby') {
      const lat = Number(body.lat);
      const lng = Number(body.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
        return json({ error: 'lat and lng (numbers) required' }, 400);
      }
      const radiusM = Math.min(
        Math.max(Number(body.radius) || NEARBY_DEFAULT_RADIUS_M, NEARBY_MIN_RADIUS_M),
        NEARBY_MAX_RADIUS_M,
      );

      // Stub mode: proximity-filter the fixture set, no DB/Google.
      if (STUB) {
        return json({ stub: true, source: 'db', restaurants: stubNearby(lat, lng, radiusM) });
      }

      // 1) PostGIS-first (E-5 RESOLVED): the GIST-indexed KNN RPC. Free, fast.
      const dbRows = await dbNearby(lat, lng, radiusM);
      if (dbRows.length >= DB_NEARBY_THRESHOLD) {
        linkChainsLater(dbRows.slice(0, NEARBY_CAP).map((r) => r.id), userId);
        return json({ stub: false, source: 'db', restaurants: dbRows.slice(0, NEARBY_CAP) });
      }

      // 2) DB is thin → fall back to Google searchNearby for discovery, upsert
      //    the results so the DB warms for next time.
      if (!(await placesBudgetAllows(userId))) {
        return json({ stub: false, source: 'db', restaurants: dbRows.slice(0, NEARBY_CAP) });
      }
      const googlePlaces = await googleNearby(lat, lng, radiusM);
      // FB2-BE-1: pass the query origin so each upserted Google row gets a
      // computed distance_meters (the upserted row no longer carries coords).
      const upserted = await upsertNearbyBatch(googlePlaces, lat, lng);

      // 3) Merge DB + Google, dedupe by google_place_id (fall back to id when a
      //    row has no place id), preserving DB-first (KNN) ordering then Google.
      const merged: RestaurantRow[] = [];
      const seen = new Set<string>();
      for (const r of [...dbRows, ...upserted]) {
        const key = r.google_place_id ?? r.id;
        if (seen.has(key)) continue;
        seen.add(key);
        merged.push(r);
      }

      const source = upserted.length === 0 ? 'db' : dbRows.length === 0 ? 'google' : 'blend';
      linkChainsLater(merged.slice(0, NEARBY_CAP).map((r) => r.id), userId);
      return json({ stub: false, source, restaurants: merged.slice(0, NEARBY_CAP) });
    }

    return json({ error: `unknown op '${op}'` }, 400);
  } catch (err) {
    // The detail is logged, not returned: database messages name tables and columns (audit finding 19).
    console.error('places-search: unhandled:', err instanceof Error ? err.message : err);
    return json({ error: 'search failed' }, 500);
  }
});
