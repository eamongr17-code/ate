// supabase/functions/sort-entry/harness.ts
//
// A six-line test shim so the sorter's tests run under BOTH runtimes:
//
//   deno test --no-check supabase/functions/sort-entry/         (the deployment runtime)
//   node --test supabase/functions/sort-entry/*_test.ts         (no Deno install needed)
//
// The sorter's core (parse.ts · validate.ts · model.ts's pure halves) uses no runtime
// APIs at all, so the only thing that differs between runtimes is who registers a
// test. Deliberately dependency-free — no std/assert import, so a first run needs no
// network and the same files work in CI whichever runtime is available.

type TestFn = () => void | Promise<void>;
type Registrar = (name: string, fn: TestFn) => void;

// deno-lint-ignore no-explicit-any
const denoTest = (globalThis as any).Deno?.test as Registrar | undefined;
const nodeTest: Registrar | undefined = denoTest
  ? undefined
  : ((await import('node:test')).default as unknown as Registrar);

export const test: Registrar = denoTest ?? nodeTest!;

export function assertEquals(actual: unknown, expected: unknown, message?: string): void {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) {
    throw new Error(`${message ? message + '\n' : ''}  actual:   ${a}\n  expected: ${b}`);
  }
}

export function assert(condition: unknown, message = 'assertion failed'): void {
  if (!condition) throw new Error(message);
}
