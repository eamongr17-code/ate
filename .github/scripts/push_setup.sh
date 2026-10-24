#!/usr/bin/env bash
# .github/scripts/push_setup.sh <project-ref>
#
# Push notifications (0059): turns the send-push drain on for one project once its APNs key is there, and
# writes to the job summary what stands in the way when it is not. Idempotent, so every apply runs it:
#   1. the project's function secrets hold APNS_KEY_ID, APNS_TEAM_ID and APNS_PRIVATE_KEY (names only are
#      read; the values never leave Supabase). Missing → says which, and stops (push stays a no-op);
#   2. push_configure(url) as the service role: stores the function URL and, once, the kick secret the
#      database generates itself (integration-design.md, "One-time setup per project");
#   3. one drain of send-push, which must answer configured: true;
#   4. how many phones have a push token, the other half: a person who never allowed notifications has none.
set -euo pipefail

ref="$1"
url="https://$ref.supabase.co"

names=$(supabase secrets list --project-ref "$ref" -o json | jq -r '.[].name')
missing=""
for n in APNS_KEY_ID APNS_TEAM_ID APNS_PRIVATE_KEY; do
  echo "$names" | grep -qx "$n" || missing="$missing $n"
done
if [ -n "$missing" ]; then
  echo "### Push notifications: off" >> "$GITHUB_STEP_SUMMARY"
  echo "The project's Edge Function secrets lack:$missing. Until they are set, nobody gets a push." | tee -a "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# The same key choice as dish_dedup.sh: a secret key when the project has one, else the legacy service_role.
keys=$(supabase projects api-keys --project-ref "$ref" --reveal -o json 2>/dev/null \
  || supabase projects api-keys --project-ref "$ref" -o json)
key=$(echo "$keys" | jq -r '([.[] | select((.api_key // "") | test("^sb_secret_[A-Za-z0-9_-]+$"))][0].api_key)
                           // ([.[] | select(.name == "service_role")][0].api_key) // empty')
[ -n "$key" ] || { echo "::error::No secret or service_role key for $ref"; exit 1; }
echo "::add-mask::$key"

code=$(curl -s -o configure.json -w '%{http_code}' "$url/rest/v1/rpc/push_configure" \
  -H "apikey: $key" -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
  -d "{\"p_url\":\"$url/functions/v1/send-push\"}")
echo "push_configure: HTTP $code"
[ "$code" = 204 ] || [ "$code" = 200 ] || { cat configure.json; exit 1; }

code=$(curl -s -o drain.json -w '%{http_code}' --max-time 60 -X POST "$url/functions/v1/send-push" \
  -H "Authorization: Bearer $key")
echo "send-push: HTTP $code $(cat drain.json)"
[ "$code" = 200 ] && [ "$(jq -r '.configured // true' drain.json)" = true ] \
  || { echo "::error::send-push is not sending"; exit 1; }

phones=$(curl -s -o /dev/null -D - "$url/rest/v1/device_push_tokens?select=token" \
  -H "apikey: $key" -H "Authorization: Bearer $key" -H 'Prefer: count=exact' -H 'Range: 0-0' \
  | tr -d '\r' | sed -n 's/^[Cc]ontent-[Rr]ange: .*\///p')
{
  echo "### Push notifications: on"
  echo "Drain: $(jq -c '{claimed, sent, dropped}' drain.json). Phones with a push token: ${phones:-unknown}."
} | tee -a "$GITHUB_STEP_SUMMARY"
