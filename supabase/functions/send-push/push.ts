// supabase/functions/send-push/push.ts
//
// The sender's whole logic, runtime-free so it is tested under Node and Deno alike (index.ts only wires
// Deno.serve + supabase-js into it). See index.ts for the contract.

export const BUNDLE_ID = 'com.eamongracias.ate';
export const APNS_HOSTS = { sandbox: 'api.sandbox.push.apple.com', production: 'api.push.apple.com' } as const;
export type ApnsEnv = keyof typeof APNS_HOSTS;
const JWT_MAX_AGE_S = 50 * 60;            // Apple: valid ≤ 60 min, refresh no more than every 20
const BODY_MAX = 178;

export type Env = (name: string) => string | undefined;
export type RpcResult = { data: unknown; error: { message: string } | null };
export interface Db { rpc(name: string, args?: Record<string, unknown>): PromiseLike<RpcResult> }
export interface Deps {
  env: Env;
  db: () => Db;
  fetch: (url: string, init: RequestInit) => Promise<Response>;
  now?: () => number;                     // ms; injectable for the JWT cache test
}

/** One row of push_claim_ate_with (0059). */
export interface Claimed {
  notification_id: string;
  companion_id: string;
  entry_id: string;
  recipient_id: string;
  actor_username: string;
  place_name: string | null;
  dish_names: string[];
  badge: number;
  tokens: { token: string; apns_env: string }[];
}

export interface ApnsConfig { keyId: string; teamId: string; privateKey: string }

/** null = not configured → the function is a no-op (deploying before the .p8 exists is harmless). */
export function readApnsConfig(env: Env): ApnsConfig | null {
  const keyId = env('APNS_KEY_ID')?.trim();
  const teamId = env('APNS_TEAM_ID')?.trim();
  const privateKey = env('APNS_PRIVATE_KEY')?.trim();
  if (!keyId || !teamId || !privateKey) return null;
  return { keyId, teamId, privateKey };
}

// ─── Copy — design/rebuild/ate-with.html "The push": title = who + where, body = the dishes, nothing else.
const ACRONYM = /\b\p{Lu}{2,}\b/u;
export function pushCopy(row: Pick<Claimed, 'actor_username' | 'place_name' | 'dish_names'>): { title: string; body?: string } {
  const who = `@${row.actor_username}`;
  const title = row.place_name ? `${who} ate with you at ${row.place_name}` : `${who} ate with you`;
  const names = (row.dish_names ?? []).map((n) => n.trim()).filter(Boolean);
  if (names.length === 0) return { title };
  // "Tagliatelle al ragù, tiramisu, prawn spaghetti": a list in sentence case (an acronym keeps its case).
  let body = names.map((n, i) => (i === 0 || ACRONYM.test(n) ? n : n.toLocaleLowerCase())).join(', ');
  if ([...body].length > BODY_MAX) body = [...body].slice(0, BODY_MAX - 1).join('').trimEnd() + '…';
  return { title, body };
}

export function payload(row: Claimed): Record<string, unknown> {
  return {
    aps: { alert: pushCopy(row), badge: row.badge, sound: 'default', 'thread-id': 'ate-with' },
    type: 'ate_with',
    companion_id: row.companion_id,
    notification_id: row.notification_id,
    entry_id: row.entry_id,
  };
}

// ─── The provider token (ES256 JWT), cached per key under 50 minutes.
const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const b64urlJson = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));

function pkcs8(pem: string): Uint8Array {
  const b64 = pem.replace(/\\n/g, '\n').replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\s+/g, '');
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

let jwtCache: { key: string; jwt: string; iat: number } | null = null;
export function resetJwtCache(): void { jwtCache = null; }

export async function providerToken(cfg: ApnsConfig, nowMs: number): Promise<string> {
  const iat = Math.floor(nowMs / 1000);
  const key = `${cfg.teamId}:${cfg.keyId}`;
  if (jwtCache && jwtCache.key === key && iat - jwtCache.iat < JWT_MAX_AGE_S) return jwtCache.jwt;
  const signer = await crypto.subtle.importKey('pkcs8', pkcs8(cfg.privateKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const input = `${b64urlJson({ alg: 'ES256', kid: cfg.keyId })}.${b64urlJson({ iss: cfg.teamId, iat })}`;
  // WebCrypto's ECDSA signature is already the raw r‖s (IEEE P1363) form JWS wants.
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, signer, new TextEncoder().encode(input)));
  jwtCache = { key, jwt: `${input}.${b64url(sig)}`, iat };
  return jwtCache.jwt;
}

