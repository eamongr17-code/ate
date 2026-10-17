// supabase/functions/sort-entry/rated.ts
//
// ONLY RATED DISHES, AND ONLY RATINGS FROM THE SCORE KEY (17 Oct, Eamon).
//
//   POST /functions/v1/sort-entry
//   { "entry_id": …, "score_tokens": [{ "offset": 9, "length": 3 }] }   (also on "preview": true)
//
// Two rules, applied last, after every other gate:
//
//   1. A line with no score is not a dish. "Pad thai with crispy pork belly 4.5" names one dish;
//      the model used to print a second, unrated "Crispy Pork Belly". Nobody reviews a dish without
//      rating it, so an unrated line is a description of another dish and is dropped. Every client.
//   2. When the client sends `score_tokens` (every score pill in the words, scalar spans — the
//      composer no longer turns typed numbers into pills), a score survives only when its evidence
//      covers one of them. "gone in 4 minutes, the ragù <4.5>" scores the ragù 4.5 and nothing 4.
//      A client that sends no `score_tokens` (an older build, a re-sort that cannot know them) keeps
//      the old prose reading.
//
// `score_tokens` also feeds the secret 6 (./six.ts sixSpans keeps only the spans that say a six),
// so a client sends the same list as `six_tokens` for servers that predate this file.

import { scalarLength, scalarOffset, sliceScalars } from './offsets.ts';
import { parseSixTokens, type SixToken } from './six.ts';
import type { SortItem } from './types.ts';

export type ScoreToken = SixToken;

/** `score_tokens` off a request body: null when absent (the old reading), else the valid spans. */
export function parseScoreTokens(raw: unknown): ScoreToken[] | null {
  return Array.isArray(raw) ? parseSixTokens(raw) : null;
}

/**
 * Where this line's score evidence sits on a marked span — its own offset when that covers one, else
 * the first occurrence of the evidence that does — or null. A model returns evidence as text, so its
 * offset is the FIRST match: "Waited 4.5 hrs. Brisket <4.5>" pointed the brisket at the prose 4.5.
 */
function markedOffset(item: SortItem, marks: readonly ScoreToken[], body: string): number | null {
  const evidence = item.score_evidence;
  if (!evidence) return null;
  const len = scalarLength(evidence);
  const covers = (at: number) => marks.some((m) => m.offset >= at && m.offset + m.length <= at + len);
  if (typeof item.evidence_offset === 'number' && covers(item.evidence_offset)) return item.evidence_offset;
  for (let i = body.indexOf(evidence); i >= 0; i = body.indexOf(evidence, i + 1)) {
    const at = scalarOffset(body, i);
    if (covers(at)) return at;
  }
  return null;
}

/**
 * The lines that print: scored ones, and — when the client marked its pills — scored by a pill, with
 * the evidence moved onto it. Items are copied, never mutated.
 */
export function keepRated(items: readonly SortItem[], marks: readonly ScoreToken[] | null, body: string): SortItem[] {
  const out: SortItem[] = [];
  for (const it of items) {
    if (it.score === null) continue;
    if (marks === null) {
      out.push({ ...it });
      continue;
    }
    const at = markedOffset(it, marks, body ?? '');
    if (at !== null) out.push({ ...it, evidence_offset: at });
  }
  return out;
}

const PILL = /^(?:[0-5](?:\.[05])?|6(?:\.0)?)$/;

/**
 * A pill nobody claimed scores the line whose dish is named nearest BEFORE it, when that line has no
 * score yet — the rule the secret 6 follows (./six.ts attachSixTokens), now for every pill (17 Oct:
 * "Batch Brew, did the job <3.0>" printed Batch Brew unrated and the 3.0 as words). A pill is the
 * diner's own rating from the Score key, so it is never left on the floor. Items are copied.
 */
export function attachScoreTokens(items: readonly SortItem[], marks: readonly ScoreToken[] | null, body: string): SortItem[] {
  const out = items.map((it) => ({ ...it }));
  if (!marks) return out;
  const text = body ?? '';
  for (const m of marks) {
    const said = sliceScalars(text, m.offset, m.length);
    if (!PILL.test(said)) continue;
    const value = Number(said);
    if (value < 0.5) continue;
    const claimed = out.some((it) =>
      it.score !== null && typeof it.evidence_offset === 'number' && it.score_evidence &&
      it.evidence_offset <= m.offset && m.offset + m.length <= it.evidence_offset + scalarLength(it.score_evidence));
    if (claimed) continue;
    let owner = -1;
    for (let i = 0; i < out.length; i++) {
      const at = out[i].mention_offset;
      if (typeof at !== 'number' || at > m.offset) continue;
      if (owner < 0 || at > (out[owner].mention_offset as number)) owner = i;
    }
    if (owner < 0 || out[owner].score !== null) continue;
    out[owner].score = value;
    out[owner].score_evidence = said;
    out[owner].evidence_offset = m.offset;
  }
  return out;
}
