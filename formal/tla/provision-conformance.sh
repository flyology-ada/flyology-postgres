#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
manifest=$repository_root/tests/alire.toml
source_repository=https://github.com/flyology-ada/tla.git
formal_build_root=$repository_root/build/formal-tla
source_root=$formal_build_root/source
install_root=$formal_build_root/install
tool=$install_root/bin/flyology-tla
toolchain=$formal_build_root/toolchain
revision_file=$install_root/flyology-tla-revision

revision=$(sed -n \
  's|^flyology_tla = { url = "https://github.com/flyology-ada/tla.git", commit = "\([0-9a-f]*\)" }$|\1|p' \
  "$manifest")
case "$revision" in
  ''|*[!0-9a-f]*)
    printf '%s\n' "cannot read the exact flyology_tla pin from $manifest" >&2
    exit 1
    ;;
esac
test "${#revision}" -eq 40 || {
  printf '%s\n' "invalid flyology_tla revision in $manifest: $revision" >&2
  exit 1
}

mkdir -p "$formal_build_root"
if [ ! -d "$source_root/.git" ]; then
  test ! -e "$source_root" || {
    printf '%s\n' "existing path is not a Git checkout: $source_root" >&2
    exit 1
  }
  git init -q "$source_root"
  git -C "$source_root" remote add origin "$source_repository"
fi

test "$(git -C "$source_root" remote get-url origin)" = "$source_repository" || {
  printf '%s\n' "unexpected flyology_tla origin: $source_root" >&2
  exit 1
}

current_revision=$(git -C "$source_root" rev-parse HEAD 2>/dev/null || true)
if [ "$current_revision" != "$revision" ]; then
  git -C "$source_root" fetch --depth 1 origin "$revision"
  git -C "$source_root" checkout -q --detach FETCH_HEAD
fi
test "$(git -C "$source_root" rev-parse HEAD)" = "$revision"

installed_revision=$(sed -n '1p' "$revision_file" 2>/dev/null || true)
if [ ! -x "$tool" ] || [ "$installed_revision" != "$revision" ]; then
  test ! -e "$install_root" || {
    printf '%s\n' \
      "remove incomplete or mismatched managed install: $install_root" >&2
    exit 1
  }
  (
    cd "$source_root"
    alr -n install --prefix "$install_root"
  )
  printf '%s\n' "$revision" >"$revision_file"
fi

if ! "$tool" toolchain verify "$toolchain"; then
  "$tool" toolchain install "$toolchain"
fi
"$tool" toolchain verify "$toolchain"

printf '%s\n' \
  "flyology_tla_revision=$revision" \
  "tool=$tool" \
  "toolchain=$toolchain" \
  "work_root=$formal_build_root/work"
