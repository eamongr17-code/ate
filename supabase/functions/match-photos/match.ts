// supabase/functions/match-photos/match.ts
//
// Which photo is which dish (13 Oct beta: Paris posted three dishes and three photos, and every dish
// showed the first one). Pure: the plan of what to ask, the request, and the gate on the answer.
// index.ts does the reads and the one write (apply_photo_matches, 0063).
//
// The model only proposes, as everywhere in Ate: a pairing is kept only when it names a photo and a
// line that exist. A line may take several photos (22 Oct: Paris's two photos of one noodle soup;
// only the first was named), and a photo several lines (22 Oct: a sandwich and its fries on one
// plate, 0083). Each pairing may say where the dish sits in the photo: a box, from the same call. A
// line the author picked by hand is never offered. A photo of no listed dish (the people at the
// table, the room) is left out, also on a one-dish entry. Without the key nothing is asked: one line
// takes every photo, and anything more is left as it is.

import {
  ANTHROPIC_URL,
  ANTHROPIC_VERSION,
  DEFAULT_TIMEOUT_MS,
  modelEnabled,
  resolveModel,
  type SorterModel,
} from '../sort-entry/model.ts';

export { modelEnabled, resolveModel };

/** `url` is the stored address (what a match writes back); `read`, when set, is where its bytes are read. */
export type Photo = { position: number; url: string; read?: string };
/** A photo with its bytes, read by the function itself (see loadImages). */
export type LoadedPhoto = Photo & { data: string; media_type: ImageType };
export type ImageType = 'image/jpeg' | 'image/png' | 'image/webp' | 'image/gif';
export type Line = {
  review_id: string;
  dish: string;
  note: string | null;
  /** The author chose this line's photo (or none) by hand. */
  picked: boolean;
  photo_url: string | null;
};
/** `box`: where the dish sits, [left, top, right, bottom] as 0–1 fractions of the image. */
export type Match = { review_id: string; photo_url: string; box?: Box };
export type Box = [number, number, number, number];

/** More photos than this are not sent; the composer allows five. */
export const MAX_PHOTOS = 8;
/** Images take longer than words: still a fast answer, but not the sorter's 5 s. */
export const MATCH_TIMEOUT_MS = Math.max(DEFAULT_TIMEOUT_MS, 12_000);
/** A photo bigger than this is not read (the app uploads ~1600 px JPEGs, well under). */
export const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
/** Each photo read from storage, before the model is asked. */
export const IMAGE_TIMEOUT_MS = 5_000;

/**
 * `…/entry-0.jpg` → `…/entry-0_t.jpg`: the 480 px copy every upload writes beside the full one
 * (PhotoThumbnail / PhotoAddress in AteKit). Enough to tell a pasta from a tiramisu, a fraction of
 * the tokens, and fast to read. `null` when the URL has no file to derive it from.
 */
export function thumbnailUrl(url: string): string | null {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  const slash = u.pathname.lastIndexOf('/');
  const file = u.pathname.slice(slash + 1);
  if (!file || file.endsWith('_t.jpg')) return null;
  const dot = file.lastIndexOf('.');
  const stem = dot > 0 ? file.slice(0, dot) : file;
  u.pathname = u.pathname.slice(0, slash + 1) + stem + '_t.jpg';
  return u.toString();
}

const BUCKET_PATH = '/storage/v1/object/public/review-photos/';

/**
 * Where to read a stored photo (0067, the readiness review): only a file in the AUTHOR'S OWN folder
 * of the review-photos bucket, and always from our own storage at `base` (SUPABASE_URL), whatever
 * host the stored URL names. `entry_photos.photo_url` is client-written, so without this the
 * function would fetch any address an author typed in. `null` = not ours: never read, never offered.
 */
export function ownPhotoReadUrl(url: string, authorId: string, base: string): string | null {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  const at = u.pathname.indexOf(BUCKET_PATH);
  if (at < 0) return null;
  const path = u.pathname.slice(at + BUCKET_PATH.length);
  if (!path.toLowerCase().startsWith(`${authorId.toLowerCase()}/`) || path.includes('..') || /%(2e|2f|5c)/i.test(path)) return null;
  return `${base.replace(/\/+$/, '')}${BUCKET_PATH}${path}`;
}

function toBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

const IMAGE_TYPES: readonly ImageType[] = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

