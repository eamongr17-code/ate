// supabase/functions/read-share/index.ts
//
// Ate — SHARE TO ATE. Someone shares a TikTok / Instagram / web link into Ate; this reads it and
// SUGGESTS a dish and a place to prefill the share card (design/rebuild/share-to-ate.html). It
// NEVER writes a save: the app calls add_own_save (0061) only after the user confirms the card.
//
//   POST /functions/v1/read-share          (user JWT required — the anon key alone is a 401)
//   body: { url: string, text?: string }   (text = whatever the share sheet passed: often the
//                                           caption, often just the link again, may be empty)
//   → 200 { ok: true,
//           source: 'tiktok' | 'instagram' | 'link',    (= own_saves.source)
//           url: string,                                (canonical https — store as source_url)
//           author: string | null,                      (≤ 100 — source_author)
//           caption: string | null,                     (≤ 2200 — source_caption)
//           thumbnail_url: string | null,               (https)
//           dish: string | null,                        (≤ 120, singular, title case)
//           place_query: string | null,                 (the venue as the words name it)
//           place: { restaurant_id: uuid | null, google_place_id: string | null,
//                    name: string, locality: string | null } | null }
//     401 unauthorized · 405 not POST · 422 bad url (unparseable, not https, > 2048)
//     429 rate limited ({ error, retry_after } — 30 reads per 10 min per user)
//
// WHAT IT READS
//   tiktok    short links (vm./vt.tiktok.com, tiktok.com/t/…) are resolved by following redirects
//             (TikTok hosts only), then TikTok's public oEmbed gives caption (title), author_name
//             and thumbnail_url. No key, no cost. oEmbed down → the shared text is the caption.
//   instagram no keyless oEmbed (needs an approved Meta app) → only the shared text, minus links.
//   link      the page's og:title / og:description / og:image — https only, 3 s, 256 KB, ≤ 3
//             redirects, SSRF-guarded (no localhost, private, link-local or metadata addresses,
//             checked on every hop and after DNS). Any failure → just the shared text.
//   Every outbound fetch has a timeout and a size cap (./fetch.ts). None of them can fail the read.
//
// DISH + PLACE ARE NEVER INVENTED. The caption goes to Claude through a forced tool call, the
// sorter's pattern and constants (./model.ts ← ../sort-entry/model.ts: ANTHROPIC_API_KEY,
// ATE_SHARE_MODEL defaulting to claude-haiku-5-5, 5 s). The server keeps a dish or a place_query
// only if its words are in the caption/text. Without the key there is NO model call: dish and
// place_query are null and the oEmbed fields still come back.
//
// THE PLACE IS NEVER ASSUMED (rule 8). place_query becomes `place` only when unambiguous
// (./place.ts): exactly one STRONG row we already hold (search_local_restaurants, as sort-entry
// does) → restaurant_id; else exactly one Google prediction from places-search op=autocomplete
// (called AS THE USER, so its VIC fence, food/bev types, stub mode and rate limit all apply
// unchanged — no second copy of the fence) → google_place_id, and the app resolves it through its
// existing pick path (op=details → a restaurants row). Several candidates or none → place null.
//
// RATE LIMIT (./limit.ts): 30 / 10 min per user in the isolate, plus one places_rate_hit (0013) at
// places-search's own 60 s / 90 policy as the cross-isolate ceiling (fails open, as there).
//
// Secrets: ANTHROPIC_API_KEY (optional; absent → no suggestion), ATE_SHARE_MODEL (optional),
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY (auto-injected). Google is reached
// only through places-search, so GOOGLE_PLACES_API_KEY stays that function's secret.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { canonicalTikTokVideo, classifyUrl, isTikTokHost, textWithoutUrls, type ClassifiedUrl } from './url.ts';
import { parseOpenGraph, readCapped, safeFetch, type Resolver } from './fetch.ts';
import { EMPTY_META, MAX_AUTHOR, MAX_CAPTION, parseTikTokOEmbed, tiktokOEmbedUrl, type PostMeta } from './oembed.ts';
import { modelInput, resolveShareModel, suggestFromCaption } from './model.ts';
import { decideGoogle, decideLocal, type LocalRow, type PredictionRow, type SharePlace } from './place.ts';
import { READ_SHARE_WINDOW_S, WindowLimiter } from './limit.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const MODEL_ID = resolveShareModel(Deno.env.get('ATE_SHARE_MODEL'));

