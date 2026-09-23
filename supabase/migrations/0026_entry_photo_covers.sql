-- 0026_entry_photo_covers.sql
-- Ate backend — the dish cover follows the PHOTOS WE ACTUALLY HAVE.
--
-- THE BUG (CEO's live entries, staging 2026-09-24): `dish_stats.cover_url` is NULL for
-- every V1 dish, so Saved rows and dish tiles draw a blank thumbnail. 0009 derived the
-- cover from `reviews.photo_url` — the Wave-0 shape, where a review WAS the photo. In V1
-- the sorter writes the reviews and the photos land on the ENTRY (`entry_photos`), so
-- `reviews.photo_url` is null on everything the sorter has ever written.
--
-- THE FIX, same spirit as 0009: STILL LIVE-DERIVED, never a stored column. The cover is
-- the newest review the viewer can see that HAS a photo, where "has a photo" now means
--     coalesce(reviews.photo_url, the first photo of that review's entry)
-- The per-review precedence keeps 0009's meaning intact (a legacy review's own photo still
-- wins for that review) and only fills the null case the V1 write path creates. "First
-- photo of the entry" = lowest `position` (0 in practice; ordering by position rather than
-- testing `= 0` survives a deleted first photo).
--
-- ONE DERIVATION, ONE PLACE: `dish_cover_url(dish)` / `restaurant_cover_url(restaurant)`.
-- Four read paths want this expression (dish_stats, restaurant_stats, entry_cards items,
-- and through dish_stats: my_saved_dishes / place_dishes / dish_summary / search_all); a
-- copy in each is how they drift apart.
--
-- STILL VIEWER-RELATIVE, which is the privacy rule this schema already made (0022): both
-- functions are SECURITY INVOKER, so RLS runs as the caller — `entry_photos` is readable
-- only when its parent entry is (own, or public and not blocked). A private entry's photo
-- can therefore cover a dish for its author and for nobody else. No `visibility = 'public'`
-- test is written here on purpose: adding one would ALSO hide the author's own photo from
-- their own Saved row, and RLS already answers the leak question.
--
-- WIRE IMPACT: ADDITIVE + one BEHAVIOURAL value change. No shape change, nothing removed.
--   * BEHAVIOURAL: `dish_stats.cover_url` / `restaurant_stats.cover_url` (and therefore
--     `my_saved_dishes.dish_cover_url`, `place_dishes.cover_url`, `place_summary.cover_url`,
--     `dish_summary.cover_url`, `search_all`'s dish `detail.cover_url`) are now NON-NULL
--     wherever the dish's entries carry photos. Same column, same type; a client that draws
--     a placeholder on null simply stops drawing it.
--   * ADDITIVE: `my_saved_dishes` gains `cover_url` (appended last; the same value as the
--     existing `dish_cover_url`, which is KEPT — nothing that reads it breaks).
--   * ADDITIVE: every `entry_cards.items[]` element gains `cover_url` — the DISH's cover
--     (not necessarily a photo from this entry; `photos[]` is the entry's own).
--   * ADDITIVE: index `reviews_restaurant_recent_idx`, so the restaurant cover pick is an
--     index scan instead of a top-N over every review at the place.

set search_path = public, extensions;

-- ===========================================================================
-- THE DERIVATION
-- ===========================================================================
create or replace function public.dish_cover_url(p_dish_id uuid)
returns text
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(v.photo_url, ep.photo_url)
  from public.reviews v
  left join lateral (
    select x.photo_url
    from public.entry_photos x
    where x.entry_id = v.entry_id
    order by x.position, x.created_at
    limit 1
  ) ep on true
  where v.dish_id = p_dish_id
    and (v.photo_url is not null or ep.photo_url is not null)
  order by v.created_at desc, v.id desc
  limit 1;
$$;

comment on function public.dish_cover_url(uuid) is
  'The dish''s cover photo, live-derived: the newest VISIBLE review that has a photo, where a photo is coalesce(reviews.photo_url, the first entry_photo of that review''s entry). NULL when none. SECURITY INVOKER — viewer-relative through RLS.';

create or replace function public.restaurant_cover_url(p_restaurant_id uuid)
returns text
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(v.photo_url, ep.photo_url)
  from public.reviews v
  left join lateral (
    select x.photo_url
    from public.entry_photos x
    where x.entry_id = v.entry_id
    order by x.position, x.created_at
    limit 1
  ) ep on true
  where v.restaurant_id = p_restaurant_id
    and (v.photo_url is not null or ep.photo_url is not null)
  order by v.created_at desc, v.id desc
  limit 1;
$$;

comment on function public.restaurant_cover_url(uuid) is
  'The place''s cover photo, live-derived exactly like dish_cover_url but across every dish reviewed there. NULL when none — place_summary still falls back to restaurants.cover_url. An entry with photos but NO dish lines does not cover its place: there is no review row to hang it on.';

-- Kept executable by `anon` because `dish_stats`/`restaurant_stats` are granted to anon
-- (0005/0009): revoking it there would turn today's empty result into a 42501 error.
revoke all on function public.dish_cover_url(uuid)       from public;
revoke all on function public.restaurant_cover_url(uuid) from public;
grant execute on function public.dish_cover_url(uuid)       to authenticated, anon, service_role;
grant execute on function public.restaurant_cover_url(uuid) to authenticated, anon, service_role;

-- The restaurant pick is "newest first at this place"; reviews_restaurant_idx is
-- (restaurant_id) alone, so the sort was a top-N over every review there.
create index if not exists reviews_restaurant_recent_idx
  on public.reviews (restaurant_id, created_at desc, id desc);

-- ===========================================================================
-- dish_stats — identical columns; cover_url now comes from the shared derivation.
-- ===========================================================================
create or replace view public.dish_stats
with (security_invoker = true) as
  select
    d.id              as dish_id,
    d.restaurant_id,
    round(avg(r.score), 1)::numeric(2,1) as score,     -- NULL when nobody scored it
    count(r.id)::int  as review_count,
    public.dish_cover_url(d.id) as cover_url,
    count(r.score)::int as scored_count,
    count(distinct r.reviewer_id)::int as people_count
  from public.dishes d
  left join public.reviews r on r.dish_id = d.id
  where d.merged_into_dish_id is null
  group by d.id, d.restaurant_id;

comment on view public.dish_stats is
  'Per-dish aggregates over the reviews the VIEWER can see: score (NULL = nobody scored it), review_count (all), scored_count, people_count (distinct reviewers), cover_url (dish_cover_url — the newest visible photo, the review''s own or its entry''s first). Live dishes only.';

-- ===========================================================================
-- restaurant_stats — identical columns; same swap.
-- ===========================================================================
create or replace view public.restaurant_stats
with (security_invoker = true) as
  select
    rst.id as restaurant_id,
    round(avg(ds.score) filter (where ds.score is not null), 1)::numeric(2,1) as avg_rating,
    coalesce(sum(ds.review_count), 0)::int as review_count,
    public.restaurant_cover_url(rst.id) as cover_url,
    coalesce(ppl.people_count, 0)::int as people_count,
    count(ds.dish_id) filter (where ds.review_count > 0)::int as dish_count
  from public.restaurants rst
  left join public.dish_stats ds on ds.restaurant_id = rst.id
  left join lateral (
    select count(distinct rp.reviewer_id)::int as people_count
    from public.reviews rp
    where rp.restaurant_id = rst.id
  ) ppl on true
  group by rst.id, ppl.people_count;

comment on view public.restaurant_stats is
  'Restaurant rating = MEAN OF PER-DISH AVERAGES (null-score dishes excluded) + review_count + cover_url (restaurant_cover_url) + people_count (distinct reviewers) + dish_count (dishes with at least one visible review).';

grant select on public.dish_stats       to authenticated, anon;
grant select on public.restaurant_stats to authenticated, anon;

-- ===========================================================================
-- my_saved_dishes — + cover_url (appended LAST). `dish_cover_url` stays, same value:
-- create-or-replace cannot rename a column and nothing is gained by breaking a reader.
-- ORDERING IS THE CLIENT'S: keyset (saved_at desc, dish_id desc) — see
-- integration-design.md. NOT restaurant_name: grouping by place is presentation, and a
-- name-ordered list has no stable cursor.
-- ===========================================================================
create or replace view public.my_saved_dishes
with (security_invoker = true) as
  select
    s.dish_id,
    d.name                as dish_name,
    r.id                  as restaurant_id,
    r.name                as restaurant_name,
    r.city                as restaurant_city,
    ds.score              as dish_score,
    ds.cover_url          as dish_cover_url,
    s.source_entry_id,
    s.source_user_id,
    sp.username           as source_username,
    s.created_at          as saved_at,
    ds.cover_url          as cover_url
  from public.saves s
  join public.dishes d       on d.id = s.dish_id
  join public.restaurants r  on r.id = d.restaurant_id
  left join public.dish_stats ds on ds.dish_id = s.dish_id
  left join public.profiles sp   on sp.id = s.source_user_id
  where s.user_id = (select auth.uid());

comment on view public.my_saved_dishes is
  'The caller''s saved dishes joined to place + dish aggregate + provenance handle. Page with the keyset (saved_at desc, dish_id desc). cover_url == dish_cover_url (the older name, kept).';

grant select on public.my_saved_dishes to authenticated;

-- ===========================================================================
-- entry_cards — 0025's shape, with `cover_url` added to each items[] element.
-- Everything else is 0025 verbatim: a view has to be re-stated whole.
-- ===========================================================================
create or replace view public.entry_cards
with (security_invoker = true) as
  select
    e.id,
    e.author_id,
    e.body,
    e.visibility,
    e.restaurant_id,
    e.restaurant_source,
    e.order_number,
    e.sort_status,
    e.sorted_at,
    e.created_at,
    e.updated_at,
    (e.author_id = (select auth.uid())) as is_mine,
    jsonb_build_object(
      'id', p.id, 'username', p.username, 'name', p.name,
      'avatar_url', p.avatar_url, 'city', p.city
    ) as author,
    case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'name', r.name, 'address', r.address,
      'city', r.city, 'cuisine', r.cuisine
    ) end as place,
    coalesce(ph.photos, '[]'::jsonb) as photos,
    coalesce(ph.photo_count, 0)      as photo_count,
    coalesce(it.items, '[]'::jsonb)  as items,
    coalesce(it.dish_count, 0)       as dish_count,
    it.avg_score,
    -- WHERE the place is named in the words (0025).
    e.place_offset,
    char_length(e.place_query) as place_length
  from public.entries e
  join public.profiles p on p.id = e.author_id
  left join public.restaurants r on r.id = e.restaurant_id
  left join lateral (
    select
      jsonb_agg(jsonb_build_object('url', x.photo_url, 'position', x.position)
                order by x.position) as photos,
      count(*)::int as photo_count
    from public.entry_photos x
    where x.entry_id = e.id
  ) ph on true
  left join lateral (
    select
      jsonb_agg(jsonb_build_object(
        'review_id', v.id,
        'dish_id',   v.dish_id,
        'dish_name', d.name,
        'score',     v.score,
        'note',      v.note,
        'position',  v.entry_position,
        'saved',     (s.user_id is not null),
        'evidence_offset', v.evidence_offset,
        'evidence_length', char_length(v.score_evidence),
        'mention_offset',  v.mention_offset,
        'mention_length',  char_length(v.mention_text),
        'corrected', (v.corrected_at is not null),
        -- the DISH's cover, so a receipt line can draw its thumbnail without a second
        -- round trip. NOT this entry's photo — `photos[]` is that.
        'cover_url', public.dish_cover_url(v.dish_id)
      ) order by v.entry_position nulls last, v.created_at, v.id) as items,
      count(*)::int as dish_count,
      round(avg(v.score), 2)::numeric(3,2) as avg_score
    from public.reviews v
    join public.dishes d on d.id = v.dish_id
    left join public.saves s on s.dish_id = v.dish_id and s.user_id = (select auth.uid())
    where v.entry_id = e.id
  ) it on true;

comment on view public.entry_cards is
  'The one entry shape for Journal slip / Feed slip / Entry page / Share receipt: entry + author + place + photos[] + items[] (each with the dish''s cover_url) + receipt footer (dish_count, avg_score over scored items) + where each finding sits in body (place_offset/length, items[].evidence_* and mention_*, all 0-based UNICODE SCALAR offsets). Read a single entry with ?id=eq.<uuid>; page lists via get_entry_feed / get_entries_by_author / get_entries_at_place.';

grant select on public.entry_cards to authenticated;
