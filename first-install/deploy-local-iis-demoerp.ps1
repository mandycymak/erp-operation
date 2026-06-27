# deploy-local-iis-demoerp.ps1
# ONE-TIME local IIS setup that mirrors a production deploy: hosts server\publish\ under IIS,
# pointed at ops.config.demoerp.json (opsDb 'demoerp' on local SQLEXPRESS + fm3k* ERP over the VPN).
# After this, redeploying = re-publish + copy + recycle the pool (see redeploy-demoerp.bat).
#
# RUN IN AN ELEVATED (Administrator) PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\deploy-local-iis-demoerp.ps1
#
# Idempotent: safe to re-run. It does NOT touch the source ERP or the network instance on 8079.

param(
  [string]$Root    = "C:\Users\mandy\erp-operation",            # OPS_ROOT: holds ops.config.demoerp.json + client files + lang\
  [string]$Publish = "C:\Users\mandy\erp-operation\server\publish",
  [string]$Pool    = "erpops-demoerp",
  [string]$Site    = "erpops-demoerp",
  [int]   $Port    = 8080,                                       # http://localhost:8080  (8079 is the dev network instance)
  [string]$Config  = "ops.config.demoerp.json",
  [string]$OpsDb   = "demoerp",
  [string]$SqlInstance = "localhost\SQLEXPRESS"
)
$ErrorActionPreference = 'Stop'
function Step($m){ Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# 0. must be admin
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)){
  Write-Error "Run this in an ELEVATED PowerShell (Administrator)."; exit 1
}

# 0b. FIRST-INSTALL guard. This RECREATES the IIS app pool + site and RESETS the pool environment
#     variables (OPS_ROOT / OPS_CONFIG). On an EXISTING customer site that can re-point the app at the
#     wrong/empty database and make the customer's users look "lost". For a routine update use
#     ..\update-customer.bat instead - it never touches the pool/env. Require an explicit confirmation.
Write-Host ""
Write-Host "  This is the FIRST-INSTALL IIS bootstrap (creates/recreates the pool, site and env vars)." -ForegroundColor Yellow
Write-Host "  For a routine update of a live site, cancel and run ..\update-customer.bat instead." -ForegroundColor Yellow
$ans = Read-Host "  Type INSTALL to set up IIS for this site, or press Enter to cancel"
if ($ans -ne 'INSTALL') { Write-Host "  Cancelled - nothing changed." -ForegroundColor Cyan; exit 0 }

# 1. enable IIS (client-OS optional features). No Managed Code -> no ASP.NET feature needed.
Step "Enabling IIS Windows features"
$feats = 'IIS-WebServerRole','IIS-WebServer','IIS-CommonHttpFeatures','IIS-StaticContent','IIS-DefaultDocument',
         'IIS-HttpErrors','IIS-RequestFiltering','IIS-NetFxExtensibility45','IIS-ISAPIExtensions','IIS-ISAPIFilter',
         'IIS-ManagementConsole'
foreach($f in $feats){
  $s = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
  if($s -and $s.State -ne 'Enabled'){ Write-Host "  enabling $f"; Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart | Out-Null }
  else { Write-Host "  $f already enabled" }
}

# 2. ASP.NET Core Hosting Bundle (provides ANCM = AspNetCoreModuleV2). Required for IIS to host the app.
Step "Checking ASP.NET Core Hosting Bundle (ANCM)"
$ancm = Test-Path "$env:windir\System32\inetsrv\aspnetcorev2.dll"
if(-not $ancm){
  Write-Host "  ANCM missing. Trying winget..." -ForegroundColor Yellow
  $wg = Get-Command winget -ErrorAction SilentlyContinue
  if($wg){ winget install --id Microsoft.DotNet.HostingBundle.10 -e --accept-source-agreements --accept-package-agreements }
  if(-not (Test-Path "$env:windir\System32\inetsrv\aspnetcorev2.dll")){
    Write-Error "Hosting Bundle still not installed. Download 'ASP.NET Core 10 Hosting Bundle' from https://dotnet.microsoft.com/download/dotnet/10.0 , install it, then re-run this script."
    exit 1
  }
}
iisreset /restart | Out-Null
Write-Host "  ANCM present."

$appcmd = "$env:windir\System32\inetsrv\appcmd.exe"

