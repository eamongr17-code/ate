// supabase/functions/sort-entry/validate.ts
//
// POST-VALIDATION — applied to EVERY plan, in EVERY mode, before it is written.
// The stub parser is already conservative; the model is not trustworthy by
// construction. This module is the same gate for both, and it is deliberately
// identical in effect to apply_entry_sort's SQL checks (0021):
//
//   * a SCORE survives only if its evidence is a literal substring of the words AND
//     that evidence actually contains the number (DESIGN rule 7);
//   * a NOTE survives only if it is a literal substring of the words (rule 9);
//   * a DISH survives only if its name appears in the words or is already on the
//     matched restaurant's menu — a model may not conjure a dish nobody mentioned;
//   * an OFFSET survives only if the body really says that text there (./offsets.ts),
//     and is otherwise recomputed from the first occurrence, never guessed.
//
// Substring tests are CASE-SENSITIVE on purpose: Postgres `position(x in y)` is
// case-sensitive, so anything this module lets through on a looser test would be
// silently dropped by the database instead — a divergence that would be invisible
// until someone wondered where a score went.

import { findNumbers } from './parse.ts';
import { scalarLength, scalarOffset, verifiedScalarOffset } from './offsets.ts';
import type { SortItem, SortPlan } from './types.ts';

export const MAX_ITEMS = 24;

/** Does this literal slice of the user's words actually say this number? */
export function evidenceSupportsScore(evidence: string, score: number): boolean {
  if (!evidence) return false;
  return findNumbers(evidence).some((h) => Math.abs(h.value - score) < 1e-9);
}

const isHalfStep = (n: number) => n >= 0.5 && n <= 5 && Math.abs(n * 2 - Math.round(n * 2)) < 1e-9;

export type ValidateOptions = {
  body: string;
  knownDishes?: string[];
};

export function validateItem(item: SortItem, opts: ValidateOptions): SortItem | null {
  const body = opts.body ?? '';
  const known = opts.knownDishes ?? [];
  const knownByKey = new Map(known.map((d) => [d.trim().replace(/\s+/g, ' ').toLowerCase(), d.trim()]));

  let dish = String(item?.dish_name ?? '').trim().replace(/\s+/g, ' ');
  if (!dish || dish.length > 120) return null;

  // anti-hallucination: the name is either in the words or already on the menu.
  const inBody = body.toLowerCase().includes(dish.toLowerCase());
  const onMenu = knownByKey.get(dish.toLowerCase());
  if (!inBody && !onMenu) return null;

  // AN EXISTING DISH WINS ON A CASE-INSENSITIVE MATCH. Prose arrives lowercase
  // ("salmon roll"); the menu already says "Salmon roll" and that is the name the
  // receipt prints. (The database agrees independently: find_or_create_dish selects on
  // lower(name), so it resolves to the same row either way — this keeps the PLAN
  // honest about which dish it means.)
  if (onMenu && onMenu !== dish) dish = onMenu;

  // ---- score + evidence ---------------------------------------------------
  let score: number | null = typeof item.score === 'number' ? item.score : null;
  if (score !== null && !Number.isFinite(score)) score = null;
  if (score !== null && !isHalfStep(score)) score = null;

  let evidence: string | null = item.score_evidence ? String(item.score_evidence).trim() : null;
  if (score !== null) {
    if (!evidence || !body.includes(evidence) || !evidenceSupportsScore(evidence, score)) {
      score = null;
      evidence = null;
    }
  } else {
    evidence = null;
  }

  // ---- note ---------------------------------------------------------------
  let note: string | null = item.note ? String(item.note).trim() : null;
  if (note && !body.includes(note)) note = null;
  if (note && note.length > 240) {
    // trim from the END only, so it stays a substring
    const cut = note.slice(0, 240);
    const lastSpace = cut.lastIndexOf(' ');
    note = (lastSpace > 80 ? cut.slice(0, lastSpace) : cut).trim();
    if (!body.includes(note)) note = null;
  }
  if (note !== null && note.length === 0) note = null;

  // ---- WHERE: scalar offsets, verified or recomputed, never guessed --------
  // The parser supplies the exact occurrence it matched. A model supplies text only, so
  // the offset is recovered here from the first occurrence — the same fallback
  // apply_entry_sort uses, so TypeScript and SQL cannot disagree about the answer.
  const evidenceOffset = evidence ? verifiedScalarOffset(body, evidence, item?.evidence_offset) : null;

  let mentionText = typeof item?.mention_text === 'string' ? item.mention_text : null;
  let mentionOffset = mentionText ? verifiedScalarOffset(body, mentionText, item?.mention_offset) : null;
  if (mentionText === null || mentionOffset === null) {
    // recover it: the dish is named SOMEWHERE in the words (case may differ, which is
    // why this is a lowercase search and the slice — not the name — is what we keep).
    const at = body.toLowerCase().indexOf(dish.toLowerCase());
    if (at < 0) {
      mentionText = null;
      mentionOffset = null;
    } else {
      mentionText = body.slice(at, at + dish.length);
      mentionOffset = scalarOffset(body, at);
    }
  }
  if (mentionText !== null && scalarLength(mentionText) === 0) {
    mentionText = null;
    mentionOffset = null;
  }

  return {
    dish_name: dish,
    score,
    score_evidence: evidence,
    note,
    evidence_offset: evidenceOffset,
    mention_text: mentionText,
    mention_offset: mentionOffset,
  };
}

/**
 * Validate a whole plan: drop what cannot be proved, dedupe by dish (first mention
 * wins, but a scored duplicate promotes the score onto the kept line), cap the list.
 */
export function validatePlan(plan: SortPlan, opts: ValidateOptions): SortPlan {
  const items: SortItem[] = [];
  const index = new Map<string, number>();

  for (const raw of plan?.items ?? []) {
    const item = validateItem(raw, opts);
    if (!item) continue;
    const key = item.dish_name.toLowerCase();
    const at = index.get(key);
    if (at === undefined) {
      if (items.length >= MAX_ITEMS) continue;
      index.set(key, items.length);
      items.push(item);
      continue;
    }
    // same dish twice in one entry = one line. Keep the first, but take a score or a
    // note the first mention lacked.
    const kept = items[at];
    if (kept.score === null && item.score !== null) {
      kept.score = item.score;
      kept.score_evidence = item.score_evidence;
      kept.evidence_offset = item.evidence_offset;
    }
    if (!kept.note && item.note) kept.note = item.note;
    // the mention stays the FIRST one — the receipt's line order follows the words.
  }

  const place = plan?.place_query ? String(plan.place_query).trim() : null;
  const keptPlace = place && place.length >= 2 ? place : null;
  return {
    place_query: keptPlace,
    place_offset: verifiedScalarOffset(opts.body ?? '', keptPlace, plan?.place_offset),
    items,
  };
}
