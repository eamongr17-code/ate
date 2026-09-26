// supabase/functions/sort-entry/eval_test.ts
//
//   node --test supabase/functions/sort-entry/eval_test.ts
//
// The eval's machinery, proved WITHOUT a key or a network: a fake Messages API answers
// with known plans, and the grading, the gate accounting, the money and the redaction
// are asserted. (The real run is eval.ts itself, by hand, with a key.)

import { test, assert, assertEquals } from './harness.ts';
import { fixtures } from './fixtures.ts';
import { fencedPlaceNames, findNumbers, parseEntry } from './parse.ts';
import { validatePlan } from './validate.ts';
import {
  costUsd,
  fixtureLine,
  gradeFixture,
  parseArgs,
  percentile,
  redactor,
  runModel,
  sideBySide,
  summarise,
  summaryLines,
} from './eval.ts';
import type { SortPlan } from './types.ts';

const byId = (id: string) => fixtures.find((f) => f.id === id)!;

/** A fake API that answers each request with the plan registered for its words. */
function fakeApi(replies: Map<string, SortPlan['items']>, seen: string[] = []) {
  return ((_url: string, init: RequestInit) => {
    const req = JSON.parse(String(init.body));
    seen.push(req.model);
    const words = String(req.messages[0].content).split('<<<\n')[1].split('\n>>>')[0];
    const items = replies.get(words) ?? [];
    return Promise.resolve(
      new Response(
        JSON.stringify({
          content: [{ type: 'tool_use', name: 'sort_entry', input: { items } }],
          usage: { input_tokens: 1000, output_tokens: 100 },
        }),
        { status: 200 },
      ),
    );
  }) as unknown as typeof fetch;
}

test('a model that says what the stub says passes every stub-graded fixture', async () => {
  // Fixtures that pin an evidence OFFSET are left out on purpose: a model only returns
  // text, the offset is recovered from its first occurrence, and a bare "4.5" first
  // occurs inside "$14.50" — exactly what the eval exists to catch in a real model.
  const graded = fixtures.filter((f) => !f.modelOnly && !f.items.some((i) => 'evidence_offset' in i));
  const replies = new Map<string, SortPlan['items']>();
  for (const f of graded) {
    const opts = { body: f.body, knownDishes: f.knownDishes ?? [] };
    const plan = validatePlan(parseEntry({ ...opts, placeNames: fencedPlaceNames(f.resolvedPlace ?? {}) }), opts);
    replies.set(f.body, plan.items.map((i) => ({ ...i, evidence_offset: null, mention_text: null, mention_offset: null })));
  }
  const seen: string[] = [];
  const run = await runModel({
    model: 'claude-sonnet-5',
    apiKey: 'sk-ant-test',
    fixtures: graded,
    fetchImpl: fakeApi(replies, seen),
  });
  const failing = run.runs.filter((r) => !r.pass).map((r) => `${r.id}: ${r.diff}`);
  assertEquals(failing, [], 'every fixture passes');
  assert(seen.every((m) => m === 'claude-sonnet-5'), 'the chosen model is the one requested');

  const s = summarise(run);
  assertEquals([s.total, s.pass, s.core, s.failures, s.rejectedScores], [graded.length, graded.length, graded.length, 0, 0]);
  assertEquals(s.inputTokens, 1000 * graded.length);
  assertEquals(s.outputTokens, 100 * graded.length);
});

test('model-only: a right answer passes; an inferred score is caught by the gate and counted', async () => {
  const f = byId('model-sentiment-only');
  const right = [
    { dish_name: 'veal cutlet', score: null, score_evidence: null, note: 'genuinely perfect' },
    { dish_name: 'chips', score: null, score_evidence: null, note: "the best I've had in years" },
  ];
  // the worst bug: a score from sentiment, with made-up "evidence"
  const inferred = [
    { dish_name: 'veal cutlet', score: 5, score_evidence: 'genuinely perfect', note: 'genuinely perfect' },
    { dish_name: 'chips', score: null, score_evidence: null, note: "the best I've had in years" },
  ];
  // deno-lint-ignore no-explicit-any
  const plan = (items: any[]): SortPlan => ({ place_query: null, place_offset: null, items });

  const ok = gradeFixture(f, plan(right));
  assert(ok.pass && ok.core && ok.modelOnly, JSON.stringify(ok));

  // the gate strips the invented score, so the line prints unscored — the eval still
  // counts the attempt, which is the number that says whether a model can be trusted.
  const bad = gradeFixture(f, plan(inferred));
  assertEquals(bad.rejected, { dishes: 0, scores: 1, notes: 0 });
  assert(bad.pass, 'the gate made the output correct');

  // a paraphrased note and an invented dish are rejected too
  const para = gradeFixture(f, plan([
    { dish_name: 'veal cutlet', score: null, note: 'it was perfect' },
    { dish_name: 'chips', score: null, note: "the best I've had in years" },
    { dish_name: 'gravy', score: 4, score_evidence: '4' },
  ]));
  assertEquals(para.rejected, { dishes: 1, scores: 0, notes: 1 });
  assert(!para.pass && para.core, 'notes differ, dishes and scores right');
  assert(fixtureLine({ ...para, latencyMs: 1, usage: null, error: null }).startsWith('  CORE  model-sentiment-only'));
});

