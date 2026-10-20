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
//     and is otherwise recomputed from the first occurrence, never guessed;
//   * a 6 (0041, the secret score) survives only if its evidence covers a span the CLIENT
//     marked as a six (./six.ts) — the one score above 5, and never one read off the prose.
//
// Substring tests are CASE-SENSITIVE on purpose: Postgres `position(x in y)` is
// case-sensitive, so anything this module lets through on a looser test would be
// silently dropped by the database instead — a divergence that would be invisible
// until someone wondered where a score went.

import { findNumbers } from './parse.ts';
import { scalarLength, scalarOffset, verifiedScalarOffset } from './offsets.ts';
import { sixEvidenceOffset, type SixSpan } from './six.ts';
import { matchKey, sameDishGate } from './same-dish.ts';
import { cleanStyles } from './styles.ts';
import type { SortItem, SortPlan } from './types.ts';

export const MAX_ITEMS = 24;

/** Does this literal slice of the user's words actually say this number? */
export function evidenceSupportsScore(evidence: string, score: number): boolean {
  if (!evidence) return false;
  return findNumbers(evidence).some((h) => Math.abs(h.value - score) < 1e-9);
}

/**
 * The name a receipt prints (10 Oct, Eamon: "Gin & tonic", not "Gin & tonics"; 13 Oct, Eamon: the
 * headings capitalised, "Fish Stir Fry", not "Fish stir fry"). `proposed` is the model's
 * printed_name; it is used only when it is plainly the same dish as `spoken` — same first letters,
 * about the same length — so the model can fix a number and the capitals but never rename a dish.
 * Without one (the stub, or a model that left it out) the words' spelling is kept. Either way the
 * name is printed in title case (titleCase).
 */
export function printedName(spoken: string, proposed?: string | null): string {
  const clean = (s: string) => s.trim().replace(/\s+/g, ' ');
  // Letters only, '&' read as 'and', so a swap of the one for the other is the same dish.
  const stem = (s: string) => clean(s).toLowerCase().replace(/&/g, 'and').replace(/[^\p{L}\p{N}]+/gu, '');
  if (typeof proposed === 'string') {
    const p = clean(proposed);
    const a = stem(spoken);
    const b = stem(p);
    const sameDish = p.length > 0 && p.length <= 120 && a.length >= 2 && b.length >= 2 &&
      a.slice(0, 3) === b.slice(0, 3) && Math.abs(a.length - b.length) <= Math.max(3, Math.ceil(a.length / 4));
    if (sameDish) return titleCase(p);
  }
  return titleCase(clean(spoken));
}

/**
 * Small words stay lower case inside a name ("Cacio e Pepe", "Tagliatelle al Ragù", "Fish & Chips");
 * the first word is always capitalised. Mirrors public.dish_title (0065), which prints the same
 * names in the database.
 */
const MINOR_WORDS = new Set([
  'a', 'an', 'and', '&', 'or', 'of', 'with', 'on', 'in', 'the', 'to', 'for', 'n',
  'al', 'alla', 'alle', 'di', 'da', 'de', 'del', 'della', 'e', 'con', 'y', 'en', 'au', 'aux', 'à',
]);

/**
 * Title case, the way a menu prints a dish: every word's first letter capital ("Fish Stir Fry",
 * "Stir-Fry" across a hyphen), small words lower case after the first. A word with a capital of its
 * own past its first letter ("McFlurry", "BBQ") is somebody's spelling and stays — unless the whole
 * name is in capitals, which carries no meaning ("CHICKEN PARMA" → "Chicken Parma").
 */
export function titleCase(name: string): string {
  if (!name) return name;
  const shouting = !/\p{Ll}/u.test(name);
  const base = shouting ? name.toLowerCase() : name;
  const capital = (part: string) => {
    const first = [...part][0];
    if (!first) return part;
    const rest = part.slice(first.length);
    return /\p{Lu}/u.test(rest) ? part : first.toUpperCase() + rest;
  };
  return base.split(' ').map((word, i) => {
    if (i > 0 && MINOR_WORDS.has(word.toLowerCase())) return word.toLowerCase();
    return word.split('-').map(capital).join('-');
  }).join(' ');
}

/** Words that join a dish (or its score) to the comment after it; never the start of a note. */
const NOTE_GLUE = /^(?:[\s,;:.\-–—]+|(?:and|but|was|were|is|are|which|that|tho|though)\b)+/iu;

