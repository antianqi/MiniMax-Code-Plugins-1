# session v0.5.0
# session Get-LatestSessionFile *.jsonl
# pill " " "
# " pill
# session
# agent -> toolCall / toolResult / thinking
# " " agent 40
# 40 " "
# sessions.json status.json status.json agent
# notify-island.ps1 detector agent
# sessions.json detector

# session id ->

# mcode-island runs on Windows only: the status pill is a WPF window and the
# autostart entry is a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
# On any other platform fail with a clear message instead of a cryptic WPF or
# registry error.
if ($env:OS -ne 'Windows_NT') {
  Write-Output 'mcode-island supports Windows only (this host is not Windows).'
  exit 1
}
$script:trackedSessions = [ordered]@{}
$script:sessionTitleCache = @{}
# id -> cycle
$script:dismissedSessions = @{}
# sessions.json status.json
$script:sessionsDirty = $false
$script:lastGroupsScan = [DateTime]::MinValue
$script:lastGroups = @{}

# detector session
$script:SEED_WINDOW_MS = 30 * 60 * 1000

# SQLite
# lib " "

$script:runtimeTitlesAvailable = $false
if (Test-Path (Join-Path $PSScriptRoot 'Runtime-Titles.ps1')) {
  . (Join-Path $PSScriptRoot 'Runtime-Titles.ps1')
  $script:runtimeTitlesAvailable = $true
}

# session " "
# - " " mtime toolCall
# toolCall " "
# 80+
# - " " agent 40
# 40 mtime " "
# 60 detector
$script:ACTIVE_WINDOW_MS = 60 * 1000

# agent
# toolCall toolResult " "
# 5
$script:STALE_RUNNING_MS = 5 * 60 * 1000

function Get-SessionIdFromDir($dir) {
  $name = [System.IO.Path]::GetFileName($dir)
  $i = $name.IndexOf('session_')
  if ($i -lt 0) { return $name }
  $b64 = $name.Substring($i + 8)
  try {
    $pad = (4 - ($b64.Length % 4)) % 4
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64 + ('=' * $pad)))
  } catch {
    return $name
  }
}

# session
# <sessionsRoot>/<Y>/<M>/<D>/<HH-mm-ss-fff>-session_<base64(id)>/
# ledger.jsonl messages.jsonl fallback
# session
# Get-LatestSessionFile ledger
# messages 60s
function Get-SessionLogGroups($root) {
  $groups = @{}
  if (-not $root -or !(Test-Path -LiteralPath $root)) { return $groups }
  foreach ($dir in [System.IO.Directory]::EnumerateDirectories($root, '*session_*', 'AllDirectories')) {
    $log = $null
    $mtime = [DateTime]::MinValue
    foreach ($name in @($FNAME_LEDGER, $FNAME_MESSAGES)) {
      $p = Join-Path $dir $name
      if (!(Test-Path -LiteralPath $p)) { continue }
      try { $t = [System.IO.File]::GetLastWriteTimeUtc($p) } catch { continue }
      if ($t -gt $mtime) { $mtime = $t; $log = $p }
    }
    if (-not $log) { continue }
    $id = Get-SessionIdFromDir $dir
    $groups[$id] = @{ Id = $id; Dir = $dir; Log = $log; MTime = $mtime }
  }
  return $groups
}

# user
# " " session compaction
# role=compactionSummary role=custom user
# agent
# agent user
# XML "<background-task-finished> Local backend..."
function Test-IsSystemInjected($text) {
  if (-not $text) { return $true }
  $t = ([string]$text).Trim()
  if (-not $t) { return $true }
  return ($t -match '^<(system-reminder|background-task|task-notification|agent-context|command-|user-message|system-)')
}

