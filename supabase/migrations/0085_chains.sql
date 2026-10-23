-- 0085_chains.sql
-- CHAIN RESTAURANTS ARE ONE PLACE FOR DISHES (23 Oct, Eamon): "If someone had a chicken burrito from
-- GYG, there's no difference between the locations — it's the same dish."
--
--   1. chains: one row per chain. A location joins through restaurants.chain_id. Every location keeps
--      its own row, address and pin, and an entry still records the exact location it was at.
--   2. One menu per chain. A chain's dishes all live at ONE of its locations, the anchor
--      (chains.anchor_restaurant_id), so a dish, its rating, lines and photos are chain-wide with no
--      change to dishes' identity, merge_dish or the review trigger (reviews.restaurant_id stays
--      == dishes.restaurant_id, i.e. the anchor for a chain line). place_menu(place) is the place
--      whose dishes a place shows: the anchor for a chain location, else itself. Every place read
--      (place_dishes, place_summary's numbers, place_numbers for Search/nearby, the cover, the diet
--      filter) and every dish write (find_or_create_dish, the sorter's known dishes, corrections,
--      ate-with) goes through it. place_family(place) is every location of its chain: the entries
--      "at this place" and your visits are chain-wide too.
--   3. A chain dish shows no suburb (dish_locality): it is not at one.
--   4. chain_attach / chain_detach / chain_dissolve. Attaching moves a location's dishes onto the
--      chain's menu: a dish the menu already has (same name or spelling key) is merged into it with
--      merge_dish (reason 'chain', logged, unmerge_dish undoes it); any other dish moves as it is
--      (same id: saves and lists keep pointing at it). Detaching moves that location's lines back to
--      dishes of its own.
--   5. Detection (chain_candidates → chain_record_and_link, driven by places-search and the Prod
--      workflow's backfill, _shared/chains.ts): two Google places are one chain when their names have
--      the same key (dish_key: case, accents, punctuation, plurals) AND their Google websites have the
--      same host. A shared social or ordering host (instagram.com, ubereats.com …) proves nothing and
--      never links. Google gives no chain id; the website costs one Place Details (Enterprise) call per
--      place, made only when its name repeats, and recorded (website_checked_at) so never asked twice.
--
-- WIRE IMPACT: none. Same signatures and columns; a chain location's numbers, dishes and entries are
-- the chain's, and a chain dish's restaurant_locality is NULL.
-- DATA: no row changes here. Linking happens as places are checked (places-search, the Prod backfill).

set search_path = public, extensions;

-- ===========================================================================
-- 1. Chains.
-- ===========================================================================
create table if not exists public.chains (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null,
  website_host         text,
  anchor_restaurant_id uuid not null references public.restaurants(id),
  source               text not null default 'auto' check (source in ('auto', 'manual')),
  created_at           timestamptz not null default now()
);
comment on table public.chains is
  '0085: a chain of restaurants. Its locations point at it (restaurants.chain_id); its dishes all live at anchor_restaurant_id, so every location shows one menu. Service role only.';

alter table public.chains enable row level security;          -- no policy: read through the functions
revoke all on public.chains from public, anon, authenticated;
grant select, insert, update, delete on public.chains to service_role;

alter table public.restaurants add column if not exists chain_id uuid references public.chains(id) on delete set null;
alter table public.restaurants add column if not exists website_host text;
alter table public.restaurants add column if not exists website_checked_at timestamptz;
comment on column public.restaurants.chain_id is '0085: the chain this location belongs to (its dishes are the chain''s, see place_menu).';
comment on column public.restaurants.website_host is '0085: the host of the place''s Google website (lower case, no www.), fetched only when its name repeats.';

create index if not exists restaurants_chain_idx on public.restaurants (chain_id) where chain_id is not null;
create index if not exists restaurants_name_key_idx on public.restaurants (public.dish_key(name)) where source = 'places';

alter table public.dish_merges drop constraint if exists dish_merges_reason_check;
alter table public.dish_merges add constraint dish_merges_reason_check
  check (reason in ('same_name', 'ai', 'manual', 'chain'));

-- ===========================================================================
-- 2. place_menu / place_family / dish_locality.
-- ===========================================================================
-- DEFINER: chains has no client grant. One primary-key lookup.
create or replace function public.place_menu(p_restaurant_id uuid)
returns uuid language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
    (select c.anchor_restaurant_id from public.restaurants r join public.chains c on c.id = r.chain_id
      where r.id = p_restaurant_id),
    p_restaurant_id);
$$;
comment on function public.place_menu(uuid) is
  '0085: the place whose dishes this place shows: its chain''s anchor, else itself.';

create or replace function public.place_family(p_restaurant_id uuid)
returns uuid[] language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
    (select case when r.chain_id is null then array[r.id]
                 else array(select x.id from public.restaurants x where x.chain_id = r.chain_id) end
       from public.restaurants r where r.id = p_restaurant_id),
    array[p_restaurant_id]);
$$;
comment on function public.place_family(uuid) is
  '0085: every location of this place''s chain (just itself when it has none).';

create or replace function public.dish_locality(p_chain_id uuid, p_address text, p_city text)
returns text language sql stable set search_path = public, extensions as $$
  select case when p_chain_id is null then public.place_locality(p_address, p_city) end;
$$;
comment on function public.dish_locality(uuid, text, text) is
  '0085: the suburb shown beside a dish: none for a chain''s dish, which is not at one location.';

revoke all on function public.place_menu(uuid)    from public;
revoke all on function public.place_family(uuid)  from public;
revoke all on function public.dish_locality(uuid, text, text) from public;
grant execute on function public.place_menu(uuid)   to anon, authenticated, service_role;
grant execute on function public.place_family(uuid) to anon, authenticated, service_role;
grant execute on function public.dish_locality(uuid, text, text) to anon, authenticated, service_role;

