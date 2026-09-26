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

import { scalarLength, sliceScalars } from './offsets.ts';
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
    const start = scalars.slice(0, t.offset).join('').length;
    const end = start + scalars.slice(t.offset, t.offset + t.length).join('').length;
    spans.push([start, end]);
  }
  return spans;
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
  const end = at + note.length;
  let cursor = at;
  let cut = false;
  for (;;) {
    while (cursor < end && /[\s,.;:…—–-]/.test(body[cursor])) cursor++;
    const span = spans.find(([s, e]) => s === cursor && e <= end);
    if (!span) break;
    cursor = span[1];
    cut = true;
  }
  if (!cut) return note;
  const rest = body.slice(cursor, end).replace(/^[\s,.;:…—–-]+/, '').trim();
  return rest.length ? rest : null;
}

/** A model may propose a tag word as a dish ("GF"). A marked tag is never a dish. */
function isTagWord(item: SortItem, spans: Array<[number, number]>, body: string): boolean {
  if (typeof item.mention_offset !== 'number' || !item.mention_text) return false;
  const s = utf16Index(body, item.mention_offset);
  const e = s + item.mention_text.length;
  return spans.some(([a, b]) => a <= s && e <= b);
}

/**
 * Put each marked token's codes on the line it follows. Every returned item carries `tags`
 * (possibly `[]`), canonical. Items are copied, never mutated.
 */
export function attachTagTokens(items: SortItem[], body: string, tokens: TagToken[]): SortItem[] {
  const spans = tagTokenSpans(body, tokens);
  const out = items
    .filter((it) => !isTagWord(it, spans, body))
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
