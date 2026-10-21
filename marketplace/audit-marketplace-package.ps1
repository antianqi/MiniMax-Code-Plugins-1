#Requires -Version 7.0
# Compliance audit for a MiniMax Marketplace package.
# Usage: pwsh -File audit-marketplace-package.ps1 -PackageDir <dir>
param(
  [Parameter(Mandatory)][string]$PackageDir
)
$ErrorActionPreference = 'Stop'

$fails = New-Object System.Collections.Generic.List[string]
$passes = 0
function Check([bool]$ok, [string]$label, [string]$detail = '') {
  if ($ok) { $script:passes++; Write-Host "  PASS  $label" -ForegroundColor DarkGreen }
  else { $script:fails.Add("$label :: $detail"); Write-Host "  FAIL  $label :: $detail" -ForegroundColor Red }
}

$pkg = (Resolve-Path $PackageDir).Path
Write-Host "auditing $pkg" -ForegroundColor Cyan

$allFiles = Get-ChildItem $pkg -Recurse -File -Force

# --- 1. entry point -----------------------------------------------------------
$manifestPath = Join-Path $pkg '.minimax-plugin/plugin.json'
Check (Test-Path $manifestPath) '.minimax-plugin/plugin.json exists'
if (-not (Test-Path $manifestPath)) { throw 'no manifest' }

$mb = [System.IO.File]::ReadAllBytes($manifestPath)
$hasBom = $mb.Length -ge 3 -and $mb[0] -eq 0xEF -and $mb[1] -eq 0xBB -and $mb[2] -eq 0xBF
Check (-not $hasBom) 'manifest has no UTF-8 BOM'

$manifestText = (New-Object System.Text.UTF8Encoding($false)).GetString($mb)
$manifest = $manifestText | ConvertFrom-Json
Check ($manifest -is [psobject]) 'manifest top level is an object'

# duplicate key detection: ConvertFrom-Json silently keeps the last one
$dupKeys = @()
foreach ($line in ($manifestText -split "`n")) {
  $t = $line.Trim()
  if ($t -match '^"([^"]+)"\s*:') {
    $k = $Matches[1]
    if ($dupKeys -contains $k) { } else { $dupKeys += $k }
  }
}
$rawKeyCount = ([regex]::Matches($manifestText, '(?m)^\s*"[^"]+"\s*:')).Count
$parsedKeyCount = @($manifest.PSObject.Properties).Count
Check ($rawKeyCount -eq $parsedKeyCount) 'manifest has no duplicate keys' "raw=$rawKeyCount parsed=$parsedKeyCount"

# --- 2. required manifest fields ---------------------------------------------
foreach ($f in @('schemaVersion','name','displayName','version','description','author','icon','category','exampleQueries','apps','mcpServers','skills')) {
  Check ($manifest.PSObject.Properties.Name -contains $f) "manifest has field '$f'"
}
Check ($manifest.schemaVersion -eq 1) 'schemaVersion is 1' ([string]$manifest.schemaVersion)
Check ($manifest.name -match '^[a-z][a-z0-9]*([._-][a-z0-9]+)*$') 'name matches the form rule' ([string]$manifest.name)
Check ($manifest.name.Length -le 80) 'name <= 80 chars'
Check ($manifest.name -ceq (Split-Path $pkg -Leaf)) 'package dir name equals manifest name' "dir=$(Split-Path $pkg -Leaf) name=$($manifest.name)"
Check (@($manifest.exampleQueries).Count -le 3) 'exampleQueries <= 3' ([string]@($manifest.exampleQueries).Count)
Check (@($manifest.skills).Count -ge 1 -or @($manifest.mcpServers).Count -ge 1 -or @($manifest.apps).Count -ge 1) 'package declares at least one capability'
foreach ($s in @($manifest.skills)) {
  Check (Test-Path (Join-Path $pkg $s)) "referenced skill exists: $s"
}

# --- 3. icon ------------------------------------------------------------------
$iconRel = [string]$manifest.icon
Check ($iconRel -match '\.(png|jpg|jpeg|webp)$') 'icon extension is lowercase png/jpg/jpeg/webp' $iconRel
$iconPath = Join-Path $pkg $iconRel
Check (Test-Path $iconPath) 'icon file exists' $iconRel
if (Test-Path $iconPath) {
  $ib = [System.IO.File]::ReadAllBytes($iconPath)
  $isPng = $ib.Length -gt 8 -and $ib[0] -eq 0x89 -and $ib[1] -eq 0x50 -and $ib[2] -eq 0x4E -and $ib[3] -eq 0x47
  Check $isPng 'icon is a PNG'
  Add-Type -AssemblyName System.Drawing
  $img = [System.Drawing.Image]::FromFile($iconPath)
  Check ($img.Width -eq $img.Height) 'icon is square' "$($img.Width)x$($img.Height)"
  $img.Dispose()
}