async function readImage(url: string, fetchImpl: typeof fetch, timeoutMs: number): Promise<{ data: string; media_type: ImageType } | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, { signal: controller.signal, redirect: 'error' });
    if (!res.ok) return null;
    if (Number(res.headers.get('content-length') ?? 0) > MAX_IMAGE_BYTES) return null;
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (!bytes.length || bytes.length > MAX_IMAGE_BYTES) return null;
    const type = (res.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
    return { data: toBase64(bytes), media_type: (IMAGE_TYPES as readonly string[]).includes(type) ? type as ImageType : 'image/jpeg' };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * The photos' bytes, read here rather than left for the API to fetch by URL (14 Oct: photos still
 * had no dish; a URL the API cannot fetch, or a 1600 px original that runs past the timeout, fails
 * the whole call silently). The thumbnail first, the original when there is none. A photo that
 * cannot be read is left out; the order is kept.
 */
export async function loadImages(
  photos: Photo[],
  opts: { fetchImpl?: typeof fetch; timeoutMs?: number } = {},
): Promise<LoadedPhoto[]> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const timeoutMs = opts.timeoutMs ?? IMAGE_TIMEOUT_MS;
  const read = await Promise.all(photos.map(async (p) => {
    const from = p.read ?? p.url;
    const thumb = thumbnailUrl(from);
    const image = (thumb ? await readImage(thumb, fetchImpl, timeoutMs) : null) ?? await readImage(from, fetchImpl, timeoutMs);
    return image ? { position: p.position, url: p.url, ...image } : null;
  }));
  return read.filter((p): p is LoadedPhoto => p !== null);
}

/**
 * What to do before any model is asked. `ask` lists only what is still open: the lines nobody
 * picked and the photos no picked line holds.
 *
 * A one-dish entry is asked too (26 Oct, Eamon: a photo of the people you were with is no photo of
 * the dish). Its `fallback` is the old answer, every photo is that dish, kept for when the model
 * cannot be asked (no key, over budget) or does not answer: then nothing is worse than before.
 */
export function plan(photos: Photo[], lines: Line[]):
  | { kind: 'nothing' }
  | { kind: 'ask'; photos: Photo[]; lines: Line[]; fallback: Match[] | null } {
  const held = new Set(lines.filter((l) => l.picked && l.photo_url).map((l) => l.photo_url!));
  const openPhotos = [...photos].sort((a, b) => a.position - b.position).filter((p) => !held.has(p.url)).slice(0, MAX_PHOTOS);
  const openLines = lines.filter((l) => !l.picked);
  if (!openPhotos.length || !openLines.length) return { kind: 'nothing' };
  const fallback = openLines.length === 1 && lines.length === 1
    ? openPhotos.map((p) => ({ review_id: openLines[0].review_id, photo_url: p.url }))
    : null;
  return { kind: 'ask', photos: openPhotos, lines: openLines, fallback };
}

export const TOOL = {
  name: 'match_photos',
  description: 'Say which dish each photo shows.',
  input_schema: {
    type: 'object',
    properties: {
      pairs: {
        type: 'array',
        description: 'One entry per listed dish clearly visible in a photo. A photo showing two dishes gets two entries. Leave out photos that show none.',
        items: {
          type: 'object',
          properties: {
            photo: { type: 'integer', description: 'The photo number, as labelled.' },
            dish: { type: 'integer', description: 'The dish number, as listed.' },
            box: {
              type: 'array',
              items: { type: 'integer' },
              description: 'Where this dish is in the photo: [left, top, right, bottom], each 0–1000 of the image width or height, tight around the food (and its plate or glass).',
            },
          },
          required: ['photo', 'dish', 'box'],
        },
      },
    },
    required: ['pairs'],
  },
} as const;

const SYSTEM = [
  'You match a diner\'s food photos to the dishes they wrote about in one restaurant visit.',
  'A dish may have several photos (two angles, before and after a bite), so pair every photo of it.',
  'A photo may show several listed dishes (a shared table, a burger and its fries): pair each one it',
  'clearly shows, with a box around where it is. A dish only glimpsed at the edge is not paired.',
  'Only the listed dishes count. A side, sauce or garnish served with a listed dish (the fries with a',
  'club sandwich) is part of that dish and inside its box, never a dish of its own unless it is listed.',
  'Use what is visibly on the plate or in the glass. If a photo shows no listed dish (the room, a menu,',
  'people, a dish not in the list), or you cannot tell, leave it out. Never guess.',
].join(' ');

