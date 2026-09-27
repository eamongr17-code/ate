-- supabase/staging-seed/remove.sql — STAGING ONLY. Takes the round-6 dummy dataset back out, in one
-- batch, from the registry setup.sql keeps. Touches NOTHING the registry does not list.
--
--   node supabase/staging-seed/seed.mjs --remove --i-mean-it
--
-- What goes, in order:
--   1. the saves the seed made in real accounts' names (Eamon's) — listed in staging_seed.saves;
--   2. every seeded entry (the 60 in Eamon's journal included) — cascades its lines and photo ROWS
--      (never the storage files: those belong to the earlier demo entries and stay);
--   3. every seeded account — cascades its profile, and anything it still owns (saves included);
--   4. every seeded restaurant NOBODY REAL still points at — its dishes go with it. A seeded place
--      that a real entry, line or save has used since is KEPT (with its dishes) and listed in the
--      NOTICE output; the catalogue loses nothing a real row needs.
-- Then the registry rows for what went. The `staging_seed` schema itself stays (it holds nothing
-- once the registry is empty; drop it with the seed's other files when the dataset is retired).
-- Not undone: the order numbers the 60 synthetic entries consumed in Eamon's account (numbers are
-- never reused; his next entry keeps counting up).

select staging_seed.assert_staging();

do $$
declare
  v_saves   int;
  v_entries int;
  v_users   int;
  v_places  int;
  v_kept    text;
begin
  -- The seeded ROW only: same user, dish AND created_at. A real re-save (unsave, save again) is a new
  -- row with a new created_at and stays; so does any save the registry holds no timestamp for.
  delete from public.saves s
   using staging_seed.saves r
   where s.user_id = r.user_id and s.dish_id = r.dish_id
     and r.saved_at is not null and s.created_at = r.saved_at;
  get diagnostics v_saves = row_count;
  delete from staging_seed.saves;

  delete from public.entries e
   using staging_seed.registry r
   where r.tbl = 'entries' and e.id = r.id;
  get diagnostics v_entries = row_count;
  delete from staging_seed.registry where tbl = 'entries';

  delete from auth.users u
   using staging_seed.registry r
   where r.tbl = 'users' and u.id = r.id;
  get diagnostics v_users = row_count;
  delete from staging_seed.registry where tbl = 'users';

  select string_agg(x.name, ', ' order by x.name) into v_kept
  from public.restaurants x
  join staging_seed.registry r on r.tbl = 'restaurants' and r.id = x.id
  where exists (select 1 from public.entries e where e.restaurant_id = x.id)
     or exists (select 1 from public.reviews v where v.restaurant_id = x.id)
     or exists (select 1 from public.saves s join public.dishes d on d.id = s.dish_id where d.restaurant_id = x.id);

  delete from public.restaurants x
   using staging_seed.registry r
   where r.tbl = 'restaurants' and x.id = r.id
     and not exists (select 1 from public.entries e where e.restaurant_id = x.id)
     and not exists (select 1 from public.reviews v where v.restaurant_id = x.id)
     and not exists (select 1 from public.saves s join public.dishes d on d.id = s.dish_id where d.restaurant_id = x.id);
  get diagnostics v_places = row_count;
  delete from staging_seed.registry r
   where r.tbl = 'restaurants' and not exists (select 1 from public.restaurants x where x.id = r.id);

  raise notice 'staging_seed removed: % saves in real accounts, % entries, % accounts, % restaurants', v_saves, v_entries, v_users, v_places;
  if v_kept is not null then
    raise notice 'staging_seed KEPT (a real row uses them): %', v_kept;
  end if;
end;
$$;

-- Report what is left (0 rows = everything went, and the schema can go too).
select tbl, count(*) as left_in_registry from staging_seed.registry group by tbl;
