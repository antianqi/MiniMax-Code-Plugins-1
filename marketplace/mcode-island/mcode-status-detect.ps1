# mcode-status-detect.ps1 - background state detector
# Reads the local MiniMax Code session log, infers the agent state and
# writes it to status.json, so the widget keeps moving even when the agent
# does not push a state itself.
# Path resolution (in order):
# 1. explicit -Root override
# 2. the desktop data directory: $env:MINIMAX_DATA_DIR, or
# <userprofile>/.minimax
# 3. <userprofile>
# Session log (in order):
# 1. <dataDir>/v2/sessions/<date>/*/ledger.jsonl (preferred, v2 event stream)
# 2. <dataDir>/v2/sessions/<date>/*/messages.jsonl (fallback)
# State mapping:
# role=user -> idle (waiting for the user)
# role=assistant + toolCall -> working "<tool>: <args>"
# role=assistant + thinking -> thinking
# role=assistant + text -> idle (replied, waiting for the user)
# role=toolResult + !isError -> done "<tool> done"
# role=toolResult + isError -> error "<tool> failed"
# 60s without a new event -> idle (fallback)
# Precedence:
# a state pushed by the agent (source != detector) is kept
# the detector may override it with idle / error (fallback)
# the detector never overrides working / thinking / done


param(
  [switch]$Once,
  [string]$Root = ''    # override: the directory that holds .minimax/v2/sessions
)

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


# role names
$S_USER       = 'user'
$S_ASSISTANT  = 'assistant'
$S_TOOLRESULT = 'toolResult'
$S_COMPACTION = 'compactionSummary'
# state values
$S_IDLE     = 'idle'
$S_THINKING = 'thinking'
$S_WORKING  = 'working'
$S_WAITING  = 'waiting'
$S_DONE     = 'done'
$S_ERROR    = 'error'
# content type discriminators
$S_TOOLCALL  = 'toolCall'
$S_TEXT      = 'text'
$S_THINK_BLK = 'thinking'
# source tag
$S_DETECTOR  = 'detector'
# messages (UTF-8 encoded Chinese)
$MSG_USER_WAIT  = 'Waiting for you'
$MSG_AGENT_DONE = 'agent replied, waiting for you' # agent
$MSG_COMPACT    = 'session compacted' # session
$MSG_IDLE_FMT   = 'Idle {0}s' # {0}s
$DOTS            = '...'                                                # ...
$FMT_O           = 'o'                                                           # 'o' (ISO 8601 timestamp)
$FMT_O_FULL      = 'O'                                                           # 'O' (ISO 8601 full)
# log reason tags
$R_NO_CURRENT    = 'no current status'
$R_OWN_CHANGED   = 'own state changed'
$R_OWN_MSG       = 'own message changed'
$R_TAKEOVER      = 'takeover to settle'
# session log file names ( ledger)
$FNAME_LEDGER    = 'ledger.jsonl'   # ledger.jsonl
$FNAME_MESSAGES  = 'messages.jsonl'  # messages.jsonl
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
$TOOL_FALLBACK_RUNNING = 'Using'   # Using
$TOOL_FALLBACK_DONE    = 'Used'         # Used
# v2 sessions relative to user profile
$V2_SESSIONS_REL = '.minimax\v2\sessions'  # .minimax\v2\sessions