/**
 * The note as the receipt prints it under the dish: what was said AFTER the dish and its score.
 * A model often quotes the whole clause ("was a 4.5, the best thing all week", "is a solid four");
 * this keeps only what follows the dish name and the score's evidence, then drops the leading glue
 * ("was", "and", ","). It only ever cuts from the ends, so the note stays a literal slice of the
 * words; nothing left means no note.
 */
export function tidyNote(note: string, at: { dish?: string | null; evidence?: string | null }): string | null {
  let n = note;
  const after = (needle: string | null | undefined, keepIfEmpty: boolean) => {
    if (!needle) return;
    const i = n.toLowerCase().indexOf(needle.toLowerCase());
    if (i < 0) return;
    const rest = n.slice(i + needle.length);
    // a dish named at the END of its own note ("then we shared a second pappardelle") is
    // part of the comment; a score at the end of it is not
    if (keepIfEmpty && !/\p{L}{2}/u.test(rest)) return;
    n = rest;
  };
  after(at.dish, true);
  after(at.evidence, false);
  n = n.replace(NOTE_GLUE, '').replace(/[\s,;:\-–—]+$/u, '').trim();
  // a lone number or "out of five" left over is part of the score, not a comment
  return n.length === 0 || /^[\d.\/\s]+$/.test(n) ? null : n;
}

/** Cut a note where it runs on into ANOTHER dish of the same entry ("4 and the tiramisu was a 3"). */
function cutAtOtherDishes(note: string, others: string[]): string | null {
  const lower = note.toLowerCase();
  let end = note.length;
  for (const o of others) {
    const i = o.length >= 3 ? lower.indexOf(o.toLowerCase()) : -1;
    if (i >= 0 && i < end) end = i;
  }
  if (end === note.length) return note;
  const cut = note.slice(0, end).replace(/[\s,;:\-–—]+$/u, '').replace(/\s+(?:and|the|then|with)$/iu, '').replace(/\s+(?:and|the)$/iu, '').trim();
  return cut.length ? cut : null;
}

const isHalfStep = (n: number) => n >= 0.5 && n <= 5 && Math.abs(n * 2 - Math.round(n * 2)) < 1e-9;

/** The one menu dish with this name's match key (./same-dish.ts), or null (none, or a duplicate pair: the oldest-first DB pick is not ours to guess). */
function uniqueByKey(menu: string[], name: string): string | null {
  const k = matchKey(name);
  if (!k) return null;
  const hits = menu.filter((m) => matchKey(m) === k);
  return hits.length === 1 ? hits[0].trim() : null;
}

