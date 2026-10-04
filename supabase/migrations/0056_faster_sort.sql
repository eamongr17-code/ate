-- 0056_faster_sort.sql
-- Ate backend — FASTER LOGGING. Two server-internal helpers for sort-entry; nothing a client calls.
--
--   sort_preview_cache.plan → NULLABLE. A row with plan IS NULL is a PENDING claim: a preview has
--                        started the model call for that (author, cache_key) and has not stored its
--                        plan yet. The real sort after Done that finds it WAITS for the plan instead
--                        of making a second, simultaneous model call (the double spend 0039 left
--                        open). A claim older than p_pending_seconds is stale (the preview died) and
--                        is treated as absent. Readers written before this file select `plan` and
--                        coerce null to a miss, so an older function deploy stays correct.
--
--   sort_preview_claim(author, key, model, claim, pending_seconds) → jsonb {state, plan}
--                        state: 'hit' (plan ready) · 'pending' (fresh claim, no plan yet) ·
--                        'claimed' (p_claim and nothing usable was there: this caller now owns the
--                        key and must store or release it) · 'none' (p_claim = false, nothing usable).
--                        Atomic: the claim is an INSERT ... ON CONFLICT on the table's PRIMARY KEY (a
--                        TOTAL unique — landmine 1), taking over only an expired row or a stale claim.
--
--   sort_entry_context(entry_id) → jsonb: the entry row sort-entry needs, plus — for a USER-pinned
--                        place — that place's name and menu (≤ 300 live dish names), plus the
--                        sorter-owned lines that hold a 6 (0044's carry input). One round trip where
--                        the function made four serial ones. null when the entry does not exist.
--
-- ACCESS: both functions are service_role only (the function's admin client), like 0039's.
-- WIRE IMPACT: none for clients. (sort-entry's response gains `entry_card` — additive, documented in
-- integration-design.md; that is the function, not this file.)

set search_path = public, extensions;

-- ===========================================================================
-- 1. Pending claims in the preview cache.
-- ===========================================================================
alter table public.sort_preview_cache alter column plan drop not null;

comment on column public.sort_preview_cache.plan is
  '0039: the model''s RAW plan for the draft. 0056: NULL = a pending claim (a preview is calling the model now); the real sort waits for it rather than calling the model a second time. Stale after sort_preview_claim''s p_pending_seconds.';

create or replace function public.sort_preview_claim(
  p_author_id       uuid,
  p_cache_key       text,
  p_model           text    default null,
  p_claim           boolean default true,
  p_pending_seconds integer default 15
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_stale   interval := make_interval(secs => least(greatest(coalesce(p_pending_seconds, 15), 1), 300));
  v_claimed boolean;
  v_plan    jsonb;
  v_created timestamptz;
begin
  if p_claim then
    insert into public.sort_preview_cache as c (author_id, cache_key, plan, model, created_at, expires_at)
      values (p_author_id, p_cache_key, null, p_model, now(), now() + interval '15 minutes')
      on conflict (author_id, cache_key) do update
        set plan = null, model = excluded.model, created_at = excluded.created_at, expires_at = excluded.expires_at
        -- only take over what nobody can use: an expired row, or a claim whose preview died
        where c.expires_at <= now() or (c.plan is null and c.created_at <= now() - v_stale)
      returning true into v_claimed;
    if v_claimed then
      return jsonb_build_object('state', 'claimed', 'plan', null);
    end if;
  end if;

  select c.plan, c.created_at into v_plan, v_created
    from public.sort_preview_cache c
   where c.author_id = p_author_id and c.cache_key = p_cache_key and c.expires_at > now();

  if found and v_plan is not null then
    return jsonb_build_object('state', 'hit', 'plan', v_plan);
  end if;
  if found and v_created > now() - v_stale then
    return jsonb_build_object('state', 'pending', 'plan', null);
  end if;
  return jsonb_build_object('state', 'none', 'plan', null);
end; $$;

comment on function public.sort_preview_claim(uuid, text, text, boolean, integer) is
  '0056: preview-cache state for (author, key) — hit | pending | claimed | none. p_claim = true (a preview about to call the model) atomically inserts a pending row unless a usable plan or a fresh claim is there. p_claim = false (the real sort) only reads. service_role only.';

revoke all on function public.sort_preview_claim(uuid, text, text, boolean, integer) from public, anon, authenticated;
grant execute on function public.sort_preview_claim(uuid, text, text, boolean, integer) to service_role;

-- ===========================================================================
-- 2. Everything the sort reads about an entry before the model, in one trip.
-- ===========================================================================
create or replace function public.sort_entry_context(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object(
    'entry', jsonb_build_object(
      'id', e.id, 'author_id', e.author_id, 'body', e.body, 'restaurant_id', e.restaurant_id,
      'restaurant_source', e.restaurant_source, 'sort_status', e.sort_status, 'sort_plan', e.sort_plan),
    -- the pinned place (user-chosen only: a sorter-matched place is re-resolved from the words)
    'place_name', r.name,
    'known_dishes', case when r.id is null then null else coalesce((
      select jsonb_agg(d.name)
      from (select x.name from public.dishes x
             where x.restaurant_id = r.id and x.merged_into_dish_id is null
             limit 300) d), '[]'::jsonb) end,
    'prior_sixes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dish_name', d.name, 'mention_text', v.mention_text, 'mention_offset', v.mention_offset,
               'score_evidence', v.score_evidence, 'evidence_offset', v.evidence_offset)
             order by v.entry_position nulls last, v.created_at, v.id)
      from public.reviews v
      left join public.dishes d on d.id = v.dish_id
      where v.entry_id = e.id and v.score = 6 and v.corrected_at is null), '[]'::jsonb)
  )
  from public.entries e
  left join public.restaurants r
    on r.id = e.restaurant_id and e.restaurant_source = 'user'
  where e.id = p_entry_id;
$$;

comment on function public.sort_entry_context(uuid) is
  '0056: sort-entry''s pre-model reads in one trip — {entry, place_name, known_dishes (user-pinned place only, else null), prior_sixes}. null for an unknown entry. service_role only.';

revoke all on function public.sort_entry_context(uuid) from public, anon, authenticated;
grant execute on function public.sort_entry_context(uuid) to service_role;
