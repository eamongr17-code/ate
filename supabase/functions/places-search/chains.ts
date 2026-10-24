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
