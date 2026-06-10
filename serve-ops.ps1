<#
  serve-ops.ps1  — Control Tower web service (HttpListener + JSON API + static files).
  Reads ONLY the small pgsops tables (shipment_alerts) — never the ERP on a request path.
  Lifts serve-dashboard.ps1's proven plumbing: Send-Json/Send-File (no-store), RunQ retry,
  the follow-up subsystem (here keyed by job_no), and the SQL-free-endpoints-before-$cn rule.

  Open mode (no users.json): the client picks a "current operator" sent via the X-Ops-User header
  (demo identity for the worklist + @-mention loop; NOT a security boundary).
  Local test:  .\serve-ops.ps1 [-Port 8078]
#>
param([string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"), [string]$Hostname="localhost", [int]$Port=0)
$ErrorActionPreference="Stop"
$cfg=Get-Content $ConfigPath -Raw|ConvertFrom-Json
function EnvOrConfig($n,$v){ $e=[Environment]::GetEnvironmentVariable($n); if($e -and $e.Trim()){$e}else{$v} }
$server=EnvOrConfig "DB_SERVER" $cfg.server; $auth=EnvOrConfig "DB_AUTH" $cfg.auth
$user=EnvOrConfig "DB_USER" $cfg.user; $password=EnvOrConfig "DB_PASSWORD" $cfg.password; $opsDb=EnvOrConfig "DB_OPS_DB" $cfg.opsDb
if($Port -le 0){ if($env:DB_PORT -and $env:DB_PORT.Trim()){ $Port=[int]$env:DB_PORT } else { $Port=[int]$cfg.port } }
# the web service reads ONLY pgsops, so it connects to the OPS server (may differ from the source ERP; falls back to source)
$opsServer=EnvOrConfig "DB_OPS_SERVER" $cfg.opsServer; if(-not ("$opsServer".Trim())){ $opsServer=$server }
$opsAuth=EnvOrConfig "DB_OPS_AUTH" $cfg.opsAuth; if(-not ("$opsAuth".Trim())){ $opsAuth=$auth }
$opsUser=EnvOrConfig "DB_OPS_USER" $cfg.opsUser; if(-not ("$opsUser".Trim())){ $opsUser=$user }
$opsPassword=EnvOrConfig "DB_OPS_PASSWORD" $cfg.opsPassword; if(-not ("$opsPassword".Trim())){ $opsPassword=$password }
$authClause= if($opsAuth -eq 'sql'){"User ID=$opsUser;Password=$opsPassword"}else{"Integrated Security=True"}
$ConnStr="Server=$opsServer;Database=$opsDb;$authClause;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512"
$AppName= if($cfg.appName){$cfg.appName}else{"Control Tower"}
$AppSubtitle= if($cfg.appSubtitle){$cfg.appSubtitle}else{""}
$InstanceName= if($cfg.instanceName){$cfg.instanceName}else{""}
$StationCode= if($cfg.stationCode){"$($cfg.stationCode)".Trim()}else{""}   # which station this instance serves (inbound feed)
$Root=$PSScriptRoot
$ListDir=Join-Path $Root "ops-lists"; if(-not (Test-Path $ListDir)){ New-Item -ItemType Directory -Path $ListDir|Out-Null }
$NotesPath=Join-Path $ListDir "job-notes.json"

# ---------------- identity (open mode) ----------------
$UsersPath=Join-Path $Root "users.json"
$script:AuthOn = Test-Path $UsersPath        # users.json present -> (future) real auth; absent -> open/demo mode
function Me-User($ctx){
  $h="$($ctx.Request.Headers['X-Ops-User'])".Trim()
  if($h){ return $h }
  $q="$($ctx.Request.QueryString['as'])".Trim(); if($q){ return $q }
  '(open)'
}

# ---------------- HTTP plumbing (lifted) ----------------
function Read-Body($ctx){ $sr=New-Object IO.StreamReader($ctx.Request.InputStream,$ctx.Request.ContentEncoding); try{$sr.ReadToEnd()}finally{$sr.Close()} }
function Send-Json($ctx,$obj,$code=200){
  $json=$obj|ConvertTo-Json -Depth 12 -Compress
  $bytes=[Text.Encoding]::UTF8.GetBytes($json)
  $ctx.Response.StatusCode=$code; $ctx.Response.ContentType="application/json; charset=utf-8"
  $ctx.Response.Headers["Access-Control-Allow-Origin"]="*"
  $ctx.Response.Headers["Cache-Control"]="no-store, no-cache, must-revalidate, max-age=0"
  $ctx.Response.Headers["Pragma"]="no-cache"; $ctx.Response.Headers["Expires"]="0"
  $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length); $ctx.Response.OutputStream.Close()
}
function Ctype($path){ switch([IO.Path]::GetExtension($path).ToLower()){ ".html"{"text/html; charset=utf-8"} ".js"{"application/javascript; charset=utf-8"} ".css"{"text/css; charset=utf-8"} ".json"{"application/json; charset=utf-8"} ".svg"{"image/svg+xml"} default{"application/octet-stream"} } }
function Send-File($ctx,$path){
  if(-not (Test-Path $path)){ $ctx.Response.StatusCode=404; $ctx.Response.OutputStream.Close(); return }
  $bytes=[IO.File]::ReadAllBytes($path); $ctx.Response.ContentType=Ctype $path
  $ctx.Response.Headers["Cache-Control"]="no-store, no-cache, must-revalidate, max-age=0"; $ctx.Response.Headers["Pragma"]="no-cache"
  $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length); $ctx.Response.OutputStream.Close()
}
function Test-Transient($ex){ "$($ex.Message)" -match 'semaphore timeout|transport-level|network-related|forcibly closed|not currently available|timeout period elapsed|pre-login' }
function Reset-Conn($cn){ try{ if($cn.State -ne 'Open'){ $cn.Close(); $cn.Open() } }catch{ try{$cn.Open()}catch{} } }
function RunQ($cn,$sql,$params,$timeoutSec=45){
  for($attempt=1;;$attempt++){ try{
    $cmd=$cn.CreateCommand(); $cmd.CommandText=$sql; $cmd.CommandTimeout=$timeoutSec
    foreach($k in $params.Keys){ $v=$params[$k]; [void]$cmd.Parameters.AddWithValue("@$k",$(if($null -eq $v){[DBNull]::Value}else{$v})) }
    $r=$cmd.ExecuteReader(); $rows=@()
    while($r.Read()){ $o=[ordered]@{}; for($i=0;$i -lt $r.FieldCount;$i++){ $v=$r.GetValue($i); if($v -is [DBNull]){$v=$null}; $o[$r.GetName($i)]=$v }; $rows+=[pscustomobject]$o }
    $r.Close(); return $rows
  } catch { $isTimeout="$($_.Exception.Message)" -match 'Timeout expired|Execution Timeout|timeout period elapsed'
    if($attempt -ge 2 -or $isTimeout -or -not (Test-Transient $_.Exception)){ throw }; Reset-Conn $cn; Start-Sleep -Milliseconds (300*$attempt) } }
}

