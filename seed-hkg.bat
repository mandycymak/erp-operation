@echo off
setlocal
REM ---------------------------------------------------------------------------
REM seed-hkg.bat - repeatable HKG worklist delta refresh (Sea + Air).
REM   Reads the READ-ONLY source ERP (fm3khkg) over the VPN and writes the
REM   configured ops DB. Run it whenever a new/edited HKG shipment should show
REM   up without waiting for a scheduled refresh.
REM
REM   Usage:  seed-hkg.bat [config-file]
REM           (no arg = ops.config.demoerp.json next to this script)
REM   Pre-req: VPN up (source ERP 192.168.5.2 reachable) + write access to the
REM            ops DB named in the config (opsServer/opsDb).
REM ---------------------------------------------------------------------------
set "CFG=%~1"
if "%CFG%"=="" set "CFG=%~dp0ops.config.demoerp.json"

echo === HKG Sea (delta) ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0seed-alerts.ps1" -ConfigPath "%CFG%" -Station fm3khkg -StationCode HKG -Mode Sea -Delta -Limit 200

echo === HKG Air (delta) ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0seed-alerts.ps1" -ConfigPath "%CFG%" -Station fm3khkg -StationCode HKG -Mode Air -Delta -Limit 200

echo === Done ===
endlocal
