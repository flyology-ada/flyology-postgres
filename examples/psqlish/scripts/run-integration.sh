#!/bin/sh
set -eu

example_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository_root=$(CDPATH= cd -- "$example_root/../.." && pwd)
postgres_prefix=$($repository_root/tests/scripts/ensure-postgres.sh)
port=${PSQLISH_POSTGRES_PORT:-55434}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-psqlish.XXXXXX")
data_dir=$run_root/data
password_file=$run_root/password
postgres_log=$run_root/postgres.log
started=false

cleanup () {
  if [ "$started" = true ]; then
    "$postgres_prefix/bin/pg_ctl" -D "$data_dir" -m fast -w stop \
      >/dev/null 2>&1 || true
  fi
  rm -rf -- "$run_root"
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' 'flyology-secret' > "$password_file"
"$postgres_prefix/bin/initdb" \
  -D "$data_dir" \
  --username=flyology \
  --pwfile="$password_file" \
  --auth-local=trust \
  --auth-host=scram-sha-256 \
  --no-sync \
  >/dev/null
"$postgres_prefix/bin/pg_ctl" \
  -D "$data_dir" \
  -l "$postgres_log" \
  -o "-h 127.0.0.1 -p $port -F -c synchronous_commit=off" \
  -w start \
  >/dev/null
started=true

output=$(PGHOST=127.0.0.1 PGPORT=$port PGUSER=flyology \
  PGDATABASE=postgres PGPASSWORD=flyology-secret \
  "$example_root/bin/flyology_psql" \
  --command "select 2 as n, null::text as missing, ''::text as empty; select 3 as n;")

printf '%s\n' "$output" | grep -q 'NULL'
printf '%s\n' "$output" | grep -q 'SELECT 1'

batch_output=$(PGHOST=127.0.0.1 PGPORT=$port PGUSER=flyology \
  PGDATABASE=postgres PGPASSWORD=flyology-secret \
  "$example_root/bin/flyology_psql" \
  --command 'select generate_series(1, 1001) as n')
printf '%s\n' "$batch_output" | grep -q '(1000 rows)'
printf '%s\n' "$batch_output" | grep -q '(1 row)'
printf '%s\n' "$batch_output" | grep -q 'SELECT 1001'

describe_output=$(PGHOST=127.0.0.1 PGPORT=$port PGUSER=flyology \
  PGDATABASE=postgres PGPASSWORD=flyology-secret \
  "$example_root/bin/flyology_psql" <<'PSQL'
\d pg_catalog.pg_class
\q
PSQL
)
printf '%s\n' "$describe_output" | grep -q 'relname'

if PGHOST=127.0.0.1 PGPORT=$port PGUSER=flyology \
  PGDATABASE=postgres PGPASSWORD=flyology-secret \
  "$example_root/bin/flyology_psql" --command 'select 1 / 0' \
  >/dev/null 2>&1; then
  echo 'SQL errors must produce a failing exit status' >&2
  exit 1
fi

printf '%s\n' 'psqlish real Postgres integration passed'
