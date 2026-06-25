<#
  register-ops-tasks.ps1
  Registers Windows Task Scheduler jobs for the operational data refresh (SQL Express has no Agent):
    - publish-bookings.ps1 per configured station: Sea 3x/day, Air every 2h (start times STAGGERED per station
      so 50 publishers don't all write the central feed at once).
    - seed-alerts.ps1 -DELTA per configured station (worklist refresh / listener stand-in): Air every
      $WorklistAirMins min (default 5), Sea every $WorklistSeaMins min (default 15). Delta = pulls only rows the
      ERP created/edited since the per-station watermark (dbo.alert_watermark), so a tight interval stays cheap.
      Run the FULL backfill once first (seed-data.bat / seed-alerts without -Delta) to populate history.
    - watch-bookings.ps1 -DELTA per station x mode every $BookingWatchMins min (default 5): detects newly-received
      EXPORT bookings and records/notifies a factory(shipper) alert (dbo.booking_alert).
    - seed-station-map.ps1 weekly (refresh station_dim + route map; surfaces newly-unmapped agent codes).
  MUST be run from an ELEVATED (Administrator) PowerShell -- it exits early otherwise (never silently no-ops).
  Usage: .\register-ops-tasks.ps1 [-ConfigPath .\ops.config.json] [-WorklistLimit 120]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [string[]]$SeaTimes=@("07:00","12:00","17:00"),   # Sea daily triggers for the cross-station PUBLISHER (feed)
  [int]$AirEveryHours=2,                             # Air repetition interval for the PUBLISHER (feed)
  [int]$WorklistAirMins=5,                           # worklist refresh (seed-alerts -Delta) interval - Air is time-critical
  [int]$WorklistSeaMins=15,                          # worklist refresh (seed-alerts -Delta) interval - Sea
  [int]$WorklistLimit=200,                           # seed-alerts -Limit safety cap per delta run (rarely hit)
  [int]$BookingWatchMins=5                           # watch-bookings.ps1 interval (new-booking -> factory alert)
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
$watch=Join-Path $PSScriptRoot "watch-bookings.ps1"
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
  # --- Sea worklist refresh (seed-alerts -DELTA): every $WorklistSeaMins min, staggered per station. Delta = pulls
  #     only shipments created/edited since the per-station watermark, so a tight interval stays cheap on the ERP. ---
  $seaWlTrig=New-ScheduledTaskTrigger -Once -At (Add-Minutes "00:00" $off) -RepetitionInterval (New-TimeSpan -Minutes $WorklistSeaMins) -RepetitionDuration (New-TimeSpan -Days 3650)
  $seaWlCmd="& '$seed' -ConfigPath '$ConfigPath' -Station '$db' -StationCode '$code' -Mode Sea -Delta -Limit $WorklistLimit"
  Register-OpsCmdTask "Ops Worklist Sea $code" $seaWlCmd $seaWlTrig
  # --- Air worklist refresh (seed-alerts -DELTA): every $WorklistAirMins min (air is fast - operators want <=15 min). ---
  $airWlTrig=New-ScheduledTaskTrigger -Once -At (Add-Minutes "00:00" $off) -RepetitionInterval (New-TimeSpan -Minutes $WorklistAirMins) -RepetitionDuration (New-TimeSpan -Days 3650)
  $airWlCmd="& '$seed' -ConfigPath '$ConfigPath' -Station '$db' -StationCode '$code' -Mode Air -Delta -Limit $WorklistLimit"
  Register-OpsCmdTask "Ops Worklist Air $code" $airWlCmd $airWlTrig
  # --- new-booking -> factory alert watcher: every $BookingWatchMins min per station x mode, staggered. ---
  $bwTrig=New-ScheduledTaskTrigger -Once -At (Add-Minutes "00:00" ($off+1)) -RepetitionInterval (New-TimeSpan -Minutes $BookingWatchMins) -RepetitionDuration (New-TimeSpan -Days 3650)
  Register-OpsTask "Ops Booking Watch Sea $code" "$watch`" -ConfigPath `"$ConfigPath`" -Station `"$db`" -StationCode `"$code`" -Mode Sea" $bwTrig
  Register-OpsTask "Ops Booking Watch Air $code" "$watch`" -ConfigPath `"$ConfigPath`" -Station `"$db`" -StationCode `"$code`" -Mode Air" $bwTrig
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

# --- operations / governance jobs (backup, watchdog, retention) ---
# A longer time limit for the backup + purge (a large DB backup can exceed the default 20 min).
$longSettings=New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 2)

# nightly backup (02:00): ops DB .bak + secrets copy + prune.
$backupScript=Join-Path $PSScriptRoot "backup-ops.ps1"
$backupAction=New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$backupScript`" -ConfigPath `"$ConfigPath`""
try { Register-ScheduledTask -TaskName "Ops Backup" -Action $backupAction -Trigger (New-ScheduledTaskTrigger -Daily -At "02:00") -Principal $principal -Settings $longSettings -Force -ErrorAction Stop | Out-Null; Write-Host "  registered: Ops Backup" -ForegroundColor Green; $script:okCount++ } catch { Write-Host "  FAILED: Ops Backup -- $($_.Exception.Message)" -ForegroundColor Red; $script:failCount++ }

# watchdog every 25 min: health checks -> health_check_log + alert on failure.
$healthScript=Join-Path $PSScriptRoot "ops-healthcheck.ps1"
$healthTrig=New-ScheduledTaskTrigger -Once -At (Get-Date "00:05") -RepetitionInterval (New-TimeSpan -Minutes 25) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-OpsTask "Ops Healthcheck" "$healthScript`" -ConfigPath `"$ConfigPath`"" $healthTrig

# weekly retention/purge (Sunday 04:00, after the dim refreshes): aging + log rotation.
$purgeScript=Join-Path $PSScriptRoot "purge-ops.ps1"
$purgeAction=New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$purgeScript`" -ConfigPath `"$ConfigPath`""
try { Register-ScheduledTask -TaskName "Ops Purge" -Action $purgeAction -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "04:00") -Principal $principal -Settings $longSettings -Force -ErrorAction Stop | Out-Null; Write-Host "  registered: Ops Purge" -ForegroundColor Green; $script:okCount++ } catch { Write-Host "  FAILED: Ops Purge -- $($_.Exception.Message)" -ForegroundColor Red; $script:failCount++ }

$color = if($script:failCount -gt 0){'Red'}else{'Cyan'}
Write-Host "Done. $($script:okCount) task(s) registered, $($script:failCount) failed, across $($stations.Count) station(s)." -ForegroundColor $color
Write-Host "Review in Task Scheduler: 'Ops Publish *' (feed) / 'Ops Worklist *' (delta refresh) / 'Ops Booking Watch *' (factory alerts) / 'Ops Station Map Refresh' / 'Ops Port Dim Refresh' / 'Ops Backup' / 'Ops Healthcheck' / 'Ops Purge'." -ForegroundColor Cyan
if($script:failCount -gt 0){ exit 1 }
