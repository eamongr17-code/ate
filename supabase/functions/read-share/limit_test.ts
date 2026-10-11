// supabase/functions/read-share/limit_test.ts

import { test, assertEquals } from '../sort-entry/harness.ts';
import { READ_SHARE_LIMIT, READ_SHARE_WINDOW_S, WindowLimiter } from './limit.ts';

test('30 reads per 10 minutes per user, fixed window', () => {
  assertEquals([READ_SHARE_LIMIT, READ_SHARE_WINDOW_S], [30, 600]);
  const l = new WindowLimiter();
  const t0 = 1_700_000_400_000; // a window boundary (multiple of 600 s)
  for (let i = 0; i < 30; i++) assertEquals(l.hit('u1', t0 + i), true);
  assertEquals(l.hit('u1', t0 + 31), false, 'the 31st is refused');
  assertEquals(l.hit('u2', t0 + 32), true, 'per user');
  assertEquals(l.hit('u1', t0 + 600_000), true, 'a new window resets');
});
