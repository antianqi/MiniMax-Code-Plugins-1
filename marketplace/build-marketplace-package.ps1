#Requires -Version 7.0
<#
.SYNOPSIS
  Builds the MiniMax Marketplace submission package for mcode-island.

.DESCRIPTION
  The Marketplace package rules (MiniMax Plugin Development and Submission Guide)
  require every text file to be UTF-8 **without** a BOM. Windows PowerShell 5.1
  only decodes a BOM-less .ps1 file with the ANSI code page (GBK on zh-CN), so a
  BOM-less .ps1 that contains non-ASCII bytes can be mis-parsed. The upstream
  plugin therefore ships UTF-8 **with** a BOM and Chinese comments, which is the
  correct trade-off for a repo checkout but not for a Marketplace package.

  This builder produces the Marketplace variant:
    * .ps1 / .cmd files become pure ASCII (verified byte-wise)
    * user-visible Chinese becomes plain English; the Chinese documentation
      stays in README.zh-CN.md and skills/<name>/SKILL.md
    * obfuscated literals (`_s (0x..)` byte arrays) become plain string
      literals, so nothing in the package is hidden from review
    * every entry script gets an explicit Windows-only guard
    * the Hook client extension (io.minimax.mcode/), the Claude-format manifest
      (.claude-plugin/), the agent-plugins.org manifest, the 5h-usage module
      (scripts/lib/Get-5hUsage.ps1) and set-token.ps1 are NOT part of a
      Marketplace package, so the shipped package reads no credential, keeps
      no token and makes no network request at all
    * the build fails if the package would contain any credential, URL or
      Hook token

  .md and .json files are written by hand and are not touched by this builder.

.PARAMETER Check
  Verify that the committed package matches what this builder would produce.
  Exits 1 and lists the differences when it does not.

.EXAMPLE
  pwsh -File marketplace/build-marketplace-package.ps1
  pwsh -File marketplace/build-marketplace-package.ps1 -Check
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$SourceDir = 'plugins/antianqi/mcode-island',
  [string]$OutDir = 'marketplace/mcode-island',
  [switch]$Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$src = Join-Path $RepoRoot $SourceDir
$out = Join-Path $RepoRoot $OutDir

if (-not (Test-Path $src)) { throw "source plugin dir not found: $src" }

# --- runtime files that a Marketplace package actually needs -----------------
# Not shipped, on purpose:
#   io.minimax.mcode/      Hook client extension (the form does not accept Hooks)
#   .claude-plugin/        Claude-format manifest with a hooks block
#   plugin.json            agent-plugins.org manifest (the entry point is
#                          .minimax-plugin/plugin.json)
#   set-token.ps1          stores a credential
#   scripts/lib/Get-5hUsage.ps1
#                          the 5h-usage module: it holds the API URL, the
#                          request headers and the token resolution
#   scripts/smoke.mjs, scripts/test-*
#                          development-only
#   *.bak-r16              backup file
$runtimeFiles = @(
  'mcode-island.ps1'
  'mcode-island.cmd'
  'notify-island.ps1'
  'wrap-tool.ps1'
  'mcode-status-detect.ps1'
  'start-island.ps1'
  'stop-island.ps1'
  'status-island.ps1'
  'show-island.ps1'
  'pin-island.ps1'
  'autostart.ps1'
  'start-detect-island.ps1'
  'status-detect-island.ps1'
  'stop-detect-island.ps1'
  'scripts/lib/Protect-Text.ps1'
  'scripts/lib/Status-Store.ps1'
)

$copyBinaryFiles = @(
  'LICENSE'
  'assets/state-done.png'
  'assets/state-error.png'
  'assets/state-idle.png'
  'assets/state-thinking.png'
  'assets/state-waiting.png'
  'assets/state-working.png'
  'assets/wrap-demo.png'
)

