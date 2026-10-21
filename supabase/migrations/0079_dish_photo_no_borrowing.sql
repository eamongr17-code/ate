-- 0079_dish_photo_no_borrowing.sql
-- Ate backend — a dish never shows another dish's photo.
--
-- Bug (21 Oct, Eamon): an entry with two dishes and one photo. match-photos gave the photo to the
-- dish in it and left the other line without one, and the dish page of that other dish (hero,
-- Similar dishes cards, every cover) still showed it. The cover reads fell back to "the entry's
-- first photo" for any line with no photo of its own (0026, 0029, 0060). That fallback predates
-- photo matching (0063) and is only true when the entry has ONE line: then its photos can only be
-- that dish. With two or more lines, a line with no photo has no photo.
--
-- The rule, one place: public.review_photo_url(review). The line's own photo; else, only when it is
-- the entry's only line AND the author has not said "No dish" for it (photo_picked_at) or for the photo
-- (entries.photo_picks, 0064), the entry's
-- first photo; else null. Lines with no entry (Wave 0 reviews) keep only their own photo.
--
-- Rewired: dish_cover_url, dish_photos, list_item_photo (same signatures, grants kept by
-- create or replace). Everything else that shows a dish's cover (dish_summary, similar_dishes,
-- search, feed edition, place dishes, saves) reads dish_cover_url / dish_photos, so it follows.
-- Unchanged on purpose: restaurant_cover_url (any photo of a visit is a photo of the place) and the
-- entry-level reads (entry_cards, journal_days, the receipt), which show the visit's own photos.
--
-- Volume: the "only line" test is one probe of reviews_entry_idx (entry_id, entry_position) per
-- candidate line; no table scan, no new index.

set search_path = public, extensions;

create or replace function public.review_photo_url(p_review public.reviews)
returns text
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(
    p_review.photo_url,
    case when p_review.entry_id is not null
          and p_review.photo_picked_at is null
          and not exists (
            select 1 from public.reviews o
            where o.entry_id = p_review.entry_id and o.id <> p_review.id
          )
    then (
      select x.photo_url
      from public.entry_photos x
      join public.entries e on e.id = x.entry_id
      where x.entry_id = p_review.entry_id
        and e.photo_picks -> x.photo_url is distinct from 'null'::jsonb  -- not called "No dish" (0064)
      order by x.position, x.created_at
      limit 1
    ) end
  );
$$;

comment on function public.review_photo_url(public.reviews) is
  '0079: the photo a dish line shows — its own photo, else (only when it is its entry''s only line and the author has not picked "No dish") the entry''s first photo, else NULL. Never another dish''s photo.';

revoke all on function public.review_photo_url(public.reviews) from public;
grant execute on function public.review_photo_url(public.reviews) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
create or replace function public.dish_cover_url(p_dish_id uuid)
returns text
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select p.url
  from public.reviews v
  cross join lateral (select public.review_photo_url(v) as url) p
  where v.dish_id = p_dish_id
    and p.url is not null
  order by v.created_at desc, v.id desc
  limit 1;
$$;

comment on function public.dish_cover_url(uuid) is
  'The dish''s cover photo, live-derived: the newest VISIBLE review with a photo, where a photo is review_photo_url (0079) — never another dish''s. NULL when none. SECURITY INVOKER — viewer-relative through RLS.';

-- ---------------------------------------------------------------------------
create or replace function public.dish_photos(p_dish_id uuid, p_limit int default 8)
returns jsonb
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('url', p.url, 'entry_id', p.entry_id)
              order by p.created_at desc, p.review_id desc),
    '[]'::jsonb)
  from (
    select v.id as review_id, v.entry_id, v.created_at, ph.url
    from public.reviews v
    cross join lateral (select public.review_photo_url(v) as url) ph
    where v.dish_id = p_dish_id
      and ph.url is not null
    order by v.created_at desc, v.id desc
    limit least(greatest(p_limit, 1), 24)
  ) p;
$$;

comment on function public.dish_photos(uuid, int) is
  'A dish''s photos, newest first, one per review, same derivation as dish_cover_url (review_photo_url, 0079) — photos[0].url == cover_url. [] when it has none. Viewer-relative through RLS.';

-- ---------------------------------------------------------------------------
-- The photo a list item shows: the line's photo by the same rule. Never another dish's or person's.
create or replace function public.list_item_photo(p_entry_id uuid, p_dish_id uuid)
returns text language sql stable security invoker set search_path = public, extensions as $$
  select public.review_photo_url(r)
  from public.reviews r
  where r.entry_id = p_entry_id and r.dish_id = p_dish_id
  order by (public.review_photo_url(r) is null), r.entry_position nulls last, r.id
  limit 1;
$$;
