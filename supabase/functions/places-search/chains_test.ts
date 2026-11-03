// supabase/functions/places-search/chains_test.ts
//
//   node --test supabase/functions/places-search/chains_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  addChainLocations, type FoundPlace, googleTextSearchPage, googleWebsite, linkChains, searchBox, websiteHost,
} from './chains.ts';

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

// ---------------------------------------------------------------------------
// 0106: a chain's other locations.
// ---------------------------------------------------------------------------

const place = (id: string, host: string | null, name = 'Guzman y Gomez'): FoundPlace =>
  ({ google_place_id: id, name, address: '', city: '', lat: -37.8, lng: 144.9, cuisine: '', host });

test('googleTextSearchPage: name inside the box, website in the mask, the next page passed on', async () => {
  let seen: { url: string; mask: string; body: Record<string, unknown> } | null = null;
  const fake = (async (url: string, init: RequestInit) => {
    seen = { url, mask: (init.headers as Record<string, string>)['X-Goog-FieldMask'], body: JSON.parse(String(init.body)) };
    return new Response(JSON.stringify({
      places: [
        { id: 'g1', displayName: { text: 'Guzman y Gomez - Fitzroy' }, formattedAddress: '1 Smith St, Fitzroy VIC 3065, Australia',
          location: { latitude: -37.8, longitude: 144.98 }, websiteUri: 'https://www.guzmanygomez.com.au/x', primaryTypeDisplayName: { text: 'Mexican' } },
        { id: 'g2', displayName: { text: 'No point' } },
      ],
      nextPageToken: 'tok2',
    }), { status: 200 });
  }) as unknown as typeof fetch;
  const got = await googleTextSearchPage('k', 'Guzman y Gomez', -37.8, 144.96, 'tok1', fake);
  assert.match(seen!.url, /places:searchText$/);
  assert.match(seen!.mask, /places\.websiteUri/);
  assert.match(seen!.mask, /nextPageToken/);
  assert.equal(seen!.body.textQuery, 'Guzman y Gomez');
  assert.equal(seen!.body.pageToken, 'tok1');
  assert.ok((seen!.body.locationRestriction as { rectangle: unknown }).rectangle);
  assert.equal(got.next, 'tok2');
  assert.deepEqual(got.places, [{
    google_place_id: 'g1', name: 'Guzman y Gomez - Fitzroy', address: '1 Smith St, Fitzroy VIC 3065, Australia',
    city: 'Fitzroy', lat: -37.8, lng: 144.98, cuisine: 'Mexican', host: 'guzmanygomez.com.au',
  }], 'a result with no point is dropped');
  const down = (async () => new Response('{}', { status: 403 })) as unknown as typeof fetch;
  assert.deepEqual(await googleTextSearchPage('k', 'x', 0, 0, null, down), { ok: false, places: [], next: null });
});

test('searchBox: about a city each way, clamped', () => {
  const b = searchBox(-37.8, 144.96);
  assert.ok(Math.abs(b.high.latitude - b.low.latitude - 1) < 1e-9);
  assert.ok(b.high.longitude - b.low.longitude > 1, 'wider in longitude away from the equator');
  const pole = searchBox(89.9, 179.9);
  assert.equal(pole.high.latitude, 90);
  assert.equal(pole.high.longitude, 180);
});

function locationsDb(due: Record<string, unknown>[]) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  return {
    calls,
    rpc: async (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      if (fn === 'chain_locations_due') return { data: due, error: null };
      return { data: 'chain-1', error: null };
    },
  };
}
const due = (over: Record<string, unknown> = {}) => ({
  restaurant_id: 'r1', google_place_id: 'self', name: 'Guzman y Gomez', latitude: -37.8, longitude: 144.98,
  website_host: null, website_checked: false, ...over,
});

