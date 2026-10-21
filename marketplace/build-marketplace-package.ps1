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
    * user-visible Chinese in the WPF XAML survives as XML numeric character
      references, and in PowerShell strings as ([char]0x..) code points
    * Chinese comments are removed (the upstream copy keeps them; the .md files
      in this package keep the Chinese documentation)
    * the Hook client extension (io.minimax.mcode/), the Claude-format manifest
      (.claude-plugin/), the agent-plugins.org manifest and the dev-only
      smoke/test scripts are NOT part of a Marketplace package

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
# The hooks tree, .claude-plugin/, the agent-plugins.org plugin.json, the
# *.bak-r16 backup and the smoke/test scripts are intentionally excluded.
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
  'set-token.ps1'
  'start-detect-island.ps1'
  'status-detect-island.ps1'
  'stop-detect-island.ps1'
  'scripts/lib/Get-5hUsage.ps1'
  'scripts/lib/Protect-Text.ps1'
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

# --- code-level Chinese -> ASCII-safe equivalents -----------------------------
# Console diagnostics become English. The WPF XAML keeps its Chinese copy by
# using XML numeric character references; PowerShell string literals use
# ([char]0x..) code points, both of which keep the file pure ASCII.
$replacements = [ordered]@{
  'mcode-island.ps1' = @(
    @{ from = 'ToolTip="mmx 5h 用量（来自 coding_plan/remains）"'
       to   = 'ToolTip="mmx 5h &#x7528;&#x91CF;&#xFF08;&#x6765;&#x81EA;coding_plan/remains&#xFF09;"' }
    @{ from = 'Text="等待任务"'
       to   = 'Text="&#x7B49;&#x5F85;&#x4EFB;&#x52A1;"' }
    @{ from = "label='mcode · 思考中'"
       to   = "label=('mcode ' + [char]0xB7 + ' ' + [char]0x601D + [char]0x8003 + [char]0x4E2D)" }
    @{ from = "label='mcode · 执行中'"
       to   = "label=('mcode ' + [char]0xB7 + ' ' + [char]0x6267 + [char]0x884C + [char]0x4E2D)" }
    @{ from = "label='mcode · 等待审批'"
       to   = "label=('mcode ' + [char]0xB7 + ' ' + [char]0x7B49 + [char]0x5F85 + [char]0x5BA1 + [char]0x6279)" }
    @{ from = "label='mcode · 已完成'"
       to   = "label=('mcode ' + [char]0xB7 + ' ' + [char]0x5DF2 + [char]0x5B8C + [char]0x6210)" }
    @{ from = "label='mcode · 出错'"
       to   = "label=('mcode ' + [char]0xB7 + ' ' + [char]0x51FA + [char]0x9519)" }
    @{ from = "icon='⚙'"
       to   = 'icon=([char]0x2699)' }
    @{ from = "icon='✓'"
       to   = 'icon=([char]0x2713)' }
    @{ from = "icon='✕'"
       to   = 'icon=([char]0x2715)' }
    @{ from = '"$stepStr · $Detail"'
       to   = '"$stepStr $([char]0xB7) $Detail"' }
  )
  'mcode-status-detect.ps1' = @(
    @{ from = '.mcode-active not found at $mcodeActiveDir — mcode not running or different layout'
       to   = '.mcode-active not found at $mcodeActiveDir - mcode not running or different layout' }
  )
  'scripts/lib/Protect-Text.ps1' = @(
    @{ from = @'
# There are two independent producers of that text:
#
#   1. the hook path  -- io.minimax.mcode/hooks/scripts/_lib.ps1
#   2. the detector   -- mcode-status-detect.ps1, which re-derives
#                        messages from mcode's own session log rather than
#                        from a hook event
#
# A helper wired into only one of them is a silent half-fix: the pill looks
# clean while the detector keeps writing the raw text to disk. Both
# dot-source this file. scripts/smoke.mjs check 9 asserts BOTH consumers
# actually invoke the function, not merely that it is defined.
'@
       to   = @'
# One producer of that text:
#
#   1. the detector -- mcode-status-detect.ps1, which re-derives
#                     messages from mcode's own session log
#
# The detector dot-sources this file, so the redaction happens before the
# command text reaches disk.
'@ }
  )
  'wrap-tool.ps1' = @(
    @{ from = '"$brief 完成"'
       to   = '"$brief $([char]0x5B8C)$([char]0x6210)"' }
    @{ from = '"read 完成"'
       to   = '"read $([char]0x5B8C)$([char]0x6210)"' }
    @{ from = '"write 完成"'
       to   = '"write $([char]0x5B8C)$([char]0x6210)"' }
    @{ from = '"edit 完成"'
       to   = '"edit $([char]0x5B8C)$([char]0x6210)"' }
    @{ from = '"glob 完成"'
       to   = '"glob $([char]0x5B8C)$([char]0x6210)"' }
    @{ from = '"grep 完成"'
       to   = '"grep $([char]0x5B8C)$([char]0x6210)"' }
    @{ from = "'web 完成'"
       to   = "'web ' + [char]0x5B8C + [char]0x6210" }
    @{ from = "'task 完成'"
       to   = "'task ' + [char]0x5B8C + [char]0x6210" }
    @{ from = "'notebook 完成'"
       to   = "'notebook ' + [char]0x5B8C + [char]0x6210" }
    @{ from = '"$Tool 完成"'
       to   = '"$Tool $([char]0x5B8C)$([char]0x6210)"' }
    @{ from = '"$Tool 等待审批 (exit=$ExitCode)"'
       to   = '"$Tool $([char]0x7B49)$([char]0x5F85)$([char]0x5BA1)$([char]0x6279) (exit=$ExitCode)"' }
    @{ from = '"$Tool 失败 (exit=$ExitCode)"'
       to   = '"$Tool $([char]0x5931)$([char]0x8D25) (exit=$ExitCode)"' }
  )
  'start-island.ps1' = @(
    @{ from = '("已在运行（PID " + $old + "）")'
       to   = '("already running (PID " + $old + ")")' }
    @{ from = '("mcode-island 已启动 (PID " + $proc.Id + "，已就绪)")'
       to   = '("mcode-island started (PID " + $proc.Id + ", ready)")' }
    @{ from = '("mcode-island 已启动 (PID " + $proc.Id + "，等待中...)")'
       to   = '("mcode-island started (PID " + $proc.Id + ", waiting...)")' }
  )
  'set-token.ps1' = @(
    @{ from = '"token 来源: $src"'
       to   = '"token source: $src"' }
    @{ from = '"token 来源: config.json planApiToken ($masked)"'
       to   = '"token source: config.json planApiToken ($masked)"' }
    @{ from = '"token 未配置"'
       to   = '"token not configured"' }
    @{ from = "'已从 config.json 删除 planApiToken'"
       to   = "'planApiToken removed from config.json'" }
    @{ from = "'config.json 没有 planApiToken，无需删除'"
       to   = "'config.json has no planApiToken, nothing to remove'" }
    @{ from = "'用法: set-token.ps1 <token> | -Show | -Clear'"
       to   = "'usage: set-token.ps1 <token> | -Show | -Clear'" }
    @{ from = '"已写入 $cfgFile"'
       to   = '"written to $cfgFile"' }
    @{ from = "'重启 detector 后生效: mcode-island detect-off && mcode-island detect-on'"
       to   = "'takes effect after restarting the detector: mcode-island detect-off && mcode-island detect-on'" }
  )
  'autostart.ps1' = @(
    @{ from = "'DISABLED: 本来就没注册'"
       to   = "'DISABLED: not registered'" }
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
}

# --- helpers ------------------------------------------------------------------

# Every character outside printable ASCII (plus tab) is stripped from comments:
# CJK, fullwidth forms, em dashes and arrows all have to go, because a
# BOM-less .ps1 is read with the ANSI code page by Windows PowerShell 5.1.
$nonAsciiPattern = '[^\u0020-\u007E\t]'

function Remove-NonAscii {
  param([string]$Text)
  return [regex]::Replace($Text, $nonAsciiPattern, '')
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
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.Clear([System.Drawing.Color]::Transparent)

  function New-Brush([string]$hex) {
    return New-Object System.Drawing.SolidBrush(
      [System.Drawing.ColorTranslator]::FromHtml($hex))
  }

  # app tile background
  $bg = New-Brush '#FF0B0E14'
  $g.FillEllipse($bg, 0, 0, $size, $size)
  $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
  $r = 112.0
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

foreach ($rel in $runtimeFiles) {
  $srcPath = Join-Path $src $rel
  $outPath = Join-Path $out $rel
  if (-not (Test-Path $srcPath)) { throw "missing runtime file: $rel" }

  $bytes = [System.IO.File]::ReadAllBytes($srcPath)
  $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
  if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

  if ($replacements.Contains($rel)) {
    foreach ($rep in $replacements[$rel]) {
      if (-not $text.Contains($rep.from)) {
        throw "replacement source not found in ${rel}: $($rep.from)"
      }
      $text = $text.Replace($rep.from, $rep.to)
    }
  }

  $text = Remove-ChineseComments $text

  # hard guarantee: ASCII only, LF only, no BOM
  $nonAscii = @($text.ToCharArray() | Where-Object { [int]$_ -gt 127 })
  if ($nonAscii.Count -gt 0) {
    $sample = ($nonAscii | Select-Object -First 5 | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' '
    throw "${rel}: still contains non-ASCII characters ($sample)"
  }
  $text = $text -replace "`r`n", "`n"

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

if (-not $Check) {
  $problems = New-Object System.Collections.Generic.List[string]
  foreach ($rel in $runtimeFiles) {
    $outPath = Join-Path $out $rel
    if ($rel.EndsWith('.ps1')) {
      $errs = Get-ParseErrorCount $outPath
      if ($errs -gt 0) { $problems.Add("${rel}: $errs PowerShell parse error(s)") }
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
  Write-Host "OK  every .ps1 parses and is ASCII-only without a BOM" -ForegroundColor Green
} else {
  if ($drift.Count -gt 0) {
    $drift | ForEach-Object { Write-Host "  DRIFT $_" -ForegroundColor Yellow }
    Write-Host "marketplace package is out of sync with $SourceDir" -ForegroundColor Yellow
    exit 1
  }
  Write-Host "OK  marketplace package is in sync with $SourceDir" -ForegroundColor Green
}
