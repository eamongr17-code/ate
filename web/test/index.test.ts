// Run: npm test (node --test, type-stripped). The logo import is stubbed by test/loader.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { aasa, parseCard, renderEntry, text, thumbnailURL } from '../src/render.ts';

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

test('title is @handle at Place; dishes in order; best score filled; unscored empty', () => {
  const html = renderEntry(card, 'https://chewsfood.app', env);
  assert.ok(html.includes('<title>@eamon at Small Wins</title>'));
  assert.ok(html.indexOf('Cacio e Pepe') < html.indexOf('Burnt Butter Mash'));
  assert.match(html, /class="sc best">.*4\.5/);
  assert.match(html, /Negroni<\/span><span class="sc"><\/span>/);
  assert.ok(html.includes('data-app="ate://entry/6f1c2d3e-0000-4000-8000-000000000001"'));
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
