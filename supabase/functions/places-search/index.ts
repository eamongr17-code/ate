// supabase/functions/places-search/index.ts
//
// Ate backend — Google Places proxy (data-model §1.2, §5 "nearby").
//
// Three operations, switched by `?op=`:
//   - op=autocomplete  body: { input: string, lat?, lng?, session_token? }
//       → returns place predictions [{ google_place_id, name, secondary,
//         distance_meters? }] — VIC-restricted, food/bev-only, capped at 5
//         (PH-BE-1). FB2-BE-1: when BOTH lat+lng are sent, `origin` is forwarded
//         to Google and each prediction carries `distance_meters` (metres from the
//         origin); omitted otherwise (additive, back-compat). The wire field is
//         snake_case `distance_meters` to match the FE consumer + the existing
//         wire convention (google_place_id, cover_url, secondary).
//       MANUAL-RESTO (search-blend): ALSO returns `results` — a unified, ranked,
//         capped-at-5, discriminated list merging the Places predictions with
//         fuzzy-matched user-added (source='manual') restaurants from our DB
//         (via the search_manual_restaurants RPC, migration 0015). Each item is
//         tagged `kind:'place'` (resolve-on-select, has google_place_id) or
//         `kind:'manual'` (already a restaurants row, has the real `id`, select
//         directly — no resolve). `predictions` stays Places-only for
//         back-compat; the FE migrates to `results`. See
//         docs/backend/manual-search-blend-contract.md.
//   - op=details       body: { google_place_id: string, session_token? }
//       → resolves a Place to full detail AND UPSERTS a restaurants row by
//         google_place_id, returning the restaurant row (the "resolve Place → row"
//         write path). This is the only way restaurants are created.
//   - op=nearby        body: { lat: number, lng: number, radius?: number }
//       → PostGIS-first KNN against our restaurants table (free, GIST-indexed,
//         via the restaurants_nearby RPC); falls back to Google searchNearby
//         ONLY when DB matches are below threshold, upserting the Google results.
//         VIC-restricted, food/bev-only, capped at 10 (PH-BE-2).
//         Returns { stub, source, restaurants: [{ id, google_place_id, name,
//         address, city, cuisine, cover_url, distance_meters? }] }. FB2-BE-1:
//         distance_meters = the restaurants_nearby RPC's distance_m (DB rows) or a
//         haversine from the query origin (Google-fallback rows), in metres.
//
// Places hardening (PH-BE-1 / PH-BE-2, Eamon-locked 2026-06-16):
//   - VIC restriction: bounding-box locationRestriction (rectangle) + region
//     'au' CONTAIN results to the VIC box (a hard restriction, not a bias). On
//     top of containment, a server-side DROP removes only border-bleed — a
//     result whose address/secondary text POSITIVELY names another AU
//     state/territory (NSW/QLD/SA/WA/NT/TAS/ACT). A result with no state token
//     (just a suburb + "Australia") is KEPT, because the rectangle already
//     guarantees it sits inside the VIC box. (Earlier we required a VIC token,
//     but Google routinely omits the state in autocomplete secondary text, which
//     silently dropped legitimate Melbourne venues → 0 predictions → a
//     RestaurantNotFoundError on the core flow. PH-BE-1+2 peer-review fix.)
//     Applied to BOTH autocomplete and nearby (PH-E1 RESOLVED).
//   - Food/bev types: autocomplete keeps the 5 includedPrimaryTypes — Places API
//     (New) autocomplete CAPS includedPrimaryTypes at 5 (PH-E2 RESOLVED). Nearby
//     uses the broader food/bev includedTypes set (searchNearby allows up to 50).
//     All type strings verified against the live Places API (New) Table-A docs
//     (developers.google.com/maps/documentation/places/web-service/place-types).
//   - Caps: typed autocomplete → 5 predictions; nearby default list → 10 (PH-E3
//     RESOLVED). Enforced server-side; the FE belt-and-suspenders slices too.
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

