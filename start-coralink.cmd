@echo off
rem Double-click to start Coralink server. To stop, run:  start-coralink.cmd stop
cd /d "%~dp0"
if "%1"=="stop" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-coralink.ps1" -Stop
) else if "%1"=="status" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-coralink.ps1" -Status
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-coralink.ps1"
)
echo.
pause
