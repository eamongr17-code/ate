// supabase/functions/sort-entry/tags.ts
//
// DIETARY TAGS on a receipt line (migration 0036): gf · df · v · vg · nf.
//
// A tag is the USER'S, like a score. The sorter never infers one: "the waiter said it was
// gluten free" in the prose tags nothing. The ONLY way a tag reaches the sorter is a span of
// the body the CLIENT marked as a tag token (the composer's inline chip) and sent alongside
// the sort request:
//
//   POST /functions/v1/sort-entry
//   { "entry_id": …, "force": …, "tag_tokens": [{ "offset": 23, "length": 2 }] }
//
// Offsets and lengths are UNICODE SCALARS into `entries.body`, the unit of every other
// offset on this contract (./offsets.ts). Each marked span is read here, recognised against a
// small closed vocabulary ("GF", "gluten free", "vegan", "GF/DF" …) and attached to the dish
// line it FOLLOWS — the nearest dish mention at or before it. A span that says nothing we
// recognise, points outside the body, or precedes every dish is dropped, never guessed at.
//
// The plan's items never carry tags from the parser or the model: validateItem rebuilds each
// item without them, and attachTagTokens is the only thing that sets `tags` afterwards. So
// "never invents a tag" holds in every sorter mode by construction.

import { scalarLength, scalarOffset, sliceScalars } from './offsets.ts';
import type { SortItem } from './types.ts';

/** The closed set, in its canonical order. Matches `reviews_tags_closed_set` (0036). */
export const TAG_CODES = ['gf', 'df', 'v', 'vg', 'nf'] as const;
export type TagCode = typeof TAG_CODES[number];

/** A client-marked span of the body: 0-based scalar offset + scalar length. */
export type TagToken = { offset: number; length: number };

/** At most this many tokens are read per sort. The composer cannot produce more honestly. */
export const MAX_TAG_TOKENS = 96;

/**
 * What a marked token may SAY. Deliberately small: every entry is a phrase a menu or a
 * diner actually writes for that code. Keys are normalised (lower case, hyphens and runs of
 * whitespace collapsed to one space) — see normaliseWord.
 */
const WORDS: Record<string, TagCode> = {
  'gf': 'gf', 'gluten free': 'gf', 'glutenfree': 'gf',
  'df': 'df', 'dairy free': 'df', 'dairyfree': 'df',
  'v': 'v', 'veg': 'v', 'vego': 'v', 'veggie': 'v', 'vegetarian': 'v',
  'vg': 'vg', 've': 'vg', 'vegan': 'vg',
  'nf': 'nf', 'nut free': 'nf', 'nutfree': 'nf',
};

