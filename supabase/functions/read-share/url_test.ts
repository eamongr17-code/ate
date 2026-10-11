// supabase/functions/read-share/url_test.ts
//
//   deno test --no-check supabase/functions/read-share/
//   node --test supabase/functions/read-share/*_test.ts

import { test, assert, assertEquals } from '../sort-entry/harness.ts';
import { canonicalTikTokVideo, classifyUrl, textWithoutUrls } from './url.ts';

test('a TikTok video URL collapses to its canonical address', () => {
  const c = classifyUrl('https://www.tiktok.com/@melbfoodie/video/7301234567890123456?is_from_webapp=1&sender_device=pc&_r=1#x');
  assertEquals(c, {
    source: 'tiktok',
    url: 'https://www.tiktok.com/@melbfoodie/video/7301234567890123456',
    short: false,
    author: null,
  });
  assertEquals(classifyUrl('https://m.tiktok.com/@a.b_c/photo/7301234567890123456/')?.url,
    'https://www.tiktok.com/@a.b_c/photo/7301234567890123456');
});

test('TikTok short links are flagged for resolution and lose their query', () => {
  for (const raw of ['https://vm.tiktok.com/ZMabc123/', 'https://vt.tiktok.com/ZSxyz/?_t=1', 'https://www.tiktok.com/t/ZT8abcDEF/']) {
    const c = classifyUrl(raw)!;
    assertEquals(c.source, 'tiktok');
    assert(c.short, raw);
    assert(!c.url.includes('?'), c.url);
  }
  assert(!classifyUrl('https://www.tiktok.com/@x/video/1234567890')!.short);
  assert(!classifyUrl('https://vm.tiktok.com/')!.short, 'the bare host is not a short link');
});

test('a resolved short link is kept only when it lands on a video or photo page', () => {
  assertEquals(canonicalTikTokVideo('https://www.tiktok.com/@chef/video/7301234567890123456?_t=8&_r=1'),
    'https://www.tiktok.com/@chef/video/7301234567890123456');
  assertEquals(canonicalTikTokVideo('https://www.tiktok.com/login?redirect=x'), null);
  assertEquals(canonicalTikTokVideo('https://example.com/@chef/video/7301234567890123456'), null);
});

test('Instagram posts and reels canonicalise; an account in the path is the author', () => {
  assertEquals(classifyUrl('https://www.instagram.com/reel/C9xYz_12AB/?igsh=MTV4&utm_source=ig_web_copy_link'), {
    source: 'instagram', url: 'https://www.instagram.com/reel/C9xYz_12AB/', short: false, author: null,
  });
  assertEquals(classifyUrl('https://instagram.com/p/C9xYz_12AB')?.url, 'https://www.instagram.com/p/C9xYz_12AB/');
  assertEquals(classifyUrl('https://www.instagram.com/reels/C9xYz_12AB/')?.url, 'https://www.instagram.com/reel/C9xYz_12AB/');
  assertEquals(classifyUrl('https://www.instagram.com/chinchinmelb/reel/C9xYz_12AB/')?.author, 'chinchinmelb');
  assertEquals(classifyUrl('https://instagr.am/p/AbCdEf/')?.source, 'instagram');
});

test('anything else is a link, with tracking stripped and real parameters kept', () => {
  assertEquals(classifyUrl('https://Example.COM/menu?id=4&utm_medium=social&fbclid=abc#top'), {
    source: 'link', url: 'https://example.com/menu?id=4', short: false, author: null,
  });
  assertEquals(classifyUrl('https://notinstagram.com/p/abc/')?.source, 'link');
  assertEquals(classifyUrl('https://evil-tiktok.com/@a/video/1234567890')?.source, 'link');
});

test('422s: not https, unparseable, credentials, odd ports, too long, not a string', () => {
  for (const bad of [
    'http://www.tiktok.com/@a/video/1234567890', 'ftp://x.com/a', 'tiktok.com/@a/video/1', 'not a url', '',
    'https://user:pw@example.com/', 'https://example.com:8443/', 'https://localhost/', `https://e.com/${'a'.repeat(2050)}`,
    42, null, undefined, { url: 'https://e.com' },
  ]) {
    assertEquals(classifyUrl(bad), null, String(bad).slice(0, 60));
  }
  assertEquals(classifyUrl('  https://example.com/a  ')?.url, 'https://example.com/a');
});

test('the shared text loses its links; nothing left is null', () => {
  assertEquals(textWithoutUrls('Best gin & tonic at Bar Americano 🍸 https://vm.tiktok.com/ZMabc/'), 'Best gin & tonic at Bar Americano 🍸');
  assertEquals(textWithoutUrls('https://www.instagram.com/reel/abc/?igsh=x'), null);
  assertEquals(textWithoutUrls('  '), null);
  assertEquals(textWithoutUrls(undefined), null);
  assertEquals(textWithoutUrls('line one\n\n   line two'), 'line one\nline two');
  assertEquals(textWithoutUrls('x'.repeat(3000))!.length, 2200);
});
