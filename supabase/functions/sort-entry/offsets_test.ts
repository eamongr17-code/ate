// supabase/functions/sort-entry/offsets_test.ts
//
//   deno test --no-check supabase/functions/sort-entry/
//   node --test supabase/functions/sort-entry/offsets_test.ts
//
// THE UNIT, pinned. An offset that is off by one is not a cosmetic bug: the client
// slices the body at it, so the token lands on the wrong characters — and the failure is
// invisible until someone writes an emoji.

import { test, assert, assertEquals } from './harness.ts';
import { scalarLength, scalarOffset, sliceScalars, verifiedScalarOffset } from './offsets.ts';

const PASTA = 'Tipo 00 🍝 tagliatelle 4.5';

test('scalarLength counts code points, not UTF-16 code units', () => {
  assertEquals('🍝'.length, 2, 'JS says two — this is the trap');
  assertEquals(scalarLength('🍝'), 1);
  assertEquals(scalarLength('ragù'), 4);
  assertEquals(scalarLength(''), 0);
  assertEquals(scalarLength(PASTA), PASTA.length - 1, 'one surrogate pair, one unit of difference');
});

test('scalarOffset converts a JS index to a scalar offset', () => {
  const at = PASTA.indexOf('4.5');
  assertEquals(at, 23);
  assertEquals(scalarOffset(PASTA, at), 22, 'the emoji ahead of it is worth one, not two');
  assertEquals(scalarOffset(PASTA, 0), 0);
  assertEquals(scalarOffset(PASTA, -5), 0);
});

test('sliceScalars is the inverse — the client slices the body exactly this way', () => {
  assertEquals(sliceScalars(PASTA, 22, 3), '4.5');
  assertEquals(sliceScalars(PASTA, 8, 1), '🍝');
  assertEquals(sliceScalars(PASTA, 0, 7), 'Tipo 00');
  assertEquals(sliceScalars(PASTA, 5, 0), '');
  assertEquals(sliceScalars(PASTA, -1, 3), '');
});

test('a CORRECT claimed offset is honoured — even when an earlier occurrence exists', () => {
  // The whole point: "4.5" appears first inside a PRICE. The sorter matched the second
  // one and says so; a plain search would have found the price.
  const body = 'The tagliatelle was $14.50. Tiramisu 4.5, fine.';
  const priceAt = body.indexOf('4.5');
  const scoreAt = body.lastIndexOf('4.5');
  assert(priceAt < scoreAt, 'the price must come first for this test to mean anything');
  assertEquals(verifiedScalarOffset(body, '4.5', scoreAt), scoreAt);
  assertEquals(verifiedScalarOffset(body, '4.5', null), priceAt, 'no claim → first occurrence');
});

test('a WRONG claimed offset is not trusted; it falls back to the first occurrence', () => {
  const body = 'Kingfish 4.5, unreal.';
  const real = body.indexOf('4.5');
  assertEquals(verifiedScalarOffset(body, '4.5', 0), real);
  assertEquals(verifiedScalarOffset(body, '4.5', 9999), real);
  assertEquals(verifiedScalarOffset(body, '4.5', -3), real);
  assertEquals(verifiedScalarOffset(body, '4.5', 1.5), real, 'a fractional offset is not an offset');
});

test('text that is not in the words has no offset, and nothing is invented', () => {
  assertEquals(verifiedScalarOffset('Kingfish 4.5', '5 stars', 3), null);
  assertEquals(verifiedScalarOffset('Kingfish 4.5', '', 0), null);
  assertEquals(verifiedScalarOffset('Kingfish 4.5', null), null);
  assertEquals(verifiedScalarOffset('', '4.5', 0), null);
});

test('case matters, exactly as it does for Postgres position()', () => {
  assertEquals(verifiedScalarOffset('Kingfish 4.5', 'kingfish', 0), null);
  assertEquals(verifiedScalarOffset('Kingfish 4.5', 'Kingfish', 0), 0);
});
