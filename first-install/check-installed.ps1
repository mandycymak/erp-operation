<#
  check-installed.ps1  -  read-only "is this ops DB already a live customer?" detector.

  Used by setup-database.bat to STOP an accidental first-install run against a database that already
  holds a customer's data. Touches nothing. Connection logic mirrors verify-customer.ps1 exactly
  (config + env overrides + two-server keys + Packet Size=512).

  Exit codes:
    0  FRESH      - ops DB absent, or tables not built, or app_user AND shipment_alerts both empty -> safe to install.
    2  INSTALLED  - app_user has users and/or shipment_alerts has rows -> this is a LIVE site; do NOT first-install.
    1  UNKNOWN    - could not reach the SQL server -> caller should decide (don't assume fresh).
#>
param([string]$ConfigPath)
$ErrorActionPreference = "Stop"
if (-not $ConfigPath -or "$ConfigPath".Trim() -eq "") {
  $ConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent) "ops.config.json"   # repo root (parent of first-install\)
}
if (-not (Test-Path $ConfigPath)) {
  Write-Host ("check-installed: config not found: {0}" -f $ConfigPath) -ForegroundColor Yellow
  exit 1
}
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
function CsFor($db) { "Server=$opsServer;Database=$db;$opsAuthClause;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512" }

function Scalar($db, $sql) {
  $cn = New-Object System.Data.SqlClient.SqlConnection (CsFor $db); $cn.Open()
  try { $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 30; return $c.ExecuteScalar() } finally { $cn.Close() }
}

Write-Host ("  checking ops DB : Server={0}; Database={1}" -f $opsServer, $opsDb) -ForegroundColor Yellow
try {
  # 1) Does the ops database even exist yet? (Ask master so a missing DB isn't a connection error.)
  $dbId = Scalar "master" "SELECT DB_ID(N'$($opsDb -replace "'","''")')"
  if ($null -eq $dbId -or $dbId -is [DBNull]) {
    Write-Host "  -> database does not exist yet (FRESH)." -ForegroundColor Green
    exit 0
  }
  # 2) DB exists - are the core tables built?
  $hasUserTbl = Scalar $opsDb "SELECT OBJECT_ID('dbo.app_user')"
  if ($null -eq $hasUserTbl -or $hasUserTbl -is [DBNull]) {
    Write-Host "  -> database exists but tables are not built yet (FRESH)." -ForegroundColor Green
    exit 0
  }
  # 3) Tables exist - is there real data?
  $users     = [int](Scalar $opsDb "SELECT COUNT(*) FROM dbo.app_user")
  $shipments = 0
  $hasShip = Scalar $opsDb "SELECT OBJECT_ID('dbo.shipment_alerts')"
  if ($null -ne $hasShip -and -not ($hasShip -is [DBNull])) { $shipments = [int](Scalar $opsDb "SELECT COUNT(*) FROM dbo.shipment_alerts") }
  if ($users -gt 0 -or $shipments -gt 0) {
    Write-Host ("  -> ALREADY INSTALLED: {0} user(s), {1} shipment(s)." -f $users, $shipments) -ForegroundColor Red
    exit 2
  }
  Write-Host "  -> tables present but empty (FRESH)." -ForegroundColor Green
  exit 0
} catch {
  Write-Host ("  -> could not query the SQL server: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  exit 1
}
