// supabase/functions/delete-account/purge_test.ts — the storage purge against a fake bucket.

import { test, assert, assertEquals } from '../sort-entry/harness.ts';
import { purgeAccount, purgeFolder, type Bucket } from './purge.ts';

/** A bucket over a flat set of object paths, listing like Supabase: files one level, folders as id-less rows. */
function fakeBucket(paths: string[], opts: { failRemove?: boolean } = {}): Bucket & { left: Set<string> } {
  const left = new Set(paths);
  return {
    left,
    async list(path, { limit }) {
      const seen = new Map<string, string | null>();
      for (const p of left) {
        if (!p.startsWith(path + '/')) continue;
        const rest = p.slice(path.length + 1);
        const [head, ...tail] = rest.split('/');
        seen.set(head, tail.length ? null : `id-${p}`);
      }
      return { data: [...seen].slice(0, limit).map(([name, id]) => ({ name, id })), error: null };
    },
    async remove(ps) {
      if (opts.failRemove) return { data: null, error: { message: 'boom' } };
      const gone = ps.filter((p) => left.delete(p));
      return { data: gone.map((name) => ({ name })), error: null };
    },
  };
}

const U = '00000000-0000-4000-8000-00000000000a';
const OTHER = '00000000-0000-4000-8000-00000000000b';

test('purgeAccount: photos, list covers and the avatar go; nobody else\'s files are touched', async () => {
  const photos = fakeBucket([
    `${U}/1-0.jpg`, `${U}/1-1.jpg`, `${U}/list-covers/L.jpg`, `${OTHER}/2-0.jpg`, `${OTHER}/list-covers/M.jpg`,
    ...Array.from({ length: 250 }, (_, i) => `${U}/many-${i}.jpg`),
  ]);
  const avatars = fakeBucket([`${U}/avatar.jpg`, `${OTHER}/avatar.jpg`]);
  const n = await purgeAccount((b) => (b === 'avatars' ? avatars : photos), U);
  assertEquals(n, 254);
  assertEquals([...photos.left].sort(), [`${OTHER}/2-0.jpg`, `${OTHER}/list-covers/M.jpg`]);
  assertEquals([...avatars.left], [`${OTHER}/avatar.jpg`]);
});

test('purgeAccount: refuses anything that is not a user id (no path tricks)', async () => {
  let threw = false;
  try {
    await purgeAccount(() => fakeBucket([]), '../');
  } catch {
    threw = true;
  }
  assert(threw, 'a non-uuid folder is refused');
});

test('purgeFolder: a storage error is thrown, so the queue row stays for a retry', async () => {
  let threw = false;
  try {
    await purgeFolder(fakeBucket([`${U}/a.jpg`], { failRemove: true }), U);
  } catch {
    threw = true;
  }
  assert(threw);
});
