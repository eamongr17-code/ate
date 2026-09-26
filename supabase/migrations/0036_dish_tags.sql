-- 0036_dish_tags.sql
-- Ate backend — DIETARY TAGS on a receipt line: gf · df · v · vg · nf (Eamon, 2026-09-26).
--
-- A tag belongs to a DISH LINE (one `reviews` row), is the USER'S — never inferred — and prints as
-- a chip on the dish row. The dish page shows what most people say about the dish.
--
-- WHY NOT `review_tags`. 0010's `review_tags` is a people-tagging EDGE (tagger's review → a tagged
-- companion; PK (review_id, tagged_user_id), follows-only scope, Realtime, a response back-link).
-- Dormant in V1 but real schema with its own semantics; a dietary code is not a person. Reusing it
-- would mean a second meaning for every column. So: a column on the line itself.
--
-- WHY A COLUMN AND NOT A TABLE. One line has 0–5 codes from a closed set, always read with the line,
-- and written by the same two writers as `score` (the author's PATCH, the sorter's RPC). An array
-- column rides the existing reviews RLS (author-only UPDATE) and needs no upsert target at all — so
-- the partial-index/ON CONFLICT landmine (0014/0016) cannot arise.
--
--   reviews.tags  text[] NOT NULL DEFAULT '{}'
--     CHECK  reviews_tags_closed_set : tags <@ {gf,df,v,vg,nf}     (anything else is 23514)
--     TRIGGER reviews_tags_canonical : lower-cases, trims, dedupes, orders by that list, NULL → {}
--
-- WRITES
--   * the author: `PATCH /rest/v1/reviews?id=eq.<uuid> {"tags": ["gf","v"]}` — the same call that
--     sets a line's score. Owner-only by `reviews_update_author` (0004). NOT a correction: a tag
--     change does not stamp `corrected_at`, so tagging a line never freezes its dish or score.
--   * the sorter: `apply_entry_sort` items may carry `tags`, set ONLY from spans the client marked
--     as tag tokens (sort-entry `tag_tokens`); prose never tags (supabase/functions/sort-entry/tags.ts).
--
-- THE TAG RULE ON RE-SORT (the user's tags survive, like a correction):
--   T1. A re-sort NEVER REMOVES a tag. Only the author's PATCH does.
--   T2. A corrected line keeps its tags and gains any the client marked for it this time.
--   T3. A sorter-owned line is rebuilt, and the rebuilt line INHERITS the tags of the line it
--       replaces — matched like R3: same dish name, or same mention, or same score evidence, first
--       unclaimed in receipt order — plus any marked this time. When an entry has no lines yet
--       (no place), the parked plan's tags are what it inherits.
--   T4. Every tag is re-filtered to the closed set on the way in; the sorter cannot write an
--       unknown code, and an unknown code in a payload is dropped, not an aborted sort.
--
-- READS
--   * entry_cards.items[].tags — `[]` when none, never null; canonical order. Reaches every card read
--     and the anon browse twins (they return the view's rows).
--   * dish_summary.tags — the CONSENSUS: a code is listed when at least half of the dish's lines the
--     viewer can see carry it (and at least one does). Same line set as `review_count`, so the two
--     can never disagree. `{}` when nothing qualifies.
--
-- WIRE IMPACT
--   ADDITIVE: `reviews.tags`; `items[].tags`; `dish_summary.tags` (new OUT column, appended); sort-entry
--   `tag_tokens` (optional request field) and `items[].tags` on its response.
--   INTERNAL: dish_summary changes OUT columns ⇒ DROP-then-CREATE (landmine 7), public AND its browse
--   twin, grants restored below. apply_entry_sort / correct_entry_place keep their signatures
--   (create-or-replace, no second overload).
--
-- Forward-only. No data is rewritten: every existing line gets `{}`.

set search_path = public, extensions;

-- ===========================================================================
-- 1. The vocabulary, once.
-- ===========================================================================
create or replace function public.dish_tag_codes()
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$ select array['gf', 'df', 'v', 'vg', 'nf']::text[] $$;

comment on function public.dish_tag_codes() is
  'The closed set of dietary tag codes, in canonical order: gf, df, v, vg, nf (0036).';

-- Canonical form for STORAGE: trimmed, lower-cased, deduped, known codes in list order. Unknown
-- codes are KEPT (after the known ones) so the closed-set CHECK refuses them with 23514 instead of
-- a client's typo vanishing silently.
create or replace function public.dish_tags_canonical(p_tags text[])
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select coalesce(array_agg(t.code order by t.rank, t.code), '{}'::text[])
  from (
    select distinct lower(btrim(x)) as code,
           coalesce(array_position(public.dish_tag_codes(), lower(btrim(x))), 99) as rank
    from unnest(p_tags) as x
    where x is not null and btrim(x) <> ''
  ) t;
$$;

comment on function public.dish_tags_canonical(text[]) is
  'Storage form of reviews.tags: trimmed, lower-cased, deduped, ordered gf,df,v,vg,nf; unknown codes kept last so the CHECK refuses them (23514). NULL → {}.';

-- For the SORTER's payloads: a jsonb array (or anything else) → known codes only, canonical.
create or replace function public.dish_tags_from_json(p_tags jsonb)
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select array(
    select c
    from unnest(public.dish_tags_canonical(array(
           select jsonb_array_elements_text(
             case when jsonb_typeof(p_tags) = 'array' then p_tags else '[]'::jsonb end)
         ))) as c
    where c = any(public.dish_tag_codes())
  );
$$;

comment on function public.dish_tags_from_json(jsonb) is
  'A sorter payload''s tags → known codes only, canonical. Never raises: garbage is dropped, so a bad payload cannot abort a sort.';

revoke all on function public.dish_tag_codes()               from public, anon;
revoke all on function public.dish_tags_canonical(text[])    from public, anon;
revoke all on function public.dish_tags_from_json(jsonb)     from public, anon;
grant execute on function public.dish_tag_codes()            to authenticated, service_role;
grant execute on function public.dish_tags_canonical(text[]) to authenticated, service_role;
grant execute on function public.dish_tags_from_json(jsonb)  to authenticated, service_role;

-- ===========================================================================
-- 2. reviews.tags — the storage, the CHECK, the canonicaliser.
-- A constant default: no table rewrite, every existing line reads {}.
-- ===========================================================================
alter table public.reviews
  add column if not exists tags text[] not null default '{}'::text[];

alter table public.reviews
  add constraint reviews_tags_closed_set
  check (tags <@ array['gf', 'df', 'v', 'vg', 'nf']::text[]);

comment on column public.reviews.tags is
  'Dietary tags on this dish line (0036): subset of {gf,df,v,vg,nf}, canonical order, {} when none. The USER''S: set by the author''s PATCH or from tag tokens the client marked; never inferred. Not a correction (does not stamp corrected_at). A re-sort never removes one.';

create or replace function public.trg_review_tags_canonical()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  new.tags := public.dish_tags_canonical(new.tags);
  return new;
end; $$;

drop trigger if exists reviews_tags_canonical on public.reviews;
create trigger reviews_tags_canonical
  before insert or update of tags on public.reviews
  for each row execute function public.trg_review_tags_canonical();

-- 0008's rule: a trigger function is not an RPC.
revoke execute on function public.trg_review_tags_canonical() from public, anon, authenticated;

-- ===========================================================================
-- 3. apply_entry_sort — 0024's function, verbatim, plus THE TAG RULE (T1–T4 above).
-- Same signature ⇒ create or replace; no second overload.
--
-- p_items elements gain an OPTIONAL `tags` (jsonb array of codes). Absent = [].
-- ===========================================================================
create or replace function public.apply_entry_sort(
  p_entry_id      uuid,
  p_restaurant_id uuid    default null,
  p_items         jsonb   default '[]'::jsonb,
  p_mode          text    default 'stub',
  p_place_query   text    default null,
  p_place_offset  int     default null
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
         place_offset      = v_q_off
   where id = p_entry_id
  returning * into v_entry;

  return v_entry;
end; $$;

comment on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int) is
  'The sorter''s single transactional write: place + N dish reviews + where each finding sits in the body. PRESERVES every review the user corrected (corrected_at not null) — dish, score, evidence and note — and replaces only the sorter''s own lines, forced or not. Drops any score whose evidence is not a substring of the body (rule 7) and any note that is not (rule 9). Tags (0036): items[].tags are client-marked codes, filtered to the closed set; a re-sort never removes a tag — a rebuilt line inherits the tags of the line it replaces. service_role only.';

revoke all on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int) from public, anon, authenticated;
grant execute on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int) to service_role;

