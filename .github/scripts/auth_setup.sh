#!/usr/bin/env bash
# .github/scripts/auth_setup.sh <project-ref> <domain>
#
# Email sign-in (Nov 2026): sets the project's Auth config through the Management API, so nothing is
# clicked in the dashboard and every apply puts it back as the repo says. Idempotent.
#   - the sender: Resend's SMTP (RESEND_API_KEY, a GitHub secret) as hello@<domain>. Supabase's own
#     sender manages ~2 emails an hour, so without the key email sign-in stays off for real users.
#   - a 6-digit code in every sign-in email, never a link (mail scanners open links and burn them),
#     valid 10 minutes; one email per address per minute; 100 emails an hour project-wide.
#   - Confirm email stays ON (mailer_autoconfirm false): an account exists only once its code is typed.
#   - site URL + redirect allow-list on <domain>, so no email can send anyone elsewhere.
# Skips with a note (exit 0) when the key or the domain is missing. Needs SUPABASE_ACCESS_TOKEN.
set -euo pipefail

ref="$1"
domain="${2:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ -z "$domain" ] || [ -z "${RESEND_API_KEY:-}" ]; then
  {
    echo "### Email sign-in: sender not set"
    [ -n "$domain" ] || echo "No domain yet (Config/domain.txt)."
    [ -n "${RESEND_API_KEY:-}" ] || echo "No RESEND_API_KEY GitHub secret."
  } | tee -a "$summary"
  exit 0
fi
echo "::add-mask::$RESEND_API_KEY"

dir="$(cd "$(dirname "$0")" && pwd)"
template=$(cat "$dir/../../supabase/templates/code.html")

body=$(jq -n \
  --arg domain "$domain" \
  --arg pass "$RESEND_API_KEY" \
  --arg html "$template" \
  '{
    external_email_enabled: true,
    mailer_autoconfirm: false,
    mailer_otp_length: 6,
    mailer_otp_exp: 600,
    mailer_secure_email_change_enabled: true,
    site_url: ("https://" + $domain),
    uri_allow_list: ("https://" + $domain + "/**,ate://**"),
    smtp_host: "smtp.resend.com",
    smtp_port: "465",
    smtp_user: "resend",
    smtp_pass: $pass,
    smtp_admin_email: ("hello@" + $domain),
    smtp_sender_name: "Ate",
    smtp_max_frequency: 60,
    rate_limit_email_sent: 100,
    mailer_subjects_magic_link: "{{ .Token }} is your Ate code",
    mailer_templates_magic_link_content: $html,
    mailer_subjects_confirmation: "{{ .Token }} is your Ate code",
    mailer_templates_confirmation_content: $html,
    mailer_subjects_reauthentication: "{{ .Token }} is your Ate code",
    mailer_templates_reauthentication_content: $html,
    mailer_subjects_email_change: "{{ .Token }} is your Ate code",
    mailer_templates_email_change_content: $html
  }')

code=$(curl -s -o auth.json -w '%{http_code}' -X PATCH \
  "https://api.supabase.com/v1/projects/$ref/config/auth" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H 'Content-Type: application/json' \
  -d "$body")
if [ "$code" != 200 ]; then
  echo "::error::Auth config update failed: HTTP $code"
  jq -r '.message // .' auth.json 2>/dev/null | head -5 || true
  rm -f auth.json
  exit 1
fi
rm -f auth.json
{
  echo "### Email sign-in: on"
  echo "Codes come from hello@$domain (Resend). Confirm email stays on."
} | tee -a "$summary"
