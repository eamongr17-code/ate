-- 0089_ate_with_photos.sql
-- THE TAGGER'S PHOTOS COME WITH THE TAG (25 Oct, Eamon): "when a user accepts a tag and adds their own
-- ratings, the pictures from the original review do not come with it to the new one."
--
-- respond_ate_with built the person's own entry from the place, the visit's time and their lines, and
-- nothing else: their receipt, Journal slip, share cards and the dish pages had no photo of the meal
-- they shared. Now the entry also takes the tagger's photos, with which dish each one shows:
--
--   * entry_photos — the tagger's photos, in their order (positions renumbered 0…). The same file,
--     never a copy: the url is shared. A dish the person removed takes its photos with it: when they
--     removed any, only photos showing a dish they kept come (a photo of only the removed dish is a
--     photo of something they didn't have). When they kept every dish, or the tagger's photos were
--     never matched, every photo comes.
--   * photo_dishes — each kept dish's pairings (and boxes, 0083) onto the person's line for that dish.
--   * reviews.photo_url / photo_picked_at — each kept line's main photo and the tagger's hand pick.
--   * entries.photo_picks / photo_also (0064/0083) for the photos that came, and photos_matched_at /
--     photos_located_at as the tagger's: matched photos are not matched again, and unmatched ones are
--     matched the first time someone opens them (match-photos, unmatched_only), as on the original.
--   A snapshot at answer time, like the lines: the tagger's later edits never touch the person's entry.
--
-- FILES: the urls point into the tagger's storage folder. delete_entry (0037) already purges only the
-- caller's own folder and never a url another entry still holds, so neither side's delete removes a
-- photo the other's entry shows. The person cannot delete the files; removing one from their entry
-- only drops their row.
--
--   dish_photos — the same photo on the tagger's and the person's line was shown twice on the dish
--     page. Now each photo once, the tagger's first (the photo is theirs), then by the same order.
--
-- WIRE IMPACT: none. Same signatures; entry_cards already carries photos. Older builds see the photos
-- on the returned card as on any entry.
--
-- Volume: at most five photos per entry (the composer's limit) × its lines; every read is by entry id
-- (entry_photos PK, photo_dishes PK, reviews_entry_idx). dish_photos reads the same rows as before,
-- de-duplicates before its limit, and works out boxes only for the rows it returns.

set search_path = public, extensions;

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

  -- 0089: the tagger's photos. Their lines for the dishes the person kept, and whether they kept all.
  select coalesce(array_agg(t.id), '{}'),
         coalesce(bool_and(coalesce(td.merged_into_dish_id, t.dish_id) = any(v_seen)), true)
    into v_kept, v_every
  from public.reviews t
  left join public.dishes td on td.id = t.dish_id
  where t.entry_id = v_e.id;
  v_kept := array(select t.id from public.reviews t left join public.dishes td on td.id = t.dish_id
                  where t.id = any(v_kept) and coalesce(td.merged_into_dish_id, t.dish_id) = any(v_seen));

  select coalesce(array_agg(p.photo_url order by p.position), '{}') into v_urls
  from public.entry_photos p
  where p.entry_id = v_e.id
    and (v_every or v_e.photos_matched_at is null
         or exists (select 1 from public.photo_dishes pd
                    where pd.entry_id = v_e.id and pd.photo_url = p.photo_url and pd.review_id = any(v_kept))
         or exists (select 1 from public.reviews t where t.id = any(v_kept) and t.photo_url = p.photo_url));

  if cardinality(v_urls) > 0 then
    insert into public.entry_photos (entry_id, position, photo_url)
    select p_entry_id, (u.n - 1)::smallint, u.url
    from unnest(v_urls) with ordinality u(url, n);

    insert into public.photo_dishes (entry_id, photo_url, review_id, box_left, box_top, box_right, box_bottom)
    select p_entry_id, pd.photo_url, n.id, pd.box_left, pd.box_top, pd.box_right, pd.box_bottom
    from public.photo_dishes pd
    join public.reviews t on t.id = pd.review_id
    left join public.dishes td on td.id = t.dish_id
    join public.reviews n on n.entry_id = p_entry_id and n.dish_id = coalesce(td.merged_into_dish_id, t.dish_id)
    where pd.entry_id = v_e.id and pd.review_id = any(v_kept) and pd.photo_url = any(v_urls)
    on conflict do nothing;

    -- Each line's main photo (and a hand pick, so a later match keeps it): the tagger's first line for it.
    update public.reviews n
       set photo_url = t.photo_url, photo_picked_at = t.photo_picked_at
      from (select distinct on (coalesce(td.merged_into_dish_id, t.dish_id))
                   coalesce(td.merged_into_dish_id, t.dish_id) as dish_id, t.photo_url, t.photo_picked_at
            from public.reviews t
            left join public.dishes td on td.id = t.dish_id
            where t.id = any(v_kept)
            order by coalesce(td.merged_into_dish_id, t.dish_id), t.entry_position nulls last, t.id) t
     where n.entry_id = p_entry_id and n.dish_id = t.dish_id
       and (t.photo_url = any(v_urls) or (t.photo_url is null and t.photo_picked_at is not null));
  end if;

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

  update public.entry_companions
     set status = 'accepted', response_entry_id = p_entry_id, responded_at = now()
   where id = v_c.id;
  update public.notifications set read_at = coalesce(read_at, now()), dismissed_at = now()
   where companion_id = v_c.id and dismissed_at is null;

  return query select c.* from public.entry_cards c where c.id = p_entry_id;
end; $function$;

-- ===========================================================================
-- dish_photos — 0083's, each photo once. A photo on several lines of the dish (the tagger's and the
-- person who answered the tag) shows the line of the person whose file it is; boxes are worked out for the returned rows only.
-- ===========================================================================
create or replace function public.dish_photos(p_dish_id uuid, p_limit int default 8)
returns jsonb
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(
    jsonb_agg(jsonb_strip_nulls(jsonb_build_object('url', p.url, 'entry_id', p.entry_id, 'box', p.box,
                                                   'with', case when p.box is not null then p.others end))
              order by p.created_at desc, p.review_id desc, p.ord),
    '[]'::jsonb)
  from (
    select u.review_id, u.entry_id, u.created_at, u.url, u.ord,
           (select jsonb_build_array(pd.box_left, pd.box_top, pd.box_right, pd.box_bottom)
            from public.photo_dishes pd
            where pd.entry_id = u.entry_id and pd.photo_url = u.url and pd.review_id = u.review_id
              and pd.box_left is not null
              and exists (select 1 from public.photo_dishes o
                          where o.entry_id = pd.entry_id and o.photo_url = pd.photo_url
                            and o.review_id <> pd.review_id)) as box,
           (select jsonb_agg(jsonb_build_object('name', d.name,
                     'box', jsonb_build_array(o.box_left, o.box_top, o.box_right, o.box_bottom)) order by o.box_left)
            from public.photo_dishes o
            join public.reviews r on r.id = o.review_id
            join public.dishes d on d.id = r.dish_id
            where o.entry_id = u.entry_id and o.photo_url = u.url and o.review_id <> u.review_id
              and o.box_left is not null) as others
    from (
      select distinct on (ph.url) v.id as review_id, v.entry_id, v.created_at, ph.url, ph.ord
      from public.reviews v
      cross join lateral (
        select x.url, min(x.ord) as ord
        from (
          select public.review_photo_url(v) as url, -1 as ord
          union all
          select pd.photo_url, x.position
          from public.photo_dishes pd
          join public.entry_photos x on x.entry_id = pd.entry_id and x.photo_url = pd.photo_url
          where pd.review_id = v.id
        ) x
        where x.url is not null
        group by x.url
      ) ph
      where v.dish_id = p_dish_id
      order by ph.url,
               position('/review-photos/' || v.reviewer_id::text || '/' in ph.url) > 0 desc,   -- the file's owner
               v.created_at desc, v.id desc, ph.ord
    ) u
    order by u.created_at desc, u.review_id desc, u.ord
    limit least(greatest(p_limit, 1), 24)
  ) p;
$$;

comment on function public.dish_photos(uuid, int) is
  'A dish''s photos, newest review first, every photo of each review (0081), its main photo (review_photo_url, 0079) first — photos[0].url == cover_url. Each photo once: one shared by an answered tag shows the original''s (0089). `box` [l,t,r,b] (0–1) and `with` [{name, box}] (the other placed dishes) where the photo is shared and this dish was placed (0083). [] when it has none. Viewer-relative through RLS.';
