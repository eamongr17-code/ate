-- 0024_corrections_and_offsets.sql
-- Ate backend — the user's corrections SURVIVE a re-sort, and every finding says WHERE
-- in the words it was found.
--
-- WHY THIS EXISTS (two client-visible gaps QA found against 0021/0022):
--
--   1. RE-SORT WAS DESTRUCTIVE. apply_entry_sort deleted every review of the entry and
--      rebuilt from the parse, and the edge function honoured `force`. So a user who
--      fixed a mis-matched dish could lose that fix to any later re-sort. A correction
--      is the USER'S data. It is now recorded (`reviews.corrected_at`,
--      `entries.place_corrected_at`) and PRESERVED — see THE PRESERVATION RULE below.
--      The server no longer depends on the client choosing not to force.
--
--   2. TOKENS WERE REBUILT BY SEARCHING THE BODY. The client re-derived its inline score
--      token by searching `body` for the number, which finds "$14.50" before a 4.5.
--      Every finding now carries the offset the sorter actually matched at.
--
-- THE OFFSET UNIT — stated once, and it is not negotiable afterwards:
--   a 0-BASED UNICODE SCALAR (code point) offset into `entries.body`, with lengths in
--   the same unit. Postgres string functions (position/substring/char_length) count code
--   points in a UTF8 database, so this is the unit the DATABASE can verify — which it
--   does, on every write, via verified_offset(). JavaScript and Swift both count UTF-16,
--   so both ends convert; one emoji before the token is enough to make the two units
--   disagree, so the conversion is spelled out in the contract doc and in offsets.ts.
--
-- WIRE IMPACT:
--   ADDITIVE      : columns `reviews.corrected_at`, `reviews.corrected_from_name`,
--                   `reviews.evidence_offset`, `reviews.mention_text`,
--                   `reviews.mention_offset`; `entries.place_corrected_at`,
--                   `entries.place_query`, `entries.place_offset`; function
--                   `verified_offset`. Nothing existing changes name, type or nullability.
--   BREAKING, but INTERNAL ONLY (no client calls it, nothing is deployed yet):
--                   apply_entry_sort gains p_place_query + p_place_offset, which means
--                   DROP-then-CREATE rather than CREATE OR REPLACE. Two overloads would
--                   make every PostgREST named-argument call ambiguous ("function is not
--                   unique", 42725) — a landmine, not a nicety. The function is
--                   service_role-only and its ONE caller (supabase/functions/sort-entry)
--                   ships in this same change.
--   BEHAVIOUR     : dish DISPLAY names are normalised on CREATE (trim, collapse
--                   whitespace, capitalise the first letter) so prose-derived dishes stop
--                   printing as "salmon roll". An existing dish's name is never touched.
--
-- Forward-only. 0021 is not edited.

set search_path = public, extensions;

-- ===========================================================================
-- verified_offset — VERIFIED TRUST, the same shape as DESIGN rule 7.
--
-- The sorter says "the evidence is at 59". We believe it only if the body really says
-- that text there; otherwise we fall back to the FIRST occurrence, and to NULL when
-- there is none. Never a guess, because a wrong offset puts the client's token on the
-- wrong words — and the claim matters: the first "4.5" in the body may be a price.
-- ===========================================================================
create or replace function public.verified_offset(p_body text, p_text text, p_claim int)
returns int
language sql
immutable
set search_path = public, extensions
as $$
  select case
    when p_body is null or p_text is null or p_text = '' then null
    when p_claim is not null and p_claim >= 0
         and substring(p_body from p_claim + 1 for char_length(p_text)) = p_text
      then p_claim
    when position(p_text in p_body) > 0 then position(p_text in p_body) - 1
    else null
  end;
$$;

comment on function public.verified_offset(text, text, int) is
  'The 0-based UNICODE SCALAR offset of p_text in p_body: the claimed one if the body really says it there, else the first occurrence, else NULL. Postgres counts code points, which is why scalars are the published unit.';

revoke all on function public.verified_offset(text, text, int) from public, anon, authenticated;
grant execute on function public.verified_offset(text, text, int) to service_role;

-- ===========================================================================
-- reviews — provenance of the USER'S corrections, and WHERE each finding sits.
-- ===========================================================================
alter table public.reviews
  add column if not exists corrected_at        timestamptz,
  add column if not exists corrected_from_name text,
  add column if not exists evidence_offset     integer,
  add column if not exists mention_text        text,
  add column if not exists mention_offset      integer;

comment on column public.reviews.corrected_at is
  'When the AUTHOR last fixed this receipt line (dish, score or note). Non-null makes the line the user''s: apply_entry_sort preserves it through any re-sort, forced or not.';
comment on column public.reviews.corrected_from_name is
  'The dish name this line carried when the user first corrected it — i.e. the sorter''s proposal. Used ONLY to recognise that same proposal on a later re-sort so it is not re-inserted as a duplicate line.';
comment on column public.reviews.evidence_offset is
  '0-based UNICODE SCALAR offset of score_evidence in entries.body. The client draws its inline score token here instead of searching the body (which finds "$14.50" before a 4.5).';
comment on column public.reviews.mention_text is
  'The verbatim slice of entries.body that NAMED this dish. Can differ from dishes.name in case/spacing, because the receipt prints the menu''s spelling.';
comment on column public.reviews.mention_offset is
  '0-based UNICODE SCALAR offset of mention_text in entries.body.';

-- "which lines of this entry are the user's?" — asked on every re-sort.
create index if not exists reviews_corrected_idx
  on public.reviews (entry_id) where corrected_at is not null;

-- ===========================================================================
-- entries — the place correction, and WHERE the place was named.
-- ===========================================================================
alter table public.entries
  add column if not exists place_corrected_at timestamptz,
  add column if not exists place_query        text,
  add column if not exists place_offset       integer;

comment on column public.entries.place_corrected_at is
  'When the author overrode the place (correct_entry_place). Once set, the sorter never records a place mention for this entry again — the words point at a venue that is not the one attached.';
comment on column public.entries.place_query is
  'The verbatim slice of body that named the attached place (sorter match, or the phrase matching a place the user tapped). NULL when the words never named it.';
comment on column public.entries.place_offset is
  '0-based UNICODE SCALAR offset of place_query in body — the client''s place token.';

-- These columns are NOT in 0018's column grants, so clients cannot write them. The
-- 0021/0024 RPCs remain their only writers.

-- ===========================================================================
-- trg_review_mark_corrected — a correction is recorded WHEREVER it comes from.
--
-- correct_entry_dish stamps explicitly. This trigger is the net under it: any UPDATE by
-- the reviewer themselves that changes the dish, the score or the note is a correction,
-- including a plain `PATCH /rest/v1/reviews {score}` (the contract's own way to set a
-- score). Sorter writes are NOT corrections: they arrive as service_role, where
-- auth.uid() is NULL.
--
-- ONE EXCEPTION, and it is explicit: correct_entry_place re-points every line to the
-- same dish NAME at the new restaurant. That is mechanical, not a per-line decision, so
-- it sets `ate.repointing` for its transaction and this trigger ignores the dish change.
--
-- corrected_at is MONOTONE — it can be set, never cleared. There is no product reason to
-- un-correct a line, and "cleanup" that silently reverts a user's fix is exactly the
-- class of mistake this migration exists to make impossible.
-- ===========================================================================
create or replace function public.trg_review_mark_corrected()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_repointing boolean := coalesce(current_setting('ate.repointing', true) = 'on', false);
  v_changed   boolean;
begin
  -- never lose an existing stamp
  new.corrected_at := coalesce(new.corrected_at, old.corrected_at);

  if v_uid is null or v_uid <> new.reviewer_id then
    return new;                       -- the sorter / service role: not a correction
  end if;
  if new.corrected_at is distinct from old.corrected_at then
    return new;                       -- an explicit setter (correct_entry_dish) wins
  end if;

  v_changed := (new.score is distinct from old.score)
            or (new.note  is distinct from old.note)
            or (not v_repointing and new.dish_id is distinct from old.dish_id);

  if v_changed then
    new.corrected_at := now();
    if new.dish_id is distinct from old.dish_id and new.corrected_from_name is null and not v_repointing then
      select d.name into new.corrected_from_name from public.dishes d where d.id = old.dish_id;
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists reviews_mark_corrected on public.reviews;
create trigger reviews_mark_corrected
  before update on public.reviews
  for each row execute function public.trg_review_mark_corrected();

-- 0008's rule: a trigger function is not an RPC.
revoke execute on function public.trg_review_mark_corrected() from public, anon, authenticated;

-- ===========================================================================
-- find_or_create_dish — unchanged contract, two additions:
--   * the LOOKUP key is whitespace-normalised, so "pork  and chive" finds the existing
--     "Pork and chive" instead of creating a twin;
--   * the DISPLAY name is normalised ON CREATE ONLY: trimmed, whitespace collapsed,
--     first letter capitalised. Prose arrives lower case ("salmon roll") and a receipt
--     that prints "salmon roll" looks like a bug. An EXISTING dish's name is never
--     touched — it may have been curated, and it is not this function's to rewrite.
-- Still SELECT-then-INSERT: dishes_identity_uq is PARTIAL by design (0014/0016), so
-- ON CONFLICT is not available here and never will be.
-- ===========================================================================
create or replace function public.find_or_create_dish(
  p_restaurant_id uuid,
  p_name          text,
  p_created_by    uuid default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_name    text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_display text;
  v_id      uuid;
begin
  if p_restaurant_id is null then
    raise exception 'find_or_create_dish requires a restaurant' using errcode = '22023';
  end if;
  if v_name = '' then
    raise exception 'find_or_create_dish requires a dish name' using errcode = '22023';
  end if;

  select d.id into v_id
  from public.dishes d
  where d.restaurant_id = p_restaurant_id
    and lower(d.name) = lower(v_name)
    and d.merged_into_dish_id is null
  limit 1;
  if v_id is not null then
    return v_id;                      -- an existing dish keeps its own name
  end if;

  v_display := upper(substr(v_name, 1, 1)) || substr(v_name, 2);

  begin
    insert into public.dishes (name, restaurant_id, created_by_user_id)
    values (v_display, p_restaurant_id, p_created_by)
    returning id into v_id;
  exception when unique_violation then
    -- lost the race against a concurrent creator: take theirs.
    select d.id into v_id
    from public.dishes d
    where d.restaurant_id = p_restaurant_id
      and lower(d.name) = lower(v_name)
      and d.merged_into_dish_id is null
    limit 1;
  end;

  return v_id;
end; $$;

comment on function public.find_or_create_dish(uuid, text, uuid) is
  'Select-then-insert the live dish (restaurant_id, lower(name)), normalising the DISPLAY name on create only (trim, collapse whitespace, capitalise first letter). NEVER ON CONFLICT — dishes_identity_uq is partial by design (0014/0016).';

revoke all on function public.find_or_create_dish(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.find_or_create_dish(uuid, text, uuid) to service_role;

-- ===========================================================================
-- apply_entry_sort — the sorter's single transactional write, now non-destructive.
--
-- p_items: ordered jsonb array; each element
--   { "dish_name": text, "score": number|null, "score_evidence": text|null,
--     "note": text|null, "evidence_offset": int|null,
--     "mention_text": text|null, "mention_offset": int|null }
--
-- THE PRESERVATION RULE (the whole point of this migration; documented verbatim in
-- docs/backend/integration-design.md):
--
--   A review with `corrected_at IS NOT NULL` is the USER'S line.
--   R1. It is never deleted by a re-sort, forced or not. Only rows with corrected_at
--       IS NULL — the ones the sorter still owns — are replaced.
--   R2. Its dish_id, score, score_evidence and note are never modified. Only its
--       `entry_position` (receipt ordering) and its offsets (WHERE in the current body)
--       are refreshed, and the offsets only when the text they point at still matches.
--   R3. A parsed item is matched to a corrected line — and then NOT inserted, so the
--       receipt gains no duplicate — when any of these hold, in this order:
--         (a) the item's dish_name equals `corrected_from_name` (the sorter's original
--             proposal for that line) case-insensitively; or
--         (b) the item's dish_name equals the line's CURRENT dish name
--             case-insensitively (the user only re-cased or re-picked the same dish); or
--         (c) the item's score_evidence is identical to the line's score_evidence — the
--             same number in the same words is the same mention.
--       First unclaimed line in receipt order wins; each line is claimed at most once.
--   R4. A corrected line that matches NO item still survives, appended after the parsed
--       lines in its previous order. The words may no longer mention that dish; the user
--       said it was there, and the sorter does not get a vote on that.
--   R5. A corrected line PINS THE PLACE. The user corrected a dish against THIS
--       restaurant's menu, so a fresh sorter match may not move the entry elsewhere and
--       orphan the line. (restaurant_source keeps recording how the place got there.)
--
--   Rules 7 and 9 are re-asserted on every SORTER-PROPOSED line, exactly as before. They
--   are NOT re-applied to a preserved line: they constrain what the sorter may write, not
--   what the user may keep. A body edit does not retro-delete their words.
--
-- Everything else is 0021's behaviour, unchanged.
-- ===========================================================================
drop function if exists public.apply_entry_sort(uuid, uuid, jsonb, text);

create function public.apply_entry_sort(
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
                               end
       where id = v_keep.id;

      v_validated := v_validated || jsonb_build_object(
        'dish_name', v_name, 'score', v_score, 'score_evidence', v_evidence,
        'note', v_note, 'position', v_pos,
        'evidence_offset', v_e_off, 'mention_text', v_mention, 'mention_offset', v_m_off,
        'preserved', true
      );
      continue;
    end if;

    v_validated := v_validated || jsonb_build_object(
      'dish_name', v_name, 'score', v_score, 'score_evidence', v_evidence,
      'note', v_note, 'position', v_pos,
      'evidence_offset', v_e_off, 'mention_text', v_mention, 'mention_offset', v_m_off,
      'preserved', false
    );

    -- no place ⇒ no dish rows possible; the plan above is the record.
    if v_rid is not null then
      v_dish := public.find_or_create_dish(v_rid, v_name, v_entry.author_id);
      insert into public.reviews
        (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, score_evidence,
         note, evidence_offset, mention_text, mention_offset, created_at)
      values
        (v_entry.author_id, v_dish, v_rid, p_entry_id, v_pos, v_score, v_evidence,
         v_note, v_e_off, v_mention, v_m_off, v_entry.created_at);
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
  'The sorter''s single transactional write: place + N dish reviews + where each finding sits in the body. PRESERVES every review the user corrected (corrected_at not null) — dish, score, evidence and note — and replaces only the sorter''s own lines, forced or not. Drops any score whose evidence is not a substring of the body (rule 7) and any note that is not (rule 9). service_role only.';

revoke all on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int) from public, anon, authenticated;
grant execute on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int) to service_role;

-- ===========================================================================
-- correct_entry_place — as 0021, plus:
--   * it records that the user overrode the place (`place_corrected_at`) and drops the
--     recorded place mention: the phrase in the words named a different venue, so a
--     place token drawn on it would be a lie;
--   * the mechanical dish re-point is flagged (`ate.repointing`) so the correction
--     trigger does not mark every line as a dish correction;
--   * the parked-plan replay carries the offsets through, re-verified against the body
--     as it is NOW (the author may have edited their words since the sort).
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
    -- per-line dish correction, so the correction trigger sits this one out.
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
         note, evidence_offset, mention_text, mention_offset, created_at)
      values
        (v_entry.author_id, v_dish, p_restaurant_id, p_entry_id, v_pos, v_score, v_evid,
         v_note, v_e_off, v_ment, v_m_off, v_entry.created_at);
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
  'Author fixes an entry''s place: re-resolves its dishes at the new restaurant, or applies the parked sort_plan if it had none. Pins restaurant_source=''user'', stamps place_corrected_at and clears the recorded place mention.';

