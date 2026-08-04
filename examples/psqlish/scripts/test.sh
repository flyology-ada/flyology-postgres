#!/bin/sh
set -eu

example_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

(cd "$example_root/tests" && alr -n build && alr -n test)

if [ "${POSTGRES_INTEGRATION:-0}" = 1 ]; then
  "$example_root/scripts/run-integration.sh"
fi
