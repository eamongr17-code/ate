// supabase/functions/sort-entry/eval.ts
//
// THE MODEL EVAL — runs the fixture corpus (./fixtures.ts) through model mode exactly as
// the function would (same request, same place candidates, same validate.ts gate) and
// grades the result with the fixtures' own expectations.
//
//   cd supabase/functions/sort-entry
//   deno run --allow-net --allow-env eval.ts --model claude-haiku-4-5
//   deno run --allow-net --allow-env eval.ts --both
//   (node eval.ts --both works too — same code, no Deno needed)
//
// Reads ANTHROPIC_API_KEY from the environment and never prints it. Spends real tokens
// (a full --both run is roughly 2 x 80 short calls); nothing is written anywhere.
//
// GRADING, per fixture, after validate.ts:
//   dishes  the same dishes in the same order (case-insensitive: the database matches
//           dishes on lower(name), so case is spelling, not identity)
//   scores  dishes right AND every score equal, null where the user gave no number, and
//           the score's offset where the fixture pins one
//   notes   every note equal (trailing punctuation ignored) — a style choice, reported
//           separately because it is not a safety property
//   PASS = all three. CORE = dishes + scores: the part that can mislead a reader.
// Also counted: what the gate REJECTED from the raw reply (an unprovable score is the
// model trying to infer one), call failures, latency, tokens and dollars.

import { fixtures as corpus, type Fixture } from './fixtures.ts';
import { placeCandidateSpans } from './parse.ts';
import { validateItem, validatePlan } from './validate.ts';
import { callModel, isSorterModel, SORTER_MODELS, type ModelUsage, type SorterModel } from './model.ts';
import type { SortPlan } from './types.ts';

/** USD per million tokens. */
export const PRICING: Record<SorterModel, { input: number; output: number }> = {
  'claude-haiku-4-5': { input: 1, output: 5 },
  'claude-sonnet-5': { input: 2, output: 10 },
};

export function costUsd(model: SorterModel, usage: ModelUsage): number {
  const p = PRICING[model];
  return (usage.input_tokens * p.input + usage.output_tokens * p.output) / 1_000_000;
}

/** Nearest-rank percentile; null for no samples. */
export function percentile(samples: number[], p: number): number | null {
  if (!samples.length) return null;
  const sorted = [...samples].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length, Math.max(1, rank)) - 1];
}

export type Grade = {
  id: string;
  modelOnly: boolean;
  dishes: boolean;
  scores: boolean;
  notes: boolean;
  pass: boolean;
  core: boolean;
  /** what validate.ts threw away from the raw reply */
  rejected: { dishes: number; scores: number; notes: number };
  /** one line on what differed, empty on a pass */
  diff: string;
};

const dishKey = (s: string) => s.trim().replace(/\s+/g, ' ').toLowerCase();
const noteKey = (s: string | null) => (s === null ? null : s.trim().replace(/[\s.,;:!]+$/u, ''));

const line = (items: Array<{ dish_name: string; score: number | null; note: string | null }>) =>
  items.map((i) => `${i.dish_name} ${i.score ?? '-'}${i.note ? ` "${i.note}"` : ''}`).join(' | ') || '(none)';

/** Pure: grade one fixture from the model's raw plan (null = the call failed). */
export function gradeFixture(f: Fixture, raw: SortPlan | null): Grade {
  const opts = { body: f.body, knownDishes: f.knownDishes ?? [] };
  const got = raw ? validatePlan(raw, opts).items : [];
  const want = f.items;

  const rejected = { dishes: 0, scores: 0, notes: 0 };
  for (const r of raw?.items ?? []) {
    const v = validateItem(r, opts);
    if (!v) {
      rejected.dishes++;
      continue;
    }
    if (typeof r.score === 'number' && v.score === null) rejected.scores++;
    if (r.note && v.note === null) rejected.notes++;
  }

  // a failed call proves nothing, even where the right answer is "no items"
  const dishes = raw !== null && got.length === want.length &&
    want.every((w, i) => dishKey(w.dish_name) === dishKey(got[i].dish_name));
  const values = dishes && want.every((w, i) => w.score === got[i].score);
  // where the fixture pins WHERE the score is (a price in the same words also says
  // "4.5"), the model's evidence must land there too — the client draws the token on it
  const offsets = dishes &&
    want.every((w, i) => w.evidence_offset === undefined || (w.evidence_offset ?? null) === got[i].evidence_offset);
  const scores = values && offsets;
  const notes = dishes && want.every((w, i) => noteKey(w.note) === noteKey(got[i].note));
  const pass = dishes && scores && notes;

  let diff = '';
  if (!raw) diff = 'no plan';
  else if (values && !offsets) {
    const at = (xs: Array<{ evidence_offset?: number | null }>) => xs.map((x) => x.evidence_offset ?? '-').join(',');
    diff = `score offsets: want ${at(want)} / got ${at(got)}`;
  } else if (!pass) {
    const what = !dishes ? 'dishes' : !scores ? 'scores' : 'notes';
    diff = `${what}: want ${line(want)} / got ${line(got)}`;
  }
  return { id: f.id, modelOnly: Boolean(f.modelOnly), dishes, scores, notes, pass, core: scores, rejected, diff };
}

