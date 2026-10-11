// supabase/functions/read-share/oembed_test.ts

import { test, assertEquals } from '../sort-entry/harness.ts';
import { EMPTY_META, parseTikTokOEmbed, tiktokOEmbedUrl } from './oembed.ts';

test('the oEmbed request URL encodes the post URL', () => {
  assertEquals(tiktokOEmbedUrl('https://www.tiktok.com/@a/video/123'),
    'https://www.tiktok.com/oembed?url=https%3A%2F%2Fwww.tiktok.com%2F%40a%2Fvideo%2F123');
});

test('a real-shaped TikTok oEmbed reply becomes author, caption, thumbnail', () => {
  const reply = JSON.stringify({
    version: '1.0', type: 'video', title: 'The  cacio e pepe at Tipo 00 🤤\n#melbournefood',
    author_url: 'https://www.tiktok.com/@melbeats', author_name: 'Melb Eats', author_unique_id: 'melbeats',
    thumbnail_url: 'https://p16-sign-va.tiktokcdn.com/obj/abc.jpeg?x-expires=1', thumbnail_width: 576,
    provider_name: 'TikTok', html: '<blockquote>…</blockquote>',
  });
  assertEquals(parseTikTokOEmbed(reply), {
    author: 'Melb Eats',
    caption: 'The cacio e pepe at Tipo 00 🤤 #melbournefood',
    thumbnail_url: 'https://p16-sign-va.tiktokcdn.com/obj/abc.jpeg?x-expires=1',
  });
});

test('missing display name falls back to the @handle; an http thumbnail is dropped', () => {
  assertEquals(parseTikTokOEmbed({ title: '', author_unique_id: 'x', thumbnail_url: 'http://insecure/a.jpg' }), {
    author: '@x', caption: null, thumbnail_url: null,
  });
});

test('error replies and garbage are EMPTY, never a throw', () => {
  assertEquals(parseTikTokOEmbed('{"code":400,"message":"Something went wrong"}'), EMPTY_META);
  assertEquals(parseTikTokOEmbed('<html>'), EMPTY_META);
  assertEquals(parseTikTokOEmbed(null), EMPTY_META);
  assertEquals(parseTikTokOEmbed([1, 2]), EMPTY_META);
});

test('caps: author 100, caption 2200 (own_saves 0061)', () => {
  const m = parseTikTokOEmbed({ author_name: 'a'.repeat(300), title: 'b'.repeat(5000) });
  assertEquals([m.author!.length, m.caption!.length], [100, 2200]);
});
