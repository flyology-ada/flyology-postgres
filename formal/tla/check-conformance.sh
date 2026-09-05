#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
formal_build_root=$repository_root/build/formal-tla
managed_tool=$formal_build_root/install/bin/flyology-tla
managed_toolchain_helper=$formal_build_root/install/share/toolchain.sh
managed_provisioning_receipt=$formal_build_root/install/flyology-tla-provisioning
tool=${FLYOLOGY_TLA_TOOL:-$managed_tool}
toolchain=${FLYOLOGY_TLA_TOOLCHAIN:-$formal_build_root/toolchain}
work_root=${FLYOLOGY_TLA_WORK_ROOT:-$formal_build_root/work}
work_root_marker=$work_root/.flyology-postgres-conformance-work-root
work_root_identity='flyology-postgres formal conformance work root v1'
model=$repository_root/formal/tla/PgoutputProducer.tla
configuration=$repository_root/formal/tla/PgoutputProducer_Replay.cfg
fixed_configuration=$repository_root/formal/tla/PgoutputProducer.cfg
issue56_configuration=$repository_root/formal/tla/PgoutputProducer_56_broken.cfg
issue57_configuration=$repository_root/formal/tla/PgoutputProducer_57_broken.cfg
issue58_configuration=$repository_root/formal/tla/PgoutputProducer_58_broken.cfg
proof=$repository_root/formal/tla/PgoutputProducerProof.tla
model_work=$work_root/model
proof_work=$work_root/proof
raw_trace=$model_work/replay-raw.json
trace_dir=$repository_root/formal/tla/traces
trace=$trace_dir/pgoutput_producer.trace.json
generated_dir=$repository_root/tests/generated/tla
generated_check=$work_root/generated-check
normalized_check=$work_root/pgoutput_producer.trace.json
replay=$repository_root/tests/bin/flyology-postgres-replication-logical-producer-conformance

maximum_steps=32
maximum_json_depth=64
toolchain_id=tla2tools-1.8.0+b123b22

usage()
{
  printf '%s\n' \
    'usage: check-conformance.sh [preflight [model|verify-model-output|proof|normalize|generate|replay|all]|model|verify-model-output|proof|normalize|generate|replay|all]' >&2
  exit 2
}

require_file()
{
  test -f "$1" || {
    printf '%s\n' "missing required file: $1" >&2
    exit 1
  }
}

require_directory()
{
  test -d "$1" || {
    printf '%s\n' "missing required directory: $1" >&2
    exit 1
  }
}

