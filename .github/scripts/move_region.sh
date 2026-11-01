#!/usr/bin/env bash
# .github/scripts/move_region.sh <check|copy> <old-ref> <new-ref>
#
# One-off (Nov 2026): moves prod from Seoul to a new Sydney project. Supabase's own "restore to a new
# project" keeps the region, so this is a logical copy (docs: platform/migrating-within-supabase).
#   check  read-only on both sides: dumps the old database and writes what it holds to the summary.
#   copy   makes the new project a copy of the old one, which is only READ:
#            1. the new project's DB password becomes SUPABASE_DB_PASSWORD, so prod.yml needs no new secret;
#            2. our migrations up to the old project's last one, so auth triggers and storage policies exist;
#            3. every table's rows (auth users keep their IDs, so Apple sign-in finds the same accounts),
#               loaded over emptied tables, so a re-run gives the same result;
#            4. stored photo URLs re-pointed at the new project;
#            5. the photo files themselves, then their owners put back as they were;
#            6. the auth and API settings, and every function secret (values never reach the log);
#            7. the rest of the migrations and every edge function, then counts compared side by side.
# It refuses to copy over a new project that already holds entries newer than the old one's (it is live).
# Needs SUPABASE_ACCESS_TOKEN and SUPABASE_DB_PASSWORD (the old project's).
set -euo pipefail

mode="$1"; old="$2"; new="$3"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
api="https://api.supabase.com/v1"
ref_re='^[a-z]{20}$'
[[ "$old" =~ $ref_re ]] || { echo "::error::bad old ref"; exit 1; }
[[ "$mode" == check || ( "$new" =~ $ref_re && "$old" != "$new" ) ]] || { echo "::error::bad new ref"; exit 1; }
[[ "$mode" == check || "$mode" == copy ]] || { echo "::error::mode is check or copy"; exit 1; }

call() { # method path [json]
  local out code
  out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' -X "$1" "$api$2" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H 'Content-Type: application/json' \
    ${3:+--data "$3"})
  if [[ "$code" != 2* ]]; then echo "::error::$1 $2 → HTTP $code: $(head -c 400 "$out")" >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}

pooler_url() { # ref → session-pooler URL (runners have no IPv6, so never the direct host)
  local cfg host port user
  cfg=$(call GET "/projects/$1/config/database/pooler")
  host=$(echo "$cfg" | jq -r '[.[] | select(.database_type == "PRIMARY")][0].db_host')
  user=$(echo "$cfg" | jq -r '[.[] | select(.database_type == "PRIMARY")][0].db_user')
  port=5432 # session mode: pg_dump and long transactions need it
  local pw
  pw=$(jq -rn --arg p "$SUPABASE_DB_PASSWORD" '$p|@uri')
  echo "postgresql://$user:$pw@$host:$port/postgres?sslmode=require"
}