$configDir = Join-Path $env:APPDATA 'mcode-island'
if (!(Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
# status.json store Get-StatusFilePath
$logFile    = Join-Path $configDir 'island.log'
$pidFile    = Join-Path $configDir 'detect.pid'
$cfgFile    = Join-Path $configDir 'config.json'


# Shared redaction helper (round-20). The detector is the SECOND producer
# of tool text -- it re-derives messages from mcode's session log rather
. "$PSScriptRoot/scripts/lib/Protect-Text.ps1"
. "$PSScriptRoot/scripts/lib/Plan-Usage.ps1"
# Cross-process status.json protocol (round-21 review #1).
# both write status.json. They had no mutual exclusion: the detector
# the lock, the single snapshot read and the atomic replace, so both
# sides follow one protocol.
. "$PSScriptRoot/scripts/lib/Status-Store.ps1"
# session v0.5.0
# pill session Get-LatestSessionFile
# " " pill lib
# session / /
# sessions.json status.json agent
# $script: dot-source lib
. "$PSScriptRoot/scripts/lib/Session-Tracker.ps1"
$script:plan5hLastCallAt = [DateTime]::MinValue
$script:plan5hRemainingPct = $null # 0..100
$script:plan5hResetMs = $null

# Todo widget completed / (total - cancelled) * 100
$script:plan5hTodoData = $null      # @{ percent; currentTodo; completed; total }
$script:plan5hTodoCacheMtime = [DateTime]::MinValue
$script:plan5hLastWrittenTodoPct = $null # status.json todoProgress

# MiniMax Code
# MiniMax Code app
# <dataDir>/v2/sessions <dataDir>
# MINIMAX_DATA_DIR
# MiniMax Code CLI CLI node
# cmdline CLI null
# detector exit 2
function Find-McodeRoot {
 # 1) -Root
  if ($script:optRoot -and (Test-Path $script:optRoot)) { return $script:optRoot }

 # 2)
  foreach ($dataDir in Get-DataDirs) {
    if (Test-Path (Join-Path $dataDir 'v2\sessions')) {
      $parent = Split-Path -Parent $dataDir
      if ($parent) { return $parent }
    }
  }

 # 3)
  if ($env:USERPROFILE) { return $env:USERPROFILE }

  return $null
}

function Get-DataDirs {
  $dirs = @()
  if ($env:MINIMAX_DATA_DIR) { $dirs += $env:MINIMAX_DATA_DIR }
  if ($env:USERPROFILE) { $dirs += (Join-Path $env:USERPROFILE '.minimax') }
  return $dirs
}

# sessions
function Get-SessionsRoot($mcodeRoot) {
 # 1) <dataDir>/v2/sessions
  foreach ($dataDir in Get-DataDirs) {
    $candidate = Join-Path $dataDir 'v2\sessions'
    if (Test-Path $candidate) { return $candidate }
  }

 # 2) <userprofile>/.minimax/v2/sessions
  if ($env:USERPROFILE) {
    $candidate = Join-Path $env:USERPROFILE $V2_SESSIONS_REL
    if (Test-Path $candidate) { return $candidate }
  }

 # 3) .minimax/v2/sessions
  if ($mcodeRoot) {
    $parent = Split-Path -Parent $mcodeRoot
    $candidate = Join-Path $parent (Join-Path '.minimax' (Join-Path 'v2' 'sessions'))
    if (Test-Path $candidate) { return $candidate }
  }

  return $null
}

$script:optRoot = $Root
$mcodeRoot = Find-McodeRoot
$sessionsRoot   = Get-SessionsRoot $mcodeRoot
if (-not $sessionsRoot) {
  Write-Error "Cannot find the MiniMax Code session store (~/.minimax/v2/sessions). Set MINIMAX_DATA_DIR or pass -Root."
  exit 2
}

$script:lastDetectedState = ''
$script:lastMsgsSnapshot  = @{ path = ''; mtime = ''; lastInferred = $null }

# 5s session log
# Get-LatestSessionFile Get-ChildItem
# cmdlet PS 5.1 hidden window Runspace 9
# poll widget
$CACHE_TTL = [TimeSpan]::FromSeconds(5)
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

# Reads the last COMPLETE json line of a session log.
# The old implementation read a fixed 64 KB tail window and parsed the
# fragments backwards. One session-log line can be far bigger than that: an
# agent that reads a screenshot writes the base64 image into a single line
# (200 KB - 560 KB in the wild), and a big file read is just as fat. The
# window then held nothing but a fragment of that line, ConvertFrom-Json
# threw on it, and the catch-all returned the previously cached inference --
# which belonged to an earlier file, often an earlier conversation. The pill
# then showed the previous task's state for the whole new conversation.
# So the window grows until a line actually parses. Reading one fat line is
# cheap (a few hundred KB, once per change); reporting another session's
# state is not.
function Get-LastJsonLine($file) {
  $fi = [System.IO.FileInfo]::new($file)
  $len = $fi.Length
  if ($len -le 0) { return $null }
 # A single line is never allowed to pull more than 8 MB into memory.
  $cap = [Math]::Min($len, 8MB)
  $window = [Math]::Min($len, 65536)
  while ($window -le $cap) {
    $fs = $null
    try {
      $fs = [System.IO.File]::Open($fi.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      [void]$fs.Seek(-$window, [System.IO.SeekOrigin]::End)
      $buf = New-Object byte[] $window
      [void]$fs.Read($buf, 0, $window)
    } catch {
      return $null
    } finally {
      if ($fs) { $fs.Close() }
    }
    $text = [System.Text.Encoding]::UTF8.GetString($buf)
    $parts = $text -split "`n"
 # Walk backwards. Index 0 is the fragment the window cut into, so it is
 # only trustworthy when the whole file is inside the window.
    for ($i = $parts.Length - 1; $i -ge 1; $i--) {
      $line = $parts[$i].TrimEnd("`r")
      if (-not $line -or $line.Length -le 10) { continue }
      try { return ($line | ConvertFrom-Json) } catch { continue }
    }
    if ($window -ge $len) {
 # The whole file is here: the first fragment is a complete line too.
      $line = $parts[0].TrimEnd("`r")
      if ($line.Length -gt 10) {
        try { return ($line | ConvertFrom-Json) } catch { return $null }
      }
    }
    $next = $window * 2
    if ($next -gt $cap) { $next = $cap }
    if ($next -eq $window) { break }
    $window = $next
  }
  return $null
}

function Read-LastMessage($file) {
  if (-not $file) { return $null }
  try {
    $fi = [System.IO.FileInfo]::new($file)
    $mtime = $fi.LastWriteTime.ToString($FMT_O_FULL)
 # The cache is keyed on path AND mtime. Keying it on the mtime alone
 # let a session switch return the previous file's message, because two
 # files touched in the same tick share an mtime.
    if ($script:lastMsgsSnapshot.path -eq $file -and $script:lastMsgsSnapshot.mtime -eq $mtime) {
 # mtime idle
      return $script:lastMsgsSnapshot.lastInferred
    }
    $msg = Get-LastJsonLine $file
    $script:lastMsgsSnapshot.path = $file
    $script:lastMsgsSnapshot.mtime = $mtime
    $script:lastMsgsSnapshot.lastInferred = $msg
    return $msg
  } catch {
 # A file we cannot read right now (locked, mid-write) must not make us
 # report another session's state. Returning $null leaves the current
 # status untouched, which is the honest answer: "no new information".
    return $null
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

# Writes status.json.
# Two write semantics, and they must not be confused (round-20 #5, #7):
# - state inference (default): the detector inferred a new state from
# the session log and is asserting it. The sub-step counters are
# relationship to this message. `source` becomes `detector`, which
# is the arbitration token that lets the detector rewrite this
# state later.
# - metadata refresh (-MetadataRefresh): the 60s 5h-usage refresh and
# the todo-progress refresh. They restate the current state and
# refresh numbers; they do not claim the state. So state, message,
# family, the sub-step counters and `source` all come from the
# snapshot taken in this same call.
# Both run under one exclusive lock and take exactly ONE snapshot
# (round-21 review hetaoBackend #1). The previous version read the
# file twice -- once here for the sub-step fields and once at the call
# site for the state -- and then wrote the result back over the whole
# into a stale payload or lost outright.
function Write-Status($state, $message, $family, [switch]$MetadataRefresh) {
  $lock = Enter-StatusLock
  try {
    Write-StatusUnderLock $state $message $family -MetadataRefresh:$MetadataRefresh
  } finally {
    Exit-StatusLock $lock
  }
}

# The body of Write-Status, for callers that already hold the lock.
# Splitting it out is what lets the arbitration path read the snapshot
# and act on it without taking the lock twice: the lock is not
# re-entrant, because a nested take would deadlock against itself.
function Write-StatusUnderLock($state, $message, $family, [switch]$MetadataRefresh) {
 # usage5h 0..100 " " null = /
 # usage5hResetMs null =
 # todoProgress 0..100 cancelled null = todo
 # family shell/read/write/search/task/web/plan null =
  $usageField  = if ($null -ne $script:plan5hRemainingPct) { [int]$script:plan5hRemainingPct } else { $null }
  $resetField  = if ($null -ne $script:plan5hResetMs)     { [int]$script:plan5hResetMs }     else { $null }
  $todoPct     = if ($null -ne $script:plan5hTodoData)    { [int]$script:plan5hTodoData.percent } else { $null }
  $todoCnt     = if ($null -ne $script:plan5hTodoData)    { ("{0}/{1}" -f $script:plan5hTodoData.completed, $script:plan5hTodoData.total) } else { $null }

 # The one snapshot. Every field below is derived from it, so the
 # payload is always a single coherent generation.
  $prev = Read-StatusSnapshot

  $curState = $state
  $curMsg   = $message
  $famField = if ($family) { [string]$family } else { $null }

  if ($MetadataRefresh) {
    $curState = if ($prev) { [string]$prev.state } else { $S_IDLE }
    $curMsg   = if ($prev) { [string]$prev.message } else { '' }
 # A null family must stay null, not become an empty string: the
 # widget asks "is there a family to tint with", and "[string]$null"
 # would answer with a string that means the same thing to it but
 # changes the on-disk shape of the payload.
    $famField = if ($prev -and $prev.PSObject.Properties['family'] -and $null -ne $prev.family) { [string]$prev.family } else { $null }
  }

 # detector payload " "
 # round-20 #5
 # - -MetadataRefresh 60s 5h todo
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
  if ($MetadataRefresh -and $prev) {
    if ($prev.PSObject.Properties['step'])   { $stepField   = [int]$prev.step }
    if ($prev.PSObject.Properties['total'])  { $totalField  = [int]$prev.total }
    if ($prev.PSObject.Properties['detail'] -and $null -ne $prev.detail) { $detailField = [string]$prev.detail }
    if ($prev.PSObject.Properties['source'] -and $prev.source) { $sourceField = [string]$prev.source }
  }
  $payload = [PSCustomObject]@{
    state          = $curState
    message        = $curMsg
    family         = $famField
    progress       = -1
    usage5h        = $usageField
    usage5hResetMs = $resetField
    todoProgress   = $todoPct
    todosCount     = $todoCnt
    step           = $stepField
    total          = $totalField
    detail         = $detailField
    source         = $sourceField
  }
 # `ts` and the monotonic `version` are stamped by the store, from the
 # same snapshot this payload was built from.
  Write-StatusSnapshot -Payload $payload -Previous $prev
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

# status.json is read through the store lib now (Read-StatusSnapshot),
# which resolves the same path but shares the locking protocol with the
# writers. The local Read-StatusObj is gone: it read the file without
# the lock, which is what let a caller act on a snapshot that another
# process had already replaced.

if (-not $Once) {
  Set-Content -Path $pidFile -Value $PID -Encoding ASCII
  Log-Line "detector started (PID $PID) mcodeRoot=$mcodeRoot"
}

# session
# detector per-tick guard autostart
# sessions.json
# 30 session
try {
  Restore-SessionTracker
  Seed-SessionTracker
  Write-SessionsFile -Force
} catch {
  Log-Line "SESSIONS INIT FAIL: $($_.Exception.Message)"
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

 # 0) session +
 # " session " "
    try {
      Update-SessionTracker
      Write-SessionsFile
    } catch {
      Log-Line "SESSIONS UPDATE FAIL: $($_.Exception.Message)"
    }

 # 1) session log 5s EnumerateFiles .jsonl
 # mcode CLI
 # "mcode " session log
 # error
 # "60s idle"
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

 # 3) 60s idle mtime
 # `waiting` ask_user agent
 # session log 60s " 60s"
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
      $newState  = [string]$inferred.state
      $newMsg    = [string]$inferred.message
      $logLine   = $null

 # The arbitration read and the write it authorises are ONE
 # critical section (round-21 review hetaoBackend #1). Reading the
 # push was judged against a stale snapshot and then overwritten by
 # the write that stale snapshot had authorised.
      $lock = Enter-StatusLock
      try {
        $cur = Read-StatusSnapshot
        $curSource = if ($cur) { [string]$cur.source } else { '' }
        $curState  = if ($cur) { [string]$cur.state  } else { '' }

        $isOwn = ($curSource -eq $S_DETECTOR)
        $stateChanged = ($curState -ne $newState)
 # `working` detector session log `waiting` waiting
 # settle detector status.json pill
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
          Write-StatusUnderLock $newState $newMsg $inferred.family
          if ($script:lastDetectedState -ne $newState) {
            $script:lastDetectedState = $newState
            $logLine = "$newState :: $newMsg ($reason)"
          }
        }
      } finally {
        Exit-StatusLock $lock
      }
 # Appended outside the critical section: the log write must not
 # hold the lock that the other writer is waiting for.
      if ($logLine) { Log-Line $logLine }
    }

 # 4) 5h 60s status.json widget
    $prevPct  = $script:plan5hRemainingPct
    $prevMs   = $script:plan5hResetMs
    Get-PlanUsage | Out-Null

    $curPct   = $script:plan5hRemainingPct
    $curMs    = $script:plan5hResetMs
    $usageChanged = ($prevPct -ne $curPct) -or ($prevMs -ne $curMs) -and ($null -ne $curPct)
    if ($usageChanged) {
 # Metadata refresh: restate the current state and refresh the
 # numbers. The snapshot it restates is read INSIDE Write-Status,
 # is either fully seen or fully missed -- never half. The old code
 # read the file here, read it again inside Write-Status, and wrote
 # between the two reads was clobbered with stale values
 # (round-21 review hetaoBackend #1).
      Write-Status -MetadataRefresh
      Log-Line ("5h usage refreshed: remaining=" + $curPct + "% resetMs=" + $curMs)
    }

 # 5) Todo mtime status.json
    $prevTodoPct  = $script:plan5hLastWrittenTodoPct
    $curTodoData  = Get-TodoProgress
    $curTodoPct   = if ($null -ne $curTodoData) { $curTodoData.percent } else { $null }
    $todoChanged  = ($prevTodoPct -ne $curTodoPct)
    if ($todoChanged) {
      Write-Status -MetadataRefresh
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
  $STOPPED_MSG = 'detector stopped'
  Log-Line $STOPPED_MSG
}
