#!/usr/bin/env sh
# Regression coverage for ENG-712 (plugin#413): a wedged install lock must not
# block ensure-monk-agent.sh forever, and a lock released before the deadline
# must still let the installer proceed.
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work_dir="$(mktemp -d)"
holder_pid=""

cleanup() {
  if [ -n "$holder_pid" ]; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

# auto_update=0 with a pre-populated executable target short-circuits
# ensure-monk-agent.sh right after the lock section (no network needed), which
# keeps this fixture focused on lock behavior alone.
install_dir="$work_dir/install"
mkdir -p "$install_dir"
target="$install_dir/monk-agent"
printf '#!/bin/sh\ntrue\n' >"$target"
chmod +x "$target"
lock_file="$install_dir/.monk-agent.lock"
out_file="$work_dir/ensure-out"

run_ensure() {
  timeout_s="$1"
  MONK_AGENT_INSTALL_DIR="$install_dir" \
  MONK_AGENT_AUTO_UPDATE=0 \
  MONK_AGENT_INSTALL_LOCK_TIMEOUT="$timeout_s" \
    "$repo_root/scripts/ensure-monk-agent.sh"
}

wait_for_lock_held() {
  waited=0
  while flock -n "$lock_file" true 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -ge 50 ]; then
      echo "lock holder never acquired $lock_file" >&2
      exit 1
    fi
    sleep 0.1
  done
}

# Case 1: a lock held for longer than the deadline must time out with a
# non-zero exit, not hang forever.
(
  exec 9>"$lock_file"
  flock 9
  sleep 30
) &
holder_pid=$!
wait_for_lock_held

start_s=$(date +%s)
if run_ensure 1 >"$out_file" 2>&1; then
  echo "expected ensure-monk-agent.sh to time out while the lock is held" >&2
  cat "$out_file" >&2
  exit 1
fi
elapsed=$(($(date +%s) - start_s))
if [ "$elapsed" -gt 10 ]; then
  echo "ensure-monk-agent.sh took ${elapsed}s to time out on a 1s deadline" >&2
  cat "$out_file" >&2
  exit 1
fi
if ! grep -q "Timed out after 1s waiting for another monk-agent install" "$out_file"; then
  echo "missing timeout diagnostic" >&2
  cat "$out_file" >&2
  exit 1
fi

kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
holder_pid=""

# Case 2: a lock released before the deadline must let the installer recover
# and return the already-installed binary.
(
  exec 9>"$lock_file"
  flock 9
  sleep 1
) &
holder_pid=$!
wait_for_lock_held

installed="$(run_ensure 10)"
wait "$holder_pid" 2>/dev/null || true
holder_pid=""
if [ "$installed" != "$target" ]; then
  echo "expected ensure-monk-agent.sh to recover and print $target, got: $installed" >&2
  exit 1
fi

echo "ensure-monk-agent lock-timeout tests passed."
