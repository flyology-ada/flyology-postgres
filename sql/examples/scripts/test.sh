#!/bin/sh
set -eu

example_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

"$example_root/bin/analyze_sql"
"$example_root/bin/transform_sql_ast"

printf '%s\n' 'SQL visitor examples passed'