# --- 4. skill frontmatter -----------------------------------------------------
foreach ($s in @($manifest.skills)) {
  $skillPath = Join-Path $pkg $s
  if (-not (Test-Path $skillPath)) { continue }
  $text = [System.IO.File]::ReadAllText($skillPath)
  Check ($text.StartsWith("---`n") -or $text.StartsWith("---`r`n")) "$s starts with YAML frontmatter"
  $end = $text.IndexOf("`n---", 3)
  if ($end -gt 0) {
    $fm = $text.Substring(3, $end - 3)
    $nameMatch = [regex]::Match($fm, '(?m)^name:\s*(.+)$')
    $descMatch = [regex]::Match($fm, '(?m)^description:\s*(.+)$')
    Check ($nameMatch.Success) "$s frontmatter has name"
    if ($nameMatch.Success) {
      $expected = Split-Path (Split-Path $skillPath -Parent) -Leaf
      Check ($nameMatch.Groups[1].Value.Trim() -eq $expected) "$s frontmatter name equals its directory" "fm=$($nameMatch.Groups[1].Value.Trim()) dir=$expected"
    }
    Check ($descMatch.Success) "$s frontmatter has description"
    if ($descMatch.Success) {
      $d = $descMatch.Groups[1].Value.Trim()
      Check ($d.Length -gt 0 -and $d.Length -le 1024) "$s description length in 1..1024" "len=$($d.Length)"
    }
  }
  $body = $text.Substring($end + 4)
  Check ($body.Trim().Length -gt 0) "$s has a non-empty body"
}

# --- 5. package-wide file rules ----------------------------------------------
foreach ($f in $allFiles) {
  $rel = $f.FullName.Substring($pkg.Length + 1) -replace '\\','/'
  Check ($rel -match '^[\x20-\x7E]+$') "path is printable ASCII: $rel"
  Check ($f.Attributes -notmatch 'ReparsePoint') "not a symlink: $rel"
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  $isText = $f.Extension -in @('.ps1','.cmd','.json','.md','.txt','.mjs','.js','.yml','.yaml')
  if ($isText) {
    Check (-not $bom) "text file has no BOM: $rel"
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
    if ($f.Extension -in @('.ps1','.cmd')) {
      Check ($nonAscii -eq 0) "script file is ASCII-only: $rel" "$nonAscii non-ASCII byte(s)"
    }
  }
  Check (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0x76 -and $bytes[1] -eq 0x65 -and $bytes[2] -eq 0x72)) "not a Git LFS pointer: $rel"
}

# --- 6. no hooks --------------------------------------------------------------
$hookHits = @()
foreach ($f in $allFiles) {
  if ($f.Extension -notin @('.ps1','.cmd','.json','.md')) { continue }
  $t = [System.IO.File]::ReadAllText($f.FullName)
  if ($t -match '(?i)hook') { $hookHits += $f.FullName.Substring($pkg.Length + 1) }
}
Check ($hookHits.Count -eq 0) 'package contains no Hook material' ($hookHits -join ', ')

# --- 7. no secrets ------------------------------------------------------------
$secretHits = @()
foreach ($f in $allFiles) {
  if ($f.Extension -notin @('.ps1','.cmd','.json','.md')) { continue }
  $t = [System.IO.File]::ReadAllText($f.FullName)
  foreach ($pat in @('sk-[A-Za-z0-9]{16,}', 'Bearer\s+[A-Za-z0-9\-_\.]{20,}', '"?(api[_-]?key|secret|access[_-]?token|client[_-]?secret)"?\s*[:=]\s*["''][^"'']{12,}["'']')) {
    if ($t -match $pat) { $secretHits += "$($f.Name): $pat" }
  }
}
Check ($secretHits.Count -eq 0) 'package contains no credential-looking literal' ($secretHits -join '; ')

# --- 8. no hardcoded host paths ----------------------------------------------
$pathHits = @()
foreach ($f in $allFiles) {
  if ($f.Extension -notin @('.ps1','.cmd','.json')) { continue }
  $t = [System.IO.File]::ReadAllText($f.FullName)
  if ($t -match '(?m)([A-Za-z]:\\Users\\|/Users/|/home/|C:\\Users\\)') { $pathHits += $f.Name }
}
Check ($pathHits.Count -eq 0) 'no hardcoded host paths' (($pathHits | Sort-Object -Unique) -join ', ')

# --- 9. scripts still parse ---------------------------------------------------
foreach ($f in $allFiles | Where-Object { $_.Extension -eq '.ps1' }) {
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
  Check ($errors.Count -eq 0) "PowerShell parses cleanly: $($f.Name)" "$($errors.Count) error(s)"
}

# --- 10. package size limits --------------------------------------------------
$totalBytes = ($allFiles | Measure-Object Length -Sum).Sum
Check ($allFiles.Count -le 1024) 'file count <= 1024' ([string]$allFiles.Count)
Check ($totalBytes -le 64MB) 'unpacked total <= 64 MiB' ("{0:N0} bytes" -f $totalBytes)
$longest = 0; $deepest = 0
foreach ($f in $allFiles) {
  $rel = $f.FullName.Substring($pkg.Length + 1) -replace '\\','/'
  $longest = [Math]::Max($longest, $rel.Length)
  $deepest = [Math]::Max($deepest, ($rel -split '/').Count)
}
Check ($longest -le 512) 'longest path <= 512 bytes' ([string]$longest)
Check ($deepest -le 16) 'path depth <= 16 segments' ([string]$deepest)

Write-Host ''
Write-Host "passed: $passes   failed: $($fails.Count)" -ForegroundColor $(if ($fails.Count) { 'Red' } else { 'Green' })
if ($fails.Count -gt 0) { $fails | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }; exit 1 }