// ─── One send. ok · dead (drop the token) · transient (retry later) · rejected (APNs refused the
// payload or our token: retrying the same request will not help).
export type Outcome = 'ok' | 'dead' | 'transient' | 'rejected';
const DEAD_REASONS = new Set(['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic']);
const AUTH_REASONS = new Set(['ExpiredProviderToken', 'InvalidProviderToken', 'MissingProviderToken']);

async function sendOne(deps: Deps, env: ApnsEnv, jwt: string, token: string, row: Claimed, nowMs: number): Promise<Outcome> {
  let res: Response;
  try {
    res = await deps.fetch(`https://${APNS_HOSTS[env]}/3/device/${token}`, {
      method: 'POST',
      headers: {
        authorization: `bearer ${jwt}`,
        'apns-topic': BUNDLE_ID,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-expiration': String(Math.floor(nowMs / 1000) + 24 * 3600),
        'apns-collapse-id': row.companion_id,
        'content-type': 'application/json',
      },
      body: JSON.stringify(payload(row)),
    });
  } catch {
    return 'transient';
  }
  if (res.status === 200) return 'ok';
  if (res.status === 410) return 'dead';
  let reason = '';
  try { reason = String((await res.json())?.reason ?? ''); } catch { /* no body */ }
  if (res.status === 400 && DEAD_REASONS.has(reason)) return 'dead';
  if (res.status === 403 && AUTH_REASONS.has(reason)) { resetJwtCache(); return 'transient'; }
  if (res.status === 429 || res.status >= 500) return 'transient';
  return 'rejected';
}

function bearer(req: Request): string {
  return (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
}
function sameSecret(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

export function createHandler(deps: Deps): (req: Request) => Promise<Response> {
  return async (req) => {
    if (!sameSecret(bearer(req), deps.env('SUPABASE_SERVICE_ROLE_KEY') ?? '')) {
      return json(401, { error: 'unauthorized' });
    }
    const cfg = readApnsConfig(deps.env);
    if (!cfg) return json(200, { ok: true, skipped: 'apns_not_configured' });

    const db = deps.db();
    const claimed = await db.rpc('push_claim_ate_with', { p_limit: 50 });
    if (claimed.error) return json(500, { error: 'claim failed', detail: claimed.error.message });
    const rows = (claimed.data ?? []) as Claimed[];
    const nowMs = (deps.now ?? Date.now)();

    const done: string[] = [];
    const dead: string[] = [];
    let sent = 0;
    for (const row of rows) {
      // The host is the TOKEN's: a TestFlight build on staging holds a production token, an Xcode build
      // a sandbox one. Sending to the wrong host answers BadDeviceToken and would delete a live token.
      const tokens = (row.tokens ?? []).filter((t) => t.apns_env === 'sandbox' || t.apns_env === 'production');
      const outcomes: Outcome[] = [];
      for (const { token, apns_env } of tokens) {
        const jwt = await providerToken(cfg, nowMs);
        const o = await sendOne(deps, apns_env as ApnsEnv, jwt, token, row, nowMs);
        outcomes.push(o);
        if (o === 'ok') sent++;
        if (o === 'dead') dead.push(token);
      }
      // Pushed unless EVERY attempt was transient (no device at all also counts: nothing to retry).
      // A transient-only row keeps its claim, which goes stale in 2 min; the minute drain retries (≤ 5).
      if (outcomes.length === 0 || outcomes.some((o) => o !== 'transient')) done.push(row.notification_id);
    }
    if (dead.length) await db.rpc('push_drop_tokens', { p_tokens: dead });
    if (done.length) await db.rpc('push_mark_sent', { p_ids: done });
    return json(200, { ok: true, claimed: rows.length, sent, marked: done.length, dropped: dead.length });
  };
}
