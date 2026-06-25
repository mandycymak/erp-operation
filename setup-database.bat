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
REM  The DEFAULT ADMIN (admin / admin123) is created automatically the first time
REM  the .NET server starts against an empty app_user table (server/Auth.cs) - so
REM  after this + start-dotnet.bat you can log in and change the password.
REM
REM  Idempotent and safe to re-run. Run with a SQL login that can create the DB +
REM  tables (DDL). Connection + DB names come from the config (env DB_*/OPS_* win).
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
echo   Next: start the app with start-dotnet.bat (it seeds a default admin/admin123 on first run),
echo         then fill live data over the VPN with seed-data.bat.
pause
goto :eof
:fail
echo.
echo setup-database FAILED - see the error above (is the SQL server reachable and the config correct?).
pause
exit /b 1
