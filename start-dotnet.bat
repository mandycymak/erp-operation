@echo off
REM Launch the ASP.NET Core Control Tower (multi-threaded replacement for serve-ops.ps1).
REM Binds the port from ops.config.json (default 8078). Browse http://localhost:8078/
REM   Override port:   set OPS_HTTP_PORT=5079     (e.g. to run beside serve-ops.ps1 during migration)
REM   LAN access:      set OPS_HOST=+             (then browse http://<server-ip>:8078/)
REM   Pick a tenant config: set OPS_CONFIG=ops.config.network.json
REM Requires the .NET 10 SDK (or runtime, if using a published build). The Swivel VPN must be up for data.
cd /d "%~dp0server"
dotnet run -c Release
