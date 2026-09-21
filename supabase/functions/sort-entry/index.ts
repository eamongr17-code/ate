// supabase/functions/sort-entry/index.ts
//
// Ate — THE SORTER. Adds structure to an entry, asynchronously, after the user's
// words are already safely saved (docs/DESIGN.md rule 9). It finds the place they
// named and the dishes they mentioned, and writes them as `reviews` rows through one
// transactional RPC. It never touches `entries.body`.
//
//   POST /functions/v1/sort-entry
//   body: { entry_id: uuid, force?: boolean, dry_run?: boolean }
//   → 200 { ok, mode, entry_id, sort_status, restaurant_id, place_query, items[] }
//     401 unauthorized · 403 not your entry · 404 unknown entry · 422 bad request
//
// TWO MODES, ONE CONTRACT
//   stub  (DEFAULT — CEO decision, no AI spend yet): ./parse.ts, a rule-based parser.
//         No network, no key, fully deterministic, pinned by ~40 fixtures.
//   model (ONLY when ANTHROPIC_API_KEY is present in the function secrets):
//         ./model.ts, claude-haiku-4-5 with a forced tool call. Inert without the
//         key — the code path is unreachable, not merely unused. A model failure
//         falls back to the stub rather than failing the sort.
//   ATE_SORTER_MODE=stub forces stub even with a key (eval/incident switch).
//
// BOTH modes go through ./validate.ts and then through apply_entry_sort's SQL checks
// (migration 0021), which drop any score whose evidence is not literally in the words
// and any note that is not a substring of them. Three gates, same rule, no mode can
// bypass it.
//
// THE PLACE IS NEVER INVENTED (rule 8). The parser only POINTS at phrases that look
// like a name; those are matched against restaurants WE ALREADY HOLD via the
// search_local_restaurants RPC (migration 0017). No Google call, no row creation, no
// location input. If the user named somewhere we don't have, the entry stays
// placeless and the app offers the place sheet — and the plan is parked in
// entries.sort_plan so attaching the place later still prints the receipt.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { parseEntry, placeCandidates } from './parse.ts';
import { validatePlan } from './validate.ts';
import { resolveMode, sortWithModel } from './model.ts';
import type { SorterMode, SortPlan } from './types.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';

const MODE: SorterMode = resolveMode(ANTHROPIC_KEY, Deno.env.get('ATE_SORTER_MODE'));

/** A local match must clear this to attach a place. Mirrors the search blend's bar. */
const PLACE_MATCH_MIN = 0.55;
/** How many candidate phrases we are willing to look up per entry. */
const PLACE_LOOKUPS = 4;

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

/**
 * AUTH GATE (same shape as places-search): the anon/publishable key is a valid
 * project JWT and is extractable from the app bundle, so platform verify_jwt is not
 * enough — we require a token that resolves to a real USER. Never fails open.
 */
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

type EntryRow = {
  id: string;
  author_id: string;
  body: string;
  restaurant_id: string | null;
  restaurant_source: string | null;
  sort_status: string;
};

type LocalMatch = { id: string; name: string; match_score: number; strong: boolean };

/**
 * Resolve the place from the WORDS ALONE, against rows we already hold.
 * Returns null when nothing clears the bar — a placeless entry is a valid outcome.
 */
async function resolvePlace(
  admin: ReturnType<typeof adminClient>,
  candidates: string[],
): Promise<{ restaurant_id: string; name: string; query: string } | null> {
  const tried = candidates.slice(0, PLACE_LOOKUPS);
  if (!tried.length) return null;

  const results = await Promise.all(
    tried.map(async (q) => {
      try {
        const { data, error } = await admin.rpc('search_local_restaurants', { p_query: q, p_limit: 3 });
        if (error) return { q, rows: [] as LocalMatch[] };
        return { q, rows: (data ?? []) as LocalMatch[] };
      } catch {
        return { q, rows: [] as LocalMatch[] };
      }
    }),
  );

  let best: { restaurant_id: string; name: string; query: string; score: number } | null = null;
  for (const { q, rows } of results) {
    for (const row of rows) {
      const score = Number(row.match_score ?? 0);
      // `strong` means an exact substring hit or a high trigram score — the same
      // signal the composer's search blend trusts to shadow a Google prediction.
      if (!row.strong && score < PLACE_MATCH_MIN) continue;
      // Prefer a longer candidate phrase on a tie: "Hardware Societe" over "Hardware".
      const weighted = score + q.length / 1000;
      if (!best || weighted > best.score) {
        best = { restaurant_id: row.id, name: row.name, query: q, score: weighted };
      }
    }
  }
  return best ? { restaurant_id: best.restaurant_id, name: best.name, query: best.query } : null;
}

