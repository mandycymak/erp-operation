<#
  register-ops-tasks.ps1
  Registers Windows Task Scheduler jobs for the cross-station inbound booking feed (SQL Express has no Agent):
    - publish-bookings.ps1 per configured station: Sea 3x/day, Air every 2h (start times STAGGERED per station
      so 50 publishers don't all write the central feed at once).
    - seed-station-map.ps1 weekly (refresh station_dim + route map; surfaces newly-unmapped agent codes).
  Run once per host. May require an elevated (Administrator) PowerShell.
  Note: the operational worklist seeder (seed-alerts.ps1 / future listener) is scheduled separately.
  Usage: .\register-ops-tasks.ps1 [-ConfigPath .\ops.config.json]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [string[]]$SeaTimes=@("07:00","12:00","17:00"),   # Sea publish daily triggers
  [int]$AirEveryHours=2                              # Air publish repetition interval
)
$ErrorActionPreference="Stop"
$cfg=Get-Content $ConfigPath -Raw|ConvertFrom-Json
$pub=Join-Path $PSScriptRoot "publish-bookings.ps1"
$map=Join-Path $PSScriptRoot "seed-station-map.ps1"
$principal=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 20)

function Register-OpsTask($name,$argLine,$triggers){
  $action=New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$argLine`""
  try{
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "  registered: $name" -ForegroundColor Green
  } catch {
    Write-Host "  FAILED: $name -- $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  (re-run from an elevated PowerShell, or create the task manually.)" -ForegroundColor Yellow
  }
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
  $i++
}
# --- weekly station-map refresh (Sunday 03:00) ---
$mapTrig=New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "03:00"
Register-OpsTask "Ops Station Map Refresh" "$map`" -ConfigPath `"$ConfigPath`"" $mapTrig

Write-Host "Done. Registered feed tasks for $($stations.Count) station(s). Review in Task Scheduler under the names 'Ops Publish *' / 'Ops Station Map Refresh'." -ForegroundColor Cyan
