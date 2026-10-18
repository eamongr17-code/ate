-- 0071_dish_dedup.sql
-- SAME DISH, DIFFERENT NAMES (18 Oct, Eamon): "Carbonara" and "Spaghetti Carbonara" at one place
-- are one dish, but a real restaurant has three pastas and three steaks, so nothing here presumes.
-- Always within ONE restaurant.
--
--   1. dish_key(name) — the spelling key (accents, capitals, punctuation, "&"/"and"/"n", "the",
--      plurals, a space inside a compound). Word order is kept. Mirrors sort-entry same-dish.ts
--      dishKey exactly; both are pinned against dish-key-cases.json.
--   2. find_or_create_dish resolves, in order: the live exact name → a MERGED-AWAY exact name (its
--      survivor: a merged name is an alias, so a re-sort cannot recreate the duplicate) → the live
--      same-key dish (oldest) → a merged-away same-key name → a new dish. The model's judgement
--      ("the carbonara" is the Spaghetti Carbonara) happens in sort-entry, behind a gate.
--   3. merge_dish, rebuilt for everything that now points at a dish: reviews (→ lists via 0060's
--      trigger), saves, the legacy list_dishes, and the entries' photo picks (0064, by name). It
--      refuses two places, and two dishes one entry names on separate lines (the diner told them
--      apart). Every merge is logged with what it moved; unmerge_dish puts it back.
--   4. dish_merge_proposals — what the scan (dish-dedup function) suggests for dishes that ALREADY
--      exist. Nothing merges until a person approves the list (merge_dish_proposals).
--
-- Nothing here deletes data. The old two-argument merge_dish had no callers but tests.

set search_path = public, extensions;

-- ===========================================================================
-- 1. The spelling key.
-- ===========================================================================
-- One word, singular; the same rules as same-dish.ts singular(). Consistency, not grammar.
create or replace function public.dish_word_singular(p_word text)
returns text language sql immutable parallel safe set search_path = public, extensions as $$
  select case
    when length(p_word) > 4 and p_word ~ 'ies$'              then left(p_word, -3) || 'i'
    when length(p_word) > 3 and p_word ~ 'ie$'               then left(p_word, -1)
    when length(p_word) > 3 and p_word ~ '[^aeiou]y$'        then left(p_word, -1) || 'i'
    when length(p_word) > 4 and p_word ~ 'oes$'              then left(p_word, -2)
    when length(p_word) > 4 and p_word ~ '(s|x|z|ch|sh)es$'  then left(p_word, -2)
    when length(p_word) > 3 and p_word ~ 's$' and p_word !~ '(ss|us)$' then left(p_word, -1)
    else p_word
  end;
$$;

-- The words of a dish's identity, in order (same-dish.ts dishWords).
create or replace function public.dish_words(p_name text)
returns text[] language plpgsql immutable parallel safe set search_path = public, extensions as $$
declare
  v   text := public.search_key(p_name);             -- trimmed, accent-folded, lower case (0031)
  w   text;
  out text[] := '{}';
begin
  v := replace(v, '&', ' and ');
  foreach w in array regexp_split_to_array(v, '[ \t\n\r\f\v!-%''-/:-@\[-`{-~’‘“”–—·•]+') loop
    continue when w = '';
    w := case w when 'n' then 'and' when 'w' then 'with' else w end;
    continue when w in ('the', 'a', 'an');
    out := out || public.dish_word_singular(w);
  end loop;
  return out;
end; $$;

create or replace function public.dish_key(p_name text)
returns text language sql immutable parallel safe set search_path = public, extensions as $$
  select array_to_string(public.dish_words(p_name), '');
$$;

