// supabase/functions/sort-entry/six.ts
//
// THE SECRET 6 (round 4, migration 0041). Scores are 0.5-5.0 in half steps, and above them sits a
// 6 — the diner's "better than a five". Like a dietary tag, a 6 is ONLY ever the user's mark:
//
//   POST /functions/v1/sort-entry
//   { "entry_id": …, "six_tokens": [{ "offset": 9, "length": 1 }] }      (also on "preview": true)
//
// Offsets and lengths are UNICODE SCALARS into the body (./offsets.ts). A marked span must SAY a
// six — "6" or "6.0", standing alone (not the 6 of "16" or "6.5") — or it is dropped. From there:
//
//   * the parser treats each marked span as a self-evident number worth 6, so "Tiramisu 6" finds
//     its dish exactly the way "Tiramisu 4.5" does (parseEntry's `sixSpans`);
//   * validate.ts keeps a score of 6 only when its evidence covers a marked span — in every mode,
//     so a model that reads "we were 6" as a score is overruled;
//   * attachSixTokens gives a marked six the parser or model left unclaimed to the dish named
//     nearest before it, when that line has no score of its own.
//
// Nothing else makes a 6. The parser's own number grammar stops at 5, so a TYPED "6" in the words
// is never a score, and the model is told as much.

import { scalarLength, scalarOffset, sliceScalars } from './offsets.ts';
import type { SortItem } from './types.ts';

/** A client-marked span of the body: 0-based scalar offset + scalar length. */
export type SixToken = { offset: number; length: number };

/** A marked span that verifiably says a six: scalar offset/length, UTF-16 [start, end), its text. */
export type SixSpan = { offset: number; length: number; start: number; end: number; text: string };

/** More sixes than dishes is not an honest entry; MAX_ITEMS is 24. */
export const MAX_SIX_TOKENS = 24;

const SIX_TEXT = /^6(?:\.0)?$/;

/** Read `six_tokens` off a request body. Anything malformed is dropped, never coerced. */
export function parseSixTokens(raw: unknown): SixToken[] {
  if (!Array.isArray(raw)) return [];
  const out: SixToken[] = [];
  for (const t of raw.slice(0, MAX_SIX_TOKENS)) {
    const offset = (t as { offset?: unknown })?.offset;
    const length = (t as { length?: unknown })?.length;
    if (
      typeof offset === 'number' && Number.isInteger(offset) && offset >= 0 &&
      typeof length === 'number' && Number.isInteger(length) && length > 0 && length <= 3
    ) {
      out.push({ offset, length });
    }
  }
  return out;
}

/** The marked spans that really say a lone six, in body order, deduped. */
export function sixSpans(body: string, tokens: readonly SixToken[]): SixSpan[] {
  const text = body ?? '';
  const total = scalarLength(text);
  const seen = new Set<number>();
  const out: SixSpan[] = [];
  for (const t of tokens) {
    if (t.offset + t.length > total || seen.has(t.offset)) continue;
    const said = sliceScalars(text, t.offset, t.length);
    if (!SIX_TEXT.test(said)) continue;
    const start = [...text].slice(0, t.offset).join('').length;
    const end = start + said.length;
    // standing alone: not the tail of "16" / "1.6", not the head of "65" / "6.5"
    if (/[\d.]/.test(text[start - 1] ?? '') || /^\d|^\.\d/.test(text.slice(end))) continue;
    seen.add(t.offset);
    out.push({ offset: t.offset, length: t.length, start, end, text: said });
  }
  return out.sort((a, b) => a.offset - b.offset);
}

/**
 * Where a score of 6 with this evidence sits — the scalar offset of an occurrence of `evidence` that
 * COVERS a marked six — or null, and then the 6 does not survive. The claimed offset is tried first;
 * then every occurrence in body order (a model returns text only).
 */
export function sixEvidenceOffset(
  body: string,
  evidence: string,
  claimed: number | null | undefined,
  spans: readonly SixSpan[],
): number | null {
  if (!evidence || !spans.length) return null;
  const len = scalarLength(evidence);
  const covers = (at: number) => spans.some((s) => s.offset >= at && s.offset + s.length <= at + len);
  if (typeof claimed === 'number' && Number.isInteger(claimed) && claimed >= 0 &&
      sliceScalars(body, claimed, len) === evidence && covers(claimed)) {
    return claimed;
  }
  for (let i = body.indexOf(evidence); i >= 0; i = body.indexOf(evidence, i + 1)) {
    const at = scalarOffset(body, i);
    if (covers(at)) return at;
  }
  return null;
}

