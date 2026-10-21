# mcode-island - 5h API token
# set-token.ps1 <token> # token %APPDATA%\mcode-island\config.json
# set-token.ps1 -Show #
# set-token.ps1 -Clear # token
# token MINIMAX_OAUTH_TOKEN
# 1. $env:MINIMAX_OAUTH_TOKEN
# 2. $env:MINIMAX_API_KEY
# 3. config.json planApiToken
# set-token token

param(
  [Parameter(Position=0)]
  [string]$Token,
  [switch]$Show,
  [switch]$Clear
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$cfgDir = Join-Path $env:APPDATA 'mcode-island'
if (!(Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
$cfgFile = Join-Path $cfgDir 'config.json'

function Read-Cfg {
  if (Test-Path $cfgFile) {
    try { return (Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
  }
  return [PSCustomObject]@{}
}

function Write-Cfg($obj) {
  $obj | ConvertTo-Json | Out-File -FilePath $cfgFile -Encoding UTF8
}

if ($Show) {
  $cfg = Read-Cfg
  $hasCfg = $cfg.PSObject.Properties['planApiToken'] -and $cfg.planApiToken
  $hasEnv = $env:MINIMAX_OAUTH_TOKEN -or $env:MINIMAX_API_KEY
  if ($hasEnv) {
    $src = if ($env:MINIMAX_OAUTH_TOKEN) { 'env:MINIMAX_OAUTH_TOKEN' } else { 'env:MINIMAX_API_KEY' }
    Write-Output "token source: $src"
  } elseif ($hasCfg) {
    $masked = $cfg.planApiToken.Substring(0, [Math]::Min(10, $cfg.planApiToken.Length)) + '...'
    Write-Output "token source: config.json planApiToken ($masked)"
  } else {
    Write-Output "token not configured"
  }
  exit 0
}

if ($Clear) {
  $cfg = Read-Cfg
  if ($cfg.PSObject.Properties['planApiToken']) {
    $cfg.PSObject.Properties.Remove('planApiToken')
    Write-Cfg $cfg
    Write-Output 'planApiToken removed from config.json'
  } else {
    Write-Output 'config.json has no planApiToken, nothing to remove'
  }
  exit 0
}

if (-not $Token) {
  Write-Output 'usage: set-token.ps1 <token> | -Show | -Clear'
  exit 1
}

$cfg = Read-Cfg
if ($cfg.PSObject.Properties['planApiToken']) {
  $cfg.planApiToken = $Token
} else {
  $cfg | Add-Member -NotePropertyName 'planApiToken' -NotePropertyValue $Token
}
Write-Cfg $cfg
$masked = $Token.Substring(0, [Math]::Min(10, $Token.Length)) + '...'
Write-Output "written to $cfgFile"
Write-Output "  planApiToken: $masked"
Write-Output 'takes effect after restarting the detector: mcode-island detect-off && mcode-island detect-on'