comment on function public.dish_key(text) is
  '0071: the spelling key — two names with one key are one dish with no judgement involved. Mirrors sort-entry same-dish.ts dishKey (pinned by dish-key-cases.json). '''' for a name with no words.';

create index if not exists dishes_restaurant_key_idx on public.dishes (restaurant_id, public.dish_key(name));

revoke all on function public.dish_word_singular(text) from public, anon;
revoke all on function public.dish_words(text)         from public, anon;
revoke all on function public.dish_key(text)           from public, anon;
grant execute on function public.dish_key(text) to authenticated, service_role;

-- ===========================================================================
-- 2. find_or_create_dish — same contract, the key and the aliases added.
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
  v_key     text;
  v_display text;
  v_id      uuid;
begin
  if p_restaurant_id is null then
    raise exception 'find_or_create_dish requires a restaurant' using errcode = '22023';
  end if;
  if v_name = '' then
    raise exception 'find_or_create_dish requires a dish name' using errcode = '22023';
  end if;
  v_key := public.dish_key(v_name);

  -- the live dish of that exact name: an existing dish keeps its own name
  select d.id into v_id
  from public.dishes d
  where d.restaurant_id = p_restaurant_id
    and lower(d.name) = lower(v_name)
    and d.merged_into_dish_id is null
  limit 1;
  if v_id is not null then
    return v_id;
  end if;

  -- a name merged away is an alias of its survivor
  select public.resolve_dish(d.id) into v_id
  from public.dishes d
  where d.restaurant_id = p_restaurant_id
    and lower(d.name) = lower(v_name)
    and d.merged_into_dish_id is not null
  order by d.created_at, d.id
  limit 1;
  if v_id is not null then
    return v_id;
  end if;

  if v_key <> '' then
    -- the same dish spelled another way; the oldest when the place holds two (the scan proposes
    -- merging them)
    select d.id into v_id
    from public.dishes d
    where d.restaurant_id = p_restaurant_id
      and public.dish_key(d.name) = v_key
      and d.merged_into_dish_id is null
    order by d.created_at, d.id
    limit 1;
    if v_id is not null then
      return v_id;
    end if;

    select public.resolve_dish(d.id) into v_id
    from public.dishes d
    where d.restaurant_id = p_restaurant_id
      and public.dish_key(d.name) = v_key
      and d.merged_into_dish_id is not null
    order by d.created_at, d.id
    limit 1;
    if v_id is not null then
      return v_id;
    end if;
  end if;

  v_display := public.dish_title(v_name);

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
  'Select-then-insert (0071): live exact name → merged-away exact name (its survivor) → live same dish_key (oldest) → merged-away same key → a new dish, display name in title case (dish_title). NEVER ON CONFLICT — dishes_identity_uq is partial by design (0014/0016).';

revoke all on function public.find_or_create_dish(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.find_or_create_dish(uuid, text, uuid) to service_role;

-- ===========================================================================
-- 3. The merge log, merge_dish and unmerge_dish.
-- ===========================================================================
create table if not exists public.dish_merges (
  id                  bigint generated always as identity primary key,
  restaurant_id       uuid        not null references public.restaurants(id) on delete cascade,
  source_dish_id      uuid        not null references public.dishes(id) on delete cascade,
  target_dish_id      uuid        not null references public.dishes(id) on delete cascade,
  source_name         text        not null,
  target_name         text        not null,
  reason              text        not null check (reason in ('same_name', 'ai', 'manual')),
  detail              jsonb,
  -- what moved, so unmerge_dish can put it back
  moved_review_ids    uuid[]      not null default '{}',
  moved_save_users    uuid[]      not null default '{}',
  dropped_saves       jsonb       not null default '[]',   -- the saver held both: their row on the source
  moved_list_ids      uuid[]      not null default '{}',   -- legacy list_dishes
  dropped_list_dishes jsonb       not null default '[]',
  moved_entry_ids     uuid[]      not null default '{}',   -- the entries whose lines moved
  merged_at           timestamptz not null default now(),
  undone_at           timestamptz
);
create index if not exists dish_merges_source_idx on public.dish_merges (source_dish_id);
create index if not exists dish_merges_target_idx on public.dish_merges (target_dish_id);

comment on table public.dish_merges is
  '0071: every dish merge and what it moved (reviews, saves, legacy list rows, photo picks), so unmerge_dish can split it back out. Service role only.';

alter table public.dish_merges enable row level security;          -- no policy: no client reads it
revoke all on public.dish_merges from public, anon, authenticated;
grant select, insert, update on public.dish_merges to service_role;

drop function if exists public.merge_dish(uuid, uuid);

create or replace function public.merge_dish(
  p_source uuid,
  p_target uuid,
  p_reason text  default 'manual',
  p_detail jsonb default null
)
returns bigint                                 -- the dish_merges row
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_src      public.dishes;
  v_tgt      public.dishes;
  v_target   uuid := public.resolve_dish(p_target);
  v_reviews  uuid[];
  v_moved    uuid[];
  v_dropped  jsonb;
  v_lists    uuid[];
  v_ldropped jsonb;
  v_entries  uuid[];
  v_id       bigint;
begin
  if p_source = v_target then
    raise exception 'cannot merge a dish into itself (%)', p_source using errcode = '22023';
  end if;
  if coalesce(p_reason, '') not in ('same_name', 'ai', 'manual') then
    raise exception 'merge reason %', p_reason using errcode = '22023';
  end if;

  -- both rows locked, in id order (two merges of the same pair cannot deadlock)
  perform 1 from public.dishes where id in (p_source, v_target) order by id for update;
  select * into v_src from public.dishes where id = p_source;
  select * into v_tgt from public.dishes where id = v_target;
  if v_src.id is null or v_tgt.id is null then
    raise exception 'dish not found' using errcode = 'P0002';
  end if;
  if v_src.merged_into_dish_id is not null then
    raise exception 'dish % is already merged', p_source using errcode = '22023';
  end if;
  if v_src.restaurant_id <> v_tgt.restaurant_id then
    raise exception 'dishes_at_different_places' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.reviews a join public.reviews b on b.entry_id = a.entry_id
    where a.dish_id = p_source and b.dish_id = v_target and a.entry_id is not null
  ) then
    raise exception 'dishes_share_an_entry' using errcode = '22023';   -- the diner told them apart
  end if;

  -- 1. reviews. ate.repointing: not a user's correction (0024). 0060's trigger carries list items.
  perform set_config('ate.repointing', 'on', true);
  with moved as (
    update public.reviews set dish_id = v_target where dish_id = p_source returning id, entry_id
  )
  select coalesce(array_agg(id), '{}'), coalesce(array_agg(distinct entry_id) filter (where entry_id is not null), '{}')
    into v_reviews, v_entries
  from moved;
  perform set_config('ate.repointing', 'off', true);

  -- 2. saves: a saver who held both keeps the target's row; theirs on the source is recorded and dropped
  with gone as (
    delete from public.saves s
    where s.dish_id = p_source
      and exists (select 1 from public.saves t where t.user_id = s.user_id and t.dish_id = v_target)
    returning s.*
  )
  select coalesce(jsonb_agg(to_jsonb(gone)), '[]') into v_dropped from gone;
  with moved as (
    update public.saves set dish_id = v_target where dish_id = p_source returning user_id
  )
  select coalesce(array_agg(user_id), '{}') into v_moved from moved;

  -- 3. legacy list_dishes (dormant since V1), the same way
  with gone as (
    delete from public.list_dishes b
    where b.dish_id = p_source
      and exists (select 1 from public.list_dishes a where a.list_id = b.list_id and a.dish_id = v_target)
    returning b.*
  )
  select coalesce(jsonb_agg(to_jsonb(gone)), '[]') into v_ldropped from gone;
  with moved as (
    update public.list_dishes set dish_id = v_target where dish_id = p_source returning list_id
  )
  select coalesce(array_agg(list_id), '{}') into v_lists from moved;

  -- 4. photo picks (0064) name the dish in lower case: those entries' picks follow the merge
  update public.entries e
     set photo_picks = (
       select coalesce(jsonb_object_agg(k.key,
                case when k.value = to_jsonb(lower(v_src.name)) then to_jsonb(lower(v_tgt.name)) else k.value end), '{}')
       from jsonb_each(e.photo_picks) k)
   where e.id = any (v_entries)
     and exists (select 1 from jsonb_each(e.photo_picks) k where k.value = to_jsonb(lower(v_src.name)));

  -- 5. tombstone, and flatten anything that pointed at the source
  update public.dishes set merged_into_dish_id = v_target where id = p_source;
  update public.dishes set merged_into_dish_id = v_target where merged_into_dish_id = p_source;

  insert into public.dish_merges (
    restaurant_id, source_dish_id, target_dish_id, source_name, target_name, reason, detail,
    moved_review_ids, moved_save_users, dropped_saves, moved_list_ids, dropped_list_dishes, moved_entry_ids)
  values (
    v_src.restaurant_id, p_source, v_target, v_src.name, v_tgt.name, p_reason, p_detail,
    v_reviews, v_moved, v_dropped, v_lists, v_ldropped, v_entries)
  returning id into v_id;
  return v_id;
end; $$;

comment on function public.merge_dish(uuid, uuid, text, jsonb) is
  '0071: merge source INTO target (same place only; refused when one entry names both): reviews, saves, legacy list rows and photo picks follow; the source becomes an alias (tombstone); logged in dish_merges. Service role only.';

revoke all on function public.merge_dish(uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.merge_dish(uuid, uuid, text, jsonb) to service_role;

create or replace function public.unmerge_dish(p_merge_id bigint)
returns uuid                                   -- the source dish, live again
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  m     public.dish_merges;
  v_src public.dishes;
  v_tgt public.dishes;
begin
  select * into m from public.dish_merges where id = p_merge_id for update;
  if m.id is null then
    raise exception 'merge not found' using errcode = 'P0002';
  end if;
  if m.undone_at is not null then
    raise exception 'merge % is already undone', p_merge_id using errcode = '22023';
  end if;
  perform 1 from public.dishes where id in (m.source_dish_id, m.target_dish_id) order by id for update;
  select * into v_src from public.dishes where id = m.source_dish_id;
  select * into v_tgt from public.dishes where id = m.target_dish_id;
  if v_src.merged_into_dish_id is distinct from m.target_dish_id or v_tgt.merged_into_dish_id is not null then
    raise exception 'merge % has been built on since (merged again); undo the later merge first', p_merge_id
      using errcode = '22023';
  end if;
  if exists (select 1 from public.dishes d where d.restaurant_id = v_src.restaurant_id
             and lower(d.name) = lower(v_src.name) and d.merged_into_dish_id is null) then
    raise exception 'a live dish is called % again', v_src.name using errcode = '23505';
  end if;

  update public.dishes set merged_into_dish_id = null where id = m.source_dish_id;

  perform set_config('ate.repointing', 'on', true);
  -- by entry as well as by id: a re-sort re-mints a line's id, and those entries held no target line
  -- before the merge (merge_dish refuses one that did)
  update public.reviews set dish_id = m.source_dish_id
   where dish_id = m.target_dish_id
     and (id = any (m.moved_review_ids) or entry_id = any (m.moved_entry_ids));
  perform set_config('ate.repointing', 'off', true);

  update public.saves s set dish_id = m.source_dish_id
   where s.dish_id = m.target_dish_id and s.user_id = any (m.moved_save_users)
     and not exists (select 1 from public.saves t where t.user_id = s.user_id and t.dish_id = m.source_dish_id);
  insert into public.saves select * from jsonb_populate_recordset(null::public.saves, m.dropped_saves)
  on conflict do nothing;

  update public.list_dishes l set dish_id = m.source_dish_id
   where l.dish_id = m.target_dish_id and l.list_id = any (m.moved_list_ids)
     and not exists (select 1 from public.list_dishes t where t.list_id = l.list_id and t.dish_id = m.source_dish_id);
  insert into public.list_dishes select * from jsonb_populate_recordset(null::public.list_dishes, m.dropped_list_dishes)
  on conflict do nothing;

  update public.entries e
     set photo_picks = (
       select coalesce(jsonb_object_agg(k.key,
                case when k.value = to_jsonb(lower(v_tgt.name)) then to_jsonb(lower(v_src.name)) else k.value end), '{}')
       from jsonb_each(e.photo_picks) k)
   where e.id = any (m.moved_entry_ids);

  update public.dish_merges set undone_at = now() where id = p_merge_id;
  return m.source_dish_id;
end; $$;

comment on function public.unmerge_dish(bigint) is
  '0071: split a merge back out — the source is live again with the reviews, saves, legacy list rows and photo picks it had. Service role only.';

revoke all on function public.unmerge_dish(bigint) from public, anon, authenticated;
grant execute on function public.unmerge_dish(bigint) to service_role;

-- ===========================================================================
-- 4. Proposals for the dishes that already exist.
-- ===========================================================================
create table if not exists public.dish_merge_proposals (
  id             bigint generated always as identity primary key,
  restaurant_id  uuid        not null references public.restaurants(id) on delete cascade,
  source_dish_id uuid        not null references public.dishes(id) on delete cascade,
  target_dish_id uuid        not null references public.dishes(id) on delete cascade,
  source_name    text        not null,
  target_name    text        not null,
  reason         text        not null check (reason in ('same_name', 'ai')),
  why            text,
  status         text        not null default 'proposed'
                             check (status in ('proposed', 'merged', 'rejected', 'stale')),
  merge_id       bigint      references public.dish_merges(id) on delete set null,
  note           text,
  created_at     timestamptz not null default now(),
  decided_at     timestamptz,
  constraint dish_merge_proposals_pair_uq unique (source_dish_id, target_dish_id)
);

comment on table public.dish_merge_proposals is
  '0071: what the dish-dedup scan suggests merging among dishes that already exist. Nothing merges until a person approves (merge_dish_proposals). Service role only.';

alter table public.dish_merge_proposals enable row level security;
revoke all on public.dish_merge_proposals from public, anon, authenticated;
grant select, insert, update on public.dish_merge_proposals to service_role;

-- What the scan reads, one place per row: its live dishes that have a line (lines, created_at and up
-- to three notes each) and the pairs one entry names on separate lines (never merged).
create or replace function public.dish_scan_places()
returns table (restaurant_id uuid, place_name text, dishes jsonb, shared_pairs jsonb)
language sql stable security definer set search_path = public, extensions as $$
  with live as (
    select d.id, d.name, d.restaurant_id, d.created_at, count(r.id)::int as lines,
           (array_agg(r.note order by r.created_at desc) filter (where r.note is not null and r.note <> ''))[1:3] as notes
    from public.dishes d
    join public.reviews r on r.dish_id = d.id
    where d.merged_into_dish_id is null
    group by d.id
  ),
  places as (
    select l.restaurant_id from live l group by l.restaurant_id having count(*) >= 2
  )
  select p.restaurant_id,
         (select x.name from public.restaurants x where x.id = p.restaurant_id),
         (select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'lines', l.lines,
                                              'created_at', l.created_at, 'notes', coalesce(to_jsonb(l.notes), '[]'))
                           order by l.created_at, l.id)
            from live l where l.restaurant_id = p.restaurant_id),
         coalesce((select jsonb_agg(distinct jsonb_build_array(least(a.dish_id, b.dish_id), greatest(a.dish_id, b.dish_id)))
            from public.reviews a
            join public.reviews b on b.entry_id = a.entry_id and b.dish_id <> a.dish_id
            where a.entry_id is not null and a.restaurant_id = p.restaurant_id), '[]')
  from places p;
$$;

revoke all on function public.dish_scan_places() from public, anon, authenticated;
grant execute on function public.dish_scan_places() to service_role;

-- Merge the approved proposals: ids, or every open one when p_ids is null. A proposal the data has
-- moved past (a dish merged or gone since, or now named on one entry with its pair) is marked stale
-- with the reason, never forced.
create or replace function public.merge_dish_proposals(p_ids bigint[] default null)
returns table (proposal_id bigint, status text, merge_id bigint, note text)
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  p  public.dish_merge_proposals;
  v_merge bigint;
begin
  for p in
    select * from public.dish_merge_proposals x
    where x.status = 'proposed' and (p_ids is null or x.id = any (p_ids))
    order by x.id
  loop
    begin
      v_merge := public.merge_dish(p.source_dish_id, p.target_dish_id, p.reason,
                                   jsonb_build_object('proposal_id', p.id, 'why', p.why));
      update public.dish_merge_proposals set status = 'merged', merge_id = v_merge, decided_at = now() where id = p.id;
      proposal_id := p.id; status := 'merged'; merge_id := v_merge; note := null;
    exception when others then
      update public.dish_merge_proposals x set status = 'stale', note = sqlerrm, decided_at = now() where x.id = p.id;
      proposal_id := p.id; status := 'stale'; merge_id := null; note := sqlerrm;
    end;
    return next;
  end loop;
end; $$;

revoke all on function public.merge_dish_proposals(bigint[]) from public, anon, authenticated;
grant execute on function public.merge_dish_proposals(bigint[]) to service_role;
