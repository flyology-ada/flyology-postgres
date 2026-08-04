#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tests_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
postgres_prefix=$("$script_dir/ensure-postgres.sh")
real_port=${POSTGRES_TEST_PORT:-55433}
server_port=${POSTGRES_PSQL_TEST_PORT:-55432}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-postgres.XXXXXX")
data_dir="$run_root/data"
postgres_log="$run_root/postgres.log"
server_log="$run_root/server.log"
password_file="$run_root/password"
server_pid=
postgres_started=false

cleanup () {
  if [ "$postgres_started" = true ]; then
    "$postgres_prefix/bin/pg_ctl" -D "$data_dir" -m fast -w stop \
      >/dev/null 2>&1 || true
  fi
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
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
  -o "-h 127.0.0.1 -p $real_port -F -c synchronous_commit=off -c full_page_writes=off" \
  -w start \
  >/dev/null
postgres_started=true

POSTGRES_TEST_PORT=$real_port \
  "$tests_root/bin/postgres_test_client"

"$postgres_prefix/bin/pg_ctl" -D "$data_dir" -m fast -w stop >/dev/null
postgres_started=false

POSTGRES_TEST_PORT=$server_port \
  "$tests_root/bin/postgres_test_server" >"$server_log" 2>&1 &
server_pid=$!

attempt=0
while ! grep -q '^ready$' "$server_log"; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    echo "Flyology Postgres test server did not become ready" >&2
    cat "$server_log" >&2
    exit 1
  fi
  sleep 0.05
done

result=$(PGPASSWORD=flyology-secret \
  "$postgres_prefix/bin/psql" \
  -h 127.0.0.1 \
  -p "$server_port" \
  -U flyology \
  -d postgres \
  -v ON_ERROR_STOP=1 \
  -P 'null=(null)' \
  -Atc 'select 1')

expected=$(printf '%s\n' '1|alpha|(null)' '2||omega')
if [ "$result" != "$expected" ]; then
  echo "psql received an unexpected result: $result" >&2
  cat "$server_log" >&2
  exit 1
fi

POSTGRES_TEST_PORT=$server_port \
  "$tests_root/bin/postgres_test_cancellation"

if PGPASSWORD=wrong-password \
  "$postgres_prefix/bin/psql" \
  -h 127.0.0.1 \
  -p "$server_port" \
  -U flyology \
  -d postgres \
  -Atc 'select 1' >/dev/null 2>&1; then
  echo "Flyology Postgres test server accepted a wrong password" >&2
  exit 1
fi

printf '%s\n' 'psql-to-Flyology server integration passed'
