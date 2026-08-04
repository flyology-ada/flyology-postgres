#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
example_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
repository_root=$(CDPATH= cd -- "$example_root/../.." && pwd)
postgres_prefix=$(
  "$repository_root/tests/scripts/ensure-postgres.sh"
)
port=${FLYOLOGY_PGISH_TEST_PORT:-55432}
task_mode=${FLYOLOGY_PGISH_TASK_MODE:-lightweight}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-pgish.XXXXXX")
server_log="$run_root/server.log"
recovery_sql="$run_root/recovery.sql"
server_pid=

cleanup () {
  if [ -n "$server_pid" ]; then
    kill -TERM "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$run_root"
}
trap cleanup EXIT HUP INT TERM

FLYOLOGY_PGISH_PORT=$port \
FLYOLOGY_PGISH_REPO=$repository_root \
  "$example_root/bin/flyology_pgish" \
  >"$server_log" 2>&1 &
server_pid=$!

attempt=0
while ! grep -q '^ready ' "$server_log"; do
  attempt=$((attempt + 1))
  if ! kill -0 "$server_pid" >/dev/null 2>&1 || [ "$attempt" -ge 200 ]; then
    echo "pgish did not become ready" >&2
    cat "$server_log" >&2
    exit 1
  fi
  sleep 0.05
done

FLYOLOGY_PGISH_PORT=$port \
  "$example_root/bin/pgish_extended_client"

if [ -x "$repository_root/examples/psqlish/bin/flyology_psql" ]; then
  PGHOST=127.0.0.1 PGPORT=$port PGUSER=flyology PGDATABASE=flyology \
    "$repository_root/examples/psqlish/scripts/run-pgish-integration.sh"
fi

psql_command () {
  "$postgres_prefix/bin/psql" \
    -h 127.0.0.1 -p "$port" -U flyology -d flyology \
    -v ON_ERROR_STOP=1 "$@"
}

actual=$(psql_command -Atc \
  "SELECT table_name FROM information_schema.tables WHERE table_schema = 'flyology' ORDER BY table_name LIMIT 3")
expected=$(printf '%s\n' flyology_environment flyology_repo_commits flyology_runtime_groups)
if [ "$actual" != "$expected" ]; then
  echo "unexpected information_schema result: $actual" >&2
  cat "$server_log" >&2
  exit 1
fi

psql_command -Atc \
  "SELECT protocol_version, task_mode FROM flyology_server_info" \
  | grep -q "^3.2|$task_mode$"
psql_command -Atc \
  "SELECT name FROM flyology_settings WHERE unit IS NULL ORDER BY name" \
  | grep -q '^authentication$'
psql_command -Atc \
  "SHOW server_version" | grep -q '^18.4$'
null_and_empty=$(psql_command -P 'null=(null)' -Atc \
  "SELECT '', unit FROM flyology_settings WHERE name = 'authentication'")
if [ "$null_and_empty" != '|(null)' ]; then
  echo "NULL and empty text were not distinct: $null_and_empty" >&2
  exit 1
fi
psql_command -Atc \
  "SELECT short_hash, subject, committed_at FROM flyology_repo_commits ORDER BY committed_at DESC LIMIT 2" \
  >/dev/null
psql_command -Atc \
  "SELECT group_id, members, dispatches FROM flyology_runtime_groups ORDER BY group_id LIMIT 4" \
  >/dev/null

cat >"$recovery_sql" <<'SQL'
\set ON_ERROR_STOP off
SELECT FROM flyology_tables;
SELECT 'recovered';
SQL
psql_command -Atf "$recovery_sql" 2>/dev/null | grep -q '^recovered$'

# Catalog/meta-command coverage is intentionally run through real psql.
psql_command -c '\dt flyology.*' >/dev/null
psql_command -c '\d flyology.flyology_server_info' >/dev/null

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=

printf '%s\n' 'real psql-to-pgish integration passed'
