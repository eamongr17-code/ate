#!/usr/bin/env bash
# .github/scripts/function_secrets.sh <project-ref>
#
# Copies the function secrets Eamon keeps in GitHub (repo → Settings → Secrets → Actions) into the
# project's Edge Function secrets, so he pastes each value in ONE place. Only names that are present
# are set; a missing one is reported by name and left as it is in Supabase. Values never reach the log.
#   APNS_KEY_ID, APNS_PRIVATE_KEY (the .p8's text)  → push (send-push). APNS_TEAM_ID is Ate's team.
set -euo pipefail

ref="$1"
envfile=$(mktemp)
trap 'rm -f "$envfile"' EXIT
set_names=""
missing=""

add() { # name value
  local name="$1" value="$2"
  if [ -z "$value" ]; then missing="$missing $name"; return; fi
  # .env format: a multi-line value (the .p8) is double-quoted with its newlines escaped.
  printf '%s="%s"\n' "$name" "$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS="\\n"} {print}' | sed 's/\\n$//')" >> "$envfile"
  set_names="$set_names $name"
}

add APNS_KEY_ID "${APNS_KEY_ID:-}"
add APNS_PRIVATE_KEY "${APNS_PRIVATE_KEY:-}"
if [ -n "${APNS_KEY_ID:-}" ] && [ -n "${APNS_PRIVATE_KEY:-}" ]; then
  add APNS_TEAM_ID "9M6K835247"
fi

if [ -s "$envfile" ]; then
  supabase secrets set --project-ref "$ref" --env-file "$envfile" >/dev/null
fi
{
  echo "### Function secrets"
  echo "Set from GitHub:${set_names:- none}."
  [ -z "$missing" ] || echo "Not in GitHub secrets (left as they are in Supabase):$missing."
} | tee -a "$GITHUB_STEP_SUMMARY"
