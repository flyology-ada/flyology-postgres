#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tests_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
versions=${POSTGRES_REPLICATION_VERSIONS:-"14.23 15.18 16.14 17.10 18.4"}
port=${POSTGRES_REPLICATION_PORT:-55434}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-replication.XXXXXX")
tls_dir="$run_root/tls"
ca_key="$tls_dir/ca-key.pem"
ca_cert="$tls_dir/ca-cert.pem"
server_key="$tls_dir/server-key.pem"
server_request="$tls_dir/server.csr"
server_cert="$tls_dir/server-cert.pem"
server_extensions="$tls_dir/server-ext.cnf"
postgres_prefix=
data_dir=
postgres_log=
postgres_started=false
replication_client_pid=
replication_server_pid=
replication_proxy_pid=
primary_proxy_pid=
reset_proxy_pid=
replication_client_port=$port
standby_started=false
standby_dir=

archive_failure_logs () {
  artifact_dir=${POSTGRES_REPLICATION_ARTIFACT_DIR:-}
  if [ -z "$artifact_dir" ]; then
    return
  fi
  mkdir -p "$artifact_dir"
  for version_dir in "$run_root"/[0-9]*; do
    if [ ! -d "$version_dir" ]; then
      continue
    fi
    artifact_version="$artifact_dir/$(basename "$version_dir")"
    mkdir -p "$artifact_version"
    for log in "$version_dir"/*.log; do
      if [ -f "$log" ]; then
        cp "$log" "$artifact_version/"
      fi
    done
  done
}

cleanup () {
  status=$?
  if [ -n "$replication_client_pid" ]; then
    kill "$replication_client_pid" >/dev/null 2>&1 || true
    wait "$replication_client_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$primary_proxy_pid" ]; then
    kill "$primary_proxy_pid" >/dev/null 2>&1 || true
    wait "$primary_proxy_pid" >/dev/null 2>&1 || true
  fi
  if [ "$standby_started" = true ]; then
    "$postgres_prefix/bin/pg_ctl" -D "$standby_dir" -m immediate -w stop \
      >/dev/null 2>&1 || true
  fi
  if [ -n "$replication_server_pid" ]; then
    kill "$replication_server_pid" >/dev/null 2>&1 || true
    wait "$replication_server_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$replication_proxy_pid" ]; then
    kill "$replication_proxy_pid" >/dev/null 2>&1 || true
    wait "$replication_proxy_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$reset_proxy_pid" ]; then
    kill "$reset_proxy_pid" >/dev/null 2>&1 || true
    wait "$reset_proxy_pid" >/dev/null 2>&1 || true
  fi
  if [ "$postgres_started" = true ]; then
    "$postgres_prefix/bin/pg_ctl" -D "$data_dir" -m immediate -w stop \
      >/dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ]; then
    archive_failure_logs
  fi
  rm -rf -- "$run_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tls_dir"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj '/CN=Flyology Replication Test CA' \
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

psql () {
  PGPASSWORD=flyology-secret \
    "$postgres_prefix/bin/psql" \
    "host=127.0.0.1 port=$port user=flyology dbname=postgres sslmode=disable" \
    -v ON_ERROR_STOP=1 "$@"
}

run_client () {
  scenario=$1
  major=$2
  logical_version=${3:-}
  slot=${4:-}
  start_lsn=${5:-}

  if ! POSTGRES_REPLICATION_PORT=$replication_client_port \
    POSTGRES_TLS_CA_FILE=$ca_cert \
    POSTGRES_REPLICATION_SCENARIO=$scenario \
    POSTGRES_SERVER_MAJOR=$major \
    POSTGRES_LOGICAL_VERSION=$logical_version \
    POSTGRES_REPLICATION_SLOT=$slot \
    POSTGRES_REPLICATION_START_LSN=$start_lsn \
      "$tests_root/bin/postgres_test_replication"
  then
    printf '%s\n' "PostgreSQL $major server log:" >&2
    cat "$postgres_log" >&2
    return 1
  fi
}

run_parallel_abort () {
  major=$1
  slot=$2
  client_log="$version_root/logical_v4-client.log"

  POSTGRES_REPLICATION_PORT=$replication_client_port \
  POSTGRES_TLS_CA_FILE=$ca_cert \
  POSTGRES_REPLICATION_SCENARIO=logical_v4 \
  POSTGRES_SERVER_MAJOR=$major \
  POSTGRES_LOGICAL_VERSION=4 \
  POSTGRES_REPLICATION_SLOT=$slot \
  POSTGRES_REPLICATION_START_LSN= \
    "$tests_root/bin/postgres_test_replication" \
    >"$client_log" 2>&1 &
  replication_client_pid=$!

  attempt=0
  while [ "$(psql -qAtc \
    "select count(*) from pg_replication_slots where slot_name = '$slot' and active")" != 1 ]
  do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
      printf '%s\n' \
        "logical_v4 client did not activate slot $slot" >&2
      cat "$client_log" >&2
      return 1
    fi
    sleep 0.05
  done

  seed_large_abort 500000
  if ! wait "$replication_client_pid"; then
    replication_client_pid=
    cat "$client_log" >&2
    printf '%s\n' "PostgreSQL $major server log:" >&2
    cat "$postgres_log" >&2
    return 1
  fi
  replication_client_pid=
  cat "$client_log"
}

run_reconnect_resume () {
  major=$1
  slot=$2
  adversity=${3:-graceful}

  initial_lsn=$(psql -qAtc \
    "select confirmed_flush_lsn from pg_replication_slots where slot_name = '$slot'")
  psql -qAtc \
    "insert into flyology_replication values (800000, 'checkpoint', 0, 'watchful')" \
    >/dev/null
  seed_large_commit 800000

  if [ "$adversity" = reset ]; then
    reset_proxy_port=$((port + 12))
    reset_proxy_log="$version_root/reset-proxy.log"
    python3 "$script_dir/fragmenting-proxy.py" \
      --listen-port "$reset_proxy_port" \
      --upstream-port "$port" \
      --seed "$((major * 1009 + 3))" \
      --reset-server-bytes 20000 \
      >"$reset_proxy_log" 2>&1 &
    reset_proxy_pid=$!
    attempt=0
    until grep -q '^ready seed=' "$reset_proxy_log"; do
      attempt=$((attempt + 1))
      if ! kill -0 "$reset_proxy_pid" >/dev/null 2>&1; then
        cat "$reset_proxy_log" >&2
        printf '%s\n' "reset transport proxy exited early" >&2
        return 1
      fi
      if [ "$attempt" -ge 100 ]; then
        cat "$reset_proxy_log" >&2
        printf '%s\n' "reset transport proxy did not become ready" >&2
        return 1
      fi
      sleep 0.05
    done
    if POSTGRES_REPLICATION_PORT=$reset_proxy_port \
      POSTGRES_TLS_CA_FILE=$ca_cert \
      POSTGRES_REPLICATION_SCENARIO=logical_resume_reset \
      POSTGRES_SERVER_MAJOR=$major \
      POSTGRES_LOGICAL_VERSION=1 \
      POSTGRES_REPLICATION_SLOT=$slot \
      POSTGRES_REPLICATION_START_LSN=$initial_lsn \
        "$tests_root/bin/postgres_test_replication" \
        >"$version_root/reset-client.log" 2>&1
    then
      printf '%s\n' "reset replication client unexpectedly succeeded" >&2
      return 1
    fi
    attempt=0
    until grep -q '^reset server_bytes=20000$' "$reset_proxy_log"; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 100 ]; then
        cat "$reset_proxy_log" >&2
        cat "$version_root/reset-client.log" >&2
        printf '%s\n' "transport reset was not injected" >&2
        return 1
      fi
      sleep 0.05
    done
    kill "$reset_proxy_pid" >/dev/null 2>&1 || true
    wait "$reset_proxy_pid" >/dev/null 2>&1 || true
    reset_proxy_pid=
  elif [ "$adversity" = timeout ]; then
    timeout_proxy_port=$((port + 13))
    timeout_proxy_log="$version_root/timeout-proxy.log"
    python3 "$script_dir/fragmenting-proxy.py" \
      --listen-port "$timeout_proxy_port" \
      --upstream-port "$port" \
      --seed "$((major * 1009 + 4))" \
      --stall-server-bytes 20000 \
      --stall-seconds 1 \
      >"$timeout_proxy_log" 2>&1 &
    reset_proxy_pid=$!
    attempt=0
    until grep -q '^ready seed=' "$timeout_proxy_log"; do
      attempt=$((attempt + 1))
      if ! kill -0 "$reset_proxy_pid" >/dev/null 2>&1; then
        cat "$timeout_proxy_log" >&2
        printf '%s\n' "timeout transport proxy exited early" >&2
        return 1
      fi
      if [ "$attempt" -ge 100 ]; then
        cat "$timeout_proxy_log" >&2
        printf '%s\n' "timeout transport proxy did not become ready" >&2
        return 1
      fi
      sleep 0.05
    done
    if ! POSTGRES_REPLICATION_PORT=$timeout_proxy_port \
      POSTGRES_TLS_CA_FILE=$ca_cert \
      POSTGRES_REPLICATION_SCENARIO=logical_resume_timeout \
      POSTGRES_REPLICATION_RECEIVE_TIMEOUT=0.2 \
      POSTGRES_SERVER_MAJOR=$major \
      POSTGRES_LOGICAL_VERSION=1 \
      POSTGRES_REPLICATION_SLOT=$slot \
      POSTGRES_REPLICATION_START_LSN=$initial_lsn \
        "$tests_root/bin/postgres_test_replication" \
        >"$version_root/timeout-client.log" 2>&1
    then
      cat "$version_root/timeout-client.log" >&2
      printf '%s\n' "timed replication client did not report its timeout" >&2
      return 1
    fi
    attempt=0
    until grep -Eq '^stall server_bytes=[0-9]+ seconds=1.0$' \
      "$timeout_proxy_log"
    do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 100 ]; then
        cat "$timeout_proxy_log" >&2
        cat "$version_root/timeout-client.log" >&2
        printf '%s\n' "transport stall was not injected" >&2
        return 1
      fi
      sleep 0.05
    done
    kill "$reset_proxy_pid" >/dev/null 2>&1 || true
    wait "$reset_proxy_pid" >/dev/null 2>&1 || true
    reset_proxy_pid=
  else
    run_client logical_resume_first "$major" 1 "$slot" "$initial_lsn"
  fi

  attempt=0
  acknowledged_lsn=$initial_lsn
  while [ "$(psql -qAtc \
    "select '$acknowledged_lsn'::pg_lsn > '$initial_lsn'::pg_lsn")" != t ]
  do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
      printf '%s\n' \
        "logical resume did not persist its acknowledged checkpoint" >&2
      return 1
    fi
    sleep 0.05
    acknowledged_lsn=$(psql -qAtc \
      "select confirmed_flush_lsn from pg_replication_slots where slot_name = '$slot'")
  done

  restart_lsn=$(psql -qAtc \
    "select restart_lsn from pg_replication_slots where slot_name = '$slot'")
  if [ "$(psql -qAtc \
    "select '$restart_lsn'::pg_lsn <= '$acknowledged_lsn'::pg_lsn")" != t ]; then
    printf '%s\n' "logical slot restart LSN advanced beyond its acknowledgement" >&2
    return 1
  fi

  run_client logical_resume_second "$major" 1 "$slot" "$acknowledged_lsn"
  final_lsn=$(psql -qAtc \
    "select confirmed_flush_lsn from pg_replication_slots where slot_name = '$slot'")
  if [ "$(psql -qAtc \
    "select '$final_lsn'::pg_lsn > '$acknowledged_lsn'::pg_lsn")" != t ]; then
    printf '%s\n' "logical resume did not acknowledge the replayed transaction" >&2
    return 1
  fi
  printf '%s\n' \
    "PostgreSQL $major $adversity reconnect resumed $acknowledged_lsn -> $final_lsn"
}

drop_slot () {
  slot=$1
  slot_query="select pg_drop_replication_slot(slot_name) "
  slot_query="${slot_query}from pg_replication_slots "
  slot_query="${slot_query}where slot_name = '$slot'"
  psql -qAtc "$slot_query" >/dev/null
}

create_slot () {
  slot=$1
  two_phase=${2:-false}
  drop_slot "$slot"
  if [ "$two_phase" = true ]; then
    psql -qAtc \
      "select slot_name from pg_create_logical_replication_slot('$slot', 'pgoutput', false, true)" \
      >/dev/null
  else
    psql -qAtc \
      "select slot_name from pg_create_logical_replication_slot('$slot', 'pgoutput')" \
      >/dev/null
  fi
}

seed_large_commit () {
  offset=$1
  psql -q <<SQL
begin;
insert into flyology_replication (id, payload, marker, mood)
select $offset + g, repeat(g::text || ':', 32), g, 'happy'
from generate_series(1, 1000) as g;
commit;
SQL
}

seed_large_prepare () {
  offset=$1
  gid=$2
  psql -q <<SQL
begin;
insert into flyology_replication (id, payload, marker, mood)
select $offset + g, repeat(g::text || ':', 32), g, 'watchful'
from generate_series(1, 1000) as g;
prepare transaction '$gid';
commit prepared '$gid';
SQL
}

seed_large_abort () {
  offset=$1
  psql -q <<SQL
begin;
insert into flyology_replication (id, payload, marker, mood)
select $offset + g, repeat(g::text || ':', 32), g, 'happy'
from generate_series(1, 1000) as g;
select pg_sleep(3);
rollback;
SQL
}

run_real_standby () {
  major=$1
  replication_server_port=$((port + 1))
  standby_port=$((port + 2))
  primary_proxy_port=$((port + 11))
  standby_dir="$version_root/standby"
  standby_log="$version_root/standby.log"
  replication_server_log="$version_root/replication-server.log"
  primary_proxy_log="$version_root/primary-proxy.log"
  marker="replayed-by-flyology-$major"
  physical_slot="flyology_physical_$major"

  psql -q <<'SQL'
create table flyology_standby_probe (value text primary key);
insert into flyology_standby_probe values ('base-backup');
checkpoint;
SQL

  PGPASSWORD=flyology-secret \
    "$postgres_prefix/bin/pg_basebackup" \
    -d "host=127.0.0.1 port=$port user=flyology dbname=postgres sslmode=disable" \
    -D "$standby_dir" -X stream -c fast --no-sync >/dev/null

  psql -qAtc 'select pg_switch_wal()' >/dev/null
  psql -qAtc \
    "insert into flyology_standby_probe values ('$marker')" >/dev/null
  primary_end_lsn=$(psql -qAtc 'select pg_current_wal_flush_lsn()')
  primary_system_id=$(
    "$postgres_prefix/bin/pg_controldata" "$data_dir" |
      sed -n 's/^Database system identifier: *//p'
  )

  "$postgres_prefix/bin/pg_ctl" \
    -D "$data_dir" -m fast -w stop >/dev/null
  postgres_started=false

  POSTGRES_REPLICATION_SERVER_PORT=$replication_server_port \
  POSTGRES_PRIMARY_SYSTEM_ID=$primary_system_id \
  POSTGRES_PRIMARY_END_LSN=$primary_end_lsn \
  POSTGRES_PRIMARY_WAL_DIR="$data_dir/pg_wal" \
  POSTGRES_PRIMARY_WAL_SEGMENT_SIZE=16777216 \
  POSTGRES_PRIMARY_SLOT=$physical_slot \
  POSTGRES_TLS_CERT_FILE=$server_cert \
  POSTGRES_TLS_KEY_FILE=$server_key \
    "$tests_root/bin/postgres_test_replication_server" \
    >"$replication_server_log" 2>&1 &
  replication_server_pid=$!

  attempt=0
  until grep -q '^ready$' "$replication_server_log"; do
    attempt=$((attempt + 1))
    if ! kill -0 "$replication_server_pid" >/dev/null 2>&1; then
      cat "$replication_server_log" >&2
      printf '%s\n' "Flyology replication server exited early" >&2
      return 1
    fi
    if [ "$attempt" -ge 100 ]; then
      cat "$replication_server_log" >&2
      printf '%s\n' "Flyology replication server did not become ready" >&2
      return 1
    fi
    sleep 0.05
  done

  python3 "$script_dir/fragmenting-proxy.py" \
    --listen-port "$primary_proxy_port" \
    --upstream-port "$replication_server_port" \
    --seed "$((major * 1009 + 2))" \
    >"$primary_proxy_log" 2>&1 &
  primary_proxy_pid=$!
  attempt=0
  until grep -q '^ready seed=' "$primary_proxy_log"; do
    attempt=$((attempt + 1))
    if ! kill -0 "$primary_proxy_pid" >/dev/null 2>&1; then
      cat "$primary_proxy_log" >&2
      printf '%s\n' "standby transport proxy exited early" >&2
      return 1
    fi
    if [ "$attempt" -ge 100 ]; then
      cat "$primary_proxy_log" >&2
      printf '%s\n' "standby transport proxy did not become ready" >&2
      return 1
    fi
    sleep 0.05
  done

  : > "$standby_dir/standby.signal"
  primary_conninfo="primary_conninfo = 'host=localhost hostaddr=127.0.0.1"
  primary_conninfo="$primary_conninfo port=$primary_proxy_port"
  primary_conninfo="$primary_conninfo user=flyology password=flyology-secret"
  primary_conninfo="$primary_conninfo sslmode=verify-full sslrootcert=$ca_cert"
  primary_conninfo="$primary_conninfo application_name=flyology_standby_$major'"
  {
    printf '%s\n' "$primary_conninfo"
    printf '%s\n' "primary_slot_name = '$physical_slot'"
    printf '%s\n' "wal_retrieve_retry_interval = '100ms'"
  } >> "$standby_dir/postgresql.auto.conf"

  standby_options="-h 127.0.0.1 -p $standby_port -F"
  standby_options="$standby_options -c hot_standby=on"
  standby_options="$standby_options -c max_wal_senders=20"
  standby_options="$standby_options -c max_replication_slots=20"
  standby_options="$standby_options -c max_prepared_transactions=20"
  standby_options="$standby_options -c wal_receiver_status_interval=10s"
  if ! "$postgres_prefix/bin/pg_ctl" \
    -D "$standby_dir" -l "$standby_log" \
    -o "$standby_options" -w start >/dev/null
  then
    cat "$replication_server_log" >&2
    cat "$standby_log" >&2
    return 1
  fi
  standby_started=true

  attempt=0
  replayed=
  while [ "$replayed" != "$marker" ]; do
    attempt=$((attempt + 1))
    replayed=$(PGPASSWORD=flyology-secret PGCONNECT_TIMEOUT=1 \
      "$postgres_prefix/bin/psql" \
      "host=127.0.0.1 port=$standby_port user=flyology dbname=postgres sslmode=disable" \
      -qAtc \
      "select value from flyology_standby_probe where value = '$marker'" \
      2>/dev/null || true)
    if [ "$attempt" -ge 300 ]; then
      printf '%s\n' "PostgreSQL $major standby did not replay marker" >&2
      cat "$replication_server_log" >&2
      cat "$standby_log" >&2
      return 1
    fi
    sleep 0.1
  done

  attempt=0
  until grep -q '^standby feedback received=' "$replication_server_log"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
      printf '%s\n' "PostgreSQL $major standby did not send feedback" >&2
      cat "$replication_server_log" >&2
      return 1
    fi
    sleep 0.05
  done

  attempt=0
  until grep -q '^streaming complete$' "$replication_server_log"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
      printf '%s\n' "PostgreSQL $major COPY BOTH did not finish" >&2
      cat "$replication_server_log" >&2
      return 1
    fi
    sleep 0.05
  done
  if ! grep -q '^standby keepalive reply received=' \
    "$replication_server_log"
  then
    cat "$replication_server_log" >&2
    printf '%s\n' "PostgreSQL $major standby missed requested keepalive reply" >&2
    return 1
  fi

  "$postgres_prefix/bin/pg_ctl" \
    -D "$standby_dir" -m fast -w stop >/dev/null
  standby_started=false

  feedback_before_restart=$(grep -c '^standby feedback received=' \
    "$replication_server_log")
  if ! "$postgres_prefix/bin/pg_ctl" \
    -D "$standby_dir" -l "$standby_log" \
    -o "$standby_options" -w start >/dev/null
  then
    cat "$replication_server_log" >&2
    cat "$standby_log" >&2
    return 1
  fi
  standby_started=true

  attempt=0
  feedback_after_restart=$feedback_before_restart
  while [ "$feedback_after_restart" -le "$feedback_before_restart" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 200 ]; then
      printf '%s\n' "PostgreSQL $major restarted standby sent no feedback" >&2
      cat "$replication_server_log" >&2
      cat "$standby_log" >&2
      return 1
    fi
    sleep 0.05
    feedback_after_restart=$(grep -c '^standby feedback received=' \
      "$replication_server_log")
  done

  "$postgres_prefix/bin/pg_ctl" \
    -D "$standby_dir" -m fast -w stop >/dev/null
  standby_started=false
  kill "$replication_server_pid" >/dev/null 2>&1 || true
  wait "$replication_server_pid" >/dev/null 2>&1 || true
  replication_server_pid=
  kill "$primary_proxy_pid" >/dev/null 2>&1 || true
  wait "$primary_proxy_pid" >/dev/null 2>&1 || true
  primary_proxy_pid=
  if ! grep -Eq '^connection [0-9]+ .*client_writes=[1-9][0-9]* .*server_writes=[1-9][0-9]*$' \
    "$primary_proxy_log"
  then
    cat "$primary_proxy_log" >&2
    printf '%s\n' "standby transport proxy moved no bidirectional data" >&2
    return 1
  fi
  printf '%s\n' "PostgreSQL $major real standby passed"
}

