-- 0103_same_day_one_entry.sql
-- Ate backend — one place, one day, one entry (Eamon, 2 Nov: "any reviews from the same restaurant on
-- the same day should be grouped into one review post"; mockup same-day-one-entry, option A).
--
-- Before: answering an "ate with" tag always made a NEW entry, so someone who had already posted their
-- lunch at Tipo 00 and was then tagged in a friend's Tipo 00 entry ended up with two Tipo 00 receipts
-- for one sitting, the dishes they had already scored offered to them again.
--
-- Now:
--   * same_day_entry(author, place, at) — the author's FIRST entry at that place on that day. A day is
--     a Melbourne calendar day (award_day_zone(), as "3 in a day" counts them). Read by entries_author_idx.
--   * my_same_day_entry(place, at) — the composer's question before it posts: the caller's entry there
--     that day, as an entry_cards row, or none. The app then ADDS its words, photos and people to that
--     entry (an edit in the author's own hand) instead of inserting a second one.
--   * ate_with_prefill + `my_entry_id` and `my_dish_ids` (additive): the tagged person's same-day entry
--     at the tagger's place, and the dishes already on it. The sheet leaves those dishes out; with
--     none left, the app answers with nothing and opens their entry.
--   * respond_ate_with — when the person already has an entry at that place that day, the answer goes
--     INTO it: new dishes become new lines under theirs (a dish already there is skipped — they scored
--     it already), their words go after their earlier words as a new paragraph, the tagger's photos of
--     the new dishes are added after theirs, and the tag points at that entry. Nothing to add is legal
--     then (it only links the two). Without a same-day entry, 0089's behaviour exactly.
--   * entry_companions.response_request_id: the app's minted id for its answer, so a retry of an answer
--     that went into a same-day entry is still recognised (a different id is still 23505).
--   * entry_companions_response_uq dropped: one entry can now answer two people's tags (two friends
--     tag you at the same dinner). entry_with_people lists every host, each person once.
--
-- RULE 9 NOTE: entries.body is still only ever the author's words. Appending the words they typed in
-- the answer to the words they already had is their hand, in order, never rewritten.
--
-- WIRE IMPACT: ADDITIVE. One new RPC; two new prefill keys (older builds ignore them, and keep showing
-- every dish — their answer then lands in the same-day entry anyway, the dish already there skipped).
-- respond_ate_with may now return an entry whose id is NOT p_entry_id (the same-day one): render the
-- returned card, as the app already does.
--
-- Volume: every lookup is entries_author_idx (author, created_at) over one day; the append is the
-- same per-entry writes 0089 makes.

set search_path = public, extensions;

-- ===========================================================================
-- 1. Which entry is "that day's"
-- ===========================================================================
create or replace function public.same_day_entry(p_author uuid, p_restaurant uuid, p_at timestamptz,
                                                 p_exclude uuid default null)
returns uuid language sql stable security definer set search_path = public, extensions as $$
  with d as (select (p_at at time zone public.award_day_zone())::date as day)
  select e.id
  from public.entries e, d
  where e.author_id = p_author
    and e.restaurant_id = p_restaurant
    and e.created_at >= (d.day::timestamp at time zone public.award_day_zone())
    and e.created_at <  ((d.day + 1)::timestamp at time zone public.award_day_zone())
    and e.id is distinct from p_exclude
  order by e.created_at, e.id
  limit 1;
$$;
revoke all on function public.same_day_entry(uuid, uuid, timestamptz, uuid) from public, anon, authenticated;
grant execute on function public.same_day_entry(uuid, uuid, timestamptz, uuid) to service_role;

create or replace function public.my_same_day_entry(p_restaurant_id uuid, p_at timestamptz)
returns setof public.entry_cards language plpgsql stable security invoker set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'sign in' using errcode = '42501';
  end if;
  if p_restaurant_id is null or p_at is null then
    return;
  end if;
  -- same_day_entry's rule (award_day_zone() is not the caller's to run), read as the caller: their own rows.
  select e.id into v_id
  from public.entries e
  where e.author_id = v_uid
    and e.restaurant_id = p_restaurant_id
    and e.created_at >= (((p_at at time zone 'Australia/Melbourne')::date)::timestamp at time zone 'Australia/Melbourne')
    and e.created_at <  ((((p_at at time zone 'Australia/Melbourne')::date) + 1)::timestamp at time zone 'Australia/Melbourne')
  order by e.created_at, e.id
  limit 1;
  if v_id is null then
    return;
  end if;
  return query select c.* from public.entry_cards c where c.id = v_id;