# user <system-reminder> agent-context
function Get-SessionTitle($file) {
  if (-not $file) { return '' }
  if ($script:sessionTitleCache.ContainsKey($file)) { return $script:sessionTitleCache[$file] }
  $title = ''
  try {
    $fs = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
 # 64 KB user base64 KB
      $cap = 64 * 1024
      $len = [Math]::Min($cap, $fs.Length)
      $buf = New-Object byte[] $len
      $read = 0
      while ($read -lt $len) {
        $n = $fs.Read($buf, $read, $len - $read)
        if ($n -le 0) { break }
        $read += $n
      }
      $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
      $assistantFallback = ''
      foreach ($raw in ($text -split "`n")) {
        $line = $raw.TrimEnd("`r")
        if (-not $line -or $line.Length -le 10) { continue }
        $msg = $null
        try { $msg = $line | ConvertFrom-Json } catch { continue }
        $m = $msg.message
        if (-not $m) { continue }
        $role = [string]$m.role
        $t = ''
        foreach ($c in @($m.content)) {
          if ($c.type -eq 'text' -and $c.text) { $t = [string]$c.text; break }
        }
        if (-not $t) { continue }
        $t = $t -replace '(?s)<system-reminder>.*?</system-reminder>', ''
        $t = ($t -replace '\s+', ' ').Trim()
        if (-not $t) { continue }
 # user
        if (Test-IsSystemInjected $t) { continue }
        if ($role -eq $S_USER) { $title = $t; break }
 # compaction
 # compactionSummary agent
        if (-not $assistantFallback -and $role -eq $S_ASSISTANT) { $assistantFallback = $t }
      }
      if (-not $title) { $title = $assistantFallback }
    } finally {
      $fs.Close()
    }
  } catch {
    $title = ''
  }
  if ($title.Length -gt 40) { $title = $title.Substring(0, 40) + '...' }
  $script:sessionTitleCache[$file] = $title
  return $title
}

# session
# ** detector Infer-State **
# running/waiting/stopped "
# " pill idle running pill
# pill
# working agent
# thinking agent
# waiting agent ask_user
# idle agent
# ** ** done error pill " "" " "
# " " agent
# message family pill "Ran"
# "Read"
function Get-SessionState($msg) {
  if (-not $msg) { return '' }
  $m = $msg.message
  if (-not $m) {
 # ledger {kind, phase, action, ...}
    $kind = [string]$msg.kind
 # ** ** agent
 # working done
    if ($kind -eq $S_TOOLRESULT) { return 'working' }
    if ($kind -eq 'toolCall' -or $kind -eq $S_TOOLCALL) {
      if (Test-IsAskUser ([string]$msg.toolName)) { return 'waiting' }
      return 'working'
    }
    if ($kind -eq $S_ASSISTANT -and [string]$msg.phase -eq $S_THINKING) { return 'thinking' }
    return ''
  }
  $role = [string]$m.role
 # agent pill idle " "
  if ($role -eq $S_USER) { return 'idle' }
  if ($role -eq $S_ASSISTANT) {
 # detector content toolCall
    $hasTool = $null
    $hasThink = $null
    $hasText = $null
    if ($m.content) {
      foreach ($c in @($m.content)) {
        if     ($hasTool  -eq $null -and $c.type -eq $S_TOOLCALL)  { $hasTool  = $c }
        elseif ($hasThink -eq $null -and $c.type -eq $S_THINK_BLK) { $hasThink = $c }
        elseif ($hasText  -eq $null -and $c.type -eq $S_TEXT)      { $hasText  = $c }
        if ($hasTool) { break }
      }
    }
    if ($hasTool) {
      if (Test-IsAskUser ([string]$hasTool.name)) { return 'waiting' }
      return 'working'
    }
    if ($hasThink -and -not $hasText) { return 'thinking' }
    if ($hasText) { return 'idle' }
    return 'idle'
  }
 # pill /
 # "Read""Edited"
 # " " agent
  if ($role -eq $S_TOOLRESULT) { return 'working' }
  return ''
}

# " " agent
# idle agent
# waiting agent ask_user
# done
# stopped agent
# error
# working/thinking
$script:ROUND_END_STATES = @('idle', 'waiting', 'done', 'stopped', 'error')

# " " agent
$script:ACTIVE_STATES = @('working', 'thinking')

