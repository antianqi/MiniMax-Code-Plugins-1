# detector PID + cmdline

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
$detectScript = 'mcode-status-detect.ps1' # cmdline
if (!(Test-Path $pidFile)) { Write-Output 'NOT RUNNING'; exit 0 }

$targetPid = (Get-Content $pidFile -ErrorAction SilentlyContinue) -as [int]
if ($targetPid -and $targetPid -gt 0) {
  $p = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
  if ($p -and -not $p.HasExited) {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -and $cmd.IndexOf($detectScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
      Stop-Process -Id $targetPid -Force
      Write-Output ("stopped PID " + $targetPid)
    } else {
      Write-Output ("REFUSED: PID " + $targetPid + " is alive but not the detector (PID reuse suspected). Refusing to kill.")
    }
  } else {
    Write-Output ("NOT RUNNING (stale pid " + $targetPid + ")")
  }
}
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