end; $$;
revoke all on function public.my_same_day_entry(uuid, timestamptz) from public, anon;
grant execute on function public.my_same_day_entry(uuid, timestamptz) to authenticated, service_role;

-- ===========================================================================
-- 2. One entry may answer several tags
-- ===========================================================================
alter table public.entry_companions drop constraint if exists entry_companions_response_uq;
-- The id the app minted for its answer. It names the answer's entry unless the answer went into a
-- same-day entry; either way a retry with it is recognised (and a different id still gets 23505).
alter table public.entry_companions add column if not exists response_request_id uuid;
create index if not exists entry_companions_response_idx
  on public.entry_companions (response_entry_id) where response_entry_id is not null;

-- 0058's projection, with every host (an entry can answer two people's tags) and each person once.
create or replace function public.entry_with_people(p_entry_id uuid)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with entry as (
    select e.id, e.author_id
    from public.entries e
    where e.id = p_entry_id
      and (e.author_id = (select auth.uid()) or not public.blocked_with(e.author_id))
  ),
  host as (                                    -- this entry is someone's response: whose visits?
    select c.entry_id as host_entry, c.tagger_id as host_id, c.responded_at
    from entry
    join public.entry_companions c on c.response_entry_id = entry.id and c.status = 'accepted'
  ),
  people as (
    select c.companion_id as user_id, c.status, c.response_entry_id as entry_id, 1 as ord, c.created_at
    from entry
    join public.entry_companions c on c.entry_id = entry.id
    where (c.status = 'accepted' and c.response_entry_id is not null)
       or (c.status = 'pending' and (select auth.uid()) in (c.tagger_id, c.companion_id))
    union all
    select h.host_id, 'accepted', h.host_entry, 0, h.responded_at from host h
    union all
    select c.companion_id, 'accepted', c.response_entry_id, 1, c.created_at
    from host h
    join public.entry_companions c on c.entry_id = h.host_entry
    where c.status = 'accepted' and c.response_entry_id is not null and c.response_entry_id <> p_entry_id
  ),
  once as (
    select distinct on (x.user_id) x.*
    from people x
    order by x.user_id, x.ord, (x.status = 'accepted') desc, x.created_at nulls first
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', p.id, 'username', p.username, 'name', p.name, 'avatar_url', p.avatar_url,
           'status', x.status, 'entry_id', x.entry_id)
         order by x.ord, x.created_at nulls first, p.username), '[]'::jsonb)
  from once x
  join public.profiles p on p.id = x.user_id
  where x.user_id <> (select author_id from entry)
    and p.deleted_at is null
    and not public.blocked_with(x.user_id);
$$;