-- ===========================================================================
-- 4. correct_entry_place — 0024's function, verbatim, except that printing the PARKED plan now
-- carries each item's tags (they were marked before the entry had a place to hang lines on).
-- ===========================================================================
create or replace function public.correct_entry_place(p_entry_id uuid, p_restaurant_id uuid)
returns public.entries
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_entry public.entries;
  v_rev   record;
  v_item  jsonb;
  v_dish  uuid;
  v_pos   smallint := 0;
  v_name  text;
  v_score numeric(2,1);
  v_evid  text;
  v_note  text;
  v_ment  text;
  v_e_off int;
  v_m_off int;
begin
  select * into v_entry from public.entries where id = p_entry_id for update;
  if v_entry.id is null or v_entry.author_id <> (select auth.uid()) then
    raise exception 'entry % not found or not yours', p_entry_id using errcode = '42501';
  end if;
  if p_restaurant_id is null then
    raise exception 'a restaurant is required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.restaurants r where r.id = p_restaurant_id) then
    raise exception 'restaurant % not found', p_restaurant_id using errcode = '23503';
  end if;

  if exists (select 1 from public.reviews v where v.entry_id = p_entry_id) then
    -- (a) repoint every existing line item to the same dish NAME at the new place.
    -- Moving a line to the equivalent dish at another restaurant is bookkeeping, not a
    -- per-line dish correction, so the correction trigger sits this one out. Tags ride
    -- the row untouched.
    perform set_config('ate.repointing', 'on', true);
    for v_rev in
      select v.id, v.entry_position, d.name
      from public.reviews v join public.dishes d on d.id = v.dish_id
      where v.entry_id = p_entry_id
      order by v.entry_position nulls last, v.created_at, v.id
    loop
      v_dish := public.find_or_create_dish(p_restaurant_id, v_rev.name, v_entry.author_id);
      -- restaurant_id is re-derived by trg_review_set_restaurant from the new dish.
      update public.reviews set dish_id = v_dish where id = v_rev.id;
    end loop;
    perform set_config('ate.repointing', 'off', true);
  else
    -- (b) print the parked plan at last.
    for v_item in select * from jsonb_array_elements(coalesce(v_entry.sort_plan, '[]'::jsonb)) loop
      v_name := btrim(coalesce(v_item ->> 'dish_name', ''));
      if v_name = '' or v_pos >= 24 then
        continue;
      end if;
      begin
        v_score := (v_item ->> 'score')::numeric(2,1);
      exception when others then
        v_score := null;
      end;
      v_evid := nullif(btrim(coalesce(v_item ->> 'score_evidence', '')), '');
      v_note := nullif(btrim(coalesce(v_item ->> 'note', '')), '');
      v_ment := nullif(btrim(coalesce(v_item ->> 'mention_text', '')), '');
      -- re-assert rules 7 + 9 against the body AS IT IS NOW: the plan was parked
      -- when the entry was sorted, and the author may have edited their words since.
      if v_score is not null and (v_evid is null or position(v_evid in v_entry.body) = 0) then
        v_score := null;
        v_evid  := null;
      end if;
      if v_note is not null and position(v_note in v_entry.body) = 0 then
        v_note := null;
      end if;
      v_e_off := public.verified_offset(
        v_entry.body, v_evid,
        case when (v_item ->> 'evidence_offset') ~ '^\d{1,9}$' then (v_item ->> 'evidence_offset')::int end);
      v_m_off := public.verified_offset(
        v_entry.body, v_ment,
        case when (v_item ->> 'mention_offset') ~ '^\d{1,9}$' then (v_item ->> 'mention_offset')::int end);
      if v_m_off is null then
        v_ment := null;
      end if;

      v_pos  := v_pos + 1;
      v_dish := public.find_or_create_dish(p_restaurant_id, v_name, v_entry.author_id);
      insert into public.reviews
        (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, score_evidence,
         note, evidence_offset, mention_text, mention_offset, created_at, tags)
      values
        (v_entry.author_id, v_dish, p_restaurant_id, p_entry_id, v_pos, v_score, v_evid,
         v_note, v_e_off, v_ment, v_m_off, v_entry.created_at,
         public.dish_tags_from_json(v_item -> 'tags'));
    end loop;
  end if;

  update public.entries
     set restaurant_id      = p_restaurant_id,
         restaurant_source  = 'user',
         sort_status        = 'sorted',
         place_corrected_at = now(),
         place_query        = null,
         place_offset       = null
   where id = p_entry_id
  returning * into v_entry;

  return v_entry;
