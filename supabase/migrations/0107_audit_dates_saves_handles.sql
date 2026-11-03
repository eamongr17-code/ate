-- 0107_audit_dates_saves_handles.sql
-- Ate backend — the weekly independent audit (4 Nov), database half. Each case is reproduced and then
-- refused in supabase/tests/db/audit_nov4_test.mjs.
--
--   1. Changing the day you ate (set_entry_date, 0063) moved the entry but left its lines on the old
--      day: reviews.created_at drives the dish pages, the place's lines and the awards' dates, so a
--      re-dated visit kept showing on the day it was typed. The lines now move with the entry, as
--      every other writer already does (apply_entry_sort and 0103 insert lines at the entry's time).
--      Rows already out of step are NOT touched here: fixing them is a bulk change to prod data.
--   2. saves: the table grants the client INSERT / UPDATE (save_dish and save_entry_dishes are
--      invoker upserts and need them), so a client could write any source_user_id directly and mint
--      "Saved by someone" / "10 saves" awards for anyone. For client writes the provenance is now the
--      server's: source_user_id is the source entry's author (read under the caller's RLS, exactly as
--      save_dish does), and a source entry that did not print the saved dish records no provenance.
--      An upsert that leaves the source entry as it was is not re-checked (first provenance wins).
--   3. profiles.username: the server only checked the length; the app's alphabet is letters, digits
--      and "_" (HandleName.swift). Client writes must now match it (dots allowed, as handles imported
--      before the app's rule may carry one). A trigger, not a CHECK, so a legacy row still saves when
--      some other column changes.
--
-- Only client writes (anon / authenticated) are checked: definer RPCs, merges and the service role
-- write as other roles. Volume: every check is one primary-key or (entry_id) indexed lookup.

set search_path = public, extensions;

-- ===========================================================================
-- 1. set_entry_date — 0063, plus the entry's lines.
-- ===========================================================================
create or replace function public.set_entry_date(p_entry_id uuid, p_eaten_at timestamptz)
returns void
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'sign in to edit' using errcode = '42501';
  end if;
  -- A day of slack for time zones; nothing before the app could have existed.
  if p_eaten_at is null or p_eaten_at > now() + interval '1 day' or p_eaten_at < timestamptz '2000-01-01' then
    raise exception 'eaten_at' using errcode = '22023';
  end if;
  update public.entries e set created_at = p_eaten_at
  where e.id = p_entry_id and e.author_id = v_uid;
  if not found then
    raise exception 'entry not found' using errcode = 'P0002';
  end if;
  -- The lines were eaten when the entry was (reviews_entry_idx). Not a correction: the
  -- correction net (0024/0097) looks at score, note and dish only.
  update public.reviews r set created_at = p_eaten_at
  where r.entry_id = p_entry_id and r.created_at is distinct from p_eaten_at;
end; $$;

revoke all on function public.set_entry_date(uuid, timestamptz) from public, anon;
grant execute on function public.set_entry_date(uuid, timestamptz) to authenticated;

-- ===========================================================================
-- 2. saves — provenance is the server's.
-- ===========================================================================
-- Invoker, so current_user still says who is writing and the entry is read under the caller's RLS.
create or replace function public.trg_saves_provenance()
returns trigger language plpgsql security invoker set search_path = public, extensions as $$
begin
  if current_user not in ('anon', 'authenticated') then return new; end if;
  if tg_op = 'UPDATE' and new.source_entry_id is not distinct from old.source_entry_id then
    new.source_user_id := old.source_user_id;          -- first provenance wins; nothing to re-check
    return new;
  end if;
  new.source_user_id := null;
  if new.source_entry_id is not null then
    select e.author_id into new.source_user_id
      from public.entries e
     where e.id = new.source_entry_id
       and exists (select 1 from public.reviews r
                    where r.entry_id = e.id and r.dish_id = new.dish_id);
    if new.source_user_id is null then
      new.source_entry_id := null;                      -- not an entry that printed this dish
    end if;
  end if;
  return new;
end; $$;

revoke execute on function public.trg_saves_provenance() from public, anon, authenticated;

drop trigger if exists saves_provenance on public.saves;
create trigger saves_provenance
  before insert or update of source_entry_id, source_user_id on public.saves
  for each row execute function public.trg_saves_provenance();

-- ===========================================================================
-- 3. profiles.username — the app's alphabet, for client writes.
-- ===========================================================================
create or replace function public.trg_profiles_username_format()
returns trigger language plpgsql security invoker set search_path = public, extensions as $$
begin
  if current_user not in ('anon', 'authenticated') then return new; end if;
  if tg_op = 'UPDATE' and new.username is not distinct from old.username then return new; end if;
  if new.username::text !~ '^[A-Za-z0-9_.]{1,30}$' then
    raise exception 'username' using errcode = '23514';
  end if;
  return new;
end; $$;

revoke execute on function public.trg_profiles_username_format() from public, anon, authenticated;

drop trigger if exists profiles_username_format on public.profiles;
create trigger profiles_username_format
  before insert or update of username on public.profiles
  for each row execute function public.trg_profiles_username_format();
