<#
  loadtest-booknow.ps1  -  concurrency / throughput test for the Book Now -> ERP flow.

  WHAT IT DOES (three phases):
    1. BURST   - fire N concurrent POST /api-ops/book-now (true parallelism via a runspace pool).
                 Measures registration latency (p50/p95/max) and success rate. This is the user-facing click.
    2. DRAIN   - polls dbo.book_pending until every queued booking reaches 'done' or 'failed'. The BookingPusher
                 background service performs the ERP /booking/update OFF the request path, so this is where you
                 see the REAL ERP write throughput. Reports drain time + failures.
    3. VERIFY  - confirms how many landed in the ERP, and CHECKS FOR DUPLICATE BOOKING NUMBERS + deadlocks (the
                 key concurrency-safety signal). Writes a result file under results\ for developers to review.

  *** THIS WRITES REAL BOOKINGS TO THE TARGET ERP *** (unless the server is in MOCK mode). Point it at demoerp,
  not a customer. There is no booking-delete API, so the test records persist in the ERP.

  PRE-REQS: the server running (BaseUrl); the Swivel VPN up; erpApi MOCK OFF for a real ERP test (the script
  warns if mock is on); a test user with a station in scope (its primary_station receives the bookings).

  USAGE (from repo root):
    .\tools\loadtest\loadtest-booknow.ps1 -BaseUrl http://localhost:8079 -Email you@co.com -Password *** -Count 100 -Note "OPS_BOOKING_WORKERS=5"
    .\tools\loadtest\loadtest-booknow.ps1 -BaseUrl http://localhost:8079 -Email you@co.com -Password *** -Count 5 -SkipDrain   # quick harness check

  Each run writes results\booknow-<timestamp>-count<N>.md (commit it so other developers can see the outcome).
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
  # repo root is two levels up (tools\loadtest\ -> tools\ -> root)
  [string]$ConfigPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "ops.config.demoerp.json"),
  [string]$OutDir    = (Join-Path $PSScriptRoot "results"),
  [string]$Note      = "",            # free-text note recorded in the result file (e.g. the OPS_BOOKING_WORKERS value)
  [int]$DrainTimeoutMin = 30,
  [switch]$SkipDrain                  # only run the burst (no ERP write wait / no DB poll)
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
$BaseUrl = $BaseUrl.TrimEnd('/')

# result-file accumulator: every Rep line is both shown and saved to the run's .md
$report = New-Object System.Collections.Generic.List[string]
function Rep($line, $color){ if($color){ Write-Host $line -ForegroundColor $color } else { Write-Host $line }; $report.Add($line) }
function SaveReport($stamp) {
  try {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $f = Join-Path $OutDir ("booknow-{0}-count{1}.md" -f $stamp, $Count)
    "# Book Now load test - $stamp" | Out-File -FilePath $f -Encoding utf8
    $report | Out-File -FilePath $f -Append -Encoding utf8
    Write-Host ("`n  result saved: {0}" -f $f) -ForegroundColor Cyan
  } catch { Write-Host ("  (could not write result file: {0})" -f $_.Exception.Message) -ForegroundColor Yellow }
}

# ---- 0. login -> ops_sid cookie ----
Write-Host "`n=== Book Now load test ===" -ForegroundColor Cyan
Rep ("- target: {0}   count: {1}   concurrency: {2}   mode: {3}" -f $BaseUrl, $Count, $Concurrency, $Mode)
if ($Note) { Rep ("- note: {0}" -f $Note) }
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
$stamp = $start.ToString('yyyyMMdd-HHmmss')
Rep ("- run started: {0}" -f $start.ToString('yyyy-MM-dd HH:mm:ss'))
$worker = {
  param($BaseUrl, $sid, $body, $i)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    # a manual "Cookie:" header is NOT honored by Invoke-RestMethod here - build a real cookie container instead
    $u = [Uri]$BaseUrl
    $ws = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $ws.Cookies.Add((New-Object System.Net.Cookie('ops_sid', $sid, '/', $u.Host)))
    $r = Invoke-RestMethod "$BaseUrl/api-ops/book-now" -Method Post -ContentType "application/json" `
           -WebSession $ws -Body $body -TimeoutSec 60
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
Write-Host "`n## Phase 1: registration burst" -ForegroundColor Cyan
$report.Add("`n## Phase 1: registration burst")
Rep ("- registered ok {0}/{1}   failed {2}   wall {3}s" -f $ok.Count, $Count, $fail.Count, $burstSec) $(if($fail.Count){'Yellow'}else{'Green'})
if ($lat.Count) { Rep ("- register latency ms: p50={0}  p95={1}  max={2}" -f (Pct $lat 0.5), (Pct $lat 0.95), $lat[-1]) }
if ($fail.Count) { Rep ("- sample errors: {0}" -f (($fail | Select-Object -First 3 | ForEach-Object { $_.err }) -join ' | ')) 'Yellow' }
$isMock = @($ok | Where-Object { $_.mock }).Count -gt 0
if ($isMock) { Rep "- NOTE: server is in MOCK mode - bookings went to erp-mock\, NOT the real ERP. Set erpApi mock OFF for a real test." 'Yellow' }
if ($SkipDrain) { Rep "- SkipDrain set: not waiting for the ERP push."; SaveReport $stamp; exit 0 }
if ($ok.Count -eq 0) { Rep "- No successful registrations - nothing to drain." 'Red'; SaveReport $stamp; exit 1 }

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
        $a=New-Object System.Data.SqlClient.SqlDataAdapter $c; $t=New-Object System.Data.DataTable; [void]$a.Fill($t); return ,$t }  # ,$t: stop PS unrolling the DataTable (else .Rows is null)
  finally { $cn.Close() }
}
Write-Host "`n## Phase 2: ERP push drain (BookingPusher)" -ForegroundColor Cyan
$report.Add("`n## Phase 2: ERP push drain (BookingPusher)")
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

