#!/usr/bin/env bash
# .github/scripts/dish_dedup.sh <project-ref> <scan|scan-merge-names|merge|reject|chains> [ids]
#
# Same dish, different names (0071): calls the dish-dedup function on one project with its service-role
# key, read here through SUPABASE_ACCESS_TOKEN and never printed, and writes the open proposals as a
# table to the job summary. `scan` only proposes; `scan-merge-names` also merges the pairs that are the
# same name spelled or ordered differently (no model judged those); `merge` and `reject` act on the
# numbers in `ids` ("3,5,8"; merge also takes "all").
set -euo pipefail

ref="$1"
action="$2"
raw_ids="${3:-}"

# A secret key (sb_secret_…) when the project has one, else the legacy service_role key: a project on
# the new API keys may have the legacy ones switched off. --reveal is tried first (newer CLIs mask secrets).
keys=$(supabase projects api-keys --project-ref "$ref" --reveal -o json 2>/dev/null \
  || supabase projects api-keys --project-ref "$ref" -o json)
key=$(echo "$keys" | jq -r '([.[] | select((.api_key // "") | test("^sb_secret_[A-Za-z0-9_-]+$"))][0].api_key)
                           // ([.[] | select(.name == "service_role")][0].api_key) // empty')
[ -n "$key" ] || { echo "::error::No secret or service_role key for $ref"; exit 1; }
echo "::add-mask::$key"
case "$key" in sb_secret_*) echo "Using the project's secret key" ;; *) echo "Using the legacy service_role key" ;; esac

case "$action" in
  scan) body='{"action":"scan"}' ;;
  scan-merge-names) body='{"action":"scan","merge":"same_name"}' ;;
  chains) body='{"action":"chains"}' ;;   # chain restaurants (0085): check repeated names' websites, link
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

if [ "$action" = chains ]; then
  {
    echo "### Chain restaurants"
    jq -r '"Places with a repeated name: \(.candidates). Websites checked this run: \(.fetched). Chains linked this run: \(.chains | length).",
           "",
           "| Chain | Website | Locations |", "|---|---|---|",
           (.all_chains[] | "| \(.name) | \(.website_host // "") | \(.restaurants[0].count // 0) |")' out.json
  } | tee -a "$GITHUB_STEP_SUMMARY"
  exit 0
fi

{
  echo "### Duplicate dishes: $action"
  jq -r '(if .places != null then "Places checked: \(.places). Pairs the model judged: \(.pairs_asked). New proposals: \(.new_proposals)." else empty end),
         (if .results then (.results[] | "- Proposal \(.proposal_id): \(.status)\(if .note then " (\(.note))" else "" end)") else empty end),
         (if .rejected then "- Rejected: \(.rejected | map(tostring) | join(", "))" else empty end)' out.json
  if [ "$action" != merge ] && [ "$action" != reject ]; then
    echo
    echo "Still open:"
    echo
    echo '| # | Place | Keep | Merge into it | Why |'
    echo '|---|---|---|---|---|'
    jq -r '.open[] | "| \(.id) | \(.restaurants.name // "") | \(.target_name) | \(.source_name) | \(if .reason == "same_name" then "same name, spelled differently" else (.why // "") end) |"' out.json
  fi
} | tee -a "$GITHUB_STEP_SUMMARY"
