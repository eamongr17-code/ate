// supabase/functions/apple-token/index.ts
//
// Ate — SIGN IN WITH APPLE'S TOKEN, KEPT SO IT CAN BE REVOKED. App Store guideline 5.1.1(v): an app
// that offers Sign in with Apple revokes the user's Apple token when they delete their account.
// Revoking needs Apple's refresh token, which only an exchange of the one-time authorization code
// (handed to the app at sign-in) produces, so:
//
//   POST /functions/v1/apple-token   (user JWT required)
//   { action: "store", code }  after sign-in: exchange the code, keep the refresh token (0068).
//   { action: "revoke" }       before delete_account: revoke the kept token at Apple, forget it.
//   → 200 { ok: true, configured: bool, stored?: bool, revoked?: bool }
//     401 unauthorized · 405 not POST · 422 bad body
//
// Inert (configured: false) until the Sign in with Apple key is in the function secrets:
// APPLE_TEAM_ID, APPLE_SIGNIN_KEY_ID, APPLE_SIGNIN_PRIVATE_KEY (the .p8), APPLE_CLIENT_ID (optional,
// the bundle id). Never fails the caller's flow: the app treats every answer as best-effort.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { appleConfig, exchangeCode, revokeToken } from './apple.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const CONFIG = appleConfig((k) => Deno.env.get(k));

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

async function authedUserId(req: Request): Promise<string | null> {
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!token) return null;
  try {
    const authClient = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
    const { data, error } = await authClient.auth.getUser(token);
    return error || !data?.user?.id ? null : data.user.id;
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);
  const userId = await authedUserId(req);
  if (!userId) return json({ error: 'unauthorized' }, 401);

  const body = await req.json().catch(() => null) as { action?: unknown; code?: unknown } | null;
  const action = body?.action;
  if (action !== 'store' && action !== 'revoke') return json({ error: 'bad action' }, 422);
  if (!CONFIG) return json({ ok: true, configured: false });

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

  if (action === 'store') {
    const code = typeof body?.code === 'string' ? body.code.trim() : '';
    if (!code || code.length > 512) return json({ error: 'bad code' }, 422);
    const refreshToken = await exchangeCode(CONFIG, code);
    if (!refreshToken) return json({ ok: true, configured: true, stored: false });
    const { error } = await admin.from('apple_tokens')
      .upsert({ user_id: userId, refresh_token: refreshToken, updated_at: new Date().toISOString() });
    if (error) console.error('apple-token: store failed:', error.message);
    return json({ ok: true, configured: true, stored: !error });
  }

  const { data: row, error: readError } = await admin.from('apple_tokens')
    .select('refresh_token').eq('user_id', userId).maybeSingle();
  if (readError) console.error('apple-token: read failed:', readError.message);
  if (!row?.refresh_token) return json({ ok: true, configured: true, revoked: false });
  const revoked = await revokeToken(CONFIG, row.refresh_token);
  if (revoked) await admin.from('apple_tokens').delete().eq('user_id', userId);
  return json({ ok: true, configured: true, revoked });
});