// VIC bounding box (PH-E1): rectangle covering Victoria, Australia. low =
// south-west corner, high = north-east corner. Used as `locationRestriction`
// for autocomplete + nearby — a hard restriction, not a bias.
// south = -39.20: covers VIC's southernmost point (Wilsons Promontory ~-39.14)
// with a small margin. An earlier -37.5 was NORTH of Melbourne CBD (-37.81) and
// silently excluded Melbourne, Geelong, the Mornington Peninsula, Phillip Island
// and all of Gippsland → 0 autocomplete predictions for the core flow.
const VIC_RECTANGLE = {
  low: { latitude: -39.2, longitude: 140.96 },
  high: { latitude: -33.98, longitude: 149.98 },
};

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

// Result caps (PH-E3).
const AUTOCOMPLETE_CAP = 5;
const NEARBY_CAP = 10;

// Nearby radius (metres). Default to a walkable/short-drive radius; clamp to a
// sane range so a malformed client value can't blow out the search.
const NEARBY_DEFAULT_RADIUS_M = 2000;
const NEARBY_MIN_RADIUS_M = 100;
const NEARBY_MAX_RADIUS_M = 50000;

// PostGIS-first threshold (PH-BE-2): if the DB returns at least this many
// nearby rows, serve from DB and skip the paid Google call entirely.
const DB_NEARBY_THRESHOLD = 5;

// VIC post-filter (PH-E1, hardened PH-BE-1+2 follow-up): the bounding-box
// `locationRestriction` rectangle + `includedRegionCodes:['au']` already CONTAIN
// results to the VIC box, so a result inside the box is presumed Victorian. The
// only failure we still need to catch is border-bleed: a venue physically just
// across the VIC line (the box overshoots the SA/NSW borders slightly) whose
// address positively names ANOTHER Australian state/territory.
//
// Earlier we *required* a VIC/"Victoria" token — but Google routinely omits the
// state from autocomplete secondary text (a real Melbourne venue shows
// "Fitzroy, Australia" or just "Melbourne, Australia"), so require-VIC silently
// dropped legitimate venues → 0 predictions → RestaurantNotFoundError on the
// core "where did you eat?" flow. We now invert the rule:
//
//   DROP only when the text POSITIVELY names a non-VIC AU state/territory.
//   KEEP everything else (no state token = inside-the-box = Victorian).
//
// Word-boundary anchors on the abbreviations so "WA" doesn't fire inside
// "WARRNAMBOOL" and "SA" doesn't fire inside "SALE" — both legitimate VIC towns.
const OTHER_AU_STATE_RE =
  /\b(?:NSW|QLD|SA|WA|NT|TAS|ACT)\b|\bNew South Wales\b|\bQueensland\b|\bSouth Australia\b|\bWestern Australia\b|\bNorthern Territory\b|\bTasmania\b|\bAustralian Capital Territory\b/i;

// Returns true when the text positively names a non-VIC state/territory → DROP.
function namesOtherAuState(text: string | null | undefined): boolean {
  return OTHER_AU_STATE_RE.test(text ?? '');
}

// ---------------------------------------------------------------------------
// Fixture data (stub mode) — VIC venues so the stub experience matches the
// production intent (VIC-only, food/bev). Coords are real Melbourne locations.
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