-- ===========================================================================
-- 3. The prefill says which dishes the person already has that day
-- ===========================================================================
create or replace function public.ate_with_prefill(p_companion_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid  uuid := (select auth.uid());
  v_c    public.entry_companions;
  v_e    public.entries;
  v_mine uuid;
  v_out  jsonb;
begin
  select * into v_c from public.entry_companions c where c.id = p_companion_id and c.companion_id = v_uid;
  if not found or public.blocked_with(v_c.tagger_id) then
    raise exception 'tag_not_found' using errcode = 'P0002';
  end if;
  select * into v_e from public.entries where id = v_c.entry_id;
  if v_e.restaurant_id is not null then
    v_mine := public.same_day_entry(v_uid, v_e.restaurant_id, v_e.created_at);
  end if;

  update public.notifications set read_at = now()
  where companion_id = v_c.id and recipient_id = v_uid and read_at is null;

  select jsonb_build_object(
    'companion_id', v_c.id,
    'status', v_c.status,
    'response_entry_id', v_c.response_entry_id,
    'entry_id', v_e.id,
    'visited_at', v_e.created_at,
    'sort_status', v_e.sort_status,
    'body', coalesce(v_e.body, ''),
    'tagger', jsonb_build_object('id', a.id, 'username', a.username, 'name', a.name, 'avatar_url', a.avatar_url),
    'place', case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'name', r.name, 'address', r.address, 'locality', public.place_locality(r.address, r.city)) end,
    'dishes', coalesce((
      select jsonb_agg(jsonb_build_object('dish_id', x.dish_id, 'dish_name', x.name, 'position', x.pos, 'score', x.score)
                       order by x.pos)
      from (
        -- One row per dish (sittings collapse); its score is the one on its first line.
        select distinct on (v.dish_id) v.dish_id, d.name, v.entry_position as pos, v.score
        from public.reviews v join public.dishes d on d.id = v.dish_id
        where v.entry_id = v_e.id
        order by v.dish_id, v.entry_position
      ) x), '[]'::jsonb),
    -- 0103: the person's own entry at this place that day, and the dishes already on it — the tagger's
    -- dish ids as the prefill lists them, so a merged dish matches either way round.
    'my_entry_id', v_mine,
    'my_dish_ids', coalesce((
      select jsonb_agg(distinct t.dish_id)
      from public.reviews t
      left join public.dishes td on td.id = t.dish_id
      where t.entry_id = v_e.id
        and exists (select 1 from public.reviews m left join public.dishes md on md.id = m.dish_id
                    where m.entry_id = v_mine
                      and coalesce(md.merged_into_dish_id, m.dish_id) = coalesce(td.merged_into_dish_id, t.dish_id))
    ), '[]'::jsonb)
  ) into v_out
  from public.profiles a
  left join public.restaurants r on r.id = v_e.restaurant_id
  where a.id = v_c.tagger_id;
  return v_out;
end; $$;

-- ===========================================================================
-- 4. respond_ate_with — into the same-day entry when there is one
-- ===========================================================================
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
  v_kept  uuid[];
  v_every boolean;
  v_urls  text[];
  v_into  public.entries;       -- 0103: the person's own entry at this place that day
  v_have  uuid[] := '{}';       -- dishes already on it
  v_first int := 0;             -- its next photo slot
