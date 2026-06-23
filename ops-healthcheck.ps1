<#
  ops-healthcheck.ps1 - the watchdog. Runs every ~20-30 min (Task Scheduler). For each check it writes a row to
  health_check_log (so the in-app IT-Admin "Audit & Health" board shows current state + recovery), and on ANY
  failure it appends to ops-health.log + sends an alert (SMTP and/or webhook from the config `alerts` block) and
  exits non-zero. A 'fail' followed later by an 'ok' is how support sees a problem AND its recovery.

  Checks: app (HTTP /api-ops/health), db (SELECT 1), tasks (Ops * scheduled-task last result), feed freshness,
  backup recency, ops DB size, free disk, and (if a source ERP server is configured) VPN reachability (TCP 1433).
  Usage: .\ops-healthcheck.ps1 [-ConfigPath .\ops.config.json] [-HealthUrl http://localhost:8078/api-ops/health]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [string]$HealthUrl="",
  [string]$BackupDir=(Join-Path $PSScriptRoot "backups")
)
$ErrorActionPreference="Stop"
$cfg=[IO.File]::ReadAllText($ConfigPath)|ConvertFrom-Json
$r=$cfg.retention; $al=$cfg.alerts
function Num($v,$d){ if($v){[double]$v}else{$d} }
$FeedStaleHours = Num $r.feedStaleHours 12
$BackupStaleHrs = Num $r.backupStaleHours 26
$DbSizeWarnMb   = Num $r.dbSizeWarnMb 5000
$DiskFreeWarnMb = Num $r.diskFreeWarnMb 2000

function EnvOrConfig($n,$v){ $e=[Environment]::GetEnvironmentVariable($n); if($e -and $e.Trim()){$e}else{$v} }
$server=EnvOrConfig "DB_SERVER" $cfg.server; $auth=EnvOrConfig "DB_AUTH" $cfg.auth
$user=EnvOrConfig "DB_USER" $cfg.user; $pwd=EnvOrConfig "DB_PASSWORD" $cfg.password
$opsDb=EnvOrConfig "DB_OPS_DB" $cfg.opsDb
$opsServer=EnvOrConfig "DB_OPS_SERVER" $cfg.opsServer; if(-not ("$opsServer".Trim())){ $opsServer=$server }
$opsAuth=EnvOrConfig "DB_OPS_AUTH" $cfg.opsAuth; if(-not ("$opsAuth".Trim())){ $opsAuth=$auth }
$opsUser=EnvOrConfig "DB_OPS_USER" $cfg.opsUser; if(-not ("$opsUser".Trim())){ $opsUser=$user }
$opsPwd=EnvOrConfig "DB_OPS_PASSWORD" $cfg.opsPassword; if(-not ("$opsPwd".Trim())){ $opsPwd=$pwd }
$opsAc= if($opsAuth -eq 'sql'){"User ID=$opsUser;Password=$opsPwd"}else{"Integrated Security=True"}
$cs="Server=$opsServer;Database=$opsDb;$opsAc;TrustServerCertificate=True;Connect Timeout=10;Packet Size=512"