const STUB_PLACES: StubPlace[] = [
  {
    google_place_id: 'seed_place_chintamani',
    name: 'Chin Chin',
    address: '125 Flinders Ln',
    city: 'Melbourne VIC',
    lat: -37.8159,
    lng: 144.9686,
    cuisine: 'Thai',
    cover_url: 'https://images.unsplash.com/photo-1558030006-450675393462?auto=format&fit=crop&w=600&q=70',
  },
  {
    google_place_id: 'seed_place_pellegrini',
    name: "Pellegrini's Espresso Bar",
    address: '66 Bourke St',
    city: 'Melbourne VIC',
    lat: -37.8118,
    lng: 144.9719,
    cuisine: 'Italian',
    cover_url: 'https://images.unsplash.com/photo-1529193591184-b1d58069ecdd?auto=format&fit=crop&w=600&q=70',
  },
  {
    google_place_id: 'seed_place_attica',
    name: 'Attica',
    address: '74 Glen Eira Rd, Ripponlea',
    city: 'Ripponlea VIC',
    lat: -37.8772,
    lng: 144.9966,
    cuisine: 'Modern Australian',
    cover_url: 'https://images.unsplash.com/photo-1559737558-2f5a35f4523b?auto=format&fit=crop&w=600&q=70',
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
async function googleAutocomplete(input: string, lat?: number, lng?: number, sessionToken?: string) {
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
      // PH-E1: hard-restrict to the VIC bounding box (replaces the prior
      // locationBias circle — a bias merely re-ranked, this excludes) + scope
      // to Australia for belt-and-suspenders country containment.
      locationRestriction: { rectangle: VIC_RECTANGLE },
      includedRegionCodes: ['au'],
      // FB2-BE-1: origin → Google returns distanceMeters per suggestion. Only
      // sent when both coords are finite (additive).
      ...(hasOrigin ? { origin: { latitude: lat as number, longitude: lng as number } } : {}),
      // BE-PLACES-3: when a session token is supplied, bill the autocomplete
      // keystrokes + the eventual Place Details as ONE session. Omitted → each
      // request bills standalone (back-compat).
      ...(sessionToken ? { sessionToken } : {}),
    }),
  });
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
        name: (s.placePrediction.structuredFormat?.mainText?.text ?? s.placePrediction.text?.text) as string,
        secondary: (s.placePrediction.structuredFormat?.secondaryText?.text ?? '') as string,
        ...(Number.isFinite(dm) ? { distance_meters: dm as number } : {}),
      };
    })
    // PH-BE-1 follow-up: drop ONLY when the secondary text positively names
    // another AU state/territory (border-bleed). A state-less "Melbourne,
    // Australia" is KEPT — the locationRestriction rectangle already guarantees
    // it's inside the VIC box, and Google often omits the state token.
    .filter((p) => !namesOtherAuState(p.secondary))
    // PH-E3: cap typed predictions at 5.
    .slice(0, AUTOCOMPLETE_CAP);
}

