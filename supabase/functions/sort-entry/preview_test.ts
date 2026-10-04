// supabase/functions/sort-entry/preview_test.ts
//
//   deno test --no-check supabase/functions/sort-entry/
//   node --test supabase/functions/sort-entry/preview_test.ts
//
// EARLY SORT (round 3, 0039). The rules under test:
//   * a HIT returns the cached plan and makes NO model call and NO rate-limit hit;
//   * a MISS calls the model once; a preview stores what it returned, the real sort does not;
//   * the key is the same for the same (body, tag tokens in any order, place, model) and moves
//     when any of them moves;
//   * the spend guard is consulted only on a preview miss, and a refusal calls nothing;
//   * a broken cache degrades to a model call, never to a failed sort;
//   * 0056: a preview CLAIMS its key; a real sort that finds the claim pending WAITS for that plan
//     (no second, simultaneous model call) and calls the model itself only when the wait times out.

import { test, assert, assertEquals } from './harness.ts';
import {
  canonicalTagTokens,
  coerceCachedPlan,
  consumeCachedPlan,
  modelPlanWithCache,
  parsePreviewRequest,
  PENDING_WAIT_MS,
  PREVIEW_MAX_BODY,
  PREVIEW_RATE_LIMIT,
  PREVIEW_RATE_WINDOW_SECONDS,
  PREVIEW_TTL_SECONDS,
  previewCacheKey,
  sha256Hex,
  sortMeta,
  type CacheState,
  type PreviewCache,
} from './preview.ts';
import type { SortPlan } from './types.ts';

const PLAN: SortPlan = {
  place_query: null,
  place_offset: null,
  items: [{
    dish_name: 'Tiramisu', score: 4, score_evidence: 'Tiramisu 4.0', note: null,
    evidence_offset: null, mention_text: null, mention_offset: null,
  }],
};

const PENDING = Symbol('pending');
type Row = SortPlan | typeof PENDING;

/** The 0056 table's semantics in a Map: a PENDING row is a claim with no plan yet. */
function memoryCache(): PreviewCache & {
  rows: Map<string, Row>; puts: number; removes: number; releases: number; peeks: number;
} {
  const rows = new Map<string, Row>();
  const state = (r: Row | undefined): CacheState =>
    r === undefined ? { state: 'none' } : r === PENDING ? { state: 'pending' } : { state: 'hit', plan: r };
  const c = {
    rows,
    puts: 0,
    removes: 0,
    releases: 0,
    peeks: 0,
    async peek(a: string, k: string) {
      c.peeks++;
      return state(rows.get(`${a}|${k}`));
    },
    async claim(a: string, k: string) {
      const r = rows.get(`${a}|${k}`);
      if (r !== undefined) return state(r);
      rows.set(`${a}|${k}`, PENDING);
      return { state: 'claimed' } as CacheState;
    },
    async remove(a: string, k: string) {
      c.removes++;
      rows.delete(`${a}|${k}`);
    },
    async release(a: string, k: string) {
      c.releases++;
      if (rows.get(`${a}|${k}`) === PENDING) rows.delete(`${a}|${k}`);
    },
    async put(a: string, k: string, plan: SortPlan) {
      c.puts++;
      rows.set(`${a}|${k}`, plan);
    },
  };
  return c;
}

/** A virtual clock: sleeping advances time instantly, and `onSleep` lets a test land a plan mid-wait. */
function fakeClock(onSleep: (t: number) => void = () => {}) {
  let t = 0;
  return {
    now: () => t,
    sleep: async (ms: number) => { t += ms; onSleep(t); },
  };
}

function countingModel(plan: SortPlan | null = PLAN) {
  const m = { calls: 0, run: async () => { m.calls++; return plan; } };
  return m;
}

const KEY = { body: 'Tipo 00. Tiramisu 4.0 GF', tagTokens: [{ offset: 22, length: 2 }], restaurantId: 'a1b2c3d4-0000-4000-8000-000000000001', model: 'claude-haiku-4-5' };

test('the limits are the contract: 15 min TTL, 12 previews per 10 min', () => {
  assertEquals(PREVIEW_TTL_SECONDS, 900);
  assertEquals(PREVIEW_RATE_LIMIT, 12);
  assertEquals(PREVIEW_RATE_WINDOW_SECONDS, 600);
});

