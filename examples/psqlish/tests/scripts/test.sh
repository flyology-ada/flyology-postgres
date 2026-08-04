#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tests_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
actual=$($tests_root/bin/fixture_tests)
expected='psqlish fixture tests passed'

if [ "$actual" != "$expected" ]; then
  echo "unexpected fixture output: $actual" >&2
  exit 1
fi

printf '%s\n' "$actual"
