#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tests_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

"$tests_root/bin/tests"

if [ "${POSTGRES_INTEGRATION:-1}" = 1 ]; then
  "$script_dir/run-integration.sh"
fi
