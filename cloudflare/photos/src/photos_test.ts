// cloudflare/photos/src/photos_test.ts — the photo store's rules.   node --test src/*_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isServiceKey, ownKeys, parseKey, publicUrl, purgeUser, sniff, supabaseUrl, userId, type Store } from './photos.ts';

const U = '00000000-0000-4000-8000-00000000000a';
const V = '00000000-0000-4000-8000-00000000000b';

test('keys: only our two buckets, under a uid folder, safe characters, no ..', () => {
  assert.deepEqual(parseKey(`review-photos/${U}/e-0.jpg`), { bucket: 'review-photos', path: `${U}/e-0.jpg`, key: `review-photos/${U}/e-0.jpg` });
  assert.equal(parseKey(`/review-photos/${U}/list-covers/l.jpg`)?.key, `review-photos/${U}/list-covers/l.jpg`);
  assert.equal(parseKey(`avatars/${U}/avatar.jpg`)?.bucket, 'avatars');
  for (const bad of [
    `feedback-screenshots/${U}/x.png`, `review-photos/not-a-uid/x.jpg`, `review-photos/${U.toUpperCase()}/x.jpg`,
    `review-photos/${U}/../${V}/x.jpg`, `review-photos/${U}/%2e%2e/x.jpg`, `review-photos/${U}/a b.jpg`,
    `review-photos/${U}`, `review-photos/${U}/`, 'review-photos', '', `review-photos/${U}/x.jpg?v=1`,
    `review-photos/${U}/%E0%A4%A.jpg`, `review-photos/${U}/a/b/c/d.jpg`,
  ]) assert.equal(parseKey(bad), null, bad);
});

test('sniff: JPEG and PNG by their bytes, nothing else', () => {
  assert.equal(sniff(new Uint8Array([0xff, 0xd8, 0xff, 0xe0])), 'image/jpeg');
  assert.equal(sniff(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), 'image/png');
  assert.equal(sniff(new TextEncoder().encode('<svg onload=alert(1)>')), null);
  assert.equal(sniff(new Uint8Array([0x47, 0x49, 0x46, 0x38])), null, 'GIF');
  assert.equal(sniff(new Uint8Array([])), null);
});

test('URLs: one prefix swap between Supabase and R2', () => {
  const key = `review-photos/${U}/e-0.jpg`;
  assert.equal(publicUrl('https://photos.x.app/', key), `https://photos.x.app/${key}`);
  assert.equal(supabaseUrl('https://ref.supabase.co', key), `https://ref.supabase.co/storage/v1/object/public/${key}`);
});

test('ownKeys: yours only, ≤ 100, deduped; one stranger key refuses the lot', () => {
  assert.equal(ownKeys([`review-photos/${U}/a.jpg`, `review-photos/${U}/a.jpg`], U)?.length, 1);
  assert.equal(ownKeys([`review-photos/${U}/a.jpg`, `review-photos/${V}/a.jpg`], U), null);
  assert.equal(ownKeys([], U), null);
  assert.equal(ownKeys('review-photos/x', U), null);
  assert.equal(ownKeys(Array.from({ length: 101 }, (_, i) => `review-photos/${U}/${i}.jpg`), U), null);
});

const fakeFetch = (status: number, body: unknown, seen: { url?: string; headers?: HeadersInit }[] = []) =>
  (async (url: string, init?: RequestInit) => {
    seen.push({ url, headers: init?.headers });
    return new Response(JSON.stringify(body), { status });
  }) as unknown as typeof fetch;

test('userId: Supabase Auth decides; anything but a 200 with a uid is signed out', async () => {
  const seen: { url?: string; headers?: HeadersInit }[] = [];
  assert.equal(await userId('tok', 'https://ref.supabase.co/', 'anon', fakeFetch(200, { id: U.toUpperCase() }, seen)), U);
  assert.equal(seen[0].url, 'https://ref.supabase.co/auth/v1/user');
  assert.deepEqual(seen[0].headers, { apikey: 'anon', Authorization: 'Bearer tok' });
  assert.equal(await userId('tok', 'https://ref.supabase.co', 'anon', fakeFetch(401, {})), null);
  assert.equal(await userId('tok', 'https://ref.supabase.co', 'anon', fakeFetch(200, { id: 'x' })), null);
  assert.equal(await userId('', 'https://ref.supabase.co', 'anon', fakeFetch(200, { id: U })), null);
  const boom = (async () => { throw new Error('down'); }) as unknown as typeof fetch;
  assert.equal(await userId('tok', 'https://ref.supabase.co', 'anon', boom), null);
});

test('isServiceKey: only a key the admin endpoint accepts', async () => {
  assert.equal(await isServiceKey('k', 'https://ref.supabase.co', fakeFetch(200, { users: [] })), true);
  assert.equal(await isServiceKey('k', 'https://ref.supabase.co', fakeFetch(403, {})), false);
  assert.equal(await isServiceKey('', 'https://ref.supabase.co', fakeFetch(200, {})), false);
});

function fakeStore(keys: string[]): Store & { left: Set<string> } {
  const left = new Set(keys);
  return {
    left,
    async list({ prefix, limit = 1000 }) {
      const all = [...left].filter((k) => k.startsWith(prefix)).sort();
      return { objects: all.slice(0, limit).map((key) => ({ key })), truncated: all.length > limit };
    },
    async delete(ks) { for (const k of [ks].flat()) left.delete(k); },
  };
}

test('purgeUser: every file in both buckets under the uid, nobody else\'s', async () => {
  const many = Array.from({ length: 2500 }, (_, i) => `review-photos/${U}/e-${i}.jpg`);
  const store = fakeStore([...many, `review-photos/${U}/list-covers/l.jpg`, `avatars/${U}/avatar.jpg`,
    `review-photos/${V}/e-0.jpg`, `avatars/${V}/avatar.jpg`, `review-photos/${U}x/e.jpg`]);
  assert.equal(await purgeUser(store, U), 2502);
  assert.deepEqual([...store.left].sort(), [`avatars/${V}/avatar.jpg`, `review-photos/${U}x/e.jpg`, `review-photos/${V}/e-0.jpg`]);
  await assert.rejects(purgeUser(store, ''), /not a user id/);
  await assert.rejects(purgeUser(store, 'x/../'), /not a user id/);
});
