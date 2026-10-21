# widget
# PID + cmdline PID
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
