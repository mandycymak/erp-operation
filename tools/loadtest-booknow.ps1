<#
  loadtest-booknow.ps1  -  concurrency / throughput test for the Book Now -> ERP flow.

  WHAT IT DOES (three phases):
    1. BURST   - fire N concurrent POST /api-ops/book-now (true parallelism via a runspace pool).
                 Measures registration latency (p50/p95/max) and success rate. This is the user-facing click.
    2. DRAIN   - polls dbo.book_pending until every queued booking reaches 'done' or 'failed'. The BookingPusher
                 background service performs the ~10s ERP /booking/update OFF the request path, so this is where you
                 see the REAL ERP write throughput. Reports total drain time + failures.
    3. VERIFY  - counts how many were confirmed in the ERP (booking_no stamped) and prints sample numbers.

  *** THIS WRITES REAL BOOKINGS TO THE TARGET ERP *** (unless the server is in MOCK mode). Point it at demoerp,
  not a customer. There is no booking-delete API, so the test records persist in the ERP.

  PRE-REQS: the server running (BaseUrl); the Swivel VPN up; erpApi MOCK OFF for a real ERP test (the script
  warns if mock is on); a test user with a station in scope (its primary_station receives the bookings).

  USAGE (from repo root):
    .\tools\loadtest-booknow.ps1 -BaseUrl http://localhost:8079 -Email you@co.com -Password *** -Count 100
    .\tools\loadtest-booknow.ps1 -BaseUrl http://localhost:8079 -Email you@co.com -Password *** -Count 5 -SkipDrain   # quick harness check
#>
param(
  [string]$BaseUrl   = "http://localhost:8079",
  [Parameter(Mandatory=$true)][string]$Email,
  [Parameter(Mandatory=$true)][string]$Password,
  [int]$Count        = 100,
  [int]$Concurrency  = 50,            # max in-flight registration requests
  [string]$Mode      = "Sea",         # Sea | Air
  [string]$PolName   = "HONG KONG",
  [string]$PodName   = "SINGAPORE",
  [string]$Commodity = "LOADTEST",
  [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "ops.config.demoerp.json"),  # for the drain poll
  [int]$DrainTimeoutMin = 30,
  [switch]$SkipDrain                  # only run the burst (no ERP write wait / no DB poll)
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
$BaseUrl = $BaseUrl.TrimEnd('/')

# ---- 0. login -> ops_sid cookie ----
Write-Host "`n=== Book Now load test ===" -ForegroundColor Cyan
Write-Host ("  target : {0}   count : {1}   concurrency : {2}   mode : {3}" -f $BaseUrl, $Count, $Concurrency, $Mode)
$login = Invoke-WebRequest "$BaseUrl/api-ops/login" -Method Post -ContentType "application/json" `
          -Body (@{ email = $Email; password = $Password } | ConvertTo-Json) -UseBasicParsing -SessionVariable sess
$sid = ($sess.Cookies.GetCookies($BaseUrl) | Where-Object Name -eq 'ops_sid').Value
if (-not $sid) { Write-Host "  LOGIN FAILED - no ops_sid cookie. Check the email/password." -ForegroundColor Red; exit 1 }
Write-Host "  login ok (ops_sid acquired)." -ForegroundColor Green

# minimal valid Book Now payload (POL/POD as NAMES are accepted; commodity + POL + POD are the required set)
$bodyTemplate = @{ mode=$Mode; bound="Export"; polName=$PolName; podName=$PodName; commodity=$Commodity;
                   quantity="1"; quantityUnit="CTN"; grossWeight="100"; cbm="1" } | ConvertTo-Json -Compress

# ---- 1. BURST: N concurrent registrations via a runspace pool ----
$start = Get-Date
$worker = {
  param($BaseUrl, $sid, $body, $i)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-RestMethod "$BaseUrl/api-ops/book-now" -Method Post -ContentType "application/json" `
           -Headers @{ Cookie = "ops_sid=$sid" } -Body $body -TimeoutSec 60
    $sw.Stop()
    [pscustomobject]@{ i=$i; ms=$sw.ElapsedMilliseconds; ok=[bool]$r.ok; refNo=$r.refNo; mock=[bool]$r.mock; err=$r.error }
  } catch {
    $sw.Stop()
    [pscustomobject]@{ i=$i; ms=$sw.ElapsedMilliseconds; ok=$false; refNo=$null; mock=$null; err=$_.Exception.Message }
  }
}
$pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1,$Concurrency)); $pool.Open()
$jobs = @()
foreach ($i in 1..$Count) {
  $ps = [powershell]::Create().AddScript($worker).AddArgument($BaseUrl).AddArgument($sid).AddArgument($bodyTemplate).AddArgument($i)
  $ps.RunspacePool = $pool
  $jobs += [pscustomobject]@{ ps=$ps; handle=$ps.BeginInvoke() }
}
Write-Host ("  firing {0} concurrent registrations..." -f $Count)
$res = foreach ($j in $jobs) { $j.ps.EndInvoke($j.handle); $j.ps.Dispose() }
$pool.Close(); $pool.Dispose()
$burstSec = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)

