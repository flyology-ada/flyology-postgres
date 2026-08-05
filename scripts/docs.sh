#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
documentation_output="$project_root/docs/api"
website_kit="$project_root/vendor/website-kit"

if [ ! -f "$website_kit/scripts/render-gnatdoc-theme.mjs" ]; then
   printf '%s\n' \
     "website kit is unavailable; run: git submodule update --init" >&2
   exit 1
fi

if ! command -v gnatdoc >/dev/null 2>&1; then
   installed_gnatdoc=${ALIRE_INSTALL_PREFIX:-"$HOME/.alire"}/bin/gnatdoc
   if [ ! -x "$installed_gnatdoc" ]; then
      printf '%s\n' \
        "gnatdoc not found; install it with: $alr install gnatdoc_bin" >&2
      exit 1
   fi
   PATH=$(dirname "$installed_gnatdoc"):$PATH
   export PATH
fi

case "$documentation_output" in
   "$project_root"/docs/api) ;;
   *)
      printf '%s\n' "refusing unsafe documentation output path: $documentation_output" >&2
      exit 1
      ;;
esac

cd "$project_root"
"$alr" build --stop-after=generation
rm -rf "$documentation_output"
node "$website_kit/scripts/render-gnatdoc-theme.mjs" \
  "$project_root/docs/gnatdoc-theme.json" \
  "$project_root/docs/gnatdoc/html"
FLYOLOGY_POSTGRES_HMAC_PROJECT=$(
  "$alr" exec -- node scripts/resolve-doc-project.mjs hmac_ada.gpr
)
FLYOLOGY_POSTGRES_RANDOM_PROJECT=$(
  "$alr" exec -- node scripts/resolve-doc-project.mjs system_random.gpr
)
export FLYOLOGY_POSTGRES_HMAC_PROJECT
export FLYOLOGY_POSTGRES_RANDOM_PROJECT
export FLYOLOGY_POSTGRES_DOCUMENTATION=true
"$alr" exec -- gnatdoc \
  --backend=html \
  --generate=public \
  --warnings \
  --style=gnat \
  -P flyology_postgres.gpr \
  -O docs/api

mkdir -p docs/api/fonts
cp "$website_kit/assets/fonts/geologica-latin-variable.woff2" docs/api/fonts/
cp assets/brand/flyology-mark-transparent.svg docs/api/flyology-mark.svg
cp "$website_kit/assets/scripts/ada-highlight.js" docs/api/ada-highlight.js
node "$website_kit/scripts/build-api-search-index.mjs" docs/api

test -f docs/api/index.html
test -f docs/api/search-index.js
