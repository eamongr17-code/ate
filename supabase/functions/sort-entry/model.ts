// supabase/functions/sort-entry/model.ts
//
// REAL MODE — implemented, and INERT until `ANTHROPIC_API_KEY` exists in the
// function's secrets. Nothing in this module runs, and no network call is made,
// without that key: index.ts picks the mode from the key's presence, and
// sortWithModel() refuses to build a request without one.
//
// It returns the SAME SortPlan the stub returns and is then put through the SAME
// validate.ts gate, which is the whole point of the design: the model can only ever
// propose. It cannot invent a score (the evidence must be in the user's words), it
// cannot paraphrase a note (it must be a substring) and it cannot conjure a dish
// nobody mentioned. Switching modes cannot loosen a single rule.
//
// Structured output uses a forced tool call (tool_choice) rather than "please reply
// with JSON", so a malformed reply is a transport failure we can detect, not prose we
// have to guess at. Any failure → null → index.ts falls back to the stub, so sorting
// degrades rather than breaks.

import type { SortPlan } from './types.ts';

/**
 * The models the sorter may run on, chosen by the ATE_SORTER_MODEL secret. Bare aliases,
 * never date-suffixed snapshots: the two were compared on the fixture corpus with eval.ts
 * and the choice is a config flip, not a code change.
 */
export const SORTER_MODELS = ['claude-haiku-4-5', 'claude-sonnet-5'] as const;
export type SorterModel = typeof SORTER_MODELS[number];
export const DEFAULT_MODEL: SorterModel = 'claude-haiku-4-5';

export function isSorterModel(v: unknown): v is SorterModel {
  return typeof v === 'string' && (SORTER_MODELS as readonly string[]).includes(v);
}

/**
 * ATE_SORTER_MODEL → the model ID sent to the API. Unset/blank → the default. An
 * unrecognised value also runs the default (with a warning) rather than sending an ID we
 * never evaluated: a typo in a secret must degrade, not break every sort.
 */
export function resolveModel(raw: string | null | undefined): SorterModel {
  const v = (raw ?? '').trim();
  if (!v) return DEFAULT_MODEL;
  if (isSorterModel(v)) return v;
  console.warn(`sort-entry: ATE_SORTER_MODEL=${JSON.stringify(v)} is not one of ${SORTER_MODELS.join(', ')}; using ${DEFAULT_MODEL}`);
  return DEFAULT_MODEL;
}

export const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';
export const ANTHROPIC_VERSION = '2023-06-01';
export const DEFAULT_TIMEOUT_MS = 20_000;

export function modelEnabled(key: string | null | undefined): boolean {
  return typeof key === 'string' && key.trim().length > 0;
}

/**
 * The mode switch, in one testable place. Stub unless a key exists; ATE_SORTER_MODE
 * can force stub (an eval / incident switch) but can NEVER force model without a key.
 */
export function resolveMode(key: string | null | undefined, forced?: string | null): 'stub' | 'model' {
  if ((forced ?? '').trim().toLowerCase() === 'stub') return 'stub';
  return modelEnabled(key) ? 'model' : 'stub';
}

const SYSTEM = [
  'You sort a diner\'s free-text note about one restaurant visit into receipt line items.',
  'You NEVER rewrite, translate, summarise or improve their words.',
  '',
  'Rules (violating any of these means the item is discarded server-side):',
  '1. SCORES ARE ONLY EVER THE USER\'S. Give a score ONLY when they explicitly wrote or',
  '   said a number for that dish ("4.5", "4/5", "four and a half", "a solid four").',
  '   NEVER infer a score from sentiment, however clear the sentiment is. No number in',
  '   the words means score: null. Numbers that are not scores (times, prices, counts,',
  '   dates, "gone in four minutes") are not scores.',
  '2. score_evidence must be the EXACT substring of their text containing that number.',
  '   Copy it character for character. If you cannot copy it, omit the score.',
  '3. note must be an EXACT substring of their text — a quote, never a paraphrase, never',
  '   re-punctuated. Omit it if they said nothing about that dish.',
  '4. dish_name must appear in their text, or be one of the known menu dishes supplied.',
  '   Do not invent dishes. Do not split one dish into two.',
  '5. place_query is the phrase in their text that NAMES a restaurant, or omit it. Never',
  '   guess a place from a dish, a suburb, or anything else.',
  '6. Order the items as the dishes appear in their text.',
  '7. A note is the words that follow that dish (and its score) up to the next dish,',
  '   without the dish name or the score, and without leading glue ("and", "was", ",").',
  '   It is printed under the dish on a receipt, so it must read as a comment on it.',
].join('\n');

const TOOL = {
  name: 'sort_entry',
  description: 'Return the receipt line items for this visit. Omit any field you cannot prove from the text.',
  input_schema: {
    type: 'object',
    properties: {
      place_query: {
        type: 'string',
        description: 'The phrase in the text that names the restaurant. Omit if the text names no place.',
      },
      items: {
        type: 'array',
        description: 'One entry per dish mentioned, in the order they appear.',
        items: {
          type: 'object',
          properties: {
            dish_name: { type: 'string', description: 'The dish as the text names it.' },
            score: {
              type: 'number',
              description: 'The score the user explicitly gave, 0.5-5 in half steps. Omit when they gave no number.',
            },
            score_evidence: {
              type: 'string',
              description: 'Exact substring of the text containing that number. Required whenever score is present.',
            },
            note: { type: 'string', description: 'Exact substring of the text about this dish. Omit if none.' },
          },
          required: ['dish_name'],
        },
      },
    },
    required: ['items'],
  },
} as const;

export type ModelRequest = {
  url: string;
  headers: Record<string, string>;
  body: string;
};

