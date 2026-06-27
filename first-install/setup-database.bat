@echo off
REM ============================================================================
REM  first-install\setup-database.bat  -  FIRST INSTALL ONLY (a brand-new customer).
REM ----------------------------------------------------------------------------
REM  Creates the ops database (if absent) + ALL tables idempotently (incl. the SQL
REM  credential/role/scope store dbo.app_user / app_user_scope), then seeds the 37
REM  milestone definitions. Run with a SQL login that can create the DB + tables.
REM
REM  >>> THIS IS NOT THE UPDATE SCRIPT. <<<
REM  To update an EXISTING customer site after pulling new code, close this and run
REM  ..\update-customer.bat instead. This script is only for a NEW, empty database.
REM
REM  A built-in detector first checks the target ops DB. If it already holds users
REM  or shipments, it STOPS and makes you type INSTALL to override - so a stray
REM  double-click on a live site cannot run setup by accident.
REM
REM  Usage (run from the repo root, pass the tenant config):
REM      first-install\setup-database.bat -ConfigPath .\ops.config.<tenant>.json
REM ============================================================================
setlocal
REM Run everything with the repo root as the working dir, so a relative -ConfigPath
REM (e.g. .\ops.config.acme.json) and the root .ps1 scripts both resolve correctly.
pushd "%~dp0.."

echo.
echo === FIRST-INSTALL: create the ops database + tables ===
echo.
echo [0/3] Checking whether the target database is already a LIVE customer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-installed.ps1" %*
set CHK=%errorlevel%

if "%CHK%"=="2" goto :installed
if "%CHK%"=="1" goto :unknown
goto :proceed

:installed
echo.
echo  **************************************************************************
echo  *  STOP: this database is ALREADY INSTALLED (it has users/shipments).    *
echo  *  setup-database is the FIRST-INSTALL path. Re-running it is additive    *
echo  *  and will NOT delete data, but you almost certainly want to UPDATE:     *
echo  *        close this window and run  ..\update-customer.bat                *
echo  **************************************************************************
echo.
set /p ANSWER="Type  INSTALL  to run first-install against this live DB anyway, or press Enter to cancel: "
if /I "%ANSWER%"=="INSTALL" goto :proceed
goto :cancel

:unknown
echo.
echo  Could not verify the database (see the message above). If you are SURE this is a
echo  brand-new install, continue; otherwise cancel and check OPS_CONFIG / the -ConfigPath.
echo.
set /p ANSWER="Type  INSTALL  to continue, or press Enter to cancel: "
if /I "%ANSWER%"=="INSTALL" goto :proceed
goto :cancel

:proceed
echo.
echo [1/3] Creating the ops database + tables...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\setup-ops.ps1" %*
if errorlevel 1 goto :fail

echo.
echo [2/3] Seeding milestone configuration (37 definitions, insert-missing-only)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\seed-milestone-config.ps1" %*
if errorlevel 1 goto :fail

echo.
echo [3/3] Done. Tables are ready.
echo   Next (FIRST INSTALL only): set OPS_ALLOW_SEED=1, then start the app with ..\start-dotnet.bat
echo         so it seeds the default admin/admin123; log in, create your real users, then clear OPS_ALLOW_SEED.
echo         Fill live data over the VPN with  ..\seed-data.bat .
popd
endlocal
pause
goto :eof

:cancel
echo.
echo Cancelled - nothing was changed. For a routine update use  ..\update-customer.bat .
popd
endlocal
pause
exit /b 0

:fail
echo.
echo setup-database FAILED - see the error above (is the SQL server reachable and the config correct?).
popd
endlocal
pause
exit /b 1
