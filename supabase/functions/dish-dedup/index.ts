// supabase/functions/dish-dedup/index.ts
//
// Ate — SAME DISH, DIFFERENT NAMES among the dishes that already exist (18 Oct, Eamon). Run from
// the Prod / Staging workflows, never by the app:
//
//   POST /functions/v1/dish-dedup     Authorization: Bearer <service role key>
//   { action: 'scan' }                  → proposes (./scan.ts) and returns every open proposal
//   { action: 'scan', merge: 'same_name' } → the same, then merges the same-name proposals (no model
//                                          judged those; Eamon, 20 Oct: one button, not two)
//   { action: 'list' }                  → every open proposal
//   { action: 'merge', ids: [n, …] }    → merges those (merge_dish_proposals, 0071); ids: 'all' = every open one
//   { action: 'reject', ids: [n, …] }   → marks those rejected; a later scan never proposes them again
//   { action: 'chains' }                → links chain restaurants (0085): every unchained Google place whose
//                                         name repeats gets its website checked (up to 200 a run, once
//                                         per place), and same name + same website host become one chain
//                                         whose locations share one menu (their dishes merge)
//   401 not a service-role key · 405 not POST · 422 bad body
//
// A scan writes proposals only. Merging is a separate, named call a person makes after reading the
// list. verify_jwt = false (config.toml): this checks its own bearer, which must be the service role.
//
// Secrets: ANTHROPIC_API_KEY (without it only the spelling-key tier runs), ATE_DEDUP_MODEL (optional),
// GOOGLE_PLACES_API_KEY (chains only), SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (auto-injected).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { DEFAULT_SCAN_MODEL, pairKey, scanPlace, type Apart, type Proposal, type ScanPlace } from './scan.ts';
import { googleWebsite, linkChains } from '../places-search/chains.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const MODEL = (Deno.env.get('ATE_DEDUP_MODEL') ?? '').trim() || DEFAULT_SCAN_MODEL;
const GOOGLE_KEY = (Deno.env.get('GOOGLE_PLACES_API_KEY') ?? '').trim();

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

/** Constant-time compare of two strings. */
function same(a: string, b: string): boolean {
  const got = new TextEncoder().encode(a);
  const want = new TextEncoder().encode(b);
  if (!want.length || got.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < got.length; i++) diff |= got[i] ^ want[i];
  return diff === 0;
}

/**
 * The bearer is a service-role key, or nothing is done. The injected key is one form of it; a project
 * on the new API keys hands the workflow another (sb_secret_…, 18 Oct prod: 401), so any other bearer
 * is put to the database itself: is_service_role() (0093) is true only when PostgREST runs the request
 * as service_role. (It used to probe dish_merge_proposals, which held only while no grant ever
 * reached that table: an empty 200 to a role with SELECT and no policy would have passed.)
 */
