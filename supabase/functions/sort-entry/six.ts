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

/** A stored line's score evidence and where it sat (reviews row or parked-plan item). */
export type PriorSix = { score_evidence: string | null; evidence_offset: number | null };

/**
 * A RE-SORT KEEPS A MARKED 6 (0044). Three client paths re-sort without `six_tokens` (a tag added in
 * Entry edit, "Print it again", the retry), and the sort rebuilds every uncorrected line — so a 6 the
 * user marked earlier would be wiped. Each prior line that held a 6 becomes a marked token again, but
 * ONLY while the body still says its evidence at the SAME span: an earlier mark, preserved — never a
 * 6 read off the prose. A 6 edited out of the words, or moved by an edit before it, is gone.
 * apply_entry_sort carries by the same rule (the rule of record); this keeps the returned plan honest.
 */
export function carriedSixTokens(body: string, prior: readonly PriorSix[]): SixToken[] {
  const out: SixToken[] = [];
  for (const p of prior) {
    const ev = p?.score_evidence;
    const off = p?.evidence_offset;
    if (!ev || typeof off !== 'number' || !Number.isInteger(off) || off < 0) continue;
    if (sliceScalars(body ?? '', off, scalarLength(ev)) !== ev) continue;
    let last: RegExpExecArray | null = null;
    const lone = /(?<![\d.])6(?:\.0)?(?!\d|\.\d)/g;
    for (let m = lone.exec(ev); m; m = lone.exec(ev)) last = m;
    if (!last) continue;
    out.push({ offset: off + scalarLength(ev.slice(0, last.index)), length: scalarLength(last[0]) });
  }
  return out;
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
