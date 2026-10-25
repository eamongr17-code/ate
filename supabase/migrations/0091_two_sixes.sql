-- 0091_two_sixes.sql
-- Ate backend — at most two 6s in any two months (Eamon, 25 Oct). The secret 6 stays rare.
--
--   public.six_grants — one row per entry that holds a 6: how many 6s it was granted and when its
--     first one was. An entry's grants count for two months from that time. Deleting the entry
--     deletes the row (cascade), so its 6s come back. No policies and no grants: only the trigger
--     below (security definer) and six_allowance read or write it, so nobody can reset a count.
--
--   reviews_two_sixes (BEFORE INSERT OR UPDATE OF score on reviews) — the one choke point every
--     writer passes (apply_entry_sort, correct_entry_place, respond_ate_with, a direct PATCH). A line
--     becoming a 6 is either:
--       * a CARRY: the sorter deletes and re-inserts an entry's lines on every re-sort, so a 6 the
--         entry already holds comes back as an insert. While the entry holds fewer 6s than it was
--         granted, the 6 is let through and nothing is spent. A removed 6 is not given back
--         (deleting the entry is what gives them back).
--       * NEW: allowed only while the author's grants inside the last two months are under two;
--         then the entry is granted one more. Otherwise the line is saved as 5.0 — an old build
--         that never heard of the limit still cannot pass it.
--     An advisory lock per author serialises two sorts landing together.
--
--   six_allowance(p_entry_id) — for the composer: how many 6s are left, and when the next comes back
--     when none are. p_entry_id (an entry being edited) adds back that entry's own unused grants.
--
--   BACKFILL: every entry holding 6s today is granted exactly those, dated by the entry, so nobody
--     loses a 6 they already gave (a re-sort of an old entry is a carry).
--
-- WIRE IMPACT: ADDITIVE. One new RPC. A third 6 inside the window is saved as 5.0 (silently on old
--   builds; the app blocks it at the slider first).

set search_path = public, extensions;

create table if not exists public.six_grants (
  entry_id  uuid primary key references public.entries(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  granted   int  not null check (granted > 0),
  first_at  timestamptz not null default now()
);
create index if not exists six_grants_author_first on public.six_grants (author_id, first_at desc);
alter table public.six_grants enable row level security;
revoke all on public.six_grants from public, anon, authenticated;

insert into public.six_grants (entry_id, author_id, granted, first_at)
select e.id, e.author_id, count(*)::int, e.created_at
from public.reviews r
join public.entries e on e.id = r.entry_id
where r.score = 6
group by e.id, e.author_id, e.created_at
on conflict (entry_id) do nothing;

create or replace function public.trg_review_two_sixes()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_author  uuid;
  v_held    int;
  v_granted int;
  v_used    int;
begin
  if new.score is distinct from 6 then return new; end if;
  if tg_op = 'UPDATE' and old.score = 6 then return new; end if;
  if new.entry_id is null then return new; end if;

  select e.author_id into v_author from public.entries e where e.id = new.entry_id;
  if v_author is null then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended('two_sixes:' || v_author::text, 0));

  -- A carry: the entry already holds fewer 6s than it was granted.
  select count(*)::int into v_held
  from public.reviews r
  where r.entry_id = new.entry_id and r.score = 6 and r.id <> new.id;
  select g.granted into v_granted from public.six_grants g where g.entry_id = new.entry_id;
  if v_held < coalesce(v_granted, 0) then return new; end if;

  -- New: two in any two months.
  select coalesce(sum(g.granted), 0)::int into v_used
  from public.six_grants g
  where g.author_id = v_author and g.first_at > now() - interval '2 months';
  if v_used >= 2 then
    new.score := 5.0;
    return new;
  end if;

  insert into public.six_grants (entry_id, author_id, granted)
  values (new.entry_id, v_author, 1)
  on conflict (entry_id) do update set granted = public.six_grants.granted + 1;
  return new;
end; $$;

drop trigger if exists reviews_two_sixes on public.reviews;
create trigger reviews_two_sixes
  before insert or update of score on public.reviews
  for each row execute function public.trg_review_two_sixes();

revoke execute on function public.trg_review_two_sixes() from public, anon, authenticated;

create or replace function public.six_allowance(p_entry_id uuid default null)
returns table (sixes_left int, next_at timestamptz)
language sql stable security definer set search_path = public, extensions as $$
  with mine as (
    select g.entry_id, g.granted, g.first_at
    from public.six_grants g
    where g.author_id = auth.uid() and g.first_at > now() - interval '2 months'
  ),
  own_entry as (
    -- An entry being edited: its own 6s are carries, so its grants are not spent on it.
    select coalesce(sum(m.granted), 0)::int as granted
    from mine m where m.entry_id = p_entry_id
  ),
  used as (select coalesce(sum(m.granted), 0)::int as n from mine m)
  select greatest(2 - (select n from used), 0) + (select granted from own_entry),
         case when (select n from used) >= 2
              then (select min(m.first_at) from mine m) + interval '2 months' end
  where auth.uid() is not null;
$$;

revoke execute on function public.six_allowance(uuid) from public, anon;
grant execute on function public.six_allowance(uuid) to authenticated;

comment on function public.six_allowance(uuid) is
  'The composer''s 6 allowance (0091): sixes_left now (two in any two months, plus the edited entry''s own grants), and next_at, when the next comes back, if none are left. Signed in only.';
