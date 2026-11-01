-- 0102 — prod moved from Seoul (vyaexmnajnbryimbkgkf) to Sydney (flfcyokydrmsdrignmcu), Nov 2026.
--
-- Photo URLs written by the apps must name this project's storage (0094, 0101). The Sydney copy's rows
-- were re-pointed at the Sydney host by the move, so the Seoul ref leaves the list. Everything else is
-- 0101's function unchanged: the R2 branch stays, and it stays STABLE (it reads photo_base()).

set search_path = public, extensions;

create or replace function public.storage_url_ok(p_url text, p_bucket text)
returns boolean language sql stable set search_path = public, extensions as $$
  select p_url is null or (
    char_length(p_url) <= 2048
    and p_url !~ '\.\.'
    and (
      p_url ~ ('^(https://(cvoitgoaosofkougmarn|flfcyokydrmsdrignmcu)\.supabase\.co'
               || '|http://(127\.0\.0\.1|localhost):54321)/storage/v1/object/public/'
               || p_bucket || '/[A-Za-z0-9._/-]+(\?[A-Za-z0-9=&._-]*)?$')
      or (public.photo_base() is not null
          and starts_with(p_url, public.photo_base() || p_bucket || '/')
          and substr(p_url, char_length(public.photo_base() || p_bucket || '/') + 1)
              ~ '^[A-Za-z0-9._/-]+(\?[A-Za-z0-9=&._-]*)?$')
    )
  )
$$;
revoke all on function public.storage_url_ok(text, text) from public;
grant execute on function public.storage_url_ok(text, text) to anon, authenticated, service_role;