async function googleDetails(placeId: string, sessionToken?: string): Promise<StubPlace | null> {
  // BE-PLACES-3: sessionToken is a GET query param on Place Details (it closes
  // the autocomplete session opened above). Omitted → standalone Details call.
  const detailsUrl = new URL(`https://places.googleapis.com/v1/places/${placeId}`);
  if (sessionToken) detailsUrl.searchParams.set('sessionToken', sessionToken);
  const res = await fetch(detailsUrl.toString(), {
    headers: {
      'X-Goog-Api-Key': GOOGLE_KEY,
      // BE-PLACES-1: `photos` dropped from the field mask — it pushes the request
      // into a higher SKU tier and we discard it (cover_url stays ''). No Place
      // Photo calls until Eamon revisits.
      'X-Goog-FieldMask':
        'id,displayName,formattedAddress,location,types,primaryTypeDisplayName',
    },
  });
  if (!res.ok) return null;
  const p = await res.json();
  if (!p.id) return null;
  // best-effort city from the formatted address
  const parts = (p.formattedAddress ?? '').split(',').map((s: string) => s.trim());
  const city = parts.length >= 3 ? `${parts[parts.length - 3]}, ${parts[parts.length - 2]}` : (parts[1] ?? '');
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
        'places.id,places.displayName,places.formattedAddress,places.location,places.types,places.primaryTypeDisplayName',
    },
    body: JSON.stringify({
      // PH-E2: broad food/bev type set (searchNearby allows up to 50).
      includedTypes: NEARBY_INCLUDED_TYPES,
      // PH-E3: ask Google for up to the cap (max 20 allowed by the API; 10 is well within).
      maxResultCount: NEARBY_CAP,
      // searchNearby's locationRestriction must be a circle (it has no rectangle
      // form). The VIC containment for nearby is enforced by (a) the device being
      // in VIC and (b) the strict VIC post-filter below.
      locationRestriction: {
        circle: { center: { latitude: lat, longitude: lng }, radius: radiusM },
      },
      // Bias the ranking toward distance (closest first) for a "near me" list.
      rankPreference: 'DISTANCE',
    }),
  });
  if (!res.ok) return [];
  const data = await res.json();
  const places = (data.places ?? []) as any[];
  return places
    .filter((p) => p.id)
    .map((p) => {
      const parts = (p.formattedAddress ?? '').split(',').map((s: string) => s.trim());
      const city = parts.length >= 3 ? `${parts[parts.length - 3]}, ${parts[parts.length - 2]}` : (parts[1] ?? '');
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
    })
    // PH-BE-1 follow-up: same drop-only-on-other-state logic on nearby results
    // (formattedAddress). The searchNearby circle + the device being in VIC keep
    // results local; we only drop a result whose address positively names another
    // AU state/territory (border-bleed), never one that merely omits the state.
    .filter((p) => !namesOtherAuState(p.address));
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
// MANUAL-RESTO (search-blend). Fuzzy-match user-added (source='manual')
// restaurants by name so they surface ALONGSIDE Places predictions in the
// "Where did you eat?" step. The DB half is the search_manual_restaurants RPC
// (migration 0015): pg_trgm word_similarity + ILIKE-substring over the manual
// subset, returning a match_score (0..1) and a `strong` flag, strongest-first.
//
// SOFT-FAIL: any failure here returns [] so the core Places autocomplete is
// NEVER broken by a manual-search hiccup (an unapplied RPC, a transient DB
// error). Manual blending is additive; Places-only is always a valid result.
// ---------------------------------------------------------------------------
type ManualMatch = {
  id: string;
  name: string;
  city: string | null;
  cuisine: string | null;
  match_score: number;
  strong: boolean;
};

async function searchManualRestaurants(query: string, limit = AUTOCOMPLETE_CAP): Promise<ManualMatch[]> {
  const q = query.trim();
  if (q.length < 2) return []; // mirror the FE ≥2-char autocomplete gate
  try {
    const admin = adminClient();
    const { data, error } = await admin.rpc('search_manual_restaurants', {
      p_query: q,
      p_limit: limit,
    });
    if (error) {
      console.error('search_manual_restaurants failed (soft-fail to Places-only):', error.message);
      return [];
    }
    return (data ?? []) as ManualMatch[];
  } catch (e) {
    console.error('search_manual_restaurants threw (soft-fail to Places-only):', e);
    return [];
  }
}

// A Places prediction (the shape returned by google/stub Autocomplete).
type Prediction = {
  google_place_id: string;
  name: string;
  secondary?: string;
  distance_meters?: number;
};

// The unified, discriminated search result the FE consumes (op=autocomplete
// `results`). `kind` tells the two apart: a 'place' resolves on select via
// op=details (has google_place_id), a 'manual' IS already a restaurants row
// (has the real `id`) and is selected directly — no resolve.
type SearchResult =
  | { kind: 'place'; google_place_id: string; name: string; secondary?: string; distance_meters?: number }
  | { kind: 'manual'; id: string; name: string; city: string; cuisine?: string; match_score: number };

// Comparator mirroring the FE byDistanceAsc: nearest first, unmeasured rows
// last, stable for ties (so Google's relevance order is preserved within a
// distance tie / the trailing no-distance block).
function byDistanceAsc(a: Prediction, b: Prediction): number {
  const da = a.distance_meters;
  const db = b.distance_meters;
  const aMissing = da == null || !Number.isFinite(da);
  const bMissing = db == null || !Number.isFinite(db);
  if (aMissing && bMissing) return 0;
  if (aMissing) return 1;
  if (bMissing) return -1;
  return (da as number) - (db as number);
}

