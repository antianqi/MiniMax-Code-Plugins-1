# mcode-island -
# autostart.ps1 -Enable # widget + detector Run
# autostart.ps1 -Disable #
# autostart.ps1 -Status #
# widget start-island.ps1 detector
# widget detect-on Run key
# HKCU\...\Run\mcode-island start-island.ps1
# HKCU\...\Run\mcode-island-detect start-detect-island.ps1
# widget detector

param(
  [ValidateSet('Enable','Disable','Status')]
  [string]$Action = 'Status'
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

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# ordered hashtable detector widget Windows
$entries = [ordered]@{
  'mcode-island-detect' = (Join-Path $PSScriptRoot 'start-detect-island.ps1')
  'mcode-island'        = (Join-Path $PSScriptRoot 'start-island.ps1')
}

function Build-Command([string]$Launcher) {
  return "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Launcher`""
}

switch ($Action) {
  'Enable' {
 # Run
 # New-Item -Path $runKey -Force
 # HKCU\...\Run -Force
 # Everything / OneDrive /
 # New-ItemProperty
    if (-not (Test-Path $runKey)) {
      New-Item -Path $runKey -Force | Out-Null
    }

    $othersBefore = @((Get-Item -Path $runKey -ErrorAction SilentlyContinue).GetValueNames() |
      Where-Object { $entries.Keys -notcontains $_ })

    foreach ($name in $entries.Keys) {
      $cmd = Build-Command $entries[$name]
 # -Force
      New-ItemProperty -Path $runKey -Name $name -Value $cmd -PropertyType String -Force | Out-Null
      Write-Output "ENABLED: $runKey\$name"
      Write-Output "  Value: $cmd"
    }

    $othersAfter = @((Get-Item -Path $runKey -ErrorAction SilentlyContinue).GetValueNames() |
      Where-Object { $entries.Keys -notcontains $_ })
    $lost = @($othersBefore | Where-Object { $othersAfter -notcontains $_ })
    if ($lost.Count -gt 0) {
      Write-Output "ERROR: unrelated Run entries disappeared: $($lost -join ', ')"
      exit 1
    }
    if ($othersAfter.Count -gt 0) {
      Write-Output "  (kept $($othersAfter.Count) unrelated Run entr(y|ies))"
    }
  }
  'Disable' {
    $any = $false
    foreach ($name in $entries.Keys) {
      if (Get-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runKey -Name $name
        Write-Output "DISABLED: $name"
        $any = $true
      }
    }
    if (-not $any) { Write-Output 'DISABLED: not registered' }
  }
  'Status' {
    $any = $false
    foreach ($name in $entries.Keys) {
      $existing = Get-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
      if ($existing) {
        Write-Output "ENABLED: $name"
        Write-Output "  Value: $($existing.$name)"
        $any = $true
      } else {
        Write-Output "DISABLED: $name"
      }
    }
    if (-not $any) { Write-Output '' ; Write-Output '(no mcode-island entries registered)' }
  }
}