$ok = @($res | Where-Object ok)
$fail = @($res | Where-Object { -not $_.ok })
$lat = @($res | Where-Object ok | Select-Object -ExpandProperty ms | Sort-Object)
function Pct($a,$p){ if(-not $a){return 0}; $a[[int][math]::Floor(($a.Count-1)*$p)] }
Write-Host "`n--- Phase 1: registration burst ---" -ForegroundColor Cyan
Write-Host ("  ok {0}/{1}   failed {2}   wall {3}s" -f $ok.Count, $Count, $fail.Count, $burstSec) -ForegroundColor $(if($fail.Count){'Yellow'}else{'Green'})
if ($lat.Count) { Write-Host ("  register latency ms: p50={0}  p95={1}  max={2}" -f (Pct $lat 0.5), (Pct $lat 0.95), $lat[-1]) }
if ($fail.Count) { Write-Host ("  sample errors: {0}" -f (($fail | Select-Object -First 3 | ForEach-Object { $_.err }) -join ' | ')) -ForegroundColor Yellow }
$isMock = @($ok | Where-Object { $_.mock }).Count -gt 0
if ($isMock) { Write-Host "  NOTE: server is in MOCK mode - bookings are written to erp-mock\, NOT the real ERP. Set erpApi mock OFF to test the real write." -ForegroundColor Yellow }
if ($SkipDrain) { Write-Host "`n-SkipDrain set: not waiting for the ERP push. Done." ; exit 0 }
if ($ok.Count -eq 0) { Write-Host "  No successful registrations - nothing to drain. Stopping." -ForegroundColor Red; exit 1 }

# ---- 2. DRAIN: poll dbo.book_pending until this run's rows finish ----
# connection resolution mirrors verify-customer.ps1 (config + env overrides + two-server + Packet Size=512)
$cfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
function EnvOrCfg($n,$v){ $e=[Environment]::GetEnvironmentVariable($n); if($e -and $e.Trim()){$e}else{$v} }
$opsServer = EnvOrCfg "DB_OPS_SERVER" $cfg.opsServer; if(-not "$opsServer".Trim()){ $opsServer = EnvOrCfg "DB_SERVER" $cfg.server }
$opsDb     = EnvOrCfg "DB_OPS_DB"     $cfg.opsDb
$opsAuth   = EnvOrCfg "DB_OPS_AUTH"   $cfg.opsAuth; if(-not "$opsAuth".Trim()){ $opsAuth = EnvOrCfg "DB_AUTH" $cfg.auth }
$opsUser   = EnvOrCfg "DB_OPS_USER"   $cfg.opsUser; if(-not "$opsUser".Trim()){ $opsUser = EnvOrCfg "DB_USER" $cfg.user }
$opsPass   = EnvOrCfg "DB_OPS_PASSWORD" $cfg.opsPassword; if(-not "$opsPass".Trim()){ $opsPass = EnvOrCfg "DB_PASSWORD" $cfg.password }
$authClause = if ($opsAuth -eq 'sql') { "User ID=$opsUser;Password=$opsPass" } else { "Integrated Security=True" }
$cs = "Server=$opsServer;Database=$opsDb;$authClause;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512"
$startSql = $start.ToString("yyyy-MM-dd HH:mm:ss")

