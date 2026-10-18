// supabase/functions/dish-dedup/index.ts
//
// Ate — SAME DISH, DIFFERENT NAMES among the dishes that already exist (18 Oct, Eamon). Run from
// the Prod / Staging workflows, never by the app:
//
//   POST /functions/v1/dish-dedup     Authorization: Bearer <service role key>
//   { action: 'scan' }                  → proposes (./scan.ts) and returns every open proposal
//   { action: 'list' }                  → every open proposal
//   { action: 'merge', ids: [n, …] }    → merges those (merge_dish_proposals, 0071); ids: 'all' = every open one
//   { action: 'reject', ids: [n, …] }   → marks those rejected; a later scan never proposes them again
//   401 not the service role · 405 not POST · 422 bad body
//
// A scan writes proposals only. Merging is a separate, named call a person makes after reading the
// list. verify_jwt = false (config.toml): this checks its own bearer, which must be the service role.
//
// Secrets: ANTHROPIC_API_KEY (without it only the spelling-key tier runs), ATE_DEDUP_MODEL (optional),
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (auto-injected).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { DEFAULT_SCAN_MODEL, scanPlace, type Proposal, type ScanPlace } from './scan.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const MODEL = (Deno.env.get('ATE_DEDUP_MODEL') ?? '').trim() || DEFAULT_SCAN_MODEL;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

/** Constant-time: the bearer is the service role key, or nothing is done. */
function isServiceRole(req: Request): boolean {
  const got = new TextEncoder().encode((req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim());
  const want = new TextEncoder().encode(SERVICE_ROLE ?? '');
  if (!want.length || got.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < got.length; i++) diff |= got[i] ^ want[i];
  return diff === 0;
}

const ids = (raw: unknown): number[] | null =>
  Array.isArray(raw) && raw.length > 0 && raw.every((n) => Number.isInteger(n) && n > 0) ? raw as number[] : null;

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);
  if (!isServiceRole(req)) return json({ error: 'unauthorized' }, 401);
  const body = await req.json().then((b) => b ?? {}).catch(() => ({})) as { action?: unknown; ids?: unknown };
  const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

  const open = async () => {
    const { data, error } = await db.from('dish_merge_proposals')
      .select('id, restaurant_id, source_name, target_name, reason, why, source_dish_id, target_dish_id, created_at, restaurants(name)')
      .eq('status', 'proposed').order('id');
    if (error) throw new Error(error.message);
    return data ?? [];
  };

  try {
    switch (body.action) {
      case 'scan': {
        const { data: places, error } = await db.rpc('dish_scan_places');
        if (error) throw new Error(error.message);
        // every pair ever proposed, whatever became of it: a rejected pair is never asked again
        const { data: known, error: knownError } = await db.from('dish_merge_proposals').select('source_dish_id, target_dish_id');
        if (knownError) throw new Error(knownError.message);
        const seen = new Set((known ?? []).flatMap((k) => [`${k.source_dish_id}|${k.target_dish_id}`, `${k.target_dish_id}|${k.source_dish_id}`]));
        let asked = 0;
        const failed: string[] = [];
        const fresh: Proposal[] = [];
        // four places at a time: the function's wall clock is limited, and most places ask nothing
        const all = (places ?? []) as ScanPlace[];
        for (let i = 0; i < all.length; i += 4) {
          const batch = all.slice(i, i + 4);
          const results = await Promise.all(batch.map((place) => scanPlace(place, { apiKey: ANTHROPIC_KEY, model: MODEL })));
          results.forEach((got, j) => {
            asked += got.asked;
            if (got.failed) failed.push(batch[j].place_name ?? batch[j].restaurant_id);
            fresh.push(...got.proposals.filter((p) => !seen.has(`${p.source_dish_id}|${p.target_dish_id}`)));
          });
        }
        if (fresh.length) {
          const { error: insertError } = await db.from('dish_merge_proposals')
            .upsert(fresh, { onConflict: 'source_dish_id,target_dish_id', ignoreDuplicates: true });
          if (insertError) throw new Error(insertError.message);
        }
        return json({
          ok: true, places: (places ?? []).length, pairs_asked: asked, new_proposals: fresh.length,
          model: ANTHROPIC_KEY ? MODEL : null, places_without_ai: failed, open: await open(),
        });
      }
      case 'list':
        return json({ ok: true, open: await open() });
      case 'merge': {
        const which = body.ids === 'all' ? null : ids(body.ids);
        if (body.ids !== 'all' && !which) return json({ error: 'ids: a list of proposal numbers, or "all"' }, 422);
        const { data, error } = await db.rpc('merge_dish_proposals', { p_ids: which });
        if (error) throw new Error(error.message);
        return json({ ok: true, results: data ?? [] });
      }
      case 'reject': {
        const which = ids(body.ids);
        if (!which) return json({ error: 'ids: a list of proposal numbers' }, 422);
        const { data, error } = await db.from('dish_merge_proposals')
          .update({ status: 'rejected', decided_at: new Date().toISOString() })
          .in('id', which).eq('status', 'proposed').select('id');
        if (error) throw new Error(error.message);
        return json({ ok: true, rejected: (data ?? []).map((r) => r.id) });
      }
      default:
        return json({ error: 'action: scan, list, merge or reject' }, 422);
    }
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error('dish-dedup:', message);
    return json({ error: message }, 500);
  }
});
