#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
example_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

"$example_root/bin/introspection_server_tests"

if [ "${FLYOLOGY_POSTGRES_EXAMPLE_SKIP_INTEGRATION:-0}" != 1 ]; then
  "$script_dir/run-integration.sh"
fi
