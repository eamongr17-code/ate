-- 0039_sort_preview_cache.sql
-- Ate backend — round 3: EARLY SORT. While the user is still writing, the app may ask `sort-entry`
-- for a speculative plan (`"preview": true`). The model runs on the draft; the plan comes back for
-- display; NOTHING is written to entries or reviews. The model's RAW plan is cached here for 15
-- minutes so that, when the user taps Done and the real sort runs on the same words, tokens and
-- place, the function reuses it and makes no second model call.
--
--   sort_preview_cache   (author_id, cache_key) PK — a TOTAL unique, so the function's upsert has a
--                        legal ON CONFLICT arbiter (landmine 1). cache_key = sha256 over (sha256(body),
--                        canonical tag_tokens, restaurant_id, model id), computed in the function
--                        (supabase/functions/sort-entry/preview.ts). `plan` is the model's output
--                        BEFORE validation: the real sort re-runs every gate (validate.ts, tags.ts,
--                        apply_entry_sort's SQL checks) on it, so a cached plan can loosen nothing.
--                        THE PLAN HOLDS VERBATIM DRAFT TEXT (notes and score evidence are slices of
--                        the words), so it does not linger:
--                          * `expires_at` = created + 15 min, and a read ignores expired rows;
--                          * every preview call runs `sort_preview_purge_expired()` — a BOUNDED delete
--                            (200 oldest expired rows, on an `expires_at` index) of EVERYONE'S expired
--                            plans, so an author who never previews again is still purged. (No pg_cron:
--                            it is not enabled on these projects, and enabling it is a platform change.)
--                          * the real sort DELETES the row it consumed, once its write commits;
--                          * deleting an entry (delete_entry, a raw DELETE, or the account cascade)
--                            purges that author's plans — trigger `entries_purge_preview_cache`;
--                          * delete_account's verification now includes both tables (0035 idiom).
--   sort_preview_rate    per-author fixed-window counter (0013's places_rate_limit pattern):
--                        `sort_preview_rate_hit(author, window_s, limit)` records a preview that is
--                        about to run a sort and says whether it is within the limit (12 / 10 min).
--   entries.sort_meta    jsonb bookkeeping written by the sort in the SAME transaction:
--                        `{"cache_hit": bool, "model": text|null}`. A sibling of `sort_plan`, not a
--                        key inside it: `sort_plan` is a jsonb ARRAY that correct_entry_place and
--                        apply_entry_sort iterate as the parked plan — wrapping it in an object would
--                        break the parked-plan path for every placeless entry.
--   apply_entry_sort     + `p_meta jsonb default null` → stored in `sort_meta`. A new parameter, so
--                        DROP-then-CREATE (landmine 7) and the service_role grant restated. The body is
--                        0036's verbatim except the final UPDATE. A function deploy that omits p_meta
--                        still binds (the default), so migration-before-function is safe; the new
--                        function also retries without p_meta if it lands before this migration.
--
-- ACCESS: both tables are RLS-enabled with NO policy and every client role revoked — only the
-- function's service role reads or writes them (Supabase's default table grants are revoked
-- explicitly, not merely out-policied). Rows cascade away with the author (delete_account).
--
-- WIRE IMPACT: ADDITIVE for clients — `sort-entry` gains the `preview` request mode (see
-- integration-design.md); `correct_entry_place`'s returned entry row gains a `sort_meta` key.
-- INTERNAL: apply_entry_sort's signature (service_role only; no client calls it).

set search_path = public, extensions;

-- ===========================================================================
-- 1. The cache.
-- ===========================================================================
create table if not exists public.sort_preview_cache (
  author_id  uuid        not null references auth.users(id) on delete cascade,
  cache_key  text        not null check (cache_key ~ '^[0-9a-f]{64}$'),
  plan       jsonb       not null,
  model      text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '15 minutes',
  primary key (author_id, cache_key)
);

comment on table public.sort_preview_cache is
  'Round 3 early sort: the model''s RAW plan for a draft, keyed by (author, sha256(body)+tag_tokens+restaurant_id+model), valid 15 minutes, so the real sort after Done reuses it instead of a second model call. Server-internal: RLS on, no policy, service_role only.';

alter table public.sort_preview_cache enable row level security;
revoke all on public.sort_preview_cache from public, anon, authenticated;
grant select, insert, update, delete on public.sort_preview_cache to service_role;

create index if not exists sort_preview_cache_expires_idx on public.sort_preview_cache (expires_at);

-- Bounded, so a preview never pays for a backlog: at most p_max rows per call, oldest first.
create or replace function public.sort_preview_purge_expired(p_max integer default 200)
returns integer
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_n integer;
begin
  delete from public.sort_preview_cache c
  using (
    select x.author_id, x.cache_key
    from public.sort_preview_cache x
    where x.expires_at < now()
    order by x.expires_at
    limit least(greatest(coalesce(p_max, 200), 1), 1000)
  ) old
  where c.author_id = old.author_id and c.cache_key = old.cache_key;
  get diagnostics v_n = row_count;
  return v_n;
end; $$;

comment on function public.sort_preview_purge_expired(integer) is
  'Round 3: deletes up to p_max expired sort_preview_cache rows (anyone''s), oldest first. sort-entry calls it on every preview. service_role only.';

revoke all on function public.sort_preview_purge_expired(integer) from public, anon, authenticated;
grant execute on function public.sort_preview_purge_expired(integer) to service_role;

-- ===========================================================================
-- 2. The preview rate limit (0013's shape: atomic upsert on a TOTAL PK, self-pruning).
-- ===========================================================================
create table if not exists public.sort_preview_rate (
  author_id    uuid        not null references auth.users(id) on delete cascade,
  window_start timestamptz not null,
  hits         integer     not null default 0,
  primary key (author_id, window_start)
);

comment on table public.sort_preview_rate is
  'Round 3: per-author fixed-window counter for sort-entry previews (spend guard). Server-internal: RLS on, no policy, service_role only.';

alter table public.sort_preview_rate enable row level security;
revoke all on public.sort_preview_rate from public, anon, authenticated;
grant select, insert, update, delete on public.sort_preview_rate to service_role;

create or replace function public.sort_preview_rate_hit(
  p_author_id      uuid,
  p_window_seconds integer,
  p_limit          integer
)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_window timestamptz;
  v_hits   integer;
begin
  v_window := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);

  -- atomic: concurrent previews serialise on the (author_id, window_start) PK
  insert into public.sort_preview_rate (author_id, window_start, hits)
    values (p_author_id, v_window, 1)
    on conflict (author_id, window_start)
    do update set hits = public.sort_preview_rate.hits + 1
    returning hits into v_hits;

  delete from public.sort_preview_rate
   where author_id = p_author_id
     and window_start < v_window;

  return v_hits <= p_limit;
end; $$;

comment on function public.sort_preview_rate_hit(uuid, integer, integer) is
  'Round 3: records one sort-entry preview for the author in the current fixed window; true when within p_limit (else the function answers 429). Also prunes the author''s old windows. service_role only.';

revoke all on function public.sort_preview_rate_hit(uuid, integer, integer) from public, anon, authenticated;
grant execute on function public.sort_preview_rate_hit(uuid, integer, integer) to service_role;

-- ===========================================================================
-- 3. entries.sort_meta — sort bookkeeping beside sort_plan. Never client-writable: entries INSERT
--    and UPDATE are column-granted (0018) and this column is in neither list.
-- ===========================================================================
alter table public.entries add column if not exists sort_meta jsonb;

comment on column public.entries.sort_meta is
  'Round 3: the last sort''s bookkeeping, written by apply_entry_sort in the same transaction — {"cache_hit": bool, "model": text|null}. cache_hit = the plan came from sort_preview_cache (no second model call). Internal; not on entry_cards.';

-- ===========================================================================
-- 4. apply_entry_sort + p_meta. DROP-then-CREATE (a new parameter; landmine 7). 0036's body verbatim
--    but for the parameter and the final UPDATE's `sort_meta` line.
-- ===========================================================================
drop function if exists public.apply_entry_sort(uuid, uuid, jsonb, text, text, int);

create function public.apply_entry_sort(
  p_entry_id      uuid,
  p_restaurant_id uuid    default null,
  p_items         jsonb   default '[]'::jsonb,
  p_mode          text    default 'stub',
  p_place_query   text    default null,
  p_place_offset  int     default null,
  p_meta          jsonb   default null
)
returns public.entries
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_entry       public.entries;
  v_rid         uuid;
  v_src         text;
  v_item        jsonb;
  v_name        text;
  v_score       numeric(2,1);
  v_evidence    text;
  v_note        text;
  v_mention     text;
  v_e_off       int;
  v_m_off       int;
  v_dish        uuid;
  v_pos         smallint := 0;
  v_validated   jsonb := '[]'::jsonb;
  v_corrections int;
  v_claimed     uuid[] := '{}';
  v_keep        public.reviews;
  v_matched     boolean;
  v_leftover    uuid;
  v_query       text;
  v_q_off       int;
  -- 0036
  v_tags        text[];
  v_prior       jsonb := '[]'::jsonb;   -- tags the replaced lines carried (T3)
  v_prior_ix    bigint;
  v_prior_taken bigint[] := '{}';
begin
  select * into v_entry from public.entries where id = p_entry_id for update;
  if v_entry.id is null then
    raise exception 'entry % not found', p_entry_id using errcode = '02000';
  end if;

  select count(*) into v_corrections
  from public.reviews r
  where r.entry_id = p_entry_id and r.corrected_at is not null;

  -- rule 8 + R5: a place the USER attached is authoritative, and so is a place that has
  -- corrected lines hanging off it. The sorter may only fill a gap.
  if v_entry.restaurant_source = 'user'
     or (v_corrections > 0 and v_entry.restaurant_id is not null) then
    v_rid := v_entry.restaurant_id;
    v_src := v_entry.restaurant_source;
  elsif p_restaurant_id is not null then
    v_rid := p_restaurant_id;
    v_src := 'sorter';
  else
    v_rid := null;
    v_src := null;
  end if;

  -- WHERE the place is named in the words. After an explicit place correction there is
  -- no honest mention to record: the words named something else.
  if v_entry.place_corrected_at is not null then
    v_query := null;
    v_q_off := null;
  else
    v_query := nullif(btrim(coalesce(p_place_query, '')), '');
    v_q_off := public.verified_offset(v_entry.body, v_query, p_place_offset);
    if v_q_off is null then
      v_query := null;                -- not in the words ⇒ not a mention
    end if;
  end if;

  -- T3: remember the tags on the lines about to be replaced, in receipt order. An entry with
  -- no lines at all (placeless) inherits from its parked plan instead.
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', lower(d.name), 'mention', lower(r.mention_text),
           'evidence', r.score_evidence, 'tags', to_jsonb(r.tags))
         order by r.entry_position nulls last, r.created_at, r.id), '[]'::jsonb)
    into v_prior
  from public.reviews r
  join public.dishes d on d.id = r.dish_id
  where r.entry_id = p_entry_id and r.corrected_at is null and r.tags <> '{}'::text[];

  if not exists (select 1 from public.reviews r where r.entry_id = p_entry_id)
     and jsonb_typeof(v_entry.sort_plan) = 'array' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'name', lower(btrim(x.item ->> 'dish_name')), 'mention', lower(x.item ->> 'mention_text'),
             'evidence', x.item ->> 'score_evidence',
             'tags', to_jsonb(public.dish_tags_from_json(x.item -> 'tags')))
           order by x.ord), '[]'::jsonb)
      into v_prior
    from jsonb_array_elements(v_entry.sort_plan) with ordinality as x(item, ord)
    where cardinality(public.dish_tags_from_json(x.item -> 'tags')) > 0;
  end if;

  -- R1: replace ONLY the lines the sorter owns.
  delete from public.reviews
  where entry_id = p_entry_id and corrected_at is null;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_name := btrim(coalesce(v_item ->> 'dish_name', ''));
    if v_name = '' or v_pos >= 24 then
      continue;
    end if;

    -- ---- score: half-step range, and EVIDENCE MUST BE IN THE USER'S WORDS -----
    begin
      v_score := (v_item ->> 'score')::numeric(2,1);
    exception when others then
      v_score := null;
    end;
    v_evidence := nullif(btrim(coalesce(v_item ->> 'score_evidence', '')), '');

    if v_score is not null and (v_score < 0.5 or v_score > 5.0 or (v_score * 2) <> floor(v_score * 2)) then
      v_score := null;
    end if;
    -- THE RULE-7 GATE. No evidence, or evidence that is not literally in the body →
    -- there is no score. Applies identically to every sorter mode.
    if v_score is not null and (v_evidence is null or position(v_evidence in v_entry.body) = 0) then
      v_score    := null;
      v_evidence := null;
    end if;
    if v_score is null then
      v_evidence := null;
    end if;

    -- ---- note: must be a verbatim slice of the words (rule 9) -----------------
    v_note := nullif(btrim(coalesce(v_item ->> 'note', '')), '');
    if v_note is not null and position(v_note in v_entry.body) = 0 then
      v_note := null;
    end if;

    -- ---- WHERE: the sorter's offsets, verified against the body ---------------
    -- the regex is not decoration: a garbled payload must not abort the whole sort, and
    -- an offset is always a non-negative integer.
    v_mention := nullif(btrim(coalesce(v_item ->> 'mention_text', '')), '');
    v_e_off   := public.verified_offset(
      v_entry.body, v_evidence,
      case when (v_item ->> 'evidence_offset') ~ '^\d{1,9}$' then (v_item ->> 'evidence_offset')::int end);
    v_m_off   := public.verified_offset(
      v_entry.body, v_mention,
      case when (v_item ->> 'mention_offset') ~ '^\d{1,9}$' then (v_item ->> 'mention_offset')::int end);
    if v_m_off is null then
      v_mention := null;
    end if;

    -- ---- tags: marked by the client this time, known codes only (T4) ----------
    v_tags := public.dish_tags_from_json(v_item -> 'tags');

    v_pos := v_pos + 1;

    -- ---- R3: is this proposal a line the USER already fixed? ------------------
    v_matched := false;
    if v_corrections > 0 then
      select r.* into v_keep
      from public.reviews r
      join public.dishes d on d.id = r.dish_id
      where r.entry_id = p_entry_id
        and r.corrected_at is not null
        and not (r.id = any(v_claimed))
        and (
             lower(coalesce(r.corrected_from_name, '')) = lower(v_name)
          or lower(d.name) = lower(v_name)
          or (v_evidence is not null and r.score_evidence = v_evidence)
        )
      order by r.entry_position nulls last, r.created_at, r.id
      limit 1;
      v_matched := found;
    end if;

    if v_matched then
      v_claimed := v_claimed || v_keep.id;
      -- T2: its own tags, plus any marked for it now. Never fewer.
      v_tags := public.dish_tags_from_json(to_jsonb(v_keep.tags || v_tags));
      -- R2: ordering and WHERE only. The dish, the score, its evidence and the note are
      -- the user's and are not touched here.
      update public.reviews
         set entry_position  = v_pos,
             mention_text    = coalesce(v_mention, v_keep.mention_text),
             mention_offset  = coalesce(v_m_off,   v_keep.mention_offset),
             evidence_offset = case
                                 when v_keep.score_evidence is not null
                                      and v_keep.score_evidence = v_evidence then v_e_off
                                 else v_keep.evidence_offset
                               end,
             tags            = v_tags
       where id = v_keep.id;

      v_validated := v_validated || jsonb_build_object(
        'dish_name', v_name, 'score', v_score, 'score_evidence', v_evidence,
        'note', v_note, 'position', v_pos,
        'evidence_offset', v_e_off, 'mention_text', v_mention, 'mention_offset', v_m_off,
        'tags', to_jsonb(v_tags),
        'preserved', true
      );
      continue;
    end if;

    -- ---- T3: inherit the tags of the line this one replaces -------------------
    if jsonb_array_length(v_prior) > 0 then
      select p.ord into v_prior_ix
      from jsonb_array_elements(v_prior) with ordinality as p(e, ord)
      where not (p.ord = any(v_prior_taken))
        and (
             p.e ->> 'name' = lower(v_name)
          or (v_mention  is not null and p.e ->> 'mention'  = lower(v_mention))
          or (v_evidence is not null and p.e ->> 'evidence' = v_evidence)
        )
      order by p.ord
      limit 1;
      if v_prior_ix is not null then
        v_prior_taken := v_prior_taken || v_prior_ix;
        v_tags := public.dish_tags_from_json(
          to_jsonb(public.dish_tags_from_json(v_prior -> (v_prior_ix - 1)::int -> 'tags') || v_tags));
      end if;
      v_prior_ix := null;
    end if;

    v_validated := v_validated || jsonb_build_object(
      'dish_name', v_name, 'score', v_score, 'score_evidence', v_evidence,
      'note', v_note, 'position', v_pos,
      'evidence_offset', v_e_off, 'mention_text', v_mention, 'mention_offset', v_m_off,
      'tags', to_jsonb(v_tags),
      'preserved', false
    );

    -- no place ⇒ no dish rows possible; the plan above is the record.
    if v_rid is not null then
      v_dish := public.find_or_create_dish(v_rid, v_name, v_entry.author_id);
      insert into public.reviews
        (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, score_evidence,
         note, evidence_offset, mention_text, mention_offset, created_at, tags)
      values
        (v_entry.author_id, v_dish, v_rid, p_entry_id, v_pos, v_score, v_evidence,
         v_note, v_e_off, v_mention, v_m_off, v_entry.created_at, v_tags);
    end if;
  end loop;

  -- R4: corrected lines the parse did not account for keep their place on the receipt,
  -- after the parsed ones, in their previous order.
  if v_corrections > 0 then
    for v_leftover in
      select r.id
      from public.reviews r
      where r.entry_id = p_entry_id
        and r.corrected_at is not null
        and not (r.id = any(v_claimed))
      order by r.entry_position nulls last, r.created_at, r.id
    loop
      v_pos := v_pos + 1;
      update public.reviews set entry_position = v_pos where id = v_leftover;
    end loop;
  end if;

  update public.entries
     set restaurant_id     = v_rid,
         restaurant_source = v_src,
         sort_status       = 'sorted',
         sort_mode         = p_mode,
         sort_error        = null,
         sorted_at         = now(),
         sort_plan         = v_validated,
         place_query       = v_query,
         place_offset      = v_q_off,
         sort_meta         = p_meta
   where id = p_entry_id
  returning * into v_entry;

  return v_entry;