end; $$;

comment on function public.correct_entry_place(uuid, uuid) is
  'Author fixes an entry''s place: re-resolves its dishes at the new restaurant, or applies the parked sort_plan (tags included, 0036) if it had none. Pins restaurant_source=''user'', stamps place_corrected_at and clears the recorded place mention.';

revoke all on function public.correct_entry_place(uuid, uuid) from public, anon;
grant execute on function public.correct_entry_place(uuid, uuid) to authenticated, service_role;

-- ===========================================================================
-- 5. entry_cards — 0035's view, verbatim, with `tags` appended inside each items[] object.
-- Same columns, same types ⇒ create or replace is legal and the view's grant survives.
-- ===========================================================================
create or replace view public.entry_cards
with (security_invoker = true) as
  select
    e.id,
    e.author_id,
    e.body,
    e.visibility,
    e.restaurant_id,
    e.restaurant_source,
    e.order_number,
    e.sort_status,
    e.sorted_at,
    e.created_at,
    e.updated_at,
    (e.author_id = (select auth.uid())) as is_mine,
    jsonb_build_object(
      'id', p.id, 'username', p.username, 'name', p.name,
      'avatar_url', p.avatar_url, 'city', p.city
    ) as author,
    case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'name', r.name, 'address', r.address,
      'city', r.city, 'cuisine', r.cuisine,
      -- 0035: the suburb the card foot line prints. place_locality(), never the raw city (which is
      -- the "<street>, <suburb STATE post>" mangle on rows resolved live before 0031's PR).
      'locality', public.place_locality(r.address, r.city)
    ) end as place,
    coalesce(ph.photos, '[]'::jsonb) as photos,
    coalesce(ph.photo_count, 0)      as photo_count,
    coalesce(it.items, '[]'::jsonb)  as items,
    coalesce(it.dish_count, 0)       as dish_count,
    it.avg_score,
    -- WHERE the place is named in the words (0025).
    e.place_offset,
    char_length(e.place_query) as place_length
  from public.entries e
  join public.profiles p on p.id = e.author_id
  left join public.restaurants r on r.id = e.restaurant_id
  left join lateral (
    select
      jsonb_agg(jsonb_build_object('url', x.photo_url, 'position', x.position)
                order by x.position) as photos,
      count(*)::int as photo_count
    from public.entry_photos x
    where x.entry_id = e.id
  ) ph on true
  left join lateral (
    select
      jsonb_agg(jsonb_build_object(
        'review_id', v.id,
        'dish_id',   v.dish_id,
        'dish_name', d.name,
        'score',     v.score,
        'note',      v.note,
        'position',  v.entry_position,
        'saved',     (s.user_id is not null),
        'evidence_offset', v.evidence_offset,
        'evidence_length', char_length(v.score_evidence),
        'mention_offset',  v.mention_offset,
        'mention_length',  char_length(v.mention_text),
        'corrected', (v.corrected_at is not null),
        -- the DISH's cover, so a receipt line can draw its thumbnail without a second
        -- round trip. NOT this entry's photo — `photos[]` is that.
        'cover_url', public.dish_cover_url(v.dish_id),
        -- 0036: the line's dietary tags, canonical, [] when none (the column is NOT NULL).
        'tags', to_jsonb(v.tags)
      ) order by v.entry_position nulls last, v.created_at, v.id) as items,
      count(*)::int as dish_count,
      round(avg(v.score), 2)::numeric(3,2) as avg_score
    from public.reviews v
    join public.dishes d on d.id = v.dish_id
    left join public.saves s on s.dish_id = v.dish_id and s.user_id = (select auth.uid())
    where v.entry_id = e.id
  ) it on true;

