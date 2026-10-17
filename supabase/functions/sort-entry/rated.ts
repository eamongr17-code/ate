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

import { scalarLength } from './offsets.ts';
import { parseSixTokens, type SixToken } from './six.ts';
import type { SortItem } from './types.ts';

export type ScoreToken = SixToken;

/** `score_tokens` off a request body: null when absent (the old reading), else the valid spans. */
export function parseScoreTokens(raw: unknown): ScoreToken[] | null {
  return Array.isArray(raw) ? parseSixTokens(raw) : null;
}

/** Does this line's score evidence, where it sits, cover a marked span? */
function coversMark(item: SortItem, marks: readonly ScoreToken[]): boolean {
  const at = item.evidence_offset;
  if (typeof at !== 'number' || !item.score_evidence) return false;
  const end = at + scalarLength(item.score_evidence);
  return marks.some((m) => m.offset >= at && m.offset + m.length <= end);
}

/**
 * The lines that print: scored ones, and — when the client marked its pills — scored by a pill.
 * Items are copied, never mutated.
 */
export function keepRated(items: readonly SortItem[], marks: readonly ScoreToken[] | null): SortItem[] {
  return items
    .filter((it) => it.score !== null && (marks === null || coversMark(it, marks)))
    .map((it) => ({ ...it }));
}
