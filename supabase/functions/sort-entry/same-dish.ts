// supabase/functions/sort-entry/same-dish.ts
//
// SAME DISH, DIFFERENT WORDS (18 Oct, Eamon): "Carbonara" and "Spaghetti Carbonara" at one place are
// one dish, but a real restaurant has three pastas and three steaks, so matching must never presume.
// Two tiers, both deliberately narrow, and both only ever WITHIN ONE RESTAURANT:
//
//   1. dishKey — a spelling key. Two names with the same key are the same dish with no judgement
//      involved: accents, capitals, punctuation, "&" / "and" / "n", "the", plurals, a space inside a
//      compound ("Hot Dog" / "Hotdog"). Word ORDER is kept ("Milk Chocolate" ≠ "Chocolate Milk").
//      MIRRORED EXACTLY by public.dish_key (0071), which find_or_create_dish matches on; the db suite
//      pins the two against one table of names.
//
//   2. sameDishGate — the deterministic fence around the MODEL's "same as" (log time) and the scan's
//      proposals (existing dishes). The model may judge; this decides whether it is allowed to:
//        * every word of the shorter name matches a word of the target (equal, a prefix of 3+ letters
//          — "spag" / "spaghetti" — or one typo in a word of 5+ letters). A word the target lacks is a
//          distinguishing word: "Wagyu Carbonara" is not "Carbonara";
//        * the name says more than its category: "Steak", "Pasta", "Fried Chicken" alone never match
//          (the styles list plus a few menu headings), because the place may serve several;
//        * exactly ONE dish at the place fits. Two candidates is a guess, and a guess stays separate.
//      Anything else is refused, whatever the model said. Unsure always means separate.

import { DISH_STYLES } from './styles.ts';

/** Never a word of a dish's identity. */
const ARTICLES = new Set(['the', 'a', 'an']);

/** Spellings of the joining words, read as one. */
const JOINERS: Record<string, string> = { n: 'and', w: 'with' };

/**
 * One word, singular. Consistency matters more than grammar: both sides of every comparison go
 * through the same rules, so "Cookie" / "Cookies" both become "cooki". Mirrored by public.dish_word.
 */
export function singular(w: string): string {
  const n = w.length;
  if (n > 4 && w.endsWith('ies')) return w.slice(0, -3) + 'i';
  if (n > 3 && w.endsWith('ie')) return w.slice(0, -1);
  if (n > 3 && /[^aeiou]y$/.test(w)) return w.slice(0, -1) + 'i';
  if (n > 4 && w.endsWith('oes')) return w.slice(0, -2);
  if (n > 4 && /(?:s|x|z|ch|sh)es$/.test(w)) return w.slice(0, -2);
  if (n > 3 && w.endsWith('s') && !/(?:ss|us)$/.test(w)) return w.slice(0, -1);
  return w;
}

const FOLD: Record<string, string> = { 'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'ø': 'o', 'ł': 'l', 'đ': 'd' };

/** ASCII punctuation and symbols, the curly quotes and dashes, and whitespace: word breaks. */
const BREAKS = /[ \t\n\r\f\v!-%'-\/:-@\[-`{-~’‘“”–—·•]+/g;

/**
 * The words of a dish's identity, in order: accent-folded, lower case, "&" read as "and", articles
 * dropped, each word singular. Mirrors public.dish_words (0071).
 */
export function dishWords(name: string): string[] {
  const folded = String(name ?? '')
    .trim()
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    // the letters unaccent folds that NFD does not decompose
    .replace(/[ßæœøłđ]/g, (c) => FOLD[c])
    .replace(/&/g, ' and ');
  const out: string[] = [];
  for (const piece of folded.split(BREAKS)) {
    if (!piece) continue;
    const w = JOINERS[piece] ?? piece;
    if (ARTICLES.has(w)) continue;
    out.push(singular(w));
  }
  return out;
}

/** The spelling key: the words, run together. '' for a name with no words. */
export function dishKey(name: string): string {
  return dishWords(name).join('');
}

/** Words that name a kind of dish or a menu heading, not a dish. */
const GENERIC = new Set(
  [
    ...DISH_STYLES.flatMap((s) => s.split(' ')),
    'special', 'dish', 'plate', 'main', 'entree', 'starter', 'side', 'snack', 'share', 'sharing',
    'drink', 'cocktail', 'wine', 'beer', 'juice', 'tea', 'sweet', 'cake', 'meat', 'fish', 'veg',
    'house', 'and', 'with', 'of', 'on', 'in', 'or',
  ].map(singular),
);

/** Only a category: every word is a kind of dish ("Steak", "Fried Chicken", "Pasta"). */
export function onlyGeneric(words: string[]): boolean {
  return words.length > 0 && words.every((w) => GENERIC.has(w));
}

/** At most one edit (substitution, insertion or deletion) apart. */
function oneEdit(a: string, b: string): boolean {
  if (a === b) return true;
  if (Math.abs(a.length - b.length) > 1) return false;
  let i = 0;
  let j = 0;
  let edits = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      i++;
      j++;
      continue;
    }
    if (++edits > 1) return false;
    if (a.length > b.length) i++;
    else if (b.length > a.length) j++;
    else {
      i++;
      j++;
    }
  }
  return edits + (a.length - i) + (b.length - j) <= 1;
}

/** One of the shorter name's words standing for one of the target's. */
function wordFits(w: string, t: string): boolean {
  if (w === t) return true;
  if (w.length >= 3 && t.startsWith(w)) return true; // "spag" → "spaghetti", "bol" → "bolognese"
  return w.length >= 5 && t.length >= 5 && oneEdit(w, t); // "carbonarra" → "carbonara"
}

/** Every word of `short` fits a distinct word of `long`, in order. */
function wordsFit(short: string[], long: string[]): boolean {
  let at = 0;
  for (const w of short) {
    while (at < long.length && !wordFits(w, long[at])) at++;
    if (at >= long.length) return false;
    at++;
  }
  return true;
}

/**
 * Could `name` be another way of naming `target`? Symmetric: either may be the shorter one. Only
 * the spelling and the words decide here; whether they ARE the same dish is the model's call, and
 * whether exactly one dish fits is sameDishGate's.
 */
export function couldBeSame(name: string, target: string): boolean {
  const a = dishWords(name);
  const b = dishWords(target);
  if (!a.length || !b.length) return false;
  if (a.join('') === b.join('')) return true;
  const [short, long] = a.length <= b.length ? [a, b] : [b, a];
  if (onlyGeneric(short)) return false;
  return wordsFit(short, long);
}

/**
 * The fence around a "same dish" claim. `target` must be one of `menu` (the place's dish names), and
 * no other dish there may fit `name` too. Returns the target's own spelling, or null (separate).
 */
export function sameDishGate(name: string, target: string, menu: string[]): string | null {
  const key = (s: string) => s.trim().replace(/\s+/g, ' ').toLowerCase();
  const onMenu = menu.find((m) => key(m) === key(target));
  if (!onMenu || key(onMenu) === key(name)) return null;
  if (!couldBeSame(name, onMenu)) return null;
  const rivals = menu.filter((m) => key(m) !== key(onMenu) && key(m) !== key(name) && couldBeSame(name, m));
  // A rival with the target's own spelling key is the same dish twice on the menu (a duplicate the
  // scan will propose merging), not a second candidate.
  const targetKey = dishKey(onMenu);
  return rivals.every((r) => dishKey(r) === targetKey) ? onMenu : null;
}
