-- 0096_non_food_photos.sql
-- Ate backend — a photo of no dish is never a dish's photo (26 Oct, Eamon: "people will want to
-- sometimes upload images of not the food, but maybe the people they were with").
--
-- match-photos now asks the model about one-dish entries too, and it leaves out a photo that shows
-- no listed dish (the people, the room, a menu). Until now a one-dish entry took every photo with
-- no model, and review_photo_url (0079) let its only line fall back to the entry's first photo.
-- That fallback is right only while the entry was never matched: once it was, the match is the
-- answer, and a line the matcher gave no photo has no photo (no dish cover, no dish-page photo).
--
-- Unchanged: entry-level reads (entry_cards, journal_days, the receipt, restaurant_cover_url) still
-- show every photo of the visit. Entries never matched (posted offline, AI down) keep the fallback.
-- Old one-dish entries keep what the old rule gave them; the author fixes one with "No dish".
--
-- Volume: the extra test reads entries by primary key, already joined for photo_picks.

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
        and e.photos_matched_at is null                                  -- matched: the match is the answer (0096)
        and e.photo_picks -> x.photo_url is distinct from 'null'::jsonb  -- not called "No dish" (0064)
      order by x.position, x.created_at
      limit 1
    ) end
  );
$$;
comment on function public.review_photo_url(public.reviews) is
  '0079/0096: the photo a dish line shows — its own photo, else (only when it is its entry''s only line, the entry was never photo-matched, and the author has not picked "No dish") the entry''s first photo, else NULL. Never another dish''s photo, nor a photo the matcher found no dish in.';
