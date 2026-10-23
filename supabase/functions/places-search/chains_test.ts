// supabase/functions/places-search/chains_test.ts
//
//   node --test supabase/functions/places-search/chains_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { googleWebsite, linkChains, websiteHost } from './chains.ts';

test('websiteHost: lower case, no www, no path', () => {
  assert.equal(websiteHost('https://www.GuzmanyGomez.com.au/locations/fitzroy?utm=x'), 'guzmanygomez.com.au');
  assert.equal(websiteHost('http://order.grilld.com.au'), 'order.grilld.com.au');
  assert.equal(websiteHost('nandos.com.au'), 'nandos.com.au');
  assert.equal(websiteHost('www2.example.com'), 'example.com');
  assert.equal(websiteHost(''), null);
  assert.equal(websiteHost(undefined), null);
  assert.equal(websiteHost('not a url'), null);
});

test('googleWebsite asks for the website field only', async () => {
  let seen: { url: string; mask: string } | null = null;
  const fake = (async (url: string, init: RequestInit) => {
    seen = { url, mask: (init.headers as Record<string, string>)['X-Goog-FieldMask'] };
    return new Response(JSON.stringify({ websiteUri: 'https://www.gyg.com.au/' }), { status: 200 });
  }) as unknown as typeof fetch;
  assert.deepEqual(await googleWebsite('k', 'abc', fake), { ok: true, host: 'gyg.com.au' });
  assert.equal(seen!.mask, 'websiteUri');
  assert.match(seen!.url, /\/v1\/places\/abc$/);
  const down = (async () => new Response('{}', { status: 500 })) as unknown as typeof fetch;
  assert.deepEqual(await googleWebsite('k', 'abc', down), { ok: false, host: null });
});

test('linkChains fetches only unchecked websites, records them and links every candidate', async () => {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const db = {
    rpc: async (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      if (fn === 'chain_candidates') {
        return { data: [
          { restaurant_id: 'a', google_place_id: 'ga', checked: false },
          { restaurant_id: 'b', google_place_id: 'gb', checked: true },
          { restaurant_id: 'c', google_place_id: 'gc', checked: false },
        ], error: null };
      }
      return { data: ['chain-1'], error: null };
    },
  };
  const asked: string[] = [];
  const out = await linkChains(db, ['a'], async (id) => {
    asked.push(id);
    return id === 'gc' ? { ok: false, host: null } : { ok: true, host: 'gyg.com.au' };
  });
  assert.deepEqual(asked, ['ga', 'gc'], 'a checked place is never fetched again');
  assert.deepEqual(calls[1], {
    fn: 'chain_record_and_link',
    args: { p_websites: [{ id: 'a', host: 'gyg.com.au' }], p_ids: ['a', 'b', 'c'] },
  }, 'a failed fetch is not recorded, so it is asked again later');
  assert.deepEqual(out, { candidates: 3, fetched: 1, chains: ['chain-1'] });
});

test('linkChains: nothing to ask, nothing fetched; the fetch cap holds', async () => {
  const none = { rpc: async () => ({ data: [], error: null }) };
  assert.deepEqual(await linkChains(none, ['x'], async () => { throw new Error('no fetch'); }),
    { candidates: 0, fetched: 0, chains: [] });
  assert.deepEqual(await linkChains(none, [], async () => { throw new Error('no fetch'); }),
    { candidates: 0, fetched: 0, chains: [] });

  const many = {
    rpc: async (fn: string) => fn === 'chain_candidates'
      ? { data: Array.from({ length: 10 }, (_, i) => ({ restaurant_id: `r${i}`, google_place_id: `g${i}`, checked: false })), error: null }
      : { data: [], error: null },
  };
  let n = 0;
  const out = await linkChains(many, null, async () => (n++, { ok: true, host: null }), { maxFetches: 4 });
  assert.equal(n, 4);
  assert.equal(out.fetched, 4);
});
