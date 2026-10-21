# mcode-status-detect.ps1 - (v0.2.1)
# mcode session log agent status.json
# widget agent notify-island.ps1
# 1. mcode node cmdline <userprofile>/.minimax-code
# 2. $env:USERPROFILE/.minimax-code
# 3. $env:USERPROFILE/AppData/Roaming/minimax-code/.minimax-code
# 4. <cwd>/.minimax-code
# session log
# 1. <root>/.minimax/v2/sessions/<date>/*/ledger.jsonlmcode v2
# 2. <root>/.minimax/v2/sessions/<date>/*/messages.jsonlfallback
# role=user idle ()
# role=assistant + toolCall working "<tool>: <args>"
# role=assistant + thinking thinking
# role=assistant + text idle ()
# role=toolResult + !isError done "<tool> "
# role=toolResult + isError error "<tool> "
# mcode error "mcode "
# 60s idle
# agent status.json source != detector
# detector idle / error agent
# detector working/thinking/done agent
# PS 5.1 parser quirk:
# ASCII -eq / state= cmdlet
# ASCII _s (byte[]) helper

param(
  [switch]$Once,
  [string]$Root = ''    # override: <root>/.minimax-code and <root>/.minimax/v2/...
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null

# start-detect CreateNoWindow
# SW_HIDE
$hideSig = @'
using System;
using System.Runtime.InteropServices;
public class DetectHide {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
}
'@
if (-not ('DetectHide' -as [type])) { Add-Type $hideSig -ErrorAction SilentlyContinue }
$hwnd = [DetectHide]::GetConsoleWindow()
if ($hwnd -ne [IntPtr]::Zero) {
  [void][DetectHide]::ShowWindow($hwnd, 0)
}

function _s { param([byte[]]$b) [System.Text.Encoding]::UTF8.GetString($b) }

# role names
$S_USER       = _s (0x75,0x73,0x65,0x72)
$S_ASSISTANT  = _s (0x61,0x73,0x73,0x69,0x73,0x74,0x61,0x6E,0x74)
$S_TOOLRESULT = _s (0x74,0x6F,0x6F,0x6C,0x52,0x65,0x73,0x75,0x6C,0x74)
$S_COMPACTION = _s (0x63,0x6F,0x6D,0x70,0x61,0x63,0x74,0x69,0x6F,0x6E,0x53,0x75,0x6D,0x6D,0x61,0x72,0x79)
# state values
$S_IDLE     = _s (0x69,0x64,0x6C,0x65)
$S_THINKING = _s (0x74,0x68,0x69,0x6E,0x6B,0x69,0x6E,0x67)
$S_WORKING  = _s (0x77,0x6F,0x72,0x6B,0x69,0x6E,0x67)
$S_WAITING  = _s (0x77,0x61,0x69,0x74,0x69,0x6E,0x67)
$S_DONE     = _s (0x64,0x6F,0x6E,0x65)
$S_ERROR    = _s (0x65,0x72,0x72,0x6F,0x72)
# content type discriminators
$S_TOOLCALL  = _s (0x74,0x6F,0x6F,0x6C,0x43,0x61,0x6C,0x6C)
$S_TEXT      = _s (0x74,0x65,0x78,0x74)
$S_THINK_BLK = _s (0x74,0x68,0x69,0x6E,0x6B,0x69,0x6E,0x67)
# source tag
$S_DETECTOR  = _s (0x64,0x65,0x74,0x65,0x63,0x74,0x6F,0x72)
# messages (UTF-8 encoded Chinese)
$MSG_USER_WAIT  = _s (0xE7,0xAD,0x89,0xE7,0x94,0xA8,0xE6,0x88,0xB7)
$MSG_AGENT_DONE = _s (0x61,0x67,0x65,0x6E,0x74,0x20,0xE5,0x88,0x9A,0xE5,0x9B,0x9E,0xE5,0xA4,0x8D,0xEF,0xBC,0x8C,0xE7,0xAD,0x89,0xE7,0x94,0xA8,0xE6,0x88,0xB7) # agent
$MSG_COMPACT    = _s (0x73,0x65,0x73,0x73,0x69,0x6F,0x6E,0x20,0xE5,0x8E,0x8B,0xE7,0xBC,0xA9) # session
$MSG_MCODE_EXIT = _s (0x6D,0x63,0x6F,0x64,0x65,0x20,0xE8,0xBF,0x9B,0xE7,0xA8,0x8B,0xE5,0xB7,0xB2,0xE9,0x80,0x80,0xE5,0x87,0xBA) # mcode
$MSG_IDLE_FMT   = _s (0xE5,0xB7,0xB2,0xE9,0x9D,0x99,0xE9,0x9C,0xA8,0x20,0x7B,0x30,0x7D,0x73) # {0}s
$DOTS            = _s (0x2E,0x2E,0x2E)                                                # ...
$FMT_O           = _s (0x6F)                                                           # 'o' (ISO 8601 timestamp)
$FMT_O_FULL      = _s (0x4F)                                                           # 'O' (ISO 8601 full)
# log reason tags
$R_NO_CURRENT    = _s (0x6E,0x6F,0x20,0x63,0x75,0x72,0x72,0x65,0x6E,0x74,0x20,0x73,0x74,0x61,0x74,0x75,0x73)
$R_OWN_CHANGED   = _s (0x6F,0x77,0x6E,0x20,0x73,0x74,0x61,0x74,0x65,0x20,0x63,0x68,0x61,0x6E,0x67,0x65,0x64)
$R_OWN_MSG       = _s (0x6F,0x77,0x6E,0x20,0x6D,0x65,0x73,0x73,0x61,0x67,0x65,0x20,0x63,0x68,0x61,0x6E,0x67,0x65,0x64)
$R_TAKEOVER      = _s (0x74,0x61,0x6B,0x65,0x6F,0x76,0x65,0x72,0x20,0x74,0x6F,0x20,0x73,0x65,0x74,0x74,0x6C,0x65)
# session log file names ( ledger)
$FNAME_LEDGER    = _s (0x6C,0x65,0x64,0x67,0x65,0x72,0x2E,0x6A,0x73,0x6F,0x6E,0x6C)   # ledger.jsonl
$FNAME_MESSAGES  = _s (0x6D,0x65,0x73,0x73,0x61,0x67,0x65,0x73,0x2E,0x6A,0x73,0x6F,0x6E,0x6C)  # messages.jsonl
# tool action verbs (ASCII matches the mcode CLI TUI descriptor table HL)
# Mirrors @minimax-ai/code launcher-GHPADSKI.js HL[] so the pill shows the same
# present-tense verb ("Running") while the tool is in flight and the same
# past-tense verb ("Ran") once it returns, instead of a generic tool name.
$TOOL_ACTIONS = @{
  'bash'        = @{ running='Running';     done='Ran';          fail='Command failed' }
  'shell'       = @{ running='Running';     done='Ran';          fail='Command failed' }
  'edit'        = @{ running='Editing';     done='Edited';       fail='Edit failed' }
  'write'       = @{ running='Writing';     done='Wrote';        fail='Write failed' }
  'read'        = @{ running='Reading';     done='Read';         fail='Read failed' }
  'grep'        = @{ running='Searching';   done='Searched';     fail='Search failed' }
  'search'      = @{ running='Searching';   done='Searched';     fail='Search failed' }
  'glob'        = @{ running='Listing';     done='Listed';       fail='List failed' }
  'list'        = @{ running='Listing';     done='Listed';       fail='List failed' }
  'task'        = @{ running='Delegating';  done='Delegated';    fail='Delegation failed' }
  'web_search'  = @{ running='Web searching'; done='Web searched'; fail='Web search failed' }
  'web_fetch'   = @{ running='Fetching';     done='Fetched';      fail='Fetch failed' }
  'todowrite'   = @{ running='Planning';    done='Planned';      fail='Plan update failed' }
  'task_output' = @{ running='Reading task'; done='Read task';    fail='Task read failed' }
  'task_append' = @{ running='Steering task'; done='Steered task'; fail='Task steer failed' }
  'task_query'  = @{ running='Checking tasks'; done='Checked tasks'; fail='Task check failed' }
  'ask_user'    = @{ running='Asking';      done='Asked';        fail='Question failed' }
  'request_feature_enable' = @{ running='Requesting access'; done='Access requested'; fail='Access request failed' }
}
# Tool family the pill tints its dot by family instead of by state, so a
# read looks different from a write at a glance. Mirrors the `family` field
# of the mcode CLI TUI descriptor table (launcher-GHPADSKI.js HL[]).
# Unknown tools get no family (null) and fall back to the state color.
$TOOL_FAMILIES = @{
  'bash' = 'shell';  'shell' = 'shell'
  'read' = 'read'
  'edit' = 'write';  'write' = 'write'
  'grep' = 'search'; 'search' = 'search'; 'glob' = 'search'; 'list' = 'search'
  'task' = 'task'; 'task_output' = 'task'; 'task_append' = 'task'
 # ask_user is deliberately absent: it maps to the `waiting` state (see
 # Infer-State), and a waiting pill should wear the state color, not a family
 # tint. Giving it 'task' would paint the "come back, I'm blocked" signal in
 # the same cyan as an in-flight delegation.
  'web_search' = 'web'; 'web_fetch' = 'web'
  'todowrite' = 'plan'
  'request_feature_enable' = 'plan'
}
# default for tools not in the table (kept lowercase so it reads like a name)
$TOOL_FALLBACK_RUNNING = _s (0x55,0x73,0x69,0x6E,0x67)   # Using
$TOOL_FALLBACK_DONE    = _s (0x55,0x73,0x65,0x64)         # Used
# mcode node cli.js path fragment for cmdline match
$CLI_FRAGMENT    = _s (0x40,0x6D,0x69,0x6E,0x69,0x6D,0x61,0x78,0x2D,0x61,0x69,0x2F,0x63,0x6F,0x64,0x65,0x2F,0x63,0x6C,0x69,0x2E,0x6A,0x73)  # @minimax-ai/code/cli.js
# .mcode-active directory name
$ACTIVE_DIR      = _s (0x2E,0x6D,0x63,0x6F,0x64,0x65,0x2D,0x61,0x63,0x74,0x69,0x76,0x65)  # .mcode-active
# .minimax-code directory name (parent of .mcode-active)
$MINIMAX_CODE    = _s (0x2E,0x6D,0x69,0x6E,0x69,0x6D,0x61,0x78,0x2D,0x63,0x6F,0x64,0x65)  # .minimax-code
# v2 sessions relative to user profile
$V2_SESSIONS_REL = _s (0x2E,0x6D,0x69,0x6E,0x69,0x6D,0x61,0x78,0x5C,0x76,0x32,0x5C,0x73,0x65,0x73,0x73,0x69,0x6F,0x6E,0x73)  # .minimax\v2\sessions

$configDir = Join-Path $env:APPDATA 'mcode-island'
if (!(Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
$statusFile = Join-Path $configDir 'status.json'
$logFile    = Join-Path $configDir 'island.log'
$pidFile    = Join-Path $configDir 'detect.pid'
$cfgFile    = Join-Path $configDir 'config.json'

# 5h API 60s minimax /v1/coding_plan/remains status.json usage5h
# token env MINIMAX_OAUTH_TOKEN fallback config.json planApiToken
# The actual API call (Get-5hUsage) and the URL/host constants live
# in scripts/lib/Get-5hUsage.ps1. They are extracted into a lib so
# the windows-latest CI job (and the local runner) can exercise the
# 5h usage path against a mocked listener without requiring a real
# mcode install on the runner. Dot-source the lib here so the
# main loop's Refresh-5hUsage can call Get-5hUsage directly.
. "$PSScriptRoot/scripts/lib/Get-5hUsage.ps1"
# Shared redaction helper (round-20). The detector is the SECOND producer
# of tool text -- it re-derives messages from mcode's session log rather
. "$PSScriptRoot/scripts/lib/Protect-Text.ps1"
$PLAN_API_TTL  = [TimeSpan]::FromSeconds(60)
$script:plan5hToken = $null
if ($env:MINIMAX_OAUTH_TOKEN) { $script:plan5hToken = $env:MINIMAX_OAUTH_TOKEN }
elseif ($env:MINIMAX_API_KEY) { $script:plan5hToken = $env:MINIMAX_API_KEY }
elseif (Test-Path $cfgFile) {
  try {
    $cfg = [System.IO.File]::ReadAllText($cfgFile) | ConvertFrom-Json
    if ($cfg.PSObject.Properties['planApiToken'] -and $cfg.planApiToken) {
      $script:plan5hToken = [string]$cfg.planApiToken
    }
  } catch {}
}
$script:plan5hLastCallAt = [DateTime]::MinValue
$script:plan5hRemainingPct = $null # 0..100
$script:plan5hResetMs = $null

# Todo widget completed / (total - cancelled) * 100
$script:plan5hTodoData = $null      # @{ percent; currentTodo; completed; total }
$script:plan5hTodoCacheMtime = [DateTime]::MinValue
$script:plan5hLastWrittenTodoPct = $null # status.json todoProgress

# mcode <userprofile>/.minimax-code
function Find-McodeRoot {
 # 1) -Root
  if ($script:optRoot -and (Test-Path $script:optRoot)) { return $script:optRoot }

 # 2) mcode node cmdline
  $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($CLI_FRAGMENT) }
  foreach ($p in $procs) {
    try {
      $m = [regex]::Match($p.CommandLine, '([A-Za-z]:\\[^"'']*?)\.minimax-code\\')
      if ($m.Success) {
        $root = $m.Groups[1].Value + $MINIMAX_CODE
        if (Test-Path $root) { return $root }
      }
    } catch {}
  }

 # 3) $env:USERPROFILE/.minimax-code
  if ($env:USERPROFILE) {
    $candidate = Join-Path $env:USERPROFILE $MINIMAX_CODE
    if (Test-Path $candidate) { return $candidate }
  }

 # 4) $env:USERPROFILE/AppData/Roaming/minimax-code/.minimax-code
  if ($env:APPDATA) {
    $candidate = Join-Path (Join-Path $env:APPDATA 'minimax-code') $MINIMAX_CODE
    if (Test-Path $candidate) { return $candidate }
  }

 # 5) <cwd>/.minimax-code
  try {
    $cwd = (Get-Location).Path
    $candidate = Join-Path $cwd $MINIMAX_CODE
    if (Test-Path $candidate) { return $candidate }
  } catch {}

  return $null
}

# sessions mcode fallback userprofile
function Get-SessionsRoot($mcodeRoot) {
  if ($mcodeRoot) {
 # .minimax-code .minimax <userprofile>
    $parent = Split-Path -Parent $mcodeRoot
    $candidate = Join-Path $parent (Join-Path '.minimax' (Join-Path 'v2' 'sessions'))
    if (Test-Path $candidate) { return $candidate }
  }
  if ($env:USERPROFILE) {
    $candidate = Join-Path $env:USERPROFILE $V2_SESSIONS_REL
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

$script:optRoot = $Root
$mcodeRoot = Find-McodeRoot
if (-not $mcodeRoot) {
  Write-Error "Cannot find mcode install root (.minimax-code). Pass -Root or ensure mcode is running."
  exit 2
}
$mcodeActiveDir = Join-Path $mcodeRoot $ACTIVE_DIR
$sessionsRoot   = Get-SessionsRoot $mcodeRoot
if (-not (Test-Path $mcodeActiveDir)) {
  Write-Warning ".mcode-active not found at $mcodeActiveDir - mcode not running or different layout"
}

$script:lastDetectedState = ''
$script:lastMsgsSnapshot  = @{ mtime = ''; lastInferred = $null }

# 5s mcode PID + session log
# Get-McodePid / Get-LatestSessionFile Get-ChildItem
# cmdletPS 5.1 hidden window Runspace 9
# poll widget
$CACHE_TTL = [TimeSpan]::FromSeconds(5)
$script:lastMcodePid     = $null
$script:lastMcodePidAt   = [DateTime]::MinValue
$script:lastLatestFile   = $null
$script:lastLatestFileAt = [DateTime]::MinValue

# island.log round-20
# island.log Add-Content 2026-08-22
# 38 18MB session log
# $logKeepLines
# Add-Content O(1)
# 1/4 stat 400ms
$script:logMaxBytes   = 1MB
$script:logKeepLines  = 300
$script:logPending    = 0

function Log-Line($msg) {
  $ts = (Get-Date).ToString('HH:mm:ss')
  $line = "[$ts] [detect] $msg"
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  $script:logPending += $line.Length + 2
  if ($script:logPending -ge [int]($script:logMaxBytes / 4)) {
    $script:logPending = 0
    try {
      $fi = Get-Item -LiteralPath $logFile -ErrorAction Stop
      if ($fi.Length -gt $script:logMaxBytes) {
        $keep = @(Get-Content -LiteralPath $logFile -Tail $script:logKeepLines -Encoding UTF8)
        [System.IO.File]::WriteAllLines(
          $logFile, $keep, (New-Object System.Text.UTF8Encoding($false)))
      }
    } catch {
    }
  }
  if (-not $Once) { Write-Output $line }
}

function Get-McodePid {
  if (-not (Test-Path $mcodeActiveDir)) { return $null }
 # Use [System.IO.Directory]::EnumerateFiles instead of Get-ChildItem + foreach
 # to avoid the PS 5.1 pipeline-thread leak that built up over multi-hour
 # runs and eventually stalled the detector. See: ~30k leaked threads
 # observed after 9h of polling.
  $bestPid = $null
  $bestMtime = [DateTime]::MinValue
  foreach ($f in [System.IO.Directory]::EnumerateFiles($mcodeActiveDir, '*.json')) {
    try {
      $raw = [System.IO.File]::ReadAllText($f)
      $j = $raw | ConvertFrom-Json
      $targetPid = [int]$j.pid
      $proc = [System.Diagnostics.Process]::GetProcessById($targetPid)
      if ($proc -and -not $proc.HasExited) {
 # .mcode-active dir is tiny (one or two .json files); prefer the most
 # recently started one if multiple happen to exist.
        $mtime = [System.IO.File]::GetLastWriteTime($f)
        if ($mtime -gt $bestMtime) {
          $bestMtime = $mtime
          $bestPid = $targetPid
        }
      }
    } catch {}
  }
  return $bestPid
}

function Get-LatestSessionFile {
  if (-not $sessionsRoot -or -not (Test-Path $sessionsRoot)) { return $null }
 # Replace Get-ChildItem -Recurse | Where-Object | Sort-Object | Select-Object
 # (a 4-stage pipeline) with a single .NET enumeration + manual mtime scan.
 # Same reason as Get-McodePid: avoid the PS 5.1 pipeline-thread leak.
  $best = $null
  $bestMtime = [DateTime]::MinValue
  $bestIsLedger = $false
  foreach ($f in [System.IO.Directory]::EnumerateFiles($sessionsRoot, '*.jsonl', 'AllDirectories')) {
    $name = [System.IO.Path]::GetFileName($f)
    $isLedger = ($name -eq $FNAME_LEDGER)
    $isMsgs   = ($name -eq $FNAME_MESSAGES)
    if (-not $isLedger -and -not $isMsgs) { continue }
    try {
      $mtime = [System.IO.File]::GetLastWriteTime($f)
    } catch {
      continue
    }
 # mcode v0.2.x writes messages.jsonl live; ledger.jsonl is best-effort
 # and may be left behind by an old session. Always pick whichever file
 # is most recently touched, otherwise a stale ledger would dominate
 # and the 60s-idle fallback would fire against ancient timestamps.
    if ($mtime -gt $bestMtime) {
      $bestMtime = $mtime
      $best = $f
      $bestIsLedger = $isLedger
    }
  }
  return $best
}

function Read-LastMessage($file) {
  if (-not $file) { return $null }
  try {
    $fi = [System.IO.FileInfo]::new($file)
    $mtime = $fi.LastWriteTime.ToString($FMT_O_FULL)
    if ($script:lastMsgsSnapshot.mtime -eq $mtime) {
 # mtime idle
      return $script:lastMsgsSnapshot.lastInferred
    }
    $script:lastMsgsSnapshot.mtime = $mtime
    $fs = [System.IO.File]::Open($fi.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $len = $fs.Length
      if ($len -eq 0) { return $null }
      $lookback = [Math]::Min($len, 65536)
      $fs.Seek(-$lookback, [System.IO.SeekOrigin]::End) | Out-Null
      $buf = New-Object byte[] $lookback
      $fs.Read($buf, 0, $lookback) | Out-Null
      $text = [System.Text.Encoding]::UTF8.GetString($buf)
      $parts = $text -split "`n"
      for ($i = $parts.Length - 1; $i -ge 0; $i--) {
        $line = $parts[$i].TrimEnd("`r")
        if ($line -and $line.Length -gt 10) {
 # ConvertFrom-Json is gated by the mtime cache above, so this
 # pipeline only fires when the file actually grew. Acceptable.
          $msg = ($line | ConvertFrom-Json)
          $script:lastMsgsSnapshot.lastInferred = $msg
          return $msg
        }
      }
      return $null
    } finally {
      $fs.Close()
    }
  } catch {
    return $script:lastMsgsSnapshot.lastInferred
  }
}

# Normalize a tool name to the key shape used by $TOOL_ACTIONS
# (mcode's own Wt(): trim, lowercase, '-' -> '_'). Untrusted agent-supplied
# strings, so guard the length: a 4KB "tool name" must not become a map key.
function Get-ToolKey($name) {
  if (-not $name) { return '' }
  $n = ([string]$name).Trim().ToLowerInvariant().Replace('-', '_')
  if ($n.Length -gt 64) { $n = $n.Substring(0, 64) }
  return $n
}

# Resolve the action verb for a tool in a given phase.
# phase: 'running' | 'done' | 'fail'
# Returns '' for an unknown tool so callers can fall back to the raw name.
function Get-ToolVerb($name, $phase) {
  $key = Get-ToolKey $name
  if (-not $key) { return '' }
  $entry = $TOOL_ACTIONS[$key]
  if (-not $entry) { return '' }
  switch ($phase) {
    'running' { return [string]$entry.running }
    'done'    { return [string]$entry.done }
    'fail'    { return [string]$entry.fail }
  }
  return ''
}

# Verb for an unknown tool: "Using <name>" / "Used <name>", so the pill
# never falls back to a bare identifier with no signal about the phase.
function Get-ToolVerbFallback($name, $phase) {
  $key = Get-ToolKey $name
  if (-not $key) { return '' }
  if ($phase -eq 'running') { return "$TOOL_FALLBACK_RUNNING $key" }
  return "$TOOL_FALLBACK_DONE $key"
}

function Get-ToolFamily($name) {
  $key = Get-ToolKey $name
  if (-not $key) { return $null }
  $fam = $TOOL_FAMILIES[$key]
  if ($fam) { return [string]$fam }
  return $null
}

# Human-readable one-liner for a tool's arguments (round-20 #6).
# The running-state message used to be built as
# "$verb " + (ConvertTo-Json $args -Compress) truncated to 60 chars
# which put this on an always-on-top, one-line pill:
# Running {"command":"$ErrorActionPreference=\u0027Continue\u0027\n...
# Escaped quotes, a JSON key, and a truncation that can land mid-token.
# `skill` is not in $TOOL_ACTIONS or $TOOL_FAMILIES, so it always took
# that path -- one of the most frequent tools on screen was also the
# least readable.
# Contract: return the single most informative field for the tool, or ''
# when there is nothing worth showing. Callers render the verb alone in
# that case. Raw JSON is never returned -- there is no fallback to it.
# Unknown tools get a generic sweep of the common field names before
# giving up, because the tool taxonomy is hand-maintained and does not
# cover every tool mcode ships.
# NB: the second parameter must NOT be called `$args`. That name is a
# reserved automatic variable in PowerShell, and binding a parameter to
# it yields the unbound-argument Object[] rather than the object passed in
# -- verified: `function T($n, $args) { $args.command }` called with
# `[PSCustomObject]@{command='npm test'}` returns an empty string, because
# the parameter arrives as Object[]. Symptom is a summary that is empty for
# every single tool, which looks like "no data" rather than "bad binding".
function Format-ToolArgs($name, $toolArgs) {
  if (-not $toolArgs) { return '' }
  $key  = ([string]$name).ToLowerInvariant()
  $raw  = ''
  switch ($key) {
    'bash'          { $raw = [string]$toolArgs.command }
    'shell'         { $raw = [string]$toolArgs.command }
    'read'          { $raw = [string]$toolArgs.file_path }
    'write'         { $raw = [string]$toolArgs.file_path }
    'edit'          { $raw = [string]$toolArgs.file_path }
    'notebookedit'  { $raw = [string]$toolArgs.notebook_path }
    'grep'          { $raw = [string]$toolArgs.pattern }
    'glob'          { $raw = [string]$toolArgs.pattern }
    'list'          { $raw = [string]$toolArgs.path }
    'search'        { $raw = [string]$toolArgs.query }
    'web_search'    { $raw = [string]$toolArgs.query }
    'web_fetch'     { $raw = [string]$toolArgs.url }
    'skill'         { $raw = [string]$toolArgs.name }
    'task'          { $raw = [string]$toolArgs.description }
    'task_output'   { $raw = [string]$toolArgs.task_id }
    'task_append'   { $raw = [string]$toolArgs.task_id }
    'task_query'    { $raw = [string]$toolArgs.task_id }
    default {
      foreach ($f in 'name','command','file_path','path','pattern','query','url','description','task_id') {
        if ($toolArgs.PSObject.Properties[$f]) {
          $v = [string]$toolArgs.$f
          if (-not [string]::IsNullOrWhiteSpace($v)) { $raw = $v; break }
        }
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($raw)) { return '' }

 # The pill is a single line, and an agent command is usually a short
 # script rather than one line. Prefer the first line that actually
 # EXECUTES something over the first line that merely sets the stage.
 # `$ErrorActionPreference='Continue'` is the opening line of most agent
 # commands and says nothing about what is being worked on; reading it
 # off a status pill is indistinguishable from the pill being stuck. The
 # first real command below it -- `npm test`, `Get-ChildItem` -- is the
 # line the user actually wants.
  $fallback = ''
  $first = ''
  foreach ($ln in ($raw -split "`r?`n")) {
    $t = $ln.Trim()
    if ($t -eq '') { continue }
    if ($fallback -eq '') { $fallback = $t }
    if ($t.StartsWith('#')) { continue }   # comment
    if ($t.StartsWith('$')) { continue }   # variable assignment / preference set
    $first = $t
    break
  }
 # Every line was boilerplate. Showing the assignment beats showing nothing.
  if ($first -eq '') { $first = $fallback }
  if ([string]::IsNullOrWhiteSpace($first)) { return '' }

 # cannot reach the pill or island.log through this route either.
  $first = Protect-SecretText $first
  $first = ($first -replace '\s+', ' ').Trim()
  if ($first.Length -gt 60) { $first = $first.Substring(0, 57) + $DOTS }
  return $first
}

# ask_user is the one tool whose "in flight" state means the agent is BLOCKED,
# not busy. When the questionnaire pops, nothing progresses until the user
# comes back and answers. Reporting it as `working` tells the user "leave it
# alone, it's making progress", which is the opposite of the truth -- so it
# count, because "Asking 2 questions" is exactly the "come back" signal.
# Returns $null for every other tool, so the caller can fall through to the
# normal verb lookup.
function Test-IsAskUser($name) {
  return ((Get-ToolKey $name) -eq 'ask_user')
}

function Get-AskQuestionCount($toolArgs) {
 # Parameter is deliberately NOT named $args: that is a PowerShell automatic
 # variable, and shadowing it makes every read inside the function return the
 # function's own argument list instead of the caller's value. It silently
 # produced a count of 0 for every input, which degraded the message to a
 # bare "Asking".
  if (-not $toolArgs) { return 0 }
  try {
    $a = $toolArgs
    if ($a -is [string]) { $a = $a | ConvertFrom-Json -ErrorAction Stop }
    $qs = $a.PSObject.Properties['questions']
    if (-not $qs -or $null -eq $qs.Value) { return 0 }
    return @($qs.Value).Count
  } catch { return 0 }
}

function Infer-State($msg) {
  if (-not $msg) { return $null }
 # ledger.jsonl {kind, phase, action, ...}
 # messages.jsonl {message: {role, content, ...}, ...}
  $m = $msg.message
  if (-not $m) {
 # ledger kind/phase
    $kind = [string]$msg.kind
    $phase = [string]$msg.phase
    if ($kind -eq $S_TOOLRESULT) {
      $tv = [string]$msg.toolName
      if ($msg.isError -eq $true) {
        $verb = Get-ToolVerb $tv 'fail'
        if (-not $verb) { $verb = Get-ToolVerbFallback $tv 'fail' }
        return @{ state=$S_ERROR; message=$verb; family=$null }
      }
      $verb = Get-ToolVerb $tv 'done'
      if (-not $verb) { $verb = Get-ToolVerbFallback $tv 'done' }
      return @{ state=$S_DONE; message=$verb; family=(Get-ToolFamily $tv) }
    }
    if ($kind -eq 'toolCall' -or $kind -eq $S_TOOLCALL) {
      $tv = [string]$msg.toolName
      if (Test-IsAskUser $tv) {
        $n = Get-AskQuestionCount $msg.arguments
        if ($n -gt 0) { return @{ state=$S_WAITING; message="Asking $n question$(if ($n -gt 1) { 's' })"; family=$null } }
        return @{ state=$S_WAITING; message='Asking'; family=$null }
      }
      $verb = Get-ToolVerb $tv 'running'
      if (-not $verb) { $verb = Get-ToolVerbFallback $tv 'running' }
      $detail = [string]$msg.action
      if ($detail) { return @{ state=$S_WORKING; message="$verb $detail"; family=(Get-ToolFamily $tv) } }
      return @{ state=$S_WORKING; message=$verb; family=(Get-ToolFamily $tv) }
    }
    if ($kind -eq $S_ASSISTANT -and $phase -eq $S_THINKING) {
      return @{ state=$S_THINKING; message='' }
    }
    return $null
  }

  $role = [string]$m.role
  if ($role -eq $S_USER) { return @{ state=$S_IDLE; message=$MSG_USER_WAIT } }

  if ($role -eq $S_ASSISTANT) {
 # Use .Where({}) method on the collection instead of | Where-Object ...
 # | Select-Object pipelines: each pipeline is a thread-pool hop on
 # PS 5.1 and the completed tasks accumulate over hours-long runs.
    $hasTool  = $null
    $hasThink = $null
    $hasText  = $null
    if ($m.content) {
      foreach ($c in @($m.content)) {
        if     ($hasTool  -eq $null -and $c.type -eq $S_TOOLCALL)  { $hasTool  = $c }
        elseif ($hasThink -eq $null -and $c.type -eq $S_THINK_BLK) { $hasThink = $c }
        elseif ($hasText  -eq $null -and $c.type -eq $S_TEXT)      { $hasText  = $c }
        if ($hasTool) { break }   # toolCall wins; we can stop scanning
      }
    }

    if ($hasTool) {
      $tool  = $hasTool.name
      $args  = $hasTool.arguments
      if (Test-IsAskUser $tool) {
        $n = Get-AskQuestionCount $args
        if ($n -gt 0) { return @{ state=$S_WAITING; message="Asking $n question$(if ($n -gt 1) { 's' })"; family=$null } }
        return @{ state=$S_WAITING; message='Asking'; family=$null }
      }
      $verb  = Get-ToolVerb $tool 'running'
      if (-not $verb) { $verb = Get-ToolVerbFallback $tool 'running' }
 # Readable summary, never raw JSON (round-20 #6). When there is
 # nothing worth showing the pill wears the bare verb, which reads
 # fine -- "Using" beats "Using {\"name\":\"...\"}".
      $summary = Format-ToolArgs $tool $args
      if ($summary) {
        return @{ state=$S_WORKING; message="$verb $summary"; family=(Get-ToolFamily $tool) }
      }
      return @{ state=$S_WORKING; message=$verb; family=(Get-ToolFamily $tool) }
    }
    if ($hasThink -and -not $hasText) { return @{ state=$S_THINKING; message='' } }
    if ($hasText) { return @{ state=$S_IDLE; message=$MSG_AGENT_DONE } }
    return @{ state=$S_IDLE; message='' }
  }

  if ($role -eq $S_TOOLRESULT) {
    $tool  = $m.toolName
    $isErr = $m.isError -eq $true
    if ($isErr) {
      $verb = Get-ToolVerb $tool 'fail'
      if (-not $verb) { $verb = Get-ToolVerbFallback $tool 'fail' }
      return @{ state=$S_ERROR; message=$verb; family=$null }
    }
    $verb = Get-ToolVerb $tool 'done'
    if (-not $verb) { $verb = Get-ToolVerbFallback $tool 'done' }
    return @{ state=$S_DONE; message=$verb; family=(Get-ToolFamily $tool) }
  }

  if ($role -eq $S_COMPACTION) { return @{ state=$S_IDLE; message=$MSG_COMPACT } }

  return $null
}

function Write-Status($state, $message, $family, [switch]$KeepSubStep) {
  $tmp = "$statusFile.tmp"
 # usage5h0..100 ""null = /
 # usage5hResetMsnull =
 # todoProgress0..100 cancelled null = todo
 # familyshell/read/write/search/task/web/plannull =
  $usageField  = if ($null -ne $script:plan5hRemainingPct) { [int]$script:plan5hRemainingPct } else { $null }
  $resetField  = if ($null -ne $script:plan5hResetMs)     { [int]$script:plan5hResetMs }     else { $null }
  $todoPct     = if ($null -ne $script:plan5hTodoData)    { [int]$script:plan5hTodoData.percent } else { $null }
  $todoCnt     = if ($null -ne $script:plan5hTodoData)    { ("{0}/{1}" -f $script:plan5hTodoData.completed, $script:plan5hTodoData.total) } else { $null }
  $famField    = if ($family) { [string]$family } else { $null }
 # detector payload ""
 # round-20 #5
 # - -KeepSubStep 60s 5h todo
 # state/message status.json
 # "agent " sub-step
 # round-19 #2
 # - detector session log
 # sub-step pill
 # agent pill
 # "step 1/1" curl
  $stepField   = -1
  $totalField  = -1
  $detailField = ''
 # `source` is the arbitration token, not a label (round-20 #7). The
 # detector's settle logic reads `source == detector` as "this state is
 # mine to rewrite". A metadata refresh restates the current state and
 # refreshed numbers -- it does not claim the state -- so stamping
 # `detector` on it silently hands write authority back to the detector.
 # Observed consequence: a tool fails, the detector infers `error`, the
 # 5h-usage refresh stamps `detector` over it. From then on the detector
 # owns the state and re-derives `error` from the same stale failed
 # sat on "Command failed" until the 60s no-event fallback finally
 # dropped it to idle.
  $sourceField = $S_DETECTOR
  if ($KeepSubStep) {
    $prev = Read-StatusObj
    if ($prev) {
      if ($prev.PSObject.Properties['step'])   { $stepField   = [int]$prev.step }
      if ($prev.PSObject.Properties['total'])  { $totalField  = [int]$prev.total }
      if ($prev.PSObject.Properties['detail'] -and $null -ne $prev.detail) { $detailField = [string]$prev.detail }
      if ($prev.PSObject.Properties['source'] -and $prev.source) { $sourceField = [string]$prev.source }
    }
  }
  $payload = [PSCustomObject]@{
    state          = $state
    message        = $message
    family         = $famField
    progress       = -1
    usage5h        = $usageField
    usage5hResetMs = $resetField
    todoProgress   = $todoPct
    todosCount     = $todoCnt
    step           = $stepField
    total          = $totalField
    detail         = $detailField
    ts             = (Get-Date).ToString($FMT_O)
    source         = $sourceField
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($tmp, $payload, [System.Text.Encoding]::UTF8)
  Move-Item -Path $tmp -Destination $statusFile -Force
}

# Get-5hUsage scripts/lib/Get-5hUsage.ps1detector dot-source .
# lib windows-latest CI mcode runner 5h usage
# round-9 dot-source init install-root
# CI "Cannot find mcode install root"
# fixture model_name / current_interval_remaining_percent /
# remains_time lib CI step 4
# Get-5hUsage null fail

# 60s TTL
function Refresh-5hUsage {
  $now = Get-Date
  if (($now - $script:plan5hLastCallAt) -lt $PLAN_API_TTL) { return }
  $script:plan5hLastCallAt = $now
  $data = Get-5hUsage
  if ($null -eq $data) {
    $script:plan5hRemainingPct = $null
    $script:plan5hResetMs = $null
  } else {
    $script:plan5hRemainingPct = [int]$data.remainingPct
    $script:plan5hResetMs = [int]$data.resetMs
  }
}

# todowrite todos
# mtime mcode 1 todo
function Get-TodoProgress {
  $latest = $script:lastLatestFile
  if (-not $latest -or -not (Test-Path $latest)) { return $null }

  $mtime = [System.IO.File]::GetLastWriteTimeUtc($latest)
  if ($mtime -eq $script:plan5hTodoCacheMtime -and $null -ne $script:plan5hTodoData) {
    return $script:plan5hTodoData
  }
  $script:plan5hTodoCacheMtime = $mtime

  try {
 # toolName=todowrite role=toolResult
    $lines = [System.IO.File]::ReadAllLines($latest, [System.Text.Encoding]::UTF8)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      $line = $lines[$i]
      if ($line.IndexOf('"toolName":"todowrite"', [System.StringComparison]::Ordinal) -lt 0) { continue }
      if ($line.IndexOf('"role":"toolResult"', [System.StringComparison]::Ordinal) -lt 0) { continue }
      $j = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
      if (-not $j -or -not $j.message -or -not $j.message.details -or -not $j.message.details.todos) { continue }
      $todos = @($j.message.details.todos)
      $total = $todos.Count
      $done = 0; $cancelled = 0
      foreach ($t in $todos) {
        if ($t.status -eq 'completed')  { $done++ }
        if ($t.status -eq 'cancelled')  { $cancelled++ }
      }
      $effective = $total - $cancelled
      if ($effective -le 0) {
        $script:plan5hTodoData = $null
        return $null
      }
      $percent = [int][Math]::Floor(($done * 100) / $effective)
      $script:plan5hTodoData = @{
        percent   = $percent
        completed = $done
        total     = $total
      }
      return $script:plan5hTodoData
    }
 # = todowrite
    $script:plan5hTodoData = $null
    return $null
  } catch {
    return $null
  }
}

function Read-StatusObj {
  if (!(Test-Path $statusFile)) { return $null }
  try { return ([System.IO.File]::ReadAllText($statusFile) | ConvertFrom-Json) } catch { return $null }
}

if (-not $Once) {
  Set-Content -Path $pidFile -Value $PID -Encoding ASCII
  Log-Line "detector started (PID $PID) mcodeRoot=$mcodeRoot"
}

try {
  while ($true) {
 # --- per-tick guard -------------------------------------------------------
 # This loop had no catch: any terminating error (malformed status.json, a
 # WMI/CIM hiccup, a locked file, a bad cast in the todo parser) escaped the
 # loop, fired the finally block, logged "detector stopped" and exited the
 # process. The widget kept running, so the pill just froze on the last
 # status.json with no visible cause -- status.json silently stopped
 # changing while widget.log kept logging TOPMOST re-raises. Log the real
 # message and retry on the next tick instead of dying.
 # Indentation is intentionally flat here so the diff stays reviewable.
   try {
    $now = Get-Date
    $inferred = $null
    $latestFile = $null

 # 1) mcode 5s Get-ChildItem + Get-Process
    if (($now - $script:lastMcodePidAt) -lt $CACHE_TTL) {
      $mcodePid = $script:lastMcodePid
    } else {
      $mcodePid = Get-McodePid
      $script:lastMcodePid = $mcodePid
      $script:lastMcodePidAt = $now
    }
    if (-not $mcodePid) {
      $inferred = @{ state=$S_ERROR; message=$MSG_MCODE_EXIT }
    } else {
 # 2) session log5s EnumerateFiles .jsonl
      if (($now - $script:lastLatestFileAt) -lt $CACHE_TTL) {
        $latestFile = $script:lastLatestFile
      } else {
        $latestFile = Get-LatestSessionFile
        $script:lastLatestFile = $latestFile
        $script:lastLatestFileAt = $now
      }
      if ($latestFile) {
        $msg = Read-LastMessage $latestFile
        if ($msg) {
          $inferred = Infer-State $msg
        }
      }
    }

 # 3) 60s idle mtime
 # `waiting` ask_user agent
 # session log60s " 60s"
    if ($inferred -and $latestFile) {
      $curState = [string]$inferred.state
      $isSettled = ($curState -eq $S_IDLE) -or ($curState -eq $S_ERROR) -or ($curState -eq $S_WAITING)
      if (-not $isSettled) {
        $age = ($now - [System.IO.File]::GetLastWriteTime($latestFile)).TotalSeconds
        if ($age -gt 60) {
          $inferred = @{ state=$S_IDLE; message=($MSG_IDLE_FMT -f [int]$age) }
        }
      }
    }

    if ($inferred) {
      $cur = Read-StatusObj
      $curSource = if ($cur) { [string]$cur.source } else { '' }
      $curState  = if ($cur) { [string]$cur.state  } else { '' }
      $newState  = [string]$inferred.state
      $newMsg    = [string]$inferred.message

      $isOwn = ($curSource -eq $S_DETECTOR)
      $stateChanged = ($curState -ne $newState)
 # `working`detector session log `waiting` waiting
 # settledetector status.jsonpill
      $isSettleNew  = ($newState -eq $S_IDLE) -or ($newState -eq $S_ERROR) -or ($newState -eq $S_WAITING)

      $shouldWrite = $false
      $reason = ''

      if (-not $cur) {
        $shouldWrite = $true
        $reason = $R_NO_CURRENT
      } elseif ($isOwn -and $stateChanged) {
        $shouldWrite = $true
        $reason = $R_OWN_CHANGED
      } elseif ($isOwn -and ($cur.message -ne $newMsg) -and $newMsg) {
        $shouldWrite = $true
        $reason = $R_OWN_MSG
      } elseif (-not $isOwn -and $isSettleNew) {
        $shouldWrite = $true
        $reason = $R_TAKEOVER
      }

      if ($shouldWrite) {
        Write-Status $inferred.state $inferred.message $inferred.family
        if ($script:lastDetectedState -ne $newState) {
          Log-Line "$newState :: $newMsg ($reason)"
          $script:lastDetectedState = $newState
        }
      }
    }

 # 4) 5h 60s status.json widget
    $prevPct  = $script:plan5hRemainingPct
    $prevMs   = $script:plan5hResetMs
    Refresh-5hUsage
    $curPct   = $script:plan5hRemainingPct
    $curMs    = $script:plan5hResetMs
    $usageChanged = ($prevPct -ne $curPct) -or ($prevMs -ne $curMs) -and ($null -ne $curPct)
    if ($usageChanged) {
      $curForUsage = Read-StatusObj
      $sForU = if ($curForUsage) { [string]$curForUsage.state } else { $S_IDLE }
      $mForU = if ($curForUsage) { [string]$curForUsage.message } else { '' }
      $fForU = if ($curForUsage -and $curForUsage.PSObject.Properties['family']) { $curForUsage.family } else { $null }
 # sub-step-KeepSubStep
      Write-Status $sForU $mForU $fForU -KeepSubStep
      Log-Line ("5h usage refreshed: remaining=" + $curPct + "% resetMs=" + $curMs)
    }

 # 5) Todo mtime status.json
    $prevTodoPct  = $script:plan5hLastWrittenTodoPct
    $curTodoData  = Get-TodoProgress
    $curTodoPct   = if ($null -ne $curTodoData) { $curTodoData.percent } else { $null }
    $todoChanged  = ($prevTodoPct -ne $curTodoPct)
    if ($todoChanged) {
      $curForTodo = Read-StatusObj
      $sForT = if ($curForTodo) { [string]$curForTodo.state } else { $S_IDLE }
      $mForT = if ($curForTodo) { [string]$curForTodo.message } else { '' }
      $fForT = if ($curForTodo -and $curForTodo.PSObject.Properties['family']) { $curForTodo.family } else { $null }
 # sub-step-KeepSubStep
      Write-Status $sForT $mForT $fForT -KeepSubStep
      $script:plan5hLastWrittenTodoPct = $curTodoPct
      if ($null -ne $curTodoData) {
        Log-Line ("todo refreshed: " + $curTodoData.completed + "/" + $curTodoData.total + " = " + $curTodoPct + "%")
      } else {
        Log-Line "todo refreshed: (none)"
      }
    }

    if ($Once) { break }
    Start-Sleep -Milliseconds 1000
   } catch {
 # Log the exception type too: "loop error" alone would not tell us whether
 # this is a JSON parse, a WMI failure or an IO lock. Truncate so a runaway
 # error cannot flood island.log every tick.
    $msg = $_.Exception.GetType().Name + ': ' + $_.Exception.Message
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
    Log-Line ('loop error (retrying): ' + $msg)
    if ($Once) { break }
    Start-Sleep -Milliseconds 1000
   }
  }
} finally {
  if (-not $Once -and (Test-Path $pidFile)) {
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  }
  $STOPPED_MSG = _s (0x64,0x65,0x74,0x65,0x63,0x74,0x6F,0x72,0x20,0x73,0x74,0x6F,0x70,0x70,0x65,0x64)
  Log-Line $STOPPED_MSG
}
