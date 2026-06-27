@echo off
REM ============================================================================
REM  setup-database.bat  -  RUN THIS ONCE ON A FRESH DEPLOY, BEFORE start-dotnet.
REM ----------------------------------------------------------------------------
REM  Creates the ops database (if absent) + ALL ~21 tables idempotently, including
REM  the SQL credential/role/scope store (no credential file on the box):
REM      dbo.app_user / app_user_scope   - logins + roles + row-level scope
REM      dbo.erp_api_log                 - every ERP API call + error (admin view)
REM      ... plus shipment_alerts, milestone_*, doc_*, inbound feed, audit logs.
REM  Then seeds the 37 milestone definitions (the worklist matrix config).
REM
REM  The DEFAULT ADMIN (admin / admin123) is created the first time the .NET server
REM  starts against an EMPTY app_user table - but ONLY when OPS_ALLOW_SEED=1 is set
REM  (server/Auth.cs). Set OPS_ALLOW_SEED=1 for this first install, log in, create
REM  your real users, then unset it. (The guard stops a later mis-pointed deploy from
REM  silently re-seeding admin123 against the wrong DB and "losing" your users.)
REM
REM  SAFE / NON-DESTRUCTIVE to re-run: setup-ops creates only missing tables, and the
REM  milestone seed is INSERT-MISSING-ONLY (it preserves any milestones an admin edited
REM  in the UI; pass -Force only if you want to RESET them to defaults). It never
REM  overwrites users, roles, scope, app_setting, or shipment data.
REM
REM  >>> For a ROUTINE UPDATE of an existing customer site, do NOT run this .bat.
REM      Run setup-ops.ps1 (schema only) + redeploy. This .bat is the FIRST-INSTALL path.
REM
REM  Run with a SQL login that can create the DB + tables (DDL). Connection + DB names
REM  come from the config (env DB_*/OPS_* win).
REM  Pass the tenant config through, e.g.:  setup-database.bat -ConfigPath .\ops.config.demoerp.json
REM ============================================================================
echo Creating the ops database + tables...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-ops.ps1" %*
if errorlevel 1 goto :fail
echo.
echo Seeding milestone configuration (37 definitions)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0seed-milestone-config.ps1" %*
if errorlevel 1 goto :fail
echo.
echo Done. Tables are ready.
echo   Next (FIRST INSTALL only): set OPS_ALLOW_SEED=1, then start the app with start-dotnet.bat
echo         so it seeds the default admin/admin123; log in, create your real users, then clear OPS_ALLOW_SEED.
echo         Fill live data over the VPN with seed-data.bat.
pause
goto :eof
:fail
echo.
echo setup-database FAILED - see the error above (is the SQL server reachable and the config correct?).
pause
exit /b 1
