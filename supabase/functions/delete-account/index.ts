// supabase/functions/delete-account/index.ts
//
// Ate — DELETE MY ACCOUNT, rows first, then the files (audit 26 Oct, finding 5). The app used to empty
// the person's storage itself and only then ask the database to delete the account, so a dropped
// connection left a signed-in account with every photo gone, and a crash the other way left photos at
// public URLs nobody could delete. Now:
//
//   POST /functions/v1/delete-account     (user JWT required)
//   1. delete_account() as the caller: one transaction, all or nothing, and it queues the caller's
//      storage folders (storage_purge_queue, 0094).
//   2. the caller's review-photos/<uid>/ and avatars/<uid>/ are emptied through the Storage API with
//      the service role, and on Cloudflare R2 through the photos Worker (0101), and the queue row
//      goes. A purge that fails keeps its row; the next call of
//      this function (anyone's) retries a few old rows, so files never outlive the account for long.
//   → 200 { ok: true, auth_user_deleted: true, storage_purged: bool }
//     401 unauthorized · 405 not POST · 500 the account was not deleted (nothing changed)
//
// Secrets: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY (auto-injected).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { purgeAccount, purgeR2 } from './purge.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

const bearer = (req: Request) => (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();

async function authedUserId(token: string): Promise<string | null> {
  if (!token) return null;
  try {
    const authClient = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
    const { data, error } = await authClient.auth.getUser(token);
    return error || !data?.user?.id ? null : data.user.id;
  } catch {
    return null;
  }
}

// deno-lint-ignore no-explicit-any
async function purgeQueued(admin: any, userId: string): Promise<boolean> {
  try {
    await purgeAccount((name) => admin.storage.from(name), userId);
    // 0101: and on R2, once photos live there. Supabase's copies go above either way.
    const base = await admin.rpc('photo_base');
    await purgeR2(typeof base.data === 'string' ? base.data : null, SERVICE_ROLE, userId);
    await admin.from('storage_purge_queue').delete().eq('user_id', userId);
    return true;
  } catch (e) {
    console.error('delete-account: purge failed:', e instanceof Error ? e.message : String(e));
    await admin.rpc('storage_purge_failed', { p_user_id: userId });
    return false;
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);
  const token = bearer(req);
  const userId = await authedUserId(token);
  if (!userId) return json({ error: 'unauthorized' }, 401);

  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { error } = await asCaller.rpc('delete_account');
  if (error) {
    console.error('delete-account: delete_account failed:', error.message);
    return json({ error: 'delete failed' }, 500);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });
  const purged = await purgeQueued(admin, userId);

  // Leftovers from earlier failed purges: a few at a time, oldest first, given up after 10 tries.
  const { data: stale } = await admin.from('storage_purge_queue')
    .select('user_id').neq('user_id', userId).lt('attempts', 10).order('queued_at').limit(3);
  for (const row of stale ?? []) await purgeQueued(admin, row.user_id);

  return json({ ok: true, auth_user_deleted: true, storage_purged: purged });
});
