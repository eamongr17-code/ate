// supabase/functions/sort-entry/model_test.ts
//
//   deno test --no-check supabase/functions/sort-entry/
//   node --test supabase/functions/sort-entry/model_test.ts
//
// The point of these tests is INERTNESS: with no ANTHROPIC_API_KEY, the model path
// must not merely be unused — it must be unreachable, and provably make no network
// call. The rest pins the request shape and the tool-call parsing so the live switch
// is a config change, not a code change.

import { test, assert, assertEquals } from './harness.ts';
import {
  buildRequest,
  callModel,
  DEFAULT_MODEL,
  isSorterModel,
  modelEnabled,
  planFromResponse,
  resolveMode,
  resolveModel,
  SORTER_MODELS,
  sortWithModel,
  usageFromResponse,
} from './model.ts';

test('mode resolution: stub unless a key exists', () => {
  assertEquals(resolveMode('', undefined), 'stub');
  assertEquals(resolveMode('   ', undefined), 'stub');
  assertEquals(resolveMode(null, undefined), 'stub');
  assertEquals(resolveMode('sk-ant-xxx', undefined), 'model');
});

test('ATE_SORTER_MODE can force stub, but can never force model without a key', () => {
  assertEquals(resolveMode('sk-ant-xxx', 'stub'), 'stub');
  assertEquals(resolveMode('', 'model'), 'stub');
  assertEquals(resolveMode('sk-ant-xxx', 'model'), 'model');
});

test('modelEnabled is the single source of that truth', () => {
  assert(!modelEnabled(undefined));
  assert(!modelEnabled(''));
  assert(modelEnabled('sk-ant-xxx'));
});

test('WITHOUT a key, sortWithModel makes NO network call and returns null', async () => {
  let calls = 0;
  const spy = (() => {
    calls++;
    throw new Error('the model path must be unreachable without a key');
  }) as unknown as typeof fetch;

  assertEquals(await sortWithModel({ apiKey: '', body: 'Tipo 00. Pasta 4.5', fetchImpl: spy }), null);
  assertEquals(await sortWithModel({ apiKey: undefined, body: 'x', fetchImpl: spy }), null);
  assertEquals(calls, 0);
});

test('model ID: exactly the two evaluated aliases, haiku by default, no date suffixes', () => {
  assertEquals(SORTER_MODELS, ['claude-haiku-4-5', 'claude-sonnet-5']);
  assertEquals(DEFAULT_MODEL, 'claude-haiku-4-5');
  assertEquals(resolveModel(undefined), 'claude-haiku-4-5');
  assertEquals(resolveModel(null), 'claude-haiku-4-5');
  assertEquals(resolveModel(''), 'claude-haiku-4-5');
  assertEquals(resolveModel('  '), 'claude-haiku-4-5');
  assertEquals(resolveModel('claude-haiku-4-5'), 'claude-haiku-4-5');
  assertEquals(resolveModel('claude-sonnet-5'), 'claude-sonnet-5');
  assertEquals(resolveModel(' claude-sonnet-5\n'), 'claude-sonnet-5', 'a pasted secret keeps its newline');
});

test('model ID: anything unevaluated runs the default, never a guess', () => {
  const warn = console.warn;
  console.warn = () => {};
  try {
    for (const bad of ['claude-haiku-4-5-20251001', 'claude-sonnet-5-20260101', 'sonnet', 'CLAUDE-SONNET-5', 'claude-opus-5-5']) {
      assertEquals(resolveModel(bad), DEFAULT_MODEL, bad);
      assert(!isSorterModel(bad), bad);
    }
  } finally {
    console.warn = warn;
  }
});

test('the configured model is the one sent', () => {
  for (const model of SORTER_MODELS) {
    const payload = JSON.parse(buildRequest({ apiKey: 'sk-ant-xxx', body: 'Pasta 4.5', model }).body);
    assertEquals(payload.model, model);
    assertEquals(payload.tool_choice, { type: 'tool', name: 'sort_entry' }, `${model} is still forced through the tool`);
  }
});

test('sonnet 5 gets no sampling parameters (it rejects them with a 400)', () => {
  const req = buildRequest({ apiKey: 'sk-ant-xxx', body: 'Tipo 00. Pasta 4.5', knownDishes: ['Pasta'], model: 'claude-sonnet-5' });
  const payload = JSON.parse(req.body);
  assertEquals(payload.model, 'claude-sonnet-5');
  assertEquals('temperature' in payload, false);
});

