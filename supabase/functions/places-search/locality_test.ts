// supabase/functions/places-search/locality_test.ts
//
// The `city` mangle, pinned. Runs under BOTH runtimes, like the sorter's suites:
//
//   node --test supabase/functions/places-search/locality_test.ts
//   deno test --no-check supabase/functions/places-search/locality_test.ts
//
// It imports the REAL locality.ts, and every input below is a genuine Google
// `formattedAddress` shape for a Melbourne venue — including the exact one that used to produce
// "361 Little Bourke St, Melbourne VIC 3000" in `restaurants.city`.

import { localityFromAddress } from './locality.ts';

// Six-line runtime shim (same idea as sort-entry/harness.ts): no std/assert import, so a first run
// needs no network and the same file works wherever CI happens to have a runtime.
type TestFn = () => void | Promise<void>;
type Registrar = (name: string, fn: TestFn) => void;
// deno-lint-ignore no-explicit-any
const denoTest = (globalThis as any).Deno?.test as Registrar | undefined;
const nodeTest: Registrar | undefined = denoTest
  ? undefined
  : ((await import('node:test')).default as unknown as Registrar);
const test: Registrar = denoTest ?? nodeTest!;

function assertEquals(actual: unknown, expected: unknown, message?: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${message ? message + '\n' : ''}  actual:   ${JSON.stringify(actual)}\n` +
        `  expected: ${JSON.stringify(expected)}`,
    );
  }
}

test('the suburb in front of the state token wins — the mangle this replaced', () => {
  assertEquals(
    localityFromAddress('361 Little Bourke St, Melbourne VIC 3000, Australia'),
    'Melbourne',
  );
  assertEquals(
    localityFromAddress('125 Flinders Ln, Melbourne VIC 3000, Australia'),
    'Melbourne',
  );
  assertEquals(
    localityFromAddress('Shop 5, 123 Smith St, Collingwood VIC 3066, Australia'),
    'Collingwood',
  );
  // A two-word suburb keeps both words; `[^,]+?` cannot cross a comma, so it cannot reach back into
  // the street line.
  assertEquals(
    localityFromAddress('1 Bay St, Port Melbourne VIC 3207, Australia'),
    'Port Melbourne',
  );
});

test('the state list is case-sensitive, so a street name is never mistaken for a state', () => {
  // Lower-case 'wa' inside "Wallace Ave" must not win; the real state token does.
  assertEquals(localityFromAddress('12 Wallace Ave, Toorak VIC 3142, Australia'), 'Toorak');
  // "SAndringham" holds no word-boundaried SA; the VIC token decides.
  assertEquals(localityFromAddress('2 Bay Rd, Sandringham VIC 3191, Australia'), 'Sandringham');
});

test('no state token: the component before the country', () => {
  assertEquals(localityFromAddress('Chin Chin, Flinders Lane, Melbourne, Australia'), 'Melbourne');
  assertEquals(localityFromAddress('123 Smith St, Fitzroy, Australia'), 'Fitzroy');
});

test('a bare locality, with or without the country', () => {
  assertEquals(localityFromAddress('Melbourne, Australia'), 'Melbourne');
  assertEquals(localityFromAddress('Fitzroy'), 'Fitzroy');
});

test('nothing to name is an empty string, never a guess', () => {
  // `restaurants.city` is NOT NULL and place_locality() reads '' as absent, so the client draws no
  // chip. '' is the honest answer, not a placeholder.
  assertEquals(localityFromAddress(''), '');
  assertEquals(localityFromAddress('   '), '');
  assertEquals(localityFromAddress(null), '');
  assertEquals(localityFromAddress(undefined), '');
});

test('interstate addresses resolve like Victorian ones', () => {
  assertEquals(localityFromAddress('1 Martin Pl, Sydney NSW 2000, Australia'), 'Sydney');
});

test('abroad: Google\'s own town name wins when it sent components', () => {
  const bangkok = [
    { longText: 'Khlong Toei Nuea', types: ['sublocality_level_2', 'sublocality', 'political'] },
    { longText: 'Watthana', types: ['sublocality_level_1', 'sublocality', 'political'] },
    { longText: 'Bangkok', types: ['locality', 'political'] },
    { longText: '10110', types: ['postal_code'] },
  ];
  assertEquals(localityFromAddress('12 Sukhumvit Soi 11, Khlong Toei Nuea, Watthana, Bangkok 10110, Thailand', bangkok), 'Bangkok');
  // No locality: the district rather than a guess.
  assertEquals(localityFromAddress('Some Rd, Watthana, Bangkok 10110, Thailand', bangkok.filter((c) => !c.types.includes('locality'))), 'Watthana');
});

test('abroad without components: the component before the country, postcode dropped', () => {
  assertEquals(localityFromAddress('12 Sukhumvit Soi 11, Khlong Toei Nuea, Watthana, Bangkok 10110, Thailand'), 'Bangkok');
  assertEquals(localityFromAddress('Charoen Prathet Rd, Chiang Mai 50100, Thailand'), 'Chiang Mai');
  assertEquals(localityFromAddress('Rue de Rivoli, 75001 Paris, France'), 'Paris');
});

test('an Australian address ignores components (the state rule already answered)', () => {
  assertEquals(localityFromAddress('119 Rose St, Fitzroy VIC 3065, Australia', [{ longText: 'Melbourne', types: ['locality'] }]), 'Fitzroy');
});
