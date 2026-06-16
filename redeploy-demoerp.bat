@echo off
REM redeploy-demoerp.bat - minimal-effort redeploy of the demoerp IIS site after a code change.
REM Drops app_offline.htm (ANCM stops the app + releases Ops.dll), re-publishes in place, removes it, recycles the pool.
REM Run from an elevated prompt if your account can't recycle the pool otherwise.
setlocal
set REPO=C:\Users\mandy\pgs-operation
set PUB=%REPO%\server\publish
set POOL=pgsops-demoerp
set APPCMD=%windir%\System32\inetsrv\appcmd.exe

echo offline > "%PUB%\app_offline.htm"
pushd "%REPO%\server"
dotnet publish -c Release -o publish --nologo
popd
del "%PUB%\app_offline.htm" 2>nul
"%APPCMD%" recycle apppool /apppool.name:"%POOL%"
echo.
echo Redeployed. Open http://localhost:8080/
endlocal
