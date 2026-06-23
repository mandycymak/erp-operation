<#
  purge-ops.ps1 - data retention / aging + log rotation (the ops DB stays small over years).
  Implements the aging the schema was DESIGNED for but never had a job for: shipment_alerts.job_status and
  inbound_booking_feed are aged out by their `updated_at` staleness, append-only logs are trimmed to a horizon,
  and the on-disk log files are rotated. All horizons come from the config `retention` block (param overrides win).
  Live document attachments are NEVER auto-deleted (legal retention) - only soft-deleted ones are reclaimed.

  Writes a 'purge' row to health_check_log (so the IT-Admin Health board shows it ran) and EXITS NON-ZERO on
  failure. Safe to re-run; idempotent (it deletes by age each time).
  Usage: .\purge-ops.ps1 [-ConfigPath .\ops.config.json] [-WhatIf]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [int]$StaleDays=0, [int]$RetainClosedDays=0, [int]$RetainFeedDays=0,
  [int]$AuditRetainMonths=0, [int]$HealthRetainDays=0, [int]$AttachPurgeDays=0,
  [int]$LogRotateMb=0, [int]$LogKeep=0,
  [switch]$WhatIf
)
$ErrorActionPreference="Stop"
$cfg=[IO.File]::ReadAllText($ConfigPath)|ConvertFrom-Json
$r=$cfg.retention
# NOTE: do NOT name this 'R' - PS has a built-in alias 'r' (Invoke-History) that outranks a function.
function Ret($paramVal,$cfgVal,$default){ if($paramVal -gt 0){$paramVal}elseif($cfgVal){[int]$cfgVal}else{$default} }
$StaleDays        = Ret $StaleDays        $r.staleDays        21
$RetainClosedDays = Ret $RetainClosedDays $r.retainClosedDays 180   # >= the Find "recently-closed" window (~6 mo)
$RetainFeedDays   = Ret $RetainFeedDays   $r.retainFeedDays   120
$AuditRetainMonths= Ret $AuditRetainMonths $r.auditRetainMonths 24
$HealthRetainDays = Ret $HealthRetainDays $r.healthRetainDays 90
$AttachPurgeDays  = Ret $AttachPurgeDays  $r.attachPurgeDays  60
$LogRotateMb      = Ret $LogRotateMb      $r.logRotateMb      16
$LogKeep          = Ret $LogKeep          $r.logKeep          6

function EnvOrConfig($n,$v){ $e=[Environment]::GetEnvironmentVariable($n); if($e -and $e.Trim()){$e}else{$v} }
$server=EnvOrConfig "DB_SERVER" $cfg.server; $auth=EnvOrConfig "DB_AUTH" $cfg.auth
$user=EnvOrConfig "DB_USER" $cfg.user; $pwd=EnvOrConfig "DB_PASSWORD" $cfg.password
$opsDb=EnvOrConfig "DB_OPS_DB" $cfg.opsDb
$opsServer=EnvOrConfig "DB_OPS_SERVER" $cfg.opsServer; if(-not ("$opsServer".Trim())){ $opsServer=$server }
$opsAuth=EnvOrConfig "DB_OPS_AUTH" $cfg.opsAuth; if(-not ("$opsAuth".Trim())){ $opsAuth=$auth }
$opsUser=EnvOrConfig "DB_OPS_USER" $cfg.opsUser; if(-not ("$opsUser".Trim())){ $opsUser=$user }
$opsPwd=EnvOrConfig "DB_OPS_PASSWORD" $cfg.opsPassword; if(-not ("$opsPwd".Trim())){ $opsPwd=$pwd }
$opsAc= if($opsAuth -eq 'sql'){"User ID=$opsUser;Password=$opsPwd"}else{"Integrated Security=True"}
$cs="Server=$opsServer;Database=$opsDb;$opsAc;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512"
$cn=New-Object System.Data.SqlClient.SqlConnection $cs; $cn.Open()
function Exec($sql,[hashtable]$p){
  $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=120
  if($p){ foreach($k in $p.Keys){ [void]$c.Parameters.AddWithValue("@$k",$p[$k]) } }
  return $c.ExecuteNonQuery()
}
# A SELECT COUNT for the -WhatIf preview (same predicate as the DELETE/UPDATE).
function Count($sql,[hashtable]$p){
  $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=120
  if($p){ foreach($k in $p.Keys){ [void]$c.Parameters.AddWithValue("@$k",$p[$k]) } }
  return [int]$c.ExecuteScalar()
}

$summary=@()
function Step($label,$selSql,$mutSql,[hashtable]$p){
  if($WhatIf){
    $n=Count $selSql $p
    Write-Host ("  [WhatIf] {0}: {1} row(s) would change" -f $label,$n) -ForegroundColor Yellow
    $script:summary += "$label=$n(whatif)"
  } else {
    $n=Exec $mutSql $p
    Write-Host ("  {0}: {1} row(s)" -f $label,$n) -ForegroundColor Cyan
    $script:summary += "$label=$n"
  }
}

