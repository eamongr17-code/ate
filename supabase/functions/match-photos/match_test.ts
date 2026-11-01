// supabase/functions/match-photos/match_test.ts
//
// The model only proposes: these pin what is offered (never a picked line or its photo), the
// gate on the answer (real indices, one pairing per photo and dish, boxes), and inertness without a key.

import { test, assert, assertEquals } from '../sort-entry/harness.ts';
import {
  askModel, boxFrom, buildRequest, loadImages, matchesFromResponse, MAX_DISHES_PER_PHOTO, MAX_IMAGE_BYTES, MAX_PHOTOS, ownPhotoReadUrl, plan, thumbnailUrl,
  type Line, type Photo,
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

test('plan: a one-dish entry is asked too (a photo of the table names no dish), every photo its fallback', () => {
  const p = plan([photo(1), photo(0)], [line('a', 'Gnocchi')]);
  assertEquals(p, { kind: 'ask', photos: [photo(0), photo(1)], lines: [line('a', 'Gnocchi')], fallback: [
    { review_id: 'a', photo_url: photo(0).url },
    { review_id: 'a', photo_url: photo(1).url },
  ] });
});

test('plan: several dishes have no fallback: unanswered, nothing is written', () => {
  const p = plan([photo(0)], [line('a', 'Gnocchi'), line('b', 'Cannoli')]);
  assert(p.kind === 'ask' && p.fallback === null);
});

test('matchesFromResponse: a one-dish entry\'s photo of people is left out', () => {
  const photos = [photo(0), photo(1)];
  const lines = [line('a', 'Gnocchi')];
  assertEquals(matchesFromResponse(reply([{ photo: 2, dish: 1, box: [100, 100, 900, 900] }]), photos, lines), [
    { review_id: 'a', photo_url: photo(1).url, box: [0.1, 0.1, 0.9, 0.9] },
  ]);
  assertEquals(matchesFromResponse(reply([]), photos, lines), []);
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

test('matchesFromResponse: keeps real pairs, one per photo and dish, a dish takes several, a photo several', () => {
  const photos = [photo(0), photo(1), photo(2)];
  const lines = [line('a', 'A'), line('b', 'B')];
  const got = matchesFromResponse(reply([
    { photo: 2, dish: 1 },
    { photo: 3, dish: 1 }, // a second photo of dish 1
    { photo: 2, dish: 2 }, // photo 2 shows dish 2 too (a shared plate)
    { photo: 2, dish: 1 }, // the same pair again
    { photo: 9, dish: 2 }, // no photo 9
    { photo: 1, dish: 0 }, // no dish 0
    { photo: 1.5, dish: 2 },
    { photo: 1, dish: 2 },
  ]), photos, lines);
  assertEquals(got, [
    { review_id: 'a', photo_url: photo(1).url },
    { review_id: 'a', photo_url: photo(2).url },
    { review_id: 'b', photo_url: photo(1).url },
    { review_id: 'b', photo_url: photo(0).url },
  ]);
});

test('matchesFromResponse: a box comes back as 0–1 fractions; a broken box is dropped, the pair kept', () => {
  const photos = [photo(0)];
  const lines = [line('a', 'Club Sandwich'), line('b', 'Fries'), line('c', 'Long Black'), line('d', 'Aioli')];
  const got = matchesFromResponse(reply([
    { photo: 1, dish: 1, box: [400, 550, 1000, 1000] },
    { photo: 1, dish: 2, box: [-20, 580, 480, 1200] }, // clamped into the image
    { photo: 1, dish: 3, box: [0, 0, 210] }, // three numbers
    { photo: 1, dish: 4, box: [500, 500, 510, 900] }, // a sliver
  ]), photos, lines);
  assertEquals(got, [
    { review_id: 'a', photo_url: photo(0).url, box: [0.4, 0.55, 1, 1] },
    { review_id: 'b', photo_url: photo(0).url, box: [0, 0.58, 0.48, 1] },
    { review_id: 'c', photo_url: photo(0).url },
    { review_id: 'd', photo_url: photo(0).url },
  ]);
});

test('boxFrom: right-to-left or upside-down is no box', () => {
  assertEquals(boxFrom([600, 100, 200, 400]), undefined);
  assertEquals(boxFrom([100, 600, 400, 200]), undefined);
  assertEquals(boxFrom('0,0,1,1'), undefined);
  assertEquals(boxFrom([0, 0, 1000, 1000]), [0, 0, 1, 1]);
});

test('matchesFromResponse: at most MAX_DISHES_PER_PHOTO dishes on one photo', () => {
  const lines = Array.from({ length: MAX_DISHES_PER_PHOTO + 2 }, (_, i) => line(`l${i}`, `Dish ${i}`));
  const got = matchesFromResponse(reply(lines.map((_, i) => ({ photo: 1, dish: i + 1 }))), [photo(0)], lines);
  assertEquals(got?.length, MAX_DISHES_PER_PHOTO);
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

test('ownPhotoReadUrl: only the author\'s own bucket folder, always read from our own storage', () => {
  const me = '00000000-0000-4000-8000-00000000000A';
  const base = 'https://ref.supabase.co/';
  const own = 'https://ref.supabase.co/storage/v1/object/public/review-photos/00000000-0000-4000-8000-00000000000a/e/entry-0.jpg';
  assertEquals(ownPhotoReadUrl(own, me, base), own);
  // Another host naming our path is read from OUR storage, never theirs.
  assertEquals(
    ownPhotoReadUrl('http://169.254.169.254/storage/v1/object/public/review-photos/00000000-0000-4000-8000-00000000000a/x.jpg', me, base),
    'https://ref.supabase.co/storage/v1/object/public/review-photos/00000000-0000-4000-8000-00000000000a/x.jpg',
  );
  assertEquals(ownPhotoReadUrl('https://evil.test/cat.jpg', me, base), null);
  assertEquals(ownPhotoReadUrl('https://ref.supabase.co/storage/v1/object/public/review-photos/someone-else/x.jpg', me, base), null);
  assertEquals(ownPhotoReadUrl('https://ref.supabase.co/storage/v1/object/public/review-photos/00000000-0000-4000-8000-00000000000a/%2e%2e/x.jpg', me, base), null);
  assertEquals(ownPhotoReadUrl('https://ref.supabase.co/storage/v1/object/public/avatars/00000000-0000-4000-8000-00000000000a/x.jpg', me, base), null);
  assertEquals(ownPhotoReadUrl('not a url', me, base), null);
});

test('ownPhotoReadUrl: an R2 photo is read from the photos Worker, the author\'s folder only', () => {
  const me = '00000000-0000-4000-8000-00000000000a';
  const base = 'https://ref.supabase.co/';
  const photos = 'https://photos.x.app/';
  const own = `https://photos.x.app/review-photos/${me}/e-0.jpg`;
  assertEquals(ownPhotoReadUrl(own, me, base, photos), own);
  assertEquals(ownPhotoReadUrl(`${own}?v=2`, me, base, photos), own);
  assertEquals(ownPhotoReadUrl(own, me, base, null), null, 'R2 is not ours until it is switched on');
  assertEquals(ownPhotoReadUrl(`https://photos.x.app/review-photos/someone-else/e.jpg`, me, base, photos), null);
  assertEquals(ownPhotoReadUrl(`https://photos.x.app/avatars/${me}/a.jpg`, me, base, photos), null);
  assertEquals(ownPhotoReadUrl(`https://photos.x.app/review-photos/${me}/%2e%2e/x.jpg`, me, base, photos), null);
  assertEquals(ownPhotoReadUrl(`http://photos.x.app/review-photos/${me}/e.jpg`, me, base, photos), null, 'https only');
  // the old Supabase URLs keep working beside it
  assertEquals(
    ownPhotoReadUrl(`https://ref.supabase.co/storage/v1/object/public/review-photos/${me}/e.jpg`, me, base, photos),
    `https://ref.supabase.co/storage/v1/object/public/review-photos/${me}/e.jpg`,
  );
});

test('loadImages: reads from `read` when set, keeps `url`, and skips an oversized photo', async () => {
  const seen: string[] = [];
  const fetchImpl = (async (url: string) => {
    seen.push(url);
    if (url.includes('big')) {
      return new Response('x', { status: 200, headers: { 'content-length': String(MAX_IMAGE_BYTES + 1) } });
    }
    return url.endsWith('_t.jpg')
      ? new Response('thumb', { status: 200, headers: { 'content-type': 'image/jpeg' } })
      : new Response('missing', { status: 404 });
  }) as unknown as typeof fetch;
  const got = await loadImages([
    { position: 0, url: 'https://stored.test/p/0.jpg', read: 'https://ours.test/p/0.jpg' },
    { position: 1, url: 'https://stored.test/p/big.jpg', read: 'https://ours.test/p/big.jpg' },
  ], { fetchImpl });
  assertEquals(got.map((p) => [p.position, p.url]), [[0, 'https://stored.test/p/0.jpg']]);
  assert(seen.every((u) => u.startsWith('https://ours.test/')));
});