require_absolute_path()
{
  case "$2" in
    /*) ;;
    *)
      printf '%s\n' "$1 must be an absolute path: $2" >&2
      exit 1
      ;;
  esac
}

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

verify_managed_tool_install()
{
  test "$tool" = "$managed_tool" || return 0
  test -f "$managed_tool" && test ! -L "$managed_tool" ||
    fail "missing managed flyology-tla executable: $managed_tool"
  test -f "$managed_toolchain_helper" &&
    test ! -L "$managed_toolchain_helper" ||
    fail "missing managed toolchain helper: $managed_toolchain_helper"
  test -f "$managed_provisioning_receipt" &&
    test ! -L "$managed_provisioning_receipt" ||
    fail "missing managed provisioning receipt: $managed_provisioning_receipt"
  test "$(sed -n '1p' "$managed_provisioning_receipt")" = \
    'format=flyology-postgres-formal-provisioning/2' ||
    fail "invalid managed provisioning receipt: $managed_provisioning_receipt"
  expected_tool_sha256=$(sed -n '4s/^tool_sha256=//p' \
    "$managed_provisioning_receipt")
  expected_helper_sha256=$(sed -n \
    '5s/^toolchain_helper_sha256=//p' "$managed_provisioning_receipt")
  test "$expected_tool_sha256" = "$(sha256_file "$managed_tool")" ||
    fail 'managed flyology-tla executable fails content verification'
  test "$expected_helper_sha256" = \
    "$(sha256_file "$managed_toolchain_helper")" ||
    fail 'managed toolchain helper fails content verification'
  test "$(wc -l <"$managed_provisioning_receipt" | tr -d ' ')" -eq 5 ||
    fail "invalid managed provisioning receipt: $managed_provisioning_receipt"
}

validate_work_root_path()
{
  require_absolute_path FLYOLOGY_TLA_WORK_ROOT "$work_root"
  case "$work_root" in
    /|*/|*//*|*/./*|*/../*|*/.|*/..)
      fail "FLYOLOGY_TLA_WORK_ROOT is not a canonical dedicated path: $work_root"
      ;;
  esac
  case "$work_root" in
    *'
'*) fail 'FLYOLOGY_TLA_WORK_ROOT must not contain a line break' ;;
  esac
  test "$work_root" != "$repository_root" ||
    fail 'FLYOLOGY_TLA_WORK_ROOT must not be the repository root'

  path_component=$work_root
  while [ "$path_component" != / ]; do
    test ! -L "$path_component" ||
      fail "FLYOLOGY_TLA_WORK_ROOT crosses a symbolic link: $path_component"
    path_component=${path_component%/*}
    test -n "$path_component" || path_component=/
  done

  work_parent=${work_root%/*}
  test -n "$work_parent" || work_parent=/
  test "$work_parent" != / ||
    fail 'FLYOLOGY_TLA_WORK_ROOT must not be a direct child of /'
  require_directory "$work_parent"
}

require_owned_work_root()
{
  validate_work_root_path
  require_directory "$work_root"
  test ! -L "$work_root_marker" ||
    fail "work-root ownership marker is a symbolic link: $work_root_marker"
  require_file "$work_root_marker"
  test "$(cat "$work_root_marker")" = "$work_root_identity" ||
    fail "work root is not owned by this runner: $work_root"
}

prepare_work_root()
{
  validate_work_root_path
  if [ -e "$work_root" ] || [ -L "$work_root" ]; then
    require_owned_work_root
  else
    mkdir "$work_root"
    printf '%s\n' "$work_root_identity" >"$work_root_marker"
    require_owned_work_root
  fi
}

require_contained_work_path()
{
  case "$1" in
    "$work_root"/*) ;;
    *) fail "work path escapes the owned root: $1" ;;
  esac
}

prepare_empty_work_directory()
{
  require_owned_work_root
  require_contained_work_path "$1"
  test ! -L "$1" || fail "refusing symbolic-link work directory: $1"
  rm -rf -- "$1"
  mkdir "$1"
}

require_safe_work_file()
{
  require_owned_work_root
  require_contained_work_path "$1"
  test ! -L "$1" || fail "refusing symbolic-link work file: $1"
}

print_paths()
{
  printf '%s\n' \
    "phase=$1" \
    "repository_root=$repository_root" \
    "tool=$tool" \
    "toolchain=$toolchain" \
    "model=$model" \
    "configuration=$configuration" \
    "proof=$proof" \
    "raw_trace=$raw_trace" \
    "trace=$trace" \
    "generated_dir=$generated_dir" \
    "replay=$replay" \
    "work_root=$work_root"
}

preflight()
{
  phase=$1
  print_paths "$phase"
  test "${FLYOLOGY_TLA_TOOLCHAIN_SCRIPT+x}" != x ||
    fail 'FLYOLOGY_TLA_TOOLCHAIN_SCRIPT is not accepted by the runner'
  require_absolute_path FLYOLOGY_TLA_TOOL "$tool"
  require_absolute_path FLYOLOGY_TLA_TOOLCHAIN "$toolchain"
  require_file "$tool"
  require_file "$toolchain/receipt.json"
  require_file "$model"
  require_file "$configuration"
  validate_work_root_path
  verify_managed_tool_install

  case "$phase" in
    model)
      require_file "$fixed_configuration"
      require_file "$issue56_configuration"
      require_file "$issue57_configuration"
      require_file "$issue58_configuration"
      ;;
    verify-model-output)
      require_owned_work_root
      require_file "$model_work/fixed.log"
      require_file "$model_work/issue56.log"
      require_file "$model_work/issue57.log"
      require_file "$model_work/issue58.log"
      require_file "$model_work/replay.log"
      require_file "$raw_trace"
      ;;
    proof)
      require_file "$proof"
      ;;
    normalize)
      require_owned_work_root
      require_file "$raw_trace"
      require_directory "$trace_dir"
      ;;
    generate)
      require_directory "$generated_dir"
      ;;
    replay)
      require_file "$trace"
      require_file "$replay"
      ;;
    all)
      require_file "$fixed_configuration"
      require_file "$issue56_configuration"
      require_file "$issue57_configuration"
      require_file "$issue58_configuration"
      require_file "$proof"
      require_directory "$trace_dir"
      require_directory "$generated_dir"
      require_file "$replay"
      ;;
    *) usage ;;
  esac
}

load_toolchain()
{
  eval "$("$tool" toolchain env "$toolchain")"
}

run_tlc()
{
  configuration_file=$1
  metadir=$2
  logfile=$3
  shift 3
  (
    cd "$script_dir"
    "$FLYOLOGY_TLA_JAVA" -Xmx1g -XX:+UseParallelGC \
      -cp "$FLYOLOGY_TLA_TLC_JAR" tlc2.TLC \
      -workers 1 -coverage 1 -noGenerateSpecTE \
      -metadir "$metadir" -config "$configuration_file" "$@" \
      PgoutputProducer
  ) >"$logfile" 2>&1
}

run_expected_tlc_failure()
{
  configuration_file=$1
  invariant=$2
  stem=$3
  set +e
  run_tlc "$configuration_file" "$model_work/$stem-states" \
    "$model_work/$stem.log" \
    -dumpTrace json "$model_work/$stem-raw.json"
  status=$?
  set -e
  test "$status" -eq 12
  grep -Fq "Invariant $invariant is violated." "$model_work/$stem.log"
  ! grep -q '^Warning:' "$model_work/$stem.log"
}

model_check()
{
  preflight model
  prepare_work_root
  load_toolchain
  prepare_empty_work_directory "$model_work"

  "$FLYOLOGY_TLA_JAVA" -cp "$FLYOLOGY_TLA_TLC_JAR" tla2sany.SANY \
    "$model" >"$model_work/sany.log" 2>&1
  run_tlc "$fixed_configuration" "$model_work/fixed-states" \
    "$model_work/fixed.log"
  grep -Fq '0 states left on queue.' "$model_work/fixed.log"
  ! grep -q '^Warning:' "$model_work/fixed.log"

  run_expected_tlc_failure \
    "$issue56_configuration" SegmentPrefixSafe issue56
  run_expected_tlc_failure \
    "$issue57_configuration" SubabortPreservesTop issue57
  run_expected_tlc_failure \
    "$issue58_configuration" RelevantOutcomeSafe issue58
  run_expected_tlc_failure "$configuration" WitnessPending replay

  verify_model_output
}

verify_model_output()
{
  preflight verify-model-output
  grep -Fq \
    '40964 states generated, 1781 distinct states found, 0 states left on queue.' \
    "$model_work/fixed.log"
  grep -Fq 'The depth of the complete state graph search is 13.' \
    "$model_work/fixed.log"
  grep -Fq 'Invariant SegmentPrefixSafe is violated.' \
    "$model_work/issue56.log"
  grep -Fq 'Invariant SubabortPreservesTop is violated.' \
    "$model_work/issue57.log"
  grep -Fq 'Invariant RelevantOutcomeSafe is violated.' \
    "$model_work/issue58.log"
  grep -Fq 'Invariant WitnessPending is violated.' "$model_work/replay.log"
  for logfile in fixed issue56 issue57 issue58 replay
  do
    grep -Fq '0 states left on queue.' "$model_work/$logfile.log"
    ! grep -q '^Warning:' "$model_work/$logfile.log"
  done
  for action in \
    BeginRegular CommitRegular StartStream StopStream \
    CommitStream AbortStream Data LogicalMessage
  do
    grep -Fq "\"action\":\"$action\"" "$raw_trace"
  done
}

prove()
{
  preflight proof
  prepare_work_root
  load_toolchain
  prepare_empty_work_directory "$proof_work"
  mkdir "$proof_work/cache"

  "$FLYOLOGY_TLA_JAVA" -cp "$FLYOLOGY_TLA_TLC_JAR" tla2sany.SANY \
    "$proof" >"$proof_work/sany.log" 2>&1
  "$FLYOLOGY_TLAPM" --cache-dir "$proof_work/cache" --cleanfp --nofp \
    --strict --method smt "$proof" >"$proof_work/tlapm.log" 2>&1
  grep -Fq 'All 18 obligations proved.' "$proof_work/tlapm.log"
}

normalize()
{
  preflight normalize
  prepare_work_root
  require_safe_work_file "$normalized_check"
  load_toolchain
  "$tool" trace normalize \
    "$raw_trace" "$trace" "$model" --config "$configuration" \
    --toolchain "$toolchain_id" "$maximum_steps" "$maximum_json_depth"
  "$tool" trace normalize \
    "$raw_trace" "$normalized_check" "$model" --config "$configuration" \
    --toolchain "$toolchain_id" "$maximum_steps" "$maximum_json_depth"
  "$tool" trace validate "$trace" "$maximum_steps" "$maximum_json_depth"
  cmp "$trace" "$normalized_check"
}

generate()
{
  preflight generate
  prepare_work_root
  prepare_empty_work_directory "$generated_check"
  load_toolchain
  "$tool" ada generate "$model" --config "$configuration" \
    --package Pgoutput_Producer_Model --output "$generated_dir"
  "$tool" ada generate "$model" --config "$configuration" \
    --package Pgoutput_Producer_Model --output "$generated_check"

  test "$(find "$generated_dir" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 3
  test "$(find "$generated_check" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 3
  for generated_file in \
    pgoutput_producer_model.ads \
    pgoutput_producer_model.adb \
    pgoutput_producer_model.inference.json
  do
    require_file "$generated_dir/$generated_file"
    require_file "$generated_check/$generated_file"
    cmp "$generated_dir/$generated_file" "$generated_check/$generated_file"
  done
}

replay_trace()
{
  preflight replay
  prepare_work_root
  require_safe_work_file "$work_root/replay.log"
  "$replay" "$trace" >"$work_root/replay.log"
  grep -Fxq 'conformant: 19 modeled steps' "$work_root/replay.log"
}

if [ "$#" -eq 0 ]; then
  set -- all
fi

command=$1
case "$command" in
  preflight)
    preflight "${2:-all}"
    ;;
  model)
    test "$#" -eq 1 || usage
    model_check
    ;;
  verify-model-output)
    test "$#" -eq 1 || usage
    verify_model_output
    ;;
  proof)
    test "$#" -eq 1 || usage
    prove
    ;;
  normalize)
    test "$#" -eq 1 || usage
    normalize
    ;;
  generate)
    test "$#" -eq 1 || usage
    generate
    ;;
  replay)
    test "$#" -eq 1 || usage
    replay_trace
    ;;
  all)
    test "$#" -eq 1 || usage
    model_check
    prove
    normalize
    generate
    replay_trace
    ;;
  *) usage ;;
esac
