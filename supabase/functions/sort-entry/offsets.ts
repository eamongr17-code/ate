// supabase/functions/sort-entry/offsets.ts
//
// THE OFFSET UNIT, in one place, because getting it wrong is silent.
//
// Every offset the sorter puts on the wire — `evidence_offset`, `mention_offset`,
// `place_offset` — is a **0-based UNICODE SCALAR (code point) offset into
// `entries.body`**, and every length beside it is counted in the same unit.
//
// WHY SCALARS AND NOT UTF-16:
//   * Postgres counts CODE POINTS. In a UTF8 database `position()`, `substring()` and
//     `char_length()` are all character-based, so a scalar offset is the only unit the
//     database can verify and recompute without conversion machinery of its own.
//   * JavaScript strings are UTF-16, so THIS end converts (below).
//   * Swift's `NSRange`/`utf16` is UTF-16 too, so the CLIENT converts as well —
//     exactly, with stdlib APIs:
//         let i = body.unicodeScalars.index(body.unicodeScalars.startIndex, offsetBy: off)
//         let j = body.unicodeScalars.index(i, offsetBy: len)
//         let token = String(body.unicodeScalars[i..<j])          // the slice
//         let ns = NSRange(i..<j, in: body)                        // if UTF-16 is wanted
//
// One astral character (any emoji) before the token is enough to make UTF-16 and
// scalar offsets disagree, and "🍝" is in the fixture corpus precisely because a diner
// writing an emoji before their score is not an edge case. Hence: spelled out, tested,
// never inferred.

/** Length of `s` in Unicode scalars (code points), not UTF-16 code units. */
export function scalarLength(s: string): number {
  let n = 0;
  for (const _ of s) n++;
  return n;
}

/** Convert a JS (UTF-16) index into `body` to a Unicode scalar offset. */
export function scalarOffset(body: string, utf16Index: number): number {
  if (utf16Index <= 0) return 0;
  return scalarLength(body.slice(0, utf16Index));
}

/** The `length`-scalar slice of `body` starting at scalar `offset`. */
export function sliceScalars(body: string, offset: number, length: number): string {
  if (offset < 0 || length <= 0) return '';
  return [...body].slice(offset, offset + length).join('');
}

/**
 * The offset we are willing to publish for `text` inside `body`.
 *
 * VERIFIED TRUST, the same shape as DESIGN rule 7: a claimed offset is honoured only
 * when the body really says `text` there. Otherwise we fall back to the FIRST
 * occurrence, and to null when there is none — never to a guess. (The claim matters:
 * the first occurrence of "4.5" may be a price, which is the bug this exists to kill.)
 */
export function verifiedScalarOffset(
  body: string,
  text: string | null | undefined,
  claimed?: number | null,
): number | null {
  if (!body || !text) return null;
  const len = scalarLength(text);
  if (
    typeof claimed === 'number' &&
    Number.isInteger(claimed) &&
    claimed >= 0 &&
    sliceScalars(body, claimed, len) === text
  ) {
    return claimed;
  }
  const at = body.indexOf(text);
  return at < 0 ? null : scalarOffset(body, at);
}