for version in $versions; do
  major=${version%%.*}
  postgres_prefix=$(POSTGRES_VERSION=$version \
    "$script_dir/ensure-postgres.sh")
  version_root="$run_root/$major"
  data_dir="$version_root/data"
  postgres_log="$version_root/postgres.log"
  password_file="$version_root/password"
  mkdir -p "$version_root"
  printf '%s\n' 'flyology-secret' > "$password_file"

  "$postgres_prefix/bin/initdb" \
    -D "$data_dir" \
    --username=flyology \
    --pwfile="$password_file" \
    --auth-local=trust \
    --auth-host=scram-sha-256 \
    --no-sync \
    >/dev/null

  server_options="-h 127.0.0.1 -p $port -F"
  server_options="$server_options -c wal_level=logical"
  server_options="$server_options -c max_wal_senders=20"
  server_options="$server_options -c max_replication_slots=20"
  server_options="$server_options -c max_prepared_transactions=20"
  server_options="$server_options -c logical_decoding_work_mem=64kB"
  server_options="$server_options -c wal_sender_timeout=2000"
  server_options="$server_options -c ssl=on"
  server_options="$server_options -c ssl_cert_file=$server_cert"
  server_options="$server_options -c ssl_key_file=$server_key"
  server_options="$server_options -c ssl_ca_file=$ca_cert"
  "$postgres_prefix/bin/pg_ctl" \
    -D "$data_dir" \
    -l "$postgres_log" \
    -o "$server_options" \
    -w start \
    >/dev/null
  postgres_started=true

  replication_client_port=$((port + 10))
  replication_proxy_log="$version_root/replication-proxy.log"
  python3 "$script_dir/fragmenting-proxy.py" \
    --listen-port "$replication_client_port" \
    --upstream-port "$port" \
    --seed "$((major * 1009 + 1))" \
    >"$replication_proxy_log" 2>&1 &
  replication_proxy_pid=$!
  attempt=0
  until grep -q '^ready seed=' "$replication_proxy_log"; do
    attempt=$((attempt + 1))
    if ! kill -0 "$replication_proxy_pid" >/dev/null 2>&1; then
      cat "$replication_proxy_log" >&2
      printf '%s\n' "replication transport proxy exited early" >&2
      exit 1
    fi
    if [ "$attempt" -ge 100 ]; then
      cat "$replication_proxy_log" >&2
      printf '%s\n' "replication transport proxy did not become ready" >&2
      exit 1
    fi
    sleep 0.05
  done

  printf '%s\n' "Testing real PostgreSQL $version replication"
  psql -q <<'SQL'
