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

# widget 8 .ps1 WPF readiness
$widgetWindowClass = 'HwndWrapper[DefaultDomain*' # WPF
$ok = $false
for ($i = 0; $i -lt 16; $i++) {
  Start-Sleep -Milliseconds 500
  try {
    $p = Get-Process -Id $proc.Id -ErrorAction Stop
    if ($p.HasExited) { break }
 # WPF widget MainWindowHandle 0
    if ($p.MainWindowHandle -ne 0) { $ok = $true; break }
  } catch {}
}

if ($ok) {
  Write-Output ("mcode-island started (PID " + $proc.Id + ", ready)")
} else {
  Write-Output ("mcode-island started (PID " + $proc.Id + ", waiting...)")
}
