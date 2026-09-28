// supabase/functions/sort-entry/entry_flow_test.ts
//
//   node --test supabase/functions/sort-entry/entry_flow_test.ts        (Node only — see below)
//
// The HTTP handler itself (index.ts), end to end, with the database and the model mocked:
//   * a real sort hands the client's `tag_tokens` and `six_tokens` through to ONE apply_entry_sort
//     call — the marked GF lands on its dish, the marked 6 is a score — in stub AND model mode;
//   * a `preview: true` request writes NOTHING: no apply_entry_sort, no entries/reviews write, no
//     mark_entry_sort_failed. In model mode its only write is the preview cache row, and a repeat of
//     the same draft is served from that cache without a second model call.
//
// How: index.ts is Deno code (Deno.env, Deno.serve, `npm:` imports). A module-resolution hook maps
// `npm:@supabase/supabase-js@2` to a recording fake, a stand-in `Deno` captures the handler, and
// `fetch` answers the Anthropic call with a canned tool_use. Each mode is a fresh module instance
// (`index.ts?mode=…`) because index.ts reads its env at load. Under `deno test` this file registers
// nothing: the hook is Node's.

import { test, assert, assertEquals } from './harness.ts';

// deno-lint-ignore no-explicit-any
const G = globalThis as any;
const isDeno = Boolean(G.Deno?.test);

const USER = '00000000-0000-4000-8000-00000000000a';
const PLACE = '00000000-0000-4000-8000-0000000000f1';
const ENTRY = '00000000-0000-4000-8000-000000000001';
const BODY = 'Pasta 4.5 GF and the tiramisu 6, loved it';

/** Where a word sits in BODY, as the composer sends it: Unicode-scalar offsets. */
function mark(text: string) {
  const at = BODY.indexOf(text);
  return { offset: [...BODY.slice(0, at)].length, length: [...text].length };
}

type Call = { kind: string; table?: string; name?: string; args?: unknown };

/** The fake Supabase: records every rpc and every write, answers reads from a tiny fixture. */
function fakeWorld() {
  const calls: Call[] = [];
  const cache = new Map<string, unknown>();
  const entry = {
    id: ENTRY, author_id: USER, body: BODY, restaurant_id: PLACE, restaurant_source: 'user',
    sort_status: 'pending', sort_plan: null,
  };
  const reads: Record<string, () => unknown> = {
    entries: () => entry,
    dishes: () => [{ name: 'Pasta' }, { name: 'Tiramisu' }],
    restaurants: () => ({ name: 'Tipo 00' }),
    reviews: () => [],
  };
  const rpcs: Record<string, (a: Record<string, unknown>) => unknown> = {
    search_local_restaurants: () => [],
    sort_preview_rate_hit: () => true,
    sort_preview_purge_expired: () => 0,
    apply_entry_sort: (a) => [{ sort_status: 'sorted', restaurant_id: a.p_restaurant_id }],
    mark_entry_sort_failed: () => null,
  };

  function builder(table: string) {
    const filters: Record<string, unknown> = {};
    let op = 'select';
    let single = false;
    const done = () => {
      if (op !== 'select') return { data: null, error: null };
      if (table === 'sort_preview_cache') {
        const hit = cache.get(`${filters.author_id}|${filters.cache_key}`);
        return { data: hit ? { plan: hit } : null, error: null };
      }
      const data = reads[table]?.() ?? (single ? null : []);
      return { data, error: null };
    };
    const b = {
      select: () => b,
      eq: (col: string, v: unknown) => { filters[col] = v; return b; },
      is: () => b, gt: () => b, limit: () => b, order: () => b,
      maybeSingle: () => { single = true; return b; },
      upsert: (row: Record<string, unknown>) => {
        op = 'upsert';
        calls.push({ kind: 'write', table, name: 'upsert', args: row });
        if (table === 'sort_preview_cache') cache.set(`${row.author_id}|${row.cache_key}`, row.plan);
        return b;
      },
      insert: (row: unknown) => { op = 'insert'; calls.push({ kind: 'write', table, name: 'insert', args: row }); return b; },
      update: (row: unknown) => { op = 'update'; calls.push({ kind: 'write', table, name: 'update', args: row }); return b; },
      delete: () => { op = 'delete'; calls.push({ kind: 'write', table, name: 'delete' }); return b; },
      then: (ok: (v: unknown) => unknown, bad?: (e: unknown) => unknown) => Promise.resolve(done()).then(ok, bad),
    };
    return b;
  }

  const client = {
    auth: { getUser: async (token: string) => ({ data: { user: token ? { id: USER } : null }, error: null }) },
    rpc: async (name: string, args: Record<string, unknown>) => {
      calls.push({ kind: 'rpc', name, args });
      return { data: rpcs[name] ? rpcs[name](args ?? {}) : null, error: null };
    },
    from: (table: string) => builder(table),
  };
  return { calls, client };
}