test('every model-only fixture is passable: its dishes, scores and notes are provable from its words', () => {
  for (const f of fixtures.filter((f) => f.modelOnly)) {
    const lower = f.body.toLowerCase();
    let from = 0;
    const items = f.items.map((w) => {
      const at = lower.indexOf(w.dish_name.toLowerCase(), from);
      assert(at >= 0, `${f.id}: "${w.dish_name}" is not in the words after the previous dish`);
      from = at + w.dish_name.length;
      const hit = w.score === null ? null : findNumbers(f.body).find((h) => h.start >= at && h.value === w.score);
      assert(w.score === null || hit, `${f.id}: no "${w.score}" after "${w.dish_name}"`);
      return { dish_name: w.dish_name, score: w.score, score_evidence: hit?.text ?? null, note: w.note };
    });
    const g = gradeFixture(f, { place_query: f.place, place_offset: null, items } as SortPlan);
    assert(g.pass, `${f.id}: ${g.diff}`);
  }
});

test('grading: wrong score fails CORE; case and trailing punctuation do not matter', () => {
  const f = byId('model-scores-in-words');
  const items = [
    { dish_name: 'Pappardelle', score: 4, score_evidence: 'honestly a four', note: null },
    { dish_name: 'burnt butter gnocchi', score: 3.5, score_evidence: 'three and a half', note: null },
    { dish_name: 'tiramisu', score: 3, score_evidence: 'maybe a three', note: null },
  ];
  // deno-lint-ignore no-explicit-any
  const plan = (it: any[]) => ({ place_query: 'Tipo 00', place_offset: null, items: it }) as SortPlan;
  assert(gradeFixture(f, plan(items)).pass);

  const wrong = gradeFixture(f, plan([{ ...items[0], score: 4.5, score_evidence: 'honestly a four' }, ...items.slice(1)]));
  // 4.5 is not in "honestly a four": the gate drops it, the line is unscored, CORE fails
  assert(!wrong.core && wrong.diff.startsWith('scores:'), wrong.diff);

  const f2 = byId('design-entry');
  const noStop = gradeFixture(f2, plan([
    { dish_name: 'Tagliatelle al ragù', score: 4.5, score_evidence: '4.5', note: 'unreal, rich, glossy, gone in four minutes' },
    { dish_name: 'Tiramisu', score: 3, score_evidence: '3.0', note: 'a bit flat after that.' },
    { dish_name: 'Prawn spaghetti', score: null, note: 'looked the business.' },
  ]));
  assert(noStop.pass, noStop.diff);
});

test('a failed call is a FAIL with the reason, and rate limits are retried not scored', async () => {
  let calls = 0;
  const flaky = (() => {
    calls++;
    return Promise.resolve(
      calls === 1
        ? new Response(JSON.stringify({ error: { message: 'rate limited' } }), { status: 429 })
        : new Response(JSON.stringify({ error: { message: 'model not found' } }), { status: 404 }),
    );
  }) as unknown as typeof fetch;
  const run = await runModel({
    model: 'claude-haiku-4-5',
    apiKey: 'sk-ant-test',
    fixtures: [byId('design-entry')],
    fetchImpl: flaky,
    sleep: () => Promise.resolve(),
  });
  assertEquals(calls, 2);
  assertEquals(run.runs[0].error, 'HTTP 404: model not found');
  // even where the right answer is "nothing", a failed call is not a pass
  const empty = fixtures.find((f) => f.items.length === 0)!;
  const g = gradeFixture(empty, null);
  assert(!g.pass && !g.core, 'a failed call never passes');
  assert(!run.runs[0].pass && run.runs[0].latencyMs === null);
  assertEquals(summarise(run).failures, 1);
});

test('money: per-million pricing for both models', () => {
  assertEquals(costUsd('claude-haiku-4-5', { input_tokens: 1_000_000, output_tokens: 1_000_000 }), 6);
  assertEquals(costUsd('claude-sonnet-5', { input_tokens: 1_000_000, output_tokens: 1_000_000 }), 12);
  assertEquals(costUsd('claude-haiku-4-5', { input_tokens: 2000, output_tokens: 200 }), 0.003);
});

test('latency percentiles are nearest-rank', () => {
  const xs = Array.from({ length: 20 }, (_, i) => (i + 1) * 100);
  assertEquals(percentile(xs, 50), 1000);
  assertEquals(percentile(xs, 95), 1900);
  assertEquals(percentile([7], 95), 7);
  assertEquals(percentile([], 50), null);
});

test('arguments: --model takes only the two IDs; --both runs both', () => {
  assertEquals(parseArgs(['--model', 'claude-haiku-4-5']), { models: ['claude-haiku-4-5'], concurrency: 2 });
  assertEquals(parseArgs(['--model=claude-sonnet-5']), { models: ['claude-sonnet-5'], concurrency: 2 });
  assertEquals(parseArgs(['--both', '--concurrency', '4']), { models: ['claude-haiku-4-5', 'claude-sonnet-5'], concurrency: 4 });
  assert('error' in parseArgs([]));
  assert('error' in parseArgs(['--model', 'claude-haiku-4-5-20251001']));
  assert('error' in parseArgs(['--model']));
});

test('the key is never printed', async () => {
  const key = 'sk-ant-api03-SECRET';
  const echo = (() =>
    Promise.resolve(new Response(JSON.stringify({ error: { message: `bad key ${key}` } }), { status: 401 }))) as unknown as typeof fetch;
  const run = await runModel({ model: 'claude-haiku-4-5', apiKey: key, fixtures: [byId('design-entry')], fetchImpl: echo });
  const say = redactor(key);
  const s = summarise(run);
  const out = [...run.runs.map(fixtureLine), ...summaryLines(s), ...sideBySide(s, s)].map(say).join('\n');
  assert(!out.includes(key), out);
  assert(out.includes('[redacted]'), 'the echo was caught, not merely absent');
});
