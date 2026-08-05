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

python3 ../tools/generate_native_actions.py \
  --all \
  --vendor-root ../backends \
  --output ../src \
  --check \
  --audit \
  >"$generator_check_dir/actions.log" 2>&1 &
printf '%s\n' "$!" >"$generator_check_dir/actions.pid"

for version in 14 15 16 17 18; do
  check_generated_version "$version" \
    >"$generator_check_dir/v$version.log" 2>&1 &
  printf '%s\n' "$!" >"$generator_check_dir/v$version.pid"
done

actions_pid=$(sed -n '1p' "$generator_check_dir/actions.pid")
if wait "$actions_pid"; then
  actions_status=0
else
  actions_status=$?
  generator_check_status=1
fi
rm -f "$generator_check_dir/actions.pid"

printf '\n== Shared PostgreSQL semantic action generator check ==\n'
cat "$generator_check_dir/actions.log"
if [ "$actions_status" -ne 0 ]; then
  printf 'Shared PostgreSQL semantic action generator check failed with status %s\n' \
    "$actions_status" >&2
fi

for version in 14 15 16 17 18; do
  pid_file="$generator_check_dir/v$version.pid"
  pid=$(sed -n '1p' "$pid_file")
  if wait "$pid"; then
    version_status=0
  else
    version_status=$?
    generator_check_status=1
  fi
  rm -f "$pid_file"

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