function normaliseWord(s: string): string {
  return s
    .toLowerCase()
    .replace(/[-‐‑‒–—_]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    // surrounding brackets and punctuation: "(GF)", "GF.", "*vegan*"
    .replace(/^[\s()[\]{}*.,:;!?'"“”‘’]+|[\s()[\]{}*.,:;!?'"“”‘’]+$/g, '')
    .trim();
}

/** Canonical form: known codes only, deduped, in TAG_CODES order. */
export function canonicalTags(codes: Iterable<string>): TagCode[] {
  const set = new Set<string>();
  for (const c of codes) set.add(String(c ?? '').trim().toLowerCase());
  return TAG_CODES.filter((c) => set.has(c));
}

/**
 * The codes one marked token says. A token may carry several ("GF/DF", "gf, vg",
 * "vegan & nut free"); each part must be a vocabulary phrase on its own. Unknown parts are
 * ignored — a marked "GF pasta" says nothing, because "gf pasta" is not a tag.
 */
export function tagCodesFor(text: string): TagCode[] {
  const whole = WORDS[normaliseWord(text)];
  if (whole) return [whole];
  const parts = String(text ?? '').split(/\s*(?:[\/,&+|]|\band\b)\s*/i);
  const found: string[] = [];
  for (const part of parts) {
    const code = WORDS[normaliseWord(part)];
    if (code) found.push(code);
  }
  return canonicalTags(found);
}

/** Read `tag_tokens` off a request body. Anything malformed is dropped, never coerced. */
export function parseTagTokens(raw: unknown): TagToken[] {
  if (!Array.isArray(raw)) return [];
  const out: TagToken[] = [];
  for (const t of raw.slice(0, MAX_TAG_TOKENS)) {
    const offset = (t as { offset?: unknown })?.offset;
    const length = (t as { length?: unknown })?.length;
    if (
      typeof offset === 'number' && Number.isInteger(offset) && offset >= 0 &&
      typeof length === 'number' && Number.isInteger(length) && length > 0 && length <= 40
    ) {
      out.push({ offset, length });
    }
  }
  return out;
}

/**
 * UTF-16 [start, end) spans of the tokens, for the parser's `excludeSpans`: a tag word is
 * never a dish, nor the front half of one ("GF Salad 3.5" is the Salad).
 */
export function tagTokenSpans(body: string, tokens: TagToken[]): Array<[number, number]> {
  const scalars = [...body];
  const spans: Array<[number, number]> = [];
  for (const t of tokens) {
    if (t.offset + t.length > scalars.length) continue;
    // only a span that SAYS a tag is fenced: a mis-marked "Pasta" must not erase the dish.
    if (!tagCodesFor(scalars.slice(t.offset, t.offset + t.length).join('')).length) continue;
    const start = scalars.slice(0, t.offset).join('').length;
    const end = start + scalars.slice(t.offset, t.offset + t.length).join('').length;
    spans.push([start, end]);
  }
  return spans;
}

/** The marked words themselves, in body order — what the model is told are tags, not dishes. */
export function tagTokenWords(body: string, tokens: TagToken[]): string[] {
  const bodyLength = scalarLength(body ?? '');
  return [...tokens]
    .filter((t) => t.offset + t.length <= bodyLength)
    .sort((a, b) => a.offset - b.offset)
    .map((t) => sliceScalars(body, t.offset, t.length))
    .filter((w) => tagCodesFor(w).length > 0);
}

/** UTF-16 index of a scalar offset (the inverse of offsets.ts's scalarOffset). */
function utf16Index(body: string, scalar: number): number {
  return [...body].slice(0, scalar).join('').length;
}

/**
 * A note that OPENS with a marked tag ("tiramisu 4 DF, loved it" → "DF, loved it") prints
 * the chip twice. Cut the leading tokens off; what is left is still a verbatim slice of the
 * body (rule 9), and a note that was nothing but tags becomes null.
 */
function trimLeadingTags(item: SortItem, body: string, spans: Array<[number, number]>): string | null {
  const note = item.note;
  if (!note) return note ?? null;
  const from = typeof item.mention_offset === 'number' ? utf16Index(body, item.mention_offset) : 0;
  let at = body.indexOf(note, from);
  if (at < 0) at = body.indexOf(note);
  if (at < 0) return note;
  let end = at + note.length;
  let cursor = at;
  let cut = false;
  for (;;) {
    while (cursor < end && /[\s,.;:…—–-]/.test(body[cursor])) cursor++;
    const span = spans.find(([s, e]) => s === cursor && e <= end);
    if (!span) break;
    cursor = span[1];
    cut = true;
  }
  // …and a note that ENDS on one ("loved it GF" from a model) — same cut from the other side.
  for (;;) {
    let scan = end;
    while (scan > cursor && /[\s,.;:…—–-]/.test(body[scan - 1])) scan--;
    const span = spans.find(([s, e]) => e === scan && s >= cursor);
    if (!span) break;
    end = span[0];
    cut = true;
  }
  if (!cut) return note;
  const rest = body.slice(cursor, end).replace(/^[\s,.;:…—–-]+/, '').replace(/[\s,;:—–-]+$/, '').trim();
  return rest.length ? rest : null;
}

/** Punctuation and joiners that are never part of a dish name at either end of a run. */
const EDGE = /[\s,.;:!?…—–\-()/&+|]/u;

/**
 * A MODEL does not honour excludeSpans: it may name "GF Salad" or "Pasta GF", or offer "GF" as a
 * dish. Cut every tag span out of the item's mention and keep the longest remaining run as the
 * dish ("GF Salad" → "Salad", "Pasta GF" → "Pasta"); a mention that was only tags is dropped. The
 * name is re-derived from the body slice (the menu's spelling when it is on the menu), so the
 * mention stays a verbatim slice at a true offset. An item with no verified mention (a menu dish
 * the model named without quoting) has no span to compare and is left as it is.
 */
function stripTagSpans(
  item: SortItem,
  body: string,
  spans: Array<[number, number]>,
  knownByKey: Map<string, string>,
): SortItem | null {
  if (typeof item.mention_offset !== 'number' || !item.mention_text) return item;
  const s = utf16Index(body, item.mention_offset);
  const e = s + item.mention_text.length;
  if (body.slice(s, e) !== item.mention_text) return item;
  const cuts = spans.filter(([a, b]) => a < e && b > s).sort((x, y) => x[0] - y[0]);
  if (!cuts.length) return item;

  // the runs of the mention that no tag span covers, trimmed of edge punctuation
  const runs: Array<[number, number]> = [];
  let cursor = s;
  for (const [a, b] of cuts) {
    if (a > cursor) runs.push([cursor, Math.min(a, e)]);
    cursor = Math.max(cursor, b);
  }
  if (cursor < e) runs.push([cursor, e]);

  let best: [number, number] | null = null;
  for (let [a, b] of runs) {
    while (a < b && EDGE.test(body[a])) a++;
    while (b > a && EDGE.test(body[b - 1])) b--;
    if (!/[\p{L}\p{N}]/u.test(body.slice(a, b))) continue;
    if (!best || b - a > best[1] - best[0]) best = [a, b];
  }
  if (!best) return null;

  const slice = body.slice(best[0], best[1]);
  const name = slice.replace(/\s+/g, ' ');
  return {
    ...item,
    dish_name: knownByKey.get(name.toLowerCase()) ?? name,
    mention_text: slice,
    mention_offset: scalarOffset(body, best[0]),
  };
}

/** After stripping, "Pasta" and "Pasta GF" are one dish: first line wins, gaps are filled. */
function mergeSameDish(items: SortItem[]): SortItem[] {
  const out: SortItem[] = [];
  const index = new Map<string, number>();
  for (const it of items) {
    const key = it.dish_name.toLowerCase();
    const at = index.get(key);
    if (at === undefined) {
      index.set(key, out.length);
      out.push(it);
      continue;
    }
    const kept = out[at];
    if (kept.score === null && it.score !== null) {
      kept.score = it.score;
      kept.score_evidence = it.score_evidence;
      kept.evidence_offset = it.evidence_offset;
    }
    if (!kept.note && it.note) kept.note = it.note;
  }
  return out;
}

/**
 * Put each marked token's codes on the line it follows — by SPAN, never by name: the item whose
 * mention starts nearest before the token. Tag words are first cut out of every mention (a model
 * may have swallowed them), so a tag can never name a dish or mint one. Every returned item
 * carries `tags` (possibly `[]`), canonical. Items are copied, never mutated.
 */
export function attachTagTokens(
  items: SortItem[],
  body: string,
  tokens: TagToken[],
  knownDishes: string[] = [],
): SortItem[] {
  const spans = tagTokenSpans(body, tokens);
  const knownByKey = new Map(knownDishes.map((d) => [d.trim().replace(/\s+/g, ' ').toLowerCase(), d.trim()]));
  const stripped: SortItem[] = [];
  for (const it of items) {
    const kept = spans.length ? stripTagSpans({ ...it }, body, spans, knownByKey) : { ...it };
    if (kept) stripped.push(kept);
  }
  const out = mergeSameDish(stripped)
    .map((it) => ({ ...it, note: spans.length ? trimLeadingTags(it, body, spans) : it.note, tags: [] as string[] }));
  const bodyLength = scalarLength(body ?? '');
  for (const t of tokens) {
    if (t.offset + t.length > bodyLength) continue;
    const codes = tagCodesFor(sliceScalars(body, t.offset, t.length));
    if (!codes.length) continue;
    // the line whose dish is named nearest BEFORE the token ("Margherita 4.5 GF").
    let owner = -1;
    for (let i = 0; i < out.length; i++) {
      const at = out[i].mention_offset;
      if (typeof at !== 'number' || at > t.offset) continue;
      if (owner < 0 || at > (out[owner].mention_offset as number)) owner = i;
    }
    if (owner < 0) continue;
    out[owner].tags = canonicalTags([...(out[owner].tags ?? []), ...codes]);
  }
  return out;
}