end; $$;

comment on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int, jsonb) is
  'The sorter''s single transactional write: place + N dish reviews + where each finding sits in the body. PRESERVES every review the user corrected (corrected_at not null) — dish, score, evidence and note — and replaces only the sorter''s own lines, forced or not. Drops any score whose evidence is not a substring of the body (rule 7) and any note that is not (rule 9). Tags (0036): items[].tags are client-marked codes, filtered to the closed set; a re-sort never removes a tag. p_meta (0039) → entries.sort_meta ({cache_hit, model}). service_role only.';

revoke all on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int, jsonb) from public, anon, authenticated;
grant execute on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int, jsonb) to service_role;

-- ===========================================================================
-- 5. Deleting entries purges the author's preview plans — every path: delete_entry (0037), a raw
--    `DELETE /rest/v1/entries`, and the account cascade. Statement-level with a transition table, so
--    delete_account's hundreds of cascaded rows cost one purge, not hundreds.
-- ===========================================================================
create or replace function public.trg_entries_purge_preview_cache()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  delete from public.sort_preview_cache c
  where c.author_id in (select distinct g.author_id from gone g);
  return null;
end; $$;

revoke execute on function public.trg_entries_purge_preview_cache() from public, anon, authenticated;

drop trigger if exists entries_purge_preview_cache on public.entries;
create trigger entries_purge_preview_cache
  after delete on public.entries
  referencing old table as gone
  for each statement execute function public.trg_entries_purge_preview_cache();