export type FixtureRun = Grade & {
  latencyMs: number | null;
  usage: ModelUsage | null;
  error: string | null;
};

export type ModelRun = {
  model: SorterModel;
  runs: FixtureRun[];
};

const RETRYABLE = /^HTTP (429|500|502|503|504|529)\b/;

async function runOne(
  f: Fixture,
  model: SorterModel,
  apiKey: string,
  fetchImpl: typeof fetch | undefined,
  sleep: (ms: number) => Promise<void>,
): Promise<FixtureRun> {
  const candidates = placeCandidateSpans(f.body).map((c) => c.phrase);
  for (let attempt = 0;; attempt++) {
    const t0 = performance.now();
    const call = await callModel({
      apiKey,
      model,
      body: f.body,
      knownDishes: f.knownDishes ?? [],
      placeCandidates: candidates,
      fetchImpl,
    });
    const latencyMs = performance.now() - t0;
    // rate limits and overloads are the account's problem, not the model's: back off
    // and retry them rather than scoring them. Anything else is a real failure.
    if (call.error && RETRYABLE.test(call.error) && attempt < 4) {
      await sleep(2000 * 2 ** attempt);
      continue;
    }
    return {
      ...gradeFixture(f, call.plan),
      latencyMs: call.plan ? latencyMs : null,
      usage: call.usage,
      error: call.error,
    };
  }
}

export async function runModel(opts: {
  model: SorterModel;
  apiKey: string;
  fixtures?: Fixture[];
  concurrency?: number;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  onResult?: (r: FixtureRun) => void;
}): Promise<ModelRun> {
  const list = opts.fixtures ?? corpus;
  const sleep = opts.sleep ?? ((ms) => new Promise<void>((r) => setTimeout(r, ms)));
  const runs: FixtureRun[] = new Array(list.length);
  let next = 0;
  const worker = async () => {
    while (next < list.length) {
      const i = next++;
      runs[i] = await runOne(list[i], opts.model, opts.apiKey, opts.fetchImpl, sleep);
      opts.onResult?.(runs[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, opts.concurrency ?? 2) }, worker));
  return { model: opts.model, runs };
}

export type Summary = {
  model: SorterModel;
  total: number;
  pass: number;
  core: number;
  modelOnly: number;
  modelOnlyCore: number;
  rejectedScores: number;
  rejectedNotes: number;
  rejectedDishes: number;
  failures: number;
  p50: number | null;
  p95: number | null;
  inputTokens: number;
  outputTokens: number;
  cost: number;
};

export function summarise(run: ModelRun): Summary {
  const r = run.runs;
  const usage = r.reduce(
    (a, x) => ({
      input_tokens: a.input_tokens + (x.usage?.input_tokens ?? 0),
      output_tokens: a.output_tokens + (x.usage?.output_tokens ?? 0),
    }),
    { input_tokens: 0, output_tokens: 0 },
  );
  const latencies = r.map((x) => x.latencyMs).filter((x): x is number => x !== null);
  return {
    model: run.model,
    total: r.length,
    pass: r.filter((x) => x.pass).length,
    core: r.filter((x) => x.core).length,
    modelOnly: r.filter((x) => x.modelOnly).length,
    modelOnlyCore: r.filter((x) => x.modelOnly && x.core).length,
    rejectedScores: r.reduce((a, x) => a + x.rejected.scores, 0),
    rejectedNotes: r.reduce((a, x) => a + x.rejected.notes, 0),
    rejectedDishes: r.reduce((a, x) => a + x.rejected.dishes, 0),
    failures: r.filter((x) => x.error !== null).length,
    p50: percentile(latencies, 50),
    p95: percentile(latencies, 95),
    inputTokens: usage.input_tokens,
    outputTokens: usage.output_tokens,
    cost: costUsd(run.model, usage),
  };
}

const pct = (n: number, d: number) => `${n}/${d} (${d ? ((100 * n) / d).toFixed(1) : '0.0'}%)`;
const ms = (n: number | null) => (n === null ? 'n/a' : `${Math.round(n)} ms`);
const usd = (n: number) => `$${n.toFixed(4)}`;
const int = (n: number) => n.toLocaleString('en-AU');

export function fixtureLine(r: FixtureRun): string {
  const tag = r.pass ? 'PASS' : r.core ? 'CORE' : 'FAIL';
  const why = r.error ? `error: ${r.error}` : r.diff;
  return `  ${tag}  ${r.id}${r.modelOnly ? ' [model-only]' : ''}${why ? `  ${why}` : ''}`;
}

