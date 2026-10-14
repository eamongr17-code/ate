// supabase/functions/match-photos/match_test.ts
//
// The model only proposes: these pin what is offered (never a picked line or its photo), the
// gate on the answer (real indices, one photo per line), and inertness without a key.

import { test, assert, assertEquals } from '../sort-entry/harness.ts';
import {
  askModel, buildRequest, loadImages, matchesFromResponse, MAX_PHOTOS, plan, thumbnailUrl, type Line, type Photo,
} from './match.ts';

const photo = (position: number): Photo => ({ position, url: `https://x.test/p/${position}.jpg` });
const line = (id: string, dish: string, extra: Partial<Line> = {}): Line =>
  ({ review_id: id, dish, note: null, picked: false, photo_url: null, ...extra });
const reply = (pairs: unknown) => ({ content: [{ type: 'tool_use', name: 'match_photos', input: { pairs } }] });

test('plan: no photos or no open lines → nothing', () => {
  assertEquals(plan([], [line('a', 'Gnocchi')]).kind, 'nothing');
  assertEquals(plan([photo(0)], []).kind, 'nothing');
  assertEquals(plan([photo(0)], [line('a', 'Gnocchi', { picked: true })]).kind, 'nothing');
});

test('plan: a one-dish entry takes its first photo without asking', () => {
  const p = plan([photo(1), photo(0)], [line('a', 'Gnocchi')]);
  assertEquals(p, { kind: 'direct', matches: [{ review_id: 'a', photo_url: photo(0).url }] });
});

test('plan: picked lines and the photos they hold are never offered', () => {
  const lines = [
    line('a', 'Tagliatelle', { picked: true, photo_url: photo(0).url }),
    line('b', 'Tiramisu'),
    line('c', 'Spritz'),
  ];
  const p = plan([photo(0), photo(1), photo(2)], lines);
  assert(p.kind === 'ask');
  if (p.kind !== 'ask') return;
  assertEquals(p.photos.map((x) => x.position), [1, 2]);
  assertEquals(p.lines.map((x) => x.review_id), ['b', 'c']);
});

test('plan: a two-dish entry with one line picked still asks about the other', () => {
  const p = plan([photo(0), photo(1)], [line('a', 'Gnocchi', { picked: true }), line('b', 'Cannoli')]);
  assertEquals(p.kind, 'ask');
});

test('plan: at most MAX_PHOTOS photos are sent', () => {
  const photos = Array.from({ length: MAX_PHOTOS + 3 }, (_, i) => photo(i));
  const p = plan(photos, [line('a', 'A'), line('b', 'B')]);
  assert(p.kind === 'ask' && p.photos.length === MAX_PHOTOS);
});

test('buildRequest: labelled URL images, numbered dishes with notes, forced tool', () => {
  const req = buildRequest({
    apiKey: 'k',
    photos: [photo(0), photo(1)],
    lines: [line('a', 'Tagliatelle', { note: 'rich and silky' }), line('b', 'Tiramisu')],
  });
  const body = JSON.parse(req.body);
  assertEquals(req.headers['x-api-key'], 'k');
  assertEquals(body.tool_choice, { type: 'tool', name: 'match_photos' });
  const content = body.messages[0].content;
  assertEquals(content[0], { type: 'text', text: 'Photo 1:' });
  assertEquals(content[1], { type: 'image', source: { type: 'url', url: photo(0).url } });
  assertEquals(content[3].source.url, photo(1).url);
  assert(content[4].text.includes('1. Tagliatelle (the diner said: rich and silky)'));
  assert(content[4].text.includes('2. Tiramisu\n'));
});

test('matchesFromResponse: keeps real pairs, first claim wins on both sides', () => {
  const photos = [photo(0), photo(1), photo(2)];
  const lines = [line('a', 'A'), line('b', 'B')];
  const got = matchesFromResponse(reply([
    { photo: 2, dish: 1 },
    { photo: 3, dish: 1 }, // line 1 already has one
    { photo: 2, dish: 2 }, // photo 2 already taken
    { photo: 9, dish: 2 }, // no photo 9
    { photo: 1, dish: 0 }, // no dish 0
    { photo: 1.5, dish: 2 },
    { photo: 1, dish: 2 },
  ]), photos, lines);
  assertEquals(got, [
    { review_id: 'a', photo_url: photo(1).url },
    { review_id: 'b', photo_url: photo(0).url },
  ]);
});

test('matchesFromResponse: no tool call → null; empty pairs → no matches', () => {
  assertEquals(matchesFromResponse({ content: [{ type: 'text', text: 'hi' }] }, [photo(0)], [line('a', 'A')]), null);
  assertEquals(matchesFromResponse(null, [photo(0)], [line('a', 'A')]), null);
  assertEquals(matchesFromResponse(reply([]), [photo(0)], [line('a', 'A')]), []);
});

