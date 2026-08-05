#!/bin/sh
set -eu

for version in 14 15 16 17 18; do
  python3 ../tools/generate_ada.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --output ../src \
    --check
  python3 ../tools/generate_owned_ast.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --output ../src \
    --check
  python3 ../tools/generate_direct_owned.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --vendor "../backends/v$version/vendor" \
    --output ../src \
    --check
  python3 ../tools/generate_owned_equivalence.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --output ../src \
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
  python3 ../tools/generate_native_actions.py \
    --major "$version" \
    --vendor "../backends/v$version/vendor" \
    --output ../src \
    --check \
    --audit
  python3 ../tools/generate_native_schema.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --version-header "../backends/v$version/vendor/pg_query.h" \
    --vendor "../backends/v$version/vendor" \
    --output ../src \
    --check
done

alr -n build

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