comment on view public.entry_cards is
  'The one entry shape for Journal slip / Feed slip / Entry page / Share receipt: entry + author + place (+ locality, 0035) + photos[] + items[] (each with the dish''s cover_url and its dietary tags[], 0036) + receipt footer (dish_count, avg_score over scored items) + where each finding sits in body (place_offset/length, items[].evidence_* and mention_*, all 0-based UNICODE SCALAR offsets). Read a single entry with ?id=eq.<uuid>; page lists via get_entry_feed / get_entries_by_author / get_entries_at_place.';

-- ===========================================================================
-- 6. The dish's consensus tags, and dish_summary + `tags`.
--
-- THE RULE: a code is listed when at least HALF of the dish's lines carry it, and at least one
-- does. "Lines" = the same set `review_count` counts (every line on the dish the viewer can see —
-- SECURITY INVOKER, so a blocked author's lines count for nobody but themselves). One diner's GF
-- on a dish with one line is the consensus; one GF among three lines is not.
-- ===========================================================================
create or replace function public.dish_consensus_tags(p_dish_id uuid)
returns text[]
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(array_agg(k.code order by k.ord), '{}'::text[])
  from (
    select c.code, c.ord,
           count(*) filter (where c.code = any(v.tags)) as carrying,
           count(*) as total
    from unnest(public.dish_tag_codes()) with ordinality as c(code, ord)
    cross join public.reviews v
    where v.dish_id = p_dish_id
    group by c.code, c.ord
  ) k
  where k.carrying >= 1 and k.carrying * 2 >= k.total;
$$;

comment on function public.dish_consensus_tags(uuid) is
  'Dietary codes at least half of the dish''s visible lines carry (and at least one does), canonical order; {} when none. Viewer-relative, same line set as review_count (0036).';

revoke all on function public.dish_consensus_tags(uuid) from public, anon;
grant execute on function public.dish_consensus_tags(uuid) to authenticated, service_role;

-- New OUT column ⇒ DROP-then-CREATE (landmine 7), the browse twin with it.
drop function if exists browse.dish_summary(uuid);
drop function if exists public.dish_summary(uuid);

create function public.dish_summary(p_dish_id uuid)
returns table (
  dish_id             uuid,
  dish_name           text,
  restaurant_id       uuid,
  restaurant_name     text,
  restaurant_city     text,
  score               numeric(2,1),
  review_count        int,
  scored_count        int,
  people_count        int,
  cover_url           text,
  saved               boolean,
  my_last_score       numeric(2,1),
  -- appended 0029
  photos              jsonb,
  restaurant_locality text,
  -- appended 0036
  tags                text[]
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.dish_summary(p_dish_id);
    return;
  end if;

  -- Signed in.
  return query
  select
    d.id, d.name, r.id, r.name, nullif(btrim(r.city), ''),
    ds.score, coalesce(ds.review_count, 0), coalesce(ds.scored_count, 0),
    coalesce(ds.people_count, 0),
    ds.cover_url,
    exists (select 1 from public.saves s where s.dish_id = d.id and s.user_id = (select auth.uid())),
    (
      select v.score from public.reviews v
      where v.dish_id = d.id and v.reviewer_id = (select auth.uid()) and v.score is not null
      order by v.created_at desc, v.id desc limit 1
    ),
    public.dish_photos(d.id, 8),
    public.place_locality(r.address, r.city),
    public.dish_consensus_tags(d.id)
  from public.dishes d
  join public.restaurants r on r.id = d.restaurant_id
  left join public.dish_stats ds on ds.dish_id = d.id
  where d.id = p_dish_id;
end;
$$;

comment on function public.dish_summary(uuid) is
  'The dish page header in one call: the dish, its place, viewer-relative aggregates (score NULL = nobody scored it), the photo stack (photos[0].url == cover_url), the viewer''s own save state + last score, and the consensus dietary tags (0036: codes at least half of its lines carry). Signed out → browse.dish_summary. A dish''s "orders" is review_count.';

create function browse.dish_summary(p_dish_id uuid)
returns table (
  dish_id             uuid,
  dish_name           text,
  restaurant_id       uuid,
  restaurant_name     text,
  restaurant_city     text,
  score               numeric(2,1),
  review_count        int,
  scored_count        int,
  people_count        int,
  cover_url           text,
  saved               boolean,
  my_last_score       numeric(2,1),
  -- appended 0029
  photos              jsonb,
  restaurant_locality text,
  -- appended 0036
  tags                text[]
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select s.dish_id, s.dish_name, s.restaurant_id, s.restaurant_name, s.restaurant_city, s.score,
         s.review_count, s.scored_count, s.people_count, s.cover_url,
         false, null::numeric(2,1),                    -- saved, my_last_score: no viewer
         s.photos, s.restaurant_locality, s.tags
  from public.dish_summary(p_dish_id) s;
$$;

-- Restore exactly the grants the drop took: authenticated (0029) + anon (0034) on the public read;
-- anon only on the browse twin.
revoke all on function public.dish_summary(uuid) from public;
grant execute on function public.dish_summary(uuid) to authenticated, anon, service_role;
revoke all on function browse.dish_summary(uuid) from public;
grant execute on function browse.dish_summary(uuid) to anon;