-- ===========================================================================
-- 6. delete_account — 0035's body verbatim, plus the two 0039 tables in its "nothing personal
--    survived" check (both already cascade from auth.users; this makes a missed cascade a RAISE).
--    Same signature: create-or-replace, grants restated.
-- ===========================================================================
create or replace function public.delete_account()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_deleted int;
begin
  if v_uid is null then
    raise exception 'delete_account requires an authenticated caller' using errcode = '42501';
  end if;

  -- Everything personal hangs off this row by `on delete cascade` (header of 0035). Any failure
  -- here — privilege, trigger, FK — propagates and rolls the whole call back.
  delete from auth.users where id = v_uid;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 1 then
    raise exception 'delete_account: no auth user % to delete', v_uid using errcode = 'P0002';
  end if;

  -- Verify, don't trust: if a future table forgets its cascade, this refuses to report success —
  -- and, by raising, un-deletes everything above.
  if exists (select 1 from public.profiles       where id = v_uid)
  or exists (select 1 from public.entries        where author_id = v_uid)
  or exists (select 1 from public.reviews        where reviewer_id = v_uid)
  or exists (select 1 from public.saves          where user_id = v_uid)
  or exists (select 1 from public.blocks         where blocker_id = v_uid or blocked_id = v_uid)
  or exists (select 1 from public.reports        where reporter_id = v_uid or profile_id = v_uid)
  or exists (select 1 from public.comments       where user_id = v_uid)
  or exists (select 1 from public.lists          where owner_id = v_uid)
  or exists (select 1 from public.follows        where follower_id = v_uid or followee_id = v_uid)
  or exists (select 1 from public.review_likes   where user_id = v_uid)
  or exists (select 1 from public.comment_likes  where user_id = v_uid)
  or exists (select 1 from public.review_tags    where tagged_user_id = v_uid or tagger_id = v_uid)
  or exists (select 1 from public.notifications  where recipient_id = v_uid or actor_id = v_uid)
  or exists (select 1 from public.sort_preview_cache where author_id = v_uid)
  or exists (select 1 from public.sort_preview_rate  where author_id = v_uid)
  then
    raise exception 'delete_account: personal rows survived the cascade for %', v_uid
      using errcode = 'P0001';
  end if;

  -- Shape unchanged from 0032 so shipped decoders keep working; it can no longer say false.
  return jsonb_build_object('ok', true, 'auth_user_deleted', true);
end; $$;

comment on function public.delete_account() is
  'Deletes the CALLER''S account: the auth user, and by FK cascade every personal row (profile, entries, photos, lines, saves, blocks, reports, comments, lists, follows, likes, tags, notifications). Verifies nothing survived. RAISES on any failure and deletes nothing — never a false success. Returns {ok: true, auth_user_deleted: true}. Storage objects are the client''s to purge first. App Store 5.1.1(v).';

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
