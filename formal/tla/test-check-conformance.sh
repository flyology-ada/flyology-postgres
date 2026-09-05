#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
test_root=$repository_root/build/formal-tla-runner-test
fixture=$test_root/fixture
runner_log=$test_root/runner.log

cleanup()
{
  rm -rf -- "$test_root"
}

trap cleanup EXIT HUP INT TERM
cleanup

mkdir -p \
  "$fixture/formal/tla/traces" \
  "$fixture/proof" \
  "$fixture/support/toolchain" \
  "$fixture/tests/bin" \
  "$fixture/tests/generated/tla"
cp "$script_dir/check-conformance.sh" "$fixture/formal/tla/"
: >"$fixture/formal/tla/PgoutputProducer.tla"
: >"$fixture/formal/tla/PgoutputProducerProof.tla"
: >"$fixture/formal/tla/PgoutputProducer_Replay.cfg"
: >"$fixture/formal/tla/traces/pgoutput_producer.trace.json"
: >"$fixture/support/toolchain/receipt.json"
printf '%s\n' keep >"$fixture/proof/keep"

cat >"$fixture/support/flyology-tla" <<'EOF'
#!/bin/sh
set -eu

if [ "$1" = toolchain ] && [ "$2" = env ]; then
  printf '%s\n' \
    "FLYOLOGY_TLA_JAVA='/bin/true'" \
    "FLYOLOGY_TLA_TLC_JAR='/dev/null'" \
    "FLYOLOGY_TLAPM='/bin/true'"
  exit 0
fi

if [ "$1" = ada ] && [ "$2" = generate ]; then
  shift 2
  output=
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then
      output=$2
      shift 2
    else
      shift
    fi
  done
  test -d "$output"
  for generated_file in \
    pgoutput_producer_model.ads \
    pgoutput_producer_model.adb \
    pgoutput_producer_model.inference.json
  do
    printf '%s\n' generated >"$output/$generated_file"
  done
  exit 0
fi

exit 1
EOF
chmod +x "$fixture/support/flyology-tla"

for generated_file in \
  pgoutput_producer_model.ads \
  pgoutput_producer_model.adb \
  pgoutput_producer_model.inference.json
do
  printf '%s\n' generated >"$fixture/tests/generated/tla/$generated_file"
done

cat >"$fixture/tests/bin/flyology-postgres-replication-logical-producer-conformance" <<'EOF'
#!/bin/sh
printf '%s\n' 'conformant: 19 modeled steps'
EOF
chmod +x "$fixture/tests/bin/flyology-postgres-replication-logical-producer-conformance"

printf '%s\n' '/build/' >"$fixture/.gitignore"
git -C "$fixture" init -q
git -C "$fixture" config user.email formal-runner-test@example.invalid
git -C "$fixture" config user.name 'Formal runner test'
git -C "$fixture" add .
git -C "$fixture" commit -qm 'fixture'
mkdir "$fixture/build"

FLYOLOGY_TLA_TOOL=$fixture/support/flyology-tla \
FLYOLOGY_TLA_TOOLCHAIN=$fixture/support/toolchain \
FLYOLOGY_TLA_WORK_ROOT=$fixture/build/formal-tla \
  "$fixture/formal/tla/check-conformance.sh" replay >"$runner_log"

FLYOLOGY_TLA_TOOL=$fixture/support/flyology-tla \
FLYOLOGY_TLA_TOOLCHAIN=$fixture/support/toolchain \
FLYOLOGY_TLA_WORK_ROOT=$fixture/build/formal-tla \
  "$fixture/formal/tla/check-conformance.sh" generate >>"$runner_log"

grep -Fxq "tool=$fixture/support/flyology-tla" "$runner_log"
grep -Fxq "toolchain=$fixture/support/toolchain" "$runner_log"
grep -Fxq "work_root=$fixture/build/formal-tla" "$runner_log"
grep -Fxq 'conformant: 19 modeled steps' \
  "$fixture/build/formal-tla/replay.log"
test -f \
  "$fixture/build/formal-tla/generated-check/pgoutput_producer_model.adb"
test ! -e "$fixture/.tool-probes"

expect_rejected()
{
  rejected_root=$1
  rejected_log=$2
  set +e
  (
    cd "$fixture"
    FLYOLOGY_TLA_TOOL=$fixture/support/flyology-tla \
    FLYOLOGY_TLA_TOOLCHAIN=$fixture/support/toolchain \
    FLYOLOGY_TLA_WORK_ROOT=$rejected_root \
      "$fixture/formal/tla/check-conformance.sh" proof
  ) >"$rejected_log" 2>&1
  rejected_status=$?
  set -e
  test "$rejected_status" -ne 0
}

expect_rejected relative-work "$test_root/relative.log"
test ! -e "$fixture/relative-work"

expect_rejected "$fixture" "$test_root/repository-root.log"
grep -Fxq keep "$fixture/proof/keep"

mkdir -p "$test_root/unmanaged/proof"
printf '%s\n' keep >"$test_root/unmanaged/proof/keep"
expect_rejected "$test_root/unmanaged" "$test_root/unmanaged.log"
grep -Fxq keep "$test_root/unmanaged/proof/keep"

mkdir "$test_root/outside"
ln -s "$test_root/outside" "$test_root/link"
expect_rejected "$test_root/link/work" "$test_root/symlink.log"
test ! -e "$test_root/outside/work"

rm -rf -- "$fixture/build/formal-tla/proof"
ln -s "$test_root/outside" "$fixture/build/formal-tla/proof"
expect_rejected \
  "$fixture/build/formal-tla" "$test_root/owned-child-symlink.log"
test ! -e "$test_root/outside/cache"

test -f \
  "$fixture/build/formal-tla/.flyology-postgres-conformance-work-root"
test -z "$(git -C "$fixture" status --porcelain=v1)"