# ---------------- notes store (job_no-keyed; lifted from the follow-up subsystem) ----------------
# Return only real note records (each has an id). Filtering by .id self-heals any legacy wrapper junk and
# sidesteps PS 5.1's array-wrapping quirks. Always consume via @(Read-Notes) at call sites.
function Read-Notes {
  if(-not (Test-Path $NotesPath)){ return @() }
  $parsed=$null; try{ $parsed=Get-Content $NotesPath -Raw|ConvertFrom-Json }catch{ return @() }
  @($parsed | Where-Object { $_ -and $_.id })
}
# Serialize each record INDIVIDUALLY then join — never hand ConvertTo-Json a whole array/ArrayList (which PS 5.1
# mangles into {value,Count} wrappers or a bare object). Guarantees a clean JSON array of plain note objects.
function Write-Notes($arr){
  $parts = @($arr | Where-Object { $_ -and $_.id } | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress })
  [System.IO.File]::WriteAllText($NotesPath, '[' + ($parts -join ',') + ']', (New-Object System.Text.UTF8Encoding($false)))
}
function Note-Proj($r){ [pscustomobject]@{ id=[string]$r.id; created=[string]$r.created; user=[string]$r.user; job_no=[string]$r.job_no; milestone_code=[string]$r.milestone_code; kind=$(if($r.kind){"$($r.kind)"}else{'note'}); note=[string]$r.note; mentions=@($r.mentions|Where-Object{$_}); status=$(if($r.status){"$($r.status)"}else{'open'}); doneBy=[string]$r.doneBy; doneAt=[string]$r.doneAt; arrType=[string]$r.arr_type; party=[string]$r.party; contact=[string]$r.contact; arrStatus=[string]$r.arr_status; remindOn=[string]$r.remind_on } }
function Save-Note($ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.job_no){ return @{error='invalid payload'} }
  $arr=@(Read-Notes)
  $ment=@(@($j.mentions)|Where-Object{ $_ -and "$_".Trim() -ne '' }|ForEach-Object{"$_".Trim()}|Select-Object -Unique)
  $rec=[pscustomobject]@{ id=[guid]::NewGuid().ToString(); created=(Get-Date).ToString('o'); user=$me; job_no="$($j.job_no)"; milestone_code="$($j.milestone_code)"; kind=$(if($j.kind){"$($j.kind)"}else{'note'}); note="$($j.note)"; mentions=$ment; status='open'; doneBy=''; doneAt=''; arr_type="$($j.arr_type)"; party="$($j.party)"; contact="$($j.contact)"; arr_status=$(if($j.arr_status){"$($j.arr_status)"}else{''}); remind_on="$($j.remind_on)" }
  Write-Notes ($arr + $rec)
  @{ ok=$true; record=(Note-Proj $rec) }
}
function Handle-NoteList($qs){
  $job="$($qs['job'])".Trim(); $arr=Read-Notes
  $rows=@($arr|Where-Object{ $_ -and ((-not $job) -or ("$($_.job_no)".Trim() -eq $job)) }|Sort-Object{"$($_.created)"} -Descending)
  @{ records=@($rows|ForEach-Object{ Note-Proj $_ }) }
}
function Save-NoteDone($ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.id){ return @{error='invalid payload'} }
  $arr=@(Read-Notes); $id="$($j.id)"; $done= -not ($j.done -eq $false); $found=$false
  $out=@()
  foreach($r in $arr){
    if($r -and "$($r.id)" -eq $id){ $found=$true
      $r=[pscustomobject]@{ id=[string]$r.id; created=[string]$r.created; user=[string]$r.user; job_no=[string]$r.job_no; milestone_code=[string]$r.milestone_code; kind=$(if($r.kind){"$($r.kind)"}else{'note'}); note=[string]$r.note; mentions=@($r.mentions|Where-Object{$_}); status=$(if($done){'done'}else{'open'}); doneBy=$(if($done){$me}else{''}); doneAt=$(if($done){(Get-Date).ToString('o')}else{''}); arr_type=[string]$r.arr_type; party=[string]$r.party; contact=[string]$r.contact; arr_status=[string]$r.arr_status; remind_on=[string]$r.remind_on }
    }
    $out += $r
  }
  if(-not $found){ return @{error='not found'} }
  Write-Notes $out
  @{ ok=$true; id=$id; status=$(if($done){'done'}else{'open'}) }
}
# Project a note + its shipment context into a My-Tasks card (consignee/lane/vessel for at-a-glance).
function Task-Proj($n,$info){
  $s=$info["$($n.job_no)"]; $who=''; $lane=''; $vv=''; $astate=''; $cargo=''; $bound=''
  if($s){
    $bound="$($s.bound)"
    $who= if($bound -eq 'Import'){ "$($s.consignee_name)" } else { "$($s.shipper_name)" }
    $lane="$($s.lane)"; $vv="$($s.vessel_voyage)"; $astate="$($s.arrival_state)"
    $cargo= if("$($s.cargo_type)" -eq 'LCL'){ if($s.total_weight){ "$($s.total_weight) kg" } else { '' } } else { "$($s.container_summary)" }
  }
  [pscustomobject]@{ id=[string]$n.id; job_no=[string]$n.job_no; user=[string]$n.user; kind=$(if($n.kind){"$($n.kind)"}else{'note'});
    note=[string]$n.note; mentions=@($n.mentions|Where-Object{$_}); created=[string]$n.created; remindOn=[string]$n.remind_on;
    arrType=[string]$n.arr_type; consignee=[string]$who; lane=[string]$lane; vesselVoyage=[string]$vv; arrivalState=[string]$astate; cargo=[string]$cargo; bound=[string]$bound }
}
# "My Tasks" = follow-ups only (excludes bypass/reopen completion records). fromOthers = OPEN notes
# others @-mentioned me on; mine = OPEN notes I authored. Each enriched with shipment info; mine sorted by due date.
function Handle-MyTasks($cn,$me){
  $arr=Read-Notes
  $open=@($arr|Where-Object{ $_ -and (-not $_.status -or "$($_.status)" -eq 'open') -and ("$($_.kind)" -ne 'bypass') -and ("$($_.kind)" -ne 'reopen') })
  $assigned=@($open|Where-Object{ (@($_.mentions) -contains $me) -and ("$($_.user)" -ne $me) })
  $mine=@($open|Where-Object{ "$($_.user)" -eq $me })
  # one batched lookup of shipment context for all referenced jobs
  $jobs=@(@($assigned+$mine)|ForEach-Object{ "$($_.job_no)" }|Where-Object{$_}|Select-Object -Unique)
  $info=@{}
  if($jobs.Count){
    $p=@{}; $ins=@(); $i=0; foreach($j in $jobs){ $ins+="@j$i"; $p["j$i"]=$j; $i++ }
    $rows=@(RunQ $cn "SELECT job_no,bound,consignee_name,shipper_name,lane,vessel_voyage,arrival_state,cargo_type,CONVERT(varchar(20),total_weight) total_weight,container_summary FROM dbo.shipment_alerts WHERE job_no IN ($($ins -join ','))" $p)
    foreach($r in $rows){ $info["$($r.job_no)"]=$r }
  }
  $byDue={ @{Expression={ "$($_.remindOn)" -eq '' }}, @{Expression={ "$($_.remindOn)" }}, @{Expression={ "$($_.created)" };Descending=$true} }
  $assignedT=@($assigned|ForEach-Object{ Task-Proj $_ $info }|Sort-Object (& $byDue))
  $mineT=@($mine|ForEach-Object{ Task-Proj $_ $info }|Sort-Object (& $byDue))
  $today=(Get-Date).ToString('yyyy-MM-dd')
  $dueNow=@($mineT|Where-Object{ $_.remindOn -and "$($_.remindOn)" -le $today }).Count
  @{ assigned=$assignedT; mine=$mineT; assignedOpen=@($assignedT).Count; dueNow=$dueNow; today=$today }
}
# jobs the user is involved in via notes (authored or mentioned) — folded into the worklist "mine" lens
function My-NoteJobs($me){ @(Read-Notes|Where-Object{ $_ -and (("$($_.user)" -eq $me) -or (@($_.mentions) -contains $me)) }|ForEach-Object{"$($_.job_no)"}|Where-Object{$_}|Select-Object -Unique) }