if(-not $HealthUrl){
  if("$($cfg.healthUrl)".Trim()){ $HealthUrl=$cfg.healthUrl }
  else { $port=if($cfg.port){$cfg.port}else{8078}; $HealthUrl="http://localhost:$port/api-ops/health" }
}
# The watchdog probes its OWN host; accept a self-signed / localhost cert for the https probe (PS 5.1 has no
# -SkipCertificateCheck). Scoped to this short-lived process only.
try { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
      [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}

$cn=$null
try { $cn=New-Object System.Data.SqlClient.SqlConnection $cs; $cn.Open() } catch { $cn=$null }

$results=@()   # @{ name; status; detail; metric }
function Add-Result($name,$ok,$detail,$metric){ $script:results += @{ name=$name; status=$(if($ok){'ok'}else{'fail'}); detail=$detail; metric=$metric } }
function ScalarOps($sql){ if(-not $cn){ return $null }; $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=10; return $c.ExecuteScalar() }

# --- app (HTTP health) ---
try {
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $resp=Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 10
  $sw.Stop()
  $ok=($resp.StatusCode -eq 200) -and ($resp.Content -match '"ok"\s*:\s*true')
  Add-Result "app" $ok ("HTTP $($resp.StatusCode) in $($sw.ElapsedMilliseconds) ms") $sw.ElapsedMilliseconds
} catch { Add-Result "app" $false "HTTP request failed: $($_.Exception.Message)" $null }

# --- db (SELECT 1) ---
if($cn){ try { [void](ScalarOps "SELECT 1"); Add-Result "db" $true "SELECT 1 ok" $null } catch { Add-Result "db" $false $_.Exception.Message $null } }
else { Add-Result "db" $false "cannot open ops DB connection" $null }

# --- scheduled tasks (Ops *) ---
try {
  $tasks=@(Get-ScheduledTask -TaskName "Ops *" -ErrorAction SilentlyContinue)
  if($tasks.Count -eq 0){ Add-Result "tasks" $false "no 'Ops *' scheduled tasks registered" 0 }
  else {
    $bad=@()
    foreach($t in $tasks){
      $info=Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
      # 0 = ok; 0x41301/267009 = currently running; both are healthy.
      if($info -and $info.LastTaskResult -ne 0 -and $info.LastTaskResult -ne 267009){ $bad += ("{0}=0x{1:X}" -f $t.TaskName,$info.LastTaskResult) }
    }
    if($bad.Count){ Add-Result "tasks" $false ("failed: " + ($bad -join ', ')) $bad.Count }
    else { Add-Result "tasks" $true "$($tasks.Count) task(s), all last-run ok" $tasks.Count }
  }
} catch { Add-Result "tasks" $false "could not read scheduled tasks: $($_.Exception.Message)" $null }

# --- feed freshness (newest shipment_alerts.updated_at) ---
if($cn){ try {
  $age=ScalarOps "SELECT DATEDIFF(minute, MAX(updated_at), SYSDATETIME()) FROM dbo.shipment_alerts"
  if($null -eq $age){ Add-Result "feed" $true "no rows yet" $null }
  else { $h=[Math]::Round($age/60.0,1); Add-Result "feed" ($age -le $FeedStaleHours*60) "newest worklist row $h h old" $h }
} catch { Add-Result "feed" $false $_.Exception.Message $null } }

# --- backup recency (newest .bak age) ---
try {
  $bak=@(Get-ChildItem -Path $BackupDir -Filter "*.bak" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  if($bak.Count -eq 0){ Add-Result "backup" $false "no .bak found in $BackupDir" $null }
  else { $h=[Math]::Round(((Get-Date)-$bak[0].LastWriteTime).TotalHours,1); Add-Result "backup" ($h -le $BackupStaleHrs) "newest .bak $h h old" $h }
} catch { Add-Result "backup" $false $_.Exception.Message $null }

# --- storage: ops DB size ---
if($cn){ try {
  $mb=[double](ScalarOps "SELECT CAST(SUM(size)*8.0/1024 AS decimal(18,1)) FROM sys.database_files")
  Add-Result "storage:db" ($mb -le $DbSizeWarnMb) "ops DB $mb MB (warn > $DbSizeWarnMb)" $mb
} catch { Add-Result "storage:db" $false $_.Exception.Message $null } }

# --- storage: free disk on the backup drive ---
try {
  $root=[IO.Path]::GetPathRoot($BackupDir)
  if(-not $root){ $root=[IO.Path]::GetPathRoot($PSScriptRoot) }
  $drv=New-Object IO.DriveInfo $root
  $freeMb=[Math]::Round($drv.AvailableFreeSpace/1MB,0)
  Add-Result "storage:disk" ($freeMb -ge $DiskFreeWarnMb) "$root free $freeMb MB (warn < $DiskFreeWarnMb)" $freeMb
} catch { Add-Result "storage:disk" $false $_.Exception.Message $null }

# --- VPN / source ERP reachability (TCP 1433) ---
if("$server".Trim()){
  try {
    $hostOnly=("$server" -split ',')[0].Trim()
    $t=Test-NetConnection -ComputerName $hostOnly -Port 1433 -WarningAction SilentlyContinue
    Add-Result "erp-vpn" ($t.TcpTestSucceeded) "${hostOnly}:1433 $(if($t.TcpTestSucceeded){'reachable'}else{'UNREACHABLE'})" $null
  } catch { Add-Result "erp-vpn" $false "TCP test failed: $($_.Exception.Message)" $null }
}

# --- persist every result to health_check_log (best-effort; needs the DB) ---
if($cn){ try {
  foreach($x in $results){
    $c=$cn.CreateCommand()
    $c.CommandText="INSERT INTO dbo.health_check_log(check_name,status,detail,metric_num,occurred_at) VALUES(@n,@s,@d,@m,SYSDATETIME())"
    [void]$c.Parameters.AddWithValue("@n",$x.name); [void]$c.Parameters.AddWithValue("@s",$x.status)
    [void]$c.Parameters.AddWithValue("@d",$(if($null -eq $x.detail){[DBNull]::Value}else{$x.detail}))
    [void]$c.Parameters.AddWithValue("@m",$(if($null -eq $x.metric){[DBNull]::Value}else{$x.metric}))
    [void]$c.ExecuteNonQuery()
  }
} catch { Write-Host "warn: could not write health_check_log: $($_.Exception.Message)" -ForegroundColor Yellow } }
if($cn){ try { $cn.Close() } catch {} }

# --- report + alert on failures ---
$fails=@($results | Where-Object { $_.status -eq 'fail' })
$stamp=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
foreach($x in $results){ $col=if($x.status -eq 'ok'){'Green'}else{'Red'}; Write-Host ("  [{0}] {1} - {2}" -f $x.status.ToUpper(),$x.name,$x.detail) -ForegroundColor $col }

if($fails.Count -eq 0){ Write-Host "All health checks passed ($($results.Count))." -ForegroundColor Green; exit 0 }

$inst=if($cfg.instanceName){$cfg.instanceName}else{$opsDb}
$subject="[Control Tower] $($fails.Count) health check(s) FAILED - $inst"
$bodyLines=@("$stamp  $inst")
foreach($x in $fails){ $bodyLines += (" - {0}: {1}" -f $x.name,$x.detail) }
$body=$bodyLines -join "`r`n"
[IO.File]::AppendAllText((Join-Path $PSScriptRoot "ops-health.log"),"$subject`r`n$body`r`n`r`n",(New-Object System.Text.UTF8Encoding($false)))

# webhook (Teams / Slack-compatible {text:...})
if($al -and "$($al.webhookUrl)".Trim()){
  try { Invoke-RestMethod -Uri $al.webhookUrl -Method Post -ContentType 'application/json' -Body (@{ text="$subject`n$body" } | ConvertTo-Json) -TimeoutSec 15 | Out-Null; Write-Host "alert: webhook sent" -ForegroundColor Yellow }
  catch { Write-Host "alert: webhook FAILED: $($_.Exception.Message)" -ForegroundColor Red }
}
# email (SMTP) via System.Net.Mail (Send-MailMessage is deprecated)
if($al -and $al.smtp -and "$($al.smtp.host)".Trim() -and "$($al.smtp.from)".Trim() -and $al.smtp.to){
  try {
    $smtp=New-Object System.Net.Mail.SmtpClient($al.smtp.host, [int](Num $al.smtp.port 25))
    if($al.smtp.ssl){ $smtp.EnableSsl=$true }
    if("$($al.smtp.user)".Trim()){ $smtp.Credentials=New-Object System.Net.NetworkCredential($al.smtp.user,"$($al.smtp.password)") }
    $msg=New-Object System.Net.Mail.MailMessage
    $msg.From=$al.smtp.from; foreach($to in @($al.smtp.to)){ $msg.To.Add($to) }
    $msg.Subject=$subject; $msg.Body=$body
    $smtp.Send($msg); Write-Host "alert: email sent" -ForegroundColor Yellow
  } catch { Write-Host "alert: email FAILED: $($_.Exception.Message)" -ForegroundColor Red }
}

Write-Host "$($fails.Count) check(s) failed." -ForegroundColor Red
exit 1