create type flyology_mood as enum ('happy', 'watchful');
create table flyology_replication
  (id integer primary key,
   payload text,
   marker integer not null,
   mood flyology_mood not null);
alter table flyology_replication replica identity full;
create publication flyology_publication
  for table flyology_replication;
SQL

  physical_lsn=$(psql -qAtc 'select pg_current_wal_flush_lsn()')
  psql -q <<'SQL'
create table flyology_physical_probe (value text);
insert into flyology_physical_probe
select repeat(md5(g::text), 8) from generate_series(1, 256) as g;
checkpoint;
SQL
  run_client physical "$major" "" "" "$physical_lsn"

  psql -qAtc 'truncate flyology_replication' >/dev/null
  slot="flyology_v1_$major"
  create_slot "$slot"
  psql -q <<'SQL'
begin;
insert into flyology_replication values
  (1001, null, 1, 'happy'),
  (1002,
   (select string_agg(md5(g::text), '')
    from generate_series(1, 1000) as g),
   1,
   'watchful');
update flyology_replication set marker = 2 where id = 1002;
delete from flyology_replication where id = 1001;
select pg_logical_emit_message
  (true, 'flyology', 'real-message');
commit;
truncate flyology_replication restart identity cascade;
insert into flyology_replication values
  (1003, 'final-state', 3, 'happy');
