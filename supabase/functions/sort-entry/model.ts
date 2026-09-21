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

export const MODEL = 'claude-haiku-4-5-20251001';
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
      model: MODEL,
      max_tokens: 2048,
      temperature: 0,
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
    items: input.items.map((raw) => {
      const it = (raw ?? {}) as Record<string, unknown>;
      return {
        dish_name: typeof it.dish_name === 'string' ? it.dish_name : '',
        score: typeof it.score === 'number' ? it.score : null,
        score_evidence: typeof it.score_evidence === 'string' ? it.score_evidence : null,
        note: typeof it.note === 'string' ? it.note : null,
      };
    }),
  };
}

/**
 * Call the model. Returns null on ANY failure (no key, non-200, timeout, malformed
 * tool call) — the caller falls back to the deterministic stub.
 */
export async function sortWithModel(opts: {
  apiKey: string | null | undefined;
  body: string;
  knownDishes?: string[];
  placeCandidates?: string[];
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}): Promise<SortPlan | null> {
  if (!modelEnabled(opts.apiKey)) return null; // INERT without the secret.

  const req = buildRequest({
    apiKey: String(opts.apiKey),
    body: opts.body,
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
      console.error(`sort-entry: model HTTP ${res.status}`);
      return null;
    }
    return planFromResponse(await res.json());
  } catch (e) {
    console.error('sort-entry: model call failed:', e instanceof Error ? e.message : e);
    return null;
  } finally {
    clearTimeout(timer);
  }
}
