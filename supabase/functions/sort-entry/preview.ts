// supabase/functions/sort-entry/preview.ts
//
// EARLY SORT (round 3, migration 0039). While the user is still writing, the app may call
//
//   POST /functions/v1/sort-entry
//   { "preview": true, "body": "<the draft, exactly as it will be saved>",
//     "tag_tokens": [{ offset, length }], "restaurant_id": "<uuid>" }
//
// and get back the same plan shape a sort returns — WITHOUT writing entries or reviews. The
// point is spend and latency: the model's RAW plan is cached server-side under (author,
// sha256(body), tag_tokens, six_tokens, restaurant_id, model), and the real sort after Done reuses
// it when the key matches instead of calling the model a second time. (six_tokens joined the key in
// round 4: a plan the model made without knowing a six was marked is not the same plan.)
//
// THE CACHED PLAN HOLDS VERBATIM DRAFT TEXT — its notes and score evidence are slices of the
// words — so its life is short and ends in a DELETE, not just an expiry (migration 0039):
//   * it is reusable for 15 minutes (`expires_at`; reads ignore anything older);
//   * every preview call purges expired rows, everyone's, bounded (sort_preview_purge_expired);
//   * the real sort deletes the row it consumed once its write commits (consumeCachedPlan);
//   * deleting an entry or the account purges the author's rows (a trigger on entries + cascade).
//
// PENDING CLAIMS (0056). A preview claims its key (a row with plan = null) before it calls the model;
// a real sort that finds the claim still pending waits up to PENDING_WAIT_MS for that plan instead of
// calling the model at the same moment. A claim is released if the model fails or the spend guard
// refuses, and is stale (ignored, re-claimable) after PENDING_STALE_SECONDS if the preview died.
//
// What is cached is the model's output BEFORE any gate. Both paths then run the same
// validate.ts → tags.ts → apply_entry_sort chain on it, so a cached plan can never loosen a
// rule (no invented score, no paraphrased note, no inferred tag).
//
// Everything here is pure (no Deno, no network, no clock) except sha256, which uses the Web
// Crypto global both runtimes ship. index.ts wires it to the database.

import { cleanStyles } from './styles.ts';
import type { SortItem, SortPlan } from './types.ts';
import type { TagToken } from './tags.ts';
import type { SixToken } from './six.ts';

/** How long a preview plan stays reusable. Mirrors the table default in 0039. */
export const PREVIEW_TTL_SECONDS = 15 * 60;
/** Spend guard: at most this many previews that reach a sort, per author, per window. */
export const PREVIEW_RATE_LIMIT = 12;
export const PREVIEW_RATE_WINDOW_SECONDS = 10 * 60;
/** A draft longer than this (UTF-16 units) is refused rather than sent to the model. */
export const PREVIEW_MAX_BODY = 10_000;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Tag (or six) tokens in a form that does not depend on the order the client listed them in. */
export function canonicalTagTokens(tokens: readonly (TagToken | SixToken)[]): Array<[number, number]> {
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
  /** The client-marked sixes (0041). Absent/empty keeps the pre-round-4 key. */
  sixTokens?: readonly SixToken[];
  restaurantId: string | null;
  /** The model ID the plan came from: a plan from another model is not the same plan. */
  model: string;
};

/**
 * The cache key (the author is the other half of the table's PK). sha256 of the body, then of
 * the whole tuple, so the KEY carries no user text and has one fixed shape (64 hex). The row's
 * `plan` still does (see the header) — which is why rows are deleted, not left to expire.
 */
export async function previewCacheKey(k: PreviewKeyParts): Promise<string> {
  const bodyHash = await sha256Hex(k.body ?? '');
  const sixes = canonicalTagTokens(k.sixTokens ?? []);
  return sha256Hex(JSON.stringify([
    'ate-sort-preview/v1',
    bodyHash,
    canonicalTagTokens(k.tagTokens),
    (k.restaurantId ?? '').toLowerCase() || null,
    k.model,
    // appended only when marked, so a draft with no six keeps the key it had before round 4
    ...(sixes.length ? [['six', sixes]] : []),
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
      // 0053: the model's style words ride the cached plan; re-cleaned like any model output.
      ...(cleanStyles(i.styles).length ? { styles: cleanStyles(i.styles) } : {}),
    });
  }
  return { place_query: str(p.place_query), place_offset: int(p.place_offset), items };
}

/**
 * What the cache holds for one (author, key) — 0056:
 *   hit      a plan is ready;
 *   pending  a preview has claimed the key and is calling the model right now;
 *   claimed  (claim only) nothing usable was there, so THIS caller now owns the key and must store
 *            a plan or release the claim;
 *   none     nothing usable (and, from claim, it could not be claimed: run unclaimed).
 */
export type CacheState =
  | { state: 'hit'; plan: SortPlan }
  | { state: 'pending' }
  | { state: 'claimed' }
  | { state: 'none' };

/** The storage behind the cache — the 0039/0056 table in production, a Map in tests. */
export type PreviewCache = {
  /** Read only (the real sort): hit | pending | none. */
  peek(authorId: string, key: string): Promise<CacheState>;
  /** A preview about to call the model: hit | pending | claimed (atomic — sort_preview_claim). */
  claim(authorId: string, key: string, model: string): Promise<CacheState>;
  put(authorId: string, key: string, plan: SortPlan, model: string): Promise<void>;
  remove(authorId: string, key: string): Promise<void>;
  /** Drop this caller's PENDING claim (model failed, or the spend guard refused). Never a stored plan. */
  release(authorId: string, key: string): Promise<void>;
};

