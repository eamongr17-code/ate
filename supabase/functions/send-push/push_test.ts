// supabase/functions/send-push/push_test.ts
// deno-lint-ignore-file no-explicit-any
//
//   node --test supabase/functions/send-push/*_test.ts          (or: deno test --no-check supabase/functions/send-push/)
//
// The handler end to end with a fake database (records every rpc) and a fake APNs (`fetch`). WHICH rows
// may be pushed — never quiet, read, dismissed, declined or blocked; not before the tagger's entry has
// sorted — is decided by push_claim_ate_with and pinned in SQL by supabase/tests/db/send_push_test.mjs;
// here the rule is that the function sends exactly what the claim returns, and nothing when it returns [].

import { test, assert, assertEquals } from '../sort-entry/harness.ts';
import { createHandler, pushCopy, resetJwtCache, resetKickSecretCache, type Claimed, type Deps } from './push.ts';

const SERVICE = 'service-role-key-for-tests';
const KICK = 'f0'.repeat(32); // what push_configure would have generated

async function makeKey() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  const b64 = btoa(String.fromCharCode(...der));
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g)!.join('\n')}\n-----END PRIVATE KEY-----`;
  return { pem, publicKey: pair.publicKey };
}
const KEY = await makeKey();

const SECRETS: Record<string, string> = {
  SUPABASE_SERVICE_ROLE_KEY: SERVICE,
  APNS_KEY_ID: 'KEY1234567',
  APNS_TEAM_ID: 'TEAM123456',
  APNS_PRIVATE_KEY: KEY.pem.replace(/\n/g, '\\n'), // as a one-line secret, escaped newlines
};

const ROW: Claimed = {
  notification_id: 'n-1',
  companion_id: '00000000-0000-4000-8000-0000000000c1',
  entry_id: '00000000-0000-4000-8000-000000000001',
  recipient_id: '00000000-0000-4000-8000-00000000000b',
  actor_username: 'eamon',
  place_name: 'Tipo 00',
  dish_names: ['Tagliatelle al ragù', 'Tiramisu', 'Prawn spaghetti'],
  badge: 2,
  tokens: [{ token: 'aa'.repeat(32), apns_env: 'sandbox' }, { token: 'bb'.repeat(32), apns_env: 'production' }],
};

type Sent = { url: string; headers: Record<string, string>; body: any };
function world(opts: {
  secrets?: Record<string, string>; rows?: Claimed[]; apns?: (url: string) => Response; now?: () => number;
  kick?: string | null; failRpc?: string;
} = {}) {
  resetKickSecretCache();
  const rpcs: { name: string; args: any }[] = [];
  const sent: Sent[] = [];
  let dbOpened = 0;
  const secrets = opts.secrets ?? SECRETS;
  const deps: Deps = {
    env: (k) => secrets[k],
    db: () => {
      dbOpened++;
      return {
        rpc: async (name: string, args?: Record<string, unknown>) => {
          rpcs.push({ name, args });
          if (name === opts.failRpc) return { data: null, error: { message: 'boom' } };
          if (name === 'push_kick_secret') return { data: opts.kick === undefined ? KICK : opts.kick, error: null };
          return { data: name === 'push_claim_ate_with' ? (opts.rows ?? [ROW]) : 1, error: null };
        },
      };
    },
    fetch: async (url, init) => {
      sent.push({ url, headers: init.headers as Record<string, string>, body: JSON.parse(String(init.body)) });
      return opts.apns ? opts.apns(url) : new Response('', { status: 200 });
    },
    now: opts.now,
  };
  const call = (auth = `Bearer ${SERVICE}`) =>
    createHandler(deps)(new Request('http://x/send-push', { method: 'POST', headers: { Authorization: auth }, body: '{}' }));
  return { call, rpcs, sent, opened: () => dbOpened };
}

async function verifyJwt(jwt: string) {
  const [h, c, s] = jwt.split('.');
  const dec = (x: string) => Uint8Array.from(atob(x.replace(/-/g, '+').replace(/_/g, '/')), (ch) => ch.charCodeAt(0));
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, KEY.publicKey, dec(s), new TextEncoder().encode(`${h}.${c}`));
  return { ok, header: JSON.parse(new TextDecoder().decode(dec(h))), claims: JSON.parse(new TextDecoder().decode(dec(c))) };
}

test('copy: exactly the approved push — who + where, then the dishes', () => {
  assertEquals(pushCopy(ROW), { title: '@eamon ate with you at Tipo 00', body: 'Tagliatelle al ragù, tiramisu, prawn spaghetti' });
  assertEquals(pushCopy({ ...ROW, dish_names: [] }), { title: '@eamon ate with you at Tipo 00' }, 'no dishes: no body');
  assertEquals(pushCopy({ ...ROW, dish_names: ['Burger', 'BBQ wings'] }).body, 'Burger, BBQ wings', 'an acronym keeps its case');
  assert([...pushCopy({ ...ROW, dish_names: Array(40).fill('Gnocchi') }).body!].length <= 178, 'bounded');
});

test('happy path: one APNs request per token, each to ITS host, signed, with the tag id; then marked pushed', async () => {
  resetJwtCache();
  const w = world();
  const res = await w.call();
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { ok: true, claimed: 1, sent: 2, marked: 1, dropped: 0 });
  assertEquals(w.sent.map((x) => x.url), [
    `https://api.sandbox.push.apple.com/3/device/${'aa'.repeat(32)}`, // an Xcode-installed build
    `https://api.push.apple.com/3/device/${'bb'.repeat(32)}`,         // a TestFlight build, even on staging
  ], 'the host is the token\'s, never one per project');
  const [s] = w.sent;
  assertEquals(s.headers['apns-topic'], 'com.eamongracias.ate');
  assertEquals(s.headers['apns-push-type'], 'alert');
  assertEquals(s.body.aps.alert, { title: '@eamon ate with you at Tipo 00', body: 'Tagliatelle al ragù, tiramisu, prawn spaghetti' });
  assertEquals(s.body.aps.badge, 2);
  assertEquals([s.body.type, s.body.companion_id, s.body.entry_id], ['ate_with', ROW.companion_id, ROW.entry_id]);
  const jwt = await verifyJwt(s.headers.authorization.replace(/^bearer /, ''));
  assert(jwt.ok, 'ES256 signature verifies with the key\'s public half');
  assertEquals(jwt.header, { alg: 'ES256', kid: 'KEY1234567' });
  assertEquals(jwt.claims.iss, 'TEAM123456');
  assertEquals(w.rpcs.map((r) => r.name), ['push_claim_ate_with', 'push_mark_sent']);
  assertEquals(w.rpcs[1].args, { p_ids: ['n-1'] });
  assertEquals(w.sent[1].headers.authorization, s.headers.authorization, 'one key, one provider token, both hosts');

  const odd = world({ rows: [{ ...ROW, tokens: [{ token: 'dd'.repeat(32), apns_env: 'staging' }] }] });
  await odd.call();
  assertEquals(odd.sent.length, 0, 'an unknown environment is never guessed at (and never dropped)');
});

