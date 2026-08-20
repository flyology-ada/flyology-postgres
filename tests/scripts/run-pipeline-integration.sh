#!/bin/sh
set -eu

#  Run the pipelined extended-query suite against every supported PostgreSQL
#  major. Pipelining depends on server-side behaviour that has changed across
#  releases, so one version proves little on its own.

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tests_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
versions=${POSTGRES_PIPELINE_VERSIONS:-"14.23 15.18 16.14 17.10 18.4"}
port=${POSTGRES_PIPELINE_TEST_PORT:-55436}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-pipeline.XXXXXX")
postgres_prefix=
data_dir=
postgres_started=false

cleanup () {
  if [ "$postgres_started" = true ] && [ -n "$postgres_prefix" ]; then
    "$postgres_prefix/bin/pg_ctl" -D "$data_dir" -m immediate -w stop \
      >/dev/null 2>&1 || true
  fi
  rm -rf -- "$run_root"
}
trap cleanup EXIT HUP INT TERM

for version in $versions; do
  major=${version%%.*}
  postgres_prefix=$(POSTGRES_VERSION=$version \
    "$script_dir/ensure-postgres.sh")
  version_root="$run_root/$major"
  data_dir="$version_root/data"
  mkdir -p "$version_root"

  "$postgres_prefix/bin/initdb" \
    -D "$data_dir" \
    --username=flyology \
    --auth-local=trust \
    --auth-host=trust \
    --no-sync \
    >/dev/null

  "$postgres_prefix/bin/pg_ctl" \
    -D "$data_dir" \
    -l "$version_root/postgres.log" \
    -o "-h 127.0.0.1 -p $port -F -c synchronous_commit=off" \
    -w start \
    >/dev/null
  postgres_started=true

  if ! POSTGRES_TEST_PORT=$port \
       POSTGRES_TEST_LABEL="PostgreSQL $major" \
       "$tests_root/bin/postgres_test_pipeline"; then
    cat "$version_root/postgres.log" >&2
    exit 1
  fi

  "$postgres_prefix/bin/pg_ctl" -D "$data_dir" -m fast -w stop >/dev/null
  postgres_started=false
done

printf '%s\n' "real PostgreSQL pipeline matrix passed: $versions"