service_key() { # ref → a secret key (sb_secret_…) or the legacy service_role key
  local keys key
  keys=$(call GET "/projects/$1/api-keys?reveal=true")
  key=$(echo "$keys" | jq -r '([.[] | select((.api_key // "") | test("^sb_secret_[A-Za-z0-9_-]+$"))][0].api_key)
                             // ([.[] | select(.name == "service_role")][0].api_key) // empty')
  [ -n "$key" ] || { echo "::error::no service key for $1" >&2; return 1; }
  echo "::add-mask::$key" >&2
  echo "$key"
}

counts_sql="select 'auth.users' t, count(*) n from auth.users
  union all select 'auth.identities', count(*) from auth.identities
  union all select 'storage.objects', count(*) from storage.objects
  union all select 'public.profiles', count(*) from public.profiles
  union all select 'public.entries', count(*) from public.entries
  union all select 'public.reviews', count(*) from public.reviews
  union all select 'public.entry_photos', count(*) from public.entry_photos
  union all select 'public.restaurants', count(*) from public.restaurants
  union all select 'public.dishes', count(*) from public.dishes
  order by 1"

echo "::group::Connect"
OLD_URL=$(pooler_url "$old"); echo "::add-mask::$OLD_URL"
psql "$OLD_URL" -Atc 'select 1' >/dev/null
echo "old project reachable"
echo "::endgroup::"

# ---- dump the old project (read-only) -----------------------------------------------------------
mkdir -p move && chmod 700 move
supabase db dump --db-url "$OLD_URL" -f move/data.sql --use-copy --data-only \
  -x "storage.buckets_vectors" -x "storage.vector_indexes" \
  -x "auth.schema_migrations" -x "storage.migrations" -x "realtime.schema_migrations" \
  -x "supabase_functions.migrations" -x "cron.job_run_details" -x "net._http_response" \
  -x "net.http_request_queue" -x "vault.secrets"
old_last=$(psql "$OLD_URL" -Atc 'select max(version) from supabase_migrations.schema_migrations')
tables=$(grep -oE '^COPY "[^"]+"\."[^"]+"' move/data.sql | sed 's/^COPY //' | sort -u)
{
  echo "### Old project ($old)"
  echo "Last migration: $old_last. Tables in the dump: $(echo "$tables" | wc -l)."
  echo '```'; psql "$OLD_URL" -Atc "$counts_sql"; echo '```'
  echo "Schemas: $(echo "$tables" | cut -d. -f1 | sort | uniq -c | tr '\n' ' ')"
} | tee -a "$summary"

if [ "$mode" = check ]; then
  [[ "$new" =~ $ref_re ]] && call GET "/projects/$new" | jq '{ref: .id, region, status}' | tee -a "$summary"
  echo "CHECK ONLY: nothing was written." | tee -a "$summary"
  exit 0
fi

# ---- 1. the new project's password --------------------------------------------------------------
call PATCH "/projects/$new/database/password" "$(jq -n --arg p "$SUPABASE_DB_PASSWORD" '{password: $p}')" >/dev/null
sleep 20 # the pooler picks up the new password
NEW_URL=$(pooler_url "$new"); echo "::add-mask::$NEW_URL"
for i in 1 2 3 4 5 6; do psql "$NEW_URL" -Atc 'select 1' >/dev/null 2>&1 && break; sleep 15; done
psql "$NEW_URL" -Atc 'select 1' >/dev/null

# Live guard: once the apps write to the new project it must never be copied over again.
old_latest=$(psql "$OLD_URL" -Atc 'select coalesce(max(created_at), to_timestamp(0)) from public.entries')
if psql "$NEW_URL" -Atc "select to_regclass('public.entries') is not null" | grep -q t; then
  newer=$(psql "$NEW_URL" -Atc "select count(*) from public.entries where created_at > '$old_latest'")
  [ "$newer" = 0 ] || { echo "::error::The new project holds $newer entries newer than the old one: it is live. Not copying." | tee -a "$summary"; exit 1; }
fi

# ---- 2. migrations up to the old project's last one ---------------------------------------------
stage=$(mktemp -d)
mkdir -p "$stage/supabase/migrations"
cp supabase/config.toml "$stage/supabase/"
for f in supabase/migrations/*.sql; do
  v=$(basename "$f" | cut -d_ -f1)
  if [[ "$v" < "$old_last" || "$v" == "$old_last" ]]; then cp "$f" "$stage/supabase/migrations/"; fi
done
(cd "$stage" && supabase db push --db-url "$NEW_URL" --include-all --yes)

# ---- 3. rows, over emptied tables ---------------------------------------------------------------
truncate_list=$(echo "$tables" | paste -sd, -)
{
  echo "SET session_replication_role = replica;"
  echo "TRUNCATE $truncate_list CASCADE;"
  cat move/data.sql
} > move/load.sql
psql "$NEW_URL" --single-transaction -v ON_ERROR_STOP=1 -q -f move/load.sql

# ---- 4. photo URLs → the new project --------------------------------------------------------------
psql "$NEW_URL" -v ON_ERROR_STOP=1 -q <<SQL
set session_replication_role = replica;
do \$\$
declare c record; n bigint; total bigint := 0;
begin
  for c in
    select col.table_schema s, col.table_name t, col.column_name k, col.data_type d, col.udt_name u
    from information_schema.columns col
    join information_schema.tables tb on tb.table_schema = col.table_schema and tb.table_name = col.table_name
    where col.table_schema = 'public' and tb.table_type = 'BASE TABLE'
      and (col.data_type in ('text', 'character varying', 'jsonb') or col.udt_name = '_text')
  loop
    execute format('update %I.%I set %I = replace(%I::text, %L, %L)::%s where %I::text like %L',
      c.s, c.t, c.k, c.k, '$old.supabase.co', '$new.supabase.co',
      case when c.u = '_text' then 'text[]' when c.d = 'jsonb' then 'jsonb' else 'text' end,
      c.k, '%$old.supabase.co%');
    get diagnostics n = row_count; total := total + n;
  end loop;
  raise notice 'rows with re-pointed URLs: %', total;
end \$\$;
SQL

# ---- 5. photo files ---------------------------------------------------------------------------------
OLD_KEY=$(service_key "$old"); NEW_KEY=$(service_key "$new")
psql "$NEW_URL" -v ON_ERROR_STOP=1 -q -c "drop table if exists public._move_objects;
  create table public._move_objects as select bucket_id, name, owner, owner_id, created_at, updated_at, user_metadata from storage.objects;
  revoke all on public._move_objects from anon, authenticated;"
copied=0; failed=0
while IFS=$'\t' read -r bucket name mime; do
  [ -n "$bucket" ] || continue
  path=$(jq -rn --arg n "$name" '$n | split("/") | map(@uri) | join("/")')
  if curl -sSf -o move/obj "https://$old.supabase.co/storage/v1/object/authenticated/$bucket/$path" \
       -H "apikey: $OLD_KEY" -H "Authorization: Bearer $OLD_KEY" \
     && curl -sSf -o /dev/null -X POST "https://$new.supabase.co/storage/v1/object/$bucket/$path" \
       -H "apikey: $NEW_KEY" -H "Authorization: Bearer $NEW_KEY" -H "x-upsert: true" \
       -H "Content-Type: ${mime:-application/octet-stream}" --data-binary @move/obj; then
    copied=$((copied + 1))
  else
    failed=$((failed + 1)); echo "::warning::photo not copied: $bucket/$name"
  fi
done < <(psql "$OLD_URL" -AtF $'\t' -c "select bucket_id, name, coalesce(metadata->>'mimetype', '') from storage.objects order by 1, 2")
rm -f move/obj
psql "$NEW_URL" -v ON_ERROR_STOP=1 -q -c "update storage.objects o
    set owner = m.owner, owner_id = m.owner_id, created_at = m.created_at, updated_at = m.updated_at, user_metadata = m.user_metadata
    from public._move_objects m where o.bucket_id = m.bucket_id and o.name = m.name;
  drop table public._move_objects;"
echo "Photos: $copied copied, $failed failed." | tee -a "$summary"

# ---- 6. settings and function secrets ------------------------------------------------------------
auth=$(call GET "/projects/$old/config/auth" | jq 'with_entries(select(.value != null and
  (.key | test("^(external_|mailer_|smtp_|sms_provider$|site_url$|uri_allow_list$|jwt_exp$|rate_limit_|security_|password_|sessions_|refresh_token_|disable_signup$|mfa_|hook_)"))))
  | if (.smtp_host // "") == "" then with_entries(select(.key | test("^smtp_|^rate_limit_email_sent$") | not)) else . end')
call PATCH "/projects/$new/config/auth" "$auth" >/dev/null
echo "Auth settings copied ($(echo "$auth" | jq 'length') fields). Sign-in with Apple on: $(echo "$auth" | jq -r '.external_apple_enabled // false')." | tee -a "$summary"
rest=$(call GET "/projects/$old/postgrest" | jq '{db_schema, max_rows, db_extra_search_path, db_pool} | with_entries(select(.value != null))')
call PATCH "/projects/$new/postgrest" "$rest" >/dev/null || echo "::warning::API settings not copied"

names=$(supabase secrets list --project-ref "$old" -o json | jq -c '[.[].name | select(startswith("SUPABASE_") | not)]')
if [ "$names" != "[]" ]; then
  # Secret values can't be read through any API, so a throwaway function on the old project hands them
  # over once, to a random token only this run knows, and is deleted straight after.
  token=$(openssl rand -hex 32); echo "::add-mask::$token"
  fdir="$stage/supabase/functions/move-export"; mkdir -p "$fdir"
  cat > "$fdir/index.ts" <<'TS'
Deno.serve(async (req) => {
  const token = Deno.env.get("MOVE_EXPORT_TOKEN");
  if (!token || req.headers.get("x-move-token") !== token) return new Response("no", { status: 403 });
  const { names } = await req.json();
  const out: Record<string, string> = {};
  for (const n of names as string[]) {
    const v = Deno.env.get(n);
    if (v !== undefined && !n.startsWith("SUPABASE_") && n !== "MOVE_EXPORT_TOKEN") out[n] = v;
  }
  return Response.json(out);
});
TS
  supabase secrets set --project-ref "$old" "MOVE_EXPORT_TOKEN=$token" >/dev/null
  (cd "$stage" && supabase functions deploy move-export --project-ref "$old" --no-verify-jwt --use-api)
  sleep 10
  values=""
  for i in 1 2 3; do
    values=$(curl -sSf -X POST "https://$old.supabase.co/functions/v1/move-export" -H "x-move-token: $token" \
      -H 'Content-Type: application/json' --data "{\"names\":$names}") && break
    sleep 15
  done
  supabase functions delete move-export --project-ref "$old" || true
  supabase secrets unset --project-ref "$old" MOVE_EXPORT_TOKEN >/dev/null || true
  [ -n "$values" ] || { echo "::error::function secrets not read"; exit 1; }
  echo "$values" | jq -r 'to_entries[] | .value' | while IFS= read -r v; do echo "::add-mask::$v"; done
  envfile="move/secrets.env"
  echo "$values" | jq -r 'to_entries[] | "\(.key)=\(.value | @json)"' > "$envfile"
  supabase secrets set --project-ref "$new" --env-file "$envfile" >/dev/null
  rm -f "$envfile"
  echo "Function secrets copied: $(echo "$values" | jq -r 'keys | join(", ")')." | tee -a "$summary"
fi

# ---- 7. the rest of the migrations, the functions, and the comparison ----------------------------
supabase db push --db-url "$NEW_URL" --include-all --yes
.github/scripts/deploy_functions.sh "$new"
{
  echo "### New project ($new)"
  echo "Last migration: $(psql "$NEW_URL" -Atc 'select max(version) from supabase_migrations.schema_migrations')."
  echo '```'; psql "$NEW_URL" -Atc "$counts_sql"; echo '```'
} | tee -a "$summary"
diff <(psql "$OLD_URL" -Atc "$counts_sql") <(psql "$NEW_URL" -Atc "$counts_sql") \
  && echo "COUNTS MATCH" | tee -a "$summary" \
  || { echo "::error::counts differ (see above)"; exit 1; }
rm -rf move