test('no APNS secrets: a clean no-op — {configured:false}, no claim, no APNs, nothing marked', async () => {
  for (const missing of ['APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_PRIVATE_KEY']) {
    const secrets = { ...SECRETS };
    delete secrets[missing];
    const w = world({ secrets });
    const res = await w.call();
    assertEquals(res.status, 200);
    assertEquals(await res.json(), { ok: true, configured: false }, missing);
    assertEquals([w.opened(), w.sent.length], [0, 0], `${missing}: touched nothing`);
  }
});

test('auth: the service-role key or the database\'s kick secret; anything else is 401', async () => {
  const w = world();
  assertEquals((await w.call(`Bearer ${SERVICE}`)).status, 200, 'service role');
  assert(!w.rpcs.some((r) => r.name === 'push_kick_secret'), 'the service key needs no Vault read');

  const k = world();
  const res = await k.call(`Bearer ${KICK}`);
  assertEquals(res.status, 200, 'the kick secret pg_net sends');
  assertEquals((await res.json()).sent, 2);
  await k.call(`Bearer ${KICK}`);
  assertEquals(k.rpcs.filter((r) => r.name === 'push_kick_secret').length, 1, 'read once, then cached');

  const bad = world();
  for (const auth of ['', 'Bearer ', 'Bearer anon-key', `Bearer ${SERVICE}x`, `Bearer ${KICK.slice(1)}`, `Bearer ${KICK}0`]) {
    assertEquals((await bad.call(auth)).status, 401, JSON.stringify(auth));
  }
  assertEquals([bad.sent.length, bad.rpcs.filter((r) => r.name !== 'push_kick_secret').length], [0, 0], 'a wrong bearer claims and sends nothing');

  const unconfigured = world({ kick: null });
  assertEquals((await unconfigured.call(`Bearer ${KICK}`)).status, 401, 'no kick secret in Vault: only the service key works');
  const noKey = world({ secrets: { ...SECRETS, SUPABASE_SERVICE_ROLE_KEY: '' }, kick: '' });
  assertEquals((await noKey.call('Bearer x')).status, 401, 'empty secrets never match');
});

