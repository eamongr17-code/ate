-- 0044_six_carry.sql
-- Ate backend — round 4 fix (QA on PR #71): A RE-SORT MUST NOT WIPE A MARKED 6.
--
-- apply_entry_sort rebuilds every line the user has not corrected, and three client paths re-sort
-- WITHOUT six_tokens (a tag added in Entry edit, "Print it again", the pending/failed retry). The six
-- the user marked on the first sort was therefore lost: "Tiramisu 6 and the gnocchi 4 GF" went from
-- Tiramisu 6 to unscored after a tag-only re-sort.
--
-- The fix carries it SERVER-SIDE, exactly the way 0036 carries tags (T3): the lines about to be
-- replaced are remembered (now also when they hold a 6, with where its evidence sat); a rebuilt line
-- that matches its predecessor (same dish name, same mention, or same evidence — first unclaimed wins)
-- and arrives with NO score keeps the 6 — but ONLY while the body still says that evidence at that
-- same span. That preserves an earlier user mark and infers nothing: a 6 edited out of the words (or
-- moved by an edit in front of it) drops, and a typed "6" is still never a score. The parked plan of a
-- placeless entry carries the same way. sort-entry applies the same rule before its gate (six.ts
-- carriedSixTokens), so the plan it returns already shows the 6; this is the rule of record.
--
-- Same signature ⇒ create or replace; the body is 0041's verbatim but for the prior-line capture and
-- the carry inside T3. WIRE IMPACT: none (behavioural fix: a re-sort without six_tokens keeps a 6).

set search_path = public, extensions;


create or replace function public.apply_entry_sort(
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
  -- 0044
  v_p_ev        text;
  v_p_off       int;
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
  -- 0044: …and a marked 6 (score + where its evidence sat), carried on the same match.
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', lower(d.name), 'mention', lower(r.mention_text),
           'evidence', r.score_evidence, 'tags', to_jsonb(r.tags),
           'six', r.score = 6, 'offset', r.evidence_offset)
         order by r.entry_position nulls last, r.created_at, r.id), '[]'::jsonb)
    into v_prior
  from public.reviews r
  join public.dishes d on d.id = r.dish_id
  where r.entry_id = p_entry_id and r.corrected_at is null and (r.tags <> '{}'::text[] or r.score = 6);

  if not exists (select 1 from public.reviews r where r.entry_id = p_entry_id)
     and jsonb_typeof(v_entry.sort_plan) = 'array' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'name', lower(btrim(x.item ->> 'dish_name')), 'mention', lower(x.item ->> 'mention_text'),
             'evidence', x.item ->> 'score_evidence',
             'tags', to_jsonb(public.dish_tags_from_json(x.item -> 'tags')),
             'six', (x.item ->> 'score') in ('6', '6.0'),
             'offset', case when (x.item ->> 'evidence_offset') ~ '^\d{1,9}$' then (x.item ->> 'evidence_offset')::int end)
           order by x.ord), '[]'::jsonb)
      into v_prior
    from jsonb_array_elements(v_entry.sort_plan) with ordinality as x(item, ord)
    where cardinality(public.dish_tags_from_json(x.item -> 'tags')) > 0
       or (x.item ->> 'score') in ('6', '6.0');
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

    -- 0041: 0.5-5.0 in half steps, or THE SECRET 6. sort-entry proposes a 6 only on a span the
    -- client marked (six_tokens); this gate is the backstop: a 6 must be evidenced by a "6".
    if v_score is not null
       and not (v_score = 6 or (v_score >= 0.5 and v_score <= 5.0 and (v_score * 2) = floor(v_score * 2))) then
      v_score := null;
    end if;
    if v_score = 6 and (v_evidence is null or position('6' in v_evidence) = 0) then
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
        -- 0044 SIX CARRY: the replaced line held a user-marked 6 and this one has no score. Keep the
        -- 6 only while the words still say it AT THE SAME SPAN — an earlier mark, preserved; never a
        -- 6 read off the prose. Edited out (or moved) → dropped.
        if v_score is null and (v_prior -> (v_prior_ix - 1)::int ->> 'six')::boolean then
          v_p_ev  := v_prior -> (v_prior_ix - 1)::int ->> 'evidence';
          v_p_off := (v_prior -> (v_prior_ix - 1)::int ->> 'offset')::int;
          if v_p_ev is not null and v_p_off is not null and position('6' in v_p_ev) > 0
             and substring(v_entry.body from v_p_off + 1 for char_length(v_p_ev)) = v_p_ev then
            v_score    := 6;
            v_evidence := v_p_ev;
            v_e_off    := v_p_off;
          end if;
        end if;
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
  'The sorter''s single transactional write: place + N dish reviews + where each finding sits in the body. PRESERVES every review the user corrected (corrected_at not null) — dish, score, evidence and note — and replaces only the sorter''s own lines, forced or not. Drops any score whose evidence is not a substring of the body (rule 7) and any note that is not (rule 9). Tags (0036): items[].tags are client-marked codes, filtered to the closed set; a re-sort never removes a tag. p_meta (0039) → entries.sort_meta ({cache_hit, model}). Scores 0.5-5.0 in half steps, or 6 evidenced by a "6" (0041); a re-sort keeps a replaced line''s 6 while the body still says it at the same span (0044). service_role only.';

revoke all on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int, jsonb) from public, anon, authenticated;
grant execute on function public.apply_entry_sort(uuid, uuid, jsonb, text, text, int, jsonb) to service_role;
