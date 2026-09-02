#!/usr/bin/env sh
# PostToolUse hook for MANIFEST/MonkScript edits.
# Runs monk-agent analyzer diagnostics after file edits and logs results to
# stderr. Antigravity PostToolUse stdout must be an empty JSON object — results
# cannot be injected back into the conversation from this event type.
#
# Antigravity PostToolUse I/O:
#   stdin:  {"stepIdx":N,"transcriptPath":"...","workspacePaths":[...],...}
#   stdout: {}
#
# All logic lives in `monk-agent hook diagnostics`, so this wrapper depends only
# on the binary the plugin already installs — no jq/curl/awk. Best-effort: if the
# binary is missing we still emit {} and exit 0 so the edit is never blocked.

set -eu

# On Windows the .ps1 sibling owns this hook. A host may spawn .sh hooks in an
# interactive git-bash window (e.g. Cursor on Windows) whose stdin is a TTY,
# where `cat` would block forever. Bow out on Windows-flavored bash, or whenever
# stdin is not a pipe, so we never hang and never double up with the .ps1. Still
# emit the required empty JSON object on stdout.
case "$(uname -s 2>/dev/null)" in MINGW* | MSYS* | CYGWIN*) printf '%s\n' "{}"; exit 0 ;; esac
if [ -t 0 ]; then printf '%s\n' "{}"; exit 0; fi

agent="${MONK_AGENT_PATH:-${MONK_AGENT_INSTALL_DIR:-"$HOME/.monk/bin"}/monk-agent}"
if [ ! -x "$agent" ]; then
  printf '%s\n' "{}"
  exit 0
fi

# A wedged (not merely failing) helper must not block the edit indefinitely:
# background it under a watchdog that TERMs then KILLs it after
# MONK_AGENT_HOOK_TIMEOUT_MS (default 10s) rather than only the host's own
# external kill saving us. The handler prints diagnostics to stderr and the
# required {} to stdout; timeout/failure still needs the required {} on stdout.
timeout_ms="${MONK_AGENT_HOOK_TIMEOUT_MS:-10000}"
timeout_s=$(((timeout_ms + 999) / 1000))
cat | "$agent" hook diagnostics --format antigravity &
helper_pid=$!
(sleep "$timeout_s"; kill -TERM "$helper_pid" 2>/dev/null; sleep 1; kill -KILL "$helper_pid" 2>/dev/null) &
watchdog_pid=$!
if ! wait "$helper_pid" 2>/dev/null; then
  printf '%s\n' "{}"
fi
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

exit 0
