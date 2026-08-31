-- 0016 — restore a TOTAL unique constraint on restaurants.google_place_id.
--
-- 0014 replaced the column UNIQUE (restaurants_google_place_id_key) with a PARTIAL
-- unique index (WHERE google_place_id IS NOT NULL) so manual rows could carry NULL.
-- But PostgREST's upsert emits a bare ON CONFLICT (google_place_id), which CANNOT
-- match a partial index -> every places-search op=details resolve 500s
-- ("there is no unique or exclusion constraint matching the ON CONFLICT specification")
-- and any not-yet-in-DB restaurant fails to log.
--
-- A TOTAL unique constraint gives the same guarantee 0014 wanted: NULLS DISTINCT is
-- the default, so many manual (NULL) rows never collide, while non-NULL Place ids stay
-- deduped -- and ON CONFLICT (google_place_id) works again.

-- Add the total constraint first (coexists with the partial index), then drop the partial.
alter table public.restaurants
  add constraint restaurants_google_place_id_key unique (google_place_id);

drop index if exists public.restaurants_google_place_id_uq;

comment on constraint restaurants_google_place_id_key on public.restaurants is
  'Total UNIQUE (NULLS DISTINCT): dedupes Places rows by Place id, allows many NULL manual rows, and is targetable by ON CONFLICT (google_place_id) — see 0016 (0014 regression fix).';
