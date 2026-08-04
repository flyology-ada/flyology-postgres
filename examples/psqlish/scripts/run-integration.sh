#!/bin/sh
set -eu

example_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository_root=$(CDPATH= cd -- "$example_root/../.." && pwd)
postgres_prefix=$($repository_root/tests/scripts/ensure-postgres.sh)
port=${PSQLISH_POSTGRES_PORT:-55434}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/psqlish.XXXXXX")
data_dir=$run_root/data
password_file=$run_root/password
postgres_log=$run_root/postgres.log
tls_dir=$run_root/tls
ca_key=$tls_dir/ca-key.pem
ca_cert=$tls_dir/ca-cert.pem
server_key=$tls_dir/server-key.pem
server_request=$tls_dir/server.csr
server_cert=$tls_dir/server-cert.pem
server_extensions=$tls_dir/server-ext.cnf
started=false

cleanup () {
  if [ "$started" = true ]; then
    "$postgres_prefix/bin/pg_ctl" -D "$data_dir" -m fast -w stop \
      >/dev/null 2>&1 || true
  fi
  rm -rf -- "$run_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tls_dir"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj '/CN=psqlish Test CA' \
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
  -o "-h 127.0.0.1 -p $port -F -c synchronous_commit=off -c ssl=on -c ssl_cert_file=$server_cert -c ssl_key_file=$server_key" \
  -w start \
  >/dev/null
started=true

output=$(PGHOST=localhost PGHOSTADDR=127.0.0.1 PGPORT=$port PGUSER=flyology \
  PGDATABASE=postgres PGPASSWORD=flyology-secret PGSSLMODE=verify-full \
  PGSSLROOTCERT=$ca_cert \
  "$example_root/bin/psqlish" \
  --command "select 2 as n, null::text as missing, ''::text as empty; select 3 as n;")

printf '%s\n' "$output" | grep -q 'NULL'
printf '%s\n' "$output" | grep -q 'SELECT 1'

batch_output=$(PGHOST=localhost PGHOSTADDR=127.0.0.1 PGPORT=$port PGUSER=flyology \
  PGDATABASE=postgres PGPASSWORD=flyology-secret PGSSLMODE=verify-full \
  PGSSLROOTCERT=$ca_cert \
  "$example_root/bin/psqlish" \
  --command 'select generate_series(1, 1001) as n')
printf '%s\n' "$batch_output" | grep -q '(1000 rows)'
printf '%s\n' "$batch_output" | grep -q '(1 row)'
printf '%s\n' "$batch_output" | grep -q 'SELECT 1001'

describe_output=$(PGHOST=localhost PGHOSTADDR=127.0.0.1 PGPORT=$port PGUSER=flyology \
  PGDATABASE=postgres PGPASSWORD=flyology-secret PGSSLMODE=verify-full \
  PGSSLROOTCERT=$ca_cert \
  "$example_root/bin/psqlish" <<'PSQL'
\d pg_catalog.pg_class
\q
PSQL
)
printf '%s\n' "$describe_output" | grep -q 'relname'

if PGHOST=localhost PGHOSTADDR=127.0.0.1 PGPORT=$port PGUSER=flyology \
  PGDATABASE=postgres PGPASSWORD=flyology-secret PGSSLMODE=verify-full \
  PGSSLROOTCERT=$ca_cert \
  "$example_root/bin/psqlish" --command 'select 1 / 0' \
  >/dev/null 2>&1; then
  echo 'SQL errors must produce a failing exit status' >&2
  exit 1
fi

if PGHOST=wrong.example PGHOSTADDR=127.0.0.1 PGPORT=$port PGUSER=flyology \
  PGDATABASE=postgres PGPASSWORD=flyology-secret PGSSLMODE=verify-full \
  PGSSLROOTCERT=$ca_cert \
  "$example_root/bin/psqlish" --command 'select 1' \
  >/dev/null 2>&1; then
  echo 'psqlish accepted a certificate for the wrong host' >&2
  exit 1
fi

printf '%s\n' 'psqlish verified-TLS real Postgres integration passed'