try {
  Write-Host "Retention (days/months): stale=$StaleDays retainClosed=$RetainClosedDays feed=$RetainFeedDays audit=${AuditRetainMonths}mo health=$HealthRetainDays attach=$AttachPurgeDays" -ForegroundColor Gray

  # 1. shipment_alerts: age out shipments that fell out of the active ERP set (no refresh in StaleDays), then
  #    delete closed/void rows past the retention window.
  Step "alerts.age-out" `
    "SELECT COUNT(*) FROM dbo.shipment_alerts WHERE job_status='active' AND updated_at < DATEADD(day,-@d,SYSDATETIME())" `
    "UPDATE dbo.shipment_alerts SET job_status='closed' WHERE job_status='active' AND updated_at < DATEADD(day,-@d,SYSDATETIME())" `
    @{ d=$StaleDays }
  Step "alerts.purge-closed" `
    "SELECT COUNT(*) FROM dbo.shipment_alerts WHERE job_status IN ('closed','void') AND updated_at < DATEADD(day,-@d,SYSDATETIME())" `
    "DELETE FROM dbo.shipment_alerts WHERE job_status IN ('closed','void') AND updated_at < DATEADD(day,-@d,SYSDATETIME())" `
    @{ d=$RetainClosedDays }

  # 2. inbound_booking_feed: anything not refreshed in RetainFeedDays is stale (consumed / past / origin gone).
  Step "feed.purge" `
    "SELECT COUNT(*) FROM dbo.inbound_booking_feed WHERE updated_at < DATEADD(day,-@d,SYSDATETIME())" `
    "DELETE FROM dbo.inbound_booking_feed WHERE updated_at < DATEADD(day,-@d,SYSDATETIME())" `
    @{ d=$RetainFeedDays }

  # 3. append-only audit/event logs: keep AuditRetainMonths of history.
  foreach($t in @('milestone_event_log','doc_event_log','erp_edit_log')){
    Step "$t.purge" `
      "SELECT COUNT(*) FROM dbo.$t WHERE occurred_at < DATEADD(month,-@m,SYSDATETIME())" `
      "DELETE FROM dbo.$t WHERE occurred_at < DATEADD(month,-@m,SYSDATETIME())" `
      @{ m=$AuditRetainMonths }
  }

  # 4. health_check_log: high-frequency; keep HealthRetainDays.
  Step "health_check_log.purge" `
    "SELECT COUNT(*) FROM dbo.health_check_log WHERE occurred_at < DATEADD(day,-@d,SYSDATETIME())" `
    "DELETE FROM dbo.health_check_log WHERE occurred_at < DATEADD(day,-@d,SYSDATETIME())" `
    @{ d=$HealthRetainDays }

  # 5. doc_attachment: reclaim ONLY soft-deleted blobs past AttachPurgeDays. Live attachments are never touched.
  Step "doc_attachment.reclaim-deleted" `
    "SELECT COUNT(*) FROM dbo.doc_attachment WHERE deleted=1 AND uploaded_at < DATEADD(day,-@d,SYSDATETIME())" `
    "DELETE FROM dbo.doc_attachment WHERE deleted=1 AND uploaded_at < DATEADD(day,-@d,SYSDATETIME())" `
    @{ d=$AttachPurgeDays }

  # 6. log-file rotation: roll any log over LogRotateMb, keep the newest LogKeep archives.
  $rolled=0
  foreach($name in @('admin-audit.log','ops-error.log','ops-health.log','ops-backup.log')){
    $path=Join-Path $PSScriptRoot $name
    if(Test-Path $path){
      $sizeMb=(Get-Item $path).Length/1MB
      if($sizeMb -ge $LogRotateMb){
        if(-not $WhatIf){
          $arch="$path.$((Get-Date).ToString('yyyyMMddHHmmss'))"
          Move-Item $path $arch -Force
          $olds=@(Get-ChildItem -Path $PSScriptRoot -Filter "$name.*" -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip $LogKeep)
          foreach($o in $olds){ Remove-Item $o.FullName -Force }
        }
        $rolled++
      }
    }
  }
  Write-Host "  logs.rotated: $rolled file(s)" -ForegroundColor Cyan
  $summary += "logs.rotated=$rolled"

  if(-not $WhatIf){
    [void](Exec "INSERT INTO dbo.health_check_log(check_name,status,detail,metric_num,occurred_at) VALUES('purge','ok',@d,NULL,SYSDATETIME())" @{ d=($summary -join '; ') })
  }
  $cn.Close()
  Write-Host "Purge complete: $($summary -join '; ')" -ForegroundColor Green
  exit 0
}
catch {
  $msg=$_.Exception.Message
  try { [void](Exec "INSERT INTO dbo.health_check_log(check_name,status,detail,metric_num,occurred_at) VALUES('purge','fail',@d,NULL,SYSDATETIME())" @{ d=$msg }) } catch {}
  try { $cn.Close() } catch {}
  Write-Host "Purge FAILED: $msg" -ForegroundColor Red
  exit 1
}
