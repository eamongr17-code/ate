// supabase/functions/places-search/index.ts
//
// Ate backend — Google Places proxy (data-model §1.2, §5 "nearby").
//
// Three operations, switched by `?op=`:
//   - op=autocomplete  body: { input: string, lat?, lng?, session_token? }
//       → returns place predictions [{ google_place_id, name, secondary }]
//         VIC-restricted, food/bev-only, capped at 5 (PH-BE-1).
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
//         address, city, cuisine, cover_url }] }.
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
// Secrets this function reads (set via `supabase secrets set`):
//   - GOOGLE_PLACES_API_KEY   (absent → stub mode; present → live Google calls)
//   - SUPABASE_URL            (auto-injected in the Supabase runtime)
//   - SUPABASE_SERVICE_ROLE_KEY (auto-injected; used for the server-side upsert)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const GOOGLE_KEY = Deno.env.get('GOOGLE_PLACES_API_KEY') ?? '';
const STUB = GOOGLE_KEY.trim() === '';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

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

function stubAutocomplete(input: string) {
  const q = input.trim().toLowerCase();
  const matches = q === '' ? STUB_PLACES : STUB_PLACES.filter((p) => p.name.toLowerCase().includes(q));
  return matches
    .map((p) => ({
      google_place_id: p.google_place_id,
      name: p.name,
      secondary: `${p.address}, ${p.city}`,
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
  return withDist.map(({ p }) => ({
    id: p.google_place_id, // stub has no UUID; the place id stands in for the row id
    google_place_id: p.google_place_id,
    name: p.name,
    address: p.address,
    city: p.city,
    cuisine: p.cuisine,
    cover_url: p.cover_url,
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
async function googleAutocomplete(input: string, _lat?: number, _lng?: number, sessionToken?: string) {
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
    .map((s) => ({
      google_place_id: s.placePrediction.placeId as string,
      name: (s.placePrediction.structuredFormat?.mainText?.text ?? s.placePrediction.text?.text) as string,
      secondary: (s.placePrediction.structuredFormat?.secondaryText?.text ?? '') as string,
    }))
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

const RESTAURANT_COLS = 'id, google_place_id, name, address, city, cuisine, cover_url';

type RestaurantRow = {
  id: string;
  google_place_id: string | null;
  name: string;
  address: string | null;
  city: string | null;
  cuisine: string | null;
  cover_url: string | null;
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

// PH-BE-2: PostGIS-first nearby. Calls the GIST-indexed restaurants_nearby RPC
// (data-model §5; defined in migration 0005). KNN-ordered by distance. Returns
// the RESTAURANT_COLS shape (drops distance_m so it matches the contract row).
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
// (so they carry our UUID `id`). Sequential to keep it simple + within the per-
// request budget; the nearby cap (10) bounds the count.
async function upsertNearbyBatch(places: StubPlace[]): Promise<RestaurantRow[]> {
  const rows: RestaurantRow[] = [];
  for (const place of places) {
    rows.push(await upsertRestaurant(place));
  }
  return rows;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const url = new URL(req.url);
  const op = url.searchParams.get('op') ?? 'autocomplete';

  let body: any = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  // BE-PLACES-3: optional, additive. Present in either op body → forwarded to
  // Google to bill the autocomplete + details as one session. Absent → unchanged.
  const sessionToken = body.session_token ? String(body.session_token) : undefined;

  try {
    if (op === 'autocomplete') {
      const input = String(body.input ?? '');
      const predictions = STUB
        ? stubAutocomplete(input)
        : await googleAutocomplete(input, body.lat, body.lng, sessionToken);
      return json({ stub: STUB, predictions });
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
      const upserted = await upsertNearbyBatch(googlePlaces);

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