begin
  select * into v_c from public.entry_companions c
  where c.id = p_companion_id and c.companion_id = v_uid
  for update;
  if not found or public.blocked_with(v_c.tagger_id) then
    raise exception 'tag_not_found' using errcode = 'P0002';
  end if;
  select * into v_e from public.entries where id = v_c.entry_id;
  if v_e.restaurant_id is not null then
    select * into v_into from public.entries
    where id = public.same_day_entry(v_uid, v_e.restaurant_id, v_e.created_at, p_entry_id);
  end if;

  if v_c.status = 'accepted' then
    if v_c.response_entry_id = p_entry_id or v_c.response_request_id = p_entry_id then
      return query select c.* from public.entry_cards c where c.id = v_c.response_entry_id;   -- a retry
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
  if jsonb_array_length(p_items) = 0 and btrim(v_body) = '' and v_into.id is null then
    raise exception 'nothing_to_post' using errcode = '22023';   -- with a same-day entry it only links
  end if;

  if v_into.id is not null then
    perform 1 from public.entries where id = v_into.id for update;
    select coalesce(array_agg(distinct coalesce(md.merged_into_dish_id, m.dish_id)), '{}'),
           coalesce(max(m.entry_position), 0)
      into v_have, v_pos
    from public.reviews m left join public.dishes md on md.id = m.dish_id
    where m.entry_id = v_into.id;
    select coalesce(max(position) + 1, 0) into v_first from public.entry_photos where entry_id = v_into.id;
  else
    insert into public.entries (id, author_id, body, restaurant_id, created_at)
    values (p_entry_id, v_uid, v_body, v_e.restaurant_id, v_e.created_at);   -- same visit, same time
  end if;

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
    continue when v_dish = any(v_seen) or v_dish = any(v_have);   -- one line per dish, per sitting
    v_seen := v_seen || v_dish;
    v_pos := v_pos + 1;
    insert into public.reviews
      (reviewer_id, dish_id, restaurant_id, entry_id, entry_position, score, created_at, tags,
       corrected_at, corrected_from_name)
    values
      (v_uid, v_dish, coalesce(v_into.restaurant_id, v_e.restaurant_id), coalesce(v_into.id, p_entry_id), v_pos,
       case when jsonb_typeof(v_item -> 'score') = 'number' then (v_item ->> 'score')::numeric end,
       coalesce(v_into.created_at, v_e.created_at),
       case when jsonb_typeof(v_item -> 'tags') = 'array'
            then array(select jsonb_array_elements_text(v_item -> 'tags')) else '{}'::text[] end,
       now(), v_name);
  end loop;

  -- 0089: the tagger's photos. Their lines for the dishes the person kept, and whether they kept all.
  select coalesce(array_agg(t.id), '{}'),
         coalesce(bool_and(coalesce(td.merged_into_dish_id, t.dish_id) = any(v_seen)), true)
    into v_kept, v_every
  from public.reviews t
  left join public.dishes td on td.id = t.dish_id
  where t.entry_id = v_e.id;
  v_kept := array(select t.id from public.reviews t left join public.dishes td on td.id = t.dish_id
                  where t.id = any(v_kept) and coalesce(td.merged_into_dish_id, t.dish_id) = any(v_seen));

  if v_into.id is not null then
    -- 0103: into an entry they already had, only photos of a dish they ADDED come (never one of a dish
    -- already on their receipt, or of the room), none they already show, and only while slots remain.
    select coalesce(array_agg(x.url order by x.position), '{}') into v_urls
    from (
      select p.photo_url as url, p.position,
             row_number() over (order by p.position) as n
      from public.entry_photos p
      where p.entry_id = v_e.id
        and cardinality(v_kept) > 0
        and (exists (select 1 from public.photo_dishes pd
                     where pd.entry_id = v_e.id and pd.photo_url = p.photo_url and pd.review_id = any(v_kept))
             or exists (select 1 from public.reviews t where t.id = any(v_kept) and t.photo_url = p.photo_url))
        and not exists (select 1 from public.entry_photos o where o.entry_id = v_into.id and o.photo_url = p.photo_url)
    ) x
    where v_first + x.n - 1 < 24;
  else
    select coalesce(array_agg(p.photo_url order by p.position), '{}') into v_urls
    from public.entry_photos p
    where p.entry_id = v_e.id
      and (v_every or v_e.photos_matched_at is null
           or exists (select 1 from public.photo_dishes pd
                      where pd.entry_id = v_e.id and pd.photo_url = p.photo_url and pd.review_id = any(v_kept))
           or exists (select 1 from public.reviews t where t.id = any(v_kept) and t.photo_url = p.photo_url));
  end if;

  if cardinality(v_urls) > 0 then
    insert into public.entry_photos (entry_id, position, photo_url)
    select coalesce(v_into.id, p_entry_id), (v_first + u.n - 1)::smallint, u.url
    from unnest(v_urls) with ordinality u(url, n);

    insert into public.photo_dishes (entry_id, photo_url, review_id, box_left, box_top, box_right, box_bottom)
    select coalesce(v_into.id, p_entry_id), pd.photo_url, n.id, pd.box_left, pd.box_top, pd.box_right, pd.box_bottom
    from public.photo_dishes pd
    join public.reviews t on t.id = pd.review_id
    left join public.dishes td on td.id = t.dish_id
    join public.reviews n on n.entry_id = coalesce(v_into.id, p_entry_id)
                         and n.dish_id = coalesce(td.merged_into_dish_id, t.dish_id)
                         and n.dish_id = any(v_seen)
    where pd.entry_id = v_e.id and pd.review_id = any(v_kept) and pd.photo_url = any(v_urls)
    on conflict do nothing;

    -- Each new line's main photo (and a hand pick, so a later match keeps it): the tagger's first line for it.
    update public.reviews n
       set photo_url = t.photo_url, photo_picked_at = t.photo_picked_at
      from (select distinct on (coalesce(td.merged_into_dish_id, t.dish_id))
                   coalesce(td.merged_into_dish_id, t.dish_id) as dish_id, t.photo_url, t.photo_picked_at
            from public.reviews t
            left join public.dishes td on td.id = t.dish_id
            where t.id = any(v_kept)
            order by coalesce(td.merged_into_dish_id, t.dish_id), t.entry_position nulls last, t.id) t
     where n.entry_id = coalesce(v_into.id, p_entry_id) and n.dish_id = t.dish_id and n.dish_id = any(v_seen)
       and (t.photo_url = any(v_urls) or (t.photo_url is null and t.photo_picked_at is not null));
  end if;

  if v_into.id is not null then
    -- Their words after their earlier words; the photos' picks beside the entry's own. A photo that
    -- came unmatched leaves the entry to be matched again (match-photos takes only unmatched ones).
    update public.entries
       set body = case when btrim(v_body) = '' then body
                       when btrim(body) = '' then v_body
                       else body || E'\n\n' || v_body end,
           photo_picks = photo_picks || (select coalesce(jsonb_object_agg(k.key, k.value), '{}'::jsonb)
                                         from jsonb_each(v_e.photo_picks) k where k.key = any(v_urls)),
           photo_also  = photo_also || (select coalesce(jsonb_object_agg(k.key, k.value), '{}'::jsonb)
                                        from jsonb_each(v_e.photo_also) k where k.key = any(v_urls)),
           photos_matched_at = case when cardinality(v_urls) > 0 and v_e.photos_matched_at is null
                                    then null else photos_matched_at end
     where id = v_into.id;
  else
    -- The receipt is printed: the lines are the user's. (Words, if any, may still be run through
    -- sort-entry with force — the corrected lines survive it and anything else the words name is added.)
    update public.entries
       set sort_status = 'sorted', sort_mode = 'companion', sorted_at = now(),
           photo_picks = (select coalesce(jsonb_object_agg(k.key, k.value), '{}'::jsonb)
                          from jsonb_each(v_e.photo_picks) k where k.key = any(v_urls)),
           photo_also  = (select coalesce(jsonb_object_agg(k.key, k.value), '{}'::jsonb)
                          from jsonb_each(v_e.photo_also) k where k.key = any(v_urls)),
           photos_matched_at = case when cardinality(v_urls) > 0 then v_e.photos_matched_at end,
           photos_located_at = case when cardinality(v_urls) > 0 then v_e.photos_located_at end
     where id = p_entry_id;
  end if;

  update public.entry_companions
     set status = 'accepted', response_entry_id = coalesce(v_into.id, p_entry_id), responded_at = now(),
         response_request_id = p_entry_id
   where id = v_c.id;
  update public.notifications set read_at = coalesce(read_at, now()), dismissed_at = now()
   where companion_id = v_c.id and dismissed_at is null;

  return query select c.* from public.entry_cards c where c.id = coalesce(v_into.id, p_entry_id);
end; $function$;
