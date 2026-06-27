<#
  verify-customer.ps1
  Read-only post-deploy check: prints WHICH ops DB the config resolves to and the row counts that matter, so a
  routine update can confirm it is still on the right database with the customer's users intact (the wrong-DB
  redeploy is the one that silently "loses" users). Touches nothing. Run after setup-ops + publish.
#>
param([string]$ConfigPath = (Join-Path $PSScriptRoot "ops.config.json"))
$ErrorActionPreference = "Stop"
$cfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json   # NOT Get-Content: PS5.1 reads BOM-less UTF-8 as ANSI
function EnvOrConfig($name, $cfgVal) { $v = [Environment]::GetEnvironmentVariable($name); if ($v -and $v.Trim() -ne "") { $v } else { $cfgVal } }
$server   = EnvOrConfig "DB_SERVER"   $cfg.server
$auth     = EnvOrConfig "DB_AUTH"     $cfg.auth
$user     = EnvOrConfig "DB_USER"     $cfg.user
$password = EnvOrConfig "DB_PASSWORD" $cfg.password
$opsDb       = EnvOrConfig "DB_OPS_DB"       $cfg.opsDb
$opsServer   = EnvOrConfig "DB_OPS_SERVER"   $cfg.opsServer;   if (-not ("$opsServer".Trim()))   { $opsServer = $server }
$opsAuth     = EnvOrConfig "DB_OPS_AUTH"     $cfg.opsAuth;     if (-not ("$opsAuth".Trim()))     { $opsAuth = $auth }
$opsUser     = EnvOrConfig "DB_OPS_USER"     $cfg.opsUser;     if (-not ("$opsUser".Trim()))     { $opsUser = $user }
$opsPassword = EnvOrConfig "DB_OPS_PASSWORD" $cfg.opsPassword; if (-not ("$opsPassword".Trim())) { $opsPassword = $password }
$opsAuthClause = if ($opsAuth -eq 'sql') { "User ID=$opsUser;Password=$opsPassword" } else { "Integrated Security=True" }
$cs = "Server=$opsServer;Database=$opsDb;$opsAuthClause;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512"

function Scalar($sql) {
  $cn = New-Object System.Data.SqlClient.SqlConnection $cs; $cn.Open()
  try { $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 30; return $c.ExecuteScalar() } finally { $cn.Close() }
}

Write-Host ""
Write-Host "=== Post-deploy verification ===" -ForegroundColor Cyan
Write-Host ("  config     : {0}" -f $ConfigPath)
# Deployed build version, read straight out of the published Ops.dll (no git / no running app needed) so the
# developer can confirm the RIGHT version was deployed. The version is baked in at build time on the build box.
$dll = Join-Path $PSScriptRoot "server\publish\Ops.dll"
if (Test-Path $dll) {
  $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dll).ProductVersion
  Write-Host ("  DEPLOYED BUILD : v{0}" -f $ver) -ForegroundColor Cyan
  Write-Host  "  >>> confirm this is the version you intended to deploy <<<" -ForegroundColor Cyan
} else {
  Write-Host ("  DEPLOYED BUILD : Ops.dll not found at {0} (publish first)" -f $dll) -ForegroundColor Yellow
}
Write-Host ("  ops DB     : Server={0}; Database={1}" -f $opsServer, $opsDb) -ForegroundColor Yellow
try {
  $users      = [int](Scalar "SELECT COUNT(*) FROM dbo.app_user")
  $admins     = [int](Scalar "SELECT COUNT(*) FROM dbo.app_user WHERE is_admin=1")
  $tables     = [int](Scalar "SELECT COUNT(*) FROM sys.tables")
  $milestones = [int](Scalar "SELECT COUNT(*) FROM dbo.milestone_def")
  $shipments  = [int](Scalar "SELECT COUNT(*) FROM dbo.shipment_alerts")
  Write-Host ("  app_user   : {0} users ({1} admin)" -f $users, $admins) -ForegroundColor $(if ($users -gt 0) { 'Green' } else { 'Red' })
  Write-Host ("  tables     : {0}" -f $tables)
  Write-Host ("  milestones : {0}" -f $milestones)
  Write-Host ("  shipments  : {0}" -f $shipments)
  if ($users -eq 0) {
    Write-Host "  WARNING: app_user is EMPTY - the app is pointed at the WRONG or a FRESH database." -ForegroundColor Red
    Write-Host "           Check OPS_CONFIG / OPS_ROOT (app-pool env vars) before starting the app." -ForegroundColor Red
    exit 2
  }
  Write-Host "  OK - users present; the app is on the expected database." -ForegroundColor Green
} catch {
  Write-Host ("  ERROR querying the ops DB: {0}" -f $_.Exception.Message) -ForegroundColor Red
  Write-Host "  Is the SQL server reachable and the config correct?" -ForegroundColor Red
  exit 1
}
