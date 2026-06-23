<#
  register-ops-tasks.ps1
  Registers Windows Task Scheduler jobs for the operational data refresh (SQL Express has no Agent):
    - publish-bookings.ps1 per configured station: Sea 3x/day, Air every 2h (start times STAGGERED per station
      so 50 publishers don't all write the central feed at once).
    - seed-alerts.ps1 per configured station (worklist refresh / listener stand-in): same Sea 3x/day, Air 2h
      cadence, trailing the publisher by 3 min; -AsOf is computed at run time so it always seeds as of "today".
    - seed-station-map.ps1 weekly (refresh station_dim + route map; surfaces newly-unmapped agent codes).
  MUST be run from an ELEVATED (Administrator) PowerShell -- it exits early otherwise (never silently no-ops).
  Usage: .\register-ops-tasks.ps1 [-ConfigPath .\ops.config.json] [-WorklistLimit 120]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [string[]]$SeaTimes=@("07:00","12:00","17:00"),   # Sea daily triggers (publish + worklist)
  [int]$AirEveryHours=2,                             # Air repetition interval (publish + worklist)
  [int]$WorklistLimit=120                            # seed-alerts -Limit per station/mode
)
$ErrorActionPreference="Stop"
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)){
  Write-Host "register-ops-tasks.ps1 must run from an ELEVATED (Administrator) PowerShell." -ForegroundColor Red
  Write-Host "Right-click PowerShell -> Run as administrator, then re-run this script." -ForegroundColor Yellow
  exit 1
}
$cfg=[IO.File]::ReadAllText($ConfigPath)|ConvertFrom-Json
$pub=Join-Path $PSScriptRoot "publish-bookings.ps1"
$seed=Join-Path $PSScriptRoot "seed-alerts.ps1"
$map=Join-Path $PSScriptRoot "seed-station-map.ps1"
$principal=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 20)

$script:okCount=0; $script:failCount=0
function Invoke-Register($name,$action,$triggers){
  try{
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Host "  registered: $name" -ForegroundColor Green; $script:okCount++
  } catch {
    Write-Host "  FAILED: $name -- $($_.Exception.Message)" -ForegroundColor Red; $script:failCount++
  }
}
function Register-OpsTask($name,$argLine,$triggers){
  $action=New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$argLine`""
  Invoke-Register $name $action $triggers
}
function Register-OpsCmdTask($name,$cmd,$triggers){
  $action=New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
  Invoke-Register $name $action $triggers
}
function Add-Minutes($hhmm,$mins){ ([datetime]::ParseExact($hhmm,'HH:mm',$null)).AddMinutes($mins).ToString('HH:mm') }

$stations=@($cfg.stations | Where-Object { $_ -and $_.code -and $_.database })
$i=0
foreach($s in $stations){
  $code="$($s.code)".Trim(); $db="$($s.database)".Trim(); $off=$i*7   # stagger publishers by 7 min per station
  # --- Sea publisher: daily at each SeaTime (+ per-station offset) ---
  $seaTrig=@(); foreach($t in $SeaTimes){ $seaTrig += New-ScheduledTaskTrigger -Daily -At (Add-Minutes $t $off) }
  Register-OpsTask "Ops Publish Sea $code" "$pub`" -ConfigPath `"$ConfigPath`" -Station `"$db`" -StationCode `"$code`" -Mode Sea" $seaTrig
  # --- Air publisher: every N hours, starting at 00:00 + offset ---
  $airTrig=New-ScheduledTaskTrigger -Once -At (Add-Minutes "00:00" $off) -RepetitionInterval (New-TimeSpan -Hours $AirEveryHours) -RepetitionDuration (New-TimeSpan -Days 3650)
  Register-OpsTask "Ops Publish Air $code" "$pub`" -ConfigPath `"$ConfigPath`" -Station `"$db`" -StationCode `"$code`" -Mode Air" $airTrig
  # --- Sea worklist refresh (seed-alerts): same daily times, +3 min so it trails the publisher; -AsOf = run-time today ---
  $seaWlTrig=@(); foreach($t in $SeaTimes){ $seaWlTrig += New-ScheduledTaskTrigger -Daily -At (Add-Minutes $t ($off+3)) }
  $seaWlCmd="& '$seed' -ConfigPath '$ConfigPath' -Station '$db' -StationCode '$code' -Mode Sea -AsOf (Get-Date -Format 'yyyy-MM-dd') -Limit $WorklistLimit"
  Register-OpsCmdTask "Ops Worklist Sea $code" $seaWlCmd $seaWlTrig
  # --- Air worklist refresh: every N hours, +3 min after the Air publisher ---
  $airWlTrig=New-ScheduledTaskTrigger -Once -At (Add-Minutes "00:00" ($off+3)) -RepetitionInterval (New-TimeSpan -Hours $AirEveryHours) -RepetitionDuration (New-TimeSpan -Days 3650)
  $airWlCmd="& '$seed' -ConfigPath '$ConfigPath' -Station '$db' -StationCode '$code' -Mode Air -AsOf (Get-Date -Format 'yyyy-MM-dd') -Limit $WorklistLimit"
  Register-OpsCmdTask "Ops Worklist Air $code" $airWlCmd $airWlTrig
  $i++
}
# --- weekly station-map refresh (Sunday 03:00) ---
$mapTrig=New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "03:00"
Register-OpsTask "Ops Station Map Refresh" "$map`" -ConfigPath `"$ConfigPath`"" $mapTrig

# --- weekly port-master refresh (Sunday 03:30, after the map; portmstr barely changes) ---
$portsScript=Join-Path $PSScriptRoot "seed-ports.ps1"
$portsTrig=New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "03:30"
Register-OpsTask "Ops Port Dim Refresh" "$portsScript`" -ConfigPath `"$ConfigPath`"" $portsTrig

# --- weekly liner-master refresh (Sunday 03:40, after ports; linermstr barely changes) ---
$linersScript=Join-Path $PSScriptRoot "seed-liners.ps1"
$linersTrig=New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "03:40"
Register-OpsTask "Ops Liner Dim Refresh" "$linersScript`" -ConfigPath `"$ConfigPath`"" $linersTrig

$color = if($script:failCount -gt 0){'Red'}else{'Cyan'}
Write-Host "Done. $($script:okCount) task(s) registered, $($script:failCount) failed, across $($stations.Count) station(s)." -ForegroundColor $color
Write-Host "Review in Task Scheduler: 'Ops Publish *' (feed) / 'Ops Worklist *' (worklist refresh) / 'Ops Station Map Refresh' / 'Ops Port Dim Refresh'." -ForegroundColor Cyan
if($script:failCount -gt 0){ exit 1 }
