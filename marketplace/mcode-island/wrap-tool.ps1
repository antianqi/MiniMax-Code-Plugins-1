# mcode - wrapper (v0.2.1: status-only)
# mcode
# wrap-tool.ps1 -Tool bash -Command "npm test" # working
# wrap-tool.ps1 -Tool bash -Command "npm test" -ExitCode 0 # done
# wrap-tool.ps1 -Tool bash -Command "npm test" -ExitCode 1 # waiting
# wrap-tool.ps1 -Tool bash -Command "npm test" -ExitCode 2 # error
# v0.2.1 ""v0.1 Invoke-Expression review
# injection PS agent mcode bash tool
# shell mcode
# 1. working -Message "<Tool> <brief>" -ExitCode
# 2. done/error/waiting based on -ExitCode -ExitCode
# 3. done0, waitingwaiting-exit-code, errorerror-exit-code

param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('bash','read','write','edit','glob','grep','web','task','notebook')]
  [string]$Tool,

  [string]$Command = '',
  [string]$Path = '',
  [string]$Pattern = '',
  [string]$Glob = '',
  [string]$Description = '',
  [int]$ExitCode = -1, # -1 = not yet run, push working; 0/0 = push done/waiting/error
  [int[]]$WaitingExitCodes = @(1) # "waiting"
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 > $null

$notify = Join-Path $PSScriptRoot 'notify-island.ps1'

# "" widget
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
  'bash'     { "$brief $([char]0x5B8C)$([char]0x6210)" }
  'read'     { if ($brief) { "read $brief" } else { "read $([char]0x5B8C)$([char]0x6210)" } }
  'write'    { if ($brief) { "wrote $brief" } else { "write $([char]0x5B8C)$([char]0x6210)" } }
  'edit'     { if ($brief) { "edited $brief" } else { "edit $([char]0x5B8C)$([char]0x6210)" } }
  'glob'     { if ($Glob) { "glob $Glob" } elseif ($brief) { "glob $brief" } else { "glob $([char]0x5B8C)$([char]0x6210)" } }
  'grep'     { if ($Pattern) { "grep $Pattern" } else { "grep $([char]0x5B8C)$([char]0x6210)" } }
  'web'      { 'web ' + [char]0x5B8C + [char]0x6210 }
  'task'     { 'task ' + [char]0x5B8C + [char]0x6210 }
  'notebook' { 'notebook ' + [char]0x5B8C + [char]0x6210 }
  default    { "$Tool $([char]0x5B8C)$([char]0x6210)" }
}

if ($ExitCode -eq 0) {
  & $notify -State done -Message $doneMsg | Out-Null
  exit 0
} elseif ($WaitingExitCodes -contains $ExitCode) {
  & $notify -State waiting -Message "$Tool $([char]0x7B49)$([char]0x5F85)$([char]0x5BA1)$([char]0x6279) (exit=$ExitCode)" | Out-Null
  exit $ExitCode
} else {
  & $notify -State error -Message "$Tool $([char]0x5931)$([char]0x8D25) (exit=$ExitCode)" | Out-Null
  exit $ExitCode
}
