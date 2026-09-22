-- 0025_entry_cards_offsets.sql
-- Ate backend — the one entry shape now tells the client WHERE each finding sits in the
-- words, so inline tokens are placed, not searched for.
--
-- THE BUG THIS CLOSES: the client rebuilt its inline score token by searching `body` for
-- the score's digits. "Dinner was $14.50" contains "4.5", and it comes first — so the
-- token landed on the price. Searching is the wrong operation; the sorter already knew
-- the exact occurrence it matched (0024 stores it).
--
-- THE UNIT (same as 0024, repeated because the client reads this doc):
--   `*_offset` is a 0-BASED UNICODE SCALAR (code point) offset into `body`.
--   `*_length` is a count of UNICODE SCALARS.
--   Swift:  let s = body.unicodeScalars
--           let i = s.index(s.startIndex, offsetBy: offset)
--           let j = s.index(i, offsetBy: length)
--           let token = String(s[i..<j])            // or NSRange(i..<j, in: body) for UTF-16
--   These are NOT UTF-16 offsets. One emoji earlier in the body and the two differ.
--
-- STALENESS is the client's to check: the offsets describe the body AS IT WAS SORTED. If
-- the author edits their words without a re-sort, the slice may no longer be the token.
-- `updated_at > sorted_at` is the cheap hint; verifying the slice is the certain test
-- (for a score token: the slice must contain the score's digits).
--
-- WIRE IMPACT: ADDITIVE ONLY.
--   * `entry_cards` gains two columns, APPENDED LAST (create-or-replace cannot reorder):
--     `place_offset`, `place_length`.
--   * each `entry_cards.items[]` element gains `evidence_offset`, `evidence_length`,
--     `mention_offset`, `mention_length`, `corrected`. No existing key changes.
--   * get_entry_feed / get_entries_by_author / get_entries_at_place return `setof
--     entry_cards` and pick the new columns up with no signature change.

set search_path = public, extensions;

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
    -- WHERE the place is named in the words: the sorter's match, or the phrase that named
    -- a place the user tapped. NULL when the words never named it (or the user overrode
    -- the place, in which case the phrase named somewhere else and must not be tokenised).
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
        -- WHERE the score was said, and WHERE the dish was named. Scalars, 0-based.
        -- score_evidence itself stays off the wire (provenance, not content) — the
        -- offset + length are how the client quotes it out of the body it already has.
        'evidence_offset', v.evidence_offset,
        'evidence_length', char_length(v.score_evidence),
        'mention_offset',  v.mention_offset,
        'mention_length',  char_length(v.mention_text),
        -- the user fixed this line themselves: no re-sort will overwrite it (0024).
        'corrected', (v.corrected_at is not null)
      ) order by v.entry_position nulls last, v.created_at, v.id) as items,
      count(*)::int as dish_count,
      round(avg(v.score), 2)::numeric(3,2) as avg_score
    from public.reviews v
    join public.dishes d on d.id = v.dish_id
    left join public.saves s on s.dish_id = v.dish_id and s.user_id = (select auth.uid())
    where v.entry_id = e.id
  ) it on true;

comment on view public.entry_cards is
  'The one entry shape for Journal slip / Feed slip / Entry page / Share receipt: entry + author + place + photos[] + items[] + receipt footer (dish_count, avg_score over scored items) + where each finding sits in body (place_offset/length, items[].evidence_* and mention_*, all 0-based UNICODE SCALAR offsets). Read a single entry with ?id=eq.<uuid>; page lists via get_entry_feed / get_entries_by_author / get_entries_at_place.';

grant select on public.entry_cards to authenticated;
