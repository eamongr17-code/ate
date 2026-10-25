-- 0087_notification_photo.sql
-- NOTIFICATIONS, REFINED (25 Oct, Eamon, mockup "Notifications refined", groups by kind): an "Ate with"
-- row shows the tagger's own photo of the visit on its right.
--
--   my_notifications gains `photo_url` — the tagger's entry's first photo (position order), null when the
--   entry has none. One indexed lookup per row (entry_photos_entry_idx), on a page of at most 100.
--   entry_photos RLS applies as before (security invoker): a photo the reader may not see is null.
--
-- WIRE IMPACT: ADDITIVE. One new trailing column; old builds ignore it. The return type changes, so the
-- function is dropped and made again and its grants are given again here.

set search_path = public, extensions;

drop function if exists public.my_notifications(int, timestamptz, uuid);

create function public.my_notifications(
  p_limit             int         default 30,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null
)
returns table (
  id               uuid,
  type             text,
  created_at       timestamptz,
  read_at          timestamptz,
  actor            jsonb,
  companion_id     uuid,
  companion_status text,
  entry_id         uuid,
  place            jsonb,
  visited_at       timestamptz,
  photo_url        text
)
language plpgsql stable security invoker set search_path = public, extensions as $$
#variable_conflict use_column
begin
  -- The keyset is two-part: both fields of the last row, or neither.
  if (p_cursor_created_at is null) <> (p_cursor_id is null) then
    raise exception 'p_cursor_created_at and p_cursor_id go together' using errcode = '22023';
  end if;
  return query
  select n.id, n.type, n.created_at, n.read_at,
         jsonb_build_object('id', a.id, 'username', a.username, 'name', a.name, 'avatar_url', a.avatar_url),
         c.id, c.status, e.id,
         case when r.id is null then null else jsonb_build_object(
           'id', r.id, 'name', r.name, 'locality', public.place_locality(r.address, r.city)) end,
         e.created_at,
         ph.photo_url
  from public.notifications n
  join public.profiles a         on a.id = n.actor_id         -- RLS: blocked / deactivated actors vanish
  join public.entry_companions c on c.id = n.companion_id
  join public.entries e          on e.id = c.entry_id
  left join public.restaurants r on r.id = e.restaurant_id
  left join lateral (
    select p.photo_url from public.entry_photos p where p.entry_id = e.id order by p.position limit 1
  ) ph on true
  where n.recipient_id = (select auth.uid())
    and n.type = 'ate_with'
    and n.dismissed_at is null
    and (p_cursor_created_at is null or (n.created_at, n.id) < (p_cursor_created_at, p_cursor_id))
  order by n.created_at desc, n.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
end;
$$;

revoke all on function public.my_notifications(int, timestamptz, uuid) from public, anon;
grant execute on function public.my_notifications(int, timestamptz, uuid) to authenticated, service_role;
