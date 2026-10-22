@echo off
if not "%OS%"=="Windows_NT" (
  echo mcode-island supports Windows only - this host is not Windows.
  exit /b 1
)
chcp 65001 >nul
setlocal
set "SCRIPT_DIR=%~dp0"
set "PS=powershell.exe -NoProfile -ExecutionPolicy Bypass"

if "%1"=="" goto :start
if /i "%1"=="start" goto :start
if /i "%1"=="stop" goto :stop
if /i "%1"=="status" goto :status
if /i "%1"=="show" goto :show
if /i "%1"=="hide" goto :hide
if /i "%1"=="pin" goto :pin
if /i "%1"=="unpin" goto :unpin
if /i "%1"=="autostart-on" goto :autostart_on
if /i "%1"=="autostart-off" goto :autostart_off
if /i "%1"=="detect-on" goto :detect_on
if /i "%1"=="detect-off" goto :detect_off
if /i "%1"=="detect-status" goto :detect_status


echo Usage: mcode-island {start ^| stop ^| status ^| show ^| hide ^| pin ^| unpin ^| autostart-on ^| autostart-off ^| detect-on ^| detect-off ^| detect-status}
exit /b 1

:start
%PS% -File "%SCRIPT_DIR%start-island.ps1"
exit /b %errorlevel%

:stop
%PS% -File "%SCRIPT_DIR%stop-island.ps1"
exit /b %errorlevel%

:status
%PS% -File "%SCRIPT_DIR%status-island.ps1"
exit /b %errorlevel%

:show
%PS% -File "%SCRIPT_DIR%show-island.ps1"
exit /b %errorlevel%

:hide
echo (Alt+F4 now hides the widget; use "mcode-island show" to bring it back)
exit /b 0

:pin
%PS% -File "%SCRIPT_DIR%pin-island.ps1"
exit /b %errorlevel%

:unpin
%PS% -Command "Remove-Item -Path (Join-Path $env:APPDATA 'mcode-island\caller.json') -ErrorAction SilentlyContinue; Write-Output 'unpinned: caller.json cleared'"
exit /b %errorlevel%

:autostart_on
%PS% -File "%SCRIPT_DIR%autostart.ps1" -Action Enable
exit /b %errorlevel%

:autostart_off
%PS% -File "%SCRIPT_DIR%autostart.ps1" -Action Disable
exit /b %errorlevel%

:detect_on
%PS% -File "%SCRIPT_DIR%start-detect-island.ps1"
exit /b %errorlevel%

:detect_off
%PS% -File "%SCRIPT_DIR%stop-detect-island.ps1"
exit /b %errorlevel%

:detect_status
%PS% -File "%SCRIPT_DIR%status-detect-island.ps1"
exit /b %errorlevel%


