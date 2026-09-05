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
tls_dir="$run_root/tls"
ca_key="$tls_dir/ca-key.pem"
ca_cert="$tls_dir/ca-cert.pem"
server_key="$tls_dir/server-key.pem"
server_request="$tls_dir/server.csr"
server_cert="$tls_dir/server-cert.pem"
server_extensions="$tls_dir/server-ext.cnf"
server_pid=
psql_pid=
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
  if [ -n "$psql_pid" ]; then
    kill "$psql_pid" >/dev/null 2>&1 || true
    wait "$psql_pid" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$run_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tls_dir"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj '/CN=Flyology Postgres Test CA' \
  -keyout "$ca_key" -out "$ca_cert" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -subj '/CN=localhost' \
  -keyout "$server_key" -out "$server_request" >/dev/null 2>&1
printf '%s\n' \
  'subjectAltName=DNS:localhost' \
  'extendedKeyUsage=serverAuth' \
  > "$server_extensions"
openssl x509 -req -sha256 -days 1 \
  -in "$server_request" \
  -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
  -extfile "$server_extensions" \
  -out "$server_cert" >/dev/null 2>&1
chmod 600 "$server_key"

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
  -o "-h 127.0.0.1 -p $real_port -F -c synchronous_commit=off -c full_page_writes=off -c ssl=on -c ssl_cert_file=$server_cert -c ssl_key_file=$server_key -c ssl_ca_file=$ca_cert" \
  -w start \
  >/dev/null
postgres_started=true

POSTGRES_TEST_PORT=$real_port \
POSTGRES_TLS_CA_FILE=$ca_cert \
POSTGRES_TLS_SERVER_NAME=localhost \
  "$tests_root/bin/postgres_test_client"

"$postgres_prefix/bin/pg_ctl" -D "$data_dir" -m fast -w stop >/dev/null
postgres_started=false

POSTGRES_TEST_PORT=$server_port \
POSTGRES_TLS_CERT_FILE=$server_cert \
POSTGRES_TLS_KEY_FILE=$server_key \
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

psql_connection="host=localhost hostaddr=127.0.0.1 port=$server_port user=flyology dbname=postgres sslmode=verify-full sslrootcert=$ca_cert"

if PGPASSWORD=flyology-secret \
  "$postgres_prefix/bin/psql" \
  "host=localhost hostaddr=127.0.0.1 port=$server_port user=flyology dbname=postgres sslmode=disable" \
  -Atc 'select 1' >/dev/null 2>&1; then
  echo "Flyology Postgres TLS server accepted plaintext startup" >&2
  exit 1
fi

if PGPASSWORD=flyology-secret \
  "$postgres_prefix/bin/psql" \
  "host=wrong.example hostaddr=127.0.0.1 port=$server_port user=flyology dbname=postgres sslmode=verify-full sslrootcert=$ca_cert" \
  -Atc 'select 1' >/dev/null 2>&1; then
  echo "psql accepted the Flyology server certificate for a wrong host" >&2
  exit 1
fi

result=$(PGPASSWORD=flyology-secret \
  "$postgres_prefix/bin/psql" \
  "$psql_connection" \
  -v ON_ERROR_STOP=1 \
  -P 'null=(null)' \
  -Atc 'select 1')

expected=$(printf '%s\n' '1|alpha|(null)' '2||omega')
if [ "$result" != "$expected" ]; then
  echo "psql received an unexpected result: $result" >&2
  cat "$server_log" >&2
  exit 1
fi

copy_input="$run_root/copy-input.txt"
copy_output="$run_root/copy-output.txt"
printf 'one\t\n\\N\ttwo\n' > "$copy_input"

PGPASSWORD=flyology-secret \
  "$postgres_prefix/bin/psql" \
  "$psql_connection" \
  -v ON_ERROR_STOP=1 \
  -q \
  -c "\\copy flyology_sink from '$copy_input' with (format text)"

