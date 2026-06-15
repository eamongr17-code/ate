// supabase/functions/places-search/index.ts
//
// Ate backend — Wave 0: Google Places proxy (data-model §1.2, §5 "nearby").
//
// Two operations, switched by `?op=`:
//   - op=autocomplete  body: { input: string, lat?, lng? }
//       → returns place predictions [{ google_place_id, name, secondary }]
//   - op=details       body: { google_place_id: string }
//       → resolves a Place to full detail AND UPSERTS a restaurants row by
//         google_place_id, returning the restaurant row (the "resolve Place → row"
//         write path). This is the only way restaurants are created.
//
// STUB MODE (lead decision E-1): the Google Places API key is not yet provisioned.
// When the env secret GOOGLE_PLACES_API_KEY is ABSENT, this function serves
// deterministic FIXTURE data behind the SAME interface — so the client builds
// against the real contract today and it goes live unchanged the moment the key
// lands. When the secret is PRESENT, the real Google path runs.
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
// Fixture data (stub mode) — grounded in src/data/fixtures.ts restaurants.
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
    google_place_id: 'seed_place_goldees',
    name: "Goldee's BBQ",
    address: '4645 Dick Price Rd',
    city: 'Fort Worth, TX',
    lat: 32.6543,
    lng: -97.2078,
    cuisine: 'Barbecue',
    cover_url: 'https://images.unsplash.com/photo-1558030006-450675393462?auto=format&fit=crop&w=600&q=70',
  },
  {
    google_place_id: 'seed_place_smokering',
    name: 'Smoke Ring Co.',
    address: '1 Pit Row',
    city: 'Kansas City, MO',
    lat: 39.0997,
    lng: -94.5786,
    cuisine: 'Barbecue',
    cover_url: 'https://images.unsplash.com/photo-1529193591184-b1d58069ecdd?auto=format&fit=crop&w=600&q=70',
  },
  {
    google_place_id: 'seed_place_seans',
    name: "Sean's Shack",
    address: '12 Harbor Way',
    city: 'Portland, ME',
    lat: 43.6591,
    lng: -70.2568,
    cuisine: 'Seafood',
    cover_url: 'https://images.unsplash.com/photo-1559737558-2f5a35f4523b?auto=format&fit=crop&w=600&q=70',
  },
];

function stubAutocomplete(input: string) {
  const q = input.trim().toLowerCase();
  const matches = q === '' ? STUB_PLACES : STUB_PLACES.filter((p) => p.name.toLowerCase().includes(q));
  return matches.map((p) => ({
    google_place_id: p.google_place_id,
    name: p.name,
    secondary: `${p.address}, ${p.city}`,
  }));
}

function stubDetails(placeId: string): StubPlace | null {
  return STUB_PLACES.find((p) => p.google_place_id === placeId) ?? null;
}

// ---------------------------------------------------------------------------
// Live Google path (active only when GOOGLE_PLACES_API_KEY is present).
// Uses the Places API (New): Text Search Autocomplete + Place Details.
// ---------------------------------------------------------------------------
async function googleAutocomplete(input: string, lat?: number, lng?: number, sessionToken?: string) {
  const res = await fetch('https://places.googleapis.com/v1/places:autocomplete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': GOOGLE_KEY },
    body: JSON.stringify({
      input,
      // Ate is a restaurant-logging app — bias autocomplete to food establishments
      // so "where did you eat?" surfaces venues, not cities/regions. Up to 5 primary
      // types (Places API New). Covers restaurants, cafés, bars, bakeries, takeaway.
      includedPrimaryTypes: ['restaurant', 'cafe', 'bar', 'bakery', 'meal_takeaway'],
      // BE-PLACES-3: when a session token is supplied, bill the autocomplete
      // keystrokes + the eventual Place Details as ONE session. Omitted → each
      // request bills standalone (back-compat).
      ...(sessionToken ? { sessionToken } : {}),
      ...(lat != null && lng != null
        ? { locationBias: { circle: { center: { latitude: lat, longitude: lng }, radius: 50000 } } }
        : {}),
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
    }));
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

// ---------------------------------------------------------------------------
// Service-role client (server-side reads/writes that bypass RLS). One per
// request lifecycle — cheap to construct, no session persistence.
// ---------------------------------------------------------------------------
function adminClient() {
  return createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });
}

const RESTAURANT_COLS = 'id, google_place_id, name, address, city, cuisine, cover_url';

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
// Upsert the resolved place into restaurants by google_place_id (service role).
// ---------------------------------------------------------------------------
async function upsertRestaurant(place: StubPlace) {
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
  return data;
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

    return json({ error: `unknown op '${op}'` }, 400);
  } catch (err) {
    return json({ error: String(err instanceof Error ? err.message : err) }, 500);
  }
});