# ---------------- SQL handlers (read only the small pgsops tables) ----------------
function Handle-Roster($cn){
  $ops=@(RunQ $cn "SELECT DISTINCT pic_user u FROM dbo.shipment_alerts WHERE NULLIF(pic_user,'') IS NOT NULL UNION SELECT DISTINCT created_by FROM dbo.shipment_alerts WHERE NULLIF(created_by,'') IS NOT NULL" @{}|ForEach-Object{"$($_.u)".Trim()})
  $noteUsers=@(); try{ $noteUsers=@(Read-Notes|ForEach-Object{ "$($_.user)"; $_.mentions }|Where-Object{$_ -and "$_".Trim() -ne ''}|ForEach-Object{"$_".Trim()}) }catch{}
  $all=@($ops+$noteUsers|Where-Object{$_ -and $_ -ne '(open)'}|Select-Object -Unique|Sort-Object)
  @{ users=@($all|ForEach-Object{ [pscustomobject]@{ username=$_; displayName=$_; email='' } }) }
}
# company picker: every company that appears (in any role) on an active shipment, with its resolved name.
function Handle-Companies($cn){
  $rows=@(RunQ $cn "SELECT c.code, c.name FROM dbo.company_dim c WHERE EXISTS (SELECT 1 FROM dbo.shipment_alerts a WHERE a.job_status='active' AND c.code IN (a.cust_code,a.shipper_code,a.consignee_code,a.agent_code,a.ctrl_code)) ORDER BY CASE WHEN NULLIF(c.name,'') IS NULL THEN 1 ELSE 0 END, c.name, c.code" @{})
  @{ companies=@($rows|ForEach-Object{ [pscustomobject]@{ code=[string]$_.code; name=$(if("$($_.name)".Trim()){"$($_.name)".Trim()}else{"$($_.code)"}) } }) }
}
# POL/POD pickers: distinct loading/discharge port codes on active shipments (with mode so the UI can scope).
function Handle-Ports($cn){
  $pol=@(RunQ $cn "SELECT DISTINCT pol code, mode FROM dbo.shipment_alerts WHERE job_status='active' AND NULLIF(pol,'') IS NOT NULL" @{})
  $pod=@(RunQ $cn "SELECT DISTINCT pod code, mode FROM dbo.shipment_alerts WHERE job_status='active' AND NULLIF(pod,'') IS NOT NULL" @{})
  @{ pol=@($pol|ForEach-Object{ [pscustomobject]@{ code=[string]$_.code; mode=[string]$_.mode } }); pod=@($pod|ForEach-Object{ [pscustomobject]@{ code=[string]$_.code; mode=[string]$_.mode } }) }
}
# Inbound cross-station bookings destined to THIS station (reads only the small pgsops feed; no ERP/cross-DB).
# Station = config stationCode, with an optional ?station= override (HQ/testing). Ordered by urgency then ETD.
function Handle-Inbound($cn,$qs){
  $st= if($qs['station']){ "$($qs['station'])".Trim() } else { $StationCode }
  if(-not $st){ return @{ station=''; rows=@(); note='no stationCode configured' } }
  $p=@{ st=$st }; $w=" WHERE f.dest_station=@st AND f.feed_status<>'void' "
  if($qs['mode']){ $w+=" AND f.mode=@md "; $p['md']="$($qs['mode'])" }
  if($qs['from']){ $w+=" AND (f.etd IS NULL OR f.etd>=@from) "; $p['from']="$($qs['from'])" }
  if($qs['to']){   $w+=" AND (f.etd IS NULL OR f.etd<=@to) ";   $p['to']="$($qs['to'])" }
  if($qs['status']){ $w+=" AND f.feed_status=@fs "; $p['fs']="$($qs['status'])" }
  # default recency window: hide stale/departed clutter — keep upcoming departures (ETD today+) and recently-booked
  # new bookings (last 90d). showAll=1 reveals everything. (Operators think in weeks; this defaults to ~13 weeks.)
  if(-not $qs['showAll']){
    $today=(Get-Date).ToString('yyyy-MM-dd'); $cut90=(Get-Date).AddDays(-90).ToString('yyyy-MM-dd')
    $w+=" AND ( (f.etd IS NOT NULL AND f.etd>=@today) OR (f.etd IS NULL AND (f.booking_date IS NULL OR f.booking_date>=@cut90)) ) "
    $p['today']=$today; $p['cut90']=$cut90
  }
  # dedup vs Arrivals: if this origin HBL already exists as a local import job, it's been received -> show it under
  # the arrival worklist, not here. (Origin office + HBL; matched on the HBL the consignee receives.)
  $w+=" AND NOT EXISTS (SELECT 1 FROM dbo.shipment_alerts sa WHERE sa.station=@st AND sa.bound='Import' AND NULLIF(LTRIM(RTRIM(f.house_bill)),'') IS NOT NULL AND sa.house_bill=f.house_bill) "
  $sel="SELECT source_station,mode,booking_no,dest_station,source_jobn,master_bill,house_bill,shipper_name," +
    "ctrl_code,ctrl_name,agent_code,agent_name,consignee_code,consignee_name,cargo_type,service,container_no,po_no,spot_id,booking_qty,booking_wgt," +
    "pol,pod,carrier,vessel_flight,CONVERT(varchar(10),etd,23) etd," +
    "CONVERT(varchar(10),cargo_ready,23) cargo_ready,incoterm,cargo_summary,CONVERT(varchar(10),booking_date,23) booking_date," +
    "feed_status,assigned_to,linked_job_no,light FROM dbo.inbound_booking_feed f $w " +
    "ORDER BY CASE light WHEN 'R' THEN 0 WHEN 'A' THEN 1 ELSE 2 END, etd, source_station, source_jobn, booking_no"
  $rows=@(RunQ $cn $sel $p)
  @{ station=$st; rows=@($rows|ForEach-Object{ [pscustomobject]@{ sourceStation=[string]$_.source_station; mode=[string]$_.mode; bookingNo=[string]$_.booking_no; destStation=[string]$_.dest_station; sourceJobn=[string]$_.source_jobn; masterBill=[string]$_.master_bill; houseBill=[string]$_.house_bill; shipperName=[string]$_.shipper_name; ctrlCode=[string]$_.ctrl_code; ctrlName=[string]$_.ctrl_name; agentCode=[string]$_.agent_code; agentName=[string]$_.agent_name; consigneeCode=[string]$_.consignee_code; consigneeName=[string]$_.consignee_name; cargoType=[string]$_.cargo_type; service=[string]$_.service; containerNo=[string]$_.container_no; poNo=[string]$_.po_no; spotId=[string]$_.spot_id; bookingQty=[string]$_.booking_qty; bookingWgt=[string]$_.booking_wgt; pol=[string]$_.pol; pod=[string]$_.pod; carrier=[string]$_.carrier; vesselFlight=[string]$_.vessel_flight; etd=[string]$_.etd; cargoReady=[string]$_.cargo_ready; incoterm=[string]$_.incoterm; cargoSummary=[string]$_.cargo_summary; bookingDate=[string]$_.booking_date; feedStatus=[string]$_.feed_status; assignedTo=[string]$_.assigned_to; linkedJobNo=[string]$_.linked_job_no; light=[string]$_.light } }) }
}
# Local assignment of an inbound booking to an operator. Updates the feed and threads a note keyed by a
# synthetic FEED:<src>:<booking_no> job so the assignee's existing My-Tasks inbox/badge lights up (no new infra).
function Save-InboundAssign($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.source_station -or -not $j.mode -or -not $j.booking_no){ return @{error='invalid payload'} }
  $assignee="$($j.assignee)".Trim()
  RunQ $cn "UPDATE dbo.inbound_booking_feed SET assigned_to=@a,updated_at=SYSDATETIME() WHERE source_station=@ss AND mode=@md AND booking_no=@bn" @{ a=$(if($assignee){$assignee}else{$null}); ss="$($j.source_station)"; md="$($j.mode)"; bn="$($j.booking_no)" } | Out-Null
  $job='FEED:'+"$($j.source_station)"+':'+"$($j.booking_no)"
  $ment=@(@(@($j.mentions)+$assignee)|Where-Object{ $_ -and "$_".Trim() -ne '' }|ForEach-Object{"$_".Trim()}|Select-Object -Unique)
  $txt= if($assignee){ "Assigned inbound booking to @$assignee" } else { "Unassigned inbound booking" }
  if("$($j.note)".Trim()){ $txt+=": $("$($j.note)".Trim())" }
  $rec=[pscustomobject]@{ id=[guid]::NewGuid().ToString(); created=(Get-Date).ToString('o'); user=$me; job_no=$job; milestone_code=''; kind='inbound'; note=$txt; mentions=$ment; status='open'; doneBy=''; doneAt=''; arr_type=''; party=''; contact=''; arr_status=''; remind_on='' }
  Write-Notes (@(Read-Notes) + $rec)
  @{ ok=$true; assignedTo=$assignee }
}
function Handle-Worklist($cn,$qs,$me){
  $lens="$($qs['lens'])"; if(-not $lens){ $lens='mine' }
  $who= if($lens -eq 'user' -and $qs['user']){ "$($qs['user'])".Trim() } else { $me }
  $p=@{}; $w=" WHERE job_status='active' "
  if($lens -eq 'all'){ }
  else {
    $clauses=@("pic_user=@me","created_by=@me","last_updated_by=@me"); $p['me']=$who
    $jobs=@(My-NoteJobs $who)
    if($jobs.Count){ $ins=@(); $i=0; foreach($j in $jobs){ $ins+="@nj$i"; $p["nj$i"]=$j; $i++ }; $clauses+=("job_no IN ("+($ins -join ',')+")") }
    $w+=" AND ("+($clauses -join ' OR ')+") "
  }
  if($qs['station']){ $w+=" AND station=@st "; $p['st']=$qs['station'] }
  if($qs['mode']){ $w+=" AND mode=@md "; $p['md']=$qs['mode'] }
  # date window on sort_key (the per-shipment operationally-relevant date: ATA/ETA arriving, ETD/cargo-ready
  # for export). NULL-keyed rows are kept so a window never silently hides a shipment that lacks a date.
  if($qs['from']){ $w+=" AND (sort_key IS NULL OR sort_key>=@from) "; $p['from']="$($qs['from'])" }
  if($qs['to']){   $w+=" AND (sort_key IS NULL OR sort_key<=@to) ";   $p['to']="$($qs['to'])" }
  # company filter: match the picked code against ANY role the company may play on a shipment
  if($qs['company']){ $w+=" AND @co IN (cust_code,shipper_code,consignee_code,agent_code,ctrl_code) "; $p['co']="$($qs['company'])" }
  if($qs['pol']){ $w+=" AND pol=@pol "; $p['pol']="$($qs['pol'])" }
  if($qs['pod']){ $w+=" AND pod=@pod "; $p['pod']="$($qs['pod'])" }
  $sel="SELECT job_no,station,mode,cargo_type,bound,lane,carrier,cust_code,salesman,pic_user,created_by,last_updated_by," +
    "CONVERT(varchar(10),anchor_date,23) anchor_date,CONVERT(varchar(10),etd,23) etd,CONVERT(varchar(10),eta,23) eta," +
    "CONVERT(varchar(10),atd,23) atd,CONVERT(varchar(10),ata,23) ata,worst_light,open_amber,open_red," +
    "CONVERT(varchar(10),next_due,23) next_due,auto_done,manual_done,consignee_name,shipper_name,cust_contact,cust_phone," +
    "cust_email,vessel_voyage,container_summary,container_count,total_weight,total_cbm,arrival_state," +
    "house_bill,master_bill,incoterm,cust_ref,container_no,liner_so,CONVERT(varchar(10),cargo_ready,23) cargo_ready," +
    "CONVERT(varchar(10),sort_key,23) sort_key FROM dbo.shipment_alerts $w " +
    "ORDER BY bound, CASE arrival_state WHEN 'arrived' THEN 0 WHEN 'no_space' THEN 0 WHEN 'arriving' THEN 1 WHEN 'customs_window' THEN 1 WHEN 'planning' THEN 2 WHEN 'cargo_pending' THEN 2 WHEN 'on_track' THEN 3 ELSE 9 END, sort_key, CASE worst_light WHEN 'R' THEN 0 WHEN 'A' THEN 1 ELSE 2 END"
  $rows=@(RunQ $cn $sel $p)
  # split open notes into "chat" (a real remark/task the operator should read) vs "status update" (a milestone
  # ticked/re-opened with NO remark) — so a bare tick shows a quiet update marker, not a misleading 💬.
  $chatJobs=@{}; $updJobs=@{}
  try{ foreach($nt in @(Read-Notes)){ if(-not $nt){ continue }
    $stt="$($nt.status)"; if($stt -and $stt -ne 'open'){ continue }
    $jk="$($nt.job_no)"; if(-not $jk){ continue }
    $kk="$($nt.kind)"; $isMs=($kk -eq 'bypass' -or $kk -eq 'reopen')
    $sil=$false
    if($nt.PSObject.Properties['silent']){ $sil=[bool]$nt.silent } elseif($isMs -and ("$($nt.note)" -notmatch ':')){ $sil=$true }  # back-compat: no-':' tick text = no remark
    if($isMs -and $sil){ $cur=$updJobs[$jk]; if(-not $cur -or "$($nt.created)" -gt "$($cur.created)"){ $updJobs[$jk]=@{ code="$($nt.milestone_code)"; created="$($nt.created)" } } }
    else { $chatJobs[$jk]=1 }
  } }catch{}
  # milestone code -> human name (keyed mode|bound|code; a code like A3 means different things per bound)
  $msName=@{}; try{ foreach($md in @(RunQ $cn "SELECT mode,bound,milestone_code,name FROM dbo.milestone_def")){ $msName[("$($md.mode)|$($md.bound)|$($md.milestone_code)").ToUpper()]=("$($md.name)").Trim() } }catch{}
  @{ lens=$lens; who=$who; rows=@($rows|ForEach-Object{ [pscustomobject]@{ jobNo=[string]$_.job_no; station=[string]$_.station; mode=[string]$_.mode; cargoType=[string]$_.cargo_type; bound=[string]$_.bound; lane=[string]$_.lane; carrier=[string]$_.carrier; custCode=[string]$_.cust_code; salesman=[string]$_.salesman; picUser=[string]$_.pic_user; createdBy=[string]$_.created_by; anchor=[string]$_.anchor_date; etd=[string]$_.etd; eta=[string]$_.eta; atd=[string]$_.atd; ata=[string]$_.ata; worst=[string]$_.worst_light; openAmber=[int]$_.open_amber; openRed=[int]$_.open_red; nextDue=[string]$_.next_due; autoDone=[int]$_.auto_done; manualDone=[int]$_.manual_done; consigneeName=[string]$_.consignee_name; shipperName=[string]$_.shipper_name; custContact=[string]$_.cust_contact; custPhone=[string]$_.cust_phone; custEmail=[string]$_.cust_email; vesselVoyage=[string]$_.vessel_voyage; containerSummary=[string]$_.container_summary; containerCount=[int]$_.container_count; totalWeight=[string]$_.total_weight; totalCbm=[string]$_.total_cbm; arrivalState=[string]$_.arrival_state; houseBill=[string]$_.house_bill; masterBill=[string]$_.master_bill; incoterm=[string]$_.incoterm; custRef=[string]$_.cust_ref; containerNo=[string]$_.container_no; linerSo=[string]$_.liner_so; cargoReady=[string]$_.cargo_ready; sortKey=[string]$_.sort_key; hasNotes=[bool]$chatJobs["$($_.job_no)"]; hasUpdate=[bool]$updJobs["$($_.job_no)"]; updateMilestone=$(if($updJobs["$($_.job_no)"]){[string]$updJobs["$($_.job_no)"].code}else{''}); updateMilestoneName=$(if($updJobs["$($_.job_no)"]){ $uc=[string]$updJobs["$($_.job_no)"].code; [string]$msName[("$($_.mode)|$($_.bound)|$uc").ToUpper()] }else{''}) } }) }
}
function Handle-Shipment($cn,$qs){
  $job="$($qs['job'])".Trim(); if(-not $job){ return @{error='job required'} }
  $row=@(RunQ $cn "SELECT TOP 1 job_no,milestone_checklist FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $row.Count){ return @{error='not found'} }
  $chk=$null; try{ $chk=("$($row[0].milestone_checklist)")|ConvertFrom-Json }catch{}
  $notes=(Handle-NoteList @{ job=$job }).records
  @{ jobNo=$job; checklist=$chk; notes=$notes }
}
# Manual Tick & Confirm on a milestone: overlay bypass/reopen onto the stored checklist, recompute the rollup,
# persist, and drop a note (so it threads + can @-mention). Pure JSON — no ERP touched.
function Save-MilestoneClose($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.job_no -or -not $j.milestone_code){ return @{error='invalid payload'} }
  $job="$($j.job_no)"; $code="$($j.milestone_code)"; $reopen=($j.done -eq $false)
  $row=@(RunQ $cn "SELECT TOP 1 milestone_checklist FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $row.Count){ return @{error='not found'} }
  $chk=("$($row[0].milestone_checklist)")|ConvertFrom-Json
  $found=$false
  foreach($m in @($chk.milestones)){
    if("$($m.code)" -eq $code){
      $found=$true
      # preserve the stored light/due so a reopen restores the original planned colour (rollup only counts 'pending')
      if($reopen){ $m.state='pending'; $m.done_by=''; $m.done_at=''; $m.basis='reopened' }
      else { $m.state='bypassed'; $m.done_by=$me; $m.done_at=(Get-Date).ToString('o'); $m.basis="manual: $($j.reason)" }
    }
  }
  if(-not $found){ return @{error='milestone not in checklist'} }
  # recompute rollup from items (pending milestones with A/R lights; bypass/done are cleared)
  $amber=0;$red=0;$auto=0;$man=0;$nextDue=$null
  foreach($m in @($chk.milestones)){
    $st="$($m.state)"
    if($st -eq 'bypassed'){ $man++ } elseif($st -eq 'done'){ $auto++ }
    elseif($st -eq 'pending'){ if("$($m.light)" -eq 'A'){$amber++} elseif("$($m.light)" -eq 'R'){$red++}
      if($m.due){ $d=[datetime]"$($m.due)"; if(-not $nextDue -or $d -lt $nextDue){ $nextDue=$d } } }
  }
  $worst= if($red){'R'}elseif($amber){'A'}else{'G'}
  $chk.rollup.worst_light=$worst; $chk.rollup.open_amber=$amber; $chk.rollup.open_red=$red
  $chk.rollup.next_due=$(if($nextDue){$nextDue.ToString('yyyy-MM-dd')}else{$null}); $chk.rollup.automation.manual=$man
  $nd=$(if($nextDue){$nextDue.ToString('yyyy-MM-dd')}else{$null})
  RunQ $cn "UPDATE dbo.shipment_alerts SET milestone_checklist=@chk,worst_light=@w,open_amber=@a,open_red=@r,next_due=@nd,manual_done=@m,updated_at=SYSDATETIME() WHERE job_no=@j" @{ chk=($chk|ConvertTo-Json -Depth 8 -Compress); w=$worst; a=$amber; r=$red; nd=$nd; m=$man; j=$job } | Out-Null
  # thread a note documenting the action (mentions optional)
  $ment=@(@($j.mentions)|Where-Object{ $_ -and "$_".Trim() -ne '' }|ForEach-Object{"$_".Trim()}|Select-Object -Unique)
  $kind= if($reopen){'reopen'}else{'bypass'}
  $txt= if($reopen){"Re-opened $code"}else{"Ticked $code complete" + $(if($j.reason){": $($j.reason)"}else{''})}
  # silent = a status change with no operator remark -> the worklist shows a quiet "updated" marker, not a 💬
  $silent=[bool](-not ("$($j.reason)").Trim())
  $newNote=[pscustomobject]@{ id=[guid]::NewGuid().ToString(); created=(Get-Date).ToString('o'); user=$me; job_no=$job; milestone_code=$code; kind=$kind; note=$txt; mentions=$ment; status='open'; doneBy=''; doneAt=''; silent=$silent }
  Write-Notes (@(Read-Notes) + $newNote)
  @{ ok=$true; jobNo=$job; milestone_code=$code; state=$(if($reopen){'pending'}else{'bypassed'}); worst=$worst; openAmber=$amber; openRed=$red; nextDue=$nd }
}

$StationList=@(@($cfg.stations)|Where-Object{ $_ -and $_.code }|ForEach-Object{ [pscustomobject]@{ code="$($_.code)".Trim(); name="$($_.name)".Trim() } })
function Config-Payload { @{ appName=$AppName; instanceName=$InstanceName; appSubtitle=$AppSubtitle; stationCode=$StationCode; stations=$StationList } }

# ---------------- listener ----------------
$listener=New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://${Hostname}:$Port/")
try{ $listener.Start() }catch{ Write-Host "Failed to bind http://${Hostname}:$Port/ -- $($_.Exception.Message)" -ForegroundColor Red; throw }
Write-Host "$AppName service running at http://${Hostname}:$Port/  (Ctrl+C to stop)" -ForegroundColor Green
Write-Host "Serving from $Root  |  ops DB [$opsDb] on $opsServer" -ForegroundColor DarkGray

while($listener.IsListening){
  $ctx=$listener.GetContext(); $path=$ctx.Request.Url.AbsolutePath
  try{
    $me=Me-User $ctx
    if($path -eq "/api-ops/config"){ Send-Json $ctx (Config-Payload) }
    elseif($path -eq "/api-ops/me"){ Send-Json $ctx @{ user=$me; authOn=$script:AuthOn } }
    elseif($path -eq "/api-ops/notes"){ if($ctx.Request.HttpMethod -eq 'POST'){ Send-Json $ctx (Save-Note $ctx $me) } else { Send-Json $ctx (Handle-NoteList $ctx.Request.QueryString) } }
    elseif($path -eq "/api-ops/note-done"){ Send-Json $ctx (Save-NoteDone $ctx $me) }
    elseif($path -like "/api-ops/*"){
      $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
      try{
        $qs=$ctx.Request.QueryString
        switch($path){
          "/api-ops/roster"          { Send-Json $ctx (Handle-Roster $cn) }
          "/api-ops/companies"       { Send-Json $ctx (Handle-Companies $cn) }
          "/api-ops/ports"           { Send-Json $ctx (Handle-Ports $cn) }
          "/api-ops/inbound"         { Send-Json $ctx (Handle-Inbound $cn $qs) }
          "/api-ops/inbound-assign"  { Send-Json $ctx (Save-InboundAssign $cn $ctx $me) }
          "/api-ops/my-tasks"        { Send-Json $ctx (Handle-MyTasks $cn $me) }
          "/api-ops/worklist"        { Send-Json $ctx (Handle-Worklist $cn $qs $me) }
          "/api-ops/shipment"        { Send-Json $ctx (Handle-Shipment $cn $qs) }
          "/api-ops/milestone-close" { Send-Json $ctx (Save-MilestoneClose $cn $ctx $me) }
          default                    { Send-Json $ctx @{ error="unknown endpoint" } 404 }
        }
      } finally { $cn.Close() }
    }
    else {
      $rel= if($path -eq "/"){ "index.html" } else { $path.TrimStart("/") }
      if($rel -match "\.\."){ $ctx.Response.StatusCode=400; $ctx.Response.OutputStream.Close() }
      else { Send-File $ctx (Join-Path $Root $rel) }
    }
  } catch { try{ Send-Json $ctx @{ error=$_.Exception.Message } 500 }catch{} }
}
