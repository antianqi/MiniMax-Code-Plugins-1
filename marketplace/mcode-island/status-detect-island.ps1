# detector

# mcode-island runs on Windows only: the status pill is a WPF window and the
# autostart entry is a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
# On any other platform fail with a clear message instead of a cryptic WPF or
# registry error.
if ($env:OS -ne 'Windows_NT') {
  Write-Output 'mcode-island supports Windows only (this host is not Windows).'
  exit 1
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$pidFile = Join-Path $env:APPDATA 'mcode-island\detect.pid'
if (!(Test-Path $pidFile)) { Write-Output 'NOT RUNNING'; exit 0 }
$targetPid = (Get-Content $pidFile -ErrorAction SilentlyContinue) -as [int]
$p = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
if ($p -and -not $p.HasExited) {
  Write-Output ("RUNNING  PID=" + $p.Id + "  StartTime=" + $p.StartTime.ToString('HH:mm:ss'))
  $sf = Join-Path $env:APPDATA 'mcode-island\status.json'
  if (Test-Path $sf) {
    Write-Output '--- last status.json ---'
    Get-Content $sf -Raw
  }
} else {
  Write-Output ("NOT RUNNING (stale pid " + $targetPid + ")")
}
