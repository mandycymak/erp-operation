<#
  watch-bookings.ps1 - new-booking -> factory(shipper) alert watcher.
  Scans the source ERP for EXPORT bookings created in the last -WindowHours (default 24) and, for any not already
  recorded in dbo.booking_alert (deduped by station+mode+erp_ref), resolves the shipper(factory) contact from
  custsub and records a booking_alert row. If the config `bookingAlert.enabled` is true it NOTIFIES via the
  `alerts` webhook/SMTP (the ops channel); only when `bookingAlert.emailFactory` is also true AND SMTP is set does
  it email the factory directly. With bookingAlert disabled it still RECORDS the rows (so detection is visible/
  testable) and sends nothing. Source ERP is READ-ONLY; all writes go to the ops DB. Run frequently per station x
  mode (like the worklist seeder).
  Usage: .\watch-bookings.ps1 [-Station fm3khkg] [-StationCode HKG] [-Mode Sea] [-WindowHours 24]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [string]$Station="pgshkg", [string]$StationCode="HKG",
  [ValidateSet('Sea','Air')][string]$Mode='Sea',
  [int]$WindowHours=24
)
$ErrorActionPreference="Stop"
$cfg=[IO.File]::ReadAllText($ConfigPath)|ConvertFrom-Json
function EnvOrConfig($n,$v){ $e=[Environment]::GetEnvironmentVariable($n); if($e -and $e.Trim()){$e}else{$v} }
$server=EnvOrConfig "DB_SERVER" $cfg.server; $auth=EnvOrConfig "DB_AUTH" $cfg.auth
$user=EnvOrConfig "DB_USER" $cfg.user; $pwd=EnvOrConfig "DB_PASSWORD" $cfg.password; $opsDb=EnvOrConfig "DB_OPS_DB" $cfg.opsDb
$ac= if($auth -eq 'sql'){"User ID=$user;Password=$pwd"}else{"Integrated Security=True"}
$opsServer=EnvOrConfig "DB_OPS_SERVER" $cfg.opsServer; if(-not ("$opsServer".Trim())){ $opsServer=$server }
$opsAuth=EnvOrConfig "DB_OPS_AUTH" $cfg.opsAuth; if(-not ("$opsAuth".Trim())){ $opsAuth=$auth }
$opsUser=EnvOrConfig "DB_OPS_USER" $cfg.opsUser; if(-not ("$opsUser".Trim())){ $opsUser=$user }
$opsPwd=EnvOrConfig "DB_OPS_PASSWORD" $cfg.opsPassword; if(-not ("$opsPwd".Trim())){ $opsPwd=$pwd }
$opsAc= if($opsAuth -eq 'sql'){"User ID=$opsUser;Password=$opsPwd"}else{"Integrated Security=True"}
function CS($db){ if($db -eq $opsDb -or $db -eq 'master'){ "Server=$opsServer;Database=$db;$opsAc;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512" } else { "Server=$server;Database=$db;$ac;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512" } }
function Test-Transient($ex){ "$($ex.Message)" -match 'semaphore timeout|transport-level|timeout period|deadlock|not currently available|forcibly closed' }
function Query($db,$sql,[hashtable]$p){
  for($a=1;;$a++){ try{
    $cn=New-Object System.Data.SqlClient.SqlConnection (CS $db); $cn.Open()
    $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=90
    if($p){foreach($k in $p.Keys){[void]$c.Parameters.AddWithValue("@$k",$p[$k])}}
    $r=$c.ExecuteReader(); $rows=@()
    while($r.Read()){ $o=[ordered]@{}; for($i=0;$i -lt $r.FieldCount;$i++){ $v=$r.GetValue($i); $o[$r.GetName($i)]= if($v -is [DBNull]){$null}else{$v} }; $rows+=[pscustomobject]$o }
    $r.Close(); $cn.Close(); return ,$rows
  } catch { if($a -ge 5 -or -not (Test-Transient $_.Exception)){throw}; Start-Sleep -Seconds ($a*2) } }
}
$opsCn=New-Object System.Data.SqlClient.SqlConnection (CS $opsDb); $opsCn.Open()
function Exec($sql,[hashtable]$p){
  for($a=1;;$a++){ try{
    if($opsCn.State -ne 'Open'){ $opsCn.Close(); $script:opsCn=New-Object System.Data.SqlClient.SqlConnection (CS $opsDb); $opsCn.Open() }
    $c=$opsCn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=60
    if($p){foreach($k in $p.Keys){ $v=$p[$k]; [void]$c.Parameters.AddWithValue("@$k",$(if($null -eq $v){[DBNull]::Value}else{$v})) }}
    [void]$c.ExecuteNonQuery(); return
  } catch { if($a -ge 5 -or -not (Test-Transient $_.Exception)){throw}; try{$opsCn.Close()}catch{}; Start-Sleep -Seconds ($a*2) } }
}

# ---- notification settings (reuses the top-level `alerts` channel; `bookingAlert` toggles sending) ----
$al = $cfg.alerts
$ba = $cfg.bookingAlert
$sendOn = $ba -and ($ba.enabled -eq $true)
$emailFactory = $ba -and ($ba.emailFactory -eq $true)
$win = if($ba -and $ba.windowHours){ [int]$ba.windowHours } else { $WindowHours }

