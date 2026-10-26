-- 0093_security_sweep.sql
--
-- Pre-beta security sweep (26 Oct). RLS already denies everything below (0092 audit: every table has
-- RLS, no policy reaches anon); this removes the table GRANTS the app never uses, so a future policy
-- slip or a broad grant can't reopen them, and adds the caps the open surface was missing.
--
--   1. Client writes only where the app writes. anon writes nothing. authenticated keeps exactly the
--      direct writes the app makes (profiles update, entries insert/update, entry_photos, reviews.tags)
--      plus the ones its SECURITY INVOKER RPCs make (saves, blocks, reports, notifications,
--      device_push_tokens delete), and the contract's direct reviews/dishes writes (RLS-scoped to the
--      author). The V1-unused social tables (comments, likes, follows, review_tags, the old lists) and
--      restaurants (written only by definer RPCs and places-search's service role) lose client writes. Reads are untouched (anon keeps SELECT: the
--      staging keep-alive reads through PostgREST and RLS answers it with no rows).
--   2. Text caps on the client-written columns that had none (NOT VALID: new writes only).
--   3. A daily Google Places budget (places_budget_hit), the cost twin of 0067's ai_budget_hit: the
--      per-minute limiter (0013) alone let one account make ~130k billable calls a day.
--   4. is_service_role(): what dish-dedup asks to authorise a non-JWT secret key.

-- ===========================================================================
-- 1. Client writes only where the app writes
-- ===========================================================================
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from anon;
revoke truncate, references, trigger on all tables in schema public from authenticated;

revoke insert, update, delete on
  public.comments, public.comment_likes, public.follows, public.review_likes, public.review_tags,
  public.lists, public.list_dishes, public.restaurants, public.places_rate_limit
from authenticated;

revoke insert, update, delete on
  public.dish_stats, public.restaurant_stats, public.entry_cards, public.my_saved_dishes, public.my_own_saves
from authenticated;

-- profiles are created by handle_new_user (auth trigger); the client only updates its own columns
revoke insert on public.profiles from authenticated;
-- reports are filed by report_entry / report_profile and never edited by the client
revoke update, delete on public.reports from authenticated;

-- ===========================================================================
-- 2. Text caps (generous; NOT VALID so existing rows are left alone)
-- ===========================================================================
alter table public.entries
  add constraint entries_body_length_ck check (char_length(body) <= 20000) not valid;
alter table public.profiles
  add constraint profiles_text_length_ck check (
    char_length(name) <= 100
    and char_length(coalesce(bio, '')) <= 1000
    and char_length(coalesce(city, '')) <= 100
    and char_length(coalesce(avatar_url, '')) <= 2048
  ) not valid;
alter table public.entry_photos
  add constraint entry_photos_url_length_ck check (char_length(photo_url) <= 2048) not valid;
alter table public.reports
  add constraint reports_note_length_ck check (note is null or char_length(note) <= 2000) not valid;

-- ===========================================================================
-- 3. The Places budget
-- ===========================================================================
create table if not exists public.places_usage (
  user_id uuid    not null references auth.users(id) on delete cascade,
  day     date    not null,
  calls   integer not null default 0,
  primary key (user_id, day)
);

comment on table public.places_usage is
  '0093: billable Google Places calls per user per UTC day (places-search). Server-internal: RLS on, no policy, service_role only.';

alter table public.places_usage enable row level security;
revoke all on public.places_usage from public, anon, authenticated;
grant select, insert, update, delete on public.places_usage to service_role;

create index if not exists places_usage_day_idx on public.places_usage (day);

-- true = make the Google call (and it is counted); false = over budget, answer from our own rows.
-- Per user 400 a day (a typed search is ~5-10 calls), everyone together 4,000 a day: at Places
-- prices (~$3-32 per 1,000) the worst day is tens of dollars, not thousands.
create or replace function public.places_budget_hit(p_user_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_day   date := (now() at time zone 'utc')::date;
  v_calls integer;
begin
  if p_user_id is null then
    return false;
  end if;
  if (select coalesce(sum(u.calls), 0) from public.places_usage u where u.day = v_day) >= 4000 then
    return false;
  end if;
  insert into public.places_usage (user_id, day, calls)
    values (p_user_id, v_day, 1)
    on conflict (user_id, day)
    do update set calls = public.places_usage.calls + 1
    returning calls into v_calls;
  delete from public.places_usage u
  using (select x.user_id, x.day from public.places_usage x where x.day < v_day - 7 limit 200) old
  where u.user_id = old.user_id and u.day = old.day;
  return v_calls <= 400;
end; $$;

comment on function public.places_budget_hit(uuid) is
  '0093: counts one billable Google Places call for the user today and says whether it is within the per-user and global daily caps. service_role only.';

revoke all on function public.places_budget_hit(uuid) from public, anon, authenticated;
grant execute on function public.places_budget_hit(uuid) to service_role;

-- ===========================================================================
-- 4. is_service_role(): true only when the request runs as service_role (whatever key carried it)
-- ===========================================================================
create or replace function public.is_service_role()
returns boolean
language sql
stable
security invoker
set search_path = public, extensions
as $$ select current_user = 'service_role' $$;

revoke all on function public.is_service_role() from public;
grant execute on function public.is_service_role() to anon, authenticated, service_role;
