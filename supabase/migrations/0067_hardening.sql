-- 0067_hardening.sql
--
-- Production-readiness review (15 Oct, evaluations/production-readiness-2026-10-15.md), items 1, 2, 4.
--
-- 1. A review line can only sit on its own author's entry. 0004's policies checked who WROTE a
--    line, never whose entry it sat on, so a direct PostgREST insert/update could hang lines (and
--    scores) on someone else's receipt; entry_cards aggregates every line by entry_id. Lines with
--    no entry (pre-0018 loose reviews) are unchanged.
-- 2. One daily AI budget for the three model-calling functions (sort-entry, match-photos,
--    read-share): a per-user cap per kind plus one global ceiling across everyone. Over budget, the
--    functions degrade the way they already do without a key (stub sort, no photo match, no share
--    suggestion); nothing fails. Durable, so it holds across isolates (read-share's in-memory
--    window does not).
-- 4. A client insert can no longer date an entry into the future (which pinned it to the top of
--    the keyset Feed). Same bounds set_entry_date (0063) already enforces on edits.

-- ===========================================================================
-- 1. reviews: the entry must be the caller's own
-- ===========================================================================
drop policy if exists reviews_insert_author on public.reviews;
create policy reviews_insert_author on public.reviews
  for insert to authenticated
  with check (
    reviewer_id = (select auth.uid())
    and (entry_id is null
         or exists (select 1 from public.entries e where e.id = entry_id and e.author_id = (select auth.uid())))
  );

drop policy if exists reviews_update_author on public.reviews;
create policy reviews_update_author on public.reviews
  for update to authenticated
  using (reviewer_id = (select auth.uid()))
  with check (
    reviewer_id = (select auth.uid())
    and (entry_id is null
         or exists (select 1 from public.entries e where e.id = entry_id and e.author_id = (select auth.uid())))
  );

-- ===========================================================================
-- 2. The AI budget
-- ===========================================================================
create table if not exists public.ai_usage (
  user_id uuid    not null references auth.users(id) on delete cascade,
  day     date    not null,
  kind    text    not null check (kind in ('sort', 'match', 'share')),
  calls   integer not null default 0,
  primary key (user_id, day, kind)
);

comment on table public.ai_usage is
  '0067: model calls per user per UTC day per function (sort / match / share), the durable spend guard. Server-internal: RLS on, no policy, service_role only.';

alter table public.ai_usage enable row level security;
revoke all on public.ai_usage from public, anon, authenticated;
grant select, insert, update, delete on public.ai_usage to service_role;

create index if not exists ai_usage_day_idx on public.ai_usage (day);

-- true = make the model call (and it is counted); false = over budget, degrade.
-- Per user per day: 100 sorts, 60 photo matches, 40 share reads. Everyone together: 5,000 calls a
-- day (about $5-15 at Haiku prices), the ceiling a runaway loop or an abuser hits instead of the bill.
create or replace function public.ai_budget_hit(p_user_id uuid, p_kind text)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_day   date := (now() at time zone 'utc')::date;
  v_limit integer := case p_kind when 'sort' then 100 when 'match' then 60 when 'share' then 40 end;
  v_calls integer;
begin
  if p_user_id is null or v_limit is null then
    return false;
  end if;
  if (select coalesce(sum(u.calls), 0) from public.ai_usage u where u.day = v_day) >= 5000 then
    return false;
  end if;
  insert into public.ai_usage (user_id, day, kind, calls)
    values (p_user_id, v_day, p_kind, 1)
    on conflict (user_id, day, kind)
    do update set calls = public.ai_usage.calls + 1
    returning calls into v_calls;
  -- Old days go with the next call of the day; bounded so one call never pays for a backlog.
  delete from public.ai_usage u
  using (select x.user_id, x.day, x.kind from public.ai_usage x
         where x.day < v_day - 7 limit 200) old
  where u.user_id = old.user_id and u.day = old.day and u.kind = old.kind;
  return v_calls <= v_limit;
end; $$;

comment on function public.ai_budget_hit(uuid, text) is
  '0067: counts one model call for (user, kind) today and says whether it is within the per-user and global daily caps. service_role only.';

revoke all on function public.ai_budget_hit(uuid, text) from public, anon, authenticated;
grant execute on function public.ai_budget_hit(uuid, text) to service_role;

-- ===========================================================================
-- 4. entries.created_at on insert: never in the future
-- ===========================================================================
-- 0033's trigger, plus the clamp in the INSERT branch.
create or replace function public.trg_entry_biu()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_seq integer;
begin
  -- Every entry is public (0033). A shipped client that still sends 'private' lands public instead
  -- of failing at the composer.
  new.visibility := 'public';

  if tg_op = 'INSERT' then
    update public.profiles
       set entry_seq = entry_seq + 1
     where id = new.author_id
    returning entry_seq into v_seq;

    if v_seq is null then
      raise exception 'unknown author_id %', new.author_id using errcode = '23503';
    end if;

    -- 0067: the client's date stands (offline outbox, backfill from the camera roll) unless it is
    -- in the future or before the app could exist; then it is now. A day of slack for time zones,
    -- as set_entry_date (0063).
    if new.created_at is null
       or new.created_at > now() + interval '1 day'
       or new.created_at < timestamptz '2000-01-01' then
      new.created_at := now();
    end if;

    new.order_number      := v_seq;                -- authoritative, ignores any client value
    new.restaurant_source := case when new.restaurant_id is not null then 'user' end;
    new.updated_at        := new.created_at;
  elsif new is distinct from old then
    -- A no-op UPDATE (e.g. a pinned "Make private") leaves updated_at alone, so it cannot trip the
    -- client's `updated_at > sorted_at` stale-offsets hint.
    new.updated_at := now();
  end if;
  return new;
end; $$;
