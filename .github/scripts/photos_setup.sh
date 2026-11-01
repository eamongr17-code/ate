#!/usr/bin/env bash
# .github/scripts/photos_setup.sh <prod|staging> <project-ref> [move]
#
# Photos on Cloudflare R2 (0103). Idempotent, so every apply runs it; the summary says what it did and
# what stands in the way:
#   0. waits for the domain (Config/domain.txt, one line) and CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID.
#      Missing → says so and stops; photos stay on Supabase.
#   1. the R2 bucket (ate-photos / ate-photos-staging), and the photos Worker (cloudflare/photos) on
#      photos.<domain> / photos-staging.<domain>, deployed with the project's URL and publishable key.
#   2. checks the Worker: health 200, an unsigned upload refused (401).
#   With "move" (staging: always; prod: the Prod workflow's "move photos" box):
#   3. photo_storage_set(base): every app build with 0103's client uploads to R2 from now on.
#   4. copies every Supabase-hosted photo the database names (and its _t.jpg) into R2 through the
#      Worker's /v1/import, which answers per file: copied / present / missing / bad.
#   5. checks each copied photo is served from the photos host (HTTP 200, same size), then
#      move_photo_urls switches the rows that name those, and only those, in one transaction.
#      Anything not verified keeps its working Supabase URL; the next run tries again.
# Supabase's copies are left in place: they are the rollback (photo_storage_set(null) + the old URLs).
# Clearing them is a separate, later decision.
set -euo pipefail

env_name="$1"
ref="$2"
move="${3:-}"
url="https://$ref.supabase.co"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
say() { echo "$1" | tee -a "$summary"; }

echo "### Photos on Cloudflare R2 ($env_name)" >> "$summary"

domain=$( [ -f Config/domain.txt ] && tr -d '[:space:]' < Config/domain.txt || true )
if [ -z "$domain" ]; then
  say "Waiting for the domain (Config/domain.txt is empty). Photos stay on Supabase."
  exit 0
fi
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  say "Waiting for the CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID repository secrets. Photos stay on Supabase."
  exit 0
fi

if [ "$env_name" = prod ]; then
  host="photos.$domain"; bucket="ate-photos"; worker="ate-photos"
else
  host="photos-staging.$domain"; bucket="ate-photos-staging"; worker="ate-photos-staging"
fi
base="https://$host/"

# The same key choice as push_setup.sh: a secret key when the project has one, else service_role;
# the publishable (or anon) key is what the Worker sends to Supabase Auth with a caller's token.
keys=$(supabase projects api-keys --project-ref "$ref" --reveal -o json 2>/dev/null \
  || supabase projects api-keys --project-ref "$ref" -o json)