export type ValidateOptions = {
  body: string;
  knownDishes?: string[];
  /**
   * The spelling keys of every dish this plan names in the words (validatePlan fills it). A `same_as`
   * onto one of them is refused: the entry already names that dish on a line of its own.
   */
  planKeys?: Set<string>;
  /** The client-marked sixes (./six.ts sixSpans). Without them no 6 survives. */
  sixSpans?: SixSpan[];
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

  // The words' own spelling: where the mention is found, whatever the receipt prints.
  const spoken = dish;

  // AN EXISTING DISH WINS ON A CASE-INSENSITIVE MATCH. Prose arrives lowercase
  // ("salmon roll"); the menu already says "Salmon roll" and that is the name the
  // receipt prints. (The database agrees independently: find_or_create_dish selects on
  // lower(name), so it resolves to the same row either way — this keeps the PLAN
  // honest about which dish it means.)
  //
  // Otherwise the receipt prints the name AS A MENU WOULD (10 Oct, Eamon): the model's
  // printed_name when it is plainly the same dish, else the words, in title case.
  //
  // SAME DISH, OTHER WORDS (18 Oct, Eamon; ./same-dish.ts). Off an exact match, a menu dish with the
  // same match key is the same dish ("Gnocchis", "Mac and Cheese" for "Mac & Cheese", "Chicken Pad
  // Thai" for "Pad Thai with Chicken"), as
  // find_or_create_dish (0071) would resolve it anyway. Past that, only the model's `same_as` can name
  // a menu dish, and only through sameDishGate: the words fit, say more than a category, and fit no
  // other dish there. Never onto a dish another line of this entry names: the diner told them apart.
  const byKey = onMenu ? null : uniqueByKey(known, dish);
  const sameAs = onMenu || byKey || typeof item?.same_as !== 'string'
    ? null
    : sameDishGate(dish, item.same_as, known);
  const claimed = sameAs !== null && (opts.planKeys?.has(matchKey(sameAs)) ?? false);
  if (onMenu && onMenu !== dish) dish = onMenu;
  else if (byKey) dish = byKey;
  else if (sameAs && !claimed) dish = sameAs;
  else dish = printedName(dish, item?.printed_name);

  // ---- score + evidence ---------------------------------------------------
  let score: number | null = typeof item.score === 'number' ? item.score : null;
  if (score !== null && !Number.isFinite(score)) score = null;
  const six = score === 6;
  if (score !== null && !six && !isHalfStep(score)) score = null;

  let evidence: string | null = item.score_evidence ? String(item.score_evidence).trim() : null;
  let sixOffset: number | null = null;
  if (score !== null && six) {
    // THE SECRET 6: only on a span the client marked, wherever the evidence sits.
    sixOffset = evidence && body.includes(evidence)
      ? sixEvidenceOffset(body, evidence, item?.evidence_offset, opts.sixSpans ?? [])
      : null;
    if (sixOffset === null) {
      score = null;
      evidence = null;
    }
  } else if (score !== null) {
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
  if (note !== null) note = tidyNote(note, { dish: spoken, evidence });

  // ---- WHERE: scalar offsets, verified or recomputed, never guessed --------
  // The parser supplies the exact occurrence it matched. A model supplies text only, so
  // the offset is recovered here from the first occurrence — the same fallback
  // apply_entry_sort uses, so TypeScript and SQL cannot disagree about the answer.
  const evidenceOffset = evidence ? sixOffset ?? verifiedScalarOffset(body, evidence, item?.evidence_offset) : null;

  let mentionText = typeof item?.mention_text === 'string' ? item.mention_text : null;
  let mentionOffset = mentionText ? verifiedScalarOffset(body, mentionText, item?.mention_offset) : null;
  if (mentionText === null || mentionOffset === null) {
    // recover it: the dish is named SOMEWHERE in the words (case may differ, which is
    // why this is a lowercase search and the slice — not the name — is what we keep).
    const at = body.toLowerCase().indexOf(spoken.toLowerCase());
    if (at < 0) {
      mentionText = null;
      mentionOffset = null;
    } else {
      mentionText = body.slice(at, at + spoken.length);
      mentionOffset = scalarOffset(body, at);
    }
  }
  if (mentionText !== null && scalarLength(mentionText) === 0) {
    mentionText = null;
    mentionOffset = null;
  }

  // 0053: style words label the DISH; they are cleaned, never proved against the words.
  const styles = cleanStyles(item?.styles);

  return {
    dish_name: dish,
    score,
    score_evidence: evidence,
    note,
    evidence_offset: evidenceOffset,
    mention_text: mentionText,
    mention_offset: mentionOffset,
    ...(styles.length ? { styles } : {}),
  };
}

/**
 * Validate a whole plan: drop what cannot be proved, dedupe by dish (first mention
 * wins, but a scored duplicate promotes the score onto the kept line), cap the list.
 */
export function validatePlan(plan: SortPlan, opts: ValidateOptions): SortPlan {
  const items: SortItem[] = [];
  const index = new Map<string, number>();

  const planKeys = new Set((plan?.items ?? []).map((raw) => matchKey(String(raw?.dish_name ?? ''))).filter(Boolean));
  for (const raw of plan?.items ?? []) {
    const item = validateItem(raw, { ...opts, planKeys });
    if (!item) continue;
    // one line per dish, by spelling key: "Taco" and "Tacos" in one entry are one line, as the
    // database would resolve them to one dish anyway
    const key = matchKey(item.dish_name) || item.dish_name.toLowerCase();
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
    if (!kept.styles && item.styles) kept.styles = item.styles;
    // the mention stays the FIRST one — the receipt's line order follows the words.
  }

  for (const it of items) {
    if (!it.note) continue;
    const others = items.filter((o) => o !== it).map((o) => o.mention_text ?? o.dish_name);
    it.note = cutAtOtherDishes(it.note, others);
  }

  const place = plan?.place_query ? String(plan.place_query).trim() : null;
  const keptPlace = place && place.length >= 2 ? place : null;
  return {
    place_query: keptPlace,
    place_offset: verifiedScalarOffset(opts.body ?? '', keptPlace, plan?.place_offset),
    items,
  };
}