-- ===========================================================================
-- 3. Attach, detach, dissolve.
-- ===========================================================================
create or replace function public.chain_attach(p_restaurant_id uuid, p_chain_id uuid)
returns int                                     -- dishes moved or merged onto the chain's menu
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_anchor uuid;
  v_cur    uuid;
  d        public.dishes;
  v_target uuid;
  v_n      int := 0;
begin
  select c.anchor_restaurant_id into v_anchor from public.chains c where c.id = p_chain_id;
  if v_anchor is null then
    raise exception 'chain % not found', p_chain_id using errcode = 'P0002';
  end if;
  select r.chain_id into v_cur from public.restaurants r where r.id = p_restaurant_id for update;
  if not found then
    raise exception 'restaurant % not found', p_restaurant_id using errcode = 'P0002';
  end if;
  if v_cur = p_chain_id then
    return 0;
  end if;
  if v_cur is not null then
    raise exception 'restaurant % is in another chain', p_restaurant_id using errcode = '22023';
  end if;

  update public.restaurants set chain_id = p_chain_id where id = p_restaurant_id;
  if p_restaurant_id = v_anchor then
    return 0;
  end if;

  for d in
    select * from public.dishes x
    where x.restaurant_id = p_restaurant_id and x.merged_into_dish_id is null
    order by x.created_at, x.id
  loop
    -- the menu's dish of that name, else of that spelling key (find_or_create_dish's order)
    select m.id into v_target from public.dishes m
    where m.restaurant_id = v_anchor and m.merged_into_dish_id is null and lower(m.name) = lower(d.name)
    limit 1;
    if v_target is null and public.dish_key(d.name) <> '' then
      select m.id into v_target from public.dishes m
      where m.restaurant_id = v_anchor and m.merged_into_dish_id is null
        and public.dish_key(m.name) = public.dish_key(d.name)
      order by m.created_at, m.id
      limit 1;
    end if;

    if v_target is not null then
      perform public.merge_dish(d.id, v_target, 'chain',
                                jsonb_build_object('chain_id', p_chain_id, 'restaurant_id', p_restaurant_id));
    else
      update public.dishes set restaurant_id = v_anchor where id = d.id;
      perform set_config('ate.repointing', 'on', true);
      update public.reviews set restaurant_id = v_anchor where dish_id = d.id;   -- the trigger re-derives it
      perform set_config('ate.repointing', 'off', true);
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end; $$;
comment on function public.chain_attach(uuid, uuid) is
  '0085: a location joins a chain; its dishes move onto the chain''s menu (a dish the menu has is merged into it, logged in dish_merges). Service role only.';

create or replace function public.chain_detach(p_restaurant_id uuid)
returns int                                     -- lines moved back to the location's own dishes
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_chain  uuid;
  v_anchor uuid;
  l        record;
  v_dish   uuid;
  v_n      int := 0;
begin
  select r.chain_id, c.anchor_restaurant_id into v_chain, v_anchor
  from public.restaurants r left join public.chains c on c.id = r.chain_id
  where r.id = p_restaurant_id for update of r;
  if v_chain is null then
    return 0;
  end if;
  if v_anchor = p_restaurant_id and exists (
    select 1 from public.restaurants x where x.chain_id = v_chain and x.id <> p_restaurant_id) then
    raise exception 'restaurant % holds its chain''s menu; dissolve the chain instead', p_restaurant_id
      using errcode = '22023';
  end if;

  update public.restaurants set chain_id = null where id = p_restaurant_id;
  if v_anchor = p_restaurant_id then
    delete from public.chains where id = v_chain;
    return 0;
  end if;

  -- the merges attaching made, newest first: each source dish takes its own lines back
  for l in
    select m.id from public.dish_merges m
    where m.restaurant_id = p_restaurant_id and m.reason = 'chain' and m.undone_at is null
    order by m.id desc
  loop
    begin
      perform public.unmerge_dish(l.id);
    exception when others then
      null;                                       -- built on since: the lines move one by one below
    end;
  end loop;

  -- every other line of its entries (written since it joined) moves to a dish of its own
  perform set_config('ate.repointing', 'on', true);
  for l in
    select v.id, d.name
    from public.reviews v
    join public.entries e on e.id = v.entry_id
    join public.dishes d on d.id = v.dish_id
    where e.restaurant_id = p_restaurant_id and v.restaurant_id = v_anchor
  loop
    v_dish := public.find_or_create_dish(p_restaurant_id, l.name, null);
    update public.reviews set dish_id = v_dish where id = l.id;
    v_n := v_n + 1;
  end loop;
  perform set_config('ate.repointing', 'off', true);
  return v_n;
end; $$;
comment on function public.chain_detach(uuid) is
  '0085: a location leaves its chain; attaching''s merges are undone and the other lines of its entries move to dishes of its own. The anchor can only leave by dissolving the chain. Service role only.';

create or replace function public.chain_dissolve(p_chain_id uuid)
returns int
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_anchor uuid;
  r        record;
  v_n      int := 0;
begin
  select c.anchor_restaurant_id into v_anchor from public.chains c where c.id = p_chain_id for update;
  if v_anchor is null then
    return 0;
  end if;
  for r in select x.id from public.restaurants x where x.chain_id = p_chain_id and x.id <> v_anchor loop
    v_n := v_n + public.chain_detach(r.id);
  end loop;
  perform public.chain_detach(v_anchor);           -- the last one: deletes the chain
  return v_n;
end; $$;
comment on function public.chain_dissolve(uuid) is
  '0085: undo a chain: every location takes its own lines back. Service role only.';