# 3. SQL: let the IIS app-pool identity reach the demoerp ops DB (opsAuth=integrated).
#    The pool runs as "IIS APPPOOL\<pool>" - give it a login + db_owner on demoerp.
Step "Granting IIS app-pool identity access to [$OpsDb] on $SqlInstance"
$poolLogin = "IIS APPPOOL\$Pool"
$sql = @"
IF SUSER_ID(N'$poolLogin') IS NULL CREATE LOGIN [$poolLogin] FROM WINDOWS;
IF DB_ID(N'$OpsDb') IS NOT NULL
BEGIN
  USE [$OpsDb];
  IF USER_ID(N'$poolLogin') IS NULL CREATE USER [$poolLogin] FOR LOGIN [$poolLogin];
  ALTER ROLE db_owner ADD MEMBER [$poolLogin];
END
"@
$cs = "Server=$SqlInstance;Integrated Security=SSPI;Encrypt=False;Connect Timeout=15;Packet Size=512"
$cn = New-Object System.Data.SqlClient.SqlConnection $cs; $cn.Open()
$cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.ExecuteNonQuery() | Out-Null; $cn.Close()
Write-Host "  granted db_owner on [$OpsDb] to $poolLogin"

# 4. NTFS: the pool identity needs read on the repo + write to ops-lists\ and *-audit.log under OPS_ROOT.
Step "Granting NTFS rights on OPS_ROOT to $poolLogin"
icacls "$Root" /grant "${poolLogin}:(OI)(CI)(RX)" /T /C | Out-Null
foreach($w in @("$Root\ops-lists")){ if(-not (Test-Path $w)){ New-Item -ItemType Directory -Path $w | Out-Null }; icacls "$w" /grant "${poolLogin}:(OI)(CI)(M)" /C | Out-Null }
icacls "$Root" /grant "${poolLogin}:(M)" /C | Out-Null   # write audit logs created at the root

# 5. App pool: No Managed Code, AlwaysRunning, + the env vars ANCM passes to the app (survive re-publish).
Step "Creating app pool [$Pool]"
& $appcmd list apppool /name:"$Pool" | Out-Null
if($LASTEXITCODE -ne 0){ & $appcmd add apppool /name:"$Pool" | Out-Null }
& $appcmd set apppool /apppool.name:"$Pool" /managedRuntimeVersion:"" /startMode:"AlwaysRunning" | Out-Null
# environment variables on the pool (persist across publishes; web.config gets regenerated by dotnet publish)
function SetPoolEnv($name,$value){
  & $appcmd set config -section:system.applicationHost/applicationPools /-"[name='$Pool'].environmentVariables.[name='$name']" /commit:apphost 2>$null | Out-Null
  & $appcmd set config -section:system.applicationHost/applicationPools /+"[name='$Pool'].environmentVariables.[name='$name',value='$value']" /commit:apphost | Out-Null
}
SetPoolEnv 'OPS_ROOT'   $Root
SetPoolEnv 'OPS_CONFIG' $Config
SetPoolEnv 'OPS_DB_GATE' '16'
# (local HTTP simulation: no OPS_HTTPS. Add OPS_HTTPS=1 + a 443 binding + cert for real HTTPS.)
Write-Host "  pool configured (OPS_ROOT, OPS_CONFIG=$Config)"

# 6. Site: physical path = publish folder, http binding on $Port.
Step "Creating site [$Site] -> $Publish  (http://localhost:$Port)"
& $appcmd list site /name:"$Site" | Out-Null
if($LASTEXITCODE -ne 0){ & $appcmd add site /name:"$Site" /physicalPath:"$Publish" /bindings:"http/*:${Port}:" | Out-Null }
else { & $appcmd set site /site.name:"$Site" /[path='/'].[path='/'].physicalPath:"$Publish" 2>$null | Out-Null }
& $appcmd set app /app.name:"$Site/" /applicationPool:"$Pool" | Out-Null
& $appcmd start apppool /apppool.name:"$Pool" 2>$null | Out-Null
& $appcmd start site /site.name:"$Site" 2>$null | Out-Null

Step "Done"
Write-Host "Open:  http://localhost:$Port/" -ForegroundColor Green
Write-Host "If you see HTTP 500.3x/500.19, the Hosting Bundle was installed before IIS - run: dotnet-hosting...exe /repair  (or re-run this script)."
Write-Host "Secrets check: http://localhost:$Port/ops.config.json should return 404."