# ---- 3. VERIFY (incl. the duplicate-booking-number + deadlock check) ----
$w = "created_at >= '$startSql'"
$cntDone     = (Rows "SELECT COUNT(*) c FROM dbo.book_pending WHERE $w AND status='done'").Rows[0].c
$cntFail     = (Rows "SELECT COUNT(*) c FROM dbo.book_pending WHERE $w AND status='failed'").Rows[0].c
$cntDistinct = (Rows "SELECT COUNT(DISTINCT booking_no) c FROM dbo.book_pending WHERE $w AND status='done' AND booking_no IS NOT NULL AND booking_no<>''").Rows[0].c
$deadlocks   = (Rows "SELECT COUNT(*) c FROM dbo.book_pending WHERE $w AND last_error LIKE '%deadlock%'").Rows[0].c
$dups        = Rows "SELECT booking_no, COUNT(*) c FROM dbo.book_pending WHERE $w AND status='done' AND booking_no IS NOT NULL AND booking_no<>'' GROUP BY booking_no HAVING COUNT(*)>1 ORDER BY c DESC"
$dupCount    = $dups.Rows.Count

Write-Host "`n## Phase 3: result" -ForegroundColor Cyan
$report.Add("`n## Phase 3: result")
Rep ("- ERP-confirmed: {0}   terminal-failed: {1}   drain time: {2}s ({3} min)" -f $cntDone, $cntFail, $drainSec, [math]::Round($drainSec/60,1)) $(if($cntFail -or -not $done){'Yellow'}else{'Green'})
if ($cntDone -gt 0) {
  $rate = [math]::Round($cntDone / [math]::Max($drainSec,1) * 60, 1)
  Rep ("- ERP write throughput: ~{0} bookings/min (~{1}s per booking)" -f $rate, [math]::Round($drainSec/[math]::Max($cntDone,1),1))
  Rep ("- distinct booking numbers: {0} of {1} confirmed" -f $cntDistinct, $cntDone) $(if($cntDistinct -lt $cntDone){'Red'}else{'Green'})
}
Rep ("- deadlock errors seen during drain: {0}" -f $deadlocks) $(if($deadlocks){'Yellow'}else{'Green'})
if ($dupCount -gt 0) {
  Rep ("- !! DUPLICATE BOOKING NUMBERS: {0} number(s) assigned to more than one booking (ERP not concurrency-safe)" -f $dupCount) 'Red'
  foreach ($r in $dups.Rows) { Rep ("    {0} x{1}" -f $r.booking_no, $r.c) 'Red' }
}
if ($cntFail -gt 0) {
  $fr = Rows "SELECT TOP 3 ref_no, LEFT(CAST(last_error AS NVARCHAR(MAX)),200) err FROM dbo.book_pending WHERE $w AND status='failed'"
  Rep "- sample terminal failures:" 'Yellow'
  foreach ($r in $fr.Rows) { Rep ("    {0}: {1}" -f $r.ref_no, $r.err) 'Yellow' }
}
if (-not $done) { Rep ("- TIMED OUT after {0} min - some rows still draining (raise -DrainTimeoutMin or check the BookingPusher)." -f $DrainTimeoutMin) 'Yellow' }

# verdict
$pass = ($cntFail -eq 0 -and $dupCount -eq 0 -and $done)
$report.Add("`n## Verdict")
if ($pass) { Rep "- PASS: all bookings confirmed with distinct numbers, no terminal failures." 'Green' }
else       { Rep "- CONCURRENCY ISSUE: duplicates/failures above. Lower OPS_BOOKING_WORKERS (1 = safe serial) and/or fix the ERP-side booking-number race." 'Red' }
SaveReport $stamp

Write-Host "`n  To see them in the WORKLIST (shipment_alerts), run a delta seed for the station (e.g. .\seed-hkg.bat)." -ForegroundColor DarkGray
