#!/bin/sh
set -eu

example_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

#  Start examples/introspection_server separately. Both programs share these
#  defaults, while PG* remains available when a coordinating test chooses a
#  different endpoint or credentials.
output=$(PGPASSWORD=${PGPASSWORD:-flyology-secret} \
  "$example_root/bin/flyology_psql" --command 'select 1')
printf '%s\n' "$output" | grep -q 'SELECT'
printf '%s\n' "$output" | grep -q '(1 row)'

printf '%s\n' 'psqlish introspection-server integration passed'
