# SQLite
# session " " " 40
# " URL "
# MiniMax Code SQLite
# ~/.minimax/v2/sqlite/runtime-state.sqlite
# local_runtime_sessions title
# 417 413 " MCode
# 0.6.13 "
# PowerShell SQLite Skill-only
# npm node
# - node:sqlite Node 22.5+ ** ** npm
# - app Electron ELECTRON_RUN_AS_NODE=1 node

# lib detector
# WAL SQLite

# session id ->

# mcode-island runs on Windows only: the status pill is a WPF window and the
# autostart entry is a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
# On any other platform fail with a clear message instead of a cryptic WPF or
# registry error.
if ($env:OS -ne 'Windows_NT') {
  Write-Output 'mcode-island supports Windows only (this host is not Windows).'
  exit 1
}
$script:runtimeTitles = @{}
# 60s
$script:runtimeTitlesAt = [DateTime]::MinValue
$script:RUNTIME_TITLES_TTL_MS = 60 * 1000
# 1.9GB 1.5s
$script:RUNTIME_TITLES_TIMEOUT_MS = 1500

# Windows USERPROFILE Linux/macOS HOME CI ubuntu
# job USERPROFILE Join-Path $null
function Get-UserHome {
  foreach ($v in @($env:USERPROFILE, $env:HOME)) {
    if ($v) { return [string]$v }
  }
  return ''
}

# node
# 1. PATH node
# 2. app node ELECTRON_RUN_AS_NODE=1
# 3 node app
# ** ** node
function Get-NodeCommand {
  try {
    $c = Get-Command node -ErrorAction SilentlyContinue
    if ($c) { return @{ Exe = $c.Source; Env = $null } }

 # The CLI's own node is not a path the Marketplace package may know
 # about: the package must not depend on the MiniMax Code CLI being
 # installed. The desktop app can act as node (ELECTRON_RUN_AS_NODE=1),
 # and that is the path this build is built for.

 # app ELECTRON_RUN_AS_NODE=1 Electron node
 # exe Program Files
    $names = @('MiniMax Inside Code', 'MiniMax Code', 'Mavis')
    foreach ($n in $names) {
      $proc = Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
      if ($proc) { return @{ Exe = $proc.Path; Env = 'ELECTRON_RUN_AS_NODE=1' } }
    }
  } catch {
  }
  return $null
}

# node
# @{ id -> title } ** **
# detector
# try CI ubuntu job
# USERPROFILE Join-Path $null
function Read-RuntimeTitles {
  $result = @{}
  $tmp = $null
  try {
 # MCODE_RUNTIME_STATE_DB
 # 1.9GB
    $db = $env:MCODE_RUNTIME_STATE_DB
    if (-not $db) {
      $userHome = Get-UserHome
      if (-not $userHome) { return $result }
      $db = Join-Path $userHome '.minimax\v2\sqlite\runtime-state.sqlite'
    }
    if (-not (Test-Path -LiteralPath $db)) { return $result }

    $node = Get-NodeCommand
    if (-not $node) { return $result }

 # node:sqlite id -> title JSON
 # id IN
 # argv[1] argv[2]
 # .cjs package.json "type": "module"
 # .js ES module require() "require is not defined"
    $js = @'
const {DatabaseSync} = require("node:sqlite");
const db = new DatabaseSync(process.argv[2], {readOnly: true});
const out = {};
try {
  for (const r of db.prepare("SELECT session_id, title FROM local_runtime_sessions").all()) {
    if (r && r.title) out[String(r.session_id)] = String(r.title);
  }
} finally { db.close(); }
process.stdout.write(JSON.stringify(out));
'@

 # .NET GetTempPath() $env:TEMP
 # Linux PowerShell TEMP TMPDIR Join-Path $null
 # ubuntu CI
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('island-titles-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.cjs')
    [System.IO.File]::WriteAllText($tmp, $js, (New-Object System.Text.UTF8Encoding($false)))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node.Exe
    $psi.Arguments = '"' + $tmp + '" "' + $db + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($node.Env) { $psi.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1' }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $proc.StandardError.ReadToEnd() | Out-Null
    if (-not $proc.WaitForExit($script:RUNTIME_TITLES_TIMEOUT_MS)) {
      try { $proc.Kill() } catch {}
      return $result
    }
    if ($proc.ExitCode -ne 0) { return $result }
    if (-not $out) { return $result }
    $parsed = $out | ConvertFrom-Json
    foreach ($p in $parsed.PSObject.Properties) { $result[$p.Name] = [string]$p.Value }
  } catch {
  } finally {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) {
      try { [System.IO.File]::Delete($tmp) } catch {}
    }
  }
  return $result
}

# session
# 60s
# detector
function Get-RuntimeSessionTitle([string]$id) {
  try {
    if (-not $id) { return '' }
    $now = Get-Date
    if (($now - $script:runtimeTitlesAt).TotalMilliseconds -ge $script:RUNTIME_TITLES_TTL_MS) {
      $script:runtimeTitles = Read-RuntimeTitles
      $script:runtimeTitlesAt = $now
    }
    if ($script:runtimeTitles.ContainsKey($id)) { return [string]$script:runtimeTitles[$id] }
  } catch {
  }
  return ''
}