# --- user-visible Chinese -> plain English -----------------------------------
# Console diagnostics and the widget labels. The Chinese UI of the hosted
# plugin lives in plugins/antianqi/mcode-island; the Marketplace package is the
# English, ASCII-only variant.
$englishReplacements = [ordered]@{
  'mcode-island.ps1' = @(
    @{ from = 'ToolTip="mmx 5h 用量（来自 coding_plan/remains）"'
       to   = 'ToolTip="mmx 5h usage"' }
    @{ from = '<!-- 5h 用量：detector 拉 minimax /v1/coding_plan/remains，-1 = 未知 -->'
       to   = '<!-- 5h usage badge: filled in by the detector, -1 means unknown -->' }
    @{ from = 'Text="等待任务"'
       to   = 'Text="Waiting for task"' }
    @{ from = "label='mcode · 思考中'"
       to   = "label='mcode - thinking'" }
    @{ from = "label='mcode · 执行中'"
       to   = "label='mcode - working'" }
    @{ from = "label='mcode · 等待审批'"
       to   = "label='mcode - waiting'" }
    @{ from = "label='mcode · 已完成'"
       to   = "label='mcode - done'" }
    @{ from = "label='mcode · 出错'"
       to   = "label='mcode - error'" }
    @{ from = "icon='⚙'"
       to   = "icon='*'" }
    @{ from = "icon='✓'"
       to   = "icon='+'" }
    @{ from = "icon='✕'"
       to   = "icon='x'" }
    @{ from = '"$stepStr · $Detail"'
       to   = '"$stepStr - $Detail"' }
  )
  'mcode-status-detect.ps1' = @(
    @{ from = @'
# mcode-status-detect.ps1 - 后台守护进程 (v0.2.1)
# 监听 mcode session log，实时推断 agent 状态，写到 status.json
# 让 widget 不依赖 agent 主动调 notify-island.ps1 也能跟着动
#
# 路径解析（顺序）：
#   1. 用户显式 -Root 覆盖
#   2. 桌面端数据目录 $env:MINIMAX_DATA_DIR（没有则用 <userprofile>/.minimax）
#   3. <userprofile>
#
# session log（顺序）：
#   1. <dataDir>/v2/sessions/<date>/*/ledger.jsonl（首选，mcode v2 事件流）
#   2. <dataDir>/v2/sessions/<date>/*/messages.jsonl（fallback）
#
# 状态映射：
#   role=user                  → idle     (等用户)
#   role=assistant + toolCall  → working  "<tool>: <args>"
#   role=assistant + thinking  → thinking
#   role=assistant + text      → idle     (刚说完，等用户)
#   role=toolResult + !isError → done     "<tool> 完成"
#   role=toolResult + isError  → error    "<tool> 失败"
#   mcode 进程不在              → error    "mcode 已退出"
#   60s 无新事件                → idle     兜底
#
# 优先级：
#   agent 主动推的状态（status.json 中 source != detector）保留
#   detector 推的 idle / error 可以覆盖 agent 推的（兜底）
#   detector 推的 working/thinking/done 不覆盖 agent 推的
'@
       to   = @'
# mcode-status-detect.ps1 - background state detector
# Reads the local MiniMax Code session log, infers the agent state and
# writes it to status.json, so the widget keeps moving even when the agent
# does not push a state itself.
#
# Path resolution (in order):
#   1. explicit -Root override
#   2. the desktop data directory: $env:MINIMAX_DATA_DIR, or
#      <userprofile>/.minimax
#   3. <userprofile>
#
# Session log (in order):
#   1. <dataDir>/v2/sessions/<date>/*/ledger.jsonl   (preferred, v2 event stream)
#   2. <dataDir>/v2/sessions/<date>/*/messages.jsonl (fallback)
#
# State mapping:
#   role=user                  -> idle     (waiting for the user)
#   role=assistant + toolCall  -> working  "<tool>: <args>"
#   role=assistant + thinking  -> thinking
#   role=assistant + text      -> idle     (replied, waiting for the user)
#   role=toolResult + !isError -> done     "<tool> done"
#   role=toolResult + isError  -> error    "<tool> failed"
#   60s without a new event    -> idle     (fallback)
#
# Precedence:
#   a state pushed by the agent (source != detector) is kept
#   the detector may override it with idle / error (fallback)
#   the detector never overrides working / thinking / done
'@ }
    @{ from = '# 5h 用量 API：每 60s 调一次 minimax /v1/coding_plan/remains，写进 status.json 的 usage5h 字段'
       to   = '# 5h usage badge: optional, only active when scripts/lib/Get-5hUsage.ps1 is present' }
  )
  'wrap-tool.ps1' = @(
    @{ from = '"$brief 完成"'
       to   = '"$brief done"' }
    @{ from = '"read 完成"'
       to   = '"read done"' }
    @{ from = '"write 完成"'
       to   = '"write done"' }
    @{ from = '"edit 完成"'
       to   = '"edit done"' }
    @{ from = '"glob 完成"'
       to   = '"glob done"' }
    @{ from = '"grep 完成"'
       to   = '"grep done"' }
    @{ from = "'web 完成'"
       to   = "'web done'" }
    @{ from = "'task 完成'"
       to   = "'task done'" }
    @{ from = "'notebook 完成'"
       to   = "'notebook done'" }
    @{ from = '"$Tool 完成"'
       to   = '"$Tool done"' }
    @{ from = '"$Tool 等待审批 (exit=$ExitCode)"'
       to   = '"$Tool waiting for approval (exit=$ExitCode)"' }
    @{ from = '"$Tool 失败 (exit=$ExitCode)"'
       to   = '"$Tool failed (exit=$ExitCode)"' }
  )
  'start-island.ps1' = @(
    @{ from = '("已在运行（PID " + $old + "）")'
       to   = '("already running (PID " + $old + ")")' }
    @{ from = '("mcode-island 已启动 (PID " + $proc.Id + "，已就绪)")'
       to   = '("mcode-island started (PID " + $proc.Id + ", ready)")' }
    @{ from = '("mcode-island 已启动 (PID " + $proc.Id + "，等待中...)")'
       to   = '("mcode-island started (PID " + $proc.Id + ", waiting...)")' }
  )
  'show-island.ps1' = @(
    @{ from = "'NOT RUNNING: widget 没在跑，先 mcode-island start'"
       to   = "'NOT RUNNING: widget is not running, run mcode-island start first'" }
    @{ from = '"NOT RUNNING: PID $widgetPid 是死的，先 mcode-island start"'
       to   = '"NOT RUNNING: PID $widgetPid is dead, run mcode-island start first"' }
  )
  'pin-island.ps1' = @(
    @{ from = '"FAIL: 当前没有前台窗口"'
       to   = '"FAIL: no foreground window"' }
    @{ from = '"FAIL: 前台窗口进程已退出"'
       to   = '"FAIL: foreground window process has exited"' }
    @{ from = '"     之后点 pill 就切回这个窗口"'
       to   = '"     click the pill to switch back to this window"' }
  )
  'autostart.ps1' = @(
    @{ from = "'DISABLED: 本来就没注册'"
       to   = "'DISABLED: not registered'" }
  )
}

# Chinese strings that reach the user through an obfuscated literal.
$byteLiteralTranslations = @{
  '等用户'                        = 'Waiting for you'
  '已静默 {0}s'                   = 'Idle {0}s'
  'agent 刚回复，等用户'           = 'agent replied, waiting for you'
  'session 压缩'                  = 'session compacted'
}

# --- a package must never contain these --------------------------------------
$forbiddenPatterns = [ordered]@{
  'MM-API-Source'      = 'a request header that impersonates another MiniMax surface'
  'MINIMAX_OAUTH_TOKEN' = 'a credential read from the environment'
  'MINIMAX_API_KEY'    = 'a credential read from the environment'
  'planApiToken'       = 'a stored credential'
  'minimaxi.com'       = 'an outbound API endpoint'
  'coding_plan'        = 'an outbound API path'
  'Invoke-RestMethod'  = 'an outbound HTTP call'
  'Invoke-WebRequest'  = 'an outbound HTTP call'
  '_s (0x'             = 'an obfuscated byte-array literal'
  '[char]0x'           = 'an obfuscated code-point literal'
  '.minimax-code'      = 'a dependency on the MiniMax Code CLI'
  'mcode-active'       = 'a dependency on the MiniMax Code CLI'
  'io.minimax.mcode'   = 'the Hook client extension'
  'hooks.json'         = 'a Hook declaration'
  '"hooks"'            = 'a Hook declaration'
}

# --- helpers ------------------------------------------------------------------

$nonAsciiPattern = '[^\u0020-\u007E\t]'

function Remove-NonAscii {
  # Replace every non-ASCII run with a single space instead of deleting it:
  # a comment that mixes English and Chinese then still reads as a sentence
  # ("- progress=0..100 determinate ProgressFill") instead of as a broken
  # fragment ("- progress=0..100ProgressFill").
  param([string]$Text)
  return [regex]::Replace($Text, '[^\u0020-\u007E\t]+', ' ')
}

function Test-HasAlnum {
  param([string]$Text)
  return $Text -match '[A-Za-z0-9]'
}

function ConvertTo-CommentText {
  # A comment that no longer carries any ASCII word is dropped entirely; a
  # comment that still does is kept, tidied.
  param([string]$Text)
  $clean = Remove-NonAscii $Text
  if (-not (Test-HasAlnum $clean)) { return $null }
  $clean = [regex]::Replace($clean, '[ \t]{2,}', ' ')
  return $clean.TrimEnd()
}

function Convert-ByteArrayLiterals {
  # `_s (0x69,0x64,0x6C,0x65)` -> `'idle'`
  #
  # The upstream plugin builds some string literals from byte arrays. The
  # Marketplace review rejected that: a literal that is not readable in the
  # source looks like an attempt to keep something from the reviewer. This
  # decodes every one of them into the plain string it stands for, and
  # translates the Chinese ones (the package UI is English).
  param([string]$Text)

  $pattern = '_s\s*\(((?:0x[0-9A-Fa-f]{2}\s*,\s*)*0x[0-9A-Fa-f]{2})\)'
  $evaluator = {
    param($m)
    $bytes = @([regex]::Matches($m.Groups[1].Value, '0x([0-9A-Fa-f]{2})') |
      ForEach-Object { [byte][Convert]::ToInt32($_.Groups[1].Value, 16) })
    $value = [System.Text.Encoding]::UTF8.GetString([byte[]]$bytes)
    if ($byteLiteralTranslations.ContainsKey($value)) {
      $value = $byteLiteralTranslations[$value]
    }
    return "'" + $value.Replace("'", "''") + "'"
  }
  return [regex]::Replace($Text, $pattern, $evaluator)
}

function Remove-ChineseComments {
  param([string]$Text)

  $lines = $Text -split "`r?`n"
  $result = New-Object System.Collections.Generic.List[string]
  $i = 0

  while ($i -lt $lines.Count) {
    $line = $lines[$i]
    $trim = $line.TrimStart()

    # multi-line block comments: XML <!-- --> and PowerShell <# #>
    if ($trim.StartsWith('<!--') -or $trim.StartsWith('<#')) {
      $close = if ($trim.StartsWith('<!--')) { '-->' } else { '#>' }
      $block = New-Object System.Collections.Generic.List[string]
      $block.Add($line)
      $j = $i + 1
      $closed = $false
      while ($j -lt $lines.Count) {
        $block.Add($lines[$j])
        if ($lines[$j].Contains($close)) { $closed = $true; break }
        $j++
      }
      $stripped = @($block | ForEach-Object { Remove-NonAscii $_ })
      if ((($stripped -join "`n") -notmatch '(?i)hook') -and (($stripped -join "`n") -match '[A-Za-z0-9]')) {
        foreach ($s in $stripped) { $result.Add($s) }
      }
      $i = if ($closed) { $j + 1 } else { $lines.Count }
      continue
    }

    # comment-only line
    if ($trim.StartsWith('#') -or $trim.StartsWith('//')) {
      # A comment about the client-extension path describes a directory that is
      # not part of a Marketplace package, so it is dropped rather than left
      # behind as a stale reference.
      if ($line -notmatch '(?i)hook') {
        $clean = ConvertTo-CommentText $line
        if ($null -ne $clean) { $result.Add($clean) }
      }
      $i++
      continue
    }

    # trailing comment: only touch it when it actually carries Chinese
    $idx = $line.LastIndexOf(' #')
    if ($idx -lt 0) { $idx = $line.LastIndexOf(' //') }
    if ($idx -ge 0) {
      $code = $line.Substring(0, $idx)
      $comment = $line.Substring($idx)
      if ($comment -match '(?i)hook') {
        $result.Add($code.TrimEnd())
        $i++
        continue
      }
      if ($comment -match $nonAsciiPattern) {
        $clean = ConvertTo-CommentText $comment
        if ($null -eq $clean) {
          $result.Add($code.TrimEnd())
        } else {
          $result.Add(($code.TrimEnd() + ' ' + $clean.TrimStart()))
        }
        $i++
        continue
      }
    }

    $result.Add($line)
    $i++
  }

  return ($result -join "`n")
}

$windowsGuard = @'

# mcode-island runs on Windows only: the status pill is a WPF window and the
# autostart entry is a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
# On any other platform fail with a clear message instead of a cryptic WPF or
# registry error.
if ($env:OS -ne 'Windows_NT') {
  Write-Output 'mcode-island supports Windows only (this host is not Windows).'
  exit 1
}
'@

function Add-WindowsGuard {
  # The guard has to run after the param block, so it is inserted right
  # after the closing parenthesis of the param block (or before the first
  # statement when the script has no param block).
  param([string]$Text)

  $lines = $Text -split "`r?`n"
  $insertAt = -1

  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*param\s*\(') {
      for ($j = $i + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\)') { $insertAt = $j + 1; break }
      }
      break
    }
  }

  if ($insertAt -lt 0) {
    for ($i = 0; $i -lt $lines.Count; $i++) {
      $t = $lines[$i].Trim()
      if ($t -eq '' -or $t.StartsWith('#')) { continue }
      $insertAt = $i
      break
    }
  }
  if ($insertAt -lt 0) { $insertAt = $lines.Count }

  $guardLines = ($windowsGuard -split "`r?`n")
  $out = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($i -eq $insertAt) { foreach ($g in $guardLines) { $out.Add($g) } }
    $out.Add($lines[$i])
  }
  if ($insertAt -ge $lines.Count) { foreach ($g in $guardLines) { $out.Add($g) } }

  return ($out -join "`n")
}