-- ===========================================================================
-- 4. Detection.
-- ===========================================================================
-- A host many unrelated places share proves nothing.
create or replace function public.chain_shared_host(p_host text)
returns boolean language sql immutable parallel safe set search_path = public, extensions as $$
  select p_host is null or btrim(p_host) = '' or exists (
    select 1 from unnest(array[
      'facebook.com', 'fb.com', 'instagram.com', 'tiktok.com', 'twitter.com', 'x.com', 'youtube.com',
      'linktr.ee', 'linkin.bio', 'beacons.ai', 'bio.link', 'carrd.co',
      'google.com', 'goo.gl', 'g.page', 'business.site', 'sites.google.com',
      'ubereats.com', 'doordash.com', 'menulog.com.au', 'deliveroo.com.au', 'grubhub.com',
      'mryum.com', 'mryum.page', 'bopple.app', 'hungryhungry.com', 'orderup.com.au', 'abacus.co',
      'square.site', 'squareup.com', 'wixsite.com', 'wix.com', 'squarespace.com', 'weebly.com',
      'wordpress.com', 'shopify.com', 'myshopify.com', 'toasttab.com', 'order.online',
      'opentable.com', 'opentable.com.au', 'resy.com', 'sevenrooms.com', 'quandoo.com.au',
      'yelp.com', 'tripadvisor.com', 'zomato.com', 'broadsheet.com.au'
    ]) g
    where lower(p_host) = g or lower(p_host) like '%.' || g);
$$;

-- The places that share a name with one of p_ids (or, when p_ids is null, any unchained place whose
-- name repeats: the backfill), with whether their website is known yet. Unchained Google places only
-- on the asking side; a sibling may already be in a chain.
create or replace function public.chain_candidates(p_ids uuid[] default null, p_limit int default 50)
returns table (restaurant_id uuid, google_place_id text, checked boolean)
language sql stable security definer set search_path = public, extensions as $$
  with asking as (
    select r.id, public.dish_key(r.name) as k
    from public.restaurants r
    where r.source = 'places' and r.chain_id is null
      and (p_ids is null or r.id = any (p_ids))
      and public.dish_key(r.name) <> ''
  ),
  keys as (
    select distinct a.k from asking a
    where exists (select 1 from public.restaurants x
                  where x.source = 'places' and public.dish_key(x.name) = a.k and x.id <> a.id)
  )
  select x.id, x.google_place_id, x.website_checked_at is not null
  from keys k
  join public.restaurants x on x.source = 'places' and public.dish_key(x.name) = k.k
  order by x.website_checked_at nulls first, x.created_at, x.id
  limit least(greatest(coalesce(p_limit, 50), 1), 500);
$$;

-- Record the websites fetched for some places, then link every place in p_ids into its chain where a
-- same-name place has the same website host. Returns the chains touched.
create or replace function public.chain_record_and_link(p_websites jsonb, p_ids uuid[])
returns uuid[]
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  w        jsonb;
  v_id     uuid;
  r        public.restaurants;
  v_chain  uuid;
  v_anchor uuid;
  v_out    uuid[] := '{}';
  s        record;
begin
  for w in select * from jsonb_array_elements(coalesce(p_websites, '[]'::jsonb)) loop
    update public.restaurants
       set website_host = nullif(lower(btrim(w ->> 'host')), ''), website_checked_at = now()
     where id = (w ->> 'id')::uuid;
  end loop;

  foreach v_id in array coalesce(p_ids, '{}') loop
    select * into r from public.restaurants x where x.id = v_id;
    continue when r.id is null or r.source <> 'places' or r.chain_id is not null
               or public.chain_shared_host(r.website_host) or public.dish_key(r.name) = '';

    -- a chain that already has a location of this name and host
    select c.id into v_chain
    from public.chains c join public.restaurants x on x.chain_id = c.id
    where x.website_host = r.website_host and public.dish_key(x.name) = public.dish_key(r.name)
    limit 1;

    if v_chain is null then
      if not exists (select 1 from public.restaurants x
                     where x.id <> r.id and x.source = 'places' and x.chain_id is null
                       and x.website_host = r.website_host and public.dish_key(x.name) = public.dish_key(r.name)) then
        continue;
      end if;
      -- the anchor: the location with the most live dishes, then the oldest
      select x.id into v_anchor
      from public.restaurants x
      where x.source = 'places' and x.chain_id is null
        and x.website_host = r.website_host and public.dish_key(x.name) = public.dish_key(r.name)
      order by (select count(*) from public.dishes d where d.restaurant_id = x.id and d.merged_into_dish_id is null) desc,
               x.created_at, x.id
      limit 1;
      insert into public.chains (name, website_host, anchor_restaurant_id)
      select x.name, r.website_host, x.id from public.restaurants x where x.id = v_anchor
      returning id into v_chain;
      perform public.chain_attach(v_anchor, v_chain);
    end if;

    for s in
      select x.id from public.restaurants x
      where x.source = 'places' and x.chain_id is null
        and x.website_host = r.website_host and public.dish_key(x.name) = public.dish_key(r.name)
      order by x.created_at, x.id
    loop
      perform public.chain_attach(s.id, v_chain);
    end loop;
    if not v_chain = any (v_out) then
      v_out := v_out || v_chain;
    end if;
  end loop;
  return v_out;
end; $$;

revoke all on function public.chain_attach(uuid, uuid)                from public, anon, authenticated;
revoke all on function public.chain_detach(uuid)                      from public, anon, authenticated;
revoke all on function public.chain_dissolve(uuid)                    from public, anon, authenticated;
revoke all on function public.chain_shared_host(text)                 from public, anon, authenticated;
revoke all on function public.chain_candidates(uuid[], int)           from public, anon, authenticated;
revoke all on function public.chain_record_and_link(jsonb, uuid[])    from public, anon, authenticated;
grant execute on function public.chain_attach(uuid, uuid)             to service_role;
grant execute on function public.chain_detach(uuid)                   to service_role;
grant execute on function public.chain_dissolve(uuid)                 to service_role;
grant execute on function public.chain_shared_host(text)              to service_role;
grant execute on function public.chain_candidates(uuid[], int)        to service_role;
grant execute on function public.chain_record_and_link(jsonb, uuid[]) to service_role;

