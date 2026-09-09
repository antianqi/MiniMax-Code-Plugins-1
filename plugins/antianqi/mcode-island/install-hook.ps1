# mcode-island: install the v0.3.10 hook document into the runtime-resolved
# dataDir so the Plugin's hooks are visible to the @minimax-ai/code@0.3.10
# hook-config parser.
#
# Background. The 0.3.10 runtime reads hooks.json from:
#   - $MINIMAX_DATA_DIR/hooks/hooks.json  (project-wide)
#   - $MINIMAX_DATA_DIR/agents/<agentName>/hooks/hooks.json  (per-agent)
# It does NOT read the Plugin's own io.minimax.mcode/hooks/hooks.json
# path declared in plugin.json. The Plugin registry accepts the
# io.minimax.mcode namespace, but the hook-config parser does not
# consult that field. To make the Plugin's hooks visible, we copy
# the bundled hooks.json into the runtime-resolved dataDir.
#
# This script is idempotent: it overwrites the dataDir copy on each run.
# It is safe to call after every mcode upgrade.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-hook.ps1
#
#   # Per-agent install (for the mavis agent on this machine):
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-hook.ps1 -Agent mavis

[CmdletBinding()]
param(
    [string]$Agent = '',
    [string]$DataDir = '',
    [string]$SourcePath = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 1. Resolve the source: the bundled hooks.json in the Plugin tree.
if (-not $SourcePath) {
    $SourcePath = Join-Path $PSScriptRoot 'io.minimax.mcode\hooks\hooks.json'
}
if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Source hooks.json not found at: $SourcePath"
}

# 2. Resolve the destination dataDir.
#    The 0.3.10 runtime resolves dataDir from, in order:
#      - $env:MINIMAX_DATA_DIR
#      - $env:MAVIS_DATA_DIR
#      - the runtime default (typically $HOME/.mavis on Windows)
#    We mirror that resolution. If -DataDir is passed, that wins.
function Resolve-DataDir {
    param([string]$Override)
    if ($Override) { return $Override }
    if ($env:MINIMAX_DATA_DIR) { return $env:MINIMAX_DATA_DIR }
    if ($env:MAVIS_DATA_DIR) { return $env:MAVIS_DATA_DIR }
    # Default for Windows: the user profile .minimax (the mavis install path).
    return (Join-Path $env:USERPROFILE '.minimax')
}

$DataDir = Resolve-DataDir -Override $DataDir

# 3. Resolve the target path: project-wide or per-agent.
if ($Agent) {
    $TargetPath = Join-Path $DataDir "agents\$Agent\hooks\hooks.json"
    $TargetDir  = Split-Path -Parent $TargetPath
    $Scope      = "agent=$Agent"
} else {
    $TargetPath = Join-Path $DataDir 'hooks\hooks.json'
    $TargetDir  = Split-Path -Parent $TargetPath
    $Scope      = 'project-wide'
}

if (-not (Test-Path -LiteralPath $TargetDir)) {
    [void](New-Item -ItemType Directory -Path $TargetDir -Force)
}

# 4. Atomic copy: stage to a temp file in the same directory, then rename.
#    This matches the staging-and-rename pattern used by record.mjs in
#    the validator example. PowerShell's Move-Item -Force is essentially
#    rename on the same volume and is atomic.
$StagePath = "$TargetPath.stage-$PID"
try {
    Copy-Item -LiteralPath $SourcePath -Destination $StagePath -Force
    Move-Item -LiteralPath $StagePath -Destination $TargetPath -Force
} catch {
    if (Test-Path -LiteralPath $StagePath) {
        Remove-Item -LiteralPath $StagePath -Force -ErrorAction SilentlyContinue
    }
    throw
}

Write-Host "OK $Scope installed"
Write-Host "  source:    $SourcePath"
Write-Host "  dataDir:   $DataDir"
Write-Host "  installed: $TargetPath"
Write-Host ""
Write-Host "Note: the @minimax-ai/code@0.3.10 runtime reads this file at"
Write-Host "session start. The Plugin's own io.minimax.mcode/hooks/hooks.json"
Write-Host "is still kept in sync for when the runtime learns to read it,"
Write-Host "but the runtime currently consults only the dataDir path above."
Write-Host ""
Write-Host "Caveat (mcode 0.3.10 on Windows): the runtime's hook dispatcher"
Write-Host "spawns commands via /bin/sh -lc, which ENOENTs on Windows. The"
Write-Host "hook config is correct and the install step succeeded, but no"
Write-Host "hook will fire on Windows 0.3.10 until the runtime sets"
Write-Host "usePlatformShell: true on Windows. Track the upstream issue"
Write-Host "and use Mode B (detector) in the meantime."
