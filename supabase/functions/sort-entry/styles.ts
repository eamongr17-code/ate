// supabase/functions/sort-entry/styles.ts
//
// STYLE TAGS (0053, closed list since 0069) — 1–3 words for what KIND of dish a line is ("pasta",
// "dumplings", "dessert"). They feed the dish's tag chips, "more like this" and a tag's results page
// (whose title IS the style), so they come ONLY from the fixed list below — never a free-form word.
// They are never shown as the user's words and never touch a score, a note or a dish name.
//
// Only the MODEL proposes them, and it is given this exact list (prompt + tool-schema enum). The stub
// proposes none: the database tags every new dish from a deterministic keyword map on its name
// (dish_style_guess, 0053), whose 40 styles are this list, in this order. A model's styles replace
// that guess on the dish (dish_apply_sorter_styles).
//
// This is the first of two identical gates — apply_entry_sort re-validates with dish_styles_from_json
// (dish_style_clean → dish_style_list(), 0069) — so a word this lets through that SQL would drop is a
// divergence, not a hole. Same rule both sides: accent-folded, lower-cased, whitespace collapsed, a
// hyphen read as a space ("dim-sum" → "dim sum"); on the list; distinct; at most 3, first mention first.
// supabase/tests/db/dish_tag_links_test.mjs pins this list against the SQL one.

export const MAX_STYLES = 3;

/** THE style list — identical to dish_style_list() (0069) and dish_style_guess's map (0053), same order. */
export const DISH_STYLES = [
  'pizza', 'pasta', 'noodles', 'dumplings', 'dim sum', 'sushi', 'burgers', 'sandwiches', 'tacos', 'wraps',
  'curry', 'stew', 'soup', 'salad', 'rice', 'dessert', 'pastry', 'bread', 'breakfast', 'bbq',
  'grilled', 'roast', 'fried', 'raw', 'dips', 'cheese', 'charcuterie', 'fries', 'potatoes', 'coffee',
  'drinks', 'seafood', 'steak', 'beef', 'chicken', 'pork', 'lamb', 'duck', 'tofu', 'vegetables',
] as const;

export type DishStyle = (typeof DISH_STYLES)[number];

const ON_THE_LIST: ReadonlySet<string> = new Set(DISH_STYLES);

/** One proposed style → its entry on the list, or null when it is not on the list. */
export function cleanStyle(raw: unknown): DishStyle | null {
  if (typeof raw !== 'string') return null;
  const s = raw
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    .replace(/-/g, ' ')
    .trim()
    .replace(/\s+/g, ' ');
  return ON_THE_LIST.has(s) ? (s as DishStyle) : null;
}

/** A model's styles for one dish → at most 3 distinct styles from the list, in the order given. */
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
