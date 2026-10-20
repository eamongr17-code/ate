-- 0074_diet.sql
-- Ate backend — DIET: what you always eat, stamped on every dish you log (Eamon, design/rebuild/diet.html).
--
-- A person picks their diet once (first run, then Settings → Diet). Every NEW dish line they log is
-- saved with those codes, unless they turned one off for that dish. Their own screens hide the codes
-- that came from their diet; everyone else sees every code. A DISH is labelled once enough different
-- people mark it. The vocabulary is 0036's closed set (gf · df · v · vg · nf) and its canonicaliser.
--
--   profiles.diet     text[] NOT NULL DEFAULT '{}'   canonical, closed set (CHECK profiles_diet_closed_set)
--   reviews.diet_tags text[] NOT NULL DEFAULT '{}'   the codes on this line that came from the author's
--                                                    diet. Always ⊆ tags (CHECK reviews_diet_tags_in_tags).
--   reviews.diet_off  text[] NOT NULL DEFAULT '{}'   diet codes the author turned off on this line.
--
-- WRITES
--   * profiles.diet: the owner's ordinary profile PATCH, `PATCH /rest/v1/profiles?id=eq.<uid>
--     {"diet": ["vg"]}` (profiles_update_self + the column grant below). Stored as sent, canonical:
--     vegan is just `vg` — nothing adds v/df to it. Readable wherever the row is (profiles_select_visible);
--     no read surfaces it to anyone else.
--   * reviews.diet_tags / diet_off are SERVER-OWNED. A client's direct write of either is ignored
--     (INSERT → {}, UPDATE → derived from its tags, rule D3). They change only through the rules below.
--
-- THE DIET RULE
--   D1. STAMP AT SAVE. When apply_entry_sort makes a NEW line (not one inherited under T3, not a
--       corrected one): tags := tags ∪ (diet − off), diet_tags := diet − off, diet_off := off − tags,
--       where diet = the author's profiles.diet at that moment and off = the codes the client turned off
--       for that dish in Compose (sort-entry `diet_off_tokens` → items[].diet_off, ∩ diet). A changed diet
--       therefore reaches only dishes logged afterwards.
--   D2. A RE-SORT NEVER RE-STAMPS. An inherited (T3) or corrected line keeps its tags, diet_tags and
--       diet_off. T3 now matches against EVERY line it replaces (0036 matched only tagged ones), so a
--       line logged before the author had a diet stays unstamped through any edit. Exception, explicit:
--       a code the client turns off this time leaves the line's diet-sourced tags (into diet_off).
--   D3. TURNING OFF AFTER SAVE is the existing tags PATCH. On every write (trigger reviews_tags_diet):
--       a code leaving tags that was in diet_tags moves to diet_off; a code in diet_off that comes back
--       into tags moves back to diet_tags; diet_tags := diet_tags ∩ tags, always.
--
-- THE DISH LABEL (replaces 0036's "at least half of the lines" everywhere it is computed — dish_summary,
-- place_dishes, search, the tag chips/pages and their filters all read dish_consensus_tags):
--   Per code c, over the dish's lines the viewer can see created within dish_label_window() (12 months):
--     people(c) = distinct authors whose line carries c, where vg also counts as v and as df;
--     vetoed(c) = some line has c in its diet_off (literally c: turning off vg does not veto v or df).
--   c is a label when people(c) ≥ dish_label_min_people() (3) and not vetoed(c).
--   dish_summary.diet_counts / place_dishes.diet_counts = {c: people(c)} for 0 < people(c) < 3.
--
-- WIRE IMPACT
--   ADDITIVE: profiles.diet; entry_cards.items[].diet_tags ([] when none); dish_summary.diet_counts and
--   place_dishes.diet_counts (jsonb, appended OUT columns, {} when none); sort-entry `diet_off_tokens`
--   (optional request field) and items[].diet_off on its response; sort_plan items gain diet_tags /
--   diet_off.
--   BEHAVIOURAL: dish_summary.tags / place_dishes.tags / search_dishes.tags / dish_tags diet chips and
--   every diet filter now follow the label rule above (same columns, same types).
--   INTERNAL: dish_summary and place_dishes change OUT columns ⇒ DROP-then-CREATE (landmine 7), both
--   browse twins with them, grants restored exactly. apply_entry_sort / correct_entry_place /
--   dish_consensus_tags / place_has_tagged_dish / tag_dish_ids / dishes_by_tag keep their signatures
--   (create or replace, no second overload).
--
-- Forward-only. No data is rewritten: every existing profile and line reads {}.

set search_path = public, extensions;

-- ===========================================================================
-- 1. The constants and the vegan rule, once.
-- ===========================================================================
create or replace function public.dish_label_min_people()
returns int
language sql
immutable
parallel safe
set search_path = public, extensions
as $$ select 3 $$;

comment on function public.dish_label_min_people() is
  'A dish is labelled with a diet code once at least this many different people mark it (0074).';

create or replace function public.dish_label_window()
returns interval
language sql
immutable
parallel safe
set search_path = public, extensions
as $$ select interval '12 months' $$;

comment on function public.dish_label_window() is
  'The dish label counts only lines created within this window (0074).';

-- What a line's tags COUNT AS: vegan is also vegetarian and dairy free. For counting only — nothing
-- is ever stored expanded.
create or replace function public.diet_tags_implied(p_tags text[])
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select public.dish_tags_canonical(
    coalesce(p_tags, '{}'::text[])
    || case when 'vg' = any(coalesce(p_tags, '{}'::text[])) then array['v', 'df']::text[] else '{}'::text[] end);
$$;

comment on function public.diet_tags_implied(text[]) is
  'A line''s tags as the dish label counts them: vg also counts as v and df (0074). Canonical; never stored.';

-- The inverse, for line pre-filters: the codes whose presence on a line counts toward p_code.
create or replace function public.diet_codes_counting_as(p_code text)
returns text[]
language sql
immutable
parallel safe
set search_path = public, extensions
as $$
  select case lower(btrim(coalesce(p_code, '')))
           when 'v'  then array['v', 'vg']::text[]
           when 'df' then array['df', 'vg']::text[]
           else array[lower(btrim(coalesce(p_code, '')))]::text[]
         end;
$$;

comment on function public.diet_codes_counting_as(text) is
  'Line codes that count toward p_code on the dish label: v ← {v, vg}, df ← {df, vg}, else just itself (0074).';

revoke all on function public.dish_label_min_people()      from public, anon;
revoke all on function public.dish_label_window()          from public, anon;
revoke all on function public.diet_tags_implied(text[])    from public, anon;
revoke all on function public.diet_codes_counting_as(text) from public, anon;
grant execute on function public.dish_label_min_people()      to authenticated, service_role;
grant execute on function public.dish_label_window()          to authenticated, service_role;
grant execute on function public.diet_tags_implied(text[])    to authenticated, service_role;
grant execute on function public.diet_codes_counting_as(text) to authenticated, service_role;

-- ===========================================================================
-- 2. profiles.diet — the owner's, written by the ordinary profile PATCH.
-- ===========================================================================
alter table public.profiles
  add column if not exists diet text[] not null default '{}'::text[];

alter table public.profiles
  add constraint profiles_diet_closed_set
  check (diet <@ array['gf', 'df', 'v', 'vg', 'nf']::text[]);

comment on column public.profiles.diet is
  'What this person always eats (0074): subset of {gf,df,v,vg,nf}, canonical, {} = none. Stamped on every NEW dish line they log (reviews.diet_tags). Stored as picked: vegan is vg alone. Owner-written via profile PATCH.';

create or replace function public.trg_profile_diet_canonical()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  new.diet := public.dish_tags_canonical(new.diet);
  return new;
end; $$;

drop trigger if exists profiles_diet_canonical on public.profiles;
create trigger profiles_diet_canonical
  before insert or update of diet on public.profiles
  for each row execute function public.trg_profile_diet_canonical();

revoke execute on function public.trg_profile_diet_canonical() from public, anon, authenticated;

-- 0035 narrowed profile UPDATE to a column list; diet joins it.
grant update (diet) on public.profiles to authenticated;

-- ===========================================================================
-- 3. reviews.diet_tags / diet_off — storage, CHECKs, and rule D3.
-- ===========================================================================
alter table public.reviews
  add column if not exists diet_tags text[] not null default '{}'::text[],
  add column if not exists diet_off  text[] not null default '{}'::text[];

alter table public.reviews
  add constraint reviews_diet_tags_closed_set check (diet_tags <@ array['gf', 'df', 'v', 'vg', 'nf']::text[]),
  add constraint reviews_diet_off_closed_set  check (diet_off  <@ array['gf', 'df', 'v', 'vg', 'nf']::text[]),
  add constraint reviews_diet_tags_in_tags    check (diet_tags <@ tags);

comment on column public.reviews.diet_tags is
  'The codes on this line that came from the author''s diet (0074): always ⊆ tags, canonical, {} when none. The app hides these from the author on their own screens. Server-owned.';
comment on column public.reviews.diet_off is
  'Diet codes the author turned off on this line (0074): in Compose, or by removing a diet-sourced tag later. A code here vetoes that code''s dish label. Server-owned.';

-- SECURITY INVOKER on purpose: current_user tells a client's write (authenticated) from the server's
-- (apply_entry_sort / correct_entry_place run as their owner). Runs after reviews_tags_canonical
-- (trigger names fire in order), so NEW.tags is already canonical.
create or replace function public.trg_review_diet()
returns trigger
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_removed text[];
  v_back    text[];
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.diet_tags := '{}'::text[];
      new.diet_off  := '{}'::text[];
    else
      new.diet_tags := old.diet_tags;
      new.diet_off  := old.diet_off;
    end if;
  end if;
  new.diet_tags := public.dish_tags_canonical(new.diet_tags);
  new.diet_off  := public.dish_tags_canonical(new.diet_off);

  -- D3: a diet code leaving tags is turned off; a turned-off code coming back is the diet's again.
  v_removed := array(select c from unnest(new.diet_tags) c where not (c = any(new.tags)));
  v_back    := array(select c from unnest(new.diet_off)  c where c = any(new.tags));
  new.diet_tags := public.dish_tags_canonical(
    array(select c from unnest(new.diet_tags) c where c = any(new.tags)) || v_back);
  new.diet_off  := public.dish_tags_canonical(
    array(select c from unnest(new.diet_off) c where not (c = any(v_back))) || v_removed);
  return new;
end; $$;

drop trigger if exists reviews_tags_diet on public.reviews;
create trigger reviews_tags_diet
  before insert or update of tags, diet_tags, diet_off on public.reviews
  for each row execute function public.trg_review_diet();

revoke execute on function public.trg_review_diet() from public, anon, authenticated;

-- ===========================================================================
-- 4. apply_entry_sort — 0053's body verbatim, plus THE DIET RULE D1/D2 (marked "0074").
-- Same signature ⇒ create or replace; no second overload.
--
-- p_items elements gain an OPTIONAL `diet_off` (jsonb array of codes). Absent = [].
-- ===========================================================================
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
  v_prior       jsonb := '[]'::jsonb;   -- the lines being replaced (T3); 0074: every one of them
  v_prior_ix    bigint;
  v_prior_taken bigint[] := '{}';
  -- 0044
  v_p_ev        text;
  v_p_off       int;
  v_p_at        int;
  -- 0053
  v_styles      text[];
  -- 0074
  v_diet        text[];                 -- the author's diet, read once
  v_off         text[];                 -- codes turned off on this line now (∩ v_diet)
  v_diet_tags   text[];
  v_diet_off    text[];
  v_inherited   boolean;
  v_prior_diet  text[];
begin
  select * into v_entry from public.entries where id = p_entry_id for update;
  if v_entry.id is null then
    raise exception 'entry % not found', p_entry_id using errcode = '02000';
  end if;

  -- 0074: D1 stamps NEW lines with the diet as it is now.
  select p.diet into v_diet from public.profiles p where p.id = v_entry.author_id;
  v_diet := coalesce(v_diet, '{}'::text[]);

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

  -- T3: remember the lines about to be replaced, in receipt order. An entry with
  -- no lines at all (placeless) inherits from its parked plan instead.
  -- 0044: …and a marked 6 (its evidence, and where it sat relative to the dish's mention).
  -- 0074: EVERY replaced line (not only tagged ones) with its diet_tags / diet_off, so a rebuilt
  -- line is never re-stamped (D2).
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', lower(d.name), 'mention', lower(r.mention_text),
           'evidence', r.score_evidence, 'tags', to_jsonb(r.tags),
           'six', r.score = 6, 'offset', r.evidence_offset, 'moffset', r.mention_offset,
           'diet_tags', to_jsonb(r.diet_tags), 'diet_off', to_jsonb(r.diet_off))
         order by r.entry_position nulls last, r.created_at, r.id), '[]'::jsonb)
    into v_prior
  from public.reviews r
  join public.dishes d on d.id = r.dish_id
  where r.entry_id = p_entry_id and r.corrected_at is null;

  if not exists (select 1 from public.reviews r where r.entry_id = p_entry_id)
     and jsonb_typeof(v_entry.sort_plan) = 'array' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'name', lower(btrim(x.item ->> 'dish_name')), 'mention', lower(x.item ->> 'mention_text'),
             'evidence', x.item ->> 'score_evidence',
             'tags', to_jsonb(public.dish_tags_from_json(x.item -> 'tags')),
             'six', (x.item ->> 'score') in ('6', '6.0'),
             'offset', case when (x.item ->> 'evidence_offset') ~ '^\d{1,9}$' then (x.item ->> 'evidence_offset')::int end,
             'moffset', case when (x.item ->> 'mention_offset') ~ '^\d{1,9}$' then (x.item ->> 'mention_offset')::int end,
             'diet_tags', to_jsonb(public.dish_tags_from_json(x.item -> 'diet_tags')),
             'diet_off', to_jsonb(public.dish_tags_from_json(x.item -> 'diet_off')))
           order by x.ord), '[]'::jsonb)
      into v_prior
    from jsonb_array_elements(v_entry.sort_plan) with ordinality as x(item, ord)
    where btrim(coalesce(x.item ->> 'dish_name', '')) <> '';
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
    -- 0053: the sorter's style words for this dish (validated; never a score, never the user's words)
    v_styles := public.dish_styles_from_json(v_item -> 'styles');
    -- 0074: diet codes the client turned off for this dish — only codes of the author's diet count.
    v_off := array(select c from unnest(public.dish_tags_from_json(v_item -> 'diet_off')) c
                   where c = any(v_diet));
    v_inherited := false;

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
      -- 0074 D2: never re-stamped. A diet code turned off now leaves its diet-sourced tags; the
      -- trigger (D3) moves it to diet_off. One turned off that it did not carry is recorded too.
      v_tags := array(select c from unnest(v_tags) c
                      where not (c = any(v_off) and c = any(v_keep.diet_tags)));
      v_diet_off := public.dish_tags_canonical(
        v_keep.diet_off || array(select c from unnest(v_off) c where not (c = any(v_tags))));
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
             tags            = v_tags,
             diet_off        = v_diet_off
       where id = v_keep.id
      returning diet_tags, diet_off into v_diet_tags, v_diet_off;

      v_validated := v_validated || jsonb_build_object(
        'dish_name', v_name, 'score', v_score, 'score_evidence', v_evidence,
        'note', v_note, 'position', v_pos,
        'evidence_offset', v_e_off, 'mention_text', v_mention, 'mention_offset', v_m_off,
        'tags', to_jsonb(v_tags),
        'styles', to_jsonb(v_styles),
        'diet_tags', to_jsonb(v_diet_tags),
        'diet_off', to_jsonb(v_diet_off),
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
      -- 0074: every replaced line is a candidate now, so the STRONGEST match wins before position:
      -- same dish name, then same mention, then same score evidence. A weaker match also passes over
      -- a line some item of this sort names outright (that item will claim it by name).
      order by case
                 when p.e ->> 'name' = lower(v_name) then 0
                 when v_mention is not null and p.e ->> 'mention' = lower(v_mention) then 1
                 else 2
               end,
               (p.e ->> 'name' <> lower(v_name)
                and exists (select 1 from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i
                            where lower(btrim(coalesce(i ->> 'dish_name', ''))) = p.e ->> 'name')),
               p.ord
      limit 1;
      if v_prior_ix is not null then
        v_prior_taken := v_prior_taken || v_prior_ix;
        v_tags := public.dish_tags_from_json(
          to_jsonb(public.dish_tags_from_json(v_prior -> (v_prior_ix - 1)::int -> 'tags') || v_tags));
        -- 0074 D2: inherited, so never re-stamped: its diet_tags / diet_off come with it, less any
        -- code turned off now (which leaves its diet-sourced tags, into diet_off).
        v_inherited  := true;
        v_prior_diet := public.dish_tags_from_json(v_prior -> (v_prior_ix - 1)::int -> 'diet_tags');
        v_tags := array(select c from unnest(v_tags) c
                        where not (c = any(v_off) and c = any(v_prior_diet)));
        v_diet_tags := array(select c from unnest(v_prior_diet) c where c = any(v_tags));
        v_diet_off  := public.dish_tags_canonical(
          public.dish_tags_from_json(v_prior -> (v_prior_ix - 1)::int -> 'diet_off')
          || array(select c from unnest(v_off) c where not (c = any(v_tags))));
        -- 0044 SIX CARRY, keyed to the LINE: the replaced line held a user-marked 6 and this rebuilt
        -- line (matched to it above, as tags are) has no score. Its score-evidence span sat a fixed
        -- distance from its dish's mention; if the words at that distance from THIS line's mention
        -- still read the evidence — a lone 6 — the 6 stays, wherever the line now sits. An earlier
        -- mark, preserved; never a 6 read off the prose. Changed (the new score wins) or removed → gone.
        if v_score is null and v_m_off is not null and (v_prior -> (v_prior_ix - 1)::int ->> 'six')::boolean then
          v_p_ev  := v_prior -> (v_prior_ix - 1)::int ->> 'evidence';
          v_p_off := (v_prior -> (v_prior_ix - 1)::int ->> 'offset')::int;
          v_p_at  := v_m_off + v_p_off - (v_prior -> (v_prior_ix - 1)::int ->> 'moffset')::int;
          if v_p_ev is not null and v_p_at is not null and v_p_at >= 0 and position('6' in v_p_ev) > 0
             and substring(v_entry.body from v_p_at + 1 for char_length(v_p_ev)) = v_p_ev
             and (v_p_at = 0 or substring(v_entry.body from v_p_at for 1) !~ '[0-9.]')
             and substring(v_entry.body from v_p_at + char_length(v_p_ev) + 1 for 2) !~ '^([0-9]|[.][0-9])' then
            v_score    := 6;
            v_evidence := v_p_ev;
            v_e_off    := v_p_at;
          end if;
        end if;
      end if;
      v_prior_ix := null;
    end if;

    -- ---- 0074 D1: a NEW line takes the author's diet, less what was turned off -----
    if not v_inherited then
      v_diet_tags := array(select c from unnest(v_diet) c where not (c = any(v_off)));
      v_tags      := public.dish_tags_canonical(v_tags || v_diet_tags);
      v_diet_off  := array(select c from unnest(v_off) c where not (c = any(v_tags)));
    end if;
    v_diet_tags := public.dish_tags_canonical(v_diet_tags);
    v_diet_off  := public.dish_tags_canonical(v_diet_off);

    v_validated := v_validated || jsonb_build_object(
      'dish_name', v_name, 'score', v_score, 'score_evidence', v_evidence,
      'note', v_note, 'position', v_pos,
      'evidence_offset', v_e_off, 'mention_text', v_mention, 'mention_offset', v_m_off,
      'tags', to_jsonb(v_tags),
      'styles', to_jsonb(v_styles),
      'diet_tags', to_jsonb(v_diet_tags),
      'diet_off', to_jsonb(v_diet_off),
      'preserved', false
    );

    -- no place ⇒ no dish rows possible; the plan above is the record.
    if v_rid is not null then
      v_dish := public.find_or_create_dish(v_rid, v_name, v_entry.author_id);
      insert into public.reviews
        (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, score_evidence,
         note, evidence_offset, mention_text, mention_offset, created_at, tags, diet_tags, diet_off)
      values
        (v_entry.author_id, v_dish, v_rid, p_entry_id, v_pos, v_score, v_evidence,
         v_note, v_e_off, v_mention, v_m_off, v_entry.created_at, v_tags, v_diet_tags, v_diet_off);
      -- 0053: the dish's style tags (replacing its keyword guesses; never more than 3)
      perform public.dish_apply_sorter_styles(v_dish, v_styles);
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
  'The sorter''s single transactional write: place + N dish reviews + where each finding sits in the body. PRESERVES every review the user corrected (corrected_at not null) — dish, score, evidence and note — and replaces only the sorter''s own lines, forced or not. Drops any score whose evidence is not a substring of the body (rule 7) and any note that is not (rule 9). Tags (0036): items[].tags are client-marked codes, filtered to the closed set; a re-sort never removes a tag. p_meta (0039) → entries.sort_meta ({cache_hit, model}). Scores 0.5-5.0 in half steps, or 6 evidenced by a "6" (0041); a re-sort keeps a replaced line''s 6 while the rebuilt line''s evidence span (same distance from its mention) still reads it (0044). items[].styles (0053): ≤3 style words per new line''s dish (dish_apply_sorter_styles), kept in the parked plan. Diet (0074): a NEW line is stamped with the author''s profiles.diet less items[].diet_off (tags ∪, diet_tags, diet_off); inherited and corrected lines are never re-stamped, and lose only a diet code turned off now. service_role only.';

-- ===========================================================================
-- 5. correct_entry_place — 0053's body verbatim, plus the parked plan's diet_tags / diet_off
-- (stamped when the entry was sorted; marked "0074").
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
         note, evidence_offset, mention_text, mention_offset, created_at, tags, diet_tags, diet_off)
      values
        (v_entry.author_id, v_dish, p_restaurant_id, p_entry_id, v_pos, v_score, v_evid,
         v_note, v_e_off, v_ment, v_m_off, v_entry.created_at,
         public.dish_tags_from_json(v_item -> 'tags'),
         -- 0074: the plan's diet stamp (made at sort time); a pre-0074 plan has none → {}
         public.dish_tags_from_json(v_item -> 'diet_tags'),
         public.dish_tags_from_json(v_item -> 'diet_off'));
      -- 0053: the parked plan's style tags, onto the dish it now prints
      perform public.dish_apply_sorter_styles(v_dish, public.dish_styles_from_json(v_item -> 'styles'));
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

-- ===========================================================================
-- 6. entry_cards — 0058's view verbatim, with `diet_tags` appended inside each items[] object.
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
      'locality', public.place_locality(r.address, r.city)
    ) end as place,
    coalesce(ph.photos, '[]'::jsonb) as photos,
    coalesce(ph.photo_count, 0)      as photo_count,
    coalesce(it.items, '[]'::jsonb)  as items,
    coalesce(it.dish_count, 0)       as dish_count,
    it.avg_score,
    e.place_offset,
    char_length(e.place_query) as place_length,
    -- 0058: "ate with" — see entry_with_people.
    public.entry_with_people(e.id) as companions
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
        'cover_url', public.dish_cover_url(v.dish_id),
        'tags', to_jsonb(v.tags),
        -- 0074: which of `tags` came from the author's diet ([] when none) — the app hides these
        -- from the author on their own screens; everyone else sees every tag.
        'diet_tags', to_jsonb(v.diet_tags)
      ) order by v.entry_position nulls last, v.created_at, v.id) as items,
      count(*)::int as dish_count,
      round(avg(v.score), 2)::numeric(3,2) as avg_score
    from public.reviews v
    join public.dishes d on d.id = v.dish_id
    left join public.saves s on s.dish_id = v.dish_id and s.user_id = (select auth.uid())
    where v.entry_id = e.id
  ) it on true;

comment on view public.entry_cards is
  'The one entry shape for Journal slip / Feed slip / Entry page / Share receipt: entry + author + place (+ locality, 0035) + photos[] + items[] (each with the dish''s cover_url, its dietary tags[], 0036, and which of them came from the author''s diet, diet_tags[], 0074) + receipt footer (dish_count, avg_score over scored items) + where each finding sits in body (0-based UNICODE SCALAR offsets) + companions[] (0058, "ate with"). Read a single entry with get_entry_card; page lists via get_entry_feed / get_entries_by_author / get_entries_at_place.';

-- ===========================================================================
-- 7. THE DISH LABEL — one tally, two readers.
--
-- SECURITY INVOKER, like 0036's consensus: "visible" is the viewer's RLS on reviews, so a blocked
-- author's lines count for nobody but themselves. Signed out reads arrive through the browse twins.
-- ===========================================================================
create or replace function public.dish_diet_tally(p_dish_id uuid)
returns table (code text, ord int, people int, vetoed boolean)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select c.code,
         c.ord::int,
         (count(distinct v.reviewer_id)
            filter (where c.code = any(public.diet_tags_implied(v.tags))))::int,
         coalesce(bool_or(c.code = any(v.diet_off)), false)
  from unnest(public.dish_tag_codes()) with ordinality as c(code, ord)
  left join public.reviews v
    on v.dish_id = p_dish_id
   and v.created_at > now() - public.dish_label_window()
  group by c.code, c.ord;
$$;

comment on function public.dish_diet_tally(uuid) is
  'Per diet code, over the dish''s visible lines created within dish_label_window(): people = distinct authors whose line carries it (vg also counts as v and df), vetoed = some line has it in diet_off (0074). Viewer-relative.';

-- 0036's name and signature, 0074's rule: every caller (dish_summary, place_dishes, search_dishes,
-- dish_tags, place_has_tagged_dish, tag_dish_ids, dishes_by_tag) follows at once.
create or replace function public.dish_consensus_tags(p_dish_id uuid)
returns text[]
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(array_agg(t.code order by t.ord), '{}'::text[])
  from public.dish_diet_tally(p_dish_id) t
  where t.people >= public.dish_label_min_people() and not t.vetoed;
$$;

comment on function public.dish_consensus_tags(uuid) is
  'The dish''s diet LABELS (0074, replacing 0036''s half-of-lines rule): codes marked by at least dish_label_min_people() different people within dish_label_window() (vg counts as v and df) that no line has turned off. Canonical order; {} when none. Viewer-relative.';

create or replace function public.dish_diet_counts(p_dish_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(jsonb_object_agg(t.code, t.people), '{}'::jsonb)
  from public.dish_diet_tally(p_dish_id) t
  where t.people > 0 and t.people < public.dish_label_min_people();
$$;

comment on function public.dish_diet_counts(uuid) is
  'Below the label (0074): {code: people} for codes 0 < people < dish_label_min_people() — the "Ordered by N … eaters" line. {} when none. Viewer-relative.';

revoke all on function public.dish_diet_tally(uuid)  from public, anon;
revoke all on function public.dish_diet_counts(uuid) from public, anon;
grant execute on function public.dish_diet_tally(uuid)  to authenticated, service_role;
grant execute on function public.dish_diet_counts(uuid) to authenticated, service_role;

-- ===========================================================================
-- 8. dish_summary + `diet_counts` — 0036's bodies verbatim plus the appended column.
-- New OUT column ⇒ DROP-then-CREATE (landmine 7), the browse twin with it.
-- ===========================================================================
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
  tags                text[],
  -- appended 0074
  diet_counts         jsonb
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
    public.dish_consensus_tags(d.id),
    public.dish_diet_counts(d.id)
  from public.dishes d
  join public.restaurants r on r.id = d.restaurant_id
  left join public.dish_stats ds on ds.dish_id = d.id
  where d.id = p_dish_id;
end;
$$;

comment on function public.dish_summary(uuid) is
  'The dish page header in one call: the dish, its place, viewer-relative aggregates (score NULL = nobody scored it), the photo stack (photos[0].url == cover_url), the viewer''s own save state + last score, the diet labels (`tags`, 0074''s rule: dish_consensus_tags) and, below the label, diet_counts {code: people} for 0 < people < 3 (0074). Signed out → browse.dish_summary. A dish''s "orders" is review_count.';

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
  tags                text[],
  -- appended 0074
  diet_counts         jsonb
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select s.dish_id, s.dish_name, s.restaurant_id, s.restaurant_name, s.restaurant_city, s.score,
         s.review_count, s.scored_count, s.people_count, s.cover_url,
         false, null::numeric(2,1),                    -- saved, my_last_score: no viewer
         s.photos, s.restaurant_locality, s.tags, s.diet_counts
  from public.dish_summary(p_dish_id) s;
$$;

-- Restore exactly the grants the drop took: authenticated (0029) + anon (0034) on the public read;
-- anon only on the browse twin.
revoke all on function public.dish_summary(uuid) from public;
grant execute on function public.dish_summary(uuid) to authenticated, anon, service_role;
revoke all on function browse.dish_summary(uuid) from public;
grant execute on function browse.dish_summary(uuid) to anon;

-- ===========================================================================
-- 9. place_dishes + `diet_counts` — 0051's bodies verbatim plus the appended column.
-- New OUT column ⇒ DROP-then-CREATE (landmine 7), the browse twin first (it is the dependent).
-- ===========================================================================
drop function if exists browse.place_dishes(uuid, int, int, numeric, text, uuid);
drop function if exists public.place_dishes(uuid, int, int, numeric, text, uuid);

create function public.place_dishes(
  p_restaurant_id      uuid,
  p_limit              int     default 50,
  p_cursor_review_count int    default null,
  p_cursor_score       numeric default null,
  p_cursor_dish_name   text    default null,
  p_cursor_dish_id     uuid    default null
)
returns table (
  dish_id      uuid,
  dish_name    text,
  score        numeric(2,1),
  people_count int,
  review_count int,
  cover_url    text,
  tags         text[],
  -- appended 0074
  diet_counts  jsonb
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  if current_user = 'anon' then
    return query select * from browse.place_dishes(p_restaurant_id, p_limit, p_cursor_review_count, p_cursor_score, p_cursor_dish_name, p_cursor_dish_id);
    return;
  end if;

  return query
  select pg.dish_id, pg.dish_name, pg.score, pg.people_count, pg.review_count, pg.cover_url,
         public.dish_consensus_tags(pg.dish_id),
         public.dish_diet_counts(pg.dish_id)
  from (
    select ds.dish_id, d.name as dish_name, ds.score, ds.people_count, ds.review_count, ds.cover_url
    from public.dish_stats ds
    join public.dishes d on d.id = ds.dish_id
    where ds.restaurant_id = p_restaurant_id
      and ds.review_count > 0
      and (
        p_cursor_dish_id is null
        or coalesce(ds.score, -1) < coalesce(p_cursor_score, -1)
        or (coalesce(ds.score, -1) = coalesce(p_cursor_score, -1)
            and ds.review_count < p_cursor_review_count)
        or (coalesce(ds.score, -1) = coalesce(p_cursor_score, -1)
            and ds.review_count = p_cursor_review_count
            and (lower(d.name), ds.dish_id) > (lower(coalesce(p_cursor_dish_name, '')), p_cursor_dish_id))
      )
    order by coalesce(ds.score, -1) desc, ds.review_count desc, lower(d.name), ds.dish_id
    limit least(greatest(p_limit, 1), 200)
  ) pg
  order by coalesce(pg.score, -1) desc, pg.review_count desc, lower(pg.dish_name), pg.dish_id;
end;
$$;

create function browse.place_dishes(
  p_restaurant_id      uuid,
  p_limit              int,
  p_cursor_review_count int,
  p_cursor_score       numeric,
  p_cursor_dish_name   text,
  p_cursor_dish_id     uuid
)
returns table (
  dish_id      uuid,
  dish_name    text,
  score        numeric(2,1),
  people_count int,
  review_count int,
  cover_url    text,
  tags         text[],
  -- appended 0074
  diet_counts  jsonb
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select d.*
  from public.place_dishes(p_restaurant_id, p_limit, p_cursor_review_count, p_cursor_score,
                           p_cursor_dish_name, p_cursor_dish_id) d
  order by coalesce(d.score, -1) desc, d.review_count desc, lower(d.dish_name), d.dish_id;
$$;

comment on function public.place_dishes(uuid, int, int, numeric, text, uuid) is
  '"What to order" (0051): by the printed score desc (a 6 above every 5), tiebreak review_count desc, then name (case-insensitive), then id. Unscored dishes after every scored one (review_count desc, name, id); a dish with NO line is excluded. `tags` = the dish''s diet labels (0074''s rule), diet_counts = {code: people} below the label (0074). Keyset is 4-part — pass p_cursor_score / p_cursor_review_count / p_cursor_dish_name / p_cursor_dish_id from the last row. anon → browse twin.';

-- Restore exactly the grants the drop took (0045).
revoke all on function public.place_dishes(uuid, int, int, numeric, text, uuid) from public;
grant execute on function public.place_dishes(uuid, int, int, numeric, text, uuid) to authenticated, anon;
revoke all on function browse.place_dishes(uuid, int, int, numeric, text, uuid) from public;
grant execute on function browse.place_dishes(uuid, int, int, numeric, text, uuid) to anon;

-- ===========================================================================
-- 10. The line pre-filters in front of the label. Each picked candidate dishes by a line carrying
-- the code LITERALLY; a dish labelled v may have only vg lines, so each now asks for any code that
-- counts toward it (diet_codes_counting_as / diet_tags_implied). Bodies otherwise verbatim.
-- ===========================================================================

-- 0042's place_has_tagged_dish.
create or replace function public.place_has_tagged_dish(p_restaurant_id uuid, p_tags text[])
returns boolean
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select exists (
    select 1
    from (
      select distinct v.dish_id
      from public.reviews v
      where v.restaurant_id = p_restaurant_id
        and public.diet_tags_implied(v.tags) && p_tags
    ) c
    join public.dishes d on d.id = c.dish_id and d.merged_into_dish_id is null
    where public.dish_consensus_tags(c.dish_id) @> p_tags
  );
$$;

-- 0057's tag_dish_ids.
create or replace function public.tag_dish_ids(p_kind text, p_slug text)
returns uuid[]
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
declare
  v_kind text := nullif(lower(btrim(coalesce(p_kind, ''))), '');
  v_slug text := nullif(lower(btrim(coalesce(p_slug, ''))), '');
begin
  if v_kind is null and v_slug is null then
    return null;
  end if;
  if v_kind is null or v_slug is null then
    raise exception 'p_kind and p_slug go together (got %, %)', p_kind, p_slug using errcode = '22023';
  end if;
  if v_kind not in ('style', 'cuisine', 'suburb', 'city', 'diet') then
    raise exception 'p_kind must be style, cuisine, suburb, city or diet (got %)', p_kind using errcode = '22023';
  end if;
  if v_kind = 'diet' then
    -- any dish with a line carrying the code (0074: or one that counts as it), kept only if labelled
    return coalesce(array(
      select distinct v.dish_id from public.reviews v
      where v.tags && public.diet_codes_counting_as(v_slug) and v.dish_id is not null
        and v_slug = any(public.dish_consensus_tags(v.dish_id))), '{}');
  end if;
  return coalesce(array(
    select t.dish_id from public.dish_tag_links t where t.kind = v_kind and t.slug = v_slug), '{}');
end;
$$;

-- 0055's dishes_by_tag. Same signature and OUT columns ⇒ create or replace; grants survive.
create or replace function public.dishes_by_tag(
  p_kind                text,
  p_slug                text,
  p_limit               int     default 30,
  p_cursor_score        numeric default null,
  p_cursor_review_count int     default null,
  p_cursor_name         text    default null,
  p_cursor_dish_id      uuid    default null,
  p_city                text    default null
)
returns table (
  dish_id         uuid,
  name            text,
  restaurant_id   uuid,
  restaurant_name text,
  score           numeric(2,1),
  review_count    int,
  cover_url       text,
  saved           boolean
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_uid    uuid   := auth.uid();
  v_kind   text   := lower(btrim(coalesce(p_kind, '')));
  v_slug   text   := lower(btrim(coalesce(p_slug, '')));
  v_lim    int    := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_places uuid[];
begin
  if v_uid is null then
    raise exception 'signed-in callers only' using errcode = '42501';
  end if;
  if v_kind not in ('style', 'cuisine', 'suburb', 'city', 'diet') then
    raise exception 'p_kind must be style, cuisine, suburb, city or diet (got %)', p_kind using errcode = '22023';
  end if;
  v_places := public.city_places(p_city);

  return query
  with cand as (
    select t.dish_id from public.dish_tag_links t
    where v_kind <> 'diet' and t.kind = v_kind and t.slug = v_slug
    union
    -- diet: any dish with a line carrying the code (0074: or one that counts as it), kept below
    -- only if labelled
    select v.dish_id from public.reviews v
    where v_kind = 'diet' and v.tags && public.diet_codes_counting_as(v_slug)
  ),
  placed as (
    select c.dish_id, d.name, d.restaurant_id
    from cand c
    join public.dishes d on d.id = c.dish_id and d.merged_into_dish_id is null
    where v_places is null or d.restaurant_id = any(v_places)
  ),
  numbered as (
    select c.dish_id, c.name, c.restaurant_id,
           round(avg(v.score), 1)::numeric(2,1) as score,
           count(*)::int as review_count
    from placed c
    join public.reviews v on v.dish_id = c.dish_id
    group by c.dish_id, c.name, c.restaurant_id
  ),
  page as (
    select n.dish_id, n.name, n.restaurant_id, r.name as restaurant_name, n.score, n.review_count
    from numbered n
    join public.restaurants r on r.id = n.restaurant_id
    where (v_kind <> 'diet' or v_slug = any(public.dish_consensus_tags(n.dish_id)))
      and (
        p_cursor_dish_id is null
        or coalesce(n.score, -1) < coalesce(p_cursor_score, -1)
        or (coalesce(n.score, -1) = coalesce(p_cursor_score, -1)
            and n.review_count < p_cursor_review_count)
        or (coalesce(n.score, -1) = coalesce(p_cursor_score, -1)
            and n.review_count = p_cursor_review_count
            and (lower(n.name), n.dish_id) > (lower(coalesce(p_cursor_name, '')), p_cursor_dish_id))
      )
    order by coalesce(n.score, -1) desc, n.review_count desc, lower(n.name), n.dish_id
    limit v_lim
  )
  select p.dish_id, p.name, p.restaurant_id, p.restaurant_name, p.score, p.review_count,
         public.dish_cover_url(p.dish_id),
         exists (select 1 from public.saves s where s.user_id = v_uid and s.dish_id = p.dish_id)
  from page p
  order by coalesce(p.score, -1) desc, p.review_count desc, lower(p.name), p.dish_id;
end;
$$;