async function knownDishesAt(
  admin: ReturnType<typeof adminClient>,
  restaurantId: string | null,
): Promise<string[]> {
  if (!restaurantId) return [];
  const { data, error } = await admin
    .from('dishes')
    .select('name')
    .eq('restaurant_id', restaurantId)
    .is('merged_into_dish_id', null)
    .limit(300);
  if (error) {
    console.error('sort-entry: dish list failed:', error.message);
    return [];
  }
  return (data ?? []).map((d: { name: string }) => d.name);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const [userId, body] = await Promise.all([
    authedUserId(req),
    req.json().then((b) => b ?? {}).catch(() => ({})),
  ]);
  if (!userId) return json({ error: 'unauthorized' }, 401);

  const entryId = String((body as { entry_id?: unknown }).entry_id ?? '');
  const force = Boolean((body as { force?: unknown }).force);
  const dryRun = Boolean((body as { dry_run?: unknown }).dry_run);
  if (!entryId) return json({ error: 'entry_id required' }, 422);

  const admin = adminClient();

  try {
    const { data: entry, error: loadError } = await admin
      .from('entries')
      .select('id, author_id, body, restaurant_id, restaurant_source, sort_status')
      .eq('id', entryId)
      .maybeSingle();

    if (loadError) throw loadError;
    if (!entry) return json({ error: 'entry not found' }, 404);

    const row = entry as EntryRow;
    // Only the author may trigger a sort of their own entry. (The service role can
    // call apply_entry_sort directly for backfills; this endpoint is the user's.)
    if (row.author_id !== userId) return json({ error: 'forbidden' }, 403);

    if (row.sort_status === 'sorted' && !force) {
      return json({ ok: true, skipped: 'already sorted', mode: MODE, entry_id: row.id, sort_status: row.sort_status });
    }

    // ---- 1. the place, from the words only ---------------------------------
    const candidates = placeCandidates(row.body);
    const userPinned = row.restaurant_source === 'user' && row.restaurant_id;
    const matched = userPinned ? null : await resolvePlace(admin, candidates);
    const restaurantId = userPinned ? row.restaurant_id : matched?.restaurant_id ?? null;

    // ---- 2. the dishes ----------------------------------------------------
    const known = await knownDishesAt(admin, restaurantId);

    let plan: SortPlan | null = null;
    let usedMode: SorterMode = MODE;
    if (MODE === 'model') {
      plan = await sortWithModel({
        apiKey: ANTHROPIC_KEY,
        body: row.body,
        knownDishes: known,
        placeCandidates: candidates,
      });
      if (!plan) usedMode = 'stub'; // degrade, never fail
    }
    if (!plan) plan = parseEntry({ body: row.body, knownDishes: known });

    // ---- 3. the same gate for every mode ----------------------------------
    const validated = validatePlan(plan, { body: row.body, knownDishes: known });

    if (dryRun) {
      return json({
        ok: true,
        dry_run: true,
        mode: usedMode,
        entry_id: row.id,
        restaurant_id: restaurantId,
        place_query: matched?.query ?? validated.place_query,
        items: validated.items,
      });
    }

    // ---- 4. one transactional write ---------------------------------------
    const { data: written, error: applyError } = await admin.rpc('apply_entry_sort', {
      p_entry_id: row.id,
      p_restaurant_id: restaurantId,
      p_items: validated.items,
      p_mode: usedMode,
    });

    if (applyError) {
      console.error('sort-entry: apply_entry_sort failed:', applyError.message);
      await admin.rpc('mark_entry_sort_failed', { p_entry_id: row.id, p_error: applyError.message });
      return json({ error: 'sort failed', detail: applyError.message }, 500);
    }

    const result = (Array.isArray(written) ? written[0] : written) as { sort_status?: string; restaurant_id?: string } | null;

    return json({
      ok: true,
      mode: usedMode,
      entry_id: row.id,
      sort_status: result?.sort_status ?? 'sorted',
      restaurant_id: result?.restaurant_id ?? restaurantId,
      place_query: matched?.query ?? validated.place_query,
      items: validated.items,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error('sort-entry: unhandled:', message);
    try {
      await admin.rpc('mark_entry_sort_failed', { p_entry_id: entryId, p_error: message });
    } catch { /* the entry keeps its words either way */ }
    return json({ error: message }, 500);
  }
});