extended_copy_input="$run_root/extended-copy-input.sql"
printf 'copy flyology_sink from stdin \\bind \\g\none\t\n\\N\ttwo\n\\.\n' \
  > "$extended_copy_input"

PGPASSWORD=flyology-secret \
  "$postgres_prefix/bin/psql" \
  "$psql_connection" \
  -v ON_ERROR_STOP=1 \
  -q \
  -f "$extended_copy_input"

PGPASSWORD=flyology-secret \
  "$postgres_prefix/bin/psql" \
  "$psql_connection" \
  -v ON_ERROR_STOP=1 \
  -q \
  -c "\\copy flyology_source to '$copy_output' with (format text)"

if ! cmp -s "$copy_input" "$copy_output"; then
  echo "psql COPY received unexpected streamed data" >&2
  cat "$server_log" >&2
  exit 1
fi

if ! grep -q '^frontend COPY chunks' "$server_log"; then
  echo "psql COPY FROM did not reach the Flyology server helper" >&2
  cat "$server_log" >&2
  exit 1
fi

psql_cancel_output="$run_root/psql-cancel.out"
PGPASSWORD=flyology-secret \
  "$postgres_prefix/bin/psql" \
  "$psql_connection" \
  -v ON_ERROR_STOP=1 \
  -q \
  -c 'select pg_sleep(30)' \
  >"$psql_cancel_output" 2>&1 &
psql_pid=$!

attempt=0
while ! grep -q '^frontend QUERY sleep$' "$server_log"; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    echo "psql did not start the cancellable query" >&2
    cat "$psql_cancel_output" >&2
    cat "$server_log" >&2
    exit 1
  fi
  sleep 0.05
done

kill -INT "$psql_pid"
attempt=0
while kill -0 "$psql_pid" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    echo "psql Ctrl-C did not stop the running query" >&2
    cat "$psql_cancel_output" >&2
    cat "$server_log" >&2
    exit 1
  fi
  sleep 0.05
done

if wait "$psql_pid"; then
  psql_status=0
else
  psql_status=$?
fi
psql_pid=
if [ "$psql_status" -eq 0 ] ||
   ! grep -q 'canceling statement due to user request' "$psql_cancel_output"; then
  echo "psql Ctrl-C did not report query cancellation" >&2
  cat "$psql_cancel_output" >&2
  cat "$server_log" >&2
  exit 1
fi

POSTGRES_TEST_PORT=$server_port \
POSTGRES_TLS_CA_FILE=$ca_cert \
POSTGRES_TLS_SERVER_NAME=localhost \
  "$tests_root/bin/postgres_test_cancellation"

PGPASSWORD=flyology-secret \
  "$postgres_prefix/bin/psql" \
  "$psql_connection" \
  -v ON_ERROR_STOP=1 \
  -q \
  -f "$tests_root/scripts/extended.sql" \
  >/dev/null

for command in PARSE BIND DESCRIBE EXECUTE CLOSE SYNC; do
  if ! grep -q "^frontend $command$" "$server_log"; then
    echo "psql did not send expected extended command: $command" >&2
    cat "$server_log" >&2
    exit 1
  fi
done

if PGPASSWORD=wrong-password \
  "$postgres_prefix/bin/psql" \
  "$psql_connection" \
  -Atc 'select 1' >/dev/null 2>&1; then
  echo "Flyology Postgres test server accepted a wrong password" >&2
  exit 1
fi

#  The dummy input is intentionally non-secret. Using it here makes the client
#  proof valid for the static dummy verifier; the server must still reject the
#  unknown startup user after verification.
if PGPASSWORD='Flyology invalid SCRAM credential' \
  "$postgres_prefix/bin/psql" \
  "host=localhost hostaddr=127.0.0.1 port=$server_port user=unknown-flyology-user dbname=postgres sslmode=verify-full sslrootcert=$ca_cert" \
  -Atc 'select 1' >/dev/null 2>&1; then
  echo "Flyology Postgres test server accepted an unknown user" >&2
  exit 1
fi

printf '%s\n' 'psql-to-Flyology server integration passed'
