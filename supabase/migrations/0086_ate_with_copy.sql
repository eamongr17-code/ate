-- 0086_ate_with_copy.sql
-- COPY THEIR REVIEW (24 Oct, Eamon, mockup "Copy their review" option A): the person tagged on a dish
-- can take the tagger's review as their own in one tap, then change anything before posting.
--
--   ate_with_prefill now also returns what that tap copies, read LIVE like the rest of the prefill:
--     · `body`  — the tagger's words for the visit ('' when none);
--     · each dish's `score` — the tagger's score on that dish's first line (null when unscored).
--   Copying stays the companion's own act: respond_ate_with posts the scores and words the client sends,
--   exactly as before. Nothing is inferred (rule 7): an unscored line copies as unscored.
--
-- WIRE IMPACT: ADDITIVE. Two new keys on ate_with_prefill's jsonb (`body`, `dishes[].score`); old builds
-- ignore them. Same signature, so grants survive.

set search_path = public, extensions;

create or replace function public.ate_with_prefill(p_companion_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
  v_c   public.entry_companions;
  v_e   public.entries;
  v_out jsonb;
begin
  select * into v_c from public.entry_companions c where c.id = p_companion_id and c.companion_id = v_uid;
  if not found or public.blocked_with(v_c.tagger_id) then
    raise exception 'tag_not_found' using errcode = 'P0002';
  end if;
  select * into v_e from public.entries where id = v_c.entry_id;

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
      ) x), '[]'::jsonb)
  ) into v_out
  from public.profiles a
  left join public.restaurants r on r.id = v_e.restaurant_id
  where a.id = v_c.tagger_id;
  return v_out;
end; $$;
