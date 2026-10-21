# mcode - +
# notify-island.ps1 -State working -Message "..."
# 1. status.jsonwidget
# 2. caller.jsonwidget

param(
  [ValidateSet('idle','thinking','working','waiting','done','error')]
  [string]$State = 'idle',
  [string]$Message = '',
  [int]$Progress = -1,
  [int]$Step = -1,
  [int]$Total = -1,
  [string]$Detail = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null

$configDir = Join-Path $env:APPDATA 'mcode-island'
if (!(Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
$statusFile = Join-Path $configDir 'status.json'
$callerFile = Join-Path $configDir 'caller.json'

# console Windows Terminal tab HWND
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ConsoleWin {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("kernel32.dll")] public static extern bool AttachConsole(uint dwProcessId);
  [DllImport("kernel32.dll")] public static extern bool FreeConsole();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@ -ErrorAction SilentlyContinue

function Get-CallerFocusInfo {
 # 1) console window
  $hwnd = [ConsoleWin]::GetConsoleWindow()
  if ($hwnd -ne [IntPtr]::Zero) {
    $ownerPid = 0
    [ConsoleWin]::GetWindowThreadProcessId($hwnd, [ref]$ownerPid) | Out-Null
    return @{
      targetHwnd  = [int64]$hwnd
      targetPid   = [int]$ownerPid
      targetExe   = (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).ProcessName
      targetTitle = ''
      source      = 'console-window'
    }
  }

 # 2) consolenotify-island NonInteractive
  $parentProc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
  if ($parentProc -and $parentProc.ParentProcessId -and $parentProc.ParentProcessId -gt 0) {
 # console
    $current = [int]$parentProc.ParentProcessId
    $visited = @()
    for ($i = 0; $i -lt 6; $i++) {
      if ($visited -contains $current) { break }
      $visited += $current
      $attached = [ConsoleWin]::AttachConsole([uint32]$current)
      if ($attached) {
        $hwnd = [ConsoleWin]::GetConsoleWindow()
        [ConsoleWin]::FreeConsole() | Out-Null
        if ($hwnd -ne [IntPtr]::Zero) {
          $ownerPid = 0
          [ConsoleWin]::GetWindowThreadProcessId($hwnd, [ref]$ownerPid) | Out-Null
          return @{
            targetHwnd  = [int64]$hwnd
            targetPid   = [int]$ownerPid
            targetExe   = (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).ProcessName
            targetTitle = ''
            source      = 'attached-console'
          }
        }
      }
      $gp = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
      if (-not $gp -or -not $gp.ParentProcessId) { break }
      $current = [int]$gp.ParentProcessId
    }
  }

 # 3) fallback:
  $current = $PID
  $visited = @()
  for ($i = 0; $i -lt 6; $i++) {
    if ($visited -contains $current) { return $null }
    $visited += $current
    $proc = Get-Process -Id $current -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    if ([int64]$proc.MainWindowHandle -ne 0) {
      return @{
        targetHwnd  = [int64]$proc.MainWindowHandle
        targetPid   = $proc.Id
        targetExe   = $proc.ProcessName
        targetTitle = $proc.MainWindowTitle
        source      = 'parent-chain'
      }
    }
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
    if (-not $parent -or -not $parent.ParentProcessId -or $parent.ParentProcessId -eq 0) { return $null }
    $current = [int]$parent.ParentProcessId
  }
  return $null
}

$ts = (Get-Date).ToString('o')

# status.jsonwidget
# source='agent' detector agent working/thinking/done
# detector idle/error takeover
$payload = [PSCustomObject]@{
  state    = $State
  message  = $Message
  progress = $Progress
  step     = $Step
  total    = $Total
  detail   = $Detail
  ts       = $ts
  source   = 'agent'
} | ConvertTo-Json -Compress

# caller.jsonwidget
$myPid = $PID
$focusInfo = Get-CallerFocusInfo
$callerData = [PSCustomObject]@{
  callerPid   = $myPid
  callerSession = (Get-Process -Id $myPid).SessionId
  targetPid   = if ($focusInfo) { $focusInfo.targetPid } else { 0 }
  targetHwnd  = if ($focusInfo) { $focusInfo.targetHwnd } else { 0 }
  targetTitle = if ($focusInfo) { $focusInfo.targetTitle } else { '' }
  targetExe   = if ($focusInfo) { $focusInfo.targetExe } else { '' }
  source      = if ($focusInfo) { $focusInfo.source } else { 'none' }
  ts          = $ts
}

$tmpStatus = "$statusFile.tmp"
$tmpCaller = "$callerFile.tmp"
try {
  [System.IO.File]::WriteAllText($tmpStatus, $payload, [System.Text.Encoding]::UTF8)
  Move-Item -Path $tmpStatus -Destination $statusFile -Force
  [System.IO.File]::WriteAllText($tmpCaller, ($callerData | ConvertTo-Json -Compress), [System.Text.Encoding]::UTF8)
  Move-Item -Path $tmpCaller -Destination $callerFile -Force
  Write-Output "OK: $State - $Message"
  if ($focusInfo) {
    Write-Output ("  (caller via " + $focusInfo.source + ": " + $focusInfo.targetExe + " PID=" + $focusInfo.targetPid + " hwnd=" + $focusInfo.targetHwnd + ")")
  }
} catch {
  Write-Output "FAIL: $($_.Exception.Message)"
  exit 1
}
