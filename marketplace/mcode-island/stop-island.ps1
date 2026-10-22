# widget
# PID + cmdline PID

# mcode-island runs on Windows only: the status pill is a WPF window and the
# autostart entry is a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
# On any other platform fail with a clear message instead of a cryptic WPF or
# registry error.
if ($env:OS -ne 'Windows_NT') {
  Write-Output 'mcode-island supports Windows only (this host is not Windows).'
  exit 1
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$configDir = Join-Path $env:APPDATA 'mcode-island'
$pidFile = Join-Path $configDir 'widget.pid'
$widgetScript = 'mcode-island.ps1' # cmdline

if (!(Test-Path $pidFile)) {
  Write-Output 'NOT RUNNING'
  exit 0
}

$widgetPid = (Get-Content $pidFile -ErrorAction SilentlyContinue) -as [int]
if ($widgetPid -and $widgetPid -gt 0) {
  $proc = Get-Process -Id $widgetPid -ErrorAction SilentlyContinue
  if ($proc -and !$proc.HasExited) {
 # cmdline widget PID
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$widgetPid" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -and $cmd.IndexOf($widgetScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
      Stop-Process -Id $widgetPid -Force
      Write-Output ("stopped PID " + $widgetPid)
    } else {
      Write-Output ("REFUSED: PID " + $widgetPid + " is alive but not the widget (PID reuse suspected). Refusing to kill.")
    }
  } else {
    Write-Output ("NOT RUNNING (stale pid " + $widgetPid + ")")
  }
} else {
  Write-Output 'NOT RUNNING'
}
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