export type ModelRequest = { url: string; headers: Record<string, string>; body: string };

/** Pure: the request. Each photo is labelled before it: its bytes when read, else its URL. */
export function buildRequest(opts: { apiKey: string; photos: Array<Photo | LoadedPhoto>; lines: Line[]; model?: SorterModel }): ModelRequest {
  const content: Array<Record<string, unknown>> = [];
  opts.photos.forEach((p, i) => {
    content.push({ type: 'text', text: `Photo ${i + 1}:` });
    const source = 'data' in p
      ? { type: 'base64', media_type: p.media_type, data: p.data }
      : { type: 'url', url: p.url };
    content.push({ type: 'image', source });
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
      max_tokens: 900,
      system: SYSTEM,
      tools: [TOOL],
      tool_choice: { type: 'tool', name: TOOL.name },
      messages: [{ role: 'user', content }],
    }),
  };
}

/** Dishes in one photo beyond this are not kept (a table of ten is no tag map). */
export const MAX_DISHES_PER_PHOTO = 6;
/** A box thinner than this (of the image) is noise, not a dish. */
const MIN_BOX_SIDE = 0.03;

/** Pure: the model's 0–1000 box as 0–1 fractions, or undefined when it is not a usable box. */
export function boxFrom(raw: unknown): Box | undefined {
  if (!Array.isArray(raw) || raw.length !== 4 || !raw.every((v) => typeof v === 'number' && Number.isFinite(v))) return undefined;
  const [l, t, r, b] = (raw as number[]).map((v) => Math.min(1000, Math.max(0, v)) / 1000);
  if (r - l < MIN_BOX_SIDE || b - t < MIN_BOX_SIDE) return undefined;
  return [l, t, r, b];
}

/**
 * Pure: the model's pairs, kept only where they name a real photo and a real line. One pairing per
 * (photo, line), first claim wins; a line may take several photos and a photo several lines.
 */
export function matchesFromResponse(payload: unknown, photos: Photo[], lines: Line[]): Match[] | null {
  const content = (payload as { content?: Array<Record<string, unknown>> })?.content;
  if (!Array.isArray(content)) return null;
  const call = content.find((b) => b?.type === 'tool_use' && b?.name === TOOL.name);
  const pairs = (call?.input as { pairs?: unknown } | undefined)?.pairs;
  if (!Array.isArray(pairs)) return null;
  const used = new Set<string>();
  const perPhoto = new Map<number, number>();
  const out: Match[] = [];
  for (const raw of pairs) {
    const p = (raw ?? {}) as { photo?: unknown; dish?: unknown; box?: unknown };
    const pi = typeof p.photo === 'number' && Number.isInteger(p.photo) ? p.photo - 1 : -1;
    const li = typeof p.dish === 'number' && Number.isInteger(p.dish) ? p.dish - 1 : -1;
    if (pi < 0 || pi >= photos.length || li < 0 || li >= lines.length) continue;
    const key = `${pi}:${li}`;
    if (used.has(key) || (perPhoto.get(pi) ?? 0) >= MAX_DISHES_PER_PHOTO) continue;
    used.add(key);
    perPhoto.set(pi, (perPhoto.get(pi) ?? 0) + 1);
    const box = boxFrom(p.box);
    out.push({ review_id: lines[li].review_id, photo_url: photos[pi].url, ...(box ? { box } : {}) });
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
  const photos = await loadImages(opts.photos, { fetchImpl: opts.fetchImpl });
  if (!photos.length) {
    console.error('match-photos: no photo could be read from storage');
    return null;
  }
  const req = buildRequest({ apiKey: String(opts.apiKey), photos, lines: opts.lines, model: opts.model });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? MATCH_TIMEOUT_MS);
  try {
    const res = await (opts.fetchImpl ?? fetch)(req.url, {
      method: 'POST', headers: req.headers, body: req.body, signal: controller.signal,
    });
    if (!res.ok) {
      console.error('match-photos: model answered', res.status, (await res.text().catch(() => '')).slice(0, 300));
      return null;
    }
    return matchesFromResponse(await res.json(), photos, opts.lines);
  } catch (e) {
    console.error('match-photos: model call failed:', e instanceof Error ? e.message : String(e));
    return null;
  } finally {
    clearTimeout(timer);
  }
}
