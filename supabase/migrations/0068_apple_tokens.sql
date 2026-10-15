-- 0068_apple_tokens.sql
--
-- App Store guideline 5.1.1(v): deleting an account that signed in with Apple revokes its Apple
-- token. The apple-token edge function exchanges the app's one-time authorization code for Apple's
-- refresh token after sign-in and keeps it here, so it can revoke it just before delete_account.
-- One row per person; the auth.users cascade takes it with the account.

create table if not exists public.apple_tokens (
  user_id       uuid        primary key references auth.users(id) on delete cascade,
  refresh_token text        not null check (length(refresh_token) between 1 and 2048),
  updated_at    timestamptz not null default now()
);

comment on table public.apple_tokens is
  '0068: Apple''s refresh token per person, kept only to revoke it on account deletion. Server-internal: RLS on, no policy, service_role only.';

alter table public.apple_tokens enable row level security;
revoke all on public.apple_tokens from public, anon, authenticated;
grant select, insert, update, delete on public.apple_tokens to service_role;