SQL
  run_client logical_v1 "$major" 1 "$slot"
  drop_slot "$slot"

  psql -qAtc 'truncate flyology_replication' >/dev/null
  slot="flyology_resume_$major"
  create_slot "$slot"
  run_reconnect_resume "$major" "$slot"
  drop_slot "$slot"

  psql -qAtc 'truncate flyology_replication' >/dev/null
  slot="flyology_reset_$major"
  create_slot "$slot"
  run_reconnect_resume "$major" "$slot" reset
  drop_slot "$slot"

  psql -qAtc 'truncate flyology_replication' >/dev/null
  slot="flyology_timeout_$major"
  create_slot "$slot"
  run_reconnect_resume "$major" "$slot" timeout
  drop_slot "$slot"

  psql -qAtc 'truncate flyology_replication' >/dev/null
  slot="flyology_v2_$major"
  create_slot "$slot"
  seed_large_commit 200000
  run_client logical_v2 "$major" 2 "$slot"
  drop_slot "$slot"

  if [ "$major" -ge 15 ]; then
    psql -qAtc 'truncate flyology_replication' >/dev/null
    slot="flyology_v3_$major"
    create_slot "$slot" true
    psql -q <<SQL
begin;
insert into flyology_replication values
  (300001, 'commit prepared', 1, 'happy');
