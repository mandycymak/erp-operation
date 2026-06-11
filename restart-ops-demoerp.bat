@echo off
REM ============================================================================
REM  Restart the Control Tower - DEMOERP instance (source server 192.168.5.2).
REM  Reads ops.config.demoerp.json, serves on http://localhost:8079/.
REM  Stops any running instance on this port first, then starts a fresh one.
REM  Leave this window open while in use.
REM ============================================================================
setlocal
set PORT=8079
set CONFIG=ops.config.demoerp.json

echo Stopping any running Control Tower on port %PORT% ...
REM Exclude $PID so this kill command (whose own command line contains 'serve-ops' and the port) never kills itself.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'serve-ops\.ps1' -and $_.CommandLine -match '%PORT%' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"

echo Starting Control Tower (DEMOERP) at http://localhost:%PORT%/
echo Press Ctrl+C here to stop.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve-ops.ps1" -ConfigPath "%~dp0%CONFIG%" -Port %PORT% %*
pause
