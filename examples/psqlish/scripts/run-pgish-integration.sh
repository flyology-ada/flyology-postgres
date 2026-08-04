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
PSQL
)
printf '%s\n' "$output" | grep -q 'flyology_repo_commits'
printf '%s\n' "$output" | grep -q 'repository_head'
printf '%s\n' "$output" | grep -q 'still ready'
if printf '%s\n' "$output" | grep -q 'raised ADA.IO_EXCEPTIONS.END_ERROR'; then
  echo 'completed-query EOF emitted an End_Error traceback' >&2
  exit 1
fi

pending_output=$(
  "$example_root/bin/flyology_psql" <<'PSQL'
SELECT 'pending EOF' AS state
PSQL
)
printf '%s\n' "$pending_output" | grep -q 'pending EOF'

empty_output=$("$example_root/bin/flyology_psql" </dev/null)
if printf '%s\n' "$empty_output" | grep -q 'raised ADA.IO_EXCEPTIONS.END_ERROR'; then
  echo 'empty EOF emitted an End_Error traceback' >&2
  exit 1
fi

printf '%s\n' 'psqlish-to-pgish integration passed'