test('addChainLocations: own website from its own result; same-host places sent; pages only while they find some', async () => {
  const db = locationsDb([due()]);
  const pages: (string | null)[] = [];
  const search = async (_n: string, _a: number, _b: number, token: string | null) => {
    pages.push(token);
    if (token === null) {
      return { ok: true, places: [place('self', 'gyg.com.au'), place('a', 'gyg.com.au'), place('x', 'other.com')], next: 'p2' };
    }
    if (token === 'p2') return { ok: true, places: [place('b', 'gyg.com.au')], next: 'p3' };
    return { ok: true, places: [place('y', 'other.com')], next: 'p4' };
  };
  const out = await addChainLocations(db, ['r1'], search, async () => { throw new Error('no website call'); });
  assert.deepEqual(pages, [null, 'p2', 'p3'], 'stops at three pages');
  const add = db.calls.find((c) => c.fn === 'chain_add_locations')!;
  assert.equal(add.args.p_restaurant_id, 'r1');
  assert.equal(add.args.p_host, 'gyg.com.au');
  assert.deepEqual((add.args.p_places as FoundPlace[]).map((p) => p.google_place_id), ['a', 'b'], 'not itself, not another website');
  assert.deepEqual(out, { searched: 1, chains: ['chain-1'] });
});

test('addChainLocations: a page with no location ends the search; a known website is not asked again', async () => {
  const db = locationsDb([due({ website_checked: true, website_host: 'gyg.com.au' })]);
  const pages: (string | null)[] = [];
  const search = async (_n: string, _a: number, _b: number, token: string | null) => {
    pages.push(token);
    return { ok: true, places: [place('z', 'other.com')], next: 'more' };
  };
  await addChainLocations(db, ['r1'], search, async () => { throw new Error('no website call'); });
  assert.deepEqual(pages, [null]);
  const add = db.calls.find((c) => c.fn === 'chain_add_locations')!;
  assert.deepEqual(add.args.p_places, []);
  assert.equal(add.args.p_host, 'gyg.com.au', 'still recorded, so the place is never searched again');
});

test('addChainLocations: no own result → one website call; any failed Google call records nothing', async () => {
  const db = locationsDb([due()]);
  const asked: string[] = [];
  await addChainLocations(db, ['r1'], async () => ({ ok: true, places: [place('a', 'gyg.com.au')], next: null }),
    async (id) => (asked.push(id), { ok: true, host: 'gyg.com.au' }));
  assert.deepEqual(asked, ['self']);
  assert.deepEqual((db.calls.at(-1)!.args.p_places as FoundPlace[]).map((p) => p.google_place_id), ['a']);

  const failed = locationsDb([due()]);
  const out = await addChainLocations(failed, ['r1'], async () => ({ ok: false, places: [], next: null }), async () => ({ ok: true, host: null }));
  assert.equal(failed.calls.some((c) => c.fn === 'chain_add_locations'), false);
  assert.deepEqual(out, { searched: 0, chains: [] });

  const noSite = locationsDb([due()]);
  await addChainLocations(noSite, ['r1'], async () => ({ ok: true, places: [], next: null }), async () => ({ ok: false, host: null }));
  assert.equal(noSite.calls.some((c) => c.fn === 'chain_add_locations'), false, 'website call failed: asked again later');
});

test('addChainLocations: no website means nothing found, but the place is recorded; empty ids read nothing', async () => {
  const db = locationsDb([due()]);
  await addChainLocations(db, ['r1'], async () => ({ ok: true, places: [place('self', null), place('a', null)], next: 'n' }),
    async () => { throw new Error('no website call'); });
  const add = db.calls.find((c) => c.fn === 'chain_add_locations')!;
  assert.equal(add.args.p_host, null);
  assert.deepEqual(add.args.p_places, []);

  const none = locationsDb([]);
  assert.deepEqual(await addChainLocations(none, [], async () => { throw new Error('x'); }, async () => { throw new Error('x'); }),
    { searched: 0, chains: [] });
  assert.equal(none.calls.length, 0);
});