/** How long a sort waits for a preview that is already calling the model (0056). */
export const PENDING_WAIT_MS = 3_000;
export const PENDING_POLL_MS = 150;
/** A claim older than this is a preview that died; nobody waits on it. > the model timeout. */
export const PENDING_STALE_SECONDS = 15;

export type CachedPlan = {
  /** The model's raw plan, or null (no key, model failure, or rate-limited) → the stub runs. */
  plan: SortPlan | null;
  /** The plan came out of the cache: THIS request made no model call. */
  cacheHit: boolean;
  /** A preview was refused by the spend guard (only ever true when `admit` was given). */
  limited: boolean;
  /** How long this request waited on another request's pending model call (0 when it did not). */
  waitedMs: number;
  /** How long this request's own model call took (null when it made none). */
  modelMs: number | null;
};

type Clock = { now: () => number; sleep: (ms: number) => Promise<void> };
const realClock: Clock = {
  now: () => Date.now(),
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
};

/** Poll a pending key until its plan lands, the claim vanishes, or the budget runs out. */
async function waitForPlan(
  cache: PreviewCache, authorId: string, key: string, budgetMs: number, pollMs: number, clock: Clock,
): Promise<SortPlan | null> {
  const deadline = clock.now() + budgetMs;
  while (clock.now() < deadline) {
    await clock.sleep(Math.min(pollMs, Math.max(0, deadline - clock.now())));
    let s: CacheState;
    try {
      s = await cache.peek(authorId, key);
    } catch {
      return null;
    }
    if (s.state === 'hit') return s.plan;
    if (s.state !== 'pending') return null; // released (its model failed) or gone: stop waiting
  }
  return null;
}

/**
 * The one decision both paths share:
 *   hit      → the cached plan, no model call, no rate-limit hit;
 *   pending  → another request (a preview) is calling the model for exactly this key: WAIT for its
 *              plan (≤ waitMs) and use it — no second, simultaneous call. On timeout, call it here;
 *   miss     → (preview) claim the key, ask `admit`, run the model, store it (or release the claim);
 *              (real sort) run the model, store nothing.
 * A cache that throws is treated as a miss / a no-op store — it can slow a sort, never fail one.
 */
export async function modelPlanWithCache(opts: {
  cache: PreviewCache | null;
  authorId: string;
  key: string;
  model: string;
  run: () => Promise<SortPlan | null>;
  /** Preview: claim the key and store what the model returns. The real sort reads only. */
  store: boolean;
  /** Preview: the rate limit, consulted only when the model is about to be called. */
  admit?: () => Promise<boolean>;
  waitMs?: number;
  pollMs?: number;
  clock?: Clock;
}): Promise<CachedPlan> {
  const clock = opts.clock ?? realClock;
  let state: CacheState = { state: 'none' };
  if (opts.cache) {
    try {
      state = opts.store
        ? await opts.cache.claim(opts.authorId, opts.key, opts.model)
        : await opts.cache.peek(opts.authorId, opts.key);
    } catch {
      state = { state: 'none' };
    }
  }
  if (state.state === 'hit') return { plan: state.plan, cacheHit: true, limited: false, waitedMs: 0, modelMs: null };

  let waitedMs = 0;
  if (state.state === 'pending' && opts.cache) {
    const t0 = clock.now();
    const plan = await waitForPlan(
      opts.cache, opts.authorId, opts.key, opts.waitMs ?? PENDING_WAIT_MS, opts.pollMs ?? PENDING_POLL_MS, clock,
    );
    waitedMs = clock.now() - t0;
    if (plan) return { plan, cacheHit: true, limited: false, waitedMs, modelMs: null };
  }

  const owns = state.state === 'claimed';
  const release = async () => {
    if (!owns || !opts.cache) return;
    try {
      await opts.cache.release(opts.authorId, opts.key);
    } catch { /* a stale claim stops blocking anyone after PENDING_STALE_SECONDS */ }
  };
  if (opts.admit && !(await opts.admit())) {
    await release();
    return { plan: null, cacheHit: false, limited: true, waitedMs, modelMs: null };
  }

  const t1 = clock.now();
  const plan = await opts.run();
  const modelMs = clock.now() - t1;
  if (plan && opts.store && opts.cache) {
    try {
      await opts.cache.put(opts.authorId, opts.key, plan, opts.model);
    } catch {
      await release(); // an unstored preview only costs the real sort a model call
    }
  } else {
    await release();
  }
  return { plan, cacheHit: false, limited: false, waitedMs, modelMs };
}

/** What `entries.sort_meta` records for a sort (0039; timings 0056, present only when measured). */
export function sortMeta(
  usedModel: boolean,
  cacheHit: boolean,
  model: string | null,
  timings?: { waitedMs?: number; modelMs?: number | null; planMs?: number },
) {
  const meta: Record<string, unknown> = { cache_hit: usedModel && cacheHit, model: usedModel ? model : null };
  if (timings?.waitedMs) meta.waited_ms = Math.round(timings.waitedMs);
  if (typeof timings?.modelMs === 'number') meta.model_ms = Math.round(timings.modelMs);
  if (typeof timings?.planMs === 'number') meta.plan_ms = Math.round(timings.planMs);
  return meta;
}

/**
 * After the real sort's write COMMITS: a plan that came from the cache has served its one purpose,
 * so its row (verbatim draft text) is deleted. A miss had no row to delete; a failed write keeps it
 * so the retry can still reuse it. Never throws — the sort already succeeded.
 */
export async function consumeCachedPlan(opts: {
  cache: PreviewCache | null;
  authorId: string;
  key: string | null;
  cacheHit: boolean;
}): Promise<boolean> {
  if (!opts.cache || !opts.cacheHit || !opts.key) return false;
  try {
    await opts.cache.remove(opts.authorId, opts.key);
    return true;
  } catch {
    return false;
  }
}
