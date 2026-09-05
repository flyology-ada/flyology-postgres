#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
test_root=$repository_root/build/formal-tla-provisioner-test
upstream=$test_root/upstream
fake_bin=$test_root/fake-bin

sha256_file()
{
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

cleanup()
{
  rm -rf -- "$test_root"
}

trap cleanup EXIT HUP INT TERM
cleanup

mkdir -p "$upstream" "$fake_bin"
git -C "$upstream" init -q
git -C "$upstream" config user.email formal-provisioner-test@example.invalid
git -C "$upstream" config user.name 'Formal provisioner test'
printf '%s\n' '/ignored-cache/' >"$upstream/.gitignore"
printf '%s\n' 'name = "flyology_tla"' >"$upstream/alire.toml"
git -C "$upstream" add .
git -C "$upstream" commit -qm 'fixture'
revision=$(git -C "$upstream" rev-parse HEAD)

cat >"$fake_bin/alr" <<'EOF'
#!/bin/sh
set -eu

prefix=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --prefix ]; then
    prefix=$2
    shift 2
  else
    shift
  fi
done
test -n "$prefix"
mkdir -p "$prefix/bin"
cat >"$prefix/bin/flyology-tla" <<'TOOL'
#!/bin/sh
set -eu

if [ "$1" = toolchain ] && [ "$2" = verify ]; then
  test -f "$3/receipt.json"
elif [ "$1" = toolchain ] && [ "$2" = install ]; then
  mkdir -p "$3"
  printf '%s\n' verified >"$3/receipt.json"
else
  exit 1
fi
TOOL
chmod +x "$prefix/bin/flyology-tla"
EOF
chmod +x "$fake_bin/alr"

create_fixture()
{
  fixture_root=$1
  mkdir -p "$fixture_root/formal/tla" "$fixture_root/tests"
  sed "s|^source_repository=.*|source_repository='$upstream'|" \
    "$script_dir/provision-conformance.sh" \
    >"$fixture_root/formal/tla/provision-conformance.sh"
  chmod +x "$fixture_root/formal/tla/provision-conformance.sh"
  printf '%s\n' \
    '[[pins]]' \
    "flyology_tla = { url = \"https://github.com/flyology-ada/tla.git\", commit = \"$revision\" }" \
    >"$fixture_root/tests/alire.toml"
}

expect_rejected()
{
  fixture_root=$1
  rejected_log=$2
  set +e
  PATH=$fake_bin:$PATH \
    "$fixture_root/formal/tla/provision-conformance.sh" \
    >"$rejected_log" 2>&1
  rejected_status=$?
  set -e
  test "$rejected_status" -ne 0
}

positive=$test_root/positive
create_fixture "$positive"
PATH=$fake_bin:$PATH "$positive/formal/tla/provision-conformance.sh"
test ! -e "$positive/build/formal-tla/source"
receipt=$positive/build/formal-tla/install/flyology-tla-provisioning
grep -Fxq "revision=$revision" "$receipt"
tool=$positive/build/formal-tla/install/bin/flyology-tla
expected_tool_sha256=$(sha256_file "$tool")
grep -Fxq "tool_sha256=$expected_tool_sha256" "$receipt"
PATH=$fake_bin:$PATH "$positive/formal/tla/provision-conformance.sh"

printf '%s\n' tampered >>"$tool"
expect_rejected "$positive" "$test_root/tampered-install.log"
test ! -e "$positive/build/formal-tla/source"

dirty=$test_root/dirty
create_fixture "$dirty"
mkdir -p "$dirty/build/formal-tla"
git clone -q "$upstream" "$dirty/build/formal-tla/source"
printf '%s\n' modified >>"$dirty/build/formal-tla/source/alire.toml"
mkdir "$dirty/build/formal-tla/source/ignored-cache"
printf '%s\n' stale >"$dirty/build/formal-tla/source/ignored-cache/artifact"
expect_rejected "$dirty" "$test_root/dirty-source.log"
grep -Fq modified "$dirty/build/formal-tla/source/alire.toml"
grep -Fxq stale \
  "$dirty/build/formal-tla/source/ignored-cache/artifact"
test ! -e "$dirty/build/formal-tla/install"
