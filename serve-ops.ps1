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
$authClause= if($auth -eq 'sql'){"User ID=$user;Password=$password"}else{"Integrated Security=True"}
$ConnStr="Server=$server;Database=$opsDb;$authClause;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512"
$AppName= if($cfg.appName){$cfg.appName}else{"Control Tower"}
$AppSubtitle= if($cfg.appSubtitle){$cfg.appSubtitle}else{""}
$InstanceName= if($cfg.instanceName){$cfg.instanceName}else{""}
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
function Note-Proj($r){ [pscustomobject]@{ id=[string]$r.id; created=[string]$r.created; user=[string]$r.user; job_no=[string]$r.job_no; milestone_code=[string]$r.milestone_code; kind=$(if($r.kind){"$($r.kind)"}else{'note'}); note=[string]$r.note; mentions=@($r.mentions|Where-Object{$_}); status=$(if($r.status){"$($r.status)"}else{'open'}); doneBy=[string]$r.doneBy; doneAt=[string]$r.doneAt } }
function Save-Note($ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.job_no){ return @{error='invalid payload'} }
  $arr=@(Read-Notes)
  $ment=@(@($j.mentions)|Where-Object{ $_ -and "$_".Trim() -ne '' }|ForEach-Object{"$_".Trim()}|Select-Object -Unique)
  $rec=[pscustomobject]@{ id=[guid]::NewGuid().ToString(); created=(Get-Date).ToString('o'); user=$me; job_no="$($j.job_no)"; milestone_code="$($j.milestone_code)"; kind=$(if($j.kind){"$($j.kind)"}else{'note'}); note="$($j.note)"; mentions=$ment; status='open'; doneBy=''; doneAt='' }
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
      $r=[pscustomobject]@{ id=[string]$r.id; created=[string]$r.created; user=[string]$r.user; job_no=[string]$r.job_no; milestone_code=[string]$r.milestone_code; kind=$(if($r.kind){"$($r.kind)"}else{'note'}); note=[string]$r.note; mentions=@($r.mentions|Where-Object{$_}); status=$(if($done){'done'}else{'open'}); doneBy=$(if($done){$me}else{''}); doneAt=$(if($done){(Get-Date).ToString('o')}else{''}) }
    }
    $out += $r
  }
  if(-not $found){ return @{error='not found'} }
  Write-Notes $out
  @{ ok=$true; id=$id; status=$(if($done){'done'}else{'open'}) }
}
# "My Tasks" inbox: assigned = OPEN notes others @-mentioned me on; mine = OPEN notes I authored. Disjoint.
function Handle-MyTasks($me){
  $arr=Read-Notes
  $open=@($arr|Where-Object{ $_ -and (-not $_.status -or "$($_.status)" -eq 'open') })
  $assigned=@($open|Where-Object{ (@($_.mentions) -contains $me) -and ("$($_.user)" -ne $me) }|Sort-Object{"$($_.created)"} -Descending|ForEach-Object{ Note-Proj $_ })
  $mine=@($open|Where-Object{ "$($_.user)" -eq $me }|Sort-Object{"$($_.created)"} -Descending|ForEach-Object{ Note-Proj $_ })
  @{ assigned=$assigned; mine=$mine; assignedOpen=@($assigned).Count }
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
  $rows=@(RunQ $cn "SELECT job_no,station,mode,cargo_type,bound,lane,carrier,cust_code,salesman,pic_user,created_by,last_updated_by,CONVERT(varchar(10),anchor_date,23) anchor_date,CONVERT(varchar(10),etd,23) etd,CONVERT(varchar(10),eta,23) eta,CONVERT(varchar(10),atd,23) atd,worst_light,open_amber,open_red,CONVERT(varchar(10),next_due,23) next_due,auto_done,manual_done FROM dbo.shipment_alerts $w ORDER BY CASE worst_light WHEN 'R' THEN 0 WHEN 'A' THEN 1 ELSE 2 END, next_due" $p)
  $noteJobs=@{}; try{ Read-Notes|Where-Object{ $_ -and (-not $_.status -or "$($_.status)" -eq 'open') }|ForEach-Object{ $noteJobs["$($_.job_no)"]=1 } }catch{}
  @{ lens=$lens; who=$who; rows=@($rows|ForEach-Object{ [pscustomobject]@{ jobNo=[string]$_.job_no; station=[string]$_.station; mode=[string]$_.mode; cargoType=[string]$_.cargo_type; bound=[string]$_.bound; lane=[string]$_.lane; carrier=[string]$_.carrier; custCode=[string]$_.cust_code; salesman=[string]$_.salesman; picUser=[string]$_.pic_user; createdBy=[string]$_.created_by; anchor=[string]$_.anchor_date; etd=[string]$_.etd; eta=[string]$_.eta; atd=[string]$_.atd; worst=[string]$_.worst_light; openAmber=[int]$_.open_amber; openRed=[int]$_.open_red; nextDue=[string]$_.next_due; autoDone=[int]$_.auto_done; manualDone=[int]$_.manual_done; hasNotes=[bool]$noteJobs["$($_.job_no)"] } }) }
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
  $newNote=[pscustomobject]@{ id=[guid]::NewGuid().ToString(); created=(Get-Date).ToString('o'); user=$me; job_no=$job; milestone_code=$code; kind=$kind; note=$txt; mentions=$ment; status='open'; doneBy=''; doneAt='' }
  Write-Notes (@(Read-Notes) + $newNote)
  @{ ok=$true; jobNo=$job; milestone_code=$code; state=$(if($reopen){'pending'}else{'bypassed'}); worst=$worst; openAmber=$amber; openRed=$red; nextDue=$nd }
}

function Config-Payload { @{ appName=$AppName; instanceName=$InstanceName; appSubtitle=$AppSubtitle } }

# ---------------- listener ----------------
$listener=New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://${Hostname}:$Port/")
try{ $listener.Start() }catch{ Write-Host "Failed to bind http://${Hostname}:$Port/ -- $($_.Exception.Message)" -ForegroundColor Red; throw }
Write-Host "$AppName service running at http://${Hostname}:$Port/  (Ctrl+C to stop)" -ForegroundColor Green
Write-Host "Serving from $Root  |  ops DB [$opsDb] on $server" -ForegroundColor DarkGray

while($listener.IsListening){
  $ctx=$listener.GetContext(); $path=$ctx.Request.Url.AbsolutePath
  try{
    $me=Me-User $ctx
    if($path -eq "/api-ops/config"){ Send-Json $ctx (Config-Payload) }
    elseif($path -eq "/api-ops/me"){ Send-Json $ctx @{ user=$me; authOn=$script:AuthOn } }
    elseif($path -eq "/api-ops/notes"){ if($ctx.Request.HttpMethod -eq 'POST'){ Send-Json $ctx (Save-Note $ctx $me) } else { Send-Json $ctx (Handle-NoteList $ctx.Request.QueryString) } }
    elseif($path -eq "/api-ops/note-done"){ Send-Json $ctx (Save-NoteDone $ctx $me) }
    elseif($path -eq "/api-ops/my-tasks"){ Send-Json $ctx (Handle-MyTasks $me) }
    elseif($path -like "/api-ops/*"){
      $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
      try{
        $qs=$ctx.Request.QueryString
        switch($path){
          "/api-ops/roster"          { Send-Json $ctx (Handle-Roster $cn) }
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