/** places-search's own policy (0013): sharing its window keeps its self-pruning intact. */
const PLACES_RATE_WINDOW_S = 60;
const PLACES_RATE_MAX = 90;

const SHORT_LINK_TIMEOUT_MS = 2_500;
const OEMBED_TIMEOUT_MS = 3_000;
const OEMBED_MAX_BYTES = 64 * 1024;
const PAGE_TIMEOUT_MS = 3_000;
const PAGE_MAX_BYTES = 256 * 1024;
const PLACES_TIMEOUT_MS = 3_000;
const PLACES_MAX_BYTES = 64 * 1024;
const MAX_TEXT = 5_000;

const limiter = new WindowLimiter();

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

function adminClient() {
  return createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });
}

/** AUTH GATE (same shape as places-search / sort-entry): a token that resolves to a real USER. */
function bearer(req: Request): string {
  return (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
}

async function authedUserId(token: string): Promise<string | null> {
  if (!token) return null;
  try {
    const authClient = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
    const { data, error } = await authClient.auth.getUser(token);
    if (error || !data?.user?.id) return null;
    return data.user.id;
  } catch {
    return null;
  }
}

/** The cross-isolate ceiling. Fails OPEN on infra error, exactly as places-search does. */
async function placesBudgetAllows(admin: ReturnType<typeof adminClient>, userId: string): Promise<boolean> {
  try {
    const { data, error } = await admin.rpc('places_rate_hit', {
      p_user_id: userId,
      p_window_seconds: PLACES_RATE_WINDOW_S,
      p_limit: PLACES_RATE_MAX,
    });
    if (error) {
      console.error('read-share: places_rate_hit failed (failing open):', error.message);
      return true;
    }
    return data !== false;
  } catch (e) {
    console.error('read-share: places_rate_hit threw (failing open):', e instanceof Error ? e.message : String(e));
    return true;
  }
}

// Deno.resolveDns where the runtime has it; without it the literal host/IP checks still apply.
// deno-lint-ignore no-explicit-any
const resolveDns = (Deno as any).resolveDns as ((h: string, t: 'A' | 'AAAA') => Promise<string[]>) | undefined;
const resolver: Resolver | undefined = resolveDns
  ? async (host) => {
    const [a, aaaa] = await Promise.allSettled([resolveDns(host, 'A'), resolveDns(host, 'AAAA')]);
    const out = [
      ...(a.status === 'fulfilled' ? a.value : []),
      ...(aaaa.status === 'fulfilled' ? aaaa.value : []),
    ];
    if (!out.length) throw new Error('unresolvable');
    return out;
  }
  : undefined;

// ---------------------------------------------------------------------------
// Reading the post.
// ---------------------------------------------------------------------------

type Read = { url: string; meta: PostMeta; modelText: string | null };

async function readTikTok(c: ClassifiedUrl, sharedText: string | null): Promise<Read> {
  let url = c.url;
  if (c.short) {
    const hop = await safeFetch(url, {
      timeoutMs: SHORT_LINK_TIMEOUT_MS,
      maxBytes: 0,
      maxHops: 5,
      allowHost: isTikTokHost,
      bodyless: true,
    });
    const resolved = hop ? canonicalTikTokVideo(hop.url) : null;
    if (resolved) url = resolved;
  }
  const res = await safeFetch(tiktokOEmbedUrl(url), {
    timeoutMs: OEMBED_TIMEOUT_MS,
    maxBytes: OEMBED_MAX_BYTES,
    maxHops: 1,
    allowHost: (h) => h === 'www.tiktok.com',
    accept: 'application/json',
  });
  const meta = res && res.status === 200 && res.body ? parseTikTokOEmbed(res.body) : EMPTY_META;
  const caption = meta.caption ?? sharedText;
  return { url, meta: { ...meta, caption }, modelText: caption };
}

async function readLink(c: ClassifiedUrl, sharedText: string | null): Promise<Read> {
  // No DNS check in this runtime → no fetch of an arbitrary host at all (fail closed): the shared
  // text is all there is. TikTok's fixed hosts are unaffected.
  if (!resolver) {
    console.warn('read-share: no Deno.resolveDns; generic links read the shared text only');
    return { url: c.url, meta: { ...EMPTY_META, caption: sharedText }, modelText: sharedText };
  }
  const res = await safeFetch(c.url, {
    timeoutMs: PAGE_TIMEOUT_MS,
    maxBytes: PAGE_MAX_BYTES,
    maxHops: 3,
    resolver,
    accept: 'text/html,application/xhtml+xml',
    truncate: true,
  });
  if (!res || res.status !== 200 || !res.body || !/html/.test(res.contentType)) {
    return { url: c.url, meta: { ...EMPTY_META, caption: sharedText }, modelText: sharedText };
  }
  const og = parseOpenGraph(res.body);
  const pageWords = [og.title, og.description].filter(Boolean).join('\n') || null;
  return {
    url: c.url,
    meta: { author: null, caption: og.description ?? og.title ?? sharedText, thumbnail_url: og.image },
    modelText: pageWords,
  };
}

async function readPost(c: ClassifiedUrl, sharedText: string | null): Promise<Read> {
  if (c.source === 'tiktok') return await readTikTok(c, sharedText);
  if (c.source === 'link') return await readLink(c, sharedText);
  return { url: c.url, meta: { author: c.author, caption: sharedText, thumbnail_url: null }, modelText: sharedText };
}

// ---------------------------------------------------------------------------
// Resolving the place.
// ---------------------------------------------------------------------------

async function googlePredictions(token: string, query: string): Promise<PredictionRow[]> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PLACES_TIMEOUT_MS);
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/places-search?op=autocomplete`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, apikey: ANON_KEY },
      body: JSON.stringify({ input: query }),
      signal: controller.signal,
    });
    if (!res.ok) {
      await res.body?.cancel().catch(() => {});
      console.error(`read-share: places-search answered ${res.status}`);
      return [];
    }
    const body = await readCapped(res, PLACES_MAX_BYTES, false);
    const parsed = body ? JSON.parse(body) : null;
    return Array.isArray(parsed?.predictions) ? parsed.predictions as PredictionRow[] : [];
  } catch (e) {
    console.error('read-share: places-search failed:', e instanceof Error ? e.message : String(e));
    return [];
  } finally {
    clearTimeout(timer);
  }
}

async function resolvePlace(admin: ReturnType<typeof adminClient>, token: string, query: string): Promise<SharePlace | null> {
  let local: LocalRow[] = [];
  try {
    const { data, error } = await admin.rpc('search_local_restaurants', { p_query: query, p_limit: 5 });
    if (error) console.error('read-share: local place search failed:', error.message);
    else local = (data ?? []) as LocalRow[];
  } catch (e) {
    console.error('read-share: local place search threw:', e instanceof Error ? e.message : String(e));
  }
  const decided = decideLocal(query, local);
  if (decided.kind === 'match') return decided.place;
  if (decided.kind === 'ambiguous') return null;
  return decideGoogle(query, await googlePredictions(token, query));
}

// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const token = bearer(req);
  const userId = await authedUserId(token);
  if (!userId) return json({ error: 'unauthorized' }, 401);

  const body = await req.json().then((b) => (b && typeof b === 'object' ? b : {})).catch(() => ({}));
  const classified = classifyUrl((body as { url?: unknown }).url);
  if (!classified) return json({ error: 'bad url' }, 422);
  const rawText = (body as { text?: unknown }).text;
  const sharedText = textWithoutUrls(typeof rawText === 'string' ? rawText.slice(0, MAX_TEXT) : null, MAX_CAPTION);

  const admin = adminClient();
  if (!limiter.hit(userId) || !(await placesBudgetAllows(admin, userId))) {
    return json({ error: 'rate limited', retry_after: READ_SHARE_WINDOW_S }, 429);
  }

  const startedAt = Date.now();
  const read = await readPost(classified, sharedText);
  const suggestion = await suggestFromCaption({
    apiKey: ANTHROPIC_KEY,
    input: modelInput(read.modelText, sharedText),
    model: MODEL_ID,
  });
  const place = suggestion.place_query ? await resolvePlace(admin, token, suggestion.place_query) : null;

  console.log(JSON.stringify({
    fn: 'read-share',
    source: classified.source,
    has_caption: Boolean(read.meta.caption),
    dish: Boolean(suggestion.dish),
    place_query: Boolean(suggestion.place_query),
    place: place ? (place.restaurant_id ? 'local' : 'google') : null,
    ms: Date.now() - startedAt,
  }));

  return json({
    ok: true,
    source: classified.source,
    url: read.url,
    author: read.meta.author ? read.meta.author.slice(0, MAX_AUTHOR) : null,
    caption: read.meta.caption ? read.meta.caption.slice(0, MAX_CAPTION) : null,
    thumbnail_url: read.meta.thumbnail_url,
    dish: suggestion.dish,
    place_query: suggestion.place_query,
    place,
  });
});
