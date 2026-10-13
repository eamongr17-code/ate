// supabase/functions/match-photos/index.ts
//
// Ate — WHICH PHOTO IS WHICH DISH (design/rebuild/date-and-photos.html). The app calls this after
// an entry's photos are uploaded and its words are sorted, and again after an edit re-sorts it.
//
//   POST /functions/v1/match-photos        (user JWT required — the anon key alone is a 401)
//   body: { entry_id: uuid }
//   → 200 { ok: true, matched: int }       (matched = lines whose photo was set or cleared)
//     401 unauthorized · 404 not the caller's entry · 405 not POST · 422 bad body
//
// The author's own picks (set_review_photo, 0063) are never offered to the model. One line on the
// whole entry takes the first photo with no model. Anything more goes to Claude with the photos as
// URL images (public storage) through a forced tool call (./match.ts), and only pairs naming a real
// photo and a real line survive. Without ANTHROPIC_API_KEY, or on any model failure, nothing is
// written: the lines keep what they had and cover reads fall back to the entry's first photo.
//
// Secrets: ANTHROPIC_API_KEY (optional), ATE_SORTER_MODEL (optional, the sorter's model),
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY (auto-injected).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { askModel, plan, resolveModel, type Line, type Photo } from './match.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const MODEL_ID = resolveModel(Deno.env.get('ATE_SORTER_MODEL'));

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

function adminClient() {
  return createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });
}

/** AUTH GATE (same shape as sort-entry / read-share): a token that resolves to a real USER. */
async function authedUserId(req: Request): Promise<string | null> {
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!token) return null;
  try {
    const authClient = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
    const { data, error } = await authClient.auth.getUser(token);
    if (error || !data?.user?.id) return null;
    return data.user.id;
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const userId = await authedUserId(req);
  if (!userId) return json({ error: 'unauthorized' }, 401);

  let entryId: unknown;
  try {
    entryId = (await req.json())?.entry_id;
  } catch {
    return json({ error: 'bad body' }, 422);
  }
  if (typeof entryId !== 'string' || !UUID.test(entryId)) return json({ error: 'bad entry_id' }, 422);

  const admin = adminClient();
  const { data: entry, error: entryError } = await admin
    .from('entries').select('id, author_id').eq('id', entryId).maybeSingle();
  if (entryError) {
    console.error('match-photos: entry read failed:', entryError.message);
    return json({ error: 'read failed' }, 500);
  }
  if (!entry || entry.author_id !== userId) return json({ error: 'not found' }, 404);

  // Photos an edit overwrote in place leave their lines first (0063), so those lines are open again.
  const pruned = await admin.rpc('prune_photo_pairs', { p_entry_id: entryId });
  if (pruned.error) console.error('match-photos: prune_photo_pairs failed:', pruned.error.message);

  const [photosRes, linesRes] = await Promise.all([
    admin.from('entry_photos').select('position, photo_url').eq('entry_id', entryId).order('position'),
    admin.from('reviews')
      .select('id, note, photo_url, photo_picked_at, entry_position, dishes(name)')
      .eq('entry_id', entryId)
      .order('entry_position'),
  ]);
  if (photosRes.error || linesRes.error) {
    console.error('match-photos: read failed:', photosRes.error?.message ?? linesRes.error?.message);
    return json({ error: 'read failed' }, 500);
  }

  const photos: Photo[] = (photosRes.data ?? [])
    .filter((p) => typeof p.photo_url === 'string')
    .map((p) => ({ position: p.position as number, url: p.photo_url as string }));
  // deno-lint-ignore no-explicit-any
  const lines: Line[] = (linesRes.data ?? []).map((r: any) => ({
    review_id: r.id,
    dish: (Array.isArray(r.dishes) ? r.dishes[0]?.name : r.dishes?.name) ?? '',
    note: r.note ?? null,
    picked: r.photo_picked_at != null,
    photo_url: r.photo_url ?? null,
  }));

  const next = plan(photos, lines);
  if (next.kind === 'nothing') return json({ ok: true, matched: 0 });

  const matches = next.kind === 'direct'
    ? next.matches
    : await askModel({ apiKey: ANTHROPIC_KEY, photos: next.photos, lines: next.lines, model: MODEL_ID });
  if (!matches) return json({ ok: true, matched: 0 });

  const { data: n, error: writeError } = await admin.rpc('apply_photo_matches', {
    p_entry_id: entryId,
    p_matches: matches,
  });
  if (writeError) {
    console.error('match-photos: apply_photo_matches failed:', writeError.message);
    return json({ error: 'write failed' }, 500);
  }
  return json({ ok: true, matched: n ?? 0 });
});