-- ===========================================================================
-- 5. The reads and writes, through place_menu / place_family (same signatures; bodies as before
--    apart from the marked lines).
-- ===========================================================================
create or replace view public.restaurant_stats
with (security_invoker = true) as
  select
    rst.id                                  as restaurant_id,
    a.avg_rating,
    a.review_count,
    public.restaurant_cover_url(rst.id)     as cover_url,
    p.people_count,
    a.dish_count
  from public.restaurants rst
  cross join lateral (
    select round(avg(ds.score) filter (where ds.score is not null), 1)::numeric(2,1) as avg_rating,
           coalesce(sum(ds.review_count), 0)::int                                   as review_count,
           count(ds.dish_id) filter (where ds.review_count > 0)::int                as dish_count
    from (
      select round(avg(r.score), 1)::numeric(2,1) as score, count(r.id)::int as review_count, d.id as dish_id
      from public.dishes d
      left join public.reviews r on r.dish_id = d.id
      where d.restaurant_id = public.place_menu(rst.id) and d.merged_into_dish_id is null
      group by d.id
    ) ds
  ) a
  cross join lateral (
    select count(distinct rp.reviewer_id)::int as people_count
    from public.reviews rp
    where rp.restaurant_id = public.place_menu(rst.id)
  ) p;

