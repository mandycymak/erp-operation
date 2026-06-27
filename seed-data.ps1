<#
  seed-data.ps1 - one-shot LIVE-DATA fill for a fresh deploy (the data half of onboarding).
  Runs the read-from-ERP seeders in the right order, looping every configured station x Sea/Air:
    1. seed-station-map.ps1  (station_dim + cross-station route map)   - once
    2. seed-ports.ps1        (port_dim master)                        - once
    3. seed-liners.ps1       (liner_dim master)                       - once
    4. publish-bookings.ps1  (cross-station inbound feed) per station x mode
    5. seed-alerts.ps1       (the worklist; listener stand-in) per station x mode, -AsOf today
  These read the READ-ONLY source ERP over the Swivel VPN, so the VPN MUST be up. They write only the ops DB.
  Idempotent: re-running refreshes in place. Schema must already exist (run first-install\setup-database.bat first).
  Usage: .\seed-data.ps1 [-ConfigPath .\ops.config.json] [-Limit 120]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [int]$Limit=120
)
$ErrorActionPreference="Stop"
if(-not (Test-Path $ConfigPath)){ Write-Host "Config not found: $ConfigPath" -ForegroundColor Red; exit 1 }
$cfg=[IO.File]::ReadAllText($ConfigPath)|ConvertFrom-Json
$today=(Get-Date).ToString('yyyy-MM-dd')
$stations=@($cfg.stations | Where-Object { $_ -and $_.code -and $_.database })
if($stations.Count -eq 0){ Write-Host "No stations with code+database in $ConfigPath" -ForegroundColor Red; exit 1 }

$ok=0; $fail=0
function Run($label,$script,$prm){
  $path=Join-Path $PSScriptRoot $script
  if(-not (Test-Path $path)){ Write-Host "  SKIP $label ($script not found)" -ForegroundColor Yellow; return }
  Write-Host "  $label ..." -ForegroundColor Gray
  try{ & $path @prm; $script:ok++ }
  catch{ Write-Host "  FAILED: $label -- $($_.Exception.Message)" -ForegroundColor Red; $script:fail++ }
}

Write-Host "Filling live data for $($stations.Count) station(s) from $ConfigPath (VPN must be up)..." -ForegroundColor Cyan

# 1-3: the master/reference dims (once)
Run "station map"  "seed-station-map.ps1" @{ ConfigPath=$ConfigPath }
Run "port master"  "seed-ports.ps1"       @{ ConfigPath=$ConfigPath }
Run "liner master" "seed-liners.ps1"      @{ ConfigPath=$ConfigPath }

# 4-5: per station x mode - the inbound feed then the worklist
foreach($s in $stations){
  $code="$($s.code)".Trim(); $db="$($s.database)".Trim()
  foreach($mode in @('Sea','Air')){
    Run "publish $code $mode" "publish-bookings.ps1" @{ ConfigPath=$ConfigPath; Station=$db; StationCode=$code; Mode=$mode }
    Run "worklist $code $mode" "seed-alerts.ps1"      @{ ConfigPath=$ConfigPath; Station=$db; StationCode=$code; Mode=$mode; AsOf=$today; Limit=$Limit }
  }
}

$color = if($fail -gt 0){'Red'}else{'Green'}
Write-Host "Done. $ok step(s) ok, $fail failed, across $($stations.Count) station(s)." -ForegroundColor $color
Write-Host "Next: browse the app and confirm the worklist loads. Schedule ongoing refresh with register-ops-tasks.ps1 (elevated)." -ForegroundColor Cyan
if($fail -gt 0){ exit 1 }
