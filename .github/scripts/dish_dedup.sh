#!/usr/bin/env bash
# .github/scripts/dish_dedup.sh <project-ref> <scan|merge|reject> [ids]
#
# Same dish, different names (0071): calls the dish-dedup function on one project with its service-role
# key, read here through SUPABASE_ACCESS_TOKEN and never printed, and writes the open proposals as a
# table to the job summary. `scan` only proposes; `merge` and `reject` act on the numbers in `ids`
# ("3,5,8"; merge also takes "all").
set -euo pipefail

ref="$1"
action="$2"
raw_ids="${3:-}"

key=$(supabase projects api-keys --project-ref "$ref" -o json \
  | jq -r '[.[] | select(.name == "service_role")][0].api_key // empty')
[ -n "$key" ] || { echo "::error::No service_role key for $ref"; exit 1; }
echo "::add-mask::$key"

case "$action" in
  scan) body='{"action":"scan"}' ;;
  merge|reject)
    if [ "$action" = merge ] && [ "$raw_ids" = all ]; then
      body='{"action":"merge","ids":"all"}'
    else
      list=$(echo "$raw_ids" | tr -cs '0-9' ',' | sed 's/^,*//; s/,*$//')
      [ -n "$list" ] || { echo "::error::Give the proposal numbers to $action (e.g. 3,5,8)"; exit 1; }
      body="{\"action\":\"$action\",\"ids\":[$list]}"
    fi ;;
  *) echo "::error::Unknown action $action"; exit 1 ;;
esac

code=$(curl -s -o out.json -w '%{http_code}' --max-time 400 \
  "https://$ref.supabase.co/functions/v1/dish-dedup" \
  -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d "$body")
echo "dish-dedup $action: HTTP $code"
[ "$code" = 200 ] || { cat out.json; exit 1; }

{
  echo "### Duplicate dishes: $action"
  jq -r 'if .results then (.results[] | "- Proposal \(.proposal_id): \(.status)\(if .note then " (\(.note))" else "" end)")
         elif .rejected then "- Rejected: \(.rejected | map(tostring) | join(", "))"
         else "Places checked: \(.places). Pairs the model judged: \(.pairs_asked). New proposals: \(.new_proposals)." end' out.json
  if [ "$action" = scan ]; then
    echo
    echo '| # | Place | Keep | Merge into it | Why |'
    echo '|---|---|---|---|---|'
    jq -r '.open[] | "| \(.id) | \(.restaurants.name // "") | \(.target_name) | \(.source_name) | \(if .reason == "same_name" then "same name, spelled differently" else (.why // "") end) |"' out.json
  fi
} | tee -a "$GITHUB_STEP_SUMMARY"
