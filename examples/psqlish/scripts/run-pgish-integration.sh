#!/bin/sh
set -eu

example_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

#  Start examples/pgish separately. Both programs share these defaults, while
#  PG* remains available when a coordinating test chooses a different endpoint.
output=$(
  "$example_root/bin/flyology_psql" <<'PSQL'
\dt
\d flyology.flyology_server_info
SELECT 'still ready' AS state;
\q
PSQL
)
printf '%s\n' "$output" | grep -q 'flyology_repo_commits'
printf '%s\n' "$output" | grep -q 'repository_head'
printf '%s\n' "$output" | grep -q 'still ready'

printf '%s\n' 'psqlish-to-pgish integration passed'
