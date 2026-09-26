// supabase/functions/sort-entry/preview.ts
//
// EARLY SORT (round 3, migration 0039). While the user is still writing, the app may call
//
//   POST /functions/v1/sort-entry
//   { "preview": true, "body": "<the draft, exactly as it will be saved>",
//     "tag_tokens": [{ offset, length }], "restaurant_id": "<uuid>" }
//
// and get back the same plan shape a sort returns — WITHOUT writing entries or reviews. The
// point is spend and latency: the model's RAW plan is cached server-side for 15 minutes under
// (author, sha256(body), tag_tokens, restaurant_id, model), and the real sort after Done reuses
// it when the key matches instead of calling the model a second time.
//
// What is cached is the model's output BEFORE any gate. Both paths then run the same
// validate.ts → tags.ts → apply_entry_sort chain on it, so a cached plan can never loosen a
// rule (no invented score, no paraphrased note, no inferred tag).
//
// Everything here is pure (no Deno, no network, no clock) except sha256, which uses the Web
// Crypto global both runtimes ship. index.ts wires it to the database.

import type { SortItem, SortPlan } from './types.ts';
import type { TagToken } from './tags.ts';

/** How long a preview plan stays reusable. Mirrors the table default in 0039. */
export const PREVIEW_TTL_SECONDS = 15 * 60;
/** Spend guard: at most this many previews that reach a sort, per author, per window. */
export const PREVIEW_RATE_LIMIT = 12;
export const PREVIEW_RATE_WINDOW_SECONDS = 10 * 60;
/** A draft longer than this (UTF-16 units) is refused rather than sent to the model. */
export const PREVIEW_MAX_BODY = 10_000;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Tag tokens in a form that does not depend on the order the client listed them in. */
export function canonicalTagTokens(tokens: readonly TagToken[]): Array<[number, number]> {
  const seen = new Set<string>();
  const out: Array<[number, number]> = [];
  for (const t of tokens) {
    const k = `${t.offset}:${t.length}`;
    if (seen.has(k)) continue;
    seen.add(k);
    out.push([t.offset, t.length]);
  }
  return out.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
}

export async function sha256Hex(text: string): Promise<string> {
  const bytes = new TextEncoder().encode(text);
  const digest = await globalThis.crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export type PreviewKeyParts = {
  body: string;
  tagTokens: readonly TagToken[];
  restaurantId: string | null;
  /** The model ID the plan came from: a plan from another model is not the same plan. */
  model: string;
};

/**
 * The cache key (the author is the other half of the table's PK). sha256 of the body, then of
 * the whole tuple, so the row holds no user text and the key has one fixed shape (64 hex).
 */
export async function previewCacheKey(k: PreviewKeyParts): Promise<string> {
  const bodyHash = await sha256Hex(k.body ?? '');
  return sha256Hex(JSON.stringify([
    'ate-sort-preview/v1',
    bodyHash,
    canonicalTagTokens(k.tagTokens),
    (k.restaurantId ?? '').toLowerCase() || null,
    k.model,
  ]));
}

export type PreviewRequest = {
  body: string;
  restaurantId: string | null;
};

/** Read the preview-only fields off a request. Returns an error string for a 422. */
export function parsePreviewRequest(raw: unknown): PreviewRequest | { error: string } {
  const r = (raw ?? {}) as { body?: unknown; restaurant_id?: unknown };
  if (typeof r.body !== 'string') return { error: 'body (string) required for preview' };
  if (r.body.length > PREVIEW_MAX_BODY) return { error: 'body too long for preview' };
  const rid = r.restaurant_id;
  if (rid === undefined || rid === null || rid === '') return { body: r.body, restaurantId: null };
  if (typeof rid !== 'string' || !UUID_RE.test(rid)) return { error: 'restaurant_id must be a uuid' };
  return { body: r.body, restaurantId: rid.toLowerCase() };
}

/**
 * A plan read back from the cache table. Anything that is not plan-shaped is a MISS (the model
 * runs again), never an error: the cache is an optimisation, not a source of truth.
 */
export function coerceCachedPlan(raw: unknown): SortPlan | null {
  const p = raw as { place_query?: unknown; place_offset?: unknown; items?: unknown } | null;
  if (!p || typeof p !== 'object' || !Array.isArray(p.items)) return null;
  const str = (v: unknown) => (typeof v === 'string' ? v : null);
  const int = (v: unknown) => (typeof v === 'number' && Number.isInteger(v) && v >= 0 ? v : null);
  const items: SortItem[] = [];
  for (const it of p.items) {
    const i = (it ?? {}) as Record<string, unknown>;
    if (typeof i.dish_name !== 'string') return null;
    items.push({
      dish_name: i.dish_name,
      score: typeof i.score === 'number' ? i.score : null,
      score_evidence: str(i.score_evidence),
      note: str(i.note),
      evidence_offset: int(i.evidence_offset),
      mention_text: str(i.mention_text),
      mention_offset: int(i.mention_offset),
    });
  }
  return { place_query: str(p.place_query), place_offset: int(p.place_offset), items };
}

/** The storage behind the cache — the 0039 table in production, a Map in tests. */
export type PreviewCache = {
  get(authorId: string, key: string): Promise<SortPlan | null>;
  put(authorId: string, key: string, plan: SortPlan, model: string): Promise<void>;
};

export type CachedPlan = {
  /** The model's raw plan, or null (no key, model failure, or rate-limited) → the stub runs. */
  plan: SortPlan | null;
  /** The plan came out of the cache: no model call was made. */
  cacheHit: boolean;
  /** A preview was refused by the spend guard (only ever true when `admit` was given). */
  limited: boolean;
};

/**
 * The one decision both paths share:
 *   hit   → the cached plan, no model call, no rate-limit hit;
 *   miss  → (preview only) ask `admit`, and stop if refused; run the model; (preview only) store it.
 * A cache that throws is treated as a miss / a no-op store — it can slow a sort, never fail one.
 */
export async function modelPlanWithCache(opts: {
  cache: PreviewCache | null;
  authorId: string;
  key: string;
  model: string;
  run: () => Promise<SortPlan | null>;
  /** Preview: store what the model returns. The real sort reads only. */
  store: boolean;
  /** Preview: the rate limit, consulted only when the model is about to be called. */
  admit?: () => Promise<boolean>;
}): Promise<CachedPlan> {
  if (opts.cache) {
    let cached: SortPlan | null = null;
    try {
      cached = await opts.cache.get(opts.authorId, opts.key);
    } catch {
      cached = null;
    }
    if (cached) return { plan: cached, cacheHit: true, limited: false };
  }
  if (opts.admit && !(await opts.admit())) return { plan: null, cacheHit: false, limited: true };

  const plan = await opts.run();
  if (plan && opts.store && opts.cache) {
    try {
      await opts.cache.put(opts.authorId, opts.key, plan, opts.model);
    } catch { /* an unstored preview only costs the real sort a model call */ }
  }
  return { plan, cacheHit: false, limited: false };
}

/** What `entries.sort_meta` records for a sort (0039). */
export function sortMeta(usedModel: boolean, cacheHit: boolean, model: string | null) {
  return { cache_hit: usedModel && cacheHit, model: usedModel ? model : null };
}
