@echo off
REM ============================================================================
REM  update-customer.bat  -  ROUTINE UPDATE of an EXISTING customer site.
REM ----------------------------------------------------------------------------
REM  Run this ONE script on the customer server after pulling new program code.
REM  It does ONLY the safe, additive steps and then self-verifies the database:
REM      1. app offline
REM      2. setup-ops.ps1            - additive schema migration (new tables/columns
REM                                    only; NEVER overwrites users/roles/settings/data)
REM      3. seed-milestone-config    - INSERT-MISSING-ONLY (adds new milestone defs;
REM                                    preserves admin edits; no -Force here)
REM      4. dotnet publish (in place) + recycle the app pool
REM      5. verify-customer.ps1      - prints the resolved DB + user/table counts
REM
REM  It does NOT: reseed users, reset milestones, recreate the IIS site/pool, or
REM  backfill operational data. If this update ADDED A NEW WORKLIST SCAN COLUMN,
REM  run seed-data.bat (or seed-alerts.ps1 per station) afterwards to backfill it.
REM
REM  >>> EDIT the three settings below per site (or set them as environment vars). <<<
REM  ROOT   = repo root on this server (contains server\ + the .ps1 scripts)
REM  CONFIG = the tenant config file (the same one OPS_CONFIG points at)
REM  POOL   = the IIS application pool name for this site
REM ============================================================================
setlocal
if "%ROOT%"==""   set ROOT=C:\erp-operation
if "%CONFIG%"=="" set CONFIG=ops.config.json
if "%POOL%"==""   set POOL=erpops
set APPCMD=%windir%\System32\inetsrv\appcmd.exe
set PUB=%ROOT%\server\publish

echo.
echo === Updating customer site ===
echo   ROOT   = %ROOT%
echo   CONFIG = %CONFIG%
echo   POOL   = %POOL%
echo.

echo [1/5] Taking the app offline...
echo offline > "%PUB%\app_offline.htm" 2>nul

echo [2/5] Migrating schema (additive, non-destructive)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\setup-ops.ps1" -ConfigPath "%ROOT%\%CONFIG%"
if errorlevel 1 goto :fail

echo [3/5] Seeding any NEW milestone defs (insert-only; edits preserved)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\seed-milestone-config.ps1" -ConfigPath "%ROOT%\%CONFIG%"
if errorlevel 1 goto :fail

echo [4/5] Publishing the program + recycling the pool...
pushd "%ROOT%\server"
dotnet publish -c Release -o publish --nologo
set PUBERR=%errorlevel%
popd
del "%PUB%\app_offline.htm" 2>nul
if not "%PUBERR%"=="0" goto :fail
"%APPCMD%" recycle apppool /apppool.name:"%POOL%"

echo [5/5] Verifying the database...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\verify-customer.ps1" -ConfigPath "%ROOT%\%CONFIG%"
if errorlevel 1 goto :verifyfail

echo.
echo Update complete. Open the site and confirm your users still appear in Admin -^> Users.
echo If a new worklist scan column was added this update, run seed-data.bat to backfill old rows.
endlocal
goto :eof

:fail
del "%PUB%\app_offline.htm" 2>nul
echo.
echo UPDATE FAILED - see the error above. The app may be offline; re-run once fixed.
endlocal
exit /b 1

:verifyfail
echo.
echo VERIFICATION WARNING - the database check did not pass (see above). The app is running, but
echo confirm OPS_CONFIG / OPS_ROOT point at the correct database before relying on this site.
endlocal
exit /b 2