/** Pure: build the HTTP request. Exported so tests can assert the payload without a key. */
export function buildRequest(opts: {
  apiKey: string;
  body: string;
  model?: SorterModel;
  knownDishes?: string[];
  placeCandidates?: string[];
}): ModelRequest {
  const known = (opts.knownDishes ?? []).slice(0, 200);
  const places = (opts.placeCandidates ?? []).slice(0, 8);

  const user = [
    'THE DINER\'S WORDS (verbatim, between the markers):',
    '<<<',
    opts.body,
    '>>>',
    '',
    known.length
      ? `KNOWN MENU DISHES AT THE MATCHED PLACE (prefer these spellings when they match): ${known.join(' | ')}`
      : 'KNOWN MENU DISHES: none supplied (no place matched yet).',
    places.length ? `PLACE-NAME CANDIDATES found in the text: ${places.join(' | ')}` : '',
    '',
    'Call sort_entry.',
  ]
    .filter(Boolean)
    .join('\n');

  return {
    url: ANTHROPIC_URL,
    headers: {
      'content-type': 'application/json',
      'x-api-key': opts.apiKey,
      'anthropic-version': ANTHROPIC_VERSION,
    },
    body: JSON.stringify({
      model: opts.model ?? DEFAULT_MODEL,
      max_tokens: 2048,
      // Sonnet 5 rejects sampling parameters with a 400; Haiku 4.5 still takes them.
      ...((opts.model ?? DEFAULT_MODEL) === 'claude-haiku-4-5' ? { temperature: 0 } : {}),
      system: SYSTEM,
      tools: [TOOL],
      tool_choice: { type: 'tool', name: TOOL.name },
      messages: [{ role: 'user', content: user }],
    }),
  };
}

/** Pure: pull the plan out of a Messages API response. Returns null if it is not there. */
export function planFromResponse(payload: unknown): SortPlan | null {
  const content = (payload as { content?: Array<Record<string, unknown>> })?.content;
  if (!Array.isArray(content)) return null;
  const call = content.find((b) => b?.type === 'tool_use' && b?.name === TOOL.name);
  const input = call?.input as { place_query?: unknown; items?: unknown } | undefined;
  if (!input || !Array.isArray(input.items)) return null;

  return {
    place_query: typeof input.place_query === 'string' && input.place_query.trim() ? input.place_query.trim() : null,
    // The model is asked for TEXT, never for offsets — it cannot count code points and
    // a wrong offset is worse than none. validate.ts recovers each offset from the
    // first occurrence of the text it did return.
    place_offset: null,
    items: input.items.map((raw) => {
      const it = (raw ?? {}) as Record<string, unknown>;
      return {
        dish_name: typeof it.dish_name === 'string' ? it.dish_name : '',
        score: typeof it.score === 'number' ? it.score : null,
        score_evidence: typeof it.score_evidence === 'string' ? it.score_evidence : null,
        note: typeof it.note === 'string' ? it.note : null,
        evidence_offset: null,
        mention_text: null,
        mention_offset: null,
      };
    }),
  };
}

export type ModelUsage = { input_tokens: number; output_tokens: number };

/** Pure: the token counts off a Messages API response, or null when absent. */
export function usageFromResponse(payload: unknown): ModelUsage | null {
  const u = (payload as { usage?: Record<string, unknown> })?.usage;
  if (!u || typeof u.input_tokens !== 'number' || typeof u.output_tokens !== 'number') return null;
  return { input_tokens: u.input_tokens, output_tokens: u.output_tokens };
}

export type ModelCallOptions = {
  apiKey: string | null | undefined;
  body: string;
  model?: SorterModel;
  knownDishes?: string[];
  placeCandidates?: string[];
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
};

export type ModelCall = {
  plan: SortPlan | null;
  usage: ModelUsage | null;
  /** why plan is null — never contains the key or the request */
  error: string | null;
};

/**
 * The call with its bookkeeping (usage, failure reason) — what eval.ts measures.
 * The function itself uses sortWithModel below.
 */
export async function callModel(opts: ModelCallOptions): Promise<ModelCall> {
  if (!modelEnabled(opts.apiKey)) return { plan: null, usage: null, error: 'no key' }; // INERT without the secret.

  const req = buildRequest({
    apiKey: String(opts.apiKey),
    body: opts.body,
    model: opts.model,
    knownDishes: opts.knownDishes,
    placeCandidates: opts.placeCandidates,
  });
  const doFetch = opts.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? DEFAULT_TIMEOUT_MS);

  try {
    const res = await doFetch(req.url, {
      method: 'POST',
      headers: req.headers,
      body: req.body,
      signal: controller.signal,
    });
    if (!res.ok) {
      // the status plus the API's own one-line reason (e.g. a rejected parameter) —
      // never the raw body, never a header.
      const reason = await res.json()
        .then((j) => String((j as { error?: { message?: unknown } })?.error?.message ?? ''))
        .catch(() => '');
      return { plan: null, usage: null, error: `HTTP ${res.status}${reason ? `: ${reason.slice(0, 200)}` : ''}` };
    }
    const payload = await res.json();
    const plan = planFromResponse(payload);
    return { plan, usage: usageFromResponse(payload), error: plan ? null : 'no tool call in reply' };
  } catch (e) {
    return { plan: null, usage: null, error: e instanceof Error ? e.message : String(e) };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Call the model. Returns null on ANY failure (no key, non-200, timeout, malformed
 * tool call) — the caller falls back to the deterministic stub.
 */
export async function sortWithModel(opts: ModelCallOptions): Promise<SortPlan | null> {
  const { plan, error } = await callModel(opts);
  if (error && error !== 'no key') console.error(`sort-entry: model call failed: ${error}`);
  return plan;
}
