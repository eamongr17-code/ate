// supabase/functions/read-share/model_test.ts
//
// The model can only PROPOSE: these pin the grounding gate (nothing the words do not name survives),
// the inertness without a key, and the request/reply shapes.

import { test, assert, assertEquals } from '../sort-entry/harness.ts';
import {
  buildRequest,
  groundedIn,
  modelInput,
  NO_SUGGESTION,
  rawSuggestion,
  resolveShareModel,
  suggestFromCaption,
  validateSuggestion,
} from './model.ts';

const reply = (input: Record<string, unknown>) => ({
  content: [{ type: 'tool_use', name: 'suggest_save', input }],
  usage: { input_tokens: 100, output_tokens: 20 },
});

test('grounding: singular/plural, capitals, accents and & are forgiven', () => {
  assert(groundedIn('Gin & tonic', 'six gin and tonics later…'));
  assert(groundedIn('Dumpling', 'the DUMPLINGS at Shandong Mama'));
  assert(groundedIn('Pie', 'meat pies forever'));
  assert(groundedIn('Crème brûlée', 'creme brulee 10/10'));
  assert(groundedIn('Big Mac', 'a big mac at 3am'));
  assert(groundedIn('Chin Chin', 'dinner at #chinchin tonight'), 'hashtag run-together');
  assert(groundedIn('Gin & tonic', 'pov: #ginandtonic season'));
});

test('grounding: words that are not there are not there', () => {
  assert(!groundedIn('Pad thai', 'best thai food in Melbourne'), 'a cuisine is not a dish');
  assert(!groundedIn('Spicy margarita', 'a margarita at Bar Bambi'), 'no added adjectives');
  assert(!groundedIn('The', 'the'), 'stopwords alone never ground');
  assert(!groundedIn('Tipo 00', 'tipo pasta'));
});

test('validateSuggestion keeps only what the words support', () => {
  const words = '3 gin and tonics at Bar Americano, absolute vibes 🍸';
  assertEquals(validateSuggestion({ dish: 'Gin & tonic', place_query: 'Bar Americano' }, words),
    { dish: 'Gin & Tonic', place_query: 'Bar Americano' });
  assertEquals(validateSuggestion({ dish: 'Negroni', place_query: 'Bar Americano' }, words),
    { dish: null, place_query: 'Bar Americano' }, 'an invented dish is dropped');
  assertEquals(validateSuggestion({ dish: 'Gin & tonic', place_query: 'Melbourne' }, words),
    { dish: 'Gin & Tonic', place_query: null }, 'an invented place is dropped');
  assertEquals(validateSuggestion({ dish: 7, place_query: ['x'] }, words), NO_SUGGESTION);
  assertEquals(validateSuggestion({ dish: 'x'.repeat(121), place_query: '' }, 'x'.repeat(121)), NO_SUGGESTION);
  assertEquals(validateSuggestion({ dish: 'Croissant', place_query: '@lunecroissanterie' }, 'croissant @lunecroissanterie'),
    { dish: 'Croissant', place_query: 'lunecroissanterie' }, 'a leading # or @ is trimmed');
  assertEquals(validateSuggestion(null, words), NO_SUGGESTION);
});


test('validateSuggestion prints the dish in title case whatever the model sent (13 Oct beta)', () => {
  const words = 'the best gin and tonic at bar americano';
  assertEquals(validateSuggestion({ dish: 'gin and tonic', place_query: null }, words).dish, 'Gin and Tonic');
  assertEquals(validateSuggestion({ dish: 'GIN AND TONIC', place_query: null }, words).dish, 'Gin and Tonic');
});
test('rawSuggestion reads the forced tool call and nothing else', () => {
  assertEquals(rawSuggestion(reply({ dish: 'Croissant' })), { dish: 'Croissant', place_query: undefined });
  assertEquals(rawSuggestion({ content: [{ type: 'text', text: '{"dish":"x"}' }] }), null);
  assertEquals(rawSuggestion({ content: [{ type: 'tool_use', name: 'other', input: { dish: 'x' } }] }), null);
  assertEquals(rawSuggestion(null), null);
});

test('modelInput merges caption and shared text without repeating either', () => {
  assertEquals(modelInput('Cacio e pepe at Tipo 00', 'Cacio e pepe at Tipo 00'), 'Cacio e pepe at Tipo 00');
  assertEquals(modelInput('Cacio e pepe', 'Cacio e pepe at Tipo 00'), 'Cacio e pepe at Tipo 00');
  assertEquals(modelInput('Title', 'other words'), 'Title\n\nother words');
  assertEquals(modelInput(null, '  '), '');
  assertEquals(modelInput('a'.repeat(5000), null).length, 4000);
});

test('the request is a forced tool call on the sorter defaults', () => {
  const req = buildRequest({ apiKey: 'k', input: 'Croissant at Lune' });
  const body = JSON.parse(req.body);
  assertEquals(req.url, 'https://api.anthropic.com/v1/messages');
  assertEquals(req.headers['x-api-key'], 'k');
  assertEquals(body.model, 'claude-haiku-5-5');
  assertEquals(body.tool_choice, { type: 'tool', name: 'suggest_save' });
  assert(!('temperature' in body), 'Haiku 5.5 rejects sampling params');
  assert(body.messages[0].content.includes('Croissant at Lune'));
  assertEquals(JSON.parse(buildRequest({ apiKey: 'k', input: 'x', model: 'claude-haiku-4-5' }).body).temperature, 0);
  assertEquals(resolveShareModel(''), 'claude-haiku-5-5');
  assertEquals(resolveShareModel('claude-sonnet-5'), 'claude-sonnet-5');
  assertEquals(resolveShareModel('gpt-9'), 'claude-haiku-5-5');
});

test('INERT without a key: no network call at all', async () => {
  let calls = 0;
  const spy = (() => { calls++; return Promise.reject(new Error('no')); }) as unknown as typeof fetch;
  assertEquals(await suggestFromCaption({ apiKey: '', input: 'Croissant at Lune', fetchImpl: spy }), NO_SUGGESTION);
  assertEquals(await suggestFromCaption({ apiKey: undefined, input: 'Croissant at Lune', fetchImpl: spy }), NO_SUGGESTION);
  assertEquals(await suggestFromCaption({ apiKey: 'k', input: '   ', fetchImpl: spy }), NO_SUGGESTION, 'no words, no call');
  assertEquals(calls, 0);
});

test('a live reply goes through the gate; failures are empty, never thrown', async () => {
  const ok = (() => Promise.resolve(new Response(JSON.stringify(reply({ dish: 'Croissant', place_query: 'Paris' }))))) as unknown as typeof fetch;
  assertEquals(await suggestFromCaption({ apiKey: 'k', input: 'the croissant at Lune', fetchImpl: ok }),
    { dish: 'Croissant', place_query: null });
  const err = (() => Promise.resolve(new Response('{"error":{"message":"overloaded"}}', { status: 529 }))) as unknown as typeof fetch;
  assertEquals(await suggestFromCaption({ apiKey: 'k', input: 'the croissant', fetchImpl: err }), NO_SUGGESTION);
  const hang = ((_u: string, init: RequestInit) => new Promise((_, rej) => init.signal!.addEventListener('abort', () => rej(new Error('aborted'))))) as unknown as typeof fetch;
  assertEquals(await suggestFromCaption({ apiKey: 'k', input: 'the croissant', fetchImpl: hang, timeoutMs: 20 }), NO_SUGGESTION);
});
