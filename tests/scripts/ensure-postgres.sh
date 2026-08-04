#!/bin/sh
set -eu

version=${POSTGRES_VERSION:-18.4}
case "$version" in
  ''|*[!0-9.]*)
    echo "POSTGRES_VERSION must be a numeric stable release" >&2
    exit 2
    ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tests_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cache_root=${POSTGRES_CACHE_DIR:-"$tests_root/.cache/postgres"}
version_root="$cache_root/$version-openssl"
prefix="$version_root/install"
postgres="$prefix/bin/postgres"

if [ -x "$postgres" ] && "$postgres" --version | grep -q " $version"; then
  printf '%s\n' "$prefix"
  exit 0
fi

archive="postgresql-$version.tar.bz2"
source_url="https://ftp.postgresql.org/pub/source/v$version/$archive"
archive_dir="$version_root/download"
source_dir="$version_root/source"
build_dir="$version_root/build"

mkdir -p "$archive_dir" "$build_dir"

if [ ! -f "$archive_dir/$archive" ]; then
  curl -fL "$source_url" -o "$archive_dir/$archive"
fi
if [ ! -f "$archive_dir/$archive.sha256" ]; then
  curl -fL "$source_url.sha256" -o "$archive_dir/$archive.sha256"
fi

(cd "$archive_dir" && shasum -a 256 -c "$archive.sha256") >&2

if [ ! -x "$source_dir/configure" ]; then
  tar -xjf "$archive_dir/$archive" -C "$version_root"
  mv "$version_root/postgresql-$version" "$source_dir"
fi

if command -v gmake >/dev/null 2>&1; then
  make_command=gmake
else
  make_command=make
fi

jobs=${POSTGRES_BUILD_JOBS:-4}
configure_args=${POSTGRES_CONFIGURE_ARGS:-}

openssl_cppflags=${CPPFLAGS:-}
openssl_ldflags=${LDFLAGS:-}
openssl_pkg_config_path=${PKG_CONFIG_PATH:-}
if command -v brew >/dev/null 2>&1; then
  openssl_prefix=$(brew --prefix openssl@3 2>/dev/null || true)
  if [ -n "$openssl_prefix" ]; then
    openssl_cppflags="-I$openssl_prefix/include $openssl_cppflags"
    openssl_ldflags="-L$openssl_prefix/lib $openssl_ldflags"
    openssl_pkg_config_path="$openssl_prefix/lib/pkgconfig${openssl_pkg_config_path:+:$openssl_pkg_config_path}"
  fi
fi

(cd "$build_dir" && \
  CPPFLAGS="$openssl_cppflags" \
  LDFLAGS="$openssl_ldflags" \
  PKG_CONFIG_PATH="$openssl_pkg_config_path" \
  "$source_dir/configure" \
  --prefix="$prefix" \
  --without-readline \
  --without-zlib \
  --without-icu \
  --with-ssl=openssl \
  $configure_args) >&2
(cd "$build_dir" && "$make_command" -j "$jobs") >&2
(cd "$build_dir" && "$make_command" install) >&2

printf '%s\n' "$prefix"
