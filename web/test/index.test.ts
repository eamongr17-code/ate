// Run: npm test (node --test, type-stripped). The logo import is stubbed by test/loader.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { aasa, headlineDish, parseCard, renderEntry, text, thumbnailURL } from '../src/render.ts';

const env = {
  SUPABASE_URL: 'https://x.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'k',
  APP_LINK: 'https://testflight.apple.com/join/VsFj6pKV', APP_ID: '9M6K835247.com.eamongracias.ate',
};
const card = {
  id: '6f1c2d3e-0000-4000-8000-000000000001', created_at: '2026-10-31T09:00:00Z',
  body: 'Cacio <script>alert(1)</script> was great',
  author: { username: 'eamon' }, place: { name: 'Small Wins', locality: 'Fitzroy' },
  photos: [{ url: 'https://x.supabase.co/a.jpg', position: 1 }, { url: 'javascript:alert(1)', position: 2 }],
  items: [
    { dish_name: 'Burnt Butter Mash', score: 4, position: 2 },
    { dish_name: 'Cacio e Pepe', score: 4.5, position: 1 },
    { dish_name: 'Negroni', score: null, position: 3 },
  ],
};

test('escapes the words and drops non-https photos', () => {
  const html = renderEntry(card, 'https://chewsfood.app', env);
  assert.ok(!html.includes('<script>alert'));
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(!html.includes('javascript:'));
  assert.ok(html.includes('og:image" content="https://x.supabase.co/a.jpg"'));
});

test('dish-first: title is the top dish and score, @handle at Place under it; dishes in order; best filled', () => {
  const html = renderEntry(card, 'https://chewsfood.app', env);
  assert.ok(html.includes('<title>Cacio e Pepe ★ 4.5</title>'));
  assert.ok(html.includes('og:description" content="@eamon at Small Wins"'));
  assert.ok(html.indexOf('Cacio e Pepe</h1>') < html.indexOf('at <b>Small Wins</b>'));
  assert.ok(html.indexOf('at <b>Small Wins</b>') < html.indexOf('Burnt Butter Mash'));
  assert.match(html, /class="sc best">.*4\.5/);
  assert.match(html, /Negroni<\/h1><span class="sc"><\/span>/);
  assert.ok(html.includes('data-app="ate://entry/6f1c2d3e-0000-4000-8000-000000000001"'));
});

test('no dishes: the title falls back to @handle at Place', () => {
  const html = renderEntry({ ...card, items: [] }, 'https://chewsfood.app', env);
  assert.ok(html.includes('<title>@eamon at Small Wins</title>'));
});

test('headline dish: top score, first of a tie, else the first dish', () => {
  assert.deepEqual(headlineDish(card), { name: 'Cacio e Pepe', score: 4.5 });
  const tie = { ...card, items: [{ dish_name: 'B', score: 4, position: 2 }, { dish_name: 'A', score: 4, position: 1 }] };
  assert.equal(headlineDish(tie)?.name, 'A');
  const none = { ...card, items: [{ dish_name: 'Z', score: null, position: 2 }, { dish_name: 'Y', score: null, position: 1 }] };
  assert.deepEqual(headlineDish(none), { name: 'Y', score: null });
});

test('parseCard: null, empty, array of one', () => {
  assert.equal(parseCard(null), null);
  assert.equal(parseCard([]), null);
  assert.equal(parseCard({}), null);
  assert.equal(parseCard([card])?.id, card.id);
});

test('AASA names the app and both paths', () => {
  const a = aasa(env.APP_ID);
  assert.deepEqual(a.applinks.details[0].appIDs, [env.APP_ID]);
  assert.deepEqual(a.applinks.details[0].components.map((c) => c['/']), ['/entry/*', '/list/*']);
});

test('text() escapes quotes for attributes', () => {
  assert.equal(text(`a"b'<`), 'a&quot;b&#39;&lt;');
});

test('fonts come from our own domain, never a font host', () => {
  const html = renderEntry(card, 'https://chewsfood.app', env);
  assert.ok(!/googleapis|gstatic/.test(html));
  assert.ok(html.includes('/fonts/youngserif.woff2'));
});

test('thumbnail URL: name_t.jpg; nothing for an unknown extension', () => {
  assert.equal(thumbnailURL('https://x.co/u/e-0.jpg'), 'https://x.co/u/e-0_t.jpg');
  assert.equal(thumbnailURL('https://x.co/u/e-0.JPEG?v=2'), 'https://x.co/u/e-0_t.jpg');
  assert.equal(thumbnailURL('https://x.co/u/e-0'), null);
});

import { ogHTML, ogParts } from '../src/og.ts';

test('preview image: the top dish and its score, @handle at Place, the other dishes counted', () => {
  const parts = ogParts({ ...card, items: [...card.items, { dish_name: 'Tiramisu', score: 3, position: 4 }] });
  assert.deepEqual(parts, { dish: 'Cacio e Pepe', score: '4.5', byline: '@eamon at Small Wins', more: 3 });
});

test('preview image escapes names; the photo fills the card, or the words go in ink without one', () => {
  const logos = { ink: 'data:ink', paper: 'data:paper' };
  const bare = ogHTML({ dish: '<b>x</b>', score: null, byline: '', more: 0 }, null, logos);
  assert.ok(bare.includes('&lt;b&gt;x&lt;/b&gt;'));
  assert.ok(!bare.includes('<img src="http'));
  assert.ok(bare.includes('data:ink'));
  const full = ogHTML({ dish: 'Pad Thai', score: '5.0', byline: '@w at O', more: 2 }, 'https://p.co/a.jpg', logos);
  assert.ok(full.includes('width:1200px;height:630px;object-fit:cover'));
  assert.ok(full.includes('data:paper'));
  assert.ok(full.includes('5.0</div>'));
  assert.ok(!full.includes('★'), 'the fonts have no ★ glyph, so the star must be drawn');
  assert.ok(full.includes('@w at O · +2 more'));
});