// Merge Places predictions + fuzzy manual matches into ONE ranked, capped-at-5,
// discriminated list. Ranking (justified in the contract doc):
//   1. STRONG manual matches (near-exact typed name; strongest-first) — these
//      are places this app's users explicitly added AND the query matches them
//      closely, so they lead.
//   2. Places predictions — distance-sorted (nearest first) to preserve the
//      existing "where did you eat?" UX; Google relevance order when no origin.
//   3. WEAK manual matches (ordinary fuzzy / typo) — after Places.
// De-duped by normalised name (first wins → strong-manual > place > weak-manual,
// so a manual row is preferred over a same-named Places prediction: it's
// directly selectable with no resolve round-trip). Capped at AUTOCOMPLETE_CAP.
function blendResults(predictions: Prediction[], manual: ManualMatch[]): SearchResult[] {
  const toManual = (m: ManualMatch): SearchResult => ({
    kind: 'manual',
    id: m.id,
    name: m.name,
    city: m.city ?? '',
    ...(m.cuisine ? { cuisine: m.cuisine } : {}),
    match_score: m.match_score,
  });
  const toPlace = (p: Prediction): SearchResult => ({
    kind: 'place',
    google_place_id: p.google_place_id,
    name: p.name,
    ...(p.secondary ? { secondary: p.secondary } : {}),
    ...(Number.isFinite(p.distance_meters) ? { distance_meters: p.distance_meters as number } : {}),
  });

  const strong = manual.filter((m) => m.strong).map(toManual);
  const weak = manual.filter((m) => !m.strong).map(toManual);
  const places = [...predictions].sort(byDistanceAsc).map(toPlace);

  const ordered = [...strong, ...places, ...weak];
  const seen = new Set<string>();
  const out: SearchResult[] = [];
  for (const r of ordered) {
    const key = r.name.trim().toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(r);
  }
  return out.slice(0, AUTOCOMPLETE_CAP);
}

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
      const input = String(body.input ?? '');
      // FB2-BE-1: optional origin → distance_meters on predictions. Coerce to
      // Number so a string "lat" from the body still works; non-finite → omitted.
      const acLat = body.lat == null ? undefined : Number(body.lat);
      const acLng = body.lng == null ? undefined : Number(body.lng);
      // MANUAL-RESTO (search-blend): fetch Places predictions AND fuzzy manual
      // matches in parallel, then merge into a unified `results` list. Manual
      // search is soft-fail (returns [] on any error) so it can never break the
      // core Places autocomplete. The DB call works in stub mode too (the manual
      // catalogue is independent of the Google key).
      const [predictions, manual] = await Promise.all([
        STUB
          ? Promise.resolve(stubAutocomplete(input, acLat, acLng))
          : googleAutocomplete(input, acLat, acLng, sessionToken),
        searchManualRestaurants(input),
      ]);
      const results = blendResults(predictions as Prediction[], manual);
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
      if (known) return json({ stub: STUB, restaurant: known });

      const place = STUB ? stubDetails(placeId) : await googleDetails(placeId, sessionToken);
      if (!place) return json({ error: 'place not found' }, 404);
      const restaurant = await upsertRestaurant(place);
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
        return json({ stub: false, source: 'db', restaurants: dbRows.slice(0, NEARBY_CAP) });
      }

      // 2) DB is thin → fall back to Google searchNearby for discovery, upsert
      //    the (VIC-filtered) results so the DB warms for next time.
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
      return json({ stub: false, source, restaurants: merged.slice(0, NEARBY_CAP) });
    }

    return json({ error: `unknown op '${op}'` }, 400);
  } catch (err) {
    return json({ error: String(err instanceof Error ? err.message : err) }, 500);
  }
});