test('sha256Hex is sha256 (known vector)', async () => {
  assertEquals(await sha256Hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

test('key: stable for the same draft, tag order does not matter, 64 hex', async () => {
  const a = await previewCacheKey(KEY);
  const b = await previewCacheKey({ ...KEY, tagTokens: [{ offset: 22, length: 2 }, { offset: 22, length: 2 }] });
  assertEquals(a, b);
  assert(/^[0-9a-f]{64}$/.test(a), a);
  const two = [{ offset: 1, length: 2 }, { offset: 9, length: 3 }];
  assertEquals(await previewCacheKey({ ...KEY, tagTokens: two }), await previewCacheKey({ ...KEY, tagTokens: [...two].reverse() }));
  assertEquals(canonicalTagTokens([{ offset: 9, length: 3 }, { offset: 1, length: 2 }]), [[1, 2], [9, 3]]);
  // the place id is compared case-insensitively (Swift sends upper-case UUIDs unless lowered)
  assertEquals(await previewCacheKey({ ...KEY, restaurantId: KEY.restaurantId.toUpperCase() }), a);
});

test('key: moves when the words, a token, the place or the model moves', async () => {
  const base = await previewCacheKey(KEY);
  const variants = [
    { ...KEY, body: KEY.body + ' ' },
    { ...KEY, tagTokens: [] },
    { ...KEY, tagTokens: [{ offset: 22, length: 3 }] },
    { ...KEY, restaurantId: null },
    { ...KEY, restaurantId: 'a1b2c3d4-0000-4000-8000-000000000002' },
    { ...KEY, model: 'claude-sonnet-5' },
  ];
  for (const v of variants) assert((await previewCacheKey(v)) !== base, JSON.stringify(v));
});

test('MISS on a preview: one model call, the plan is stored, the guard is asked once', async () => {
  const cache = memoryCache();
  const model = countingModel();
  let admits = 0;
  const got = await modelPlanWithCache({
    cache, authorId: 'u1', key: 'k', model: 'm', store: true, run: model.run,
    admit: async () => { admits++; return true; },
  });
  assertEquals([got.plan, got.cacheHit, got.limited, got.waitedMs], [PLAN, false, false, 0]);
  assertEquals(model.calls, 1);
  assertEquals(admits, 1);
  assertEquals(cache.puts, 1);
});

test('HIT on the real sort after a preview: the cached plan, and NO second model call', async () => {
  const cache = memoryCache();
  const model = countingModel();
  await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: true, run: model.run, admit: async () => true });
  const real = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: false, run: model.run });
  assertEquals([real.plan, real.cacheHit, real.limited, real.modelMs], [PLAN, true, false, null]);
  assertEquals(model.calls, 1, 'the preview called the model; the real sort must not');
  assertEquals(sortMeta(true, real.cacheHit, 'm'), { cache_hit: true, model: 'm' });
});

test('a HIT on a repeat preview neither calls the model nor spends a rate-limit hit', async () => {
  const cache = memoryCache();
  cache.rows.set('u1|k', PLAN);
  const model = countingModel();
  let admits = 0;
  const got = await modelPlanWithCache({
    cache, authorId: 'u1', key: 'k', model: 'm', store: true, run: model.run,
    admit: async () => { admits++; return true; },
  });
  assertEquals(got.cacheHit, true);
  assertEquals([model.calls, admits, cache.puts], [0, 0, 0]);
});

test('the cache is per author: the same key under someone else is a MISS', async () => {
  const cache = memoryCache();
  cache.rows.set('u1|k', PLAN);
  const model = countingModel();
  const got = await modelPlanWithCache({ cache, authorId: 'u2', key: 'k', model: 'm', store: false, run: model.run });
  assertEquals([got.cacheHit, model.calls], [false, 1]);
});

test('MISS on the real sort: one model call, nothing stored', async () => {
  const cache = memoryCache();
  const model = countingModel();
  const got = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: false, run: model.run });
  assertEquals([got.cacheHit, model.calls, cache.puts], [false, 1, 0]);
  assertEquals(sortMeta(true, got.cacheHit, 'm'), { cache_hit: false, model: 'm' });
});

