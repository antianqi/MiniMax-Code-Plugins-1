# Safe traversal of the sessions root (round-24 review, hetaoBackend).
# scanner
# [System.IO.Directory]::EnumerateDirectories($root, '*session_*', 'AllDirectories')
# [System.IO.Directory]::EnumerateFiles($sessionsRoot, '*.jsonl', 'AllDirectories')
# SearchOption.AllDirectories ** reparse point**
# junction
# https://learn.microsoft.com/en-us/dotnet/api/system.io.searchoption?view=net-10.0
# sessions junction
# sessions root detector jsonl
# 1. AllDirectories
# SearchOption.TopDirectoryOnly
# 2. reparse point
# root
# 3. " " containment
# root root
# 4. reparse point jsonl
# 5. junction junction
# root reparse point
# sessions junction root

# reparse point
# true fail closed

# mcode-island runs on Windows only: the status pill is a WPF window and the
# autostart entry is a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
# On any other platform fail with a clear message instead of a cryptic WPF or
# registry error.
if ($env:OS -ne 'Windows_NT') {
  Write-Output 'mcode-island supports Windows only (this host is not Windows).'
  exit 1
}
function Test-PathIsReparsePoint([string]$Path) {
    if (-not $Path) { return $true }
    try {
        $attr = [System.IO.File]::GetAttributes($Path)
        return (($attr -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
    } catch {
        return $true
    }
}

# $Candidate $RootFull
# C:sessions-evil C:sessions
# root " "
function Test-PathContained([string]$RootFull, [string]$Candidate) {
    if (-not $RootFull -or -not $Candidate) { return $false }
    try {
        $c = [System.IO.Path]::GetFullPath($Candidate)
        $r = [System.IO.Path]::GetFullPath($RootFull)
    } catch {
        return $false
    }
    if ($c -eq $r) { return $false }
    $prefix = $r.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return $c.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

# $Root $Pattern
# -Files
# -Pattern pattern EnumerateXxx(root, pat,
# AllDirectories) pattern
# -MaxDepth
# reparse point root
function Get-SafeSessionEntries {
    param(
        [string]$Root,
        [string]$Pattern = '*',
        [switch]$Files,
        [int]$MaxDepth = 16
    )
    $out = New-Object System.Collections.ArrayList
    if (-not $Root) { return $out }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { return $out }
    if (-not (Test-Path -LiteralPath $rootFull)) { return $out }

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = $rootFull; Depth = 0 })

    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if ($cur.Depth -gt $MaxDepth) { continue }
        $dir = $cur.Path

        if ($Files) {
            try {
                foreach ($f in [System.IO.Directory]::EnumerateFiles($dir, $Pattern, [System.IO.SearchOption]::TopDirectoryOnly)) {
                    if (Test-PathIsReparsePoint $f) { continue }
                    if (-not (Test-PathContained $rootFull $f)) { continue }
                    [void]$out.Add($f)
                }
            } catch { }
        }

        try {
 # ** ** pattern
 # pattern " " " "
 # EnumerateDirectories(root, '*session_*', AllDirectories)
 # sessions <Y>/<M>/<D>/...
 # session_ pattern
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir, '*', [System.IO.SearchOption]::TopDirectoryOnly)) {
                if (-not (Test-PathContained $rootFull $d)) { continue }
 # reparse point
                if (Test-PathIsReparsePoint $d) { continue }
                if (-not $Files) {
                    $leaf = [System.IO.Path]::GetFileName($d)
                    if ($leaf -like $Pattern) { [void]$out.Add($d) }
                }
                $queue.Enqueue([pscustomobject]@{ Path = $d; Depth = $cur.Depth + 1 })
            }
        } catch { }
    }
    return $out
}
