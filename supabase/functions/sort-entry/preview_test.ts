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
//   * a broken cache degrades to a model call, never to a failed sort.

import { test, assert, assertEquals } from './harness.ts';
import {
  canonicalTagTokens,
  coerceCachedPlan,
  consumeCachedPlan,
  modelPlanWithCache,
  parsePreviewRequest,
  PREVIEW_MAX_BODY,
  PREVIEW_RATE_LIMIT,
  PREVIEW_RATE_WINDOW_SECONDS,
  PREVIEW_TTL_SECONDS,
  previewCacheKey,
  sha256Hex,
  sortMeta,
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

function memoryCache(): PreviewCache & { rows: Map<string, SortPlan>; puts: number; removes: number } {
  const rows = new Map<string, SortPlan>();
  const c = {
    rows,
    puts: 0,
    removes: 0,
    async remove(a: string, k: string) {
      c.removes++;
      rows.delete(`${a}|${k}`);
    },
    async get(a: string, k: string) {
      return rows.get(`${a}|${k}`) ?? null;
    },
    async put(a: string, k: string, plan: SortPlan) {
      c.puts++;
      rows.set(`${a}|${k}`, plan);
    },
  };
  return c;
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
  assertEquals(got, { plan: PLAN, cacheHit: false, limited: false });
  assertEquals(model.calls, 1);
  assertEquals(admits, 1);
  assertEquals(cache.puts, 1);
});

test('HIT on the real sort after a preview: the cached plan, and NO second model call', async () => {
  const cache = memoryCache();
  const model = countingModel();
  await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: true, run: model.run, admit: async () => true });
  const real = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: false, run: model.run });
  assertEquals(real, { plan: PLAN, cacheHit: true, limited: false });
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
  assertEquals(got, { plan: null, cacheHit: false, limited: true });
  assertEquals([model.calls, cache.puts], [0, 0]);
});

test('a failed model call is not cached (the stub runs; the next try asks the model again)', async () => {
  const cache = memoryCache();
  const model = countingModel(null);
  const got = await modelPlanWithCache({ cache, authorId: 'u1', key: 'k', model: 'm', store: true, run: model.run, admit: async () => true });
  assertEquals([got.plan, got.cacheHit, cache.puts], [null, false, 0]);
  assertEquals(sortMeta(false, false, 'm'), { cache_hit: false, model: null });
});

test('a cache that throws degrades to a model call, never a failure', async () => {
  const broken: PreviewCache = {
    get: async () => { throw new Error('db down'); },
    put: async () => { throw new Error('db down'); },
    remove: async () => { throw new Error('db down'); },
  };
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
    get: async () => null,
    put: async () => {},
    remove: async () => { throw new Error('db down'); },
  };
  assertEquals(await consumeCachedPlan({ cache: broken, authorId: 'u1', key: 'k', cacheHit: true }), false);
});
