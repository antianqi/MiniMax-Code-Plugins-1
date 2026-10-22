# mcode -
# STA widget
# widget PID %APPDATA%\mcode-island\widget.pid status/stop


# mcode-island runs on Windows only: the status pill is a WPF window and the
# autostart entry is a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
# On any other platform fail with a clear message instead of a cryptic WPF or
# registry error.
if ($env:OS -ne 'Windows_NT') {
  Write-Output 'mcode-island supports Windows only (this host is not Windows).'
  exit 1
}
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$configDir = Join-Path $env:APPDATA 'mcode-island'
if (!(Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

$widget = Join-Path $PSScriptRoot 'mcode-island.ps1'
$pidFile = Join-Path $configDir 'widget.pid'

# PID widget PID
function Test-IsWidgetProcess($proc, $widgetPath) {
  if (-not $proc -or $proc.HasExited) { return $false }
  $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue).CommandLine
  if (-not $cmd) { return $false }
 # CommandLine contains the widget script path (case-insensitive)
  return $cmd.IndexOf($widgetPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

if (Test-Path $pidFile) {
  $old = Get-Content $pidFile -ErrorAction SilentlyContinue
  if ($old) {
    $existing = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
    if ($existing -and (Test-IsWidgetProcess $existing $widget)) {
      Write-Output ("already running (PID " + $old + ")")
      exit 0
    }
 # Stale PID file (process dead or PID reused) clear and continue
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  }
}

# widget
# ProcessStartInfo + CreateNoWindow = $true -WindowStyle Hidden SW_HIDE
# CreateNoWindow Win32 CREATE_NO_WINDOW
# /Alt-Tab
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$widget`""
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)

# PID status / stop
Set-Content -Path $pidFile -Value $proc.Id -Encoding ASCII

# widget 8
# Process.MainWindowHandle != 0 / always-on-top
# / WPF Win32 MainWindow 0
# " " widget 1 " "
# widget
# "starting Application.Run"
$widgetLog   = Join-Path $configDir 'widget.log'
$widgetReady = 'starting Application.Run'
# widget.log append-only
# stop start
$logLenBefore = 0
if (Test-Path -LiteralPath $widgetLog) {
  try { $logLenBefore = (Get-Item -LiteralPath $widgetLog).Length } catch { $logLenBefore = 0 }
}

$ok = $false
for ($i = 0; $i -lt 16; $i++) {
  Start-Sleep -Milliseconds 500
  try {
    if ((Get-Process -Id $proc.Id -ErrorAction Stop).HasExited) { break }
  } catch { break }

  if (-not (Test-Path -LiteralPath $widgetLog)) { continue }
  try {
    $fi = Get-Item -LiteralPath $widgetLog
    if ($fi.Length -le $logLenBefore) { continue }
    $fs = [System.IO.File]::Open($fi.FullName, 'Open', 'Read', 'ReadWrite')
    try {
      [void]$fs.Seek($logLenBefore, 'Begin')
      $added = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)).ReadToEnd()
    } finally { $fs.Dispose() }
    if ($added.IndexOf($widgetReady, [System.StringComparison]::Ordinal) -ge 0) { $ok = $true; break }
  } catch {}
}

# detector start-detect-island.ps1 detect.pid
# PID mcode-status-detect.ps1 detector
# 2026-10-06 14:37:42 detector
# "detector stopped" widget status.json pill
# ~23 " "
# detector detector widget
$detectStarter = Join-Path $PSScriptRoot 'start-detect-island.ps1'
if (Test-Path $detectStarter) {
  try {
    $detOut = & $detectStarter 2>&1
    Write-Output ("detector: " + (($detOut | Out-String).Trim()))
  } catch {
    Write-Output ("detector start failed (widget is up anyway): " + $_.Exception.Message)
  }
}

if ($ok) {
  Write-Output ("mcode-island started (PID " + $proc.Id + ", ready)")
} else {
  Write-Output ("mcode-island started (PID " + $proc.Id + ", waiting...)")
}
