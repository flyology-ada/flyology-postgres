#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
site_output="$project_root/build/site"
website_kit="$project_root/vendor/website-kit"

if [ ! -f "$website_kit/scripts/install-assets.mjs" ]; then
   printf '%s\n' \
     "website kit is unavailable; run: git submodule update --init" >&2
   exit 1
fi

case "$site_output" in
   "$project_root"/build/site) ;;
   *)
      printf '%s\n' "refusing unsafe site output path: $site_output" >&2
      exit 1
      ;;
esac

rm -rf "$site_output"
mkdir -p "$site_output/assets" "$site_output/api"

cp -R "$project_root/website/." "$site_output/"
node "$website_kit/scripts/install-assets.mjs" "$site_output"
cp -R "$project_root/assets/brand" "$site_output/assets/brand"

asset_version=${GITHUB_SHA:-$(git -C "$project_root" rev-parse HEAD)}

for page in "$site_output/index.html" "$site_output/guide/index.html"; do
   versioned_page="$page.versioned"
   sed \
      -e "s|site.css\"|site.css?v=$asset_version\"|g" \
      -e "s|postgres.css\"|postgres.css?v=$asset_version\"|g" \
      -e "s|ada-highlight.js\"|ada-highlight.js?v=$asset_version\"|g" \
      -e "s|site.js\"|site.js?v=$asset_version\"|g" \
      "$page" > "$versioned_page"
   mv "$versioned_page" "$page"
done

"$project_root/scripts/docs.sh"
cp -R "$project_root/docs/api/." "$site_output/api/"
touch "$site_output/.nojekyll"

test -f "$site_output/index.html"
test "$(cat "$site_output/CNAME")" = "postgres.flyology.org"
test -f "$site_output/guide/index.html"
test -f "$site_output/api/index.html"

printf 'Flyology Postgres site built at %s\n' "$site_output"
