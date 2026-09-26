// supabase/functions/sort-entry/index.ts
//
// Ate — THE SORTER. Adds structure to an entry, asynchronously, after the user's
// words are already safely saved (docs/DESIGN.md rule 9). It finds the place they
// named and the dishes they mentioned, and writes them as `reviews` rows through one
// transactional RPC. It never touches `entries.body`.
//
//   POST /functions/v1/sort-entry
//   body: { entry_id: uuid, force?: boolean, dry_run?: boolean,
//           tag_tokens?: [{ offset, length }] }        (0036 — scalar spans the client marked)
//   → 200 { ok, mode, model, entry_id, sort_status, restaurant_id, place_query, place_offset, items[] }
//     (every item carries `tags: string[]`, possibly [])
//     (`model` is the model ID that produced the plan, null when the stub did)
//     401 unauthorized · 403 not your entry · 404 unknown entry · 422 bad request
//
//   EARLY SORT (round 3, 0039): { preview: true, body, tag_tokens?, restaurant_id? }
//   → 200 { ok, preview: true, cached, mode, model, entry_id: null, restaurant_id, place_query,
//           place_offset, items[] } · 422 bad draft · 429 rate limited (12 per 10 min per author)
//   Runs on a DRAFT and writes nothing to entries or reviews. In model mode the model's raw plan
//   is cached 15 min under (author, sha256(body), tag_tokens, restaurant_id, model); the real
//   sort after Done reuses it on a key match — no second model call — records
//   entries.sort_meta = { cache_hit, model } in the same transaction, then deletes the consumed
//   row. Every preview also purges expired plans (bounded). (./preview.ts)
//
// `force` IS NOT A LICENCE TO DESTROY. A line the user corrected survives any re-sort:
// apply_entry_sort (0024) keeps corrected rows, dish and score intact, and only re-parses
// the lines the sorter still owns. Forcing is therefore safe by construction rather than
// by the client remembering not to.
//
// Every item also carries WHERE it was found — `evidence_offset`, `mention_offset`, plus
// `place_offset` on the entry — as 0-based UNICODE SCALAR offsets into `body`
// (./offsets.ts). The client rebuilds its inline tokens from those instead of searching
// the body, which mis-hits a price ("$14.50") for a score.
//
// TWO MODES, ONE CONTRACT
//   stub  (DEFAULT — CEO decision, no AI spend yet): ./parse.ts, a rule-based parser.
//         No network, no key, fully deterministic, pinned by ~50 fixtures.
//   model (ONLY when ANTHROPIC_API_KEY is present in the function secrets):
//         ./model.ts with a forced tool call, on ATE_SORTER_MODEL (claude-haiku-4-5 by
//         default, or claude-sonnet-5). Inert without the key — the code path is
//         unreachable, not merely unused. A model failure falls back to the stub
//         rather than failing the sort.
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
//
// DIETARY TAGS ARE NEVER INFERRED (0036). Only a span the CLIENT marked as a tag token
// (`tag_tokens`) can become a tag, on the dish line it follows (./tags.ts). Prose says
// nothing: "the salad was gluten free" tags no line. A re-sort without tokens never removes
// a tag already on a line — apply_entry_sort carries them over, like a correction.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { fencedPlaceNames, mentionForPlaceName, parseEntry, placeCandidateSpans } from './parse.ts';
import { validatePlan } from './validate.ts';
import { resolveMode, resolveModel, sortWithModel } from './model.ts';
import { attachTagTokens, parseTagTokens, tagTokenSpans, tagTokenWords, type TagToken } from './tags.ts';
import {
  coerceCachedPlan,
  consumeCachedPlan,
  modelPlanWithCache,
  PREVIEW_RATE_LIMIT,
  PREVIEW_RATE_WINDOW_SECONDS,
  PREVIEW_TTL_SECONDS,
  parsePreviewRequest,
  previewCacheKey,
  sortMeta,
  type PreviewCache,
} from './preview.ts';
import type { PlaceCandidate, SorterMode, SortPlan } from './types.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';

