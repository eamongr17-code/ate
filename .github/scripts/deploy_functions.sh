#!/usr/bin/env bash
# .github/scripts/deploy_functions.sh <project-ref>
#
# Deploys every function under supabase/functions, one at a time, with config.toml's per-function
# settings (send-push and dish-dedup take no user JWT). Supabase's server-side bundler sometimes answers
# "Bundle generation timed out" (sort-entry, 28 Oct, twice) with no code change, so each function gets
# three tries with a pause between; only the function that timed out is retried. Exits non-zero if any
# function still failed, after trying all the others.
set -uo pipefail

ref="$1"
failed=()

for dir in supabase/functions/*/; do
  name=$(basename "$dir")
  [[ "$name" == _* || ! -f "$dir/index.ts" ]] && continue
  for attempt in 1 2 3; do
    if supabase functions deploy "$name" --project-ref "$ref" --use-api; then
      continue 2
    fi
    if (( attempt < 3 )); then
      wait=$(( attempt * 30 ))
      echo "::warning::$name deploy failed (try $attempt of 3); retrying in ${wait}s"
      sleep "$wait"
    fi
  done
  echo "::error::$name failed to deploy after 3 tries"
  failed+=("$name")
done

if (( ${#failed[@]} )); then
  echo "Not deployed: ${failed[*]}"
  exit 1
fi
