// supabase/functions/apple-token/apple_test.ts — the client secret Apple verifies, and the two form
// posts (code exchange, revoke), against a fake Apple.

import { test, assert, assertEquals } from '../sort-entry/harness.ts';
import { appleConfig, clientSecret, exchangeCode, revokeToken, type AppleConfig } from './apple.ts';

const fromB64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));

async function freshKey(): Promise<{ cfg: AppleConfig; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  const b64 = btoa(String.fromCharCode(...pkcs8));
  // A one-line secret, as it is pasted into the dashboard: literal \n between the PEM lines.
  const pem = `-----BEGIN PRIVATE KEY-----\\n${b64.match(/.{1,64}/g)!.join('\\n')}\\n-----END PRIVATE KEY-----`;
  return { cfg: { teamId: 'TEAM123', keyId: 'KEY456', privateKey: pem, clientId: 'com.eamongracias.ate' }, publicKey: pair.publicKey };
}

test('appleConfig: inert until team, key id and key are all set; the bundle id is the default client', () => {
  assertEquals(appleConfig(() => undefined), null);
  assertEquals(appleConfig((k) => (k === 'APPLE_TEAM_ID' ? 'T' : undefined)), null);
  const env: Record<string, string> = { APPLE_TEAM_ID: 'T', APPLE_SIGNIN_KEY_ID: 'K', APPLE_SIGNIN_PRIVATE_KEY: 'P' };
  assertEquals(appleConfig((k) => env[k])?.clientId, 'com.eamongracias.ate');
});

test('clientSecret: an ES256 JWT for Apple, signed by the key, valid five minutes', async () => {
  const { cfg, publicKey } = await freshKey();
  const jwt = await clientSecret(cfg, 1_000);
  const [h, p, s] = jwt.split('.');
  assertEquals(JSON.parse(new TextDecoder().decode(fromB64url(h))), { alg: 'ES256', kid: 'KEY456' });
  assertEquals(JSON.parse(new TextDecoder().decode(fromB64url(p))), {
    iss: 'TEAM123', iat: 1_000, exp: 1_300, aud: 'https://appleid.apple.com', sub: 'com.eamongracias.ate',
  });
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicKey, fromB64url(s), new TextEncoder().encode(`${h}.${p}`));
  assert(ok, 'the signature verifies with the public half');
});

test('exchangeCode → the refresh token; revokeToken posts it back with the hint', async () => {
  const { cfg } = await freshKey();
  const seen: Array<{ url: string; form: URLSearchParams }> = [];
  const fetchImpl = (async (url: string, init?: RequestInit) => {
    seen.push({ url, form: new URLSearchParams(String(init?.body)) });
    return url.endsWith('/auth/token')
      ? new Response(JSON.stringify({ refresh_token: 'r.1', access_token: 'a' }), { status: 200 })
      : new Response('', { status: 200 });
  }) as unknown as typeof fetch;

  assertEquals(await exchangeCode(cfg, 'c.1', fetchImpl), 'r.1');
  assertEquals(seen[0].url, 'https://appleid.apple.com/auth/token');
  assertEquals([seen[0].form.get('code'), seen[0].form.get('grant_type'), seen[0].form.get('client_id')],
    ['c.1', 'authorization_code', 'com.eamongracias.ate']);
  assert((seen[0].form.get('client_secret') ?? '').split('.').length === 3);

  assertEquals(await revokeToken(cfg, 'r.1', fetchImpl), true);
  assertEquals(seen[1].url, 'https://appleid.apple.com/auth/revoke');
  assertEquals([seen[1].form.get('token'), seen[1].form.get('token_type_hint')], ['r.1', 'refresh_token']);
});

test('Apple saying no is a null / false, never a throw', async () => {
  const { cfg } = await freshKey();
  const no = (async () => new Response('{"error":"invalid_grant"}', { status: 400 })) as unknown as typeof fetch;
  assertEquals(await exchangeCode(cfg, 'c', no), null);
  assertEquals(await revokeToken(cfg, 'r', no), false);
  const down = (async () => { throw new Error('offline'); }) as unknown as typeof fetch;
  assertEquals(await exchangeCode(cfg, 'c', down), null);
  assertEquals(await revokeToken(cfg, 'r', down), false);
});