/** A canned Anthropic reply: the plan a model would return for BODY (it says 6; it is marked). */
function modelReply() {
  return {
    content: [{
      type: 'tool_use', name: 'sort_entry',
      input: {
        place_query: null,
        items: [
          { dish_name: 'Pasta', score: 4.5, score_evidence: 'Pasta 4.5', note: null, styles: ['Pasta', ' comfort  food'] },
          { dish_name: 'tiramisu', score: 6, score_evidence: 'tiramisu 6', note: null, styles: ['dessert', 'vegan', 42] },
        ],
      },
    }],
    usage: { input_tokens: 1, output_tokens: 1 },
  };
}

let instances = 0;
async function loadHandler(mode: 'stub' | 'model') {
  const world = fakeWorld();
  let modelCalls = 0;
  G.__sortEntryFake = { createClient: () => world.client };
  const env: Record<string, string> = {
    SUPABASE_URL: 'http://fake', SUPABASE_SERVICE_ROLE_KEY: 'service', SUPABASE_ANON_KEY: 'anon',
    ...(mode === 'model' ? { ANTHROPIC_API_KEY: 'sk-ant-test' } : {}),
  };
  let handler: ((req: Request) => Promise<Response>) | null = null;
  G.Deno = { env: { get: (k: string) => env[k] }, serve: (h: typeof handler) => { handler = h; } };
  const realFetch = G.fetch;
  G.fetch = async (url: string, init: unknown) => {
    if (String(url).includes('anthropic')) {
      modelCalls++;
      return new Response(JSON.stringify(modelReply()), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    return realFetch(url, init);
  };
  await import(`./index.ts?mode=${mode}&n=${++instances}`);
  assert(handler, 'index.ts did not call Deno.serve');
  const call = async (payload: unknown) => {
    const res = await handler!(new Request('http://fake/functions/v1/sort-entry', {
      method: 'POST', headers: { Authorization: 'Bearer user-token' }, body: JSON.stringify(payload),
    }));
    return { status: res.status, json: await res.json() };
  };
  return { world, call, modelCalls: () => modelCalls };
}

const tokens = { tag_tokens: [mark('GF')], six_tokens: [mark('6')] };
const printed = (items: Array<{ dish_name: string; score: number | null; tags?: string[] }>) =>
  items.map((i) => [i.dish_name.toLowerCase(), i.score, i.tags ?? []]);
const EXPECTED = [['pasta', 4.5, ['gf']], ['tiramisu', 6, []]];
/** 0053: the model's style words, cleaned (lower-cased, trimmed, no diet words); the stub proposes none. */
const styles = (items: Array<{ styles?: string[] }>) => items.map((i) => i.styles ?? []);
const EXPECTED_STYLES = { model: [['pasta', 'comfort food'], ['dessert']], stub: [[], []] };
const WRITES_TO_ENTRIES = (c: Call) =>
  (c.kind === 'rpc' && (c.name === 'apply_entry_sort' || c.name === 'mark_entry_sort_failed'))
  || (c.kind === 'write' && c.table !== 'sort_preview_cache');

if (!isDeno) {
  const { registerHooks } = await import('node:module');
  const fake = 'export function createClient(...a) { return globalThis.__sortEntryFake.createClient(...a); }';
  registerHooks({
    resolve(spec: string, ctx: unknown, next: (s: string, c: unknown) => unknown) {
      if (spec.startsWith('npm:@supabase/supabase-js')) {
        return { url: 'data:text/javascript,' + encodeURIComponent(fake), shortCircuit: true };
      }
      return next(spec, ctx);
    },
  });

  for (const mode of ['stub', 'model'] as const) {
    test(`sort-entry (${mode}): tag_tokens and six_tokens reach apply_entry_sort, once, on the right lines`, async () => {
      const { world, call, modelCalls } = await loadHandler(mode);
      const res = await call({ entry_id: ENTRY, force: false, ...tokens });
      assertEquals(res.status, 200, JSON.stringify(res.json));
      assertEquals(modelCalls(), mode === 'model' ? 1 : 0, 'the (mocked) model runs only in model mode');
      const applies = world.calls.filter((c) => c.kind === 'rpc' && c.name === 'apply_entry_sort');
      assertEquals(applies.length, 1);
      const args = applies[0].args as { p_entry_id: string; p_restaurant_id: string; p_items: never[]; p_mode: string };
      assertEquals([args.p_entry_id, args.p_restaurant_id, args.p_mode], [ENTRY, PLACE, mode]);
      assertEquals(printed(args.p_items), EXPECTED, 'the marked GF on the pasta, the marked 6 on the tiramisu');
      assertEquals(printed(res.json.items), EXPECTED, 'and the reply says what was written');
      assertEquals(styles(args.p_items), EXPECTED_STYLES[mode], 'styles reach apply_entry_sort, cleaned (model only)');

      // Without the tokens nothing is tagged and the typed 6 is not a score (it is never inferred).
      const bare = await loadHandler(mode);
      await bare.call({ entry_id: ENTRY, force: false });
      const [plain] = bare.world.calls.filter((c) => c.kind === 'rpc' && c.name === 'apply_entry_sort');
      const items = (plain.args as { p_items: never[] }).p_items;
      assert(printed(items).every(([, s, t]) => s !== 6 && (t as string[]).length === 0), JSON.stringify(printed(items)));
    });

    test(`sort-entry (${mode}): preview:true writes nothing, and says what the sort would print`, async () => {
      const { world, call, modelCalls } = await loadHandler(mode);
      const draft = { preview: true, body: BODY, restaurant_id: PLACE, ...tokens };
      const res = await call(draft);
      assertEquals(res.status, 200, JSON.stringify(res.json));
      assertEquals([res.json.preview, res.json.entry_id, res.json.mode], [true, null, mode]);
      assertEquals(printed(res.json.items), EXPECTED, 'the preview honours the same tokens');
      assertEquals(world.calls.filter(WRITES_TO_ENTRIES), [], 'no apply_entry_sort, no entry/review write');

      const again = await call(draft);
      if (mode === 'model') {
        assertEquals(modelCalls(), 1, 'the repeat draft is served from the cache — one model call in all');
        assertEquals(again.json.cached, true);
        assert(world.calls.some((c) => c.kind === 'write' && c.table === 'sort_preview_cache'), 'the plan was cached');
      } else {
        assertEquals(modelCalls(), 0, 'stub mode never calls the model');
        assert(!world.calls.some((c) => c.kind === 'write'), 'stub mode writes nothing at all');
      }
      assertEquals(world.calls.filter(WRITES_TO_ENTRIES), []);
    });
  }

  test('sort-entry (model): the styles in a cached preview plan reach the sort after Done — one model call', async () => {
    const { world, call, modelCalls } = await loadHandler('model');
    const preview = await call({ preview: true, body: BODY, restaurant_id: PLACE, ...tokens });
    assertEquals(styles(preview.json.items), EXPECTED_STYLES.model, 'the preview shows the cleaned styles');
    const res = await call({ entry_id: ENTRY, force: false, ...tokens });
    assertEquals(res.status, 200, JSON.stringify(res.json));
    assertEquals(modelCalls(), 1, 'the sort reused the preview\'s plan');
    const [apply] = world.calls.filter((c) => c.kind === 'rpc' && c.name === 'apply_entry_sort');
    assertEquals(styles((apply.args as { p_items: never[] }).p_items), EXPECTED_STYLES.model);
    assertEquals((apply.args as { p_meta: { cache_hit: boolean } }).p_meta.cache_hit, true);
  });

  test('sort-entry: a preview body over the limit is refused 422 before the rate limit, cache or model', async () => {
    const { world, call, modelCalls } = await loadHandler('model');
    const res = await call({ preview: true, body: 'a'.repeat(10_001), restaurant_id: PLACE });
    assertEquals(res.status, 422);
    assert(String(res.json.error).includes('too long'), JSON.stringify(res.json));
    assertEquals(modelCalls(), 0);
    assertEquals(world.calls, [], 'not even the purge or the rate counter ran — the staging smoke relies on this');
  });
}
