#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
formal_build_root=$repository_root/build/formal-tla
tool=${FLYOLOGY_TLA_TOOL:-$formal_build_root/install/bin/flyology-tla}
toolchain=${FLYOLOGY_TLA_TOOLCHAIN:-$formal_build_root/toolchain}
work_root=${FLYOLOGY_TLA_WORK_ROOT:-$formal_build_root/work}
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

prepare_work_root()
{
  mkdir -p "$work_root"
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
  require_absolute_path FLYOLOGY_TLA_TOOL "$tool"
  require_absolute_path FLYOLOGY_TLA_TOOLCHAIN "$toolchain"
  require_absolute_path FLYOLOGY_TLA_WORK_ROOT "$work_root"
  require_file "$tool"
  require_file "$toolchain/receipt.json"
  require_file "$model"
  require_file "$configuration"
  require_directory "$work_root"

  case "$phase" in
    model)
      require_file "$fixed_configuration"
      require_file "$issue56_configuration"
      require_file "$issue57_configuration"
      require_file "$issue58_configuration"
      ;;
    verify-model-output)
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
      require_file "$raw_trace"
      require_directory "$trace_dir"
      ;;
    generate)
      require_directory "$generated_dir"
      require_directory "$generated_check"
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
      require_directory "$generated_check"
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
  prepare_work_root
  preflight model
  load_toolchain
  rm -rf -- "$model_work"
  mkdir -p "$model_work"

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
  prepare_work_root
  preflight proof
  load_toolchain
  rm -rf -- "$proof_work"
  mkdir -p "$proof_work/cache"

  "$FLYOLOGY_TLA_JAVA" -cp "$FLYOLOGY_TLA_TLC_JAR" tla2sany.SANY \
    "$proof" >"$proof_work/sany.log" 2>&1
  "$FLYOLOGY_TLAPM" --cache-dir "$proof_work/cache" --cleanfp --nofp \
    --strict --method smt "$proof" >"$proof_work/tlapm.log" 2>&1
  grep -Fq 'All 18 obligations proved.' "$proof_work/tlapm.log"
}

normalize()
{
  prepare_work_root
  preflight normalize
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
  prepare_work_root
  mkdir -p "$generated_check"
  preflight generate
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
  prepare_work_root
  preflight replay
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
