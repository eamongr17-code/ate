// supabase/functions/dish-dedup/scan.ts
//
// The scan of dishes that ALREADY exist (18 Oct, Eamon): which ones at one place are the same dish
// under two names. It only PROPOSES; nothing merges until a person approves the list
// (merge_dish_proposals, 0071). Pure: no IO except the injected fetch, so Node runs the suite.
//
//   1. same_name — the match key (../sort-entry/same-dish.ts matchKey: the spelling key, "X with Y"
//                  read as "Y X") is the same. No judgement.
//   2. ai        — a pair the deterministic fence allows (couldBeSame + exactly one dish at the place
//                  fits the shorter name) AND the model, shown every dish at the place with a few of
//                  the diners' notes, calls the same dish. "different" and "unsure" both stay apart.
//   Never: two places, or a pair one entry names on separate lines (the diner told them apart).
//
// The dish that survives is the one more lines use, then the older one: what people already call it.

import { couldBeSame, matchKey, sameDishGate } from '../sort-entry/same-dish.ts';

export type ScanDish = { id: string; name: string; lines: number; created_at: string; notes: string[] };
export type ScanPlace = { restaurant_id: string; place_name: string | null; dishes: ScanDish[]; shared_pairs: [string, string][] };
export type Proposal = {
  restaurant_id: string;
  source_dish_id: string;
  target_dish_id: string;
  source_name: string;
  target_name: string;
  reason: 'same_name' | 'ai';
  why: string | null;
};
export type Pair = { a: ScanDish; b: ScanDish };

/** The one-off scan runs on the most careful model; it is a few calls, once. */
export const DEFAULT_SCAN_MODEL = 'claude-opus-5-5';
export const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';
export const ANTHROPIC_VERSION = '2023-06-01';
/** A refusal falls back server-side to a model that can answer (the `"default"` routing). */
export const FALLBACK_BETA = 'server-side-fallback-2026-07-01';

const pairKey = (x: string, y: string) => (x < y ? `${x}|${y}` : `${y}|${x}`);

/** Which of the two survives: more lines, then older, then id (a total order, so reruns agree). */
export function survivor(a: ScanDish, b: ScanDish): [target: ScanDish, source: ScanDish] {
  if (a.lines !== b.lines) return a.lines > b.lines ? [a, b] : [b, a];
  if (a.created_at !== b.created_at) return a.created_at < b.created_at ? [a, b] : [b, a];
  return a.id < b.id ? [a, b] : [b, a];
}

const proposal = (place: ScanPlace, target: ScanDish, source: ScanDish, reason: Proposal['reason'], why: string | null): Proposal => ({
  restaurant_id: place.restaurant_id,
  source_dish_id: source.id,
  target_dish_id: target.id,
  source_name: source.name,
  target_name: target.name,
  reason,
  why,
});

/**
 * Tier 1 at one place: every spelling-key group of two or more folds into its survivor. Returns the
 * proposals and the dishes left once those are folded (one per group), for tier 2.
 */
export function sameNameProposals(place: ScanPlace): { proposals: Proposal[]; rest: ScanDish[] } {
  const shared = new Set(place.shared_pairs.map(([x, y]) => pairKey(x, y)));
  const groups = new Map<string, ScanDish[]>();
  const rest: ScanDish[] = [];
  for (const d of place.dishes) {
    const k = matchKey(d.name);
    if (!k) {
      rest.push(d);
      continue;
    }
    groups.set(k, [...(groups.get(k) ?? []), d]);
  }
  const proposals: Proposal[] = [];
  for (const group of groups.values()) {
    const target = group.reduce((best, d) => survivor(best, d)[0]);
    rest.push(target);
    for (const d of group) {
      if (d === target) continue;
      if (shared.has(pairKey(d.id, target.id))) {
        rest.push(d); // one entry names both: theirs to tell apart, not ours to fold
        continue;
      }
      proposals.push(proposal(place, target, d, 'same_name', null));
    }
  }
  return { proposals, rest };
}

/**
 * Tier 2's candidates at one place: pairs whose words could be the same dish, where the shorter name
 * fits that one dish and no other, and no entry names both. Only these go to the model.
 */
export function candidatePairs(place: ScanPlace, rest: ScanDish[]): Pair[] {
  const shared = new Set(place.shared_pairs.map(([x, y]) => pairKey(x, y)));
  const names = rest.map((d) => d.name);
  const out: Pair[] = [];
  for (let i = 0; i < rest.length; i++) {
    for (let j = i + 1; j < rest.length; j++) {
      const [a, b] = [rest[i], rest[j]];
      if (shared.has(pairKey(a.id, b.id)) || !couldBeSame(a.name, b.name)) continue;
      const [short, long] = a.name.length <= b.name.length ? [a, b] : [b, a];
      if (sameDishGate(short.name, long.name, names) === null) continue;
      out.push({ a, b });
    }
  }
  return out;
}

const SYSTEM = [
  'You check a restaurant\'s dish list in a dish-review app for the SAME dish logged under two names.',
  'Diners type dish names themselves, so "Carbonara" and "Spaghetti Carbonara" at one place may be one dish.',
  'But a real restaurant serves several pastas, steaks, pizzas and curries: a different cut, protein, size,',
  'filling, sauce or style is a DIFFERENT dish. Only the dishes listed have been logged; the place may serve',
  'others not listed, so a short name can stand for an unlisted dish too.',
  'For each numbered pair answer "same" only when you are confident both names mean the one dish on this',
  'menu. Answer "different" when they are not, and "unsure" whenever you cannot tell. Unsure keeps them apart,',
  'which is always acceptable; a wrong "same" merges two people\'s reviews of different dishes.',
  'Answer by calling judge_pairs once, with every pair.',
].join(' ');