const MODE: SorterMode = resolveMode(ANTHROPIC_KEY, Deno.env.get('ATE_SORTER_MODE'));
const MODEL_ID = resolveModel(Deno.env.get('ATE_SORTER_MODEL'));
/** What the response reports as `model`: the ID only when the model's plan was used. */
const modelFor = (mode: SorterMode) => (mode === 'model' ? MODEL_ID : null);

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
  candidates: PlaceCandidate[],
): Promise<{ restaurant_id: string; name: string; query: string; offset: number } | null> {
  const tried = candidates.slice(0, PLACE_LOOKUPS);
  if (!tried.length) return null;

  const results = await Promise.all(
    tried.map(async (c) => {
      try {
        const { data, error } = await admin.rpc('search_local_restaurants', { p_query: c.phrase, p_limit: 3 });
        if (error) return { c, rows: [] as LocalMatch[] };
        return { c, rows: (data ?? []) as LocalMatch[] };
      } catch {
        return { c, rows: [] as LocalMatch[] };
      }
    }),
  );

  let best: { restaurant_id: string; name: string; query: string; offset: number; score: number } | null = null;
  for (const { c, rows } of results) {
    for (const row of rows) {
      const score = Number(row.match_score ?? 0);
      // `strong` means an exact substring hit or a high trigram score — the same
      // signal the composer's search blend trusts to shadow a Google prediction.
      if (!row.strong && score < PLACE_MATCH_MIN) continue;
      // Prefer a longer candidate phrase on a tie: "Hardware Societe" over "Hardware".
      const weighted = score + c.phrase.length / 1000;
      if (!best || weighted > best.score) {
        best = { restaurant_id: row.id, name: row.name, query: c.phrase, offset: c.offset, score: weighted };
      }
    }
  }
  return best
    ? { restaurant_id: best.restaurant_id, name: best.name, query: best.query, offset: best.offset }
    : null;
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

/** The pinned restaurant's own name — used only to find its mention in the words. */
async function placeNameOf(
  admin: ReturnType<typeof adminClient>,
  restaurantId: string | null,
): Promise<string | null> {
  if (!restaurantId) return null;
  const { data, error } = await admin.from('restaurants').select('name').eq('id', restaurantId).maybeSingle();
  if (error) {
    console.error('sort-entry: place name lookup failed:', error.message);
    return null;
  }
  return (data as { name?: string } | null)?.name ?? null;
}

/** The 0039 table behind the preview cache. Errors throw; modelPlanWithCache treats them as a miss. */
function previewCache(admin: ReturnType<typeof adminClient>): PreviewCache {
  return {
    async get(authorId, key) {
      const { data, error } = await admin
        .from('sort_preview_cache')
        .select('plan')
        .eq('author_id', authorId)
        .eq('cache_key', key)
        .gt('expires_at', new Date().toISOString())
        .maybeSingle();
      if (error) throw new Error(`preview cache read: ${error.message}`);
      return coerceCachedPlan((data as { plan?: unknown } | null)?.plan);
    },
    async put(authorId, key, plan, model) {
      const now = Date.now();
      const { error } = await admin.from('sort_preview_cache').upsert(
        {
          author_id: authorId,
          cache_key: key,
          plan,
          model,
          created_at: new Date(now).toISOString(),
          expires_at: new Date(now + PREVIEW_TTL_SECONDS * 1000).toISOString(),
        },
        // (author_id, cache_key) is the table's PRIMARY KEY — a total unique, a legal arbiter.
        { onConflict: 'author_id,cache_key' },
      );
      if (error) throw new Error(`preview cache write: ${error.message}`);
    },
    async remove(authorId, key) {
      const { error } = await admin.from('sort_preview_cache').delete()
        .eq('author_id', authorId)
        .eq('cache_key', key);
      if (error) throw new Error(`preview cache delete: ${error.message}`);
    },
  };
}

/** Every preview sweeps expired plans (anyone's, bounded — 0039). Housekeeping: never fails a preview. */
async function purgeExpiredPreviews(admin: ReturnType<typeof adminClient>): Promise<void> {
  const { error } = await admin.rpc('sort_preview_purge_expired', { p_max: 200 });
  if (error) console.error('sort-entry: preview purge failed:', error.message);
}

/** The spend guard. Fails CLOSED: a preview is optional, the real sort after Done is not. */
async function admitPreview(admin: ReturnType<typeof adminClient>, authorId: string): Promise<boolean> {
  const { data, error } = await admin.rpc('sort_preview_rate_hit', {
    p_author_id: authorId,
    p_window_seconds: PREVIEW_RATE_WINDOW_SECONDS,
    p_limit: PREVIEW_RATE_LIMIT,
  });
  if (error) {
    console.error('sort-entry: preview rate check failed:', error.message);
    return false;
  }
  return data === true;
}

type Planned =
  | { limited: true }
  | {
    limited: false;
    usedMode: SorterMode;
    cacheHit: boolean;
    /** The preview-cache key this plan was looked up under (model mode only). */
    cacheKey: string | null;
    restaurantId: string | null;
    mention: PlaceCandidate | null;
    validated: SortPlan;
  };

/**
 * Words (+ marked tag tokens + an optional pinned place) → the validated plan. The one pipeline
 * for a sort, a dry run and a preview; only the preview stores into the cache and pays the rate
 * limit, and only the real sort writes.
 */
async function planFor(
  admin: ReturnType<typeof adminClient>,
  opts: {
    authorId: string;
    body: string;
    tagTokens: TagToken[];
    /** A place the USER chose (composer tap / preview's restaurant_id). Never overwritten. */
    pinnedRestaurantId: string | null;
    preview: boolean;
  },
): Promise<Planned> {
  const { body, tagTokens } = opts;

  // ---- 1. the place, from the words only (unless the user pinned one) ----
  const candidates = placeCandidateSpans(body);
  const userPinned = Boolean(opts.pinnedRestaurantId);
  const matched = userPinned ? null : await resolvePlace(admin, candidates);
  const restaurantId = userPinned ? opts.pinnedRestaurantId : matched?.restaurant_id ?? null;

  // ---- 2. the dishes, and WHERE the place is named -----------------------
  const [known, pinnedName] = await Promise.all([
    knownDishesAt(admin, restaurantId),
    userPinned ? placeNameOf(admin, restaurantId) : Promise.resolve(null),
  ]);
  // The client draws its place token off this offset. When the sorter matched the
  // place, it is the phrase that matched; when the USER pinned it (composer tap), it
  // is the candidate phrase that says that restaurant's name — and nothing at all if
  // the words never named it.
  const mention: PlaceCandidate | null = userPinned
    ? mentionForPlaceName(candidates, pinnedName)
    : matched
    ? { phrase: matched.query, offset: matched.offset }
    : null;

  let plan: SortPlan | null = null;
  let usedMode: SorterMode = MODE;
  let cacheHit = false;
  let cacheKey: string | null = null;
  if (MODE === 'model') {
    // Early sort (0039): the preview stores the model's raw plan; the real sort reuses it when the
    // words, the marked tokens, the place and the model are all the same. No second call.
    const key = await previewCacheKey({ body, tagTokens, restaurantId, model: MODEL_ID });
    cacheKey = key;
    const got = await modelPlanWithCache({
      cache: previewCache(admin),
      authorId: opts.authorId,
      key,
      model: MODEL_ID,
      store: opts.preview,
      admit: opts.preview ? () => admitPreview(admin, opts.authorId) : undefined,
      run: () =>
        sortWithModel({
          apiKey: ANTHROPIC_KEY,
          model: MODEL_ID,
          body,
          knownDishes: known,
          placeCandidates: candidates.map((c) => c.phrase),
          tagWords: tagTokenWords(body, tagTokens),
        }),
    });
    if (got.limited) return { limited: true };
    plan = got.plan;
    cacheHit = got.cacheHit;
    if (!plan) usedMode = 'stub'; // degrade, never fail
  } else if (opts.preview && !(await admitPreview(admin, opts.authorId))) {
    return { limited: true };
  }
  // The PLACE'S OWN NAME is not a dish and not the front half of one. Without this the
  // walk in front of a score eats the tail of the venue: "Baby Pizza San Danielle Pizza
  // 3.5" produced a dish called "Pizza San Danielle Pizza" (staging, 2026-09-24).
  //
  // fencedPlaceNames decides what may be fenced. It is handed everything this scope knows
  // — including the candidate phrase and the mention — and keeps only the ROW NAMES: the
  // matched candidate here is "Baby Pizza San Danielle", and fencing that run took the
  // dish down to `Pizza` on the live re-sort.
  const placeNames = fencedPlaceNames({
    pinnedName,
    matchedName: matched?.name ?? null,
    candidatePhrase: matched?.query ?? null,
    mentionPhrase: mention?.phrase ?? null,
  });
  // A marked tag word is never a dish, nor the front half of one ("GF Salad 3.5").
  const excludeSpans = tagTokenSpans(body, tagTokens);
  if (!plan) plan = parseEntry({ body, knownDishes: known, placeNames, excludeSpans });

  // ---- 3. the same gate for every mode, cached or not --------------------
  // validatePlan rebuilds every item WITHOUT tags; the client's marked tokens are the only
  // source of a tag, in every mode. attachTagTokens also cuts tag words out of any dish name
  // (the model does not honour excludeSpans) and places each tag by span, never by name.
  const gated = validatePlan(plan, { body, knownDishes: known });
  const validated: SortPlan = { ...gated, items: attachTagTokens(gated.items, body, tagTokens, known) };

  return { limited: false, usedMode, cacheHit, cacheKey, restaurantId, mention, validated };
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
  const preview = (body as { preview?: unknown }).preview === true;
  const tagTokens = parseTagTokens((body as { tag_tokens?: unknown }).tag_tokens);

  const admin = adminClient();

  // ---- EARLY SORT: a draft, not an entry. Reads only; writes nothing but the cache. ----
  if (preview) {
    const draft = parsePreviewRequest(body);
    if ('error' in draft) return json({ error: draft.error }, 422);
    try {
      await purgeExpiredPreviews(admin);
      const planned = await planFor(admin, {
        authorId: userId,
        body: draft.body,
        tagTokens,
        pinnedRestaurantId: draft.restaurantId,
        preview: true,
      });
      if (planned.limited) {
        return json({ error: 'rate limited', retry_after: PREVIEW_RATE_WINDOW_SECONDS }, 429);
      }
      return json({
        ok: true,
        preview: true,
        cached: planned.cacheHit,
        mode: planned.usedMode,
        model: modelFor(planned.usedMode),
        entry_id: null,
        restaurant_id: planned.restaurantId,
        place_query: planned.mention?.phrase ?? planned.validated.place_query,
        place_offset: planned.mention?.offset ?? planned.validated.place_offset,
        items: planned.validated.items,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error('sort-entry: preview failed:', message);
      return json({ error: 'preview failed' }, 500);
    }
  }

  if (!entryId) return json({ error: 'entry_id required' }, 422);

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

    const userPinned = row.restaurant_source === 'user' && row.restaurant_id ? row.restaurant_id : null;
    const planned = await planFor(admin, {
      authorId: row.author_id,
      body: row.body,
      tagTokens,
      pinnedRestaurantId: userPinned,
      preview: false,
    });
    if (planned.limited) throw new Error('unreachable: the real sort is never rate-limited');
    const { usedMode, cacheHit, cacheKey, restaurantId, mention, validated } = planned;

    if (dryRun) {
      return json({
        ok: true,
        dry_run: true,
        mode: usedMode,
        model: modelFor(usedMode),
        entry_id: row.id,
        restaurant_id: restaurantId,
        place_query: mention?.phrase ?? validated.place_query,
        place_offset: mention?.offset ?? validated.place_offset,
        items: validated.items,
      });
    }

    // ---- 4. one transactional write ---------------------------------------
    const args = {
      p_entry_id: row.id,
      p_restaurant_id: restaurantId,
      p_items: validated.items,
      p_mode: usedMode,
      // the place MENTION: text + where it sits (0-based scalar offset). The RPC
      // verifies the offset against the body before it stores it.
      p_place_query: mention?.phrase ?? null,
      p_place_offset: mention?.offset ?? null,
    };
    // 0039: sort bookkeeping (was the model's plan reused from a preview?), same transaction.
    let { data: written, error: applyError } = await admin.rpc('apply_entry_sort', {
      ...args,
      p_meta: sortMeta(usedMode === 'model', cacheHit, MODEL_ID),
    });
    if (applyError && /p_meta|PGRST202|could not find the function/i.test(`${applyError.code ?? ''} ${applyError.message}`)) {
      // deployed ahead of migration 0039: write without the bookkeeping rather than fail the sort
      ({ data: written, error: applyError } = await admin.rpc('apply_entry_sort', args));
    }

    if (applyError) {
      console.error('sort-entry: apply_entry_sort failed:', applyError.message);
      await admin.rpc('mark_entry_sort_failed', { p_entry_id: row.id, p_error: applyError.message });
      return json({ error: 'sort failed', detail: applyError.message }, 500);
    }

    const result = (Array.isArray(written) ? written[0] : written) as { sort_status?: string; restaurant_id?: string } | null;

    // The write committed: a plan reused from a preview is consumed — its row holds draft text.
    await consumeCachedPlan({ cache: previewCache(admin), authorId: row.author_id, key: cacheKey, cacheHit });

    return json({
      ok: true,
      mode: usedMode,
      model: modelFor(usedMode),
      entry_id: row.id,
      sort_status: result?.sort_status ?? 'sorted',
      restaurant_id: result?.restaurant_id ?? restaurantId,
      place_query: mention?.phrase ?? validated.place_query,
      place_offset: mention?.offset ?? validated.place_offset,
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
