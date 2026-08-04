#!/bin/sh
set -eu

for version in 14 15 16 17 18; do
  python3 ../tools/generate_ada.py \
    --major "$version" \
    --proto "../backends/v$version/vendor/pg_query.proto" \
    --output ../src \
    --check
  python3 ../tools/generate_types.py \
    --major "$version" \
    --catalog "../catalog/v$version/pg_type.dat" \
    --output ../src \
    --check
done

alr -n build
./bin/sql_tests
