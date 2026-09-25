// supabase/functions/places-search/locality.ts
//
// The suburb, out of a Google `formattedAddress`. The PURE half of the fix for the `city` mangle —
// its own module so locality_test.ts can exercise the REAL implementation (index.ts is a Deno.serve
// entrypoint that reads secrets on import and cannot be imported by a test).
//
// THE BUG IT REPLACES (index.ts, op=details and the searchNearby fallback):
//
//     const parts = formattedAddress.split(',').map(s => s.trim());
//     const city  = parts.length >= 3 ? `${parts[parts.length - 3]}, ${parts[parts.length - 2]}`
//                                     : (parts[1] ?? '');
//
// For "361 Little Bourke St, Melbourne VIC 3000, Australia" that stored
//     "361 Little Bourke St, Melbourne VIC 3000"
// in `restaurants.city` — a street line, a suburb, a state and a postcode in the column every screen
// prints as the suburb chip. That is the string 0029 had to write `place_locality()` to undo on read.
//
// FORWARD-ONLY, AND NO BACKFILL. New rows get a bare locality ("Melbourne"), which is exactly what
// `place_locality()`'s stored-city branch already handles, so the read path is right for old and new
// rows alike. Existing rows keep their mangled `city`: rewriting real rows to fix a display string
// is not something this team does, and the read derivation makes it unnecessary.
//
// The rules below mirror `public.place_locality(address, city)` (migration 0029) deliberately — one
// question, one answer, whether it is asked on write or on read:
//   1. the address component in FRONT of an AU state token → "Melbourne". Case-SENSITIVE state list
//      on purpose: a lower-case 'wa' would otherwise match inside "Wallace Ave".
//   2. the component before the country, for an address with no state token.
//   3. a two- or one-component address: the first component (Google always ends an AU
//      formattedAddress with the country, so "Melbourne, Australia" is a suburb and a country).
//   '' when we cannot honestly name one — `restaurants.city` is NOT NULL, and `place_locality()`
//   already treats '' as absent, so the client draws no chip rather than a guess.

// `[^,]+?` cannot cross a comma, so the capture is one address component and nothing more.
const AU_STATE_LOCALITY_RE = /([^,]+?)\s+(?:VIC|NSW|QLD|SA|WA|TAS|NT|ACT)\b/;

/**
 * The bare locality (suburb) for a Google `formattedAddress`, or `''` when it names none.
 */
export function localityFromAddress(formattedAddress: string | null | undefined): string {
  const address = (formattedAddress ?? '').trim();
  if (address === '') return '';

  // 1. "<suburb> <STATE> <post>" — the shape every Australian formatted address uses.
  const match = AU_STATE_LOCALITY_RE.exec(address);
  if (match) {
    const locality = match[1].trim();
    if (locality !== '') return locality;
  }

  const parts = address
    .split(',')
    .map((part) => part.trim())
    .filter((part) => part !== '');

  // 2. No state token: the component before the country.
  if (parts.length >= 3) return parts[parts.length - 2];

  // 3. "Melbourne, Australia" / "Melbourne".
  if (parts.length >= 1) return parts[0];

  return '';
}
