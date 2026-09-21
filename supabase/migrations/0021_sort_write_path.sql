-- 0021_sort_write_path.sql
-- Ate backend — V1 RETHINK: the SORTER's write path, and the user's corrections.
--
-- The sorter (edge function `sort-entry`) never writes tables directly. It calls
-- apply_entry_sort ONCE per entry, transactionally, and the database — not the
-- function, and certainly not the model — is the last line of defence on the two
-- rules that matter most:
--
--   DESIGN rule 7  a score must be the USER'S. apply_entry_sort DROPS any score
--                  whose `score_evidence` is not a literal substring of the entry
--                  body. Stub mode, model mode, a future mode, a malicious
--                  payload — all get the same treatment, because the check is here.
--   DESIGN rule 9  the words are never rewritten. A dish NOTE must be an exact
--                  substring of the body or it is dropped. The sorter may only
--                  QUOTE; it may not paraphrase.
--
-- DISH CREATION uses the mandated SELECT-THEN-INSERT (find_or_create_dish). It must
-- NEVER use ON CONFLICT: `dishes_identity_uq` is a PARTIAL unique index (it excludes
-- merge tombstones) BY DESIGN, and PostgreSQL cannot use a partial index as an
-- ON CONFLICT arbiter — the 0014/0016 incident. The race is handled by catching
-- unique_violation and re-selecting.
--
-- NO PLACE ⇒ NO DISH REVIEWS. `dishes.restaurant_id` is NOT NULL, so an entry with
-- no place cannot own dish rows. Such an entry is still marked `sorted` (its words
-- are the whole record) and the sorter's findings are parked in `entries.sort_plan`,
-- so that attaching a place later (correct_entry_place) can print the receipt
-- retroactively without re-running the sorter. The sorter NEVER creates a
-- restaurant — an unrecognised place name stays unattached until the user taps one.
--
-- WIRE IMPACT: ADDITIVE — RPCs only.
--   service_role : apply_entry_sort, mark_entry_sort_failed  (the edge function)
--   authenticated: correct_entry_place, correct_entry_dish    (the user's fixes)

set search_path = public, extensions;

-- ===========================================================================
-- find_or_create_dish — the ONE dish-creation path. SELECT, then INSERT, then on a
-- race re-SELECT. Case-insensitive on name, matching dishes_identity_uq's
-- (restaurant_id, lower(name)) WHERE merged_into_dish_id IS NULL.
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
  v_name text := btrim(coalesce(p_name, ''));
  v_id   uuid;
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
    return v_id;
  end if;

  begin
    insert into public.dishes (name, restaurant_id, created_by_user_id)
    values (v_name, p_restaurant_id, p_created_by)
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
  'Select-then-insert the live dish (restaurant_id, lower(name)). NEVER ON CONFLICT — dishes_identity_uq is partial by design (0014/0016).';

revoke all on function public.find_or_create_dish(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.find_or_create_dish(uuid, text, uuid) to service_role;

-- ===========================================================================
-- apply_entry_sort — the sorter's single transactional write.
--
-- p_items: ordered jsonb array; each element
--   { "dish_name": text, "score": number|null, "score_evidence": text|null, "note": text|null }
--
-- Semantics:
--   * REPLACES the entry's dish reviews (delete-then-insert). The edge function
--     only sorts entries in status 'pending'/'failed', or when explicitly forced,
--     so this never silently discards a correction the user has since made.
--   * Never touches `body`. Never sets a place the user already chose
--     (restaurant_source='user' wins over the sorter's match).
--   * Stores the VALIDATED plan (post-drop) in sort_plan, not the raw one — what is
--     parked is what would be applied.
-- ===========================================================================
create or replace function public.apply_entry_sort(
  p_entry_id      uuid,
  p_restaurant_id uuid    default null,
  p_items         jsonb   default '[]'::jsonb,
  p_mode          text    default 'stub'
)
returns public.entries
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_entry     public.entries;
  v_rid       uuid;
  v_src       text;
  v_item      jsonb;
  v_name      text;
  v_score     numeric(2,1);
  v_evidence  text;
  v_note      text;
  v_dish      uuid;
  v_pos       smallint := 0;
  v_validated jsonb := '[]'::jsonb;
begin
  select * into v_entry from public.entries where id = p_entry_id for update;
  if v_entry.id is null then
    raise exception 'entry % not found', p_entry_id using errcode = '02000';
  end if;

  -- rule 8: a place the USER attached is authoritative; the sorter may only fill a
  -- gap, never overwrite.
  if v_entry.restaurant_source = 'user' then
    v_rid := v_entry.restaurant_id;
    v_src := 'user';
  elsif p_restaurant_id is not null then
    v_rid := p_restaurant_id;
    v_src := 'sorter';
  else
    v_rid := null;
    v_src := null;
  end if;

  delete from public.reviews where entry_id = p_entry_id;

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

    v_pos := v_pos + 1;
    v_validated := v_validated || jsonb_build_object(
      'dish_name', v_name, 'score', v_score, 'score_evidence', v_evidence,
      'note', v_note, 'position', v_pos
    );

    -- no place ⇒ no dish rows possible; the plan above is the record.
    if v_rid is not null then
      v_dish := public.find_or_create_dish(v_rid, v_name, v_entry.author_id);
      insert into public.reviews
        (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, score_evidence, note, created_at)
      values
        (v_entry.author_id, v_dish, v_rid, p_entry_id, v_pos, v_score, v_evidence, v_note, v_entry.created_at);
    end if;
  end loop;

  update public.entries
     set restaurant_id     = v_rid,
         restaurant_source = v_src,
         sort_status       = 'sorted',
         sort_mode         = p_mode,
         sort_error        = null,
         sorted_at         = now(),
         sort_plan         = v_validated
   where id = p_entry_id
  returning * into v_entry;

  return v_entry;
end; $$;

comment on function public.apply_entry_sort(uuid, uuid, jsonb, text) is
  'The sorter''s single transactional write: place + N dish reviews. Drops any score whose evidence is not a substring of the body (rule 7) and any note that is not a substring (rule 9). service_role only.';

revoke all on function public.apply_entry_sort(uuid, uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.apply_entry_sort(uuid, uuid, jsonb, text) to service_role;

-- ===========================================================================
-- mark_entry_sort_failed — the sorter could not finish. The words still stand; the
-- app shows the entry without a receipt and may retry.
-- ===========================================================================
create or replace function public.mark_entry_sort_failed(p_entry_id uuid, p_error text default null)
returns void
language sql
volatile
security definer
set search_path = public, extensions
as $$
  update public.entries
     set sort_status = 'failed',
         sort_error  = left(coalesce(p_error, 'sort failed'), 500),
         sorted_at   = now()
   where id = p_entry_id;
$$;

revoke all on function public.mark_entry_sort_failed(uuid, text) from public, anon, authenticated;
grant execute on function public.mark_entry_sort_failed(uuid, text) to service_role;

-- ===========================================================================
-- correct_entry_place — the user fixes the place (design/v1/PlaceSheet).
--
-- Two cases, both handled:
--   (a) the entry already has dish reviews → each dish is RE-RESOLVED by its current
--       name at the new restaurant (a dish belongs to a restaurant, so the old rows
--       would otherwise point at the wrong menu).
--   (b) the entry has no dish reviews because it had no place → the parked
--       `sort_plan` is applied now, printing the receipt the user never got.
-- Either way the place becomes restaurant_source='user' and the sorter can never
-- overwrite it again.
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
      -- re-assert rules 7 + 9 against the body AS IT IS NOW: the plan was parked
      -- when the entry was sorted, and the author may have edited their words since.
      if v_score is not null and (v_evid is null or position(v_evid in v_entry.body) = 0) then
        v_score := null;
        v_evid  := null;
      end if;
      if v_note is not null and position(v_note in v_entry.body) = 0 then
        v_note := null;
      end if;

      v_pos  := v_pos + 1;
      v_dish := public.find_or_create_dish(p_restaurant_id, v_name, v_entry.author_id);
      insert into public.reviews
        (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, score_evidence, note, created_at)
      values
        (v_entry.author_id, v_dish, p_restaurant_id, p_entry_id, v_pos, v_score, v_evid, v_note,
         v_entry.created_at);
    end loop;
  end if;

  update public.entries
     set restaurant_id     = p_restaurant_id,
         restaurant_source = 'user',
         sort_status       = 'sorted'
   where id = p_entry_id
  returning * into v_entry;

  return v_entry;
end; $$;

comment on function public.correct_entry_place(uuid, uuid) is
  'Author fixes an entry''s place: re-resolves its dishes at the new restaurant, or applies the parked sort_plan if it had none. Pins restaurant_source=''user''.';

-- ===========================================================================
-- correct_entry_dish — the user fixes one line item (design/v1/DishSheet). Either
-- pick an existing dish at the entry's place (p_dish_id) or name one (p_dish_name).
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
  v_author uuid;
  v_rid    uuid;
  v_dish   uuid;
begin
  select v.reviewer_id, e.restaurant_id into v_author, v_rid
  from public.reviews v
  join public.entries e on e.id = v.entry_id
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

  update public.reviews set dish_id = v_dish where id = p_review_id;
  return v_dish;
end; $$;

comment on function public.correct_entry_dish(uuid, uuid, text) is
  'Author fixes one receipt line''s dish match — pick an existing dish at the place or name a new one. Score/note untouched.';

revoke all on function public.correct_entry_place(uuid, uuid)            from public, anon;
revoke all on function public.correct_entry_dish(uuid, uuid, text)       from public, anon;
grant execute on function public.correct_entry_place(uuid, uuid)          to authenticated, service_role;
grant execute on function public.correct_entry_dish(uuid, uuid, text)     to authenticated, service_role;
