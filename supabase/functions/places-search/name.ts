// supabase/functions/places-search/name.ts
//
// A place's NAME, without the keywords a business pads its Google listing with:
//   "VIVIN Suk 22 - café grocery bistro - Local Organic Natural Artisan" → "VIVIN Suk 22"
//   "Pho Hung (Vietnamese Restaurant)"                                    → "Pho Hung"
//
// Two rules, nothing guessed: cut at the first spaced separator (" - ", " – ", " — ", " | ", " · ",
// " • ", or a bare "|"), then drop one trailing (…) or […]. A hyphen inside a word ("Ka-Pow") is not
// a separator. If a rule would leave fewer than two characters, the name is kept as Google gave it.
//
// MIRRORS public.clean_place_name() (0075), which the restaurants trigger runs on every stored
// Google row. This copy cleans autocomplete predictions before they are stored, so a prediction and
// the row it becomes read the same (and the blend's name-dedupe matches them). Change both together.

const SEPARATOR = /\s+[-–—|·•]\s+|\s*\|\s*/;
const TRAILING_BRACKET = /\s*[([][^)\]]*[)\]]$/;

export function cleanPlaceName(raw: string): string {
  const name = raw.replace(/\s+/g, ' ').trim();
  const head = name.split(SEPARATOR)[0].trim();
  const cut = head.length >= 2 ? head : name;
  const bare = cut.replace(TRAILING_BRACKET, '').trim();
  return bare.length >= 2 ? bare : cut;
}