key=$(echo "$keys" | jq -r '([.[] | select((.api_key // "") | test("^sb_secret_[A-Za-z0-9_-]+$"))][0].api_key)
                           // ([.[] | select(.name == "service_role")][0].api_key) // empty')
anon=$(echo "$keys" | jq -r '([.[] | select((.api_key // "") | test("^sb_publishable_[A-Za-z0-9_-]+$"))][0].api_key)
                            // ([.[] | select(.name == "anon")][0].api_key) // empty')
[ -n "$key" ] && [ -n "$anon" ] || { echo "::error::No service or publishable key for $ref"; exit 1; }
echo "::add-mask::$key"

# 1. bucket + Worker
cd cloudflare/photos
npm ci --no-fund --no-audit >/dev/null
if ! npx wrangler r2 bucket list 2>/dev/null | grep -qx "name:[[:space:]]*$bucket"; then
  npx wrangler r2 bucket create "$bucket" --location oc 2>&1 | tail -2 || true   # oc = Oceania, nearest Melbourne
fi
cat > wrangler.generated.toml <<TOML
name = "$worker"
main = "src/index.ts"
compatibility_date = "2026-10-01"
workers_dev = false
routes = [{ pattern = "$host", custom_domain = true }]

[[r2_buckets]]
binding = "PHOTOS"
bucket_name = "$bucket"

[vars]
SUPABASE_URL = "$url"
SUPABASE_ANON_KEY = "$anon"
PUBLIC_BASE = "$base"

[observability]
enabled = true
TOML
npx wrangler deploy -c wrangler.generated.toml 2>&1 | tail -8
cd - >/dev/null

# 2. the Worker answers (a new custom domain's certificate can take a minute or two)
ok=""
for i in $(seq 1 20); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "${base}v1/health")" = 200 ]; then ok=1; break; fi
  sleep 10
done
[ -n "$ok" ] || { say "The photos Worker at $base is not answering yet; the next run tries again. Photos stay on Supabase."; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary 'x' \
  "${base}v1/object/review-photos/00000000-0000-4000-8000-000000000000/probe.jpg")
[ "$code" = 401 ] || { echo "::error::an unsigned upload got HTTP $code, not 401"; exit 1; }
say "Worker live at $base (bucket $bucket); unsigned uploads refused."

rpc() {  # rpc <function> <json>
  curl -sS --fail-with-body "$url/rest/v1/rpc/$1" -H "apikey: $key" -H "Authorization: Bearer $key" \
    -H 'Content-Type: application/json' -d "$2"
}

if [ "$move" != move ]; then
  current=$(rpc photo_storage_config '{}' | jq -r '.base // "Supabase"')
  say "New uploads go to: $current. Tick \"move photos\" to switch to R2 and move existing photos."
  exit 0
fi

# 3. new uploads → R2
rpc photo_storage_set "$(jq -nc --arg b "$base" '{p_base: $b}')" >/dev/null
say "New uploads now go to R2."

# 4. copy what the database names, and each photo's thumbnail
from="$url/storage/v1/object/public/"
rpc photo_keys_on_supabase "$(jq -nc --arg f "$from" '{p_from: $f}')" | jq -r '.[]' | sort -u > keys.txt
originals=$(wc -l < keys.txt | tr -d ' ')
{ cat keys.txt; grep '^review-photos/' keys.txt | grep -v '_t\.jpg$' | sed -E 's/\.[^./]*$/_t.jpg/'; } | sort -u > all.txt
: > results.jsonl
split -l 10 all.txt batch.   # 10 a call: a free-plan Worker makes at most 50 subrequests
for f in batch.*; do
  [ -s "$f" ] || continue
  curl -sS --fail-with-body "${base}v1/import" -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "$(jq -R . "$f" | jq -sc '{keys: .}')" | jq -c '.results[]' >> results.jsonl
done
rm -f batch.*
copied=$(jq -s '[.[] | select(.status == "copied")] | length' results.jsonl)
present=$(jq -s '[.[] | select(.status == "present")] | length' results.jsonl)

# 5. verify each original from the public host, then move only those rows
: > verified.txt
missing=0
while read -r k; do
  r=$(jq -r --arg k "$k" 'select(.key == $k) | "\(.status) \(.size // 0)"' results.jsonl | head -1)
  status=${r%% *}; size=${r##* }
  if [ "$status" = copied ] || [ "$status" = present ]; then
    got=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' "$base$k")
    if [ "$got" = "200 $size" ]; then echo "$k" >> verified.txt; continue; fi
  fi
  missing=$((missing + 1)); echo "not moved: $k ($r)"
done < keys.txt
moved=$(rpc move_photo_urls "$(jq -nc --arg f "$from" --rawfile k verified.txt '{p_from: $f, p_keys: ($k | split("\n") | map(select(. != "")))}')")
say "Photos named by the database on Supabase: $originals. Copied now: $copied, already in R2: $present (counts include thumbnails)."
say "Verified on $host and moved: $(wc -l < verified.txt | tr -d ' '). Rows switched: $moved."
[ "$missing" = 0 ] || say "Not moved (keep their Supabase URL, retried next run): $missing."
rm -f keys.txt all.txt results.jsonl verified.txt
