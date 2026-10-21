# mcode-island -
# autostart.ps1 -Enable # widget + detector Run
# autostart.ps1 -Disable #
# autostart.ps1 -Status #
# widgetstart-island.ps1detector
# widget detect-on Run key
# HKCU\...\Run\mcode-island start-island.ps1
# HKCU\...\Run\mcode-island-detect start-detect-island.ps1
# widget detector

param(
  [ValidateSet('Enable','Disable','Status')]
  [string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# ordered hashtable detector widgetWindows
$entries = [ordered]@{
  'mcode-island-detect' = (Join-Path $PSScriptRoot 'start-detect-island.ps1')
  'mcode-island'        = (Join-Path $PSScriptRoot 'start-island.ps1')
}

function Build-Command([string]$Launcher) {
  return "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Launcher`""
}

switch ($Action) {
  'Enable' {
    New-Item -Path $runKey -Force | Out-Null
    foreach ($name in $entries.Keys) {
      $cmd = Build-Command $entries[$name]
      Set-ItemProperty -Path $runKey -Name $name -Value $cmd
      Write-Output "ENABLED: $runKey\$name"
      Write-Output "  Value: $cmd"
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
