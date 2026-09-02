# PostToolUse hook for MANIFEST/MonkScript edits.
# Asks local monk-agent for analyzer diagnostics and feeds concise results back
# into the agent after template edits.
#
# All logic (path resolution, workspace discovery, the MCP call, and formatting)
# lives in `monk-agent hook diagnostics`, so this wrapper depends only on the
# binary the plugin already installs. Best-effort: a missing binary, missing
# agent, auth issues, or unavailable analyzer support must never block the
# user's edit, so we always exit 0.
#
# -Format selects the output shape: "claude" (default, also used by Cursor) emits
# a superset of fields; "codex" emits ONLY the documented PostToolUse fields,
# because Codex silently drops hook output that carries any unrecognized top-level
# key (see diagnosticsResponseJson in src/hooks/cli.ts). The Codex hook passes
# `-Format codex`; Claude/Cursor leave the default.
param([ValidateSet('claude', 'codex')][string]$Format = 'claude')

# On non-Windows the .sh sibling handles this; bow out to avoid emitting the same
# diagnostics twice. On Windows the .ps1 owns it: a host may spawn the .sh in an
# interactive git-bash window whose stdin is a TTY (e.g. Cursor), where the .sh
# can't read the payload - so the .sh bows out on Windows and the .ps1 does the
# work here.
if ($env:OS -ne 'Windows_NT' -and (Get-Command bash -ErrorAction SilentlyContinue)) { exit 0 }

$agentDir = if ($env:MONK_AGENT_INSTALL_DIR) { $env:MONK_AGENT_INSTALL_DIR } else { Join-Path $HOME ".monk\bin" }
$agent = if ($env:MONK_AGENT_PATH) { $env:MONK_AGENT_PATH } else { Join-Path $agentDir "monk-agent.exe" }

if (-not (Test-Path $agent)) { exit 0 }

# Run via Process (not the `&` call operator) so a wedged helper can be bounded
# and killed instead of blocking this best-effort hook indefinitely. Standard
# handles are left un-redirected so the binary still reads the payload straight
# from this process's inherited stdin (see block-monk.ps1 for why we do not
# read it into a PowerShell string and re-pipe it).
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $agent
$startInfo.Arguments = "hook diagnostics --format $Format"
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true

$agentProcess = $null
try {
  $agentProcess = New-Object System.Diagnostics.Process
  $agentProcess.StartInfo = $startInfo
  [void]$agentProcess.Start()
  # A wedged (not merely failing) helper must not block the edit indefinitely:
  # bound the wait and kill it on timeout rather than only the host's own
  # external tool-call timeout saving us. PS 5.1's Process class has no
  # tree-kill overload, so this only reaches the helper itself.
  $timeoutMs = if ($env:MONK_AGENT_HOOK_TIMEOUT_MS) { [int]$env:MONK_AGENT_HOOK_TIMEOUT_MS } else { 10000 }
  if (-not $agentProcess.WaitForExit($timeoutMs)) {
    try { $agentProcess.Kill() } catch {}
  }
} catch {
} finally {
  if ($agentProcess) { $agentProcess.Dispose() }
}
exit 0
