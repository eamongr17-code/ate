// supabase/functions/sort-entry/types.ts
//
// The sorter's wire + internal shapes. Kept in one tiny module with no runtime
// dependencies so the parser, the validator, the model adapter, the fixtures and the
// tests all agree by construction.

/** One receipt line the sorter proposes. */
export type SortItem = {
  /** The dish, as the user's words name it. Resolved to a dishes row by 0021's find_or_create_dish. */
  dish_name: string;
  /** The user's score, 0.5-5.0 in half steps, or null when they never gave a number (DESIGN rule 7). */
  score: number | null;
  /**
   * The LITERAL slice of the entry body that justified `score`. apply_entry_sort
   * drops any score whose evidence is not a substring of the body, so this is not
   * decoration — without it the score does not survive the write.
   */
  score_evidence: string | null;
  /** A verbatim excerpt of the user's words about this dish, or null (DESIGN rule 9). */
  note: string | null;
};

/** What the sorter proposes for one entry. */
export type SortPlan = {
  /**
   * The phrase in the words that looks like a place name. The FUNCTION resolves it
   * against restaurants we already hold; the parser only points at it. A place is
   * never invented and never derived from location (DESIGN rule 8).
   */
  place_query: string | null;
  items: SortItem[];
};

/** Everything the pure parser is allowed to know. No IO, no clock, no randomness. */
export type ParseInput = {
  body: string;
  /** Dish names already on the menu at the matched restaurant. Empty when there is no place. */
  knownDishes?: string[];
  /** Character spans to ignore when hunting for dishes (e.g. the matched place name). */
  excludeSpans?: Array<[number, number]>;
};

export type SorterMode = 'stub' | 'model';
