# mcode - widget
# mcode-island show

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# widget
$pidFile = Join-Path $env:APPDATA 'mcode-island\widget.pid'
$widgetPid = (Get-Content $pidFile -ErrorAction SilentlyContinue) -as [int]
if (-not $widgetPid -or $widgetPid -le 0) {
  Write-Output 'NOT RUNNING: widget is not running, run mcode-island start first'
  exit 0
}
$proc = Get-Process -Id $widgetPid -ErrorAction SilentlyContinue
if (-not $proc -or $proc.HasExited) {
  Write-Output "NOT RUNNING: PID $widgetPid is dead, run mcode-island start first"
  exit 0
}

# show widget 400ms Show()
$configDir = Join-Path $env:APPDATA 'mcode-island'
if (!(Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
$signalFile = Join-Path $configDir 'show.signal'

try {
  [System.IO.File]::WriteAllText($signalFile, (Get-Date).ToString('o'), [System.Text.Encoding]::ASCII)
  Write-Output "OK: signal sent (widget PID $widgetPid should show up within 1s)"
} catch {
  Write-Output "FAIL: $($_.Exception.Message)"
  exit 1
}
