// supabase/functions/sort-entry/parse.ts
//
// THE DETERMINISTIC SORTER (default mode — CEO decision: no AI spend yet).
//
// Pure functions, no IO, no network, no key, no clock. Given the user's words (and,
// when a place matched, the dish names already on that menu) it returns the same
// plan shape the model mode returns, so the rest of the pipeline cannot tell them
// apart. Every rule below is pinned by fixtures.ts + parse_test.ts.
//
// THE BIAS IS DELIBERATE AND ASYMMETRIC. A missed score is a cosmetic loss (the dish
// prints an empty star, which is a designed state). An INVENTED score is a lie about
// what the user said — the one thing DESIGN rule 7 forbids. So every ambiguous
// number is dropped, and the parser would rather find no dish than a wrong one.
//
// WHY A NUMBER IS *NOT* A SCORE (the false positives this exists to kill):
//   "gone in four minutes"      → followed by a time unit
//   "queued forty minutes"      → not a score word at all
//   "361 Little Bourke St"      → out of range / part of a longer number
//   "two of us"  "3 pm"  "$18"  "12 September"  "8:02"  "pasta x4"  "4th time"
// A number only becomes a score when it is marked ("stars", "/5", "out of five"),
// spoken as a half ("four and a half"), pre-marked ("a solid four"), written with a
// decimal ("4.5" — how the composer's score token lands in the text), or sitting
// immediately beside the dish it scores ("Margherita 4.5").

import type { ParseInput, PlaceCandidate, SortItem, SortPlan } from './types.ts';
import { scalarOffset } from './offsets.ts';

// ---------------------------------------------------------------------------
// WORDS ARE UNICODE. `\w`, `\b` and `[A-Za-z]` ARE NOT.
//
// JavaScript's `\w` is exactly [A-Za-z0-9_], so "ragù" tokenises as "rag" and the dish
// created from a diner's prose was `Tagliatelle al rag` (staging, 2026-09-22). The same
// cut hit "crème brûlée" (→ "brûlée"), lost "Bánh mì 4" entirely, and made "Dinner at
// Émile" attach to "Dinner". Melbourne menus are made of these words.
//
// THE CONVENTION, everywhere a class stands in for "a word character":
//     word     → \p{L}\p{N}\p{M}_          (letters, numbers, COMBINING MARKS, underscore)
//     inside a name → the above + ' ’ -
//     a capital → \p{Lu}                   (not [A-Z])
//     a boundary → (?<![\p{L}\p{N}\p{M}_]) / (?![...])   — `\b` is ASCII-only too, even
//                  with the /u flag, so it cannot be used to fence a name.
// `\p{M}` matters because "ragù" can arrive DECOMPOSED (u + U+0300); without it the mark
// would end the word and we would be back to "rag".
// Every regex below that touches a name, a venue or a sentence start carries /u.
//
// DELIBERATELY STILL ASCII:
//   * `\d` for score digits — a score is 0-5 written in ASCII; `\p{N}` would admit ٤ and
//     ４ as scores, and inventing a score is the one thing rule 7 forbids.
//   * the `\b` in the REJECT vocabularies (UNIT_AFTER, ORDINAL_AFTER, the big-number
//     guard). An ASCII boundary there matches MORE text, so more numbers are rejected as
//     units. Tightening it would let a number through — the unsafe direction.
// ---------------------------------------------------------------------------

/** The character class body for a Unicode word character (see the note above). */
const WORD = '\\p{L}\\p{N}\\p{M}_';

// ---------------------------------------------------------------------------
// Vocabulary
// ---------------------------------------------------------------------------

// NOTE: no standalone 'half'. "half the work", "half an hour", "half a serve" are far more
// common than anyone scoring something 0.5 by saying just "half" — it only counts as
// the tail of another number ("four and a half").
const SPOKEN: Record<string, number> = { one: 1, two: 2, three: 3, four: 4, five: 5 };

