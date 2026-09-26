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
  /**
   * WHERE in the body `score_evidence` was matched — a 0-based UNICODE SCALAR offset
   * (see ./offsets.ts). The client rebuilds its inline score token from this instead
   * of searching the body for the number, which mis-hits a price ("$14.50" for a 4.5).
   * null whenever there is no score.
   */
  evidence_offset: number | null;
  /**
   * The verbatim slice of the body that NAMED this dish. It can differ from
   * `dish_name` in case and spacing, because `dish_name` may be the menu's spelling.
   */
  mention_text: string | null;
  /** Scalar offset of `mention_text` in the body. */
  mention_offset: number | null;
  /**
   * Dietary tag codes (gf · df · v · vg · nf), canonical order. Set ONLY by
   * ./tags.ts attachTagTokens from spans the client marked as tag tokens — never by the
   * parser or the model (validateItem drops anything they put here). Absent before that step.
   */
  tags?: string[];
};

/** What the sorter proposes for one entry. */
export type SortPlan = {
  /**
   * The phrase in the words that looks like a place name. The FUNCTION resolves it
   * against restaurants we already hold; the parser only points at it. A place is
   * never invented and never derived from location (DESIGN rule 8).
   */
  place_query: string | null;
  /** Scalar offset of `place_query` in the body — the client's place token. */
  place_offset: number | null;
  items: SortItem[];
};

/** A phrase in the words that might name a place, with where it sits (scalar offset). */
export type PlaceCandidate = {
  phrase: string;
  offset: number;
};

/** Everything the pure parser is allowed to know. No IO, no clock, no randomness. */
export type ParseInput = {
  body: string;
  /** Dish names already on the menu at the matched restaurant. Empty when there is no place. */
  knownDishes?: string[];
  /** Character spans to ignore when hunting for dishes (e.g. the matched place name). */
  excludeSpans?: Array<[number, number]>;
  /**
   * The attached place's name(s) — the restaurant row's name and the phrase in the words
   * that matched it. Wherever they appear in `body` they are excluded from the dish hunt,
   * so a venue name can neither become a dish nor be swallowed into the front of one
   * ("Baby Pizza San Danielle Pizza 3.5" → `San Danielle Pizza`, not `Pizza San Danielle
   * Pizza`). Only names the FUNCTION resolved belong here — never the parser's own place
   * candidate, which for "Margherita 4.5" is the dish.
   */
  placeNames?: string[];
  /**
   * How a dish note is cut out of the words:
   *   'clause' (DEFAULT)  — what follows the dish and its score, cut at the next dish.
   *                         This is what the approved receipt prints
   *                         (design/v1/Entry: `"A bit flat after that."`): a quote that
   *                         repeats the line's own dish name and score reads badly under
   *                         it. Dangling glue and punctuation are trimmed off the ends.
   *   'sentence'          — the whole sentence the dish is mentioned in, when that
   *                         sentence is the dish's own. Keeps what they said BEFORE
   *                         naming it, at the cost of repeating the name and score.
   * Both are verbatim substrings (rule 9); this only chooses where the cut is.
   */
  noteStyle?: 'sentence' | 'clause';
};

export type SorterMode = 'stub' | 'model';