function Add-CmdWindowsGuard {
  # The .cmd shim is a batch file: the guard has to be cmd syntax and cannot
  # contain a BOM, otherwise cmd.exe chokes on the first line.
  param([string]$Text)

  $guard = @'
if not "%OS%"=="Windows_NT" (
  echo mcode-island supports Windows only (this host is not Windows).
  exit /b 1
)
'@
  $guardLines = ($guard -split "`r?`n")
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($g in $guardLines) { $out.Add($g) }
  foreach ($l in ($Text -split "`r?`n")) { $out.Add($l) }
  return ($out -join "`n")
}

function Get-ParseErrorCount {
  param([string]$Path)
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  return $errors.Count
}

function Write-TextFile {
  param([string]$Path, [string]$Content)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# --- icon ---------------------------------------------------------------------

function New-IslandIcon {
  param([string]$Path)

  Add-Type -AssemblyName System.Drawing
  $size = 512
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $bmp.SetResolution(96, 96)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.Clear([System.Drawing.Color]::Transparent)

  function New-Brush([string]$hex) {
    return New-Object System.Drawing.SolidBrush(
      [System.Drawing.ColorTranslator]::FromHtml($hex))
  }

  # app tile background
  $r = 112.0
  $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
  $tile.AddArc(0, 0, [int](2 * $r), [int](2 * $r), 180, 90)
  $tile.AddArc($size - 2 * $r, 0, [int](2 * $r), [int](2 * $r), 270, 90)
  $tile.AddArc($size - 2 * $r, $size - 2 * $r, [int](2 * $r), [int](2 * $r), 0, 90)
  $tile.AddArc(0, $size - 2 * $r, [int](2 * $r), [int](2 * $r), 90, 90)
  $g.FillPath((New-Brush '#FF12161F'), $tile)
  $g.DrawPath((New-Object System.Drawing.Pen((New-Brush '#FF2A3140'), 6)), $tile)

  # the island pill
  $pillX = 60.0; $pillY = 196.0; $pillW = 392.0; $pillH = 120.0; $pillR = 60.0
  $pill = New-Object System.Drawing.Drawing2D.GraphicsPath
  $pill.AddArc([float]$pillX, [float]$pillY, [float](2 * $pillR), [float](2 * $pillR), 180, 90)
  $pill.AddArc([float]($pillX + $pillW - 2 * $pillR), [float]$pillY, [float](2 * $pillR), [float](2 * $pillR), 270, 90)
  $pill.AddArc([float]($pillX + $pillW - 2 * $pillR), [float]($pillY + $pillH - 2 * $pillR), [float](2 * $pillR), [float](2 * $pillR), 0, 90)
  $pill.AddArc([float]$pillX, [float]($pillY + $pillH - 2 * $pillR), [float](2 * $pillR), [float](2 * $pillR), 90, 90)
  $g.FillPath((New-Brush '#FF1A202C'), $pill)

  # status dot (thinking / working)
  $g.FillEllipse((New-Brush '#33FFD24A'), 92.0, 224.0, 64.0, 64.0)
  $g.FillEllipse((New-Brush '#FFFFD24A'), 98.0, 230.0, 52.0, 52.0)

  # message placeholders
  $bar1 = New-Object System.Drawing.Drawing2D.GraphicsPath
  $bar1.AddArc(178.0, 222.0, 40.0, 40.0, 180, 90)
  $bar1.AddArc(308.0, 222.0, 40.0, 40.0, 270, 90)
  $bar1.AddArc(308.0, 242.0, 40.0, 40.0, 0, 90)
  $bar1.AddArc(178.0, 242.0, 40.0, 40.0, 90, 90)
  $g.FillPath((New-Brush '#FF4A5262'), $bar1)

  $bar2 = New-Object System.Drawing.Drawing2D.GraphicsPath
  $bar2.AddArc(178.0, 262.0, 40.0, 40.0, 180, 90)
  $bar2.AddArc(254.0, 262.0, 40.0, 40.0, 270, 90)
  $bar2.AddArc(254.0, 282.0, 40.0, 40.0, 0, 90)
  $bar2.AddArc(178.0, 282.0, 40.0, 40.0, 90, 90)
  $g.FillPath((New-Brush '#FF343B49'), $bar2)

  # trailing accent dot (done)
  $g.FillEllipse((New-Brush '#FF22C55E'), 396.0, 236.0, 40.0, 40.0)

  $g.Dispose()
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

# --- build --------------------------------------------------------------------

$drift = New-Object System.Collections.Generic.List[string]
$written = 0
$packageText = New-Object System.Collections.Generic.List[string]

foreach ($rel in $runtimeFiles) {
  $srcPath = Join-Path $src $rel
  $outPath = Join-Path $out $rel
  if (-not (Test-Path $srcPath)) { throw "missing runtime file: $rel" }

  $bytes = [System.IO.File]::ReadAllBytes($srcPath)
  $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
  if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

  if ($englishReplacements.Contains($rel)) {
    foreach ($rep in $englishReplacements[$rel]) {
      if (-not $text.Contains($rep.from)) {
        throw "replacement source not found in ${rel}: $($rep.from)"
      }
      $text = $text.Replace($rep.from, $rep.to)
    }
  }

  $text = Convert-ByteArrayLiterals $text
  $text = Remove-ChineseComments $text
  if ($rel.EndsWith('.ps1')) {
    $text = Add-WindowsGuard $text
  } else {
    $text = Add-CmdWindowsGuard $text
  }

  # hard guarantee: ASCII only, LF only, no BOM
  $nonAscii = @($text.ToCharArray() | Where-Object { [int]$_ -gt 127 })
  if ($nonAscii.Count -gt 0) {
    $sample = ($nonAscii | Select-Object -First 5 | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' '
    throw "${rel}: still contains non-ASCII characters ($sample)"
  }
  $text = $text -replace "`r`n", "`n"
  $packageText.Add("--- $rel`n$text")

  if ($Check) {
    $current = if (Test-Path $outPath) { [System.IO.File]::ReadAllText($outPath) } else { $null }
    if ($current -ne $text) { $drift.Add($rel) }
  } else {
    Write-TextFile $outPath $text
    $written++
  }
}

foreach ($rel in $copyBinaryFiles) {
  $srcPath = Join-Path $src $rel
  $outPath = Join-Path $out $rel
  if (-not (Test-Path $srcPath)) { throw "missing asset: $rel" }
  $bytes = [System.IO.File]::ReadAllBytes($srcPath)
  if ($Check) {
    $current = if (Test-Path $outPath) { [System.IO.File]::ReadAllBytes($outPath) } else { $null }
    if ($null -eq $current -or $current.Length -ne $bytes.Length) { $drift.Add($rel); continue }
    $same = $true
    for ($k = 0; $k -lt $bytes.Length; $k++) { if ($current[$k] -ne $bytes[$k]) { $same = $false; break } }
    if (-not $same) { $drift.Add($rel) }
  } else {
    $dir = Split-Path -Parent $outPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllBytes($outPath, $bytes)
    $written++
  }
}

# icon
$iconPath = Join-Path $out 'icon.png'
if ($Check) {
  if (-not (Test-Path $iconPath)) { $drift.Add('icon.png') }
} else {
  New-IslandIcon $iconPath
  $written++
}

# --- verification -------------------------------------------------------------

# The builder only writes; it never deletes. A file that used to be part of the
# package and is not any more would therefore silently stay in the output and
# ship. Catch that here instead of shipping a stale file.
$expected = New-Object System.Collections.Generic.HashSet[string]
foreach ($rel in $runtimeFiles) { [void]$expected.Add($rel) }
foreach ($rel in $copyBinaryFiles) { [void]$expected.Add($rel) }
[void]$expected.Add('icon.png')
foreach ($extra in @('.minimax-plugin/plugin.json', 'skills/mcode-island/SKILL.md', 'README.md', 'README.zh-CN.md')) {
  [void]$expected.Add($extra)
}
$stale = @()
if (Test-Path $out) {
  foreach ($f in (Get-ChildItem $out -Recurse -File -Force)) {
    $rel = $f.FullName.Substring($out.Length + 1) -replace '\\','/'
    if (-not $expected.Contains($rel)) { $stale += $rel }
  }
}
if ($stale.Count -gt 0) {
  throw ("the package contains files the builder does not produce (stale output): " + ($stale -join ', '))
}

# Nothing in a Marketplace package may read a credential, call an API or carry
# a Hook declaration. This is the guard that keeps the rejected build from
# coming back.
$scanTargets = @($runtimeFiles) + @('.minimax-plugin/plugin.json', 'skills/mcode-island/SKILL.md', 'README.md', 'README.zh-CN.md')
foreach ($rel in $scanTargets) {
  $p = Join-Path $out $rel
  if (-not (Test-Path $p)) { continue }
  $t = [System.IO.File]::ReadAllText($p)
  foreach ($pattern in $forbiddenPatterns.Keys) {
    if ($t.Contains($pattern)) {
      throw "${rel}: the package must not contain '$pattern' ($($forbiddenPatterns[$pattern]))"
    }
  }
}

if (-not $Check) {
  $problems = New-Object System.Collections.Generic.List[string]
  foreach ($rel in $runtimeFiles) {
    $outPath = Join-Path $out $rel
    if ($rel.EndsWith('.ps1')) {
      $errs = Get-ParseErrorCount $outPath
      if ($errs -gt 0) { $problems.Add("${rel}: $errs PowerShell parse error(s)") }
      $guard = [System.IO.File]::ReadAllText($outPath)
      if (-not $guard.Contains("Windows_NT")) { $problems.Add("${rel}: missing the Windows-only guard") }
    }
    $b = [System.IO.File]::ReadAllBytes($outPath)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
      $problems.Add("${rel}: still has a UTF-8 BOM")
    }
    $bad = 0
    foreach ($byte in $b) { if ($byte -gt 127) { $bad++ } }
    if ($bad -gt 0) { $problems.Add("${rel}: $bad non-ASCII byte(s)") }
  }
  if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "  FAIL $_" -ForegroundColor Red }
    throw 'package verification failed'
  }
  Write-Host "OK  built $written file(s) into $OutDir" -ForegroundColor Green
  Write-Host "OK  every .ps1 parses, is ASCII-only, has no BOM and carries the Windows guard" -ForegroundColor Green
  Write-Host "OK  no credential, no API endpoint, no Hook material in the package" -ForegroundColor Green
} else {
  if ($drift.Count -gt 0) {
    $drift | ForEach-Object { Write-Host "  DRIFT $_" -ForegroundColor Yellow }
    Write-Host "marketplace package is out of sync with $SourceDir" -ForegroundColor Yellow
    exit 1
  }
  Write-Host "OK  marketplace package is in sync with $SourceDir" -ForegroundColor Green
}