# send the ops webhook (Teams/Slack) - returns $true if it fired
function Send-Webhook($text){
  if(-not ($al -and "$($al.webhookUrl)".Trim())){ return $false }
  try { Invoke-RestMethod -Uri $al.webhookUrl -Method Post -ContentType 'application/json' -Body (@{ text=$text } | ConvertTo-Json) -TimeoutSec 15 | Out-Null; return $true }
  catch { Write-Host "  webhook FAILED: $($_.Exception.Message)" -ForegroundColor Red; return $false }
}
# send an email via SMTP to an explicit recipient - returns $true if it fired
function Send-Email($to,$subject,$body){
  if(-not ($al -and $al.smtp -and "$($al.smtp.host)".Trim() -and "$($al.smtp.from)".Trim() -and "$to".Trim())){ return $false }
  try {
    $smtp=New-Object System.Net.Mail.SmtpClient($al.smtp.host, [int]$(if($al.smtp.port){$al.smtp.port}else{25}))
    if($al.smtp.ssl){ $smtp.EnableSsl=$true }
    if("$($al.smtp.user)".Trim()){ $smtp.Credentials=New-Object System.Net.NetworkCredential($al.smtp.user,"$($al.smtp.password)") }
    $msg=New-Object System.Net.Mail.MailMessage; $msg.From=$al.smtp.from; $msg.To.Add($to); $msg.Subject=$subject; $msg.Body=$body
    $smtp.Send($msg); return $true
  } catch { Write-Host "  email FAILED ($to): $($_.Exception.Message)" -ForegroundColor Red; return $false }
}

# ---- scan recent EXPORT bookings (the factory is the shipper at origin) ----
if($Mode -eq 'Air'){
  $tbl='awbhead'; $typeWhere="awb_type IN('B','H','S')"; $noCol='booking'
  $cols="ref,jobn,booking,shpr_code,shpr_name,pol,pod,crtdate"
} else {
  $tbl='blhead'; $typeWhere="bill_type IN('B','H')"; $noCol='sono'
  $cols="ref,jobn,sono,shpr_code,shpr_name,pol,pod,crtdate"
}
$rows = Query $Station "SELECT $cols FROM dbo.$tbl WHERE $typeWhere AND bound='O' AND comp_date IS NULL AND crtdate>=DATEADD(hour,-@h,SYSDATETIME())" @{ h=$win }
Write-Host "watch-bookings: $($rows.Count) $Mode export booking(s) in $Station in the last $win h" -ForegroundColor Gray

$new=0; $sent=0
foreach($r in $rows){
  $ref="$($r.ref)".Trim(); if(-not $ref){ continue }
  $bk="$($r.$noCol)".Trim(); $job="$($r.jobn)".Trim(); $sc="$($r.shpr_code)".Trim()
  # already alerted? (deduped per booking)
  $ex = Query $opsDb "SELECT 1 x FROM dbo.booking_alert WHERE station=@s AND mode=@m AND erp_ref=@r" @{ s=$StationCode; m=$Mode; r=$ref }
  if($ex.Count){ continue }
  # resolve the factory (shipper) contact from the customer master
  $contact=$null; $email=$null
  if($sc){
    $cu = Query $Station "SELECT TOP 1 contact1,email1 FROM dbo.custsub WHERE code2=@c AND ISNULL(isdel,0)=0" @{ c=$sc }
    if($cu.Count){ $contact="$($cu[0].contact1)".Trim(); $email="$($cu[0].email1)".Trim() }
  }
  $subject="New booking $bk - $($r.shpr_name) ($StationCode $Mode)"
  $body="A booking has been received.`nBooking: $bk`nFactory/Shipper: $($r.shpr_name) [$sc]`nLane: $($r.pol) -> $($r.pod)`nJob: $job`nCreated: $($r.crtdate)"
  $channel='none'; $status='pending'
  if($sendOn){
    $fired=$false
    if(Send-Webhook ("New booking $bk ($StationCode $Mode) - $($r.shpr_name): $($r.pol)->$($r.pod)")){ $fired=$true; $channel='webhook' }
    if($emailFactory -and $email){ if(Send-Email $email $subject $body){ $fired=$true; $channel='factory-email' } }
    elseif($al -and $al.smtp -and $al.smtp.to){ foreach($t in @($al.smtp.to)){ if(Send-Email $t $subject $body){ $fired=$true; if($channel -eq 'none'){ $channel='email' } } } }
    $status = if($fired){ 'notified' } else { 'failed' }
  } else { $status='pending'; $channel='none' }
  # record (UNIQUE guard tolerates a same-instant double run)
  try {
    Exec "INSERT INTO dbo.booking_alert(station,mode,erp_ref,job_no,booking_no,shipper_code,shipper_name,factory_contact,factory_email,pol,pod,src_created,status,channel,notified_at) VALUES(@s,@m,@r,@j,@b,@sc,@sn,@fc,@fe,@pol,@pod,@cr,@st,@ch,$(if($status -eq 'notified'){'SYSDATETIME()'}else{'NULL'}))" @{
      s=$StationCode; m=$Mode; r=$ref; j=$(if($job){$job}else{$null}); b=$(if($bk){$bk}else{$null}); sc=$(if($sc){$sc}else{$null});
      sn="$($r.shpr_name)".Trim(); fc=$(if($contact){$contact}else{$null}); fe=$(if($email){$email}else{$null});
      pol="$($r.pol)".Trim(); pod="$($r.pod)".Trim(); cr=$r.crtdate; st=$status; ch=$channel }
    $new++; if($status -eq 'notified'){ $sent++ }
  } catch { if("$($_.Exception.Message)" -notmatch 'UQ_booking_alert|duplicate key'){ throw } }
}
$opsCn.Close()
Write-Host "watch-bookings: $new new alert(s) recorded for $StationCode $Mode, $sent notified ($(if($sendOn){'sending ON'}else{'recording only - bookingAlert.enabled=false'}))." -ForegroundColor Green
