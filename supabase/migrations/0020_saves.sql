-- 0020_saves.sql
-- Ate backend — V1 RETHINK: SAVE. A user saves a DISH (at its restaurant) from
-- someone's entry, from a dish page, or from a place page. The saved list reads
-- GROUPED BY RESTAURANT and shows WHO it was saved from. There are no likes.
--
-- WHY A NEW TABLE and not the old `lists` / `list_dishes` pair (whose original
-- decision was literally "save = list membership"): the V1 save carries PROVENANCE
-- ("from @jessw" — design/v1/Saved.dc.html) and there is exactly one list per user,
-- so the list row is pure ceremony and the provenance has nowhere to live.
-- `lists`/`list_dishes` are left applied and untouched; V1 simply does not read
-- them. Nothing breaks, nothing is migrated.
--
-- PK (user_id, dish_id) is a TOTAL unique constraint, so `upsert(onConflict:
-- 'user_id,dish_id')` from PostgREST is legal here — unlike dishes' identity index,
-- which is PARTIAL BY DESIGN (the 0014/0016 lesson).
--
-- WIRE IMPACT: ADDITIVE only — table `saves`, view `my_saved_dishes`, RPCs
-- `save_dish`, `unsave_dish`, `save_entry_dishes`, `is_dish_saved`.

set search_path = public, extensions;

create table public.saves (
  user_id         uuid not null references public.profiles(id) on delete cascade,
  dish_id         uuid not null references public.dishes(id)   on delete cascade,
  -- provenance: the entry this was saved off, and its author. Both nullable and
  -- both ON DELETE SET NULL — if the entry or the author goes, the save survives
  -- (you still want the dish) and just loses its "from @…".
  source_entry_id uuid references public.entries(id)  on delete set null,
  source_user_id  uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  primary key (user_id, dish_id)
);

comment on table public.saves is
  'A user''s saved dishes with provenance (which entry / whose entry it came from). Read grouped by restaurant via my_saved_dishes. No likes in V1.';

create index saves_user_idx   on public.saves (user_id, created_at desc);
create index saves_dish_idx   on public.saves (dish_id);
create index saves_source_idx on public.saves (source_entry_id) where source_entry_id is not null;
create index saves_source_user_idx on public.saves (source_user_id) where source_user_id is not null;

alter table public.saves enable row level security;

-- A save is private to the saver. Nobody else can see what you saved, and no
-- surface in V1 shows another user's saves.
create policy saves_select_own on public.saves
  for select to authenticated using (user_id = (select auth.uid()));

create policy saves_insert_own on public.saves
  for insert to authenticated with check (user_id = (select auth.uid()));

create policy saves_update_own on public.saves
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy saves_delete_own on public.saves
  for delete to authenticated using (user_id = (select auth.uid()));

revoke all on public.saves from anon;
grant select, insert, update, delete on public.saves to authenticated;
grant all on public.saves to service_role;

-- ===========================================================================
-- my_saved_dishes — the Saved screen, flat and ordered; the client groups by
-- restaurant (grouping is presentation, so it is not baked into the wire).
--
-- LEFT JOINs throughout on purpose: a blocked author's profile row is invisible
-- (0019), and an inner join would silently DROP the saved dish instead of just
-- dropping its "from @…". You keep what you saved.
--
-- dish_score is the dish's community aggregate from dish_stats (nearest 0.1; the
-- client rounds to the nearest half per DESIGN rule 7), NULL when nobody scored it.
-- ===========================================================================
create or replace view public.my_saved_dishes
with (security_invoker = true) as
  select
    s.dish_id,
    d.name                as dish_name,
    r.id                  as restaurant_id,
    r.name                as restaurant_name,
    r.city                as restaurant_city,
    ds.score              as dish_score,
    ds.cover_url          as dish_cover_url,
    s.source_entry_id,
    s.source_user_id,
    sp.username           as source_username,
    s.created_at          as saved_at
  from public.saves s
  join public.dishes d       on d.id = s.dish_id
  join public.restaurants r  on r.id = d.restaurant_id
  left join public.dish_stats ds on ds.dish_id = s.dish_id
  left join public.profiles sp   on sp.id = s.source_user_id
  where s.user_id = (select auth.uid());