test('the request is haiku by default, deterministic, and forced through the tool', () => {
  const req = buildRequest({ apiKey: 'sk-ant-xxx', body: 'Tipo 00. Pasta 4.5', knownDishes: ['Pasta'] });
  const payload = JSON.parse(req.body);

  assertEquals(payload.model, 'claude-haiku-4-5');
  assertEquals(payload.temperature, 0);
  assertEquals(payload.tool_choice, { type: 'tool', name: 'sort_entry' });
  assertEquals(payload.tools.length, 1);
  assert(payload.system.includes('NEVER'), 'the rules must travel with the request');
  assert(payload.messages[0].content.includes('Tipo 00. Pasta 4.5'), 'the words must be sent verbatim');
  assert(payload.messages[0].content.includes('Pasta'), 'the known menu must be sent');
  assertEquals(req.headers['anthropic-version'], '2023-06-01');
  assertEquals(req.headers['x-api-key'], 'sk-ant-xxx');
});

test('a tool call is read into a plan; omitted fields become null', () => {
  const plan = planFromResponse({
    content: [
      { type: 'text', text: 'ignore me' },
      {
        type: 'tool_use',
        name: 'sort_entry',
        input: {
          place_query: 'Tipo 00',
          items: [
            { dish_name: 'Pasta', score: 4.5, score_evidence: '4.5', note: 'unreal.' },
            { dish_name: 'Tiramisu' },
          ],
        },
      },
    ],
  });
  // The model is never asked WHERE anything is (it cannot count code points): every
  // offset comes back null and validate.ts recovers it from the text.
  assertEquals(plan, {
    place_query: 'Tipo 00',
    place_offset: null,
    items: [
      {
        dish_name: 'Pasta', score: 4.5, score_evidence: '4.5', note: 'unreal.',
        evidence_offset: null, mention_text: null, mention_offset: null,
      },
      {
        dish_name: 'Tiramisu', score: null, score_evidence: null, note: null,
        evidence_offset: null, mention_text: null, mention_offset: null,
      },
    ],
  });
});

test('a reply with no tool call is null, not a guess', () => {
  assertEquals(planFromResponse({ content: [{ type: 'text', text: '{"items":[]}' }] }), null);
  assertEquals(planFromResponse({}), null);
  assertEquals(planFromResponse(null), null);
  assertEquals(planFromResponse({ content: [{ type: 'tool_use', name: 'other', input: { items: [] } }] }), null);
});

test('a non-200 from the model degrades to null (the caller falls back to the stub)', async () => {
  const spy = (() => Promise.resolve(new Response('nope', { status: 500 }))) as unknown as typeof fetch;
  assertEquals(await sortWithModel({ apiKey: 'sk-ant-xxx', body: 'x', fetchImpl: spy }), null);
});

test('a live tool call round-trips into a plan', async () => {
  const body = JSON.stringify({
    content: [{ type: 'tool_use', name: 'sort_entry', input: { items: [{ dish_name: 'Pasta', score: 4.5, score_evidence: '4.5' }] } }],
  });
  const spy = (() =>
    Promise.resolve(new Response(body, { status: 200, headers: { 'content-type': 'application/json' } }))) as unknown as typeof fetch;

  const plan = await sortWithModel({ apiKey: 'sk-ant-xxx', body: 'Pasta 4.5', fetchImpl: spy });
  assertEquals(plan?.items[0].dish_name, 'Pasta');
  assertEquals(plan?.place_query, null);
});

test('usage is read off the reply for the eval; absent usage is null', () => {
  assertEquals(usageFromResponse({ usage: { input_tokens: 812, output_tokens: 96 } }), { input_tokens: 812, output_tokens: 96 });
  assertEquals(usageFromResponse({ content: [] }), null);
  assertEquals(usageFromResponse(null), null);
});

test('callModel reports why it failed, without the key', async () => {
  const spy = (() =>
    Promise.resolve(
      new Response(JSON.stringify({ type: 'error', error: { type: 'invalid_request_error', message: 'bad param' } }), {
        status: 400,
      }),
    )) as unknown as typeof fetch;
  const r = await callModel({ apiKey: 'sk-ant-secret', body: 'x', model: 'claude-sonnet-5', fetchImpl: spy });
  assertEquals(r.plan, null);
  assertEquals(r.error, 'HTTP 400: bad param');
  assert(!JSON.stringify(r).includes('sk-ant-secret'));
});
