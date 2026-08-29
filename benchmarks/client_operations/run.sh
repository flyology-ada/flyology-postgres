#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
postgres_prefix=$("$repository_root/tests/scripts/ensure-postgres.sh")
benchmark_port=${BENCHMARK_PORT:-55439}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-postgres-benchmark.XXXXXX")
data_dir="$run_root/data"
postgres_log="$run_root/postgres.log"
password_file="$run_root/password"
postgres_started=false

cleanup () {
  if [ "$postgres_started" = true ]; then
    "$postgres_prefix/bin/pg_ctl" -D "$data_dir" -m immediate -w stop \
      >/dev/null 2>&1 || true
  fi
  rm -rf -- "$run_root"
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' 'flyology-benchmark' > "$password_file"
"$postgres_prefix/bin/initdb" \
  -D "$data_dir" \
  --username=flyology_benchmark \
  --pwfile="$password_file" \
  --auth-local=trust \
  --auth-host=scram-sha-256 \
  --no-sync \
  >/dev/null

server_options="-h 127.0.0.1 -p $benchmark_port -F -c synchronous_commit=off -c full_page_writes=off -c jit=off -c ssl=off -c max_connections=100"
"$postgres_prefix/bin/pg_ctl" \
  -D "$data_dir" \
  -l "$postgres_log" \
  -o "$server_options" \
  -w start \
  >/dev/null
postgres_started=true

cd "$script_dir"
alr -n build

printf '%s\n' "benchmark_commit=$(git -C "$repository_root" rev-parse HEAD)"
printf '%s\n' "postgres_version=$("$postgres_prefix/bin/postgres" --version)"
printf '%s\n' "server_options=$server_options"
printf '%s\n' "host_os=$(uname -a)"
printf '%s\n' "alire_version=$(alr --version | head -n 1)"
printf '%s\n' "compiler=$(alr exec -- gnat --version 2>/dev/null | head -n 1 || true)"

if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/time ]; then
  /usr/bin/time -l env BENCHMARK_PORT="$benchmark_port" \
    ./bin/postgres_client_operations_benchmark
elif [ -x /usr/bin/time ]; then
  /usr/bin/time -v env BENCHMARK_PORT="$benchmark_port" \
    ./bin/postgres_client_operations_benchmark
else
  env BENCHMARK_PORT="$benchmark_port" \
    ./bin/postgres_client_operations_benchmark
fi