export function summaryLines(s: Summary): string[] {
  return [
    `${s.model}`,
    `  score       PASS ${pct(s.pass, s.total)} · CORE dishes+scores ${pct(s.core, s.total)} · model-only CORE ${
      pct(s.modelOnlyCore, s.modelOnly)
    }`,
    `  gate        rejected ${s.rejectedScores} scores, ${s.rejectedNotes} notes, ${s.rejectedDishes} dishes · ${s.failures} failed calls`,
    `  latency     p50 ${ms(s.p50)} · p95 ${ms(s.p95)}`,
    `  tokens      ${int(s.inputTokens)} in · ${int(s.outputTokens)} out · ${usd(s.cost)} (${
      usd(s.total ? (s.cost / s.total) * 1000 : 0)
    } per 1,000 entries)`,
  ];
}

export function sideBySide(a: Summary, b: Summary): string[] {
  const rows: Array<[string, (s: Summary) => string]> = [
    ['PASS (all assertions)', (s) => pct(s.pass, s.total)],
    ['CORE (dishes + scores)', (s) => pct(s.core, s.total)],
    ['model-only CORE', (s) => pct(s.modelOnlyCore, s.modelOnly)],
    ['scores rejected by gate', (s) => String(s.rejectedScores)],
    ['notes rejected by gate', (s) => String(s.rejectedNotes)],
    ['dishes rejected by gate', (s) => String(s.rejectedDishes)],
    ['failed calls', (s) => String(s.failures)],
    ['latency p50', (s) => ms(s.p50)],
    ['latency p95', (s) => ms(s.p95)],
    ['input tokens', (s) => int(s.inputTokens)],
    ['output tokens', (s) => int(s.outputTokens)],
    ['cost (this run)', (s) => usd(s.cost)],
    ['cost per 1,000 entries', (s) => usd(s.total ? (s.cost / s.total) * 1000 : 0)],
  ];
  const w0 = Math.max(...rows.map(([k]) => k.length));
  const w1 = Math.max(a.model.length, ...rows.map(([, f]) => f(a).length));
  const row = (k: string, x: string, y: string) => `${k.padEnd(w0)}   ${x.padEnd(w1)}   ${y}`;
  return [row('', a.model, b.model), ...rows.map(([k, f]) => row(k, f(a), f(b)))];
}

/** Belt and braces: whatever is printed, the key is not in it. */
export function redactor(key: string): (s: string) => string {
  return key ? (s) => s.split(key).join('[redacted]') : (s) => s;
}

export function parseArgs(args: string[]): { models: SorterModel[]; concurrency: number } | { error: string } {
  let models: SorterModel[] | null = null;
  let concurrency = 2;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--both') models = [...SORTER_MODELS];
    else if (a === '--model' || a.startsWith('--model=')) {
      const v = a.includes('=') ? a.slice(a.indexOf('=') + 1) : args[++i];
      if (!isSorterModel(v)) return { error: `--model must be one of ${SORTER_MODELS.join(', ')}` };
      models = [v];
    } else if (a === '--concurrency' || a.startsWith('--concurrency=')) {
      const v = Number(a.includes('=') ? a.slice(a.indexOf('=') + 1) : args[++i]);
      if (!Number.isInteger(v) || v < 1 || v > 8) return { error: '--concurrency must be 1-8' };
      concurrency = v;
    } else return { error: `unknown argument ${a}` };
  }
  if (!models) return { error: `pass --model <${SORTER_MODELS.join('|')}> or --both` };
  return { models, concurrency };
}

// ---- the CLI: Deno (as documented) or Node, whichever runs it ------------------------

// deno-lint-ignore no-explicit-any
const G = globalThis as any;
const envGet = (k: string): string | undefined => G.Deno?.env?.get(k) ?? G.process?.env?.[k];
const cliArgs = (): string[] => G.Deno?.args ?? G.process?.argv?.slice(2) ?? [];
const exit = (code: number): never => (G.Deno ? G.Deno.exit(code) : G.process.exit(code)) as never;

async function main() {
  const parsed = parseArgs(cliArgs());
  if ('error' in parsed) {
    console.error(`eval: ${parsed.error}\n  usage: deno run --allow-net --allow-env eval.ts (--model <id> | --both)`);
    exit(2);
    return;
  }
  const key = (envGet('ANTHROPIC_API_KEY') ?? '').trim();
  if (!key) {
    console.error('eval: ANTHROPIC_API_KEY is not set in the environment.');
    exit(2);
  }
  const say = ((r) => (s: string) => console.log(r(s)))(redactor(key));

  const summaries: Summary[] = [];
  for (const model of parsed.models) {
    say(`\n${model} — ${corpus.length} fixtures`);
    const run = await runModel({ model, apiKey: key, concurrency: parsed.concurrency, onResult: (r) => say(fixtureLine(r)) });
    const s = summarise(run);
    summaries.push(s);
    say('');
    summaryLines(s).forEach(say);
  }
  if (summaries.length === 2) {
    say('\nside by side');
    sideBySide(summaries[0], summaries[1]).forEach(say);
  }
}

if (import.meta.main) await main();
