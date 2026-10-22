# mcode - wrapper (v0.2.1: status-only)
# mcode
# wrap-tool.ps1 -Tool bash -Command "npm test" # working
# wrap-tool.ps1 -Tool bash -Command "npm test" -ExitCode 0 # done
# wrap-tool.ps1 -Tool bash -Command "npm test" -ExitCode 1 # waiting
# wrap-tool.ps1 -Tool bash -Command "npm test" -ExitCode 2 # error
# v0.2.1 " " v0.1 Invoke-Expression review
# injection PS agent mcode bash tool
# shell mcode
# 1. working -Message "<Tool> <brief>" -ExitCode
# 2. done/error/waiting based on -ExitCode -ExitCode
# 3. done 0, waiting waiting-exit-code, error error-exit-code

param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('bash','read','write','edit','glob','grep','web','task','notebook')]
  [string]$Tool,

  [string]$Command = '',
  [string]$Path = '',
  [string]$Pattern = '',
  [string]$Glob = '',
  [string]$Description = '',
  [int]$ExitCode = -1, # -1 = not yet run, push working; 0/ 0 = push done/waiting/error
  [int[]]$WaitingExitCodes = @(1) # "waiting"
)

# mcode-island runs on Windows only: the status pill is a WPF window and the
# autostart entry is a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
# On any other platform fail with a clear message instead of a cryptic WPF or
# registry error.
if ($env:OS -ne 'Windows_NT') {
  Write-Output 'mcode-island supports Windows only (this host is not Windows).'
  exit 1
}

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 > $null

$notify = Join-Path $PSScriptRoot 'notify-island.ps1'

# " " widget
$brief = $Description
if (-not $brief) {
  if ($Command) { $brief = ($Command.Substring(0, [Math]::Min(60, $Command.Length))) }
  elseif ($Path) { $brief = $Path }
  elseif ($Pattern) { $brief = $Pattern }
  elseif ($Glob) { $brief = $Glob }
  else { $brief = '' }
}
$brief = $brief -replace "`r`n", ' ' -replace "`n", ' '

if ($ExitCode -lt 0) {
 # working
  & $notify -State working -Message "$Tool : $brief" | Out-Null
  exit 0
}

# Tool-specific detector messages.jsonl toolName
$doneMsg = switch ($Tool) {
  'bash'     { "$brief done" }
  'read'     { if ($brief) { "read $brief" } else { "read done" } }
  'write'    { if ($brief) { "wrote $brief" } else { "write done" } }
  'edit'     { if ($brief) { "edited $brief" } else { "edit done" } }
  'glob'     { if ($Glob) { "glob $Glob" } elseif ($brief) { "glob $brief" } else { "glob done" } }
  'grep'     { if ($Pattern) { "grep $Pattern" } else { "grep done" } }
  'web'      { 'web done' }
  'task'     { 'task done' }
  'notebook' { 'notebook done' }
  default    { "$Tool done" }
}

if ($ExitCode -eq 0) {
  & $notify -State done -Message $doneMsg | Out-Null
  exit 0
} elseif ($WaitingExitCodes -contains $ExitCode) {
  & $notify -State waiting -Message "$Tool waiting for approval (exit=$ExitCode)" | Out-Null
  exit $ExitCode
} else {
  & $notify -State error -Message "$Tool failed (exit=$ExitCode)" | Out-Null
  exit $ExitCode
}