test('askModel: no key → null, and nothing is fetched', async () => {
  let called = false;
  const got = await askModel({
    apiKey: '',
    photos: [photo(0)],
    lines: [line('a', 'A'), line('b', 'B')],
    fetchImpl: (() => { called = true; return Promise.reject(new Error('no')); }) as typeof fetch,
  });
  assertEquals(got, null);
  assert(!called);
});

test('askModel: a good answer comes back as matches; a bad status as null', async () => {
  const photos = [photo(0), photo(1)];
  const lines = [line('a', 'A'), line('b', 'B')];
  const ok = (async () => new Response(JSON.stringify(reply([{ photo: 1, dish: 2 }])), { status: 200 })) as typeof fetch;
  assertEquals(await askModel({ apiKey: 'sk-ant-test', photos, lines, fetchImpl: ok }),
    [{ review_id: 'b', photo_url: photo(0).url }]);
  const bad = (async () => new Response('nope', { status: 529 })) as typeof fetch;
  assertEquals(await askModel({ apiKey: 'sk-ant-test', photos, lines, fetchImpl: bad }), null);
});

test('thumbnailUrl: the _t.jpg beside the original, query kept; none for a thumbnail or no file', () => {
  assertEquals(thumbnailUrl('https://x.test/storage/v1/object/public/review-photos/u/e-0.jpg'),
    'https://x.test/storage/v1/object/public/review-photos/u/e-0_t.jpg');
  assertEquals(thumbnailUrl('https://x.test/p/e-1.jpeg?v=2'), 'https://x.test/p/e-1_t.jpg?v=2');
  assertEquals(thumbnailUrl('https://x.test/p/e-1_t.jpg'), null);
  assertEquals(thumbnailUrl('https://x.test/'), null);
  assertEquals(thumbnailUrl('not a url'), null);
});

test('loadImages: thumbnail first, the original when it is missing, unreadable photos left out', async () => {
  const seen: string[] = [];
  const store: Record<string, string> = {
    'https://x.test/p/0_t.jpg': 'thumb0',
    'https://x.test/p/1.jpg': 'full1',
  };
  const fetchImpl = (async (url: string) => {
    seen.push(url);
    return url in store
      ? new Response(store[url], { status: 200, headers: { 'content-type': 'image/jpeg' } })
      : new Response('missing', { status: 404 });
  }) as unknown as typeof fetch;
  const got = await loadImages([photo(0), photo(1), photo(2)], { fetchImpl });
  assertEquals(got.map((p) => p.position), [0, 1]);
  assertEquals(atob(got[0].data), 'thumb0');
  assertEquals(atob(got[1].data), 'full1');
  assertEquals(got[0].media_type, 'image/jpeg');
  assert(!seen.includes('https://x.test/p/0.jpg'));
});

test('askModel: photos go as base64, and answers number the photos that were read', async () => {
  const lines = [line('a', 'A'), line('b', 'B')];
  let body: { messages: Array<{ content: Array<Record<string, unknown>> }> } | null = null;
  const fetchImpl = (async (url: string, init?: RequestInit) => {
    if (url.startsWith('https://api.anthropic.com')) {
      body = JSON.parse(String(init?.body));
      return new Response(JSON.stringify(reply([{ photo: 1, dish: 2 }])), { status: 200 });
    }
    // Photo 0 cannot be read at all; photo 1 can.
    if (url.includes('/0')) return new Response('gone', { status: 404 });
    return new Response('img', { status: 200, headers: { 'content-type': 'image/png' } });
  }) as unknown as typeof fetch;
  const got = await askModel({ apiKey: 'sk-ant-test', photos: [photo(0), photo(1)], lines, fetchImpl });
  assertEquals(got, [{ review_id: 'b', photo_url: photo(1).url }]);
  const image = body!.messages[0].content[1] as { source: Record<string, string> };
  assertEquals(image.source.type, 'base64');
  assertEquals(image.source.media_type, 'image/png');
});

test('askModel: no photo readable → null, and the model is not asked', async () => {
  let asked = false;
  const fetchImpl = (async (url: string) => {
    if (url.startsWith('https://api.anthropic.com')) asked = true;
    return new Response('gone', { status: 404 });
  }) as unknown as typeof fetch;
  assertEquals(await askModel({ apiKey: 'sk-ant-test', photos: [photo(0)], lines: [line('a', 'A'), line('b', 'B')], fetchImpl }), null);
  assert(!asked);
});
