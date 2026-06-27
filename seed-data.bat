@echo off
REM ============================================================================
REM  seed-data.bat  -  fill LIVE data after first-install\setup-database.bat + first app start.
REM ----------------------------------------------------------------------------
REM  Runs the read-from-ERP seeders in order, looping every configured station x
REM  Sea/Air: station map, port + liner masters, the cross-station inbound feed,
REM  and the worklist (shipment_alerts, as of today). Reads the READ-ONLY source
REM  ERP over the Swivel VPN -> THE VPN MUST BE UP. Writes only the ops DB.
REM
REM  Idempotent: re-run any time to refresh. Ongoing refresh is scheduled
REM  separately by register-ops-tasks.ps1 (run elevated); this is the initial fill.
REM  Pass the tenant config through, e.g.:  seed-data.bat -ConfigPath .\ops.config.demoerp.json
REM ============================================================================
echo Filling live data from the ERP (the Swivel VPN must be up)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0seed-data.ps1" %*
if errorlevel 1 goto :fail
echo.
echo Done. Browse the app and confirm the worklist loads.
pause
goto :eof
:fail
echo.
echo seed-data reported failures - see the log above (VPN up? stations correct in the config?).
pause
exit /b 1
