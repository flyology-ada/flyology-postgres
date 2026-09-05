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
toolchain_helper=$install_root/share/toolchain.sh
toolchain=$formal_build_root/toolchain
provisioning_receipt=$install_root/flyology-tla-provisioning
source_marker=$source_root/.git/flyology-postgres-provisioning
source_created=0

fail()
{
  printf '%s\n' "$1" >&2
  exit 1
}

sha256_file()
{
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail 'sha256sum or shasum is required'
  fi
}

cleanup_source()
{
  if [ "$source_created" -eq 1 ]; then
    test -d "$source_root/.git" && test ! -L "$source_root" &&
      test ! -L "$source_marker" &&
      test "$(cat "$source_marker" 2>/dev/null || true)" = "$revision" || {
        printf '%s\n' \
          "refusing to remove unowned provisioning source: $source_root" >&2
        return 1
      }
    rm -rf -- "$source_root"
    source_created=0
  fi
}

trap cleanup_source EXIT HUP INT TERM

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

test "${FLYOLOGY_TLA_TOOLCHAIN_SCRIPT+x}" != x ||
  fail 'FLYOLOGY_TLA_TOOLCHAIN_SCRIPT is not accepted by the provisioner'

test ! -L "$repository_root/build" ||
  fail "refusing symbolic-link build root: $repository_root/build"
mkdir -p "$formal_build_root"
test ! -L "$formal_build_root" ||
  fail "refusing symbolic-link formal build root: $formal_build_root"
test ! -e "$source_root" && test ! -L "$source_root" ||
  fail "refusing reused provisioning source: $source_root"

if [ -e "$install_root" ] || [ -L "$install_root" ]; then
  test -d "$install_root" && test ! -L "$install_root" ||
    fail "invalid managed install path: $install_root"
  test -x "$tool" && test ! -L "$tool" ||
    fail "missing managed flyology-tla executable: $tool"
  test -f "$toolchain_helper" && test ! -L "$toolchain_helper" ||
    fail "missing managed toolchain helper: $toolchain_helper"
  test -f "$provisioning_receipt" && test ! -L "$provisioning_receipt" ||
    fail "missing managed provisioning receipt: $provisioning_receipt"
  tool_sha256=$(sha256_file "$tool")
  toolchain_helper_sha256=$(sha256_file "$toolchain_helper")
  receipt_format=$(sed -n '1s/^format=//p' "$provisioning_receipt")
  receipt_revision=$(sed -n '2s/^revision=//p' "$provisioning_receipt")
  receipt_source_tree=$(sed -n '3s/^source_tree=//p' \
    "$provisioning_receipt")
  receipt_tool_sha256=$(sed -n '4s/^tool_sha256=//p' \
    "$provisioning_receipt")
  receipt_toolchain_helper_sha256=$(sed -n \
    '5s/^toolchain_helper_sha256=//p' "$provisioning_receipt")
  test "$receipt_format" = 'flyology-postgres-formal-provisioning/2' ||
    fail "invalid managed provisioning receipt: $provisioning_receipt"
  test "$receipt_revision" = "$revision" ||
    fail "managed install revision does not match $revision"
  case "$receipt_source_tree" in
    ''|*[!0-9a-f]*)
      fail "invalid managed source tree receipt: $provisioning_receipt"
      ;;
  esac
  test "${#receipt_source_tree}" -eq 40 ||
    fail "invalid managed source tree receipt: $provisioning_receipt"
  test "$receipt_tool_sha256" = "$tool_sha256" ||
    fail "managed flyology-tla executable fails content verification"
  test "$receipt_toolchain_helper_sha256" = \
    "$toolchain_helper_sha256" ||
    fail "managed toolchain helper fails content verification"
  test "$(wc -l <"$provisioning_receipt" | tr -d ' ')" -eq 5 ||
    fail "invalid managed provisioning receipt: $provisioning_receipt"
else
  mkdir "$source_root"
  source_created=1
  git -C "$source_root" init -q
  printf '%s\n' "$revision" >"$source_marker"
  git -C "$source_root" remote add origin "$source_repository"
  git -C "$source_root" fetch --depth 1 origin "$revision"
  git -C "$source_root" checkout -q --detach FETCH_HEAD
  test "$(git -C "$source_root" remote get-url origin)" = \
    "$source_repository"
  test "$(git -C "$source_root" rev-parse HEAD)" = "$revision"
  source_tree=$(git -C "$source_root" rev-parse 'HEAD^{tree}')
  test "$(git -C "$source_root" write-tree)" = "$source_tree"
  git -C "$source_root" diff --quiet
  git -C "$source_root" diff --cached --quiet
  test -z "$(git -C "$source_root" status --porcelain=v1 \
    --untracked-files=all)" ||
    fail "fresh provisioning source is not pristine: $source_root"
  test -z "$(git -C "$source_root" status --porcelain=v1 --ignored \
    --untracked-files=all)" ||
    fail "fresh provisioning source contains ignored artifacts: $source_root"

  (
    cd "$source_root"
    alr -n install --prefix "$install_root"
  )
  test -x "$tool" && test ! -L "$tool" ||
    fail "installation did not produce a regular executable: $tool"
  test -f "$toolchain_helper" && test ! -L "$toolchain_helper" ||
    fail "installation did not produce a regular toolchain helper: $toolchain_helper"
  tool_sha256=$(sha256_file "$tool")
  toolchain_helper_sha256=$(sha256_file "$toolchain_helper")
  printf '%s\n' \
    'format=flyology-postgres-formal-provisioning/2' \
    "revision=$revision" \
    "source_tree=$source_tree" \
    "tool_sha256=$tool_sha256" \
    "toolchain_helper_sha256=$toolchain_helper_sha256" \
    >"$provisioning_receipt"
  cleanup_source
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
