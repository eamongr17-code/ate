// supabase/functions/sort-entry/index.ts
//
// Ate — THE SORTER. Adds structure to an entry, asynchronously, after the user's
// words are already safely saved (docs/DESIGN.md rule 9). It finds the place they
// named and the dishes they mentioned, and writes them as `reviews` rows through one
// transactional RPC. It never touches `entries.body`.
//
//   POST /functions/v1/sort-entry
//   body: { entry_id: uuid, force?: boolean, dry_run?: boolean,
//           tag_tokens?: [{ offset, length }],         (0036 — scalar spans the client marked)
//           six_tokens?: [{ offset, length }] }        (0041 — the secret 6, client-marked only)
//   → 200 { ok, mode, model, entry_id, sort_status, restaurant_id, place_query, place_offset, items[],
//           entry_card }                               (0056 — the sorted entry_cards row, or null)
//     (every item carries `tags: string[]`, possibly [])
//     (`model` is the model ID that produced the plan, null when the stub did)
//     401 unauthorized · 403 not your entry · 404 unknown entry · 422 bad request
//
//   EARLY SORT (round 3, 0039): { preview: true, body, tag_tokens?, six_tokens?, restaurant_id? }
//   → 200 { ok, preview: true, cached, mode, model, entry_id: null, restaurant_id, place_query,
//           place_offset, items[] } · 422 bad draft · 429 rate limited (12 per 10 min per author)
//   Runs on a DRAFT and writes nothing to entries or reviews. In model mode the model's raw plan
//   is cached 15 min under (author, sha256(body), tag_tokens, six_tokens, restaurant_id, model); the real
//   sort after Done reuses it on a key match — no second model call — records
//   entries.sort_meta = { cache_hit, model } in the same transaction, then deletes the consumed
//   row. Every preview also purges expired plans (bounded). (./preview.ts)
//   0056: a preview CLAIMS its key before calling the model; a real sort that finds the claim still
//   pending WAITS (≤ 3 s) for that plan instead of making a second, simultaneous model call.
//
//   HEALTH (0056): { health: true } → 200 { ok: true, health: true } before auth, reads nothing and
//   calls nothing. It exists to boot the isolate: the keep-alive pings it, and the app may fire it
//   when the composer opens so the sort after Done does not pay a cold start.
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
//         default, claude-haiku-5-5 or claude-sonnet-5). Inert without the key — the code path is
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
//
// THE SECRET 6 IS NEVER INFERRED EITHER (0041). Scores are 0.5-5.0; a 6 exists only on a span the
// client marked (`six_tokens`, ./six.ts). A typed "6" is not a score: the parser's numbers stop at 5
// and validate.ts drops any 6 whose evidence does not cover a marked span, in every mode.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { fencedPlaceNames, mentionForPlaceName, parseEntry, placeCandidateSpans } from './parse.ts';
import { validatePlan } from './validate.ts';
import { resolveMode, resolveModel, sortWithModel } from './model.ts';
import { attachTagTokens, parseTagTokens, tagTokenSpans, tagTokenWords, type TagToken } from './tags.ts';
import {
  attachSixTokens,
  carryPriorSixes,
  parseSixTokens,
  sixMarks,
  sixSpans,
  type PriorSix,
  type SixToken,
} from './six.ts';
import {
  coerceCachedPlan,
  consumeCachedPlan,
  PENDING_STALE_SECONDS,
  modelPlanWithCache,
  PREVIEW_RATE_LIMIT,
  PREVIEW_RATE_WINDOW_SECONDS,
  PREVIEW_TTL_SECONDS,
  parsePreviewRequest,
  previewCacheKey,
  sortMeta,
  type CacheState,
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
function bearer(req: Request): string {
  return (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
}

async function authedUserId(req: Request): Promise<string | null> {
  const token = bearer(req);
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
  sort_plan: unknown;
};

type LocalMatch = { id: string; name: string; match_score: number; strong: boolean };

/** What the sort reads about an entry before the model. */
type EntryContext = {
  row: EntryRow;
  /** Pre-read for a USER-pinned place (0056); null = not pinned or not pre-read → read it in planFor. */
  pinned: { placeName: string | null; knownDishes: string[] } | null;
  /** The sorter-owned lines holding a 6; null = not pre-read → priorSixes() reads them. */
  sixLines: PriorSix[] | null;
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const strOrNull = (v: unknown) => (typeof v === 'string' ? v : null);
const intOrNull = (v: unknown) => (typeof v === 'number' ? v : null);

/**
 * The entry, its pinned place's name + menu and its six lines in ONE trip (0056's
 * sort_entry_context). null = no such entry. If the RPC is not there (function deployed ahead of the
 * migration) it falls back to the single-table entry read and lets planFor/priorSixes read the rest.
 */
async function loadEntryContext(admin: ReturnType<typeof adminClient>, entryId: string): Promise<EntryContext | null> {
  const { data, error } = await admin.rpc('sort_entry_context', { p_entry_id: entryId });
  if (!error) {
    const ctx = data as { entry?: EntryRow; place_name?: unknown; known_dishes?: unknown; prior_sixes?: unknown } | null;
    if (!ctx?.entry) return null;
    const sixLines = Array.isArray(ctx.prior_sixes)
      ? (ctx.prior_sixes as Array<Record<string, unknown>>).map((r) => ({
        dish_name: strOrNull(r.dish_name),
        mention_text: strOrNull(r.mention_text),
        mention_offset: intOrNull(r.mention_offset),
        score_evidence: strOrNull(r.score_evidence),
        evidence_offset: intOrNull(r.evidence_offset),
      }))
      : null;
    const pinned = Array.isArray(ctx.known_dishes)
      ? { placeName: strOrNull(ctx.place_name), knownDishes: (ctx.known_dishes as unknown[]).filter((n): n is string => typeof n === 'string') }
      : null;
    return { row: ctx.entry, pinned, sixLines };
  }
  console.error('sort-entry: sort_entry_context unavailable, reading serially:', error.message);
  const { data: entry, error: loadError } = await admin
    .from('entries')
    .select('id, author_id, body, restaurant_id, restaurant_source, sort_status, sort_plan')
    .eq('id', entryId)
    .maybeSingle();
  if (loadError) throw loadError;
  return entry ? { row: entry as EntryRow, pinned: null, sixLines: null } : null;
}

/**
 * The sorted entry as the app renders it: `get_entry_card` (0048) AS THE USER, so is_mine and
 * items[].saved are theirs. Returned in the response so the client need not re-read (0056).
 * Never fails the sort: any problem is a null and the client re-reads as before.
 */
async function entryCardFor(token: string, entryId: string): Promise<unknown | null> {
  try {
    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data, error } = await asUser.rpc('get_entry_card', { p_entry_id: entryId });
    if (error) {
      console.error('sort-entry: entry card read failed:', error.message);
      return null;
    }
    return (Array.isArray(data) ? data[0] : data) ?? null;
  } catch (e) {
    console.error('sort-entry: entry card read failed:', e instanceof Error ? e.message : String(e));
    return null;
  }
}

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

/** The sorter-owned lines that hold a 6 now — or, for a placeless entry, its parked plan's. */
async function priorSixes(
  admin: ReturnType<typeof adminClient>,
  row: EntryRow,
  preloaded: PriorSix[] | null = null,
): Promise<PriorSix[]> {
  if (preloaded) return parkedSixesOr(row, preloaded);
  const { data, error } = await admin
    .from('reviews')
    .select('score_evidence, evidence_offset, mention_text, mention_offset, dishes(name)')
    .eq('entry_id', row.id)
    .eq('score', 6)
    .is('corrected_at', null);
  if (error) {
    console.error('sort-entry: prior sixes lookup failed:', error.message);
    return [];
  }
  const lines: PriorSix[] = ((data ?? []) as Array<Record<string, unknown>>).map((r) => ({
    dish_name: (r.dishes as { name?: string } | null)?.name ?? null,
    mention_text: typeof r.mention_text === 'string' ? r.mention_text : null,
    mention_offset: typeof r.mention_offset === 'number' ? r.mention_offset : null,
    score_evidence: typeof r.score_evidence === 'string' ? r.score_evidence : null,
    evidence_offset: typeof r.evidence_offset === 'number' ? r.evidence_offset : null,
  }));
  return parkedSixesOr(row, lines);
}

/** The lines' sixes — or, for a placeless entry with none, its parked plan's. */
function parkedSixesOr(row: EntryRow, lines: PriorSix[]): PriorSix[] {
  if (lines.length || row.restaurant_id || !Array.isArray(row.sort_plan)) return lines;
  return (row.sort_plan as Array<Record<string, unknown>>)
    .filter((i) => Number(i?.score) === 6)
    .map((i) => ({
      dish_name: typeof i.dish_name === 'string' ? i.dish_name : null,
      mention_text: typeof i.mention_text === 'string' ? i.mention_text : null,
      mention_offset: typeof i.mention_offset === 'number' ? i.mention_offset : null,
      score_evidence: typeof i.score_evidence === 'string' ? i.score_evidence : null,
      evidence_offset: typeof i.evidence_offset === 'number' ? i.evidence_offset : null,
    }));
}

/**
 * The 0039 table behind the preview cache, with 0056's pending claims (sort_preview_claim). Errors
 * throw; modelPlanWithCache treats them as a miss. Before 0056 is applied the claim RPC is missing:
 * peek/claim then fall back to the plain 0039 read (hit or none), i.e. the old behaviour.
 */
function previewCache(admin: ReturnType<typeof adminClient>): PreviewCache {
  async function legacyRead(authorId: string, key: string): Promise<CacheState> {
    const { data, error } = await admin
      .from('sort_preview_cache')
      .select('plan')
      .eq('author_id', authorId)
      .eq('cache_key', key)
      .gt('expires_at', new Date().toISOString())
      .maybeSingle();
    if (error) throw new Error(`preview cache read: ${error.message}`);
    const plan = coerceCachedPlan((data as { plan?: unknown } | null)?.plan);
    return plan ? { state: 'hit', plan } : { state: 'none' };
  }
  async function viaRpc(authorId: string, key: string, model: string | null, claim: boolean): Promise<CacheState | null> {
    const { data, error } = await admin.rpc('sort_preview_claim', {
      p_author_id: authorId,
      p_cache_key: key,
      p_model: model,
      p_claim: claim,
      p_pending_seconds: PENDING_STALE_SECONDS,
    });
    const got = data as { state?: unknown; plan?: unknown } | null;
    if (error || !got || typeof got.state !== 'string') return null;
    if (got.state === 'hit') {
      const plan = coerceCachedPlan(got.plan);
      return plan ? { state: 'hit', plan } : { state: 'none' };
    }
    if (got.state === 'pending' || got.state === 'claimed') return { state: got.state };
    return { state: 'none' };
  }
  return {
    async peek(authorId, key) {
      return (await viaRpc(authorId, key, null, false)) ?? legacyRead(authorId, key);
    },
    async claim(authorId, key, model) {
      return (await viaRpc(authorId, key, model, true)) ?? legacyRead(authorId, key);
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
    async release(authorId, key) {
      // only a PENDING row (plan is null): never a plan someone stored
      const { error } = await admin.from('sort_preview_cache').delete()
        .eq('author_id', authorId)
        .eq('cache_key', key)
        .is('plan', null);
      if (error) throw new Error(`preview cache release: ${error.message}`);
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
    waitedMs: number;
    modelMs: number | null;
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
    /** The client-marked sixes (0041). The only way a 6 is ever written. */
    sixTokens: SixToken[];
    /** A place the USER chose (composer tap / preview's restaurant_id). Never overwritten. */
    pinnedRestaurantId: string | null;
    /** The pinned place's name + menu, already read with the entry (0056). */
    pinnedPreloaded?: { placeName: string | null; knownDishes: string[] } | null;
    preview: boolean;
  },
): Promise<Planned> {
  const { body, tagTokens, sixTokens } = opts;
  const sixes = sixSpans(body, sixTokens);

  // ---- 1. the place, from the words only (unless the user pinned one) ----
  const candidates = placeCandidateSpans(body);
  const userPinned = Boolean(opts.pinnedRestaurantId);
  const matched = userPinned ? null : await resolvePlace(admin, candidates);
  const restaurantId = userPinned ? opts.pinnedRestaurantId : matched?.restaurant_id ?? null;

  // ---- 2. the dishes, and WHERE the place is named -----------------------
  const pre = userPinned ? opts.pinnedPreloaded ?? null : null;
  const [known, pinnedName]: [string[], string | null] = pre
    ? [pre.knownDishes, pre.placeName]
    : await Promise.all([
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
  let waitedMs = 0;
  let modelMs: number | null = null;
  let cacheKey: string | null = null;
  if (MODE === 'model') {
    // Early sort (0039): the preview stores the model's raw plan; the real sort reuses it when the
    // words, the marked tokens, the place and the model are all the same. No second call.
    const key = await previewCacheKey({ body, tagTokens, sixTokens, restaurantId, model: MODEL_ID });
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
          sixMarks: sixMarks(body, sixes),
        }),
    });
    if (got.limited) return { limited: true };
    plan = got.plan;
    cacheHit = got.cacheHit;
    waitedMs = got.waitedMs;
    modelMs = got.modelMs;
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
  if (!plan) {
    plan = parseEntry({
      body, knownDishes: known, placeNames, excludeSpans, sixSpans: sixes.map((s): [number, number] => [s.start, s.end]),
    });
  }

  // ---- 3. the same gate for every mode, cached or not --------------------
  // validatePlan rebuilds every item WITHOUT tags; the client's marked tokens are the only
  // source of a tag, in every mode. attachTagTokens also cuts tag words out of any dish name
  // (the model does not honour excludeSpans) and places each tag by span, never by name.
  // A 6 survives only on a marked span (validatePlan), and a marked six nobody claimed goes to the
  // dish named just before it (attachSixTokens) — after the tag pass, which may re-cut mentions.
  const gated = validatePlan(plan, { body, knownDishes: known, sixSpans: sixes });
  const tagged = attachTagTokens(gated.items, body, tagTokens, known);
  const validated: SortPlan = { ...gated, items: attachSixTokens(tagged, sixes) };

  return { limited: false, usedMode, cacheHit, waitedMs, modelMs, cacheKey, restaurantId, mention, validated };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);
  const startedAt = Date.now();

  const body = await req.json().then((b) => b ?? {}).catch(() => ({}));
  // HEALTH (0056): boots the isolate, nothing else — no auth, no read, no model, no write.
  if ((body as { health?: unknown }).health === true) return json({ ok: true, health: true });

  const entryId = String((body as { entry_id?: unknown }).entry_id ?? '');
  const force = Boolean((body as { force?: unknown }).force);
  const dryRun = Boolean((body as { dry_run?: unknown }).dry_run);
  const preview = (body as { preview?: unknown }).preview === true;
  const tagTokens = parseTagTokens((body as { tag_tokens?: unknown }).tag_tokens);
  const sixTokens = parseSixTokens((body as { six_tokens?: unknown }).six_tokens);

  const admin = adminClient();

  // The entry read rides alongside the auth check (one trip, not two). Nothing it returns is used
  // or answered until the caller is known to be its author.
  const contextLoad = !preview && UUID_RE.test(entryId) ? loadEntryContext(admin, entryId) : null;
  contextLoad?.catch(() => {}); // awaited below; never an unhandled rejection on a 401
  const userId = await authedUserId(req);
  if (!userId) return json({ error: 'unauthorized' }, 401);

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
        sixTokens,
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
    const ctx = contextLoad ? await contextLoad : null;
    if (!ctx) return json({ error: 'entry not found' }, 404);

    const row = ctx.row;
    // Only the author may trigger a sort of their own entry. (The service role can
    // call apply_entry_sort directly for backfills; this endpoint is the user's.)
    if (row.author_id !== userId) return json({ error: 'forbidden' }, 403);

    if (row.sort_status === 'sorted' && !force) {
      return json({
        ok: true, skipped: 'already sorted', mode: MODE, entry_id: row.id, sort_status: row.sort_status,
        entry_card: await entryCardFor(bearer(req), row.id),
      });
    }

    const userPinned = row.restaurant_source === 'user' && row.restaurant_id ? row.restaurant_id : null;
    const [planned, sixLines] = await Promise.all([
      planFor(admin, {
        authorId: row.author_id,
        body: row.body,
        tagTokens,
        sixTokens,
        pinnedRestaurantId: userPinned,
        pinnedPreloaded: ctx.pinned,
        preview: false,
      }),
      priorSixes(admin, row, ctx.sixLines),
    ]);
    if (planned.limited) throw new Error('unreachable: the real sort is never rate-limited');
    const { usedMode, cacheHit, cacheKey, restaurantId, mention } = planned;
    // 0044: a re-sort without six_tokens keeps a 6 the user marked before, on the line that carried it
    // (./six.ts carryPriorSixes; apply_entry_sort enforces the same rule of record).
    const validated: SortPlan = {
      ...planned.validated,
      items: carryPriorSixes(planned.validated.items, row.body, sixLines),
    };

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
    // 0056: + how long it waited on a preview, the model call and the whole plan took (ms).
    const meta = sortMeta(usedMode === 'model', cacheHit, MODEL_ID, {
      waitedMs: planned.waitedMs,
      modelMs: planned.modelMs,
      planMs: Date.now() - startedAt,
    });
    let { data: written, error: applyError } = await admin.rpc('apply_entry_sort', { ...args, p_meta: meta });
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

    // The write committed: a plan reused from a preview is consumed — its row holds draft text —
    // and the sorted card is read back for the client, both at once.
    const [, card] = await Promise.all([
      consumeCachedPlan({ cache: previewCache(admin), authorId: row.author_id, key: cacheKey, cacheHit }),
      entryCardFor(bearer(req), row.id),
    ]);

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
      // 0056, ADDITIVE: the entry_cards row as the app reads it (get_entry_card, as this user), after
      // the write — render it instead of re-reading. null when that read failed: re-read as before.
      entry_card: card,
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
