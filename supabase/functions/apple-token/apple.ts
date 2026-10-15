// supabase/functions/apple-token/apple.ts
//
// Sign in with Apple's server half: the client secret (an ES256 JWT signed with the team's Sign in
// with Apple key), the authorization-code → refresh-token exchange, and the revoke Apple requires
// when an account is deleted (App Store guideline 5.1.1(v)).
//
// PURE apart from the injected fetch and WebCrypto, so the suite runs under Node.

export type AppleConfig = {
  teamId: string;
  keyId: string;
  /** The .p8 file's contents (PKCS#8 PEM). Literal "\n" sequences are accepted for one-line secrets. */
  privateKey: string;
  /** The app's bundle id: the client the codes were issued to. */
  clientId: string;
};

const APPLE = 'https://appleid.apple.com';
export const APPLE_TIMEOUT_MS = 5_000;

/** The config from the function's secrets, or null when any part is missing (then the function is inert). */
export function appleConfig(env: (k: string) => string | undefined): AppleConfig | null {
  const teamId = env('APPLE_TEAM_ID')?.trim();
  const keyId = env('APPLE_SIGNIN_KEY_ID')?.trim();
  const privateKey = env('APPLE_SIGNIN_PRIVATE_KEY')?.trim();
  const clientId = env('APPLE_CLIENT_ID')?.trim() || 'com.eamongracias.ate';
  if (!teamId || !keyId || !privateKey) return null;
  return { teamId, keyId, privateKey, clientId };
}

const b64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const b64urlJson = (v: unknown) => b64url(new TextEncoder().encode(JSON.stringify(v)));

function pemBytes(pem: string): Uint8Array {
  const body = pem.replace(/\\n/g, '\n').replace(/-----[A-Z ]+-----/g, '').replace(/\s+/g, '');
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

/** The client secret Apple's token endpoints take: ES256, valid five minutes. */
export async function clientSecret(cfg: AppleConfig, nowS = Math.floor(Date.now() / 1000)): Promise<string> {
  const key = await crypto.subtle.importKey(
    'pkcs8', pemBytes(cfg.privateKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'],
  );
  const signingInput = `${b64urlJson({ alg: 'ES256', kid: cfg.keyId })}.${b64urlJson({
    iss: cfg.teamId, iat: nowS, exp: nowS + 300, aud: APPLE, sub: cfg.clientId,
  })}`;
  // WebCrypto's ECDSA signature is already JOSE's r||s form.
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(signingInput)));
  return `${signingInput}.${b64url(sig)}`;
}

async function post(path: string, form: Record<string, string>, fetchImpl: typeof fetch): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), APPLE_TIMEOUT_MS);
  try {
    return await fetchImpl(`${APPLE}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(form).toString(),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

/** The app's one-time authorization code → Apple's refresh token, or null on any failure. */
export async function exchangeCode(cfg: AppleConfig, code: string, fetchImpl: typeof fetch = fetch): Promise<string | null> {
  try {
    const res = await post('/auth/token', {
      client_id: cfg.clientId,
      client_secret: await clientSecret(cfg),
      code,
      grant_type: 'authorization_code',
    }, fetchImpl);
    if (!res.ok) {
      console.error(`apple-token: exchange HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
      return null;
    }
    const body = await res.json() as { refresh_token?: unknown };
    return typeof body.refresh_token === 'string' && body.refresh_token ? body.refresh_token : null;
  } catch (e) {
    console.error('apple-token: exchange failed:', e instanceof Error ? e.message : String(e));
    return null;
  }
}

/** Revokes the refresh token (and with it the app's access to the Apple ID). True when Apple said 200. */
export async function revokeToken(cfg: AppleConfig, refreshToken: string, fetchImpl: typeof fetch = fetch): Promise<boolean> {
  try {
    const res = await post('/auth/revoke', {
      client_id: cfg.clientId,
      client_secret: await clientSecret(cfg),
      token: refreshToken,
      token_type_hint: 'refresh_token',
    }, fetchImpl);
    if (!res.ok) console.error(`apple-token: revoke HTTP ${res.status}`);
    return res.ok;
  } catch (e) {
    console.error('apple-token: revoke failed:', e instanceof Error ? e.message : String(e));
    return false;
  }
}