/**
 * A marked six nobody claimed goes to the line whose dish is named nearest BEFORE it — by span,
 * never by name, the rule tags follow — and only when that line has no score yet. Items are
 * copied, never mutated.
 */
export function attachSixTokens(items: SortItem[], spans: readonly SixSpan[]): SortItem[] {
  const out = items.map((it) => ({ ...it }));
  for (const s of spans) {
    const claimed = out.some((it) =>
      it.score === 6 && typeof it.evidence_offset === 'number' && it.score_evidence &&
      it.evidence_offset <= s.offset && s.offset + s.length <= it.evidence_offset + scalarLength(it.score_evidence));
    if (claimed) continue;
    let owner = -1;
    for (let i = 0; i < out.length; i++) {
      const at = out[i].mention_offset;
      if (typeof at !== 'number' || at > s.offset) continue;
      if (owner < 0 || at > (out[owner].mention_offset as number)) owner = i;
    }
    if (owner < 0 || out[owner].score !== null) continue;
    out[owner].score = 6;
    out[owner].score_evidence = s.text;
    out[owner].evidence_offset = s.offset;
  }
  return out;
}

/** A stored line that held a 6: its dish, where it was named, its evidence and where that sat. */
export type PriorSix = {
  dish_name: string | null;
  mention_text: string | null;
  mention_offset: number | null;
  score_evidence: string | null;
  evidence_offset: number | null;
};

const LONE_SIX = /(?<![\d.])6(?:\.0)?(?!\d|\.\d)/;

/**
 * A RE-SORT KEEPS A MARKED 6 (0044), keyed to the LINE. Three client paths re-sort without
 * `six_tokens` (a tag added in Entry edit, "Print it again", the retry) and the sort rebuilds every
 * uncorrected line. A rebuilt line that matches a predecessor which held a 6 — same dish name or same
 * mention, first unclaimed wins (the matching tags use) — and arrives UNSCORED keeps the 6 when its own
 * score-evidence span, the same distance from THIS line's mention, still reads the evidence as a lone
 * 6. So a word typed earlier keeps it; a 6 changed to a 4 prints 4 (the line already has a score); the
 * dish removed takes it along. An earlier mark preserved, never a 6 read off the prose.
 * apply_entry_sort carries by the same rule (the rule of record); this keeps the returned plan honest.
 * Items are copied, never mutated.
 */
export function carryPriorSixes(items: SortItem[], body: string, prior: readonly PriorSix[]): SortItem[] {
  const text = body ?? '';
  const scalars = [...text];
  const claimed = new Set<number>();
  return items.map((item) => {
    const it = { ...item };
    const name = it.dish_name.toLowerCase();
    const mention = it.mention_text?.toLowerCase() ?? null;
    const at = prior.findIndex((p, i) =>
      !claimed.has(i) &&
      ((p.dish_name ?? '').trim().toLowerCase() === name || (mention !== null && p.mention_text?.toLowerCase() === mention)));
    if (at < 0) return it;
    claimed.add(at);
    const p = prior[at];
    const ev = p.score_evidence;
    if (it.score !== null || typeof it.mention_offset !== 'number' || !ev || !LONE_SIX.test(ev)) return it;
    if (typeof p.evidence_offset !== 'number' || typeof p.mention_offset !== 'number') return it;
    const pos = it.mention_offset + p.evidence_offset - p.mention_offset;
    const len = scalarLength(ev);
    if (pos < 0 || sliceScalars(text, pos, len) !== ev) return it;
    // still a lone six where it sits: not the tail of "16" nor the head of "6.5"
    if (/[\d.]/.test(scalars[pos - 1] ?? '') || /^(?:\d|\.\d)/.test(scalars.slice(pos + len, pos + len + 2).join(''))) {
      return it;
    }
    it.score = 6;
    it.score_evidence = ev;
    it.evidence_offset = pos;
    return it;
  });
}

/** The marked sixes with the words just before each — what the model is told (not offsets). */
export function sixMarks(body: string, spans: readonly SixSpan[]): string[] {
  return spans.map((s) => {
    const from = Math.max(0, s.start - 40);
    const lead = body.slice(from, s.start);
    const cut = from > 0 ? lead.replace(/^\S*\s/, '') : lead; // don't start mid-word
    return `${cut}${s.text}`.trim();
  });
}