# IO Get-LastJsonLine
# Get-SessionState $m.content
# " <tool>" widget detector
# detector
# assistant -> agent " "
# user ->
# toolCall -> widget " xxx" agent
# toolCall
# toolResult ->
function Get-SessionPreview($msg) {
  if (-not $msg) { return '' }
  $m = $msg.message
  if (-not $m) { return '' }
  $role = [string]$m.role
 # toolResult
  if ($role -eq $S_TOOLRESULT) { return '' }
  $text = ''
  foreach ($c in @($m.content)) {
    if ($c.type -ne 'text' -or -not $c.text) { continue }
    $candidate = ([string]$c.text) -replace '(?s)<system-reminder>.*?</system-reminder>', ''
    $candidate = ($candidate -replace '\s+', ' ').Trim()
    if (-not $candidate) { continue }
    if (Test-IsSystemInjected $candidate) { continue }
    $text = $candidate
    break
  }
  if (-not $text) { return '' }
  return $text
}

# toolCall
# toolCall widget
# toolResult content message.toolName
# agent toolResult
# preview content toolCall
# message.toolName
function Get-SessionLastTool($msg) {
  if (-not $msg) { return '' }
  $m = $msg.message
  if (-not $m) { return '' }
  foreach ($c in @($m.content)) {
    if ($c.type -eq 'toolCall' -and $c.name) { return [string]$c.name }
  }
  if ($m.PSObject.Properties['toolName'] -and $m.toolName) { return [string]$m.toolName }
  return ''
}

# session
# SQLite " MCode 0.6.13
# " URL
function Get-SessionDisplayTitle([string]$id, [string]$log) {
  if ($script:runtimeTitlesAvailable) {
    $t = Get-RuntimeSessionTitle $id
    if ($t) { return $t }
  }
  return (Get-SessionTitle $log)
}

# session
# cycle cycle agent
# waiting -> running
function Remove-TrackedSession($id) {
  $entry = $script:trackedSessions[$id]
  if ($entry) {
    $script:dismissedSessions[$id] = @{ Cycle = $entry.Cycle; Phase = $entry.Phase }
    $script:trackedSessions.Remove($id)
    $script:sessionsDirty = $true
    return $true
  }
  return $false
}

# show.signal widget detector
# ack.signal session id
function Read-AckSignal {
  $ackFile = Join-Path $configDir 'ack.signal'
  if (!(Test-Path -LiteralPath $ackFile)) { return $null }
  $id = $null
  try { $id = (Get-Content -LiteralPath $ackFile -Raw -Encoding UTF8) } catch { $id = $null }
  try { Remove-Item -LiteralPath $ackFile -Force -ErrorAction SilentlyContinue } catch {}
  if ($id) { return $id.Trim() }
  return $null
}