test('settled per row: a failure mid-batch leaves the rows already sent marked; RPC errors are reported', async () => {
  const second: Claimed = { ...ROW, notification_id: 'n-2', tokens: [{ token: 'ee'.repeat(32), apns_env: 'sandbox' }] };
  const w = world({ rows: [ROW, second], apns: (url) => url.endsWith('ee'.repeat(32)) ? new Response('', { status: 410 }) : new Response('', { status: 200 }) });
  // a mark that errors is reported, not swallowed
  const markFails = world({ failRpc: 'push_mark_sent' });
  const r1 = await markFails.call();
  assertEquals(r1.status, 500);
  const b1 = await r1.json();
  assertEquals([b1.ok, b1.sent, b1.marked], [false, 2, 0]);
  assert(String(b1.errors).includes('mark n-1'), 'names the row');
  // a drop that errors is reported; the row is still marked
  const dropFails = world({ rows: [second], apns: () => new Response('', { status: 410 }), failRpc: 'push_drop_tokens' });
  const b2 = await (await dropFails.call()).json();
  assertEquals([b2.ok, b2.dropped, b2.marked], [false, 0, 1]);
  // row 1 is marked BEFORE row 2 is attempted
  const r3 = await w.call();
  assertEquals(w.rpcs.map((r) => r.name), ['push_claim_ate_with', 'push_mark_sent', 'push_drop_tokens', 'push_mark_sent']);
  assertEquals((await r3.json()).marked, 2);
});

test('a throw mid-batch (a lost connection on row 2) keeps row 1 marked', async () => {
  const second: Claimed = { ...ROW, notification_id: 'n-2', tokens: [{ token: 'ee'.repeat(32), apns_env: 'sandbox' }] };
  const rpcs: string[] = [];
  const handler = createHandler({
    env: (k) => SECRETS[k],
    db: () => ({
      rpc: async (name: string) => {
        rpcs.push(name);
        if (name === 'push_claim_ate_with') return { data: [ROW, second], error: null };
        if (name === 'push_drop_tokens') throw new Error('connection lost');
        return { data: 1, error: null };
      },
    }),
    fetch: async (url) => new Response('', { status: url.endsWith('ee'.repeat(32)) ? 410 : 200 }),
  });
  const res = await handler(new Request('http://x', { method: 'POST', headers: { Authorization: `Bearer ${SERVICE}` } }));
  assertEquals(res.status, 500);
  assertEquals(rpcs, ['push_claim_ate_with', 'push_mark_sent', 'push_drop_tokens'], 'row 1 was marked before the throw');
  const body = await res.json();
  assertEquals([body.marked, body.sent], [1, 2]);
  assert(String(body.errors).includes('connection lost'));
});

test('410 and BadDeviceToken drop the token; the notification still counts as pushed', async () => {
  const both: Claimed = { ...ROW, tokens: [{ token: 'aa'.repeat(32), apns_env: 'sandbox' }, { token: 'cc'.repeat(32), apns_env: 'sandbox' }] };
  const w = world({
    rows: [both],
    apns: (url) => url.endsWith('aa'.repeat(32))
      ? new Response(JSON.stringify({ reason: 'Unregistered' }), { status: 410 })
      : new Response(JSON.stringify({ reason: 'BadDeviceToken' }), { status: 400 }),
  });
  assertEquals((await (await w.call()).json()).dropped, 2);
  assertEquals(w.rpcs.find((r) => r.name === 'push_drop_tokens')!.args, { p_tokens: ['aa'.repeat(32), 'cc'.repeat(32)] });
  assertEquals(w.rpcs.find((r) => r.name === 'push_mark_sent')!.args, { p_ids: ['n-1'] });
});

test('a transient failure (5xx / network) leaves the row for the retry drain; nothing dropped', async () => {
  const w = world({ apns: () => new Response('', { status: 503 }) });
  assertEquals(await (await w.call()).json(), { ok: true, claimed: 1, sent: 0, marked: 0, dropped: 0 });
  assertEquals(w.rpcs.map((r) => r.name), ['push_claim_ate_with']);
  const down = world({ apns: () => { throw new Error('ECONNRESET'); } });
  assertEquals((await (await down.call()).json()).marked, 0);
});

test('nothing claimed (quiet, read, dismissed, declined, blocked, unsorted) → nothing sent, nothing marked', async () => {
  const w = world({ rows: [] });
  assertEquals(await (await w.call()).json(), { ok: true, claimed: 0, sent: 0, marked: 0, dropped: 0 });
  assertEquals([w.sent.length, w.rpcs.map((r) => r.name).join()], [0, 'push_claim_ate_with']);
  const noDevice = world({ rows: [{ ...ROW, tokens: [] }] });
  await noDevice.call();
  assertEquals(noDevice.rpcs.find((r) => r.name === 'push_mark_sent')!.args, { p_ids: ['n-1'] }, 'no device: marked, not retried');
});

test('the provider token is cached under 50 minutes, then re-signed', async () => {
  resetJwtCache();
  let t = Date.UTC(2026, 9, 5, 9, 0, 0);
  const w = world({ now: () => t });
  await w.call();
  t += 49 * 60_000;
  await w.call();
  t += 2 * 60_000;                                   // 51 minutes after the first
  await w.call();
  const jwts = w.sent.filter((_, i) => i % 2 === 0).map((s) => s.headers.authorization); // first token of each call
  assertEquals(jwts[0], jwts[1], 'reused inside 50 minutes');
  assert(jwts[2] !== jwts[0], 're-signed after 50 minutes');
  assertEquals((await verifyJwt(jwts[2].replace(/^bearer /, ''))).claims.iat, Math.floor(t / 1000));
});
