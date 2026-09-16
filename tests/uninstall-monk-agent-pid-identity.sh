#!/usr/bin/env sh
# Regression coverage for ENG-674 (plugin#402): pid_matches_executable() used
# to hardcode `uname -s = Linux`, so on macOS (or any non-Linux OS) the
# identity check unconditionally failed and stop_agent() never actually
# killed the managed process via the PID-file path -- only the PID file
# itself was removed. Runs on both Linux and macOS (see install-e2e.yml) to
# prove the identity check now works on both.
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work_dir="$(mktemp -d)"
agent_pid=""
cleanup() {
  if [ -n "$agent_pid" ]; then
    kill "$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

install_dir="$work_dir/bin"
mkdir -p "$install_dir"
target="$install_dir/monk-agent"
# Copy a real long-running binary to the exact managed install path so
# pid_matches_executable can resolve identity against it the same way it
# would for the real monk-agent binary.
cp "$(command -v sleep)" "$target"
chmod +x "$target"

home_dir="$work_dir/home"
agent_home="$home_dir/.monk"
run_dir="$agent_home/agent/launcher/run"
mkdir -p "$run_dir"

"$target" 30 &
agent_pid=$!
printf '%s' "$agent_pid" >"$run_dir/monk-agent.pid"

HOME="$home_dir" \
MONK_AGENT_INSTALL_DIR="$install_dir" \
MONK_AGENT_HOME="$agent_home" \
  "$repo_root/scripts/uninstall-monk-agent.sh" -y --keep-data

if kill -0 "$agent_pid" 2>/dev/null; then
  echo "uninstaller did not stop the identity-matched monk-agent process" >&2
  exit 1
fi
agent_pid=""

echo "uninstall-monk-agent pid-identity test passed."