/** A number followed by one of these is a duration/quantity/price, not a score. */
const UNIT_AFTER =
  /^[\s-]*(?:minutes?|mins?|hours?|hrs?|seconds?|secs?|days?|weeks?|months?|years?|people|persons?|of\s+us|times?|dollars?|bucks?|cents?|degrees?|percent|pm|am|o'?clock|kids?|courses?|plates?|bowls?|serves?|servings?|bites?|pieces?|slices?|sides?|beers?|wines?|glasses?|tables?|dozen|km|kms?|metres?|meters?)\b/i;

/** Ordinal suffix directly attached: "4th time". */
const ORDINAL_AFTER = /^(?:st|nd|rd|th)\b/i;

/** "stars", "/5", "out of five" — an unambiguous score marker. */
const MARKER_AFTER = /^[\s-]*(?:\/\s*5|out\s+of\s+(?:5|five)|stars?(?![\p{L}\p{N}\p{M}_]))/iu;

/**
 * The words that make a bare number a score: "a solid four", "I'd give it a four",
 * "gave it a 4", "is a five". Without one of these, a bare integer only counts when
 * it is sitting right against the dish name.
 */
const PRE_MARKER =
  /(?:giv(?:e|ing)\s+(?:it|that|them)?\s*an?|gave\s+(?:it|that|them)?\s*an?|rated?\s+(?:it|that)?\s*an?|(?:is|was|are|were|gets|got)\s+an?|solid|strong|easy|generous|comfortable|honest)\s*$/i;

/** Immediately before a number and it is not a score: "$5", "x4", "#4". */
const PRE_REJECT = /[$#x×@]\s*$/i;

/**
 * A number DIRECTLY after one of these is a ranking or a quantity, never a score:
 *
 *   "is a top five Melbourne pizza"   → a ranking idiom. Nobody scores a pizza "5" by
 *                                       calling it top five, and "Top" is not a dish.
 *   "Order two."  "we got 4"  "had 2" → how MANY, not how good.
 *
 * Checked only when the number carries no explicit marker, so "got 5 stars" and
 * "got a four" keep their score — the marker/article is what tells the two apart. Where
 * it stays ambiguous, rule 7's asymmetry decides: a bare "we got 4" loses a score rather
 * than inventing one.
 *
 * NOTE 'top' is deliberately NOT a STOPWORD: "Top Paddock" is a Melbourne venue, and
 * STOPWORDS also trims place candidates.
 */
const PRE_REJECT_WORD =
  /(?:top|bottom|order|orders|ordered|get|gets|got|grab|grabs|grabbed|share|shares|shared|split|splits|take|takes|took|have|has|had|buy|buys|bought|bring|brought|try|tries|tried)(?:\s+(?:another|about|maybe|just|like|around))?\s+$/i;

/** A word that is a NUMBER, spoken or written. Never the head of a dish name. */
const NUMBER_WORD = /^(?:\d+(?:[.,]\d+)?|one|two|three|four|five|six|seven|eight|nine|ten|dozen|couple|few)$/i;

/** Words that may not start or end a dish name. */
const STOPWORDS = new Set([
  'a', 'an', 'the', 'and', 'or', 'but', 'with', 'for', 'at', 'in', 'on', 'of', 'to', 'from',
  'my', 'her', 'his', 'their', 'our', 'your', 'its', 'this', 'that', 'these', 'those',
  'was', 'were', 'is', 'are', 'be', 'been', 'had', 'has', 'have', 'got', 'get', 'went',
  'we', 'i', 'they', 'he', 'she', 'it', 'us', 'them', 'me',
  'very', 'really', 'so', 'too', 'just', 'quite', 'pretty', 'bit', 'more', 'less',
  'then', 'than', 'also', 'again', 'still', 'twice', 'once', 'here', 'there', 'now', 'after',
  'before', 'about', 'some', 'every', 'all', 'both', 'each', 'no', 'not', 'nothing',
  'good', 'great', 'best', 'worst', 'nice', 'lovely', 'solid', 'unreal', 'ok', 'okay',
  // quantity/ordinal words that are never part of a dish's name
  'one', 'another', 'other', 'second', 'third', 'first', 'last', 'next', 'same', 'extra',
  // discourse markers — "The tiramisu, honestly, 3." must not invent a dish called
  // "honestly" out of the phrase sitting in front of the number.
  'honestly', 'obviously', 'frankly', 'anyway', 'overall', 'apparently', 'seriously',
  'literally', 'genuinely', 'basically', 'maybe', 'probably', 'definitely', 'somehow',
]);

/** After an ordering verb, one of these means movement/time, not a dish: "got TO Kisume". */
const PREP_AFTER_VERB =
  /^(?:to|into|in|at|for|with|from|by|on|about|out|back|up|down|off|over|here|there)(?![\p{L}\p{N}\p{M}_])/iu;

/** Verbs that introduce something ordered: "had the pork bun". */
const ORDER_VERB =
  /(?<![\p{L}\p{N}\p{M}_])(?:had|ordered|order|got|tried|split|shared|started\s+with|finished\s+with|went\s+for|grabbed|picked|chose|demolished|smashed)\s+(?:the|a|an|some|their|his|her|my|our|two|three|four|a\s+few)?\s*/giu;

/**
 * Is body[i] the end of a sentence? Newlines count — people write in fragments.
 * A '.' between two digits is a DECIMAL POINT, not a full stop: without this, "1.5"
 * ends the sentence and every note collapses to "Cheeseburger 1." — the first bug
 * the fixture corpus caught.
 */
function isTerminator(body: string, i: number): boolean {
  const ch = body[i];
  if (ch === '\n') return true;
  if (ch !== '.' && ch !== '!' && ch !== '?') return false;

  // Only the LAST mark of a run ends anything: "insane?? yes" is one break, not two.
  if (/[.!?]/.test(body[i + 1] ?? '')) return false;

  if (ch === '.') {
    // decimal point: "1.5" is a number, not two sentences
    if (/\d/.test(body[i - 1] ?? '') && /\d/.test(body[i + 1] ?? '')) return false;
    // the tail of an ellipsis — a pause, not a stop: "tiramisu... 3, fine."
    if (body[i - 1] === '.') return false;
    // an abbreviation full stop: a sentence restarts with a CAPITAL (or the text ends).
    // Without this, "the no. 3 toastie 4.5" is two sentences and the toastie loses
    // its score to the next dish. \p{Lu}, not [A-Z] — "Émile" and "Ñoño" start sentences.
    const rest = body.slice(i + 1);
    if (rest.trim().length && !/^\s+\p{Lu}/u.test(rest)) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const isHalfStep = (n: number) => n >= 0.5 && n <= 5 && Math.abs(n * 2 - Math.round(n * 2)) < 1e-9;

function inSpans(index: number, spans: Array<[number, number]>): boolean {
  return spans.some(([s, e]) => index >= s && index < e);
}

/** Sentence bounds containing `index`, terminator INCLUDED at the end (so a note can keep its full stop). */
export function sentenceBounds(body: string, index: number): [number, number] {
  let start = 0;
  for (let i = Math.min(index, body.length - 1); i >= 0; i--) {
    if (isTerminator(body, i)) { start = i + 1; break; }
  }
  let end = body.length;
  for (let i = index; i < body.length; i++) {
    if (isTerminator(body, i)) { end = i + 1; break; }
  }
  return [start, Math.max(end, start)];
}

// ---------------------------------------------------------------------------
// NUMBERS
// ---------------------------------------------------------------------------

export type NumberHit = {
  start: number;
  end: number;
  /** the literal slice of the body — this becomes score_evidence */
  text: string;
  value: number;
  /** true when the number carries its own proof it is a score (marker / decimal / half / pre-marker) */
  selfEvident: boolean;
};

/**
 * Every number in the body that COULD be a score, with its literal text. Units,
 * ordinals, prices and out-of-range numbers never make it out of here.
 */
export function findNumbers(body: string): NumberHit[] {
  const hits: NumberHit[] = [];

  // --- digits: 4, 4.5, 4/5, 4.5 stars --------------------------------------
  // The lookahead rejects a following DIGIT and a following DECIMAL ("4.25"), but
  // NOT a following full stop — "Kingfish 4.5." must still find 4.5.
  const digits = /(?<![\d.])([0-5](?:\.\d)?)(?!\d)(?!\.\d)/g;
  for (let m = digits.exec(body); m; m = digits.exec(body)) {
    const raw = m[1];
    const start = m.index;
    let end = start + raw.length;
    const after = body.slice(end);
    const before = body.slice(0, start);

    if (ORDINAL_AFTER.test(after)) continue;
    if (UNIT_AFTER.test(after)) continue;
    if (/^\s*%/.test(after)) continue;
    if (PRE_REJECT.test(before)) continue;

    const value = Number(raw);
    if (!isHalfStep(value)) continue;

    const marker = MARKER_AFTER.exec(after);
    if (marker) {
      end += marker[0].length;
      // skip past the marker so "4/5" and "4 out of five" don't also yield a bare 5
      digits.lastIndex = end;
    }
    // "a top 5 pizza", "order 2" — a ranking or a count. An explicit marker overrides it
    // ("got 5 stars" is still a score).
    if (!marker && PRE_REJECT_WORD.test(before)) continue;

    hits.push({
      start,
      end,
      text: body.slice(start, end),
      value,
      selfEvident: Boolean(marker) || raw.includes('.') || PRE_MARKER.test(before),
    });
  }

  // --- spoken: four, four and a half, four point five, five stars ----------
  const spoken =
    /(?<![\p{L}\p{N}\p{M}_])(one|two|three|four|five)(?![\p{L}\p{N}\p{M}_])(?:[\s-]*(?:point[\s-]*(?:five|5)|and[\s-]*a[\s-]*half))?/giu;
  for (let m = spoken.exec(body); m; m = spoken.exec(body)) {
    const start = m.index;
    let end = start + m[0].length;
    const before = body.slice(0, start);
    let after = body.slice(end);

    if (UNIT_AFTER.test(after)) continue;
    if (PRE_REJECT.test(before)) continue;

    let value = SPOKEN[m[1].toLowerCase()];
    const isHalf = /(?:point[\s-]*(?:five|5)|and[\s-]*a[\s-]*half)\s*$/i.test(m[0]);
    if (isHalf) value += 0.5;
    if (!isHalfStep(value)) continue;

    const marker = MARKER_AFTER.exec(after);
    if (marker) {
      end += marker[0].length;
      after = body.slice(end);
      spoken.lastIndex = end; // "a four out of five" is ONE score, not four and five
    }

    // "four" inside a longer number word run ("four twenty") — leave it alone.
    if (/^[\s-]*(?:hundred|thousand|twenty|thirty|forty|fifty)\b/i.test(after)) continue;
    // "a top five Melbourne pizza", "Order two." — a ranking or a count, not a score.
    if (!marker && PRE_REJECT_WORD.test(before)) continue;

    hits.push({
      start,
      end,
      text: body.slice(start, end),
      value,
      selfEvident: Boolean(marker) || isHalf || PRE_MARKER.test(before),
    });
  }

  return hits.sort((a, b) => a.start - b.start);
}

// ---------------------------------------------------------------------------
// PLACE CANDIDATES — phrases that LOOK like a place name. The function resolves
// them against restaurants we already hold; a candidate that matches nothing is
// simply forgotten (rule 8: never invented, never from location).
// ---------------------------------------------------------------------------
export function placeCandidateSpans(body: string, limit = 6): PlaceCandidate[] {
  const out: Array<{ phrase: string; weight: number; at: number }> = [];
  const seen = new Set<string>();

  // `at` is the UTF-16 index in `body` of the RAW phrase; every trim below that eats
  // characters from the FRONT shifts it, so the published offset still points at the
  // first character of the phrase we return (the client's place token starts there).
  const push = (phrase: string, weight: number, at: number) => {
    const lead = /^[^\p{L}\p{N}\p{M}_]+/u.exec(phrase);
    let clean = phrase.slice(lead ? lead[0].length : 0).replace(/[^\p{L}\p{N}\p{M}_'’&]+$/u, '');
    const start = at + (lead ? lead[0].length : 0);
    // A venue name never ends in glue: "AT BUTCHERS DINER IS A" → "BUTCHERS DINER".
    for (;;) {
      const m = /(\s+)([\p{L}\p{N}\p{M}_'’-]+)$/u.exec(clean);
      if (!m || !STOPWORDS.has(m[2].toLowerCase())) break;
      clean = clean.slice(0, m.index);
    }
    if (clean.length < 2 || clean.length > 60) return;
    const words = clean.split(/\s+/);
    if (words.every((w) => STOPWORDS.has(w.toLowerCase()))) return;
    const key = clean.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ phrase: clean, weight, at: start });
  };

  // NOTE: the token class excludes '.', so a run STOPS at a full stop. With the dot
  // inside it, "Chin Chin. The kingfish…" produced the candidate "Chin Chin. The" and
  // nothing ever matched the restaurant.

  // 1. Explicitly introduced: "at Chin Chin", "@ Tipo 00", "back to Supernormal".
  // (the preposition is spelled out in its three realistic casings rather than using
  // the /i flag, because /i would also let the CAPTURE start lowercase and every
  // "at the place near work" would become a candidate to look up.)
  const intro =
    /(?:(?<![\p{L}\p{N}\p{M}_])(?:at|At|AT)\s+|@\s*|(?<![\p{L}\p{N}\p{M}_])(?:back\s+to|to|To|TO)\s+)([\p{Lu}\p{N}][\p{L}\p{N}\p{M}_'’&-]*(?:\s+[\p{Lu}\p{N}][\p{L}\p{N}\p{M}_'’&-]*){0,3})/gu;
  for (let m = intro.exec(body); m; m = intro.exec(body)) {
    // the capture is the TAIL of the match, so this is its index without searching
    // (searching would mis-locate "to To …").
    push(m[1], 3, m.index + m[0].length - m[1].length);
  }

  // 2. Any run of capitalised / numeric tokens (how venue names read: "Tipo 00",
  //    "400 Gradi", "Hardware Societe"). Sentence-initial runs count — the design's
  //    own example entry opens with the place name.
  // the leading (?<!…) is what `\b` used to be: with `\b`, a name that OPENS with a
  // non-ASCII capital ("Émile", "Ñoño") had no boundary in front of it and never became
  // a candidate at all — the entry then matched whatever ASCII word came next.
  const runs =
    /(?<![\p{L}\p{N}\p{M}_])([\p{Lu}\p{N}][\p{L}\p{N}\p{M}_'’&-]*(?:\s+(?:[\p{Lu}\p{N}][\p{L}\p{N}\p{M}_'’&-]*|of|de|la|le|du|and|&)){0,3})/gu;
  for (let m = runs.exec(body); m; m = runs.exec(body)) {
    let phrase = m[1];
    let at = m.index;
    // trim a leading sentence-starting stopword ("With Jess" → "Jess"). CUT, never
    // re-join: a join would normalise the spacing and the phrase would stop being a
    // literal slice of the body, which is what its offset points at.
    const lead = /^[\p{L}\p{N}\p{M}_'’&-]+\s+/u.exec(phrase);
    if (lead && STOPWORDS.has(lead[0].trim().toLowerCase())) {
      phrase = phrase.slice(lead[0].length);
      at += lead[0].length;
    }
    push(phrase, 1, at);
    // also offer the leading two words of a long run ("Hardware Societe Flinders Ln")
    const two = /^[\p{L}\p{N}\p{M}_'’&-]+\s+[\p{L}\p{N}\p{M}_'’&-]+/u.exec(phrase);
    if (two && two[0].length < phrase.length) push(two[0], 1, at);
  }

  return out
    .sort((a, b) => b.weight - a.weight || b.phrase.length - a.phrase.length || a.at - b.at)
    .slice(0, limit)
    .map((c) => ({ phrase: c.phrase, offset: scalarOffset(body, c.at) }));
}

/** The phrases only — the shape the function's place lookups have always taken. */
export function placeCandidates(body: string, limit = 6): string[] {
  return placeCandidateSpans(body, limit).map((c) => c.phrase);
}

/**
 * Which candidate phrase NAMES this restaurant? Used when the user already pinned the
 * place (composer tap): the sorter has nothing to resolve, but the words still contain
 * the mention the client wants to draw a token on. Comparison is case- and
 * whitespace-insensitive, longest phrase first; no fuzziness, because a wrong mention
 * would put a place token on words that are not the place.
 */
export function mentionForPlaceName(
  candidates: PlaceCandidate[],
  name: string | null | undefined,
): PlaceCandidate | null {
  const want = (name ?? '').trim().toLowerCase().replace(/\s+/g, ' ');
  if (want.length < 2) return null;
  let best: PlaceCandidate | null = null;
  for (const c of candidates) {
    const have = c.phrase.trim().toLowerCase().replace(/\s+/g, ' ');
    if (have.length < 2) continue;
    if (have !== want && !want.startsWith(have + ' ') && !have.startsWith(want + ' ')) continue;
    if (!best || c.phrase.length > best.phrase.length) best = c;
  }
  return best;
}

// ---------------------------------------------------------------------------
// DISH MENTIONS
// ---------------------------------------------------------------------------

/**
 * `anchored` — did the USER point at this as a thing they ate?
 *
 * Two ways to earn it: it is on the matched restaurant's menu, or they introduced it with
 * a determiner ("had THE focaccia", "split A tiramisu", "shared SOME chips"). An
 * UNANCHORED candidate is a noun run the parser lifted out of ordinary prose — "had
 * proper leopard spotting on the crust", "the salsa had real heat" — and it needs a SCORE
 * to earn a receipt line. Without one it is description, not an order.
 *
 * Why a determiner rather than a list of food words: a food lexicon cannot cover bánh mì,
 * açaí bowl or pho đặc biệt without silently dropping real dishes, and guessing which
 * nouns are food is exactly the kind of inference rules 7 and 8 forbid. A determiner is
 * evidence the diner produced.
 */
type Mention = { name: string; start: number; end: number; known: boolean; anchored: boolean };

/** The determiners ORDER_VERB may swallow — "had THE pork bun" points, "had proper…" does not. */
const POINTED_BY = /(?:^|\s)(?:the|a|an|some|their|his|her|my|our|two|three|four|a\s+few)\s*$/i;

/** Every occurrence (up to 3 per dish) — a dish scored on its SECOND mention still
 *  gets its score; the duplicate lines are merged downstream by validatePlan. */
function findKnownDishes(body: string, knownDishes: string[], exclude: Array<[number, number]>): Mention[] {
  const hits: Mention[] = [];
  // longest names first so "beef rib" doesn't shadow "beef rib roll"
  for (const dish of [...knownDishes].sort((a, b) => b.length - a.length)) {
    const name = dish.trim();
    if (name.length < 3) continue;
    // Unicode fences, not `\b`/`\w`: "Bánh mì" must not match inside "Bánh mìs", and a
    // menu name that ENDS in an accented letter must still be fenced at all.
    const re = new RegExp(
      `(?<![${WORD}])${escapeRe(name).replace(/\\?\s+/g, '\\s+')}(?![${WORD}])`,
      'giu',
    );
    let found = 0;
    for (let m = re.exec(body); m && found < 3; m = re.exec(body)) {
      const start = m.index;
      const end = start + m[0].length;
      if (inSpans(start, exclude)) continue;
      if (hits.some((h) => start < h.end && end > h.start)) continue;
      hits.push({ name, start, end, known: true, anchored: true });
      found++;
    }
  }
  return hits;
}

/** Words allowed INSIDE a dish name, but never at either end: "pork and chive". */
const JOINERS = new Set(['and', '&']);

/** Walk backwards from `end` collecting up to 4 words as a dish name. */
function phraseBefore(body: string, end: number): { text: string; start: number } | null {
  const left = body.slice(0, end);
  const tokens: Array<{ w: string; at: number }> = [];
  // THE staging bug lived here: with /[\w'’-]+/ the token for "ragù" was "rag", so the
  // dish the sorter created out of a diner's prose was "Tagliatelle al rag".
  const re = /[\p{L}\p{N}\p{M}_'’-]+/gu;
  for (let m = re.exec(left); m; m = re.exec(left)) tokens.push({ w: m[0], at: m.index });
  if (!tokens.length) return null;

  const picked: Array<{ w: string; at: number }> = [];
  for (let i = tokens.length - 1; i >= 0 && picked.length < 4; i--) {
    const t = tokens[i];
    // stop at a clause boundary between this token and what we already have
    if (picked.length) {
      const between = body.slice(t.at + t.w.length, picked[0].at);
      if (/[.,;:!?\n—–]/.test(between)) break;
    }
    const lower = t.w.toLowerCase();
    if (JOINERS.has(lower)) {
      // keep it only if a content word continues on the far side ("pork and chive"),
      // never if it would dangle ("bun and 4.5") or chain names ("Jess and Tom").
      const prev = tokens[i - 1];
      if (!picked.length || !prev || STOPWORDS.has(prev.w.toLowerCase()) || JOINERS.has(prev.w.toLowerCase())) break;
      picked.unshift(t);
      continue;
    }
    if (STOPWORDS.has(lower)) break;
    if (/^\d+$/.test(lower) && picked.length === 0) break;
    picked.unshift(t);
  }
  while (picked.length && JOINERS.has(picked[0].w.toLowerCase())) picked.shift();
  while (picked.length && JOINERS.has(picked[picked.length - 1].w.toLowerCase())) picked.pop();
  if (!picked.length) return null;
  const start = picked[0].at;
  const text = body.slice(start, picked[picked.length - 1].at + picked[picked.length - 1].w.length);
  if (text.trim().length < 3) return null;
  return { text: text.trim(), start };
}

function findNewDishes(
  body: string,
  numbers: NumberHit[],
  taken: Mention[],
  exclude: Array<[number, number]>,
): Mention[] {
  const found: Mention[] = [];
  const overlaps = (s: number, e: number) =>
    [...taken, ...found].some((h) => s < h.end && e > h.start) || inSpans(s, exclude);

  // (a) score-anchored: the phrase immediately before a number is the dish
  //     ("prawn 3.5", "bread 4"). ADJACENCY is what makes this safe — the phrase
  //     walk stops at stopwords, so "table for 4", "party of 5" and "we were 4"
  //     produce nothing at all.
  for (const n of numbers) {
    if (taken.some((h) => n.start >= h.end && isAdjacent(body.slice(h.end, n.start)))) continue;
    const p = phraseBefore(body, n.start);
    if (!p) continue;
    if (!n.selfEvident && !isAdjacent(body.slice(p.start + p.text.length, n.start))) continue;
    if (overlaps(p.start, p.start + p.text.length)) continue;
    // anchored by the NUMBER sitting against it — that is this branch's whole premise.
    found.push({ name: p.text, start: p.start, end: p.start + p.text.length, known: false, anchored: true });
  }

  // (b) verb-anchored: "had the pork bun", "split the tiramisu".
  ORDER_VERB.lastIndex = 0;
  for (let m = ORDER_VERB.exec(body); m; m = ORDER_VERB.exec(body)) {
    const from = m.index + m[0].length;
    const rest = body.slice(from);
    // "got TO Kisume", "went IN at six" — movement or time, not an order.
    if (PREP_AFTER_VERB.test(rest)) continue;
    const phrase = /^[\p{L}\p{N}\p{M}_'’-]+(?:\s+[\p{L}\p{N}\p{M}_'’-]+){0,3}/u.exec(rest);
    if (!phrase) continue;
    // A dish name is a contiguous run of content words (+ joiners): cut at the first
    // interior stopword so "Kisume at 5" can never become a dish.
    const words: string[] = [];
    for (const w of phrase[0].split(/\s+/)) {
      const lower = w.toLowerCase();
      if (STOPWORDS.has(lower)) { if (words.length) break; else continue; }
      words.push(w);
    }
    while (words.length && JOINERS.has(words[words.length - 1].toLowerCase())) words.pop();
    if (!words.length) continue;
    // "got 5 stars", "had 2 beers", "order two" — a COUNT follows the verb, so this is a
    // quantity construction and not "verb + dish". Abandon it rather than mine a name out
    // of it: "5 stars" and "four" are not dishes, and taking them also steals the score
    // off the dish that earned it.
    if (NUMBER_WORD.test(words[0])) continue;
    const text = words.join(' ');
    const start = from + phrase[0].indexOf(words[0]);
    const end = start + text.length;
    if (text.length < 3) continue;
    if (overlaps(start, end)) continue;
    found.push({
      name: body.slice(start, end),
      start,
      end,
      known: false,
      // "had THE pork bun" points at a thing; "had proper leopard spotting" carries on
      // describing the one before it.
      anchored: POINTED_BY.test(m[0]),
    });
  }

  return found;
}

// ---------------------------------------------------------------------------
// NOTES — a verbatim slice, never a paraphrase (rule 9). We may only trim from the
// ENDS of a slice; cutting from the middle would stop it being the user's words.
//
// THE DEFAULT IS THE CLAUSE AFTER THE DISH, because that is what the approved receipt
// prints (design/v1/Entry: `"A bit flat after that."`). A note that opened with the dish
// name and its score would repeat the line it sits under. 'sentence' exists as the
// alternative — Eamon's call, one word at the call site, both styles tested.
// ---------------------------------------------------------------------------
export function excerptFor(
  body: string,
  mentionStart: number,
  mentionEnd: number,
  scoreSpan: [number, number] | null,
  prevEnd: number,
  nextStart: number,
  noteStyle: 'sentence' | 'clause' = 'clause',
): string | null {
  const [sentStart, sentEnd] = sentenceBounds(body, Math.max(0, mentionEnd - 1));

  // Does this dish have the sentence to ITSELF? In a list — "Pork and chive 4, prawn
  // 3.5." — the sentence belongs to every dish in it, so quoting it would print the
  // same words under each line.
  const ownsSentence = nextStart >= sentEnd && prevEnd <= sentStart;
  // Everything in the sentence that is NOT this dish's own name or its own score. If
  // that says nothing, the sentence is just "Tagliatelle al ragù 4.5." and quoting it
  // back underneath the receipt line that already prints both is noise.
  const remainder =
    body.slice(sentStart, Math.min(mentionStart, sentEnd)) +
    ' ' +
    body.slice(Math.min(scoreSpan ? Math.max(scoreSpan[1], mentionEnd) : mentionEnd, sentEnd), sentEnd);
  const sentenceIsQuotable = ownsSentence && hasOpinion(remainder);

  // 'sentence' style ONLY (not the default): the whole sentence, trimmed at its ends
  // (whitespace + a trailing comma) so it stays the user's words exactly (rule 9). It
  // keeps what they said before naming the dish, but it also repeats the dish name and
  // score that the receipt line already prints — which is why the approved design, and
  // therefore the default, is the clause below.
  if (noteStyle === 'sentence' && sentenceIsQuotable) {
    const whole = trimSentence(body.slice(quoteStart(body, sentStart, mentionStart), sentEnd));
    if (whole && hasOpinion(whole)) return whole;
  }

  // THE DEFAULT: what they said AFTER the dish and its score, cut at the next dish, with
  // dangling glue and punctuation trimmed off the ends ("the quiet star," → "the quiet
  // star"). Always a verbatim slice — trimmed, never re-joined.
  const from = Math.max(mentionEnd, scoreSpan && scoreSpan[0] >= mentionEnd ? scoreSpan[1] : 0);
  const end = Math.min(sentEnd, nextStart > from ? nextStart : sentEnd);
  const trimmed = trimExcerpt(body.slice(Math.min(from, end), end));
  if (trimmed && hasOpinion(trimmed)) return trimmed;

  // Nothing said after the dish: the whole sentence is the last resort.
  if (!sentenceIsQuotable) return null;
  const whole = trimExcerpt(body.slice(sentStart, sentEnd));
  if (whole && hasOpinion(whole)) return whole;
  return null;
}

/**
 * Does this slice actually SAY anything about the dish?
 *
 * A note has to carry at least one ordinary lowercase word that is not a stopword.
 * Fragments that are only glue and proper nouns — "the", "at 400 Gradi.", "is not." —
 * are trailing context, not the user's verdict, and printing them under a receipt
 * line would be noise. (Cheap, and it is the rule that stopped a venue name being
 * quoted back as a dish note.)
 */
function hasOpinion(s: string): boolean {
  const words = s.match(/[\p{L}\p{N}\p{M}_'’-]+/gu) ?? [];
  // \p{Ll}, not [a-z]: "élégant" and "über" are ordinary lowercase words too.
  return words.some((w) => /^\p{Ll}/u.test(w) && !STOPWORDS.has(w.toLowerCase()) && w.length > 1);
}

/**
 * Where the quoted sentence should START.
 *
 * `sentenceBounds` deliberately treats a full stop that is NOT followed by a capital as
 * an abbreviation ("the no. 3 toastie"), which keeps a score attached to its dish. The
 * cost is that a sentence beginning lower case ("insane?? yes. tiramisu... 3, fine.")
 * hangs the previous sentence's tail off the front of the quote. So for the QUOTE only,
 * step past the last sentence-ending punctuation that sits before the dish is named.
 * Moving the start forward keeps the result a literal substring (rule 9).
 */
function quoteStart(body: string, sentStart: number, mentionStart: number): number {
  const lead = body.slice(sentStart, Math.max(sentStart, mentionStart));
  // no trailing (?=\S): the lead STOPS at the dish, so the last break is often the last
  // thing in it ("… insane?? yes. " + "tiramisu").
  const breaks = /(?<![.!?])[.!?]\s+/g;
  let last = -1;
  for (let m = breaks.exec(lead); m; m = breaks.exec(lead)) last = m.index + m[0].length;
  return last > 0 ? sentStart + last : sentStart;
}

/**
 * A whole sentence, trimmed at its ENDS ONLY: surrounding whitespace and a trailing
 * comma (a sentence cut at a newline often ends on one). Nothing is dropped from the
 * front — the opening words are the user's too — so the result is always a literal
 * substring of the body.
 */
function trimSentence(raw: string): string | null {
  let s = raw.replace(/^\s+/, '').replace(/[\s,]+$/, '');
  if (s.length > 240) {
    const cut = s.slice(0, 240);
    const lastSpace = cut.lastIndexOf(' ');
    s = (lastSpace > 80 ? cut.slice(0, lastSpace) : cut).replace(/[\s,]+$/, '');
  }
  return s.length ? s : null;
}

/** Trim only from the ends, then drop a leading connective. Result is always a substring. */
function trimExcerpt(raw: string): string | null {
  let s = raw.replace(/^[\s,;:—–\-()"'`]+/, '').replace(/[\s,;:—–\-(["'`]+$/, '');
  s = s.replace(/^(?:was|were|is|are|and|but|which|that|then|so)(?![\p{L}\p{N}\p{M}_])[\s,]*/iu, '');
  s = s.replace(/^[\s,;:—–\-]+/, '');
  // A slice cut short by the next dish can end on dangling glue ("beats the"). Trim
  // trailing stopwords — but only when the slice has no terminal punctuation, so a
  // complete sentence like "a bit flat after that." is left exactly as written.
  // (cut, never re-join: a rejoin would normalise whitespace and the result would stop
  // being a literal substring of the user's words.)
  if (!/[.!?]$/.test(s)) {
    for (;;) {
      const m = /(\s+)([\p{L}\p{N}\p{M}_'’-]+)[^\p{L}\p{N}\p{M}_]*$/u.exec(s);
      if (!m || !STOPWORDS.has(m[2].toLowerCase())) break;
      s = s.slice(0, m.index);
    }
    // The cut can EXPOSE punctuation that used to be mid-clause: "was the quiet star,
    // and the" → "the quiet star,". Re-strip the ends (cut, never re-join).
    s = s.replace(/[\s,;:]+$/, '');
  }
  if (s.length > 240) {
    const cut = s.slice(0, 240);
    const lastSpace = cut.lastIndexOf(' ');
    s = lastSpace > 80 ? cut.slice(0, lastSpace) : cut;
  }
  s = s.trim();
  return s.length ? s : null;
}

// ---------------------------------------------------------------------------
// THE PARSER
// ---------------------------------------------------------------------------
export function parseEntry(input: ParseInput): SortPlan {
  const body = input.body ?? '';
  const known = input.knownDishes ?? [];
  const exclude = input.excludeSpans ?? [];
  const noteStyle = input.noteStyle ?? 'clause';

  if (!body.trim()) return { place_query: null, place_offset: null, items: [] };

  const numbers = findNumbers(body);
  const knownHits = findKnownDishes(body, known, exclude);
  // Every mention gets a line here, including repeats: a dish scored on its second
  // mention must still find its number. validatePlan merges the duplicates (first
  // line wins, a later score/note fills a gap it left).
  const mentions = [...knownHits, ...findNewDishes(body, numbers, knownHits, exclude)]
    .sort((a, b) => a.start - b.start)
    // THE ANCHOR RULE, applied BEFORE the note windows are cut. A candidate nobody
    // pointed at and no number can score is not a line item — and it must not be here at
    // all, because a mention the parser is going to refuse still ends the previous dish's
    // note ("The tacos 4, and the salsa had real heat." left the tacos quoting "the
    // salsa"). A phantom line item should cost the receipt nothing.
    .filter((m) => m.anchored || numbers.some((n) => couldScore(body, m, n)));

  const usedNumbers = new Set<NumberHit>();
  const items: SortItem[] = [];

  for (let i = 0; i < mentions.length && items.length < 24; i++) {
    const m = mentions[i];
    // The note window ends at the next DIFFERENT dish. A repeat of the same dish is
    // the same line item, so it must not chop its own note in half.
    const next = mentions.slice(i + 1).find((o) => o.name.toLowerCase() !== m.name.toLowerCase());
    const nextStart = next ? next.start : body.length;
    const prevEnd = i > 0 ? mentions[i - 1].end : -1;
    const [sentStart, sentEnd] = sentenceBounds(body, m.start);
    const windowEnd = Math.min(sentEnd, nextStart);

    // FORWARD first: the score normally follows the dish ("Margherita 4.5").
    let hit = numbers.find(
      (n) => !usedNumbers.has(n) && n.start >= m.end && n.start < windowEnd && isScoreFor(body, n, m.end),
    );
    // BACKWARD within the same sentence: "4.5 for the tagliatelle".
    if (!hit) {
      hit = [...numbers]
        .reverse()
        .find(
          (n) =>
            !usedNumbers.has(n) &&
            n.end <= m.start &&
            n.start >= Math.max(sentStart, prevEnd) &&
            isScoreFor(body, n, m.start, true),
        );
    }
    // An unanchored candidate only got this far because a number could score it; if
    // another dish claimed that number first, it goes back to being prose.
    if (!m.anchored && !hit) continue;
    if (hit) usedNumbers.add(hit);

    items.push({
      dish_name: m.name.trim(),
      score: hit ? hit.value : null,
      score_evidence: hit ? hit.text : null,
      note: excerptFor(body, m.start, m.end, hit ? [hit.start, hit.end] : null, prevEnd, nextStart, noteStyle),
      // WHERE, in scalars — the parser knows the exact occurrence it matched, which is
      // the whole point: searching the body for "4.5" later finds the price first.
      evidence_offset: hit ? scalarOffset(body, hit.start) : null,
      mention_text: body.slice(m.start, m.end),
      mention_offset: scalarOffset(body, m.start),
    });
  }

  const place = placeCandidateSpans(body, 1);
  return {
    place_query: place.length ? place[0].phrase : null,
    place_offset: place.length ? place[0].offset : null,
    items,
  };
}

/**
 * Could this number plausibly be THIS mention's score? The loose, window-free version of
 * isScoreFor, used by the anchor rule to tell "had proper leopard spotting" (no number
 * anywhere near it) from "had proper leopard spotting 4.5" (their own number, so their
 * own line). Deliberately generous: the loop below still decides who actually gets it.
 */
function couldScore(body: string, m: Mention, n: NumberHit): boolean {
  const [sentStart, sentEnd] = sentenceBounds(body, m.start);
  if (n.start >= m.end && n.start < sentEnd) return isScoreFor(body, n, m.end);
  // BACKWARD, and only when the number is sitting against it. A self-evident number
  // elsewhere in the sentence belongs to whatever else is in that sentence — the
  // margherita's own "4.5" must not keep "had proper leopard spotting" alive.
  if (n.end <= m.start && n.start >= sentStart) return isAdjacent(body.slice(n.end, m.start));
  return false;
}

/**
 * Is this number the score for a dish whose mention ends at `boundary`?
 * Self-evident numbers (marked / decimal / spoken half / pre-marked) always count.
 * A bare integer only counts when it is sitting right beside the dish — which is
 * exactly how the composer's score token lands in the text.
 */
function isScoreFor(body: string, n: NumberHit, boundary: number, backwards = false): boolean {
  if (n.selfEvident) return true;
  return isAdjacent(backwards ? body.slice(n.end, boundary) : body.slice(boundary, n.start));
}

/** Only whitespace and light punctuation between the dish and the number. */
function isAdjacent(gap: string): boolean {
  return /^[\s,:;.…—–-]{0,4}$/.test(gap);
}
