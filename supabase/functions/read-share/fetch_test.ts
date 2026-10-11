// supabase/functions/read-share/fetch_test.ts
//
// The SSRF guard, the caps and the Open Graph read — all against a fake fetch, no network.

import { test, assert, assertEquals } from '../sort-entry/harness.ts';
import { decodeEntities, hostIsSafe, isBlockedHost, isPrivateAddress, parseOpenGraph, safeFetch } from './fetch.ts';

test('private, loopback, link-local, CGNAT, metadata and mapped addresses are private', () => {
  for (const ip of [
    '127.0.0.1', '10.1.2.3', '172.16.0.1', '172.31.255.255', '192.168.1.1', '169.254.169.254', '100.64.0.1',
    '0.0.0.0', '224.0.0.1', '255.255.255.255', '::1', '::', '[::1]', 'fe80::1', 'fd00::1', 'fc00::abcd',
    '::ffff:127.0.0.1', '::ffff:10.0.0.1', '::ffff:7f00:1', '::ffff:a9fe:a9fe', '64:ff9b::a00:1', 'ff02::1',
  ]) assert(isPrivateAddress(ip), ip);
  for (const ip of ['1.1.1.1', '142.250.70.206', '172.32.0.1', '100.128.0.1', '2606:4700::1111', '2404:6800:4006::200e']) {
    assert(!isPrivateAddress(ip), ip);
  }
});

test('internal hostnames are blocked; public names are not', () => {
  for (const h of ['localhost', 'foo.localhost', 'printer.local', 'db.internal', 'router.lan', 'x.home.arpa', 'intranet', '127.0.0.1', '[::1]', '10.0.0.1', '']) {
    assert(isBlockedHost(h), h);
  }
  for (const h of ['example.com', 'www.tiktok.com', 'broadsheet.com.au', '8.8.8.8']) assert(!isBlockedHost(h), h);
});

test('hostIsSafe: https only, default port, allow-list, and every resolved address public', async () => {
  const pub = () => Promise.resolve(['93.184.216.34']);
  const rebind = () => Promise.resolve(['93.184.216.34', '10.0.0.5']);
  const fail = (): Promise<string[]> => Promise.reject(new Error('nxdomain'));
  assert(await hostIsSafe(new URL('https://example.com/'), { resolver: pub }));
  assert(!(await hostIsSafe(new URL('http://example.com/'), {})));
  assert(!(await hostIsSafe(new URL('https://example.com:8080/'), {})));
  assert(!(await hostIsSafe(new URL('https://example.com/'), { resolver: rebind })), 'any private A record refuses');
  assert(!(await hostIsSafe(new URL('https://example.com/'), { resolver: fail })), 'unresolvable refuses');
  assert(!(await hostIsSafe(new URL('https://example.com/'), { allowHost: (h) => h.endsWith('tiktok.com') })));
});

type Route = { status: number; headers?: Record<string, string>; body?: string };
function fakeFetch(routes: Record<string, Route>, seen: string[] = []) {
  return ((url: string) => {
    seen.push(url);
    const r = routes[url];
    if (!r) return Promise.reject(new Error(`unrouted ${url}`));
    return Promise.resolve(new Response(r.body ?? null, { status: r.status, headers: r.headers }));
  }) as unknown as typeof fetch;
}

test('redirects are followed hop by hop, and a hop to a private address is refused', async () => {
  const seen: string[] = [];
  const f = fakeFetch({
    'https://vm.tiktok.com/ZMabc/': { status: 301, headers: { location: 'https://www.tiktok.com/@a/video/123?_r=1' } },
    'https://www.tiktok.com/@a/video/123?_r=1': { status: 200, body: 'page' },
  }, seen);
  const ok = await safeFetch('https://vm.tiktok.com/ZMabc/', { timeoutMs: 500, maxBytes: 10, bodyless: true, fetchImpl: f });
  assertEquals([ok?.status, ok?.url, ok?.body], [200, 'https://www.tiktok.com/@a/video/123?_r=1', null]);
  assertEquals(seen.length, 2);

  const evil = fakeFetch({ 'https://e.com/a': { status: 302, headers: { location: 'https://169.254.169.254/latest/meta-data/' } } });
  assertEquals(await safeFetch('https://e.com/a', { timeoutMs: 500, maxBytes: 10, fetchImpl: evil }), null);
  const downgrade = fakeFetch({ 'https://e.com/a': { status: 302, headers: { location: 'http://e.com/a' } } });
  assertEquals(await safeFetch('https://e.com/a', { timeoutMs: 500, maxBytes: 10, fetchImpl: downgrade }), null);
  const offList = fakeFetch({ 'https://vm.tiktok.com/x': { status: 302, headers: { location: 'https://evil.com/' } } });
  assertEquals(await safeFetch('https://vm.tiktok.com/x', {
    timeoutMs: 500, maxBytes: 10, fetchImpl: offList, allowHost: (h) => h.endsWith('tiktok.com'),
  }), null);
  const loop = fakeFetch({ 'https://e.com/a': { status: 302, headers: { location: '/a' } } });
  assertEquals(await safeFetch('https://e.com/a', { timeoutMs: 500, maxBytes: 10, maxHops: 3, fetchImpl: loop }), null);
});

test('size caps: truncate keeps the head; strict mode refuses an oversize body', async () => {
  const f = fakeFetch({ 'https://e.com/big': { status: 200, headers: { 'content-type': 'text/html' }, body: 'x'.repeat(5000) } });
  const head = await safeFetch('https://e.com/big', { timeoutMs: 500, maxBytes: 100, truncate: true, fetchImpl: f });
  assertEquals(head?.body?.length, 100);
  const strict = await safeFetch('https://e.com/big', { timeoutMs: 500, maxBytes: 100, fetchImpl: f });
  assertEquals(strict?.body, null);
});

test('a hung server is abandoned at the timeout', async () => {
  const hang = ((_u: string, init: RequestInit) => new Promise((_, rej) => init.signal!.addEventListener('abort', () => rej(new Error('aborted'))))) as unknown as typeof fetch;
  const t0 = Date.now();
  assertEquals(await safeFetch('https://e.com/', { timeoutMs: 30, maxBytes: 10, fetchImpl: hang }), null);
  assert(Date.now() - t0 < 1000);
});

test('Open Graph: og tags in any attribute order, entities decoded, fallbacks, https images only', () => {
  const html = `<html><head><title>Ignored</title>
    <meta content="Tipo 00 &amp; the cacio e pepe" property="og:title">
    <meta property='og:description' content='The best pasta in Melbourne&#39;s CBD'>
    <meta property="og:image" content="https://img.example.com/a.jpg" /></head><body>…</body></html>`;
  assertEquals(parseOpenGraph(html), {
    title: 'Tipo 00 & the cacio e pepe',
    description: "The best pasta in Melbourne's CBD",
    image: 'https://img.example.com/a.jpg',
  });
  assertEquals(parseOpenGraph('<title>Just a title</title><meta name="description" content="desc"><meta property="og:image" content="http://x/a.jpg">'), {
    title: 'Just a title', description: 'desc', image: null,
  });
  assertEquals(parseOpenGraph(''), { title: null, description: null, image: null });
  assertEquals(decodeEntities('&#x1F35D; &quot;q&quot; &bogus;'), '🍝 "q" &bogus;');
});
