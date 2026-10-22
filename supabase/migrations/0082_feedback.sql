-- 0082_feedback.sql
-- Ate backend — tester feedback: the bug button's sheet, and TestFlight's own feedback, in one inbox.
--
-- The app sends a report with send_feedback (text, up to three screenshots, build, device, the last
-- screens visited). Screenshots go first to the PRIVATE bucket feedback-screenshots under
-- <uid>/<feedback id>/…, then the RPC names them. The hourly Feedback workflow (feedback.yml, service
-- role) copies each new row into an issue in the private repo eamongr17-code/ate-feedback, marks it
-- filed, and deletes its screenshots from storage (the repo keeps them). TestFlight's screenshot and
-- crash feedback lands here too (source 'testflight'), so one table dedupes both.
--
-- Volume (about 50 beta users): a tester may send 10 an hour and 30 a day; the workflow reads only
-- status = 'new' (partial index), so the table can grow without the hourly read growing with it.
-- Nobody reads another person's report: no SELECT for app roles at all.
--
-- WIRE: ADDITIVE — table feedback, RPC send_feedback, bucket feedback-screenshots.

set search_path = public, extensions;

create table public.feedback (
  id           uuid primary key default gen_random_uuid(),
  -- the sender; null only for TestFlight feedback (Apple gives an email, which we don't keep)
  user_id      uuid references auth.users(id) on delete cascade,
  source       text not null default 'app',
  -- TestFlight's submission id, so a re-read never files it twice
  external_id  text unique,
  body         text not null,
  -- storage paths in feedback-screenshots (app), or the repo paths they were copied to once filed
  screenshots  text[] not null default '{}',
  build        text,
  device       text,
  os_version   text,
  -- the last screens visited, oldest first
  screens      text[] not null default '{}',
  -- same sender + same words: a resend joins the first report's issue instead of opening another
  fingerprint  text not null,
  status       text not null default 'new',
  issue_number integer,
  created_at   timestamptz not null default now(),
  filed_at     timestamptz,
  constraint feedback_source_ck check (source in ('app', 'testflight')),
  constraint feedback_sender_ck check (source = 'testflight' or user_id is not null),
  constraint feedback_status_ck check (status in ('new', 'filed')),
  constraint feedback_body_ck check (char_length(body) between 1 and 4000),
  constraint feedback_screenshots_ck check (cardinality(screenshots) <= 6),
  constraint feedback_screens_ck check (cardinality(screens) <= 20)
);

comment on table public.feedback is
  'Tester feedback (bug button + TestFlight). Written by send_feedback / the Feedback workflow, read only by service role.';

create index feedback_new_idx         on public.feedback (created_at) where status = 'new';
create index feedback_sender_idx      on public.feedback (user_id, created_at desc) where user_id is not null;
create index feedback_fingerprint_idx on public.feedback (fingerprint, created_at desc) where status = 'filed';

alter table public.feedback enable row level security;
-- No policies: app roles never read or write the table directly; send_feedback is the one way in.
revoke all on public.feedback from public, anon, authenticated;
grant all on public.feedback to service_role;

-- ---------------------------------------------------------------------------
-- send_feedback — one report from the signed-in tester. p_id is made by the app, so a retry after a
-- dropped connection returns the same row instead of a second report (and is not counted again).
-- ---------------------------------------------------------------------------
create or replace function public.send_feedback(
  p_id          uuid,
  p_body        text,
  p_screenshots text[] default '{}',
  p_build       text default null,
  p_device      text default null,
  p_os_version  text default null,
  p_screens     text[] default '{}'
)
returns uuid
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid    uuid := (select auth.uid());
  v_body   text := btrim(coalesce(p_body, ''));
  v_shots  text[] := coalesce(p_screenshots, '{}');
  v_prefix text;
begin
  if v_uid is null then
    raise exception 'sign in to send feedback' using errcode = '42501';
  end if;
  if p_id is null then
    raise exception 'feedback_id_required' using errcode = '22023';
  end if;
  if exists (select 1 from public.feedback f where f.id = p_id) then
    if exists (select 1 from public.feedback f where f.id = p_id and f.user_id = v_uid) then
      return p_id;
    end if;
    raise exception 'feedback_id_taken' using errcode = '23505';
  end if;
  if char_length(v_body) = 0 or char_length(v_body) > 4000 then
    raise exception 'feedback_body_length' using errcode = '22023';
  end if;
  if cardinality(v_shots) > 3 then
    raise exception 'feedback_screenshot_cap' using errcode = '22023';
  end if;
  -- a screenshot is one of the sender's own uploads for this report, nothing else
  v_prefix := v_uid::text || '/' || p_id::text || '/';
  if exists (select 1 from unnest(v_shots) s where s is null or left(s, char_length(v_prefix)) <> v_prefix or s like '%..%') then
    raise exception 'feedback_screenshot_path' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('feedback:' || v_uid::text, 0));
  if (select count(*) from public.feedback f where f.user_id = v_uid and f.created_at > now() - interval '1 hour') >= 10
     or (select count(*) from public.feedback f where f.user_id = v_uid and f.created_at > now() - interval '1 day') >= 30 then
    raise exception 'feedback_rate' using errcode = '54000';
  end if;

  insert into public.feedback (id, user_id, source, body, screenshots, build, device, os_version, screens, fingerprint)
  values (
    p_id, v_uid, 'app', v_body, v_shots,
    left(p_build, 40), left(p_device, 80), left(p_os_version, 40),
    (select coalesce(array_agg(left(s, 80) order by o), '{}')
       from unnest(coalesce(p_screens, '{}')) with ordinality as t(s, o) where o > cardinality(coalesce(p_screens, '{}')) - 20),
    md5(v_uid::text || ':' || lower(regexp_replace(v_body, '\s+', ' ', 'g')))
  );
  return p_id;
end; $$;

comment on function public.send_feedback(uuid, text, text[], text, text, text, text[]) is
  'One tester report (bug button). Idempotent on p_id; 10 an hour, 30 a day per tester (54000 feedback_rate).';

revoke all on function public.send_feedback(uuid, text, text[], text, text, text, text[]) from public, anon;
grant execute on function public.send_feedback(uuid, text, text[], text, text, text, text[]) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- feedback-screenshots — PRIVATE. A tester uploads only under their own uid; nobody reads through the
-- API but the service role. 3 MB each, JPEG or PNG (the app sends JPEG).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feedback-screenshots', 'feedback-screenshots', false, 3145728, array['image/jpeg', 'image/png'])
on conflict (id) do nothing;

create policy "feedback_screenshots_insert_own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'feedback-screenshots'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