test('rate-limited preview: no model call, nothing stored, limited', async () => {
  const cache = memoryCache();
  const model = countingModel();
  const got = await modelPlanWithCache({
    cache, authorId: 'u1', key: 'k', model: 'm', store: true, run: model.run, admit: async () => false,
  });
  assertEquals([got.plan, got.cacheHit, got.limited], [null, false, true]);
  assertEquals([model.calls, cache.puts], [0, 0]);
  assertEquals(cache.rows.size, 0, 'the refused preview released its claim');
});

test('a failed model call is not cached (the stub runs; the next try asks the model again)', async () => {
  const cache = memoryCache();
  const model = countingModel(null);
  const got = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: true, run: model.run, admit: async () => true });
  assertEquals([got.plan, got.cacheHit, cache.puts], [null, false, 0]);
  assertEquals(cache.rows.size, 0, 'the failed preview released its claim: nobody waits on it');
  assertEquals(sortMeta(false, false, 'm'), { cache_hit: false, model: null });
});

test('a cache that throws degrades to a model call, never a failure', async () => {
  const down = async () => { throw new Error('db down'); };
  const broken: PreviewCache = { peek: down, claim: down, put: down, remove: down, release: down };
  const model = countingModel();
  const got = await modelPlanWithCache({ cache: broken, authorId: 'u1', key: 'k', model: 'm', store: true, run: model.run });
  assertEquals([got.plan === PLAN, got.cacheHit, model.calls], [true, false, 1]);
});

test('a cached row that is not plan-shaped is a MISS', () => {
  assertEquals(coerceCachedPlan(null), null);
  assertEquals(coerceCachedPlan({ items: 'x' }), null);
  assertEquals(coerceCachedPlan({ items: [{ score: 4 }] }), null);
  const round = coerceCachedPlan(JSON.parse(JSON.stringify(PLAN)));
  assertEquals(round, PLAN);
  // tags are never read back from a cache: tags.ts attaches them from the client's tokens only
  const tagged = coerceCachedPlan({ items: [{ dish_name: 'X', tags: ['gf'] }] });
  assertEquals(tagged?.items[0].tags, undefined);
});

test('preview request: the draft is required; a place is optional but must be a uuid', () => {
  assertEquals(parsePreviewRequest({}), { error: 'body (string) required for preview' });
  assertEquals(parsePreviewRequest({ body: '' }), { body: '', restaurantId: null });
  assertEquals(parsePreviewRequest({ body: 'x', restaurant_id: null }), { body: 'x', restaurantId: null });
  assertEquals(parsePreviewRequest({ body: 'x', restaurant_id: 'nope' }), { error: 'restaurant_id must be a uuid' });
  assertEquals(
    parsePreviewRequest({ body: 'x', restaurant_id: 'A1B2C3D4-0000-4000-8000-000000000001' }),
    { body: 'x', restaurantId: 'a1b2c3d4-0000-4000-8000-000000000001' },
  );
  assertEquals(parsePreviewRequest({ body: 'x'.repeat(PREVIEW_MAX_BODY + 1) }), { error: 'body too long for preview' });
});

test('CONSUME: after the real sort writes, the plan it reused is deleted — the next lookup is a MISS', async () => {
  const cache = memoryCache();
  const model = countingModel();
  await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: true, run: model.run, admit: async () => true });
  const real = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: false, run: model.run });
  assertEquals(await consumeCachedPlan({ cache, authorId: 'u1', key: 'k', cacheHit: real.cacheHit }), true);
  assertEquals([cache.rows.size, cache.removes], [0, 1], 'the consumed row (verbatim draft text) is gone');
  const again = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: false, run: model.run });
  assertEquals([again.cacheHit, model.calls], [false, 2]);
});