async function isServiceRole(req: Request): Promise<boolean> {
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!token) return false;
  if (same(token, SERVICE_ROLE ?? '')) return true;
  const headers: Record<string, string> = { apikey: token, 'Content-Type': 'application/json' };
  if (token.split('.').length === 3) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/is_service_role`, { method: 'POST', headers, body: '{}' }).catch(() => null);
  if (!res?.ok) {
    await res?.body?.cancel();
    return false;
  }
  return (await res.json().catch(() => false)) === true;
}

const ids = (raw: unknown): number[] | null =>
  Array.isArray(raw) && raw.length > 0 && raw.every((n) => Number.isInteger(n) && n > 0) ? raw as number[] : null;

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);
  if (!(await isServiceRole(req))) return json({ error: 'unauthorized' }, 401);
  const body = await req.json().then((b) => b ?? {}).catch(() => ({})) as { action?: unknown; ids?: unknown; merge?: unknown };
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
        // every pair ever proposed, whatever became of it: a rejected pair is never asked again; nor
        // one the model already kept apart (0094: dish_pair_verdicts), so a rerun pays for new pairs only
        const { data: known, error: knownError } = await db.from('dish_merge_proposals').select('source_dish_id, target_dish_id');
        if (knownError) throw new Error(knownError.message);
        const { data: judged, error: judgedError } = await db.from('dish_pair_verdicts').select('dish_a, dish_b');
        if (judgedError) throw new Error(judgedError.message);
        const seen = new Set((known ?? []).flatMap((k) => [`${k.source_dish_id}|${k.target_dish_id}`, `${k.target_dish_id}|${k.source_dish_id}`]));
        const skip = new Set([
          ...(known ?? []).map((k) => pairKey(k.source_dish_id, k.target_dish_id)),
          ...(judged ?? []).map((j) => pairKey(j.dish_a, j.dish_b)),
        ]);
        let asked = 0;
        let fresh = 0;
        const failed: string[] = [];
        // four places at a time: the function's wall clock is limited, and most places ask nothing.
        // Each batch is written as it lands, so a run cut off by the time limit keeps what it paid for.
        const all = (places ?? []) as ScanPlace[];
        for (let i = 0; i < all.length; i += 4) {
          const batch = all.slice(i, i + 4);
          const results = await Promise.all(batch.map((place) => scanPlace(place, { apiKey: ANTHROPIC_KEY, model: MODEL, skip })));
          const proposals: Proposal[] = [];
          const apart: Apart[] = [];
          results.forEach((got, j) => {
            asked += got.asked;
            if (got.failed) failed.push(batch[j].place_name ?? batch[j].restaurant_id);
            proposals.push(...got.proposals.filter((p) => !seen.has(`${p.source_dish_id}|${p.target_dish_id}`)));
            apart.push(...got.apart);
          });
          if (proposals.length) {
            const { error: insertError } = await db.from('dish_merge_proposals')
              .upsert(proposals, { onConflict: 'source_dish_id,target_dish_id', ignoreDuplicates: true });
            if (insertError) throw new Error(insertError.message);
            fresh += proposals.length;
          }
          if (apart.length) {
            const { error: apartError } = await db.from('dish_pair_verdicts')
              .upsert(apart, { onConflict: 'dish_a,dish_b', ignoreDuplicates: true });
            if (apartError) console.error('dish-dedup: verdicts not saved:', apartError.message);
          }
        }
        let results: unknown[] | undefined;
        if (body.merge === 'same_name') {
          const names = (await open()).filter((p) => p.reason === 'same_name').map((p) => p.id);
          results = [];
          if (names.length) {
            const { data, error: mergeError } = await db.rpc('merge_dish_proposals', { p_ids: names });
            if (mergeError) throw new Error(mergeError.message);
            results = data ?? [];
          }
        }
        return json({
          ok: true, places: (places ?? []).length, pairs_asked: asked, new_proposals: fresh,
          model: ANTHROPIC_KEY ? MODEL : null, places_without_ai: failed, ...(results ? { results } : {}), open: await open(),
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
      case 'chains': {
        if (!GOOGLE_KEY) return json({ error: 'GOOGLE_PLACES_API_KEY is not set' }, 422);
        const got = await linkChains(db, null, (placeId) => googleWebsite(GOOGLE_KEY, placeId), { maxFetches: 200, limit: 500 });
        const { data: chains, error } = await db.from('chains')
          .select('id, name, website_host, restaurants!restaurants_chain_id_fkey(count)').order('name');
        if (error) throw new Error(error.message);
        return json({ ok: true, ...got, all_chains: chains ?? [] });
      }
      default:
        return json({ error: 'action: scan, list, merge, reject or chains' }, 422);
    }
  } catch (e) {
    // service-role only (the workflows read this), so the detail is still returned here
    const message = e instanceof Error ? e.message : String(e);
    console.error('dish-dedup:', message);
    return json({ error: message }, 500);
  }
});