# session
function Update-SessionTracker {
  $acked = Read-AckSignal
  if ($acked) {
    if (Remove-TrackedSession $acked) { Log-Line "session ack: $acked" }
  }

  $groups = Get-SessionLogGroups $sessionsRoot
  $now = [DateTime]::UtcNow

  foreach ($id in @($groups.Keys)) {
    $g = $groups[$id]
    $entry = $script:trackedSessions[$id]
    if ($entry -and $entry.MTime -eq $g.MTime) {
 # " " agent
 # toolCall toolResult " "
 # continue
      if ($entry.Phase -in $script:ACTIVE_STATES) {
        $ageMs = ($now - $g.MTime).TotalMilliseconds
        if ($ageMs -gt $script:STALE_RUNNING_MS) {
          $entry.Phase = 'stopped'
          $script:sessionsDirty = $true
          Log-Line ("session stopped: " + $id + " (quiet for " + [int]($ageMs / 1000) + "s)")
        }
      }
      continue
    }

    $msg = Get-LastJsonLine $g.Log
    if (-not $msg) { continue }
    $phase = Get-SessionState $msg

    if (-not $entry) {
 # session " "
 # mtime
 # toolCall toolCall
      $ageMs = ($now - $g.MTime).TotalMilliseconds
      if ($ageMs -gt $script:ACTIVE_WINDOW_MS) { continue }

      $cycle = 1
      if ($script:dismissedSessions.ContainsKey($id)) {
        $d = $script:dismissedSessions[$id]
        if (($d.Phase -in $script:ROUND_END_STATES) -and ($phase -in $script:ACTIVE_STATES)) {
          $cycle = $d.Cycle + 1
          $script:dismissedSessions.Remove($id)
          $script:sessionsDirty = $true
        } else {
          $d.Phase = $phase
          continue
        }
      }
      $script:trackedSessions[$id] = @{
        Id = $id
        Title = (Get-SessionDisplayTitle $id $g.Log)
        Phase = $phase
        Cycle = $cycle
        MTime = $g.MTime
        SinceMs = [int64]([DateTimeOffset]::new($g.MTime).ToUnixTimeMilliseconds())
 # Preview = agent
 # LastTool = toolCall
 # LastAtMs = mtime " "
 # SinceMs
        Preview = (Get-SessionPreview $msg)
        LastTool = (Get-SessionLastTool $msg)
 # tab mcode
 # tab
 # tab
        Titles = @(@((Get-SessionDisplayTitle $id $g.Log), (Get-SessionTitle $g.Log)) | Where-Object { $_ } | Select-Object -Unique)
        LastAtMs = [int64]([DateTimeOffset]::new($g.MTime).ToUnixTimeMilliseconds())
        Dir = $g.Dir
      }
      $script:sessionsDirty = $true
      Log-Line "session tracked: $id ($phase)"
      continue
    }

 # idle/waiting/done/stopped/error
 # working/thinking
    if (($entry.Phase -in $script:ROUND_END_STATES) -and ($phase -in $script:ACTIVE_STATES)) {
 # agent ->
      $entry.Cycle = $entry.Cycle + 1
      if ($script:dismissedSessions.ContainsKey($id)) {
        $script:dismissedSessions.Remove($id)
      }
      $script:sessionsDirty = $true
      Log-Line "session restarted: $id (cycle $($entry.Cycle))"
    }
    if ($entry.Phase -ne $phase) { $script:sessionsDirty = $true }
    $entry.Phase = $phase
    $entry.MTime = $g.MTime
 # dirty Phase agent
 # Phase running dirty
 # sessions.json
    $newPreview = (Get-SessionPreview $msg)
    $newTool    = (Get-SessionLastTool $msg)
    $newAtMs    = [int64]([DateTimeOffset]::new($g.MTime).ToUnixTimeMilliseconds())
    if ($entry.Preview -ne $newPreview -or $entry.LastTool -ne $newTool -or $entry.LastAtMs -ne $newAtMs) {
      $script:sessionsDirty = $true
    }
    $entry.Preview = $newPreview
    $entry.LastTool = $newTool
    $entry.LastAtMs = $newAtMs
 # 8 tab
 # detector sessions.json
    $newTitle = (Get-SessionDisplayTitle $id $g.Log)
    if ($newTitle) {
 # tab
      $hist = @(@($entry.Titles) + @($newTitle) + @((Get-SessionTitle $g.Log)) | Where-Object { $_ } | Select-Object -Unique)
      if ($hist.Count -gt 8) { $hist = @($hist | Select-Object -Last 8) }
      $entry.Titles = $hist
    }
 # node
 # Get-RuntimeSessionTitle 60s
    if ($script:runtimeTitlesAvailable) {
      $rt = Get-RuntimeSessionTitle $id
      if ($rt -and $rt -ne $entry.Title) {
        $entry.Title = $rt
        $script:sessionsDirty = $true
      }
    }
    if (-not $entry.Title) { $entry.Title = (Get-SessionTitle $g.Log) }
  }
}

