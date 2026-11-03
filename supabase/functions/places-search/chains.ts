// supabase/functions/places-search/chains.ts
//
// Chain detection (migration 0085). Two Google places are one chain when their names have the same key
// AND their Google websites have the same host; the database decides (chain_record_and_link), this
// only fetches the websites it needs. Google has no chain id, and websiteUri is a Place Details
// Enterprise field, so a website is asked for only when a place's name repeats (chain_candidates),
// and once per place: the answer is recorded (website_checked_at), a missing website included.
//
// Pure apart from the injected database and fetch, so Node runs the suite (chains_test.ts). Used by
// places-search (in the background, after it hands back places) and dish-dedup's `chains` backfill.

import { localityFromAddress } from './locality.ts';

/** The host of a website: lower case, no `www.`; null for nothing usable. */
export function websiteHost(uri: string | null | undefined): string | null {
  const raw = (uri ?? '').trim();
  if (!raw) return null;
  try {
    const host = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(raw) ? raw : `https://${raw}`).hostname.toLowerCase();
    const bare = host.replace(/^www\d?\./, '').replace(/\.$/, '');
    return bare.includes('.') ? bare : null;
  } catch {
    return null;
  }
}

type Rpc = (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string } | null }>;
export type ChainDb = { rpc: Rpc };
type Candidate = { restaurant_id: string; google_place_id: string | null; checked: boolean };

/** One Place Details call for the website only (Enterprise SKU: 1,000 free a month). */
export async function googleWebsite(
  apiKey: string,
  placeId: string,
  fetchFn: typeof fetch = fetch,
): Promise<{ ok: boolean; host: string | null }> {
  const res = await fetchFn(`https://places.googleapis.com/v1/places/${encodeURIComponent(placeId)}`, {
    headers: { 'X-Goog-Api-Key': apiKey, 'X-Goog-FieldMask': 'websiteUri' },
  });
  if (!res.ok) {
    console.error(`Google Places website failed: HTTP ${res.status}`);
    await res.body?.cancel();
    return { ok: false, host: null };
  }
  const p = await res.json().catch(() => ({}));
  return { ok: true, host: websiteHost(p?.websiteUri) };
}

/**
 * Link `ids` (or, when null, every unchained place whose name repeats: the backfill) into their chains.
 * Fetches at most `maxFetches` websites. A failed fetch is not recorded, so it is asked again later.
 */
export async function linkChains(
  db: ChainDb,
  ids: string[] | null,
  website: (placeId: string) => Promise<{ ok: boolean; host: string | null }>,
  { maxFetches = 20, limit = 50 }: { maxFetches?: number; limit?: number } = {},
): Promise<{ candidates: number; fetched: number; chains: string[] }> {
  if (ids && ids.length === 0) return { candidates: 0, fetched: 0, chains: [] };
  const { data, error } = await db.rpc('chain_candidates', { p_ids: ids, p_limit: limit });
  if (error) throw new Error(`chain_candidates: ${error.message}`);
  const rows = (data ?? []) as Candidate[];
  if (rows.length === 0) return { candidates: 0, fetched: 0, chains: [] };

  const websites: { id: string; host: string | null }[] = [];
  for (const r of rows) {
    if (r.checked || !r.google_place_id || websites.length >= maxFetches) continue;
    const w = await website(r.google_place_id);
    if (w.ok) websites.push({ id: r.restaurant_id, host: w.host });
  }
  const { data: chains, error: linkError } = await db.rpc('chain_record_and_link', {
    p_websites: websites,
    p_ids: rows.map((r) => r.restaurant_id),
  });
  if (linkError) throw new Error(`chain_record_and_link: ${linkError.message}`);
  return { candidates: rows.length, fetched: websites.length, chains: (chains ?? []) as string[] };
}

// ---------------------------------------------------------------------------
// A chain's other locations (migration 0106, feedback #5): "chain dishes should appear on the map in
// all chain locations". Once per place that has a dish, one Text Search for its name around it; the
// results with the same name key and website host become the chain's locations (the database checks
// both again, chain_add_locations). websiteUri makes this the Text Search Enterprise SKU.
// ---------------------------------------------------------------------------

/** One place Google returned, in the shape chain_add_locations stores. */
export type FoundPlace = {
  google_place_id: string;
  name: string;
  address: string;
  city: string;
  lat: number;
  lng: number;
  cuisine: string;
  host: string | null;
};

/** How far round the place to look: about 55 km each way, i.e. a whole city. */
export const LOCATIONS_RADIUS_DEG = 0.5;
/** At most this many pages of 20 (60 locations) for one search. */
export const LOCATIONS_MAX_PAGES = 3;

/** The box round a point, LOCATIONS_RADIUS_DEG of latitude each way (wider in longitude, by latitude). */
export function searchBox(lat: number, lng: number) {
  const dLat = LOCATIONS_RADIUS_DEG;
  const dLng = Math.min(LOCATIONS_RADIUS_DEG / Math.max(Math.cos((lat * Math.PI) / 180), 0.2), 2);
  return {
    low: { latitude: Math.max(lat - dLat, -90), longitude: Math.max(lng - dLng, -180) },
    high: { latitude: Math.min(lat + dLat, 90), longitude: Math.min(lng + dLng, 180) },
  };
}

