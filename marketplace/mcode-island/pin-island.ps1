# mcode - pin
# mcode mcode-island pin
# mcode tab HWND
# pill


# mcode-island runs on Windows only: the status pill is a WPF window and the
# autostart entry is a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
# On any other platform fail with a clear message instead of a cryptic WPF or
# registry error.
if ($env:OS -ne 'Windows_NT') {
  Write-Output 'mcode-island supports Windows only (this host is not Windows).'
  exit 1
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PinW {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
"@ -ErrorAction SilentlyContinue

$hwnd = [PinW]::GetForegroundWindow()
if ($hwnd -eq [IntPtr]::Zero) {
  Write-Output "FAIL: no foreground window"
  exit 1
}
$ownerPid = 0
[PinW]::GetWindowThreadProcessId($hwnd, [ref]$ownerPid) | Out-Null
$proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
if (-not $proc) {
  Write-Output "FAIL: foreground window process has exited"
  exit 1
}

$configDir = Join-Path $env:APPDATA 'mcode-island'
if (!(Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
$callerFile = Join-Path $configDir 'caller.json'

$myPid = [int](Get-Process -Id $PID).Id
$mySession = (Get-Process -Id $myPid).SessionId
$payload = [PSCustomObject]@{
  callerPid    = $myPid
  callerSession = $mySession
  targetPid    = $proc.Id
  targetHwnd   = [int64]$hwnd
  targetTitle  = $proc.MainWindowTitle
  targetExe    = $proc.ProcessName
  source       = 'cli-pin'
  ts           = (Get-Date).ToString('o')
} | ConvertTo-Json -Compress

$tmpFile = "$callerFile.tmp"
[System.IO.File]::WriteAllText($tmpFile, $payload, [System.Text.Encoding]::UTF8)
Move-Item -Path $tmpFile -Destination $callerFile -Force

Write-Output ("OK: pin'd " + $proc.ProcessName + " (PID=" + $proc.Id + ", hwnd=" + $hwnd + ")")
Write-Output ("     title: " + $proc.MainWindowTitle)
Write-Output "     click the pill to switch back to this window"