comment on view public.my_saved_dishes is
  'The caller''s saved dishes joined to place + dish aggregate + provenance handle. Order by restaurant_name, saved_at desc for the Saved screen.';

grant select on public.my_saved_dishes to authenticated;

-- ===========================================================================
-- MUTATIONS
-- ===========================================================================

-- save_dish — idempotent. Re-saving KEEPS the original provenance (coalesce), so a
-- later save from a dish page cannot erase "from @jessw".
create or replace function public.save_dish(p_dish_id uuid, p_source_entry_id uuid default null)
returns void
language plpgsql
volatile
security invoker
set search_path = public, extensions
as $$
declare
  v_source_user uuid;
begin
  if p_source_entry_id is not null then
    -- RLS applies (invoker): we can only read an entry we are allowed to see, so a
    -- private/blocked entry cannot be used to mint provenance.
    select e.author_id into v_source_user from public.entries e where e.id = p_source_entry_id;
  end if;

  insert into public.saves (user_id, dish_id, source_entry_id, source_user_id)
  values ((select auth.uid()), p_dish_id, p_source_entry_id, v_source_user)
  on conflict (user_id, dish_id) do update
    set source_entry_id = coalesce(saves.source_entry_id, excluded.source_entry_id),
        source_user_id  = coalesce(saves.source_user_id,  excluded.source_user_id);
end; $$;

comment on function public.save_dish(uuid, uuid) is
  'Save a dish, optionally recording the entry it was seen on. Idempotent; first provenance wins.';

create or replace function public.unsave_dish(p_dish_id uuid)
returns void language sql volatile security invoker
set search_path = public, extensions as $$
  delete from public.saves where user_id = (select auth.uid()) and dish_id = p_dish_id;
$$;

-- save_entry_dishes — what the Actions sheet's "Save this place" does: take every
-- dish the entry printed and save it, provenance = that entry. Returns how many
-- rows the call touched (the FE shows nothing; it is for tests/telemetry).
create or replace function public.save_entry_dishes(p_entry_id uuid)
returns integer
language plpgsql
volatile
security invoker
set search_path = public, extensions
as $$
declare
  v_author uuid;
  v_count  integer := 0;
begin
  select e.author_id into v_author from public.entries e where e.id = p_entry_id;
  if v_author is null then
    raise exception 'entry % not found or not visible', p_entry_id using errcode = '42501';
  end if;

  with src as (
    select distinct v.dish_id from public.reviews v where v.entry_id = p_entry_id
  )
  insert into public.saves (user_id, dish_id, source_entry_id, source_user_id)
  select (select auth.uid()), src.dish_id, p_entry_id, v_author from src
  on conflict (user_id, dish_id) do update
    set source_entry_id = coalesce(saves.source_entry_id, excluded.source_entry_id),
        source_user_id  = coalesce(saves.source_user_id,  excluded.source_user_id);

  get diagnostics v_count = row_count;
  return v_count;
end; $$;

create or replace function public.is_dish_saved(p_dish_id uuid)
returns boolean language sql stable security invoker
set search_path = public, extensions as $$
  select exists (
    select 1 from public.saves s
    where s.user_id = (select auth.uid()) and s.dish_id = p_dish_id
  );
$$;

revoke all on function public.save_dish(uuid, uuid)       from public, anon;
revoke all on function public.unsave_dish(uuid)           from public, anon;
revoke all on function public.save_entry_dishes(uuid)     from public, anon;
revoke all on function public.is_dish_saved(uuid)         from public, anon;
grant execute on function public.save_dish(uuid, uuid)   to authenticated;
grant execute on function public.unsave_dish(uuid)       to authenticated;
grant execute on function public.save_entry_dishes(uuid) to authenticated;
grant execute on function public.is_dish_saved(uuid)     to authenticated;