/** One page of a Text Search for `name` inside the box round (lat, lng). */
export async function googleTextSearchPage(
  apiKey: string,
  name: string,
  lat: number,
  lng: number,
  pageToken: string | null,
  fetchFn: typeof fetch = fetch,
): Promise<{ ok: boolean; places: FoundPlace[]; next: string | null }> {
  const res = await fetchFn('https://places.googleapis.com/v1/places:searchText', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask':
        'places.id,places.displayName,places.formattedAddress,places.addressComponents,places.location,' +
        'places.primaryTypeDisplayName,places.websiteUri,nextPageToken',
    },
    body: JSON.stringify({
      textQuery: name,
      pageSize: 20,
      locationRestriction: { rectangle: searchBox(lat, lng) },
      languageCode: 'en',
      ...(pageToken ? { pageToken } : {}),
    }),
  });
  if (!res.ok) {
    console.error(`Google Places text search failed: HTTP ${res.status}`);
    await res.body?.cancel();
    return { ok: false, places: [], next: null };
  }
  // deno-lint-ignore no-explicit-any
  const data: any = await res.json().catch(() => ({}));
  // deno-lint-ignore no-explicit-any
  const places = ((data?.places ?? []) as any[])
    .filter((p) => p?.id && Number.isFinite(p?.location?.latitude) && Number.isFinite(p?.location?.longitude))
    .map((p) => ({
      google_place_id: String(p.id),
      name: String(p.displayName?.text ?? ''),
      address: String(p.formattedAddress ?? ''),
      city: localityFromAddress(p.formattedAddress, p.addressComponents),
      lat: Number(p.location.latitude),
      lng: Number(p.location.longitude),
      cuisine: String(p.primaryTypeDisplayName?.text ?? ''),
      host: websiteHost(p.websiteUri),
    }));
  return { ok: true, places, next: typeof data?.nextPageToken === 'string' && data.nextPageToken ? data.nextPageToken : null };
}

type Due = {
  restaurant_id: string;
  google_place_id: string;
  name: string;
  latitude: number;
  longitude: number;
  website_host: string | null;
  website_checked: boolean;
};
export type SearchPage = (
  name: string, lat: number, lng: number, pageToken: string | null,
) => Promise<{ ok: boolean; places: FoundPlace[]; next: string | null }>;

/**
 * For each of `ids` (or, when null, every place: the backfill) that has a dish and was never asked,
 * find its same-name, same-website places nearby and link them into its chain. A failed Google call
 * records nothing, so the place is asked again later. At most `maxSearches` places per call.
 */
export async function addChainLocations(
  db: ChainDb,
  ids: string[] | null,
  search: SearchPage,
  website: (placeId: string) => Promise<{ ok: boolean; host: string | null }>,
  { maxSearches = 3 }: { maxSearches?: number } = {},
): Promise<{ searched: number; chains: string[] }> {
  if (ids && ids.length === 0) return { searched: 0, chains: [] };
  const { data, error } = await db.rpc('chain_locations_due', { p_ids: ids, p_limit: maxSearches });
  if (error) throw new Error(`chain_locations_due: ${error.message}`);
  const chains: string[] = [];
  let searched = 0;

  for (const r of ((data ?? []) as Due[]).slice(0, maxSearches)) {
    const first = await search(r.name, r.latitude, r.longitude, null);
    if (!first.ok) continue;
    searched += 1;

    // The place's own website: known already, else from its own row in the results, else asked for.
    let host: string | null;
    const self = first.places.find((p) => p.google_place_id === r.google_place_id);
    if (r.website_checked) host = r.website_host;
    else if (self) host = self.host;
    else {
      const w = await website(r.google_place_id);
      if (!w.ok) continue;
      host = w.host;
    }

    const same = (p: FoundPlace) => host !== null && p.host === host && p.google_place_id !== r.google_place_id;
    const found = first.places.filter(same);
    // Another page only while this one still had locations on it.
    let next = found.length > 0 ? first.next : null;
    for (let page = 2; next && page <= LOCATIONS_MAX_PAGES; page++) {
      const more = await search(r.name, r.latitude, r.longitude, next);
      if (!more.ok) break;
      const hits = more.places.filter(same);
      found.push(...hits);
      next = hits.length > 0 ? more.next : null;
    }

    const { data: chain, error: addError } = await db.rpc('chain_add_locations', {
      p_restaurant_id: r.restaurant_id,
      p_host: host,
      p_places: found,
    });
    if (addError) throw new Error(`chain_add_locations: ${addError.message}`);
    if (typeof chain === 'string' && !chains.includes(chain)) chains.push(chain);
  }
  return { searched, chains };
}
