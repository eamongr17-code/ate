// supabase/functions/match-photos/match_test.ts
//
// The model only proposes: these pin what is offered (never a picked line or its photo), the
// gate on the answer (real indices, one photo per line), and inertness without a key.

import { test, assert, assertEquals } from '../sort-entry/harness.ts';
import { askModel, buildRequest, matchesFromResponse, MAX_PHOTOS, plan, type Line, type Photo } from './match.ts';

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