const TOOL = {
  name: 'judge_pairs',
  description: 'Your verdict on every numbered pair.',
  strict: true,
  input_schema: {
    type: 'object',
    additionalProperties: false,
    required: ['verdicts'],
    properties: {
      verdicts: {
        type: 'array',
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['pair', 'verdict', 'why'],
          properties: {
            pair: { type: 'integer', description: 'The pair\'s number.' },
            verdict: { type: 'string', enum: ['same', 'different', 'unsure'] },
            why: { type: 'string', description: 'One short sentence.' },
          },
        },
      },
    },
  },
} as const;

export type ModelRequest = { url: string; headers: Record<string, string>; body: string };

/** Pure: the request for one place. */
export function buildRequest(opts: { apiKey: string; place: ScanPlace; pairs: Pair[]; model?: string }): ModelRequest {
  const dish = (d: ScanDish) => {
    const notes = d.notes.filter((n) => n?.trim()).slice(0, 3).map((n) => `"${n.slice(0, 160)}"`);
    return `- ${d.name} (${d.lines} review${d.lines === 1 ? '' : 's'})${notes.length ? `: ${notes.join('; ')}` : ''}`;
  };
  const user = [
    `PLACE: ${opts.place.place_name ?? 'unnamed'}`,
    'EVERY DISH LOGGED THERE (with what diners said):',
    ...opts.place.dishes.map(dish),
    '',
    'PAIRS TO JUDGE:',
    ...opts.pairs.map((p, i) => `${i + 1}. "${p.a.name}" / "${p.b.name}"`),
    '',
    'Call judge_pairs.',
  ].join('\n');
  return {
    url: ANTHROPIC_URL,
    headers: {
      'content-type': 'application/json',
      'x-api-key': opts.apiKey,
      'anthropic-version': ANTHROPIC_VERSION,
      'anthropic-beta': FALLBACK_BETA,
    },
    body: JSON.stringify({
      model: opts.model ?? DEFAULT_SCAN_MODEL,
      max_tokens: 16000,
      // Opus 5.5 always thinks and rejects a forced tool_choice: auto + a strict schema + the
      // instruction above. Effort is explicit (its default is medium).
      output_config: { effort: 'high' },
      fallbacks: 'default',
      system: SYSTEM,
      tools: [TOOL],
      tool_choice: { type: 'auto' },
      messages: [{ role: 'user', content: user }],
    }),
  };
}

/** Pure: the model's "same" verdicts as proposals. Anything malformed, refused or missing is not a "same". */
export function aiProposals(payload: unknown, place: ScanPlace, pairs: Pair[]): Proposal[] | null {
  const p = payload as { stop_reason?: unknown; content?: Array<Record<string, unknown>> } | null;
  if (!p || p.stop_reason === 'refusal' || !Array.isArray(p.content)) return null;
  const call = p.content.find((b) => b?.type === 'tool_use' && b?.name === TOOL.name);
  const verdicts = (call?.input as { verdicts?: unknown } | undefined)?.verdicts;
  if (!Array.isArray(verdicts)) return null;
  const out: Proposal[] = [];
  const seen = new Set<number>();
  for (const raw of verdicts) {
    const v = (raw ?? {}) as { pair?: unknown; verdict?: unknown; why?: unknown };
    const i = typeof v.pair === 'number' && Number.isInteger(v.pair) ? v.pair - 1 : -1;
    if (i < 0 || i >= pairs.length || seen.has(i) || v.verdict !== 'same') continue;
    seen.add(i);
    const [target, source] = survivor(pairs[i].a, pairs[i].b);
    out.push(proposal(place, target, source, 'ai', typeof v.why === 'string' ? v.why.slice(0, 300) : null));
  }
  // A dish proposed into two different survivors is a guess between them: neither.
  const sources = new Map<string, number>();
  for (const x of out) sources.set(x.source_dish_id, (sources.get(x.source_dish_id) ?? 0) + 1);
  return out.filter((x) => sources.get(x.source_dish_id) === 1 && !out.some((y) => y.source_dish_id === x.target_dish_id));
}

/** Ask the model about one place. null on any failure: that place gets no AI proposals. */
export async function judgePlace(opts: {
  apiKey: string;
  place: ScanPlace;
  pairs: Pair[];
  model?: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}): Promise<Proposal[] | null> {
  if (!opts.apiKey.trim() || !opts.pairs.length) return opts.pairs.length ? null : [];
  const req = buildRequest(opts);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? 120_000);
  try {
    const res = await (opts.fetchImpl ?? fetch)(req.url, { method: 'POST', headers: req.headers, body: req.body, signal: controller.signal });
    if (!res.ok) {
      console.error('dish-dedup: model answered', res.status, (await res.text().catch(() => '')).slice(0, 300));
      return null;
    }
    return aiProposals(await res.json(), opts.place, opts.pairs);
  } catch (e) {
    console.error('dish-dedup: model call failed:', e instanceof Error ? e.message : String(e));
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** The whole scan of one place: tier 1, then tier 2 on what is left. */
export async function scanPlace(place: ScanPlace, opts: { apiKey: string; model?: string; fetchImpl?: typeof fetch }): Promise<{
  proposals: Proposal[];
  asked: number;
  failed: boolean;
}> {
  const { proposals, rest } = sameNameProposals(place);
  const pairs = candidatePairs(place, rest);
  if (!pairs.length || !opts.apiKey.trim()) return { proposals, asked: 0, failed: pairs.length > 0 };
  const ai = await judgePlace({ apiKey: opts.apiKey, place, pairs, model: opts.model, fetchImpl: opts.fetchImpl });
  return { proposals: [...proposals, ...(ai ?? [])], asked: pairs.length, failed: ai === null };
}