prepare transaction 'flyology_commit_$major';
commit prepared 'flyology_commit_$major';
begin;
insert into flyology_replication values
  (300002, 'rollback prepared', 1, 'watchful');
prepare transaction 'flyology_rollback_$major';
rollback prepared 'flyology_rollback_$major';
SQL
    run_client logical_v3 "$major" 3 "$slot"
    drop_slot "$slot"

    psql -qAtc 'truncate flyology_replication' >/dev/null
    slot="flyology_v3_stream_$major"
    create_slot "$slot" true
    seed_large_prepare 400000 "flyology_stream_prepare_$major"
    run_client logical_v3_stream "$major" 3 "$slot"
    drop_slot "$slot"
  fi

  if [ "$major" -ge 16 ]; then
    psql -qAtc 'truncate flyology_replication' >/dev/null
    slot="flyology_v4_$major"
    create_slot "$slot"
    run_parallel_abort "$major" "$slot"
    drop_slot "$slot"
  fi

  if [ "$major" -eq 18 ]; then
    psql -qAtc 'truncate flyology_replication' >/dev/null
    slot=flyology_binary_18
    create_slot "$slot"
    psql -qAtc \
      "insert into flyology_replication values (600001, 'binary', 1, 'happy')" \
      >/dev/null
    run_client logical_binary "$major" 4 "$slot"
    drop_slot "$slot"

    psql -qAtc 'truncate flyology_replication' >/dev/null
    psql -qAtc \
      "select pg_replication_origin_create('flyology_origin')" \
      >/dev/null
    slot=flyology_origin_18
    create_slot "$slot"
    psql -q <<'SQL'
select pg_replication_origin_session_setup('flyology_origin');
begin;
select pg_replication_origin_xact_setup('0/10', now());
insert into flyology_replication values
  (700001, 'origin', 1, 'watchful');
commit;
select pg_replication_origin_session_reset();
SQL
    run_client logical_origin "$major" 4 "$slot"
    drop_slot "$slot"
    psql -qAtc \
      "select pg_replication_origin_drop('flyology_origin')" \
      >/dev/null
  fi

  run_real_standby "$major"

  kill "$replication_proxy_pid" >/dev/null 2>&1 || true
  wait "$replication_proxy_pid" >/dev/null 2>&1 || true
  replication_proxy_pid=
  if ! grep -Eq '^connection [0-9]+ .*client_writes=[1-9][0-9]* .*server_writes=[1-9][0-9]*$' \
    "$replication_proxy_log"
  then
    cat "$replication_proxy_log" >&2
    printf '%s\n' "replication transport proxy moved no bidirectional data" >&2
    exit 1
  fi
done

printf '%s\n' \
  "real PostgreSQL replication matrix passed: $versions"
