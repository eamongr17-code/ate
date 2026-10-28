-- 0098_plate_awards.sql — plate awards (approved by Eamon 28 Oct 2026; design/rebuild/plate-awards*.html).
--
-- Twenty awards, each drawn in the app as a plate. They are always about the food, never places:
--   dishes_1 · dishes_10 · dishes_25 · dishes_50 · dishes_100 · dishes_250 · dishes_500   (lines logged)
--   first_5 · first_6 · first_half                                                        (scores you gave)
--   first_drink · first_dessert · new_country · ate_with · saved_by_someone · saves_10 ·
--   same_dish_3 · five_in_entry · three_in_day · five_at_place                           (one-offs)
--
-- Rules:
--   * An award is earned once and NEVER taken away (deleting the entry later keeps it).
--   * `earned_at` is when the thing that earned it happened (the visit's date), not when we noticed.
--   * Checks run in the database, after the writes that can earn one: a sorted line (reviews), an
--     entry or its place, a save someone makes from your entry, an ate-with tag, a drinks/dessert style
--     arriving on a dish. A check can never fail the write that triggered it.
--   * `seen_at` NULL = not shown to its owner yet. The app's full-screen takeover shows every unseen
--     award, then marks them seen. Existing people are backfilled below, unseen, so testers get what
--     they have already earned in one takeover.
--   * Others see your awards on your profile (not through a block, not when deactivated).
--
-- Wire: awards_of(user) · mark_awards_seen(awards) · award_lines(user, award, cursor…). No client write.

-- ===========================================================================
-- 1. The table
-- ===========================================================================
create table if not exists public.user_awards (
  user_id       uuid        not null references public.profiles(id) on delete cascade,
  award         text        not null,
  earned_at     timestamptz not null,
  entry_id      uuid        references public.entries(id)  on delete set null,  -- the entry that earned it
  dish_id       uuid        references public.dishes(id)   on delete set null,  -- the dish that earned it
  entry_ids     uuid[]      not null default '{}',                              -- group awards: the entries
  dish_ids      uuid[]      not null default '{}',                              -- group awards: the dishes
  other_user_id uuid        references public.profiles(id) on delete set null,  -- ate with / saved by
  seen_at       timestamptz,
  created_at    timestamptz not null default now(),
  constraint user_awards_pk primary key (user_id, award),                       -- TOTAL
  constraint user_awards_award_ck check (award in (
    'dishes_1', 'dishes_10', 'dishes_25', 'dishes_50', 'dishes_100', 'dishes_250', 'dishes_500',
    'first_5', 'first_6', 'first_half',
    'first_drink', 'first_dessert', 'new_country', 'ate_with', 'saved_by_someone', 'saves_10',
    'same_dish_3', 'five_in_entry', 'three_in_day', 'five_at_place'))
);
create index if not exists user_awards_unseen_idx on public.user_awards (user_id) where seen_at is null;

alter table public.user_awards enable row level security;
-- No policy and no grant: every read and write goes through the functions below.
revoke all on public.user_awards from public, anon, authenticated;
grant all on public.user_awards to service_role;

-- ===========================================================================
-- 2. Helpers
-- ===========================================================================

-- The country of a Google-style address ("…, Fitzroy VIC 3065, Australia" → 'australia'): its last
-- comma part when that is letters only. A typed place with no address (or no country on it) has none,
-- and a place with no country never counts towards "a dish in a new country".
create or replace function public.place_country(p_address text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select case
    when p_address is null or position(',' in p_address) = 0 then null
    else (
      select case when btrim(last) ~ '[[:alpha:]]' and btrim(last) !~ '[0-9]' then lower(btrim(last)) end
      from (select (regexp_split_to_array(p_address, ','))[cardinality(regexp_split_to_array(p_address, ','))] as last) s
    )
  end;
$$;

-- The day "3 entries in one day" counts in. The beta is in Melbourne; a per-person zone is additive.
create or replace function public.award_day_zone()
returns text language sql immutable as $$ select 'Australia/Melbourne'::text $$;

create or replace function public.award_put(
  p_user uuid, p_award text, p_at timestamptz,
  p_entry uuid default null, p_dish uuid default null,
  p_entries uuid[] default '{}', p_dishes uuid[] default '{}', p_other uuid default null)
returns int
language sql
volatile
security definer
set search_path = public, extensions
as $$
  with ins as (
    insert into public.user_awards (user_id, award, earned_at, entry_id, dish_id, entry_ids, dish_ids, other_user_id)
    select p_user, p_award, p_at, p_entry, p_dish, coalesce(p_entries, '{}'), coalesce(p_dishes, '{}'), p_other
    where p_at is not null
    on conflict (user_id, award) do nothing
    returning 1)
  select count(*)::int from ins;
$$;

-- ===========================================================================
-- 3. The check: everything a person has earned and does not hold yet. Idempotent.
-- ===========================================================================
create or replace function public.award_check(p_user uuid)
returns int
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_held  text[];
  v_n     int;
  v_m     int;
  v_added int := 0;
  r       record;
  v_s     record;
begin
  if p_user is null or not exists (select 1 from public.profiles where id = p_user) then
    return 0;
  end if;
  select coalesce(array_agg(award), '{}') into v_held from public.user_awards where user_id = p_user;
  if cardinality(v_held) >= 20 then
    return 0;
  end if;

  -- Dishes logged: the Nth line (a line = one dish on one visit, profile_summary's `dishes`).
  select count(*) into v_n from public.reviews where reviewer_id = p_user;
  foreach v_m in array array[1, 10, 25, 50, 100, 250, 500] loop
    exit when v_n < v_m;
    if not ('dishes_' || v_m) = any (v_held) then
      select rv.created_at, rv.entry_id, rv.dish_id into r
        from public.reviews rv where rv.reviewer_id = p_user
        order by rv.created_at, rv.id offset v_m - 1 limit 1;
      if found then
        v_added := v_added + public.award_put(p_user, 'dishes_' || v_m, r.created_at, r.entry_id, r.dish_id);
      end if;
    end if;
  end loop;

  -- Scores you gave: the first 5.0, the first (secret) 6, the first 0.5.
  for v_s in select * from (values ('first_5', 5.0::numeric), ('first_6', 6.0), ('first_half', 0.5)) t(award, score) loop
    if not v_s.award = any (v_held) then
      select rv.created_at, rv.entry_id, rv.dish_id into r
        from public.reviews rv where rv.reviewer_id = p_user and rv.score = v_s.score
        order by rv.created_at, rv.id limit 1;
      if found then
        v_added := v_added + public.award_put(p_user, v_s.award, r.created_at, r.entry_id, r.dish_id);
      end if;
    end if;
  end loop;

  -- First drink / first dessert: the first line of a dish carrying that style (0069's fixed list).
  for v_s in select * from (values ('first_drink', 'drinks'), ('first_dessert', 'dessert')) t(award, slug) loop
    if not v_s.award = any (v_held) then
      select rv.created_at, rv.entry_id, rv.dish_id into r
        from public.reviews rv
       where rv.reviewer_id = p_user
         and exists (select 1 from public.dish_tag_links l
                      where l.dish_id = rv.dish_id and l.kind = 'style' and l.slug = v_s.slug)
       order by rv.created_at, rv.id limit 1;
      if found then
        v_added := v_added + public.award_put(p_user, v_s.award, r.created_at, r.entry_id, r.dish_id);
      end if;
    end if;
  end loop;

  -- A dish in a new country: the first entry in a country other than your first entry's.
  if not 'new_country' = any (v_held) then
    with located as (
      select e.id, e.created_at, public.place_country(re.address) as c
        from public.entries e join public.restaurants re on re.id = e.restaurant_id
       where e.author_id = p_user and public.place_country(re.address) is not null),
    home as (select c from located order by created_at, id limit 1)
    select l.id, l.created_at into r
      from located l, home h where l.c <> h.c
     order by l.created_at, l.id limit 1;
    if found then
      v_added := v_added + public.award_put(p_user, 'new_country', r.created_at, r.id, null, array[r.id]);
    end if;
  end if;

  -- Ate with someone: you tagged someone (not declined), or you accepted someone's tag.
  if not 'ate_with' = any (v_held) then
    select x.entry_id, x.at, x.other into r from (
      select ec.entry_id, e.created_at as at, ec.companion_id as other, ec.created_at as tie
        from public.entry_companions ec join public.entries e on e.id = ec.entry_id
       where ec.tagger_id = p_user and ec.status <> 'declined'
      union all
      select coalesce(ec.response_entry_id, ec.entry_id), coalesce(ec.responded_at, ec.created_at), ec.tagger_id, ec.created_at
        from public.entry_companions ec
       where ec.companion_id = p_user and ec.status = 'accepted') x
     order by x.at, x.tie limit 1;
    if found then
      v_added := v_added + public.award_put(p_user, 'ate_with', r.at, r.entry_id, null, array[r.entry_id], '{}', r.other);
    end if;
  end if;

  -- Saved by someone (the first time) and 10 saves (the tenth): saves other people made from your entries.
  if not ('saved_by_someone' = any (v_held) and 'saves_10' = any (v_held)) then
    select s.created_at, s.source_entry_id, s.dish_id, s.user_id into r
      from public.saves s where s.source_user_id = p_user and s.user_id <> p_user
     order by s.created_at, s.user_id, s.dish_id limit 1;
    if found and not 'saved_by_someone' = any (v_held) then
      v_added := v_added + public.award_put(p_user, 'saved_by_someone', r.created_at, r.source_entry_id, r.dish_id,
                                            '{}', array[r.dish_id], r.user_id);
    end if;
    if found and not 'saves_10' = any (v_held) then
      with ten as (
        select s.created_at, s.dish_id from public.saves s
         where s.source_user_id = p_user and s.user_id <> p_user
         order by s.created_at, s.user_id, s.dish_id limit 10)
      select max(created_at) as at, count(*) as n, array_agg(distinct dish_id) as dishes into r from ten;
      if r.n = 10 then
        v_added := v_added + public.award_put(p_user, 'saves_10', r.at, null, null, '{}', r.dishes);
      end if;
    end if;
  end if;

  -- The same dish 3 times: the first dish to reach a third line.
  if not 'same_dish_3' = any (v_held) then
    with k as (
      select rv.dish_id, rv.entry_id, rv.created_at, rv.id,
             row_number() over (partition by rv.dish_id order by rv.created_at, rv.id) as n
        from public.reviews rv where rv.reviewer_id = p_user),
    third as (select dish_id, created_at, id from k where n = 3 order by created_at, id limit 1)
    select t.dish_id, t.created_at,
           (select array_agg(k.entry_id order by k.created_at, k.id) from k where k.dish_id = t.dish_id and k.n <= 3 and k.entry_id is not null) as entries
      into r from third t;
    if found then
      v_added := v_added + public.award_put(p_user, 'same_dish_3', r.created_at, null, r.dish_id,
                                            coalesce(r.entries, '{}'), array[r.dish_id]);
    end if;
  end if;

  -- 5 dishes in one entry.
  if not 'five_in_entry' = any (v_held) then
    select e.id, e.created_at into r
      from public.entries e
     where e.author_id = p_user
       and (select count(*) from public.reviews rv where rv.entry_id = e.id) >= 5
     order by e.created_at, e.id limit 1;
    if found then
      v_added := v_added + public.award_put(p_user, 'five_in_entry', r.created_at, r.id, null, array[r.id]);
    end if;
  end if;

  -- 3 entries in one day: the first day to reach a third entry.
  if not 'three_in_day' = any (v_held) then
    select x.ids[1:3] as ids, x.ats[3] as at into r from (
      select array_agg(e.id order by e.created_at, e.id) as ids,
             array_agg(e.created_at order by e.created_at, e.id) as ats
        from public.entries e where e.author_id = p_user
       group by (e.created_at at time zone public.award_day_zone())::date
      having count(*) >= 3) x
     order by x.ats[3] limit 1;
    if found then
      v_added := v_added + public.award_put(p_user, 'three_in_day', r.at, r.ids[3], null, r.ids);
    end if;
  end if;

  -- 5 different dishes at one place (a line's restaurant is its dish's menu, so a chain is one place).
  if not 'five_at_place' = any (v_held) then
    with firsts as (
      select rv.restaurant_id, rv.dish_id, min(rv.created_at) as at
        from public.reviews rv where rv.reviewer_id = p_user and rv.restaurant_id is not null
       group by rv.restaurant_id, rv.dish_id),
    ranked as (
      select restaurant_id, dish_id, at, row_number() over (partition by restaurant_id order by at, dish_id) as n
        from firsts)
    select array_agg(dish_id order by n) filter (where n <= 5) as dishes, max(at) filter (where n <= 5) as at
      into r
      from ranked group by restaurant_id having count(*) >= 5
     order by 2 limit 1;
    if found then
      v_added := v_added + public.award_put(p_user, 'five_at_place', r.at, null, null, '{}', r.dishes);
    end if;
  end if;

  return v_added;
end; $$;

-- A check that can never fail the write that fired it.
create or replace function public.award_check_quiet(p_user uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
  perform public.award_check(p_user);
exception when others then
  raise warning 'award_check(%) failed: % %', p_user, sqlstate, sqlerrm;
end; $$;

revoke all on function public.place_country(text) from public, anon, authenticated;
revoke all on function public.award_day_zone() from public, anon, authenticated;
revoke all on function public.award_put(uuid, text, timestamptz, uuid, uuid, uuid[], uuid[], uuid) from public, anon, authenticated;
revoke all on function public.award_check(uuid) from public, anon, authenticated;
revoke all on function public.award_check_quiet(uuid) from public, anon, authenticated;
grant execute on function public.place_country(text) to service_role;
grant execute on function public.award_check(uuid) to service_role;

-- ===========================================================================
-- 4. When to check
-- ===========================================================================

-- New lines (the sorter, a correction, ate-with copies): once per reviewer per statement.
create or replace function public.trg_awards_reviews_ins()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare v_user uuid;
begin
  for v_user in select distinct reviewer_id from new_lines where reviewer_id is not null loop
    perform public.award_check_quiet(v_user);
  end loop;
  return null;
end; $$;
drop trigger if exists awards_reviews_ins on public.reviews;
create trigger awards_reviews_ins after insert on public.reviews
  referencing new table as new_lines
  for each statement execute function public.trg_awards_reviews_ins();

-- A score or dish changed on a line (the author's fix).
create or replace function public.trg_awards_reviews_upd()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.award_check_quiet(new.reviewer_id);
  return null;
end; $$;
drop trigger if exists awards_reviews_upd on public.reviews;
create trigger awards_reviews_upd after update of score, dish_id on public.reviews
  for each row when (old.score is distinct from new.score or old.dish_id is distinct from new.dish_id)
  execute function public.trg_awards_reviews_upd();

-- An entry, or its place (entries before they are sorted count for "3 in one day"; the place for the country).
create or replace function public.trg_awards_entries()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.award_check_quiet(new.author_id);
  return null;
end; $$;
drop trigger if exists awards_entries on public.entries;
create trigger awards_entries after insert or update of restaurant_id on public.entries
  for each row execute function public.trg_awards_entries();

-- Someone saves a dish from your entry.
create or replace function public.trg_awards_saves()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.source_user_id is not null and new.source_user_id <> new.user_id then
    perform public.award_check_quiet(new.source_user_id);
  end if;
  return null;
end; $$;
drop trigger if exists awards_saves on public.saves;
create trigger awards_saves after insert or update of source_user_id on public.saves
  for each row execute function public.trg_awards_saves();

-- An ate-with tag, or its answer.
create or replace function public.trg_awards_companions()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.award_check_quiet(new.tagger_id);
  if new.status = 'accepted' then
    perform public.award_check_quiet(new.companion_id);
  end if;
  return null;
end; $$;
drop trigger if exists awards_companions on public.entry_companions;
create trigger awards_companions after insert or update of status on public.entry_companions
  for each row execute function public.trg_awards_companions();

-- A dish gains the drinks or dessert style after it was logged (the sorter's styles land with the sort,
-- the keyword guess on insert): check the people who logged it.
create or replace function public.trg_awards_styles()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare v_user uuid;
begin
  for v_user in
    select distinct rv.reviewer_id
      from new_links l join public.reviews rv on rv.dish_id = l.dish_id
     where l.kind = 'style' and l.slug in ('drinks', 'dessert') and rv.reviewer_id is not null
  loop
    perform public.award_check_quiet(v_user);
  end loop;
  return null;
end; $$;
drop trigger if exists awards_styles on public.dish_tag_links;
create trigger awards_styles after insert on public.dish_tag_links
  referencing new table as new_links
  for each statement execute function public.trg_awards_styles();

revoke all on function public.trg_awards_reviews_ins() from public, anon, authenticated;
revoke all on function public.trg_awards_reviews_upd() from public, anon, authenticated;
revoke all on function public.trg_awards_entries() from public, anon, authenticated;
revoke all on function public.trg_awards_saves() from public, anon, authenticated;
revoke all on function public.trg_awards_companions() from public, anon, authenticated;
revoke all on function public.trg_awards_styles() from public, anon, authenticated;

-- ===========================================================================
-- 5. Reads
-- ===========================================================================

-- A person's awards (yours when p_user is NULL), with the dish, place and score behind each (what the
-- takeover and the plate's backstamp print). At most twenty rows, so no cursor. `seen` is only
-- meaningful on your own: someone else's always reads true. Empty through a block, for a deactivated
-- profile, and signed out.
create or replace function public.awards_of(p_user uuid default null)
returns table (
  award         text,
  earned_at     timestamptz,
  entry_id      uuid,
  dish_id       uuid,
  entry_ids     uuid[],
  dish_ids      uuid[],
  other_user_id   uuid,
  other_handle    text,
  seen            boolean,
  dish_name       text,
  restaurant_name text,
  score           numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with who as (select coalesce(p_user, (select auth.uid())) as id, (select auth.uid()) as me)
  select a.award, a.earned_at, a.entry_id, a.dish_id, a.entry_ids, a.dish_ids,
         case when o.id is null then null else a.other_user_id end,
         o.username::text,
         case when a.user_id = w.me then a.seen_at is not null else true end,
         d.name::text,
         coalesce(re.name, rd.name)::text,
         ln.score
    from who w
    join public.user_awards a on a.user_id = w.id
    join public.profiles p on p.id = a.user_id
    left join public.profiles o
      on o.id = a.other_user_id and o.deleted_at is null and not public.blocked_with(o.id)
    -- the line behind it: its dish on its entry, else the entry's first line
    left join lateral (
      select rv.dish_id, rv.score from public.reviews rv
       where rv.entry_id = a.entry_id and (a.dish_id is null or rv.dish_id = a.dish_id)
       order by rv.entry_position nulls last, rv.created_at, rv.id limit 1) ln on true
    left join public.dishes d on d.id = coalesce(a.dish_id, ln.dish_id, a.dish_ids[1])
    left join public.entries e on e.id = a.entry_id
    left join public.restaurants re on re.id = e.restaurant_id
    left join public.restaurants rd on rd.id = d.restaurant_id
   where w.me is not null
     and (a.user_id = w.me or (p.deleted_at is null and not public.blocked_with(a.user_id)))
   order by a.earned_at desc, a.award;
$$;

-- The takeover has shown these (all of yours when NULL). Returns how many were marked.
create or replace function public.mark_awards_seen(p_awards text[] default null)
returns int
language sql
volatile
security definer
set search_path = public, extensions
as $$
  with upd as (
    update public.user_awards a set seen_at = now()
     where a.user_id = (select auth.uid()) and a.seen_at is null
       and (p_awards is null or a.award = any (p_awards))
    returning 1)
  select count(*)::int from upd;
$$;

-- The dishes behind an opened award, oldest first: a dish count's first N lines ("Your first 25
-- dishes"), the three lines of the same dish, the five dishes of one entry or one place, the dishes
-- of 10 saves. Lines are read under the caller's RLS (blocks apply). Keyset (created_at, review_id).
-- Entry awards (scores, firsts, country, ate with, 3 in a day) open their entries with get_entry_card.
create or replace function public.award_lines(
  p_user uuid, p_award text,
  p_after_at timestamptz default null, p_after_id uuid default null, p_limit int default 60)
returns table (
  review_id       uuid,
  entry_id        uuid,
  dish_id         uuid,
  dish_name       text,
  restaurant_id   uuid,
  restaurant_name text,
  score           numeric,
  created_at      timestamptz,
  photo_url       text)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
declare
  v_a     record;
  v_user  uuid;
  v_limit int := least(greatest(coalesce(p_limit, 60), 1), 100);
  v_n     int;
begin
  if (select auth.uid()) is null then
    return;
  end if;
  -- through awards_of, so a block, a deactivation and signing out apply exactly as on the profile
  select x.entry_id, x.dish_ids into v_a from public.awards_of(p_user) x where x.award = p_award;
  if not found then
    return;
  end if;
  v_user := coalesce(p_user, (select auth.uid()));

  if p_award like 'dishes\_%' then
    v_n := substr(p_award, 8)::int;
    return query
      select x.id, x.entry_id, x.dish_id, x.dname, x.restaurant_id, x.rname, x.score, x.created_at, x.photo
        from (
          select rv.id, rv.entry_id, rv.dish_id, d.name::text as dname, rv.restaurant_id, re.name::text as rname,
                 rv.score, rv.created_at, public.review_photo_url(rv) as photo,
                 row_number() over (order by rv.created_at, rv.id) as n
            from public.reviews rv
            join public.dishes d on d.id = rv.dish_id
            left join public.restaurants re on re.id = rv.restaurant_id
           where rv.reviewer_id = v_user) x
       where x.n <= v_n
         and (p_after_at is null or (x.created_at, x.id) > (p_after_at, p_after_id))
       order by x.created_at, x.id
       limit v_limit;
  elsif p_award = 'five_in_entry' then
    return query
      select rv.id, rv.entry_id, rv.dish_id, d.name::text, rv.restaurant_id, re.name::text, rv.score, rv.created_at,
             public.review_photo_url(rv)
        from public.reviews rv
        join public.dishes d on d.id = rv.dish_id
        left join public.restaurants re on re.id = rv.restaurant_id
       where rv.entry_id = v_a.entry_id
         and (p_after_at is null or (rv.created_at, rv.id) > (p_after_at, p_after_id))
       order by rv.created_at, rv.id
       limit v_limit;
  elsif p_award in ('same_dish_3', 'five_at_place', 'saves_10', 'saved_by_someone') then
    -- the person's first line of each dish (same_dish_3: its first three lines)
    return query
      select x.id, x.entry_id, x.dish_id, x.dname, x.restaurant_id, x.rname, x.score, x.created_at, x.photo
        from (
          select rv.id, rv.entry_id, rv.dish_id, d.name::text as dname, rv.restaurant_id, re.name::text as rname,
                 rv.score, rv.created_at, public.review_photo_url(rv) as photo,
                 row_number() over (partition by rv.dish_id order by rv.created_at, rv.id) as n
            from public.reviews rv
            join public.dishes d on d.id = rv.dish_id
            left join public.restaurants re on re.id = rv.restaurant_id
           where rv.reviewer_id = v_user and rv.dish_id = any (v_a.dish_ids)) x
       where x.n <= case when p_award = 'same_dish_3' then 3 else 1 end
         and (p_after_at is null or (x.created_at, x.id) > (p_after_at, p_after_id))
       order by x.created_at, x.id
       limit v_limit;
  end if;
end; $$;

revoke all on function public.awards_of(uuid) from public, anon;
revoke all on function public.mark_awards_seen(text[]) from public, anon;
revoke all on function public.award_lines(uuid, text, timestamptz, uuid, int) from public, anon;
grant execute on function public.awards_of(uuid) to authenticated, service_role;
grant execute on function public.mark_awards_seen(text[]) to authenticated, service_role;
grant execute on function public.award_lines(uuid, text, timestamptz, uuid, int) to authenticated, service_role;

-- ===========================================================================
-- 6. delete_account verifies the new table too (body as 0094, one line added)
-- ===========================================================================
create or replace function public.delete_account()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_deleted int;
begin
  if v_uid is null then
    raise exception 'delete_account requires an authenticated caller' using errcode = '42501';
  end if;

  delete from auth.users where id = v_uid;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 1 then
    raise exception 'delete_account: no auth user % to delete', v_uid using errcode = 'P0002';
  end if;

  if exists (select 1 from public.profiles       where id = v_uid)
  or exists (select 1 from public.entries        where author_id = v_uid)
  or exists (select 1 from public.reviews        where reviewer_id = v_uid)
  or exists (select 1 from public.saves          where user_id = v_uid)
  or exists (select 1 from public.blocks         where blocker_id = v_uid or blocked_id = v_uid)
  or exists (select 1 from public.reports        where reporter_id = v_uid or profile_id = v_uid)
  or exists (select 1 from public.comments       where user_id = v_uid)
  or exists (select 1 from public.lists          where owner_id = v_uid)
  or exists (select 1 from public.follows        where follower_id = v_uid or followee_id = v_uid)
  or exists (select 1 from public.review_likes   where user_id = v_uid)
  or exists (select 1 from public.comment_likes  where user_id = v_uid)
  or exists (select 1 from public.review_tags    where tagged_user_id = v_uid or tagger_id = v_uid)
  or exists (select 1 from public.notifications  where recipient_id = v_uid or actor_id = v_uid)
  or exists (select 1 from public.sort_preview_cache where author_id = v_uid)
  or exists (select 1 from public.sort_preview_rate  where author_id = v_uid)
  or exists (select 1 from public.user_cravings  where user_id = v_uid)
  or exists (select 1 from public.entry_companions   where tagger_id = v_uid or companion_id = v_uid)
  or exists (select 1 from public.entry_invites      where inviter_id = v_uid or redeemed_by = v_uid)
  or exists (select 1 from public.device_push_tokens where user_id = v_uid)
  or exists (select 1 from public.ate_with_ledger    where actor_id = v_uid or recipient_id = v_uid)
  or exists (select 1 from public.user_lists         where owner_id = v_uid)
  or exists (select 1 from public.user_list_items    where owner_id = v_uid)
  or exists (select 1 from public.user_awards        where user_id = v_uid)
  then
    raise exception 'delete_account: personal rows survived the cascade for %', v_uid
      using errcode = 'P0001';
  end if;

  insert into public.storage_purge_queue (user_id) values (v_uid) on conflict (user_id) do nothing;

  return jsonb_build_object('ok', true, 'auth_user_deleted', true);
end; $$;

-- ===========================================================================
-- 7. Backfill: everyone gets what they have already earned, unseen (one takeover on their next open)
-- ===========================================================================
do $$
declare v_user uuid;
begin
  for v_user in select p.id from public.profiles p
                 where exists (select 1 from public.entries e where e.author_id = p.id)
                    or exists (select 1 from public.reviews rv where rv.reviewer_id = p.id)
  loop
    perform public.award_check_quiet(v_user);
  end loop;
end $$;
