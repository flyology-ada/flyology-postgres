#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tests_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

"$tests_root/bin/postgres_test_fiber_exceptions"
"$tests_root/bin/tests"
"$script_dir/run-durable-store-integration.sh"

if [ "${POSTGRES_INTEGRATION:-1}" = 1 ]; then
  "$script_dir/run-integration.sh"
  if [ "${POSTGRES_REPLICATION_INTEGRATION:-1}" = 1 ]; then
    "$script_dir/run-replication-integration.sh"
  fi
fi
