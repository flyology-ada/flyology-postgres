#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tests_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
run_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-durable-store.XXXXXX")
waiting_pid=

cleanup () {
  status=$?
  if [ -n "$waiting_pid" ]; then
    kill -9 "$waiting_pid" >/dev/null 2>&1 || true
    wait "$waiting_pid" >/dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ]; then
    for log in "$run_root"/*.log; do
      if [ -f "$log" ]; then
        printf '%s\n' "$(basename "$log"):" >&2
        cat "$log" >&2
      fi
    done
  fi
  rm -rf -- "$run_root"
}
trap cleanup EXIT HUP INT TERM

run_action () {
  action=$1
  POSTGRES_DURABLE_STORE_DIR="$run_root/store" \
  POSTGRES_DURABLE_STORE_ACTION=$action \
    "$tests_root/bin/postgres_test_durable_store"
}

POSTGRES_DURABLE_STORE_DIR="$run_root/conformance" \
POSTGRES_DURABLE_STORE_ACTION=conformance \
  "$tests_root/bin/postgres_test_durable_store"

start_waiting_action () {
  action=$1
  marker=$2
  log="$run_root/$action.log"
  POSTGRES_DURABLE_STORE_DIR="$run_root/store" \
  POSTGRES_DURABLE_STORE_ACTION=$action \
    "$tests_root/bin/postgres_test_durable_store" >"$log" 2>&1 &
  waiting_pid=$!
  attempt=0
  until grep -q "^$marker$" "$log"; do
    attempt=$((attempt + 1))
    if ! kill -0 "$waiting_pid" >/dev/null 2>&1; then
      cat "$log" >&2
      printf '%s\n' "$action exited before its durable marker" >&2
      return 1
    fi
    if [ "$attempt" -ge 100 ]; then
      cat "$log" >&2
      printf '%s\n' "$action did not reach its durable marker" >&2
      return 1
    fi
    sleep 0.05
  done
}

kill_waiting_action () {
  kill -9 "$waiting_pid"
  wait "$waiting_pid" >/dev/null 2>&1 || true
  waiting_pid=
}

run_action initialize
start_waiting_action advance-and-wait durable-before-crash
kill_waiting_action
run_action verify-and-acknowledge

start_waiting_action inject-torn-and-wait torn-tail-durable
kill_waiting_action
run_action verify-repair

start_waiting_action hold-lock lock-held
if run_action open-and-close >"$run_root/contender.log" 2>&1; then
  printf '%s\n' "second durable-store writer unexpectedly acquired the lock" >&2
  exit 1
fi
if ! grep -q 'durable store is locked by another process' \
  "$run_root/contender.log"
then
  cat "$run_root/contender.log" >&2
  printf '%s\n' "lock contender failed for an unexpected reason" >&2
  exit 1
fi
kill_waiting_action

printf '%s\n' "crash-durable replication store integration passed"
