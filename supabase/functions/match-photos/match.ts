// supabase/functions/match-photos/match.ts
//
// Which photo is which dish (13 Oct beta: Paris posted three dishes and three photos, and every dish
// showed the first one). Pure: the plan of what to ask, the request, and the gate on the answer.
// index.ts does the reads and the one write (apply_photo_matches, 0063).
//
// The model only proposes, as everywhere in Ate: a pairing is kept only when it names a photo and a
// line that exist, each photo goes to at most one line and each line takes at most one photo. A
// line the author picked by hand is never offered. Without the key nothing is asked: one line takes
// the first photo, and anything more is left as it is.

import {
  ANTHROPIC_URL,
  ANTHROPIC_VERSION,
  DEFAULT_TIMEOUT_MS,
  modelEnabled,
  resolveModel,
  type SorterModel,
} from '../sort-entry/model.ts';

export { modelEnabled, resolveModel };

export type Photo = { position: number; url: string };
export type Line = {
  review_id: string;
  dish: string;
  note: string | null;
  /** The author chose this line's photo (or none) by hand. */
  picked: boolean;
  photo_url: string | null;
};
export type Match = { review_id: string; photo_url: string };

/** More photos than this are not sent; the composer allows five. */
export const MAX_PHOTOS = 8;
/** Images take longer than words: still a fast answer, but not the sorter's 5 s. */
export const MATCH_TIMEOUT_MS = Math.max(DEFAULT_TIMEOUT_MS, 12_000);

/**
 * What to do before any model is asked. `ask` lists only what is still open: the lines nobody
 * picked and the photos no picked line holds.
 */
export function plan(photos: Photo[], lines: Line[]):
  | { kind: 'nothing' }
  | { kind: 'direct'; matches: Match[] }
  | { kind: 'ask'; photos: Photo[]; lines: Line[] } {
  const held = new Set(lines.filter((l) => l.picked && l.photo_url).map((l) => l.photo_url!));
  const openPhotos = [...photos].sort((a, b) => a.position - b.position).filter((p) => !held.has(p.url)).slice(0, MAX_PHOTOS);
  const openLines = lines.filter((l) => !l.picked);
  if (!openPhotos.length || !openLines.length) return { kind: 'nothing' };
  // One dish left and the whole entry is about it: its photo is the first one. No model needed.
  if (openLines.length === 1 && lines.length === 1) {
    return { kind: 'direct', matches: [{ review_id: openLines[0].review_id, photo_url: openPhotos[0].url }] };
  }
  return { kind: 'ask', photos: openPhotos, lines: openLines };
}

export const TOOL = {
  name: 'match_photos',
  description: 'Say which dish each photo shows.',
  input_schema: {
    type: 'object',
    properties: {
      pairs: {
        type: 'array',
        description: 'One entry per photo that clearly shows one of the listed dishes. Leave out photos that show none.',
        items: {
          type: 'object',
          properties: {
            photo: { type: 'integer', description: 'The photo number, as labelled.' },
            dish: { type: 'integer', description: 'The dish number, as listed.' },
          },
          required: ['photo', 'dish'],
        },
      },
    },
    required: ['pairs'],
  },
} as const;

const SYSTEM = [
  'You match a diner\'s food photos to the dishes they wrote about in one restaurant visit.',
  'Each photo shows at most one listed dish as its subject; each dish has at most one photo.',
  'Use what is visibly on the plate or in the glass. If a photo shows no listed dish (the room, a menu,',
  'people, a dish not in the list), or you cannot tell, leave it out. Never guess.',
].join(' ');

export type ModelRequest = { url: string; headers: Record<string, string>; body: string };

/** Pure: the request. Photos go as URL images (public storage), each labelled before it. */
export function buildRequest(opts: { apiKey: string; photos: Photo[]; lines: Line[]; model?: SorterModel }): ModelRequest {
  const content: Array<Record<string, unknown>> = [];
  opts.photos.forEach((p, i) => {
    content.push({ type: 'text', text: `Photo ${i + 1}:` });
    content.push({ type: 'image', source: { type: 'url', url: p.url } });
  });
  const dishes = opts.lines
    .map((l, i) => `${i + 1}. ${l.dish}${l.note ? ` (the diner said: ${l.note.slice(0, 160)})` : ''}`)
    .join('\n');
  content.push({ type: 'text', text: `Dishes:\n${dishes}\n\nCall match_photos.` });
  return {
    url: ANTHROPIC_URL,
    headers: {
      'content-type': 'application/json',
      'x-api-key': opts.apiKey,
      'anthropic-version': ANTHROPIC_VERSION,
    },
    body: JSON.stringify({
      model: opts.model ?? resolveModel(null),
      max_tokens: 400,
      system: SYSTEM,
      tools: [TOOL],
      tool_choice: { type: 'tool', name: TOOL.name },
      messages: [{ role: 'user', content }],
    }),
  };
}

/**
 * Pure: the model's pairs, kept only where they name a real photo and a real line, first claim wins
 * on either side.
 */
export function matchesFromResponse(payload: unknown, photos: Photo[], lines: Line[]): Match[] | null {
  const content = (payload as { content?: Array<Record<string, unknown>> })?.content;
  if (!Array.isArray(content)) return null;
  const call = content.find((b) => b?.type === 'tool_use' && b?.name === TOOL.name);
  const pairs = (call?.input as { pairs?: unknown } | undefined)?.pairs;
  if (!Array.isArray(pairs)) return null;
  const usedPhotos = new Set<number>();
  const usedLines = new Set<number>();
  const out: Match[] = [];
  for (const raw of pairs) {
    const p = (raw ?? {}) as { photo?: unknown; dish?: unknown };
    const pi = typeof p.photo === 'number' && Number.isInteger(p.photo) ? p.photo - 1 : -1;
    const li = typeof p.dish === 'number' && Number.isInteger(p.dish) ? p.dish - 1 : -1;
    if (pi < 0 || pi >= photos.length || li < 0 || li >= lines.length) continue;
    if (usedPhotos.has(pi) || usedLines.has(li)) continue;
    usedPhotos.add(pi);
    usedLines.add(li);
    out.push({ review_id: lines[li].review_id, photo_url: photos[pi].url });
  }
  return out;
}

/** Ask the model. null on any failure: the entry then keeps whatever it had. */
export async function askModel(opts: {
  apiKey: string | null | undefined;
  photos: Photo[];
  lines: Line[];
  model?: SorterModel;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}): Promise<Match[] | null> {
  if (!modelEnabled(opts.apiKey)) return null;
  const req = buildRequest({ apiKey: String(opts.apiKey), photos: opts.photos, lines: opts.lines, model: opts.model });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? MATCH_TIMEOUT_MS);
  try {
    const res = await (opts.fetchImpl ?? fetch)(req.url, {
      method: 'POST', headers: req.headers, body: req.body, signal: controller.signal,
    });
    if (!res.ok) {
      console.error('match-photos: model answered', res.status);
      return null;
    }
    return matchesFromResponse(await res.json(), opts.photos, opts.lines);
  } catch (e) {
    console.error('match-photos: model call failed:', e instanceof Error ? e.message : String(e));
    return null;
  } finally {
    clearTimeout(timer);
  }
}