# sessions.json
# detector agent
# status.json
function Write-SessionsFile {
  param([switch]$Force)
  if (-not $Force -and -not $script:sessionsDirty) { return }
  $items = @()
  foreach ($id in @($script:trackedSessions.Keys)) {
    $e = $script:trackedSessions[$id]
    $items += [PSCustomObject]@{
      id = $e.Id
      title = $e.Title
      phase = $e.Phase
      sinceMs = $e.SinceMs
      cycle = $e.Cycle
 # / null
 # widget null
      preview = $(if ($e.Preview) { [string]$e.Preview } else { '' })
      lastTool = $(if ($e.LastTool) { [string]$e.LastTool } else { '' })
      lastAtMs = $(if ($e.LastAtMs) { [int64]$e.LastAtMs } else { 0 })
 # widget tab
      titles = @($e.Titles | Where-Object { $_ })
    }
  }
  $payload = [PSCustomObject]@{
    sessions = $items
    dismissed = $script:dismissedSessions
    ts = (Get-Date).ToString('o')
  }
  $lock = Enter-StatusLock
  try {
    $file = Join-Path $configDir 'sessions.json'
    $json = $payload | ConvertTo-Json -Compress -Depth 6
    $tmp = "$file.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
    Move-Item -Path $tmp -Destination $file -Force
    $script:sessionsDirty = $false
  } catch {
    Log-Line "SESSIONS WRITE FAIL: $($_.Exception.Message)"
  } finally {
    Exit-StatusLock $lock
  }
}

# detector detector " "
function Restore-SessionTracker {
  $file = Join-Path $configDir 'sessions.json'
  if (!(Test-Path -LiteralPath $file)) { return }
  try {
    $j = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
    foreach ($s in @($j.sessions)) {
      if (-not $s.id) { continue }
      $script:trackedSessions[$s.id] = @{
        Id = $s.id
        Title = [string]$s.title
        Phase = [string]$s.phase
        Cycle = $(if ($s.cycle) { [int]$s.cycle } else { 1 })
        MTime = [DateTime]::MinValue
        SinceMs = [int64]$s.sinceMs
 # detector
 # widget
        Preview = $(if ($s.preview) { [string]$s.preview } else { '' })
        LastTool = $(if ($s.lastTool) { [string]$s.lastTool } else { '' })
        LastAtMs = $(if ($s.lastAtMs) { [int64]$s.lastAtMs } else { 0 })
        Titles = @($s.titles | Where-Object { $_ })
        Dir = ''
      }
    }
    if ($j.dismissed) {
      foreach ($p in $j.dismissed.PSObject.Properties) {
        $v = $p.Value
 # cycle " "
        if ($v -is [int] -or $v -is [long] -or $v -is [double]) {
          $v = @{ Cycle = [int]$v; Phase = 'working' }
        }
        $script:dismissedSessions[$p.Name] = $v
      }
    }
    Log-Line ("sessions restored: " + $script:trackedSessions.Count)
  } catch {
    Log-Line "SESSIONS RESTORE FAIL: $($_.Exception.Message)"
  }
}

# session
# detector
# detector per-tick guard autostart
# " running waiting" detector
# session " "
# 30 " "
function Seed-SessionTracker {
  $groups = Get-SessionLogGroups $sessionsRoot
  $now = [DateTime]::UtcNow
  $activeCut = $now.AddMilliseconds(-1 * $script:ACTIVE_WINDOW_MS)
  $seedCut = $now.AddMilliseconds(-1 * $script:SEED_WINDOW_MS)
  foreach ($id in @($groups.Keys)) {
    $g = $groups[$id]
 # trackedSessions [ordered]@{} OrderedDictionary
 # ContainsKey Contains ContainsKey
 # "OrderedDictionary ContainsKey "
    if ($script:trackedSessions.Contains($id)) { continue }
    if ($script:dismissedSessions.ContainsKey($id)) { continue }

    $msg = Get-LastJsonLine $g.Log
    if (-not $msg) { continue }
    $phase = Get-SessionState $msg

 # - 60
 # - 30 agent detector
    $isActive = ($g.MTime -ge $activeCut)
    $isFinishedWaiting = ($g.MTime -ge $seedCut) -and ($phase -in $script:ROUND_END_STATES)
    if (-not $isActive -and -not $isFinishedWaiting) { continue }

    $script:trackedSessions[$id] = @{
      Id = $id
      Title = (Get-SessionTitle $g.Log)
      Phase = $phase
      Cycle = 1
      MTime = $g.MTime
      SinceMs = [int64]([DateTimeOffset]::new($g.MTime).ToUnixTimeMilliseconds())
      Dir = $g.Dir
    }
    $script:sessionsDirty = $true
    Log-Line "session seeded: $id ($phase)"
  }
}