create or replace function public.place_numbers(p_restaurant_id uuid, p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS TABLE(avg_rating numeric, review_count integer, people_count integer, dish_count integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  with per_dish as (
    select round(avg(v.score), 1)::numeric(2,1) as score, count(*)::int as n
    from public.dishes d
    join public.reviews v on v.dish_id = d.id
    where d.restaurant_id = public.place_menu(p_restaurant_id)
      and d.merged_into_dish_id is null
      and (p_start is null or v.created_at >= p_start)
      and (p_end   is null or v.created_at <  p_end)
    group by d.id
  )
  select (select round(avg(pd.score) filter (where pd.score is not null), 1)::numeric(2,1) from per_dish pd),
         (select coalesce(sum(pd.n), 0)::int from per_dish pd),
         (select count(distinct v.reviewer_id)::int from public.reviews v
           where v.restaurant_id = public.place_menu(p_restaurant_id)
             and (p_start is null or v.created_at >= p_start)
             and (p_end   is null or v.created_at <  p_end)),
         (select count(*)::int from per_dish);
$function$;

create or replace function public.place_dishes(p_restaurant_id uuid, p_limit integer DEFAULT 50, p_cursor_review_count integer DEFAULT NULL::integer, p_cursor_score numeric DEFAULT NULL::numeric, p_cursor_dish_name text DEFAULT NULL::text, p_cursor_dish_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(dish_id uuid, dish_name text, score numeric, people_count integer, review_count integer, cover_url text, tags text[], diet_counts jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
#variable_conflict use_column
begin
  p_restaurant_id := public.place_menu(p_restaurant_id);   -- a chain's locations share one menu (0085)
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
$function$;

create or replace function public.restaurant_cover_url(p_restaurant_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  select coalesce(v.photo_url, ep.photo_url)
  from public.reviews v
  left join lateral (
    select x.photo_url
    from public.entry_photos x
    where x.entry_id = v.entry_id
    order by x.position, x.created_at
    limit 1
  ) ep on true
  where v.restaurant_id = public.place_menu(p_restaurant_id)
    and (v.photo_url is not null or ep.photo_url is not null)
  order by v.created_at desc, v.id desc
  limit 1;
$function$;

create or replace function public.place_has_tagged_dish(p_restaurant_id uuid, p_tags text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  select exists (
    select 1
    from (
      select distinct v.dish_id
      from public.reviews v
      where v.restaurant_id = public.place_menu(p_restaurant_id)
        and public.diet_tags_implied(v.tags) && p_tags
    ) c
    join public.dishes d on d.id = c.dish_id and d.merged_into_dish_id is null
    where public.dish_consensus_tags(c.dish_id) @> p_tags
  );
$function$;

create or replace function public.get_entries_at_place(p_restaurant_id uuid, p_scope text DEFAULT 'all'::text, p_cursor_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_cursor_id uuid DEFAULT NULL::uuid, p_page_size integer DEFAULT 20)
 RETURNS SETOF entry_cards
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.get_entries_at_place(p_restaurant_id, p_scope, p_cursor_created_at, p_cursor_id, p_page_size);
    return;
  end if;

  -- Signed in: unchanged.
  return query
  select c.*
  from public.entry_cards c
  where c.restaurant_id = any (public.place_family(p_restaurant_id))
    and case p_scope
          when 'mine'   then c.author_id  = (select auth.uid())
          when 'others' then c.author_id <> (select auth.uid())
          else true
        end
    and (
      p_cursor_created_at is null
      or (c.created_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(p_page_size, 1), 50);
end;
$function$;

create or replace function public.place_summary(p_restaurant_id uuid)
 RETURNS TABLE(restaurant_id uuid, name text, address text, city text, cuisine text, cover_url text, avg_rating numeric, review_count integer, people_count integer, dish_count integer, my_visits integer, my_last_visit timestamp with time zone, locality text, entry_count integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.place_summary(p_restaurant_id);
    return;
  end if;

  -- Signed in: unchanged.
  return query
  select
    r.id, r.name,
    nullif(btrim(r.address), ''), nullif(btrim(r.city), ''), nullif(btrim(r.cuisine), ''),
    nullif(btrim(coalesce(rs.cover_url, r.cover_url)), ''),
    rs.avg_rating, coalesce(rs.review_count, 0), coalesce(rs.people_count, 0),
    coalesce(rs.dish_count, 0),
    coalesce(mine.visits, 0), mine.last_visit,
    public.place_locality(r.address, r.city),
    coalesce(here.visits, 0)
  from public.restaurants r
  left join public.restaurant_stats rs on rs.restaurant_id = r.id
  left join lateral (
    select count(*)::int as visits, max(e.created_at) as last_visit
    from public.entries e
    where e.restaurant_id = any (public.place_family(r.id)) and e.author_id = (select auth.uid())
  ) mine on true
  left join lateral (
    select count(*)::int as visits
    from public.entries e
    where e.restaurant_id = any (public.place_family(r.id))
  ) here on true
  where r.id = p_restaurant_id;
end;
$function$;

create or replace function public.sort_entry_context(p_entry_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  select jsonb_build_object(
    'entry', jsonb_build_object(
      'id', e.id, 'author_id', e.author_id, 'body', e.body, 'restaurant_id', e.restaurant_id,
      'restaurant_source', e.restaurant_source, 'sort_status', e.sort_status, 'sort_plan', e.sort_plan),
    -- the pinned place (user-chosen only: a sorter-matched place is re-resolved from the words)
    'place_name', r.name,
    'known_dishes', case when r.id is null then null else coalesce((
      select jsonb_agg(d.name)
      from (select x.name from public.dishes x
             where x.restaurant_id = public.place_menu(r.id) and x.merged_into_dish_id is null
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
$function$;

create or replace function public.correct_entry_dish(p_review_id uuid, p_dish_id uuid DEFAULT NULL::uuid, p_dish_name text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_author   uuid;
  v_rid      uuid;
  v_dish     uuid;
  v_was      text;
  v_was_from text;
begin
  select v.reviewer_id, e.restaurant_id, d.name, v.corrected_from_name
    into v_author, v_rid, v_was, v_was_from
  from public.reviews v
  join public.entries e on e.id = v.entry_id
  left join public.dishes d on d.id = v.dish_id
  where v.id = p_review_id;

  if v_author is null or v_author <> (select auth.uid()) then
    raise exception 'review % not found or not yours', p_review_id using errcode = '42501';
  end if;
  if v_rid is null then
    raise exception 'entry has no place yet — correct the place first' using errcode = '22023';
  end if;

  if p_dish_id is not null then
    select d.id into v_dish
    from public.dishes d
    where d.id = p_dish_id and d.restaurant_id = public.place_menu(v_rid) and d.merged_into_dish_id is null;
    if v_dish is null then
      raise exception 'dish % is not a live dish at this place', p_dish_id using errcode = '23503';
    end if;
  else
    v_dish := public.find_or_create_dish(v_rid, p_dish_name, v_author);
  end if;

  update public.reviews
     set dish_id             = v_dish,
         corrected_at        = now(),
         corrected_from_name = coalesce(v_was_from, v_was)
   where id = p_review_id;

  return v_dish;
end; $function$;

create or replace function public.respond_ate_with(p_companion_id uuid, p_entry_id uuid, p_items jsonb, p_body text DEFAULT ''::text)
 RETURNS SETOF entry_cards
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_uid   uuid := (select auth.uid());
  v_c     public.entry_companions;
  v_e     public.entries;
  v_item  jsonb;
  v_dish  uuid;
  v_name  text;
  v_pos   int := 0;
  v_seen  uuid[] := '{}';
  v_body  text := coalesce(p_body, '');
begin
  select * into v_c from public.entry_companions c
  where c.id = p_companion_id and c.companion_id = v_uid
  for update;
  if not found or public.blocked_with(v_c.tagger_id) then
    raise exception 'tag_not_found' using errcode = 'P0002';
  end if;
  if v_c.status = 'accepted' then
    if v_c.response_entry_id = p_entry_id then
      return query select c.* from public.entry_cards c where c.id = p_entry_id;   -- a retry
      return;
    end if;
    raise exception 'already_responded' using errcode = '23505';
  end if;
  if v_c.status = 'declined' then
    raise exception 'tag_declined' using errcode = '22023';
  end if;
  if p_entry_id is null then
    raise exception 'p_entry_id required' using errcode = '22023';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 50 then
    raise exception 'p_items must be an array of at most 50 objects' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) = 0 and btrim(v_body) = '' then
    raise exception 'nothing_to_post' using errcode = '22023';
  end if;

  select * into v_e from public.entries where id = v_c.entry_id;

  insert into public.entries (id, author_id, body, restaurant_id, created_at)
  values (p_entry_id, v_uid, v_body, v_e.restaurant_id, v_e.created_at);   -- same visit, same time

  for v_item in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(v_item) <> 'object' or jsonb_typeof(v_item -> 'dish_id') <> 'string' then
      raise exception 'each item needs a dish_id' using errcode = '22023';
    end if;
    select coalesce(m.id, d.id), coalesce(m.name, d.name) into v_dish, v_name
    from public.dishes d
    left join public.dishes m on m.id = d.merged_into_dish_id
    where d.id = (v_item ->> 'dish_id')::uuid and public.place_menu(d.restaurant_id) = public.place_menu(v_e.restaurant_id);
    if v_dish is null then
      raise exception 'dish_not_at_place' using errcode = '22023';
    end if;
    continue when v_dish = any(v_seen);                -- one line per dish
    v_seen := v_seen || v_dish;
    v_pos := v_pos + 1;
    insert into public.reviews
      (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, created_at, tags,
       corrected_at, corrected_from_name)
    values
      (v_uid, v_dish, v_e.restaurant_id, p_entry_id, v_pos,
       case when jsonb_typeof(v_item -> 'score') = 'number' then (v_item ->> 'score')::numeric end,
       v_e.created_at,
       case when jsonb_typeof(v_item -> 'tags') = 'array'
            then array(select jsonb_array_elements_text(v_item -> 'tags')) else '{}'::text[] end,
       now(), v_name);
  end loop;

  -- The receipt is printed: the lines are the user's. (Words, if any, may still be run through
  -- sort-entry with force — the corrected lines survive it and anything else the words name is added.)
  update public.entries
     set sort_status = 'sorted', sort_mode = 'companion', sorted_at = now()
   where id = p_entry_id;

  update public.entry_companions
     set status = 'accepted', response_entry_id = p_entry_id, responded_at = now()
   where id = v_c.id;
  update public.notifications set read_at = coalesce(read_at, now()), dismissed_at = now()
   where companion_id = v_c.id and dismissed_at is null;

  return query select c.* from public.entry_cards c where c.id = p_entry_id;
end; $function$;

create or replace function public.dish_summary(p_dish_id uuid)
 RETURNS TABLE(dish_id uuid, dish_name text, restaurant_id uuid, restaurant_name text, restaurant_city text, score numeric, review_count integer, scored_count integer, people_count integer, cover_url text, saved boolean, my_last_score numeric, photos jsonb, restaurant_locality text, tags text[], diet_counts jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
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
    public.dish_locality(r.chain_id, r.address, r.city),
    public.dish_consensus_tags(d.id),
    public.dish_diet_counts(d.id)
  from public.dishes d
  join public.restaurants r on r.id = d.restaurant_id
  left join public.dish_stats ds on ds.dish_id = d.id
  where d.id = p_dish_id;
end;
$function$;

create or replace function public.search_dishes(p_query text, p_limit integer DEFAULT 20, p_cursor_match_tier integer DEFAULT NULL::integer, p_cursor_review_count integer DEFAULT NULL::integer, p_cursor_dish_name text DEFAULT NULL::text, p_cursor_dish_id uuid DEFAULT NULL::uuid, p_cuisines text[] DEFAULT NULL::text[], p_tags text[] DEFAULT NULL::text[], p_min_score numeric DEFAULT NULL::numeric, p_max_score numeric DEFAULT NULL::numeric, p_city text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_tz text DEFAULT 'Australia/Melbourne'::text)
 RETURNS TABLE(dish_id uuid, dish_name text, restaurant_id uuid, restaurant_name text, restaurant_locality text, score numeric, review_count integer, scored_count integer, people_count integer, cover_url text, match_tier integer, tags text[])
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim,
           public.search_filter_keys(p_cuisines) as cuisines,
           public.search_filter_keys(p_tags)     as tags,
           case when p_from is not null then (select w.start_at from public.window_bounds(p_from, p_to, p_tz) w) end as start_at,
           case when p_to   is not null then (select w.end_at   from public.window_bounds(p_from, p_to, p_tz) w) end as end_at
  ),
  hits as (
    select d.id as dish_id, d.name as dish_name, r.id as restaurant_id, r.name as restaurant_name,
           public.dish_locality(r.chain_id, r.address, r.city)             as restaurant_locality,
           public.search_tier(public.search_key(d.name), q.key) as match_tier
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    cross join q
    where char_length(q.key) >= 2
      and d.merged_into_dish_id is null
      and public.search_key(d.name) like '%' || q.pat || '%'
      and (q.cuisines is null or lower(btrim(coalesce(r.cuisine, ''))) = any(q.cuisines))
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
  ),
  page as (
    select h.dish_id, h.dish_name, h.restaurant_id, h.restaurant_name, h.restaurant_locality,
           n.score, n.review_count, n.scored_count, n.people_count, h.match_tier
    from hits h
    cross join q
    cross join lateral public.dish_numbers(h.dish_id, q.start_at, q.end_at) n
    where n.review_count > 0
      and public.score_in_range(n.score, p_min_score, p_max_score)
      and (q.tags is null or public.dish_consensus_tags(h.dish_id) @> q.tags)
      and (p_cursor_dish_id is null
           or (h.match_tier, -n.review_count, h.dish_name, h.dish_id)
              > (coalesce(p_cursor_match_tier, 0), -coalesce(p_cursor_review_count, 0),
                 coalesce(p_cursor_dish_name, ''), p_cursor_dish_id))
    order by h.match_tier, n.review_count desc, h.dish_name, h.dish_id
    limit (select lim from q)
  )
  select p.dish_id, p.dish_name, p.restaurant_id, p.restaurant_name, p.restaurant_locality,
         p.score, p.review_count, p.scored_count, p.people_count,
         nullif(btrim(coalesce(public.dish_cover_url(p.dish_id), '')), ''), p.match_tier,
         public.dish_consensus_tags(p.dish_id)
  from page p
  order by p.match_tier, p.review_count desc, p.dish_name, p.dish_id;
$function$;

create or replace function public.search_saved(p_query text DEFAULT NULL::text, p_limit integer DEFAULT 20, p_cursor_saved_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_cursor_dish_id uuid DEFAULT NULL::uuid, p_min_score numeric DEFAULT NULL::numeric, p_max_score numeric DEFAULT NULL::numeric, p_city text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_tz text DEFAULT 'Australia/Melbourne'::text)
 RETURNS TABLE(dish_id uuid, dish_name text, restaurant_id uuid, restaurant_name text, restaurant_city text, restaurant_locality text, dish_score numeric, dish_cover_url text, source_entry_id uuid, source_user_id uuid, source_username citext, saved_at timestamp with time zone, cover_url text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim,
           case when p_from is not null then (select w.start_at from public.window_bounds(p_from, p_to, p_tz) w) end as start_at,
           case when p_to   is not null then (select w.end_at   from public.window_bounds(p_from, p_to, p_tz) w) end as end_at
  ),
  page as (
    select s.dish_id, d.name as dish_name, r.id as restaurant_id, r.name as restaurant_name,
           nullif(btrim(coalesce(r.city, '')), '')  as restaurant_city,
           public.dish_locality(r.chain_id, r.address, r.city) as restaurant_locality,
           n.score                                  as dish_score,
           (d.merged_into_dish_id is null)          as live,
           s.source_entry_id, s.source_user_id, s.created_at as saved_at
    from public.saves s
    join public.dishes d      on d.id = s.dish_id
    join public.restaurants r on r.id = d.restaurant_id
    cross join q
    -- dish_stats' numbers: a merged-away dish has none (the view lists live dishes only)
    left join lateral (
      select dn.score from public.dish_numbers(s.dish_id, null, null) dn where d.merged_into_dish_id is null
    ) n on true
    where s.user_id = (select auth.uid())
      and (
        q.key = ''
        or public.search_key(d.name) like '%' || q.pat || '%'
        or public.search_key(r.name) like '%' || q.pat || '%'
      )
      and public.score_in_range(n.score, p_min_score, p_max_score)
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
      and (q.start_at is null or s.created_at >= q.start_at)
      and (q.end_at   is null or s.created_at <  q.end_at)
      and (p_cursor_dish_id is null or (s.created_at, s.dish_id) < (p_cursor_saved_at, p_cursor_dish_id))
    order by s.created_at desc, s.dish_id desc
    limit (select lim from q)
  ),
  covered as (
    select p.*, case when p.live then nullif(btrim(coalesce(public.dish_cover_url(p.dish_id), '')), '') end as cover
    from page p
  )
  select c.dish_id, c.dish_name, c.restaurant_id, c.restaurant_name, c.restaurant_city, c.restaurant_locality,
         c.dish_score, c.cover, c.source_entry_id, c.source_user_id, sp.username, c.saved_at, c.cover
  from covered c
  left join public.profiles sp on sp.id = c.source_user_id
  order by c.saved_at desc, c.dish_id desc;
$function$;

create or replace function public.search_all(p_query text, p_limit_per_kind integer DEFAULT 10)
 RETURNS TABLE(kind text, id uuid, title text, subtitle text, score numeric, match_rank real, detail jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(p_limit_per_kind, 1), 25) as lim
  ),
  place_hits as (
    select 'place'::text as kind, r.id, r.name as title,
           coalesce(nullif(btrim(coalesce(r.cuisine, '')), ''),
                    public.place_locality(r.address, r.city)) as subtitle,
           rs.avg_rating as score,
           similarity(public.search_key(r.name), q.key)::real as match_rank,
           jsonb_build_object('city', r.city, 'cuisine', r.cuisine, 'address', r.address,
                              'locality', public.place_locality(r.address, r.city),
                              'people_count', coalesce(rs.people_count, 0)) as detail
    from public.restaurants r
    left join public.restaurant_stats rs on rs.restaurant_id = r.id
    cross join q
    where char_length(q.key) >= 2
      and public.search_key(r.name) like '%' || q.pat || '%'
    order by similarity(public.search_key(r.name), q.key) desc, r.name, r.id
    limit (select lim from q)
  ),
  dish_hits as (
    select 'dish'::text as kind, d.id, d.name as title, r.name as subtitle,
           ds.score,
           similarity(public.search_key(d.name), q.key)::real as match_rank,
           jsonb_build_object('restaurant_id', r.id, 'restaurant_city', r.city,
                              'restaurant_locality', public.dish_locality(r.chain_id, r.address, r.city),
                              'people_count', coalesce(ds.people_count, 0),
                              'cover_url', ds.cover_url) as detail
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    left join public.dish_stats ds on ds.dish_id = d.id
    cross join q
    where char_length(q.key) >= 2
      and d.merged_into_dish_id is null
      and public.search_key(d.name) like '%' || q.pat || '%'
    order by similarity(public.search_key(d.name), q.key) desc, d.name, d.id
    limit (select lim from q)
  ),
  people_hits as (
    select 'person'::text as kind, p.id, p.username::text as title, p.name as subtitle,
           null::numeric(2,1) as score,
           greatest(similarity(public.search_key(p.username::text), q.key),
                    similarity(public.search_key(p.name), q.key))::real as match_rank,
           jsonb_build_object('avatar_url', p.avatar_url, 'city', p.city) as detail
    from public.profiles p
    cross join q
    where char_length(q.key) >= 2
      and p.deleted_at is null
      and (public.search_key(p.username::text) like '%' || q.pat || '%'
           or public.search_key(p.name)        like '%' || q.pat || '%')
    order by greatest(similarity(public.search_key(p.username::text), q.key),
                      similarity(public.search_key(p.name), q.key)) desc, p.username, p.id
    limit (select lim from q)
  )
  select * from place_hits
  union all select * from dish_hits
  union all select * from people_hits;
$function$;

create or replace function public.top_ate(p_city text DEFAULT NULL::text, p_limit integer DEFAULT 8)
 RETURNS TABLE(rank integer, dish_id uuid, name text, restaurant_id uuid, restaurant_name text, suburb text, score numeric, review_count integer, cover_url text, saved boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
#variable_conflict use_column
declare
  v_uid    uuid   := auth.uid();
  v_lim    int    := least(greatest(coalesce(p_limit, 8), 1), 20);
  v_places uuid[];
begin
  if current_user = 'anon' then
    return query select * from browse.top_ate(p_city, p_limit);
    return;
  end if;
  v_places := public.city_places(p_city);

  return query
  with stats as (
    -- every dish's all-time numbers over the lines the viewer can see (dish_stats' rule)
    select v.dish_id,
           round(avg(v.score), 1)::numeric(2,1) as score,
           count(*)::int                        as review_count,
           max(v.created_at)                    as last_at
    from public.reviews v
    where v_places is null or v.restaurant_id = any(v_places)
    group by v.dish_id
    having count(distinct v.reviewer_id) filter (where v.score is not null) >= 2
  ),
  live as (
    select s.dish_id, s.score, s.review_count, s.last_at, d.name, d.restaurant_id
    from stats s
    join public.dishes d on d.id = s.dish_id and d.merged_into_dish_id is null
  ),
  win as (
    select case
             when count(*) filter (where l.last_at >= now() - interval '7 days')  >= v_lim then now() - interval '7 days'
             when count(*) filter (where l.last_at >= now() - interval '30 days') >= v_lim then now() - interval '30 days'
             else '-infinity'::timestamptz
           end as since
    from live l
  ),
  pool as (
    select l.* from live l cross join win where l.last_at >= win.since
  ),
  -- only a dish scoring at least the v_lim-th best can make the page: covers for those alone
  cut as (
    select coalesce(min(x.score), -1) as floor
    from (select p.score from pool p order by p.score desc limit v_lim) x
  ),
  covered as (
    select p.*, nullif(btrim(coalesce(public.dish_cover_url(p.dish_id), '')), '') as cover_url
    from pool p cross join cut
    where p.score >= cut.floor
  ),
  ranked as (
    select c.*,
           row_number() over (order by c.score desc, (c.cover_url is not null) desc, c.review_count desc,
                                       lower(c.name), c.dish_id)::int as pos
    from covered c
  )
  select r.pos, r.dish_id, r.name, r.restaurant_id, rs.name, public.dish_locality(rs.chain_id, rs.address, rs.city),
         r.score, r.review_count, r.cover_url,
         (v_uid is not null and exists (select 1 from public.saves s where s.user_id = v_uid and s.dish_id = r.dish_id))
  from ranked r
  join public.restaurants rs on rs.id = r.restaurant_id
  where r.pos <= v_lim
  order by r.pos;
end;
$function$;

create or replace function public.new_to_record(p_city text DEFAULT NULL::text, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 6, p_kind text DEFAULT NULL::text, p_slug text DEFAULT NULL::text)
 RETURNS TABLE(dish_id uuid, name text, restaurant_name text, suburb text, kind text, cover_url text, saved boolean, at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
#variable_conflict use_column
declare
  v_uid    uuid        := auth.uid();
  -- the client's last open, NULL → 7 days; clamped to 90 days back (a long absence is not a scan of everything)
  v_since  timestamptz := greatest(coalesce(p_since, now() - interval '7 days'), now() - interval '90 days');
  v_lim    int         := least(greatest(coalesce(p_limit, 6), 1), 20);
  v_places uuid[];
  v_tagged uuid[];
begin
  if current_user = 'anon' then
    return query select * from browse.new_to_record(p_city, p_since, p_limit, p_kind, p_slug);
    return;
  end if;
  v_places := public.city_places(p_city);
  v_tagged := public.tag_dish_ids(p_kind, p_slug);

  return query
  with recent as (
    select v.dish_id,
           max(v.created_at) filter (where v.score = 6) as six_at,
           max(v.created_at) filter (where v.score = 5) as five_at
    from public.reviews v
    where v.created_at > v_since
      and (v_places is null or v.restaurant_id = any(v_places))
      and (v_tagged is null or v.dish_id = any(v_tagged))
      and (v_uid is null or v.reviewer_id <> v_uid)
    group by v.dish_id
  ),
  judged as (
    select r.dish_id,
           case when r.six_at  is not null then 'six'
                when r.five_at is not null then 'five'
                when f.created_at > v_since and (v_uid is null or f.reviewer_id <> v_uid) then 'new'
           end as kind,
           coalesce(r.six_at, r.five_at, f.created_at) as at
    from recent r
    cross join lateral (
      select v.reviewer_id, v.created_at from public.reviews v
      where v.dish_id = r.dish_id
      order by v.created_at, v.id
      limit 1
    ) f
  ),
  page as (
    select j.dish_id, j.kind, j.at, d.name, d.restaurant_id
    from judged j
    join public.dishes d on d.id = j.dish_id and d.merged_into_dish_id is null
    where j.kind is not null
    order by case j.kind when 'six' then 0 when 'five' then 1 else 2 end, j.at desc, j.dish_id
    limit v_lim
  )
  select p.dish_id, p.name, rs.name, public.dish_locality(rs.chain_id, rs.address, rs.city), p.kind,
         nullif(btrim(coalesce(public.dish_cover_url(p.dish_id), '')), ''),
         (v_uid is not null and exists (select 1 from public.saves s where s.user_id = v_uid and s.dish_id = p.dish_id)),
         p.at
  from page p
  join public.restaurants rs on rs.id = p.restaurant_id
  order by case p.kind when 'six' then 0 when 'five' then 1 else 2 end, p.at desc, p.dish_id;
end;
$function$;

create or replace function public.find_or_create_dish(p_restaurant_id uuid, p_name text, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
  p_restaurant_id := public.place_menu(p_restaurant_id);   -- a chain location's dishes live on its chain's menu (0085)
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
end; $function$;

create or replace function public.merge_dish(p_source uuid, p_target uuid, p_reason text DEFAULT 'manual'::text, p_detail jsonb DEFAULT NULL::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
  if coalesce(p_reason, '') not in ('same_name', 'ai', 'manual', 'chain') then
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
  if public.place_menu(v_src.restaurant_id) <> public.place_menu(v_tgt.restaurant_id) then   -- one place, or one chain (0085)
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
end; $function$;
