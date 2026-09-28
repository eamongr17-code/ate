// supabase/functions/sort-entry/styles.ts
//
// STYLE TAGS (0053) — 1–3 lowercase words for what KIND of dish a line is ("pasta", "dumplings",
// "dessert"). They feed the dish's tag chips, "more like this" and a tag's results page; they are
// never shown as the user's words and never touch a score, a note or a dish name.
//
// Only the MODEL proposes them. The stub proposes none: the database tags every new dish from a
// deterministic keyword map on its name (dish_style_guess, 0053), so a stub sort still yields styles.
// A model's styles replace that guess on the dish (dish_apply_sorter_styles).
//
// This is the first of two identical gates — apply_entry_sort re-validates with dish_styles_from_json
// — so a word this lets through that SQL would drop is a divergence, not a hole. Same rule both sides:
// accent-folded, lower-cased, whitespace collapsed; 1–4 a–z words joined by a space or a hyphen;
// 3–24 characters; not a diet word or a filler; distinct; at most 3, first mention first.

export const MAX_STYLES = 3;
export const MAX_STYLE_LENGTH = 24;

const STYLE_SHAPE = /^[a-z]+([ -][a-z]+){0,3}$/;

/** Words that are not a style: diet claims (those are the user's chips, never inferred) and filler. */
export const NOT_A_STYLE = new Set([
  'vegan', 'vegetarian', 'veggo', 'plant based', 'plant-based',
  'gluten free', 'gluten-free', 'dairy free', 'dairy-free', 'nut free', 'nut-free',
  'food', 'dish', 'dishes', 'meal', 'other', 'misc', 'good', 'great', 'delicious',
]);

/** One proposed style → the clean word, or null when it is not an acceptable style tag. */
export function cleanStyle(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const s = raw
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    .trim()
    .replace(/\s+/g, ' ');
  if (s.length < 3 || s.length > MAX_STYLE_LENGTH) return null;
  if (!STYLE_SHAPE.test(s)) return null;
  if (NOT_A_STYLE.has(s)) return null;
  return s;
}

/** A model's styles for one dish → at most 3 clean, distinct words, in the order given. */
export function cleanStyles(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const r of raw.slice(0, 12)) {
    const s = cleanStyle(r);
    if (s && !out.includes(s)) out.push(s);
    if (out.length >= MAX_STYLES) break;
  }
  return out;
}