function Rows($sql) {
  $cn = New-Object System.Data.SqlClient.SqlConnection $cs; $cn.Open()
  try { $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=30
        $a=New-Object System.Data.SqlClient.SqlDataAdapter $c; $t=New-Object System.Data.DataTable; [void]$a.Fill($t); return $t }
  finally { $cn.Close() }
}
Write-Host "`n--- Phase 2: ERP push drain (BookingPusher) ---" -ForegroundColor Cyan
Write-Host ("  ops DB: Server={0}; Database={1}; watching book_pending created since {2}" -f $opsServer, $opsDb, $startSql)
$drainStart = Get-Date
$done = $false
while (((Get-Date)-$drainStart).TotalMinutes -lt $DrainTimeoutMin) {
  $t = Rows "SELECT status, COUNT(*) c FROM dbo.book_pending WHERE created_at >= '$startSql' GROUP BY status"
  $by = @{}; foreach ($r in $t.Rows) { $by[[string]$r.status] = [int]$r.c }
  $pending=($by['pending']+0); $proc=($by['processing']+0); $retry=($by['retry']+0); $doneC=($by['done']+0); $failed=($by['failed']+0)
  $left = $pending + $proc + $retry
  $el = [math]::Round(((Get-Date)-$drainStart).TotalSeconds)
  Write-Host ("  [{0,4}s] done {1}  failed {2}  | pending {3}  processing {4}  retry {5}" -f $el,$doneC,$failed,$pending,$proc,$retry)
  if ($left -eq 0 -and ($doneC + $failed) -ge $ok.Count) { $done = $true; break }
  Start-Sleep -Seconds 10
}
$drainSec = [math]::Round(((Get-Date)-$drainStart).TotalSeconds,1)

# ---- 3. VERIFY ----
$confirmed = Rows "SELECT TOP 5 ref_no, booking_no FROM dbo.book_pending WHERE created_at >= '$startSql' AND status='done' ORDER BY updated_at"
$cntDone = (Rows "SELECT COUNT(*) c FROM dbo.book_pending WHERE created_at >= '$startSql' AND status='done'").Rows[0].c
$cntFail = (Rows "SELECT COUNT(*) c FROM dbo.book_pending WHERE created_at >= '$startSql' AND status='failed'").Rows[0].c
Write-Host "`n--- Phase 3: result ---" -ForegroundColor Cyan
Write-Host ("  ERP-confirmed: {0}   failed: {1}   drain time: {2}s ({3} min)" -f $cntDone, $cntFail, $drainSec, [math]::Round($drainSec/60,1)) -ForegroundColor $(if($cntFail -or -not $done){'Yellow'}else{'Green'})
if ($cntDone -gt 0) {
  $rate = [math]::Round($cntDone / [math]::Max($drainSec,1) * 60, 1)
  Write-Host ("  ERP write throughput: ~{0} bookings/min (≈{1}s per booking)" -f $rate, [math]::Round($drainSec/[math]::Max($cntDone,1),1))
  Write-Host  "  sample confirmed (ref -> ERP booking no):"
  foreach ($r in $confirmed.Rows) { Write-Host ("    {0} -> {1}" -f $r.ref_no, $r.booking_no) }
}
if ($cntFail -gt 0) {
  $fr = Rows "SELECT TOP 3 ref_no, last_error FROM dbo.book_pending WHERE created_at >= '$startSql' AND status='failed'"
  Write-Host "  sample failures:" -ForegroundColor Yellow
  foreach ($r in $fr.Rows) { Write-Host ("    {0}: {1}" -f $r.ref_no, $r.last_error) -ForegroundColor Yellow }
}
if (-not $done) { Write-Host ("  TIMED OUT after {0} min - some rows still draining (raise -DrainTimeoutMin or check the BookingPusher)." -f $DrainTimeoutMin) -ForegroundColor Yellow }
Write-Host "`n  To see them in the WORKLIST (shipment_alerts), run a delta seed for the station, e.g.:" -ForegroundColor DarkGray
Write-Host "    .\seed-hkg.bat   (or  .\seed-alerts.ps1 -ConfigPath $ConfigPath -Station <db> -StationCode <CODE> -Mode $Mode -Delta)" -ForegroundColor DarkGray