-- ===========================================================================
-- correct_entry_dish — as 0021, plus the RECORD that makes preservation possible:
-- `corrected_at`, and `corrected_from_name` = the name this line carried the FIRST time
-- the user touched it (the sorter's proposal). First proposal wins, because that is the
-- name the sorter will propose again on every future re-sort.
-- Score and note are the user's words and are NOT touched here.
-- ===========================================================================
create or replace function public.correct_entry_dish(
  p_review_id uuid,
  p_dish_id   uuid default null,
  p_dish_name text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_author   uuid;
  v_rid      uuid;
  v_dish     uuid;
  v_was      text;
  v_was_from text;
begin
  select v.reviewer_id, e.restaurant_id, d.name, v.corrected_from_name
    into v_author, v_rid, v_was, v_was_from
  from public.reviews v
  join public.entries e on e.id = v.entry_id
  left join public.dishes d on d.id = v.dish_id
  where v.id = p_review_id;

  if v_author is null or v_author <> (select auth.uid()) then
    raise exception 'review % not found or not yours', p_review_id using errcode = '42501';
  end if;
  if v_rid is null then
    raise exception 'entry has no place yet — correct the place first' using errcode = '22023';
  end if;

  if p_dish_id is not null then
    select d.id into v_dish
    from public.dishes d
    where d.id = p_dish_id and d.restaurant_id = v_rid and d.merged_into_dish_id is null;
    if v_dish is null then
      raise exception 'dish % is not a live dish at this place', p_dish_id using errcode = '23503';
    end if;
  else
    v_dish := public.find_or_create_dish(v_rid, p_dish_name, v_author);
  end if;

  update public.reviews
     set dish_id             = v_dish,
         corrected_at        = now(),
         corrected_from_name = coalesce(v_was_from, v_was)
   where id = p_review_id;

  return v_dish;
end; $$;

comment on function public.correct_entry_dish(uuid, uuid, text) is
  'Author fixes one receipt line''s dish match — pick an existing dish at the place or name a new one. Score/note untouched. Stamps corrected_at + corrected_from_name so a later re-sort preserves the line instead of rebuilding it.';

revoke all on function public.correct_entry_place(uuid, uuid)            from public, anon;
revoke all on function public.correct_entry_dish(uuid, uuid, text)       from public, anon;
grant execute on function public.correct_entry_place(uuid, uuid)          to authenticated, service_role;
grant execute on function public.correct_entry_dish(uuid, uuid, text)     to authenticated, service_role;
