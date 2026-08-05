#!/bin/sh
set -eu

check_generated_version() {
  version=$1

  python3 ../tools/generate_ada.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --output ../src \
    --oracle-output oracle/src \
    --check
  python3 ../tools/generate_owned_ast.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --output ../src \
    --check
  python3 ../tools/generate_owned_visitors.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --output ../src \
    --check
  python3 ../tools/generate_owned_parser.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --vendor "../backends/v$version/vendor" \
    --output ../src \
    --check
  python3 ../tools/generate_owned_equivalence.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --output src \
    --check
  python3 ../tools/generate_types.py \
    --major "$version" \
    --catalog "../catalog/v$version/pg_type.dat" \
    --output ../src \
    --check
  python3 ../tools/generate_native_parser.py \
    --major "$version" \
    --vendor "../backends/v$version/vendor" \
    --output ../src \
    --check
  python3 ../tools/generate_native_schema.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --version-header "../backends/v$version/vendor/pg_query.h" \
    --vendor "../backends/v$version/vendor" \
    --output ../src \
    --check
}

python3 ../tools/generate_build_layout.py --check

generator_check_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-sql-generator-checks.XXXXXX")

cleanup_generator_checks() {
  for pid_file in "$generator_check_dir"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(sed -n '1p' "$pid_file")
    kill "$pid" 2>/dev/null || true
  done
  for pid_file in "$generator_check_dir"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(sed -n '1p' "$pid_file")
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$generator_check_dir"
}

stop_generator_checks() {
  trap - EXIT HUP INT TERM
  cleanup_generator_checks
  exit 1
}

trap cleanup_generator_checks EXIT
trap stop_generator_checks HUP INT TERM

generator_check_status=0
generator_check_parallel=${FLYOLOGY_SQL_GENERATOR_CHECK_PARALLEL:-1}

case "$generator_check_parallel" in
  0|1)
    ;;
  *)
    echo "FLYOLOGY_SQL_GENERATOR_CHECK_PARALLEL must be 0 or 1" >&2
    exit 2
    ;;
esac

start_generator_check() {
  name=$1
  shift

  "$@" >"$generator_check_dir/$name.log" 2>&1 &
  printf '%s\n' "$!" >"$generator_check_dir/$name.pid"

  if [ "$generator_check_parallel" -eq 0 ]; then
    pid=$(sed -n '1p' "$generator_check_dir/$name.pid")
    if wait "$pid"; then
      status=0
    else
      status=$?
    fi
    printf '%s\n' "$status" >"$generator_check_dir/$name.status"
    rm -f "$generator_check_dir/$name.pid"
  fi
}

finish_generator_check() {
  name=$1

  if [ -f "$generator_check_dir/$name.status" ]; then
    finished_status=$(sed -n '1p' "$generator_check_dir/$name.status")
    rm -f "$generator_check_dir/$name.status"
  else
    pid=$(sed -n '1p' "$generator_check_dir/$name.pid")
    if wait "$pid"; then
      finished_status=0
    else
      finished_status=$?
    fi
    rm -f "$generator_check_dir/$name.pid"
  fi
}

start_generator_check actions \
  python3 ../tools/generate_native_actions.py \
    --all \
    --vendor-root ../backends \
    --output ../src \
    --check \
    --audit

for version in 14 15 16 17 18; do
  start_generator_check "v$version" check_generated_version "$version"
done

finish_generator_check actions
actions_status=$finished_status
if [ "$actions_status" -ne 0 ]; then
  generator_check_status=1
fi

printf '\n== Shared PostgreSQL semantic action generator check ==\n'
cat "$generator_check_dir/actions.log"
if [ "$actions_status" -ne 0 ]; then
  printf 'Shared PostgreSQL semantic action generator check failed with status %s\n' \
    "$actions_status" >&2
fi

for version in 14 15 16 17 18; do
  finish_generator_check "v$version"
  version_status=$finished_status
  if [ "$version_status" -ne 0 ]; then
    generator_check_status=1
  fi

  printf '\n== PostgreSQL %s generator checks ==\n' "$version"
  cat "$generator_check_dir/v$version.log"
  if [ "$version_status" -ne 0 ]; then
    printf 'PostgreSQL %s generator checks failed with status %s\n' \
      "$version" "$version_status" >&2
  fi
done

cleanup_generator_checks
trap - EXIT HUP INT TERM

if [ "$generator_check_status" -ne 0 ]; then
  exit "$generator_check_status"
fi

alr -n build

(
  cd ../examples
  alr -n build
  ./scripts/test.sh
)

(
  cd ../v18/example
  alr -n build
  ./bin/unregistered_views_example
  ./bin/v18_owned_example
)

(
  cd ../multi_example
  alr -n build
  test "$(grep -c 'crate = \"flyology_postgres_sql_core\"' alire/alire.lock)" -eq 1
  ./bin/multi_version_example
)

production_library=../lib/libFlyology_Postgres_SQL.a
production_oracle_symbols=$(
  nm "$production_library" \
    | awk '$NF ~ /sql__(backends|c_oracle|decoder_v[0-9]+|decoders)/ \
           || $NF ~ /flyology_pg(14|15|16|17|18)_/ { print $NF }'
)
if [ -n "$production_oracle_symbols" ]; then
  echo "production SQL library contains validation-only symbols:" >&2
  printf '%s\n' "$production_oracle_symbols" >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin)
    library_suffix=dylib
    nm_flags=-gU
    ;;
  *)
    library_suffix=so
    nm_flags='-D --defined-only'
    ;;
esac

expected_symbols=$(printf '%s\n' data error error_position free length parse)
for version in 14 15 16 17 18; do
  library="../backends/lib/libflyology_pg_query_$version.$library_suffix"
  actual_symbols=$(
    # shellcheck disable=SC2086
    nm $nm_flags "$library" \
      | awk '{print $NF}' \
      | sed -e 's/^_//' -e 's/@.*$//' \
      | sed -n "s/^flyology_pg${version}_//p" \
      | sort
  )
  all_exported=$(
    # shellcheck disable=SC2086
    nm $nm_flags "$library" \
      | awk '{print $NF}' \
      | sed -e 's/^_//' -e 's/@.*$//' \
      | sort
  )
  expected_exported=$(
    printf '%s\n' "$expected_symbols" | sed "s/^/flyology_pg${version}_/"
  )
  if [ "$actual_symbols" != "$expected_symbols" ] \
    || [ "$all_exported" != "$expected_exported" ]; then
    echo "unexpected PostgreSQL $version backend exports:" >&2
    printf '%s\n' "$all_exported" >&2
    exit 1
  fi
done

./bin/sql_tests