test('CONSUME is a no-op on a miss, without a key, and never throws', async () => {
  const cache = memoryCache();
  cache.rows.set('u1|k', PLAN);
  assertEquals(await consumeCachedPlan({ cache, authorId: 'u1', key: 'k', cacheHit: false }), false);
  assertEquals(await consumeCachedPlan({ cache, authorId: 'u1', key: null, cacheHit: true }), false);
  assertEquals(await consumeCachedPlan({ cache: null, authorId: 'u1', key: 'k', cacheHit: true }), false);
  assertEquals([cache.rows.size, cache.removes], [1, 0], 'a miss deletes nothing');
  const broken: PreviewCache = {
    peek: async () => ({ state: 'none' }),
    claim: async () => ({ state: 'claimed' }),
    put: async () => {},
    remove: async () => { throw new Error('db down'); },
    release: async () => {},
  };
  assertEquals(await consumeCachedPlan({ cache: broken, authorId: 'u1', key: 'k', cacheHit: true }), false);
});

// ---------------------------------------------------------------------------------------------------
// 0056 — a running preview is awaited, not duplicated
// ---------------------------------------------------------------------------------------------------
test('0056 HIT: the preview finished before Done — no wait, no model call', async () => {
  const cache = memoryCache();
  cache.rows.set('u1|k', PLAN);
  const model = countingModel();
  const got = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: false, run: model.run, clock: fakeClock() });
  assertEquals([got.plan, got.cacheHit, got.waitedMs, model.calls, cache.peeks], [PLAN, true, 0, 0, 1]);
});

test('0056 PENDING then HIT: the sort waits for the running preview and uses its plan — one model call in all', async () => {
  const cache = memoryCache();
  cache.rows.set('u1|k', PENDING); // a preview claimed the key and is calling the model
  const model = countingModel();
  const clock = fakeClock((t) => { if (t >= 900) cache.rows.set('u1|k', PLAN); }); // its plan lands at ~0.9 s
  const got = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: false, run: model.run, clock });
  assertEquals([got.plan, got.cacheHit, model.calls], [PLAN, true, 0]);
  assert(got.waitedMs >= 900 && got.waitedMs < PENDING_WAIT_MS, `waited ${got.waitedMs}`);
  assertEquals(sortMeta(true, got.cacheHit, 'm', got), { cache_hit: true, model: 'm', waited_ms: got.waitedMs });
});

test('0056 PENDING then TIMEOUT: past ~3 s the sort calls the model itself, once, and stores nothing', async () => {
  const cache = memoryCache();
  cache.rows.set('u1|k', PENDING); // the preview never finishes
  const model = countingModel();
  const got = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: false, run: model.run, clock: fakeClock() });
  assertEquals([got.plan, got.cacheHit, model.calls, cache.puts], [PLAN, false, 1, 0]);
  assertEquals(got.waitedMs, PENDING_WAIT_MS);
  assert(PENDING_WAIT_MS >= 2_500 && PENDING_WAIT_MS <= 3_500, 'the wait is ~3 s');
  assertEquals(cache.rows.get('u1|k'), PENDING, 'the real sort never touches the preview\'s claim');
});

test('0056 PENDING then RELEASED: the preview\'s model failed — stop waiting at once and call it here', async () => {
  const cache = memoryCache();
  cache.rows.set('u1|k', PENDING);
  const model = countingModel();
  const clock = fakeClock((t) => { if (t >= 300) cache.rows.delete('u1|k'); });
  const got = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: false, run: model.run, clock });
  assertEquals([got.cacheHit, model.calls], [false, 1]);
  assert(got.waitedMs < 1_000, `stopped waiting at ${got.waitedMs}`);
});

test('0056: a preview claims before it calls; a second identical preview waits instead of double-spending', async () => {
  const cache = memoryCache();
  let release!: () => void;
  const gate = new Promise<void>((r) => { release = r; });
  const slow = { calls: 0, run: async () => { slow.calls++; await gate; return PLAN; } };
  let admits = 0;
  const admit = async () => { admits++; return true; };
  const first = modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: true, run: slow.run, admit });
  await Promise.resolve();
  await Promise.resolve();
  assertEquals(cache.rows.get('u1|k'), PENDING, 'the key is claimed while the model runs');
  const clock = fakeClock((t) => { if (t >= 450) release(); });
  const second = modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: true, run: slow.run, admit, clock });
  const [a, b] = await Promise.all([first, second]);
  assertEquals([a.cacheHit, b.cacheHit, slow.calls, admits, cache.puts], [false, true, 1, 1, 1]);
});
