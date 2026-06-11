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
$cfg=[IO.File]::ReadAllText($ConfigPath)|ConvertFrom-Json   # NOT Get-Content: PS5.1 reads BOM-less UTF-8 as ANSI (mojibake)
. (Join-Path $PSScriptRoot "ops-eval.ps1")   # pure helpers only (route/cargo builders for /api-ops/erp-detail)
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
# Testing clock: when ops.config.json sets asOfDate (yyyy-mm-dd), the app treats THAT as "today" for all
# operational date logic (worklist date window, inbound recency, task overdue) so a frozen historical snapshot
# behaves like a live day. Empty/absent = LIVE (real today) — program logic is identical either way.
$AsOfDate= if($cfg.asOfDate -and "$($cfg.asOfDate)".Trim() -match '^\d{4}-\d{2}-\d{2}$'){ "$($cfg.asOfDate)".Trim() }else{ '' }
function Today-Str  { if($AsOfDate){ $AsOfDate } else { (Get-Date).ToString('yyyy-MM-dd') } }
function Today-Date { if($AsOfDate){ [datetime]::ParseExact($AsOfDate,'yyyy-MM-dd',$null) } else { (Get-Date).Date } }
# System identities written by other systems into ERP pic_user (not people): their shipments broadcast to
# EVERYONE's "My work" until a real user takes over (pic_user or last_updated_by becomes a real user).
$SysUsers   =@(@($cfg.systemUsers)        | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
$SysPrefixes=@(@($cfg.systemUserPrefixes) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
$Root=$PSScriptRoot
$ListDir=Join-Path $Root "ops-lists"; if(-not (Test-Path $ListDir)){ New-Item -ItemType Directory -Path $ListDir|Out-Null }
$NotesPath=Join-Path $ListDir "job-notes.json"

# ---------------- identity & auth (lifted from serve-dashboard.ps1) ----------------
# users.json present + non-empty -> real auth (login page, sessions, scope). Absent -> OPEN/demo mode:
# identity from the X-Ops-User header exactly as before — the zero-diff baseline.
$UsersPath=Join-Path $Root "users.json"
function Reload-Users {
  $script:Users=@()
  if(Test-Path $UsersPath){ try{ $script:Users=@(([IO.File]::ReadAllText($UsersPath)|ConvertFrom-Json).users) }catch{ Write-Host "users.json parse error: $($_.Exception.Message)" -ForegroundColor Red } }
  $script:AuthOn = @($script:Users).Count -gt 0
}
Reload-Users
$Sessions=@{}                      # sid -> @{ username; role; admin; displayName; expires } (in-memory, per process)
$script:CurUser=$null              # set per-request after auth; read by the scope builders ($null = unrestricted)
function Hash-Pwd($salt,$pwd){
  $sha=[System.Security.Cryptography.SHA256]::Create()
  ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$salt`:$pwd")) | ForEach-Object { $_.ToString("x2") }) -join ""
}
function New-Salt { -join ((1..16) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }
# In a cross-site iframe the cookie must be SameSite=None; Secure. Set OPS_IFRAME=1 there; localhost keeps Lax.
$IframeCookie = $env:OPS_IFRAME -eq '1'
function Session-Cookie($sid){
  $base="ops_sid=$sid; Path=/; HttpOnly"
  if($IframeCookie){ "$base; SameSite=None; Secure" } else { "$base; SameSite=Lax" }
}
function Me-User($ctx){   # open-mode identity source (header / ?as= / '(open)') — unchanged behavior
  $h="$($ctx.Request.Headers['X-Ops-User'])".Trim()
  if($h){ return $h }
  $q="$($ctx.Request.QueryString['as'])".Trim(); if($q){ return $q }
  '(open)'
}
function Get-OpsUser($name){ $script:Users | Where-Object { $_.username -eq $name } | Select-Object -First 1 }
function Get-OpsSession($ctx){
  if(-not $script:AuthOn){ $u=Me-User $ctx; return @{ username=$u; displayName=$u; role='admin'; admin=$true; open=$true } }
  $c=$ctx.Request.Cookies['ops_sid']; if(-not $c){ return $null }
  $s=$Sessions[$c.Value]; if(-not $s){ return $null }
  if($s.expires -lt (Get-Date)){ $Sessions.Remove($c.Value); return $null }
  $s.expires=(Get-Date).AddHours(12); return $s            # 12h sliding window
}
function Handle-OpsLogin($ctx){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  $u=Get-OpsUser "$($j.username)".Trim()
  if(-not $u -or -not $u.pwdHash -or (Hash-Pwd $u.salt $j.password) -ne $u.pwdHash){ Send-Json $ctx @{ error="Invalid username or password" } 401; return }
  $dn= if("$($u.displayName)".Trim()){ "$($u.displayName)".Trim() } else { $u.username }
  $sid=[Guid]::NewGuid().ToString("N")
  $Sessions[$sid]=@{ username=$u.username; role="$($u.role)"; admin=[bool]$u.admin; displayName=$dn; expires=(Get-Date).AddHours(12) }
  $ctx.Response.Headers["Set-Cookie"]=(Session-Cookie $sid)
  Send-Json $ctx @{ username=$u.username; displayName=$dn; role="$($u.role)"; admin=[bool]$u.admin }
}
function Me-PayloadOps($sess){
  if(-not $script:AuthOn){ return @{ user=$sess.username; username=$sess.username; authOn=$false; today=(Today-Str) } }
  $u=Get-OpsUser $sess.username
  @{ user=$sess.username; username=$sess.username; authOn=$true; today=(Today-Str)
     displayName="$($sess.displayName)"; role="$($sess.role)"; admin=[bool]$sess.admin
     teams=@(@($u.teams)|Where-Object{ "$_".Trim() }); stations=@(@($u.stations)|Where-Object{ "$_".Trim() })
     primaryStation="$($u.primaryStation)".Trim(); access=@(@($u.access)|Where-Object{ "$_".Trim() })
     erpUsers=@(@($u.erpUsers)|Where-Object{ "$_".Trim() }) }
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
# prebuilt-string sibling of Send-Json (same no-store headers) — for the cached /api-ops/ports payload, where
# ConvertTo-Json over ~5k port objects would take seconds on every request (the server is single-threaded).
function Send-JsonRaw($ctx,[string]$json,$code=200){
  $bytes=[Text.Encoding]::UTF8.GetBytes($json)
  $ctx.Response.StatusCode=$code; $ctx.Response.ContentType="application/json; charset=utf-8"
  $ctx.Response.Headers["Access-Control-Allow-Origin"]="*"
  $ctx.Response.Headers["Cache-Control"]="no-store, no-cache, must-revalidate, max-age=0"
  $ctx.Response.Headers["Pragma"]="no-cache"; $ctx.Response.Headers["Expires"]="0"
  $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length); $ctx.Response.OutputStream.Close()
}
function JEsc($s){ "$s".Replace('\','\\').Replace('"','\"').Replace([char]13,' ').Replace([char]10,' ') }
# comma-separated query param -> trimmed, deduped, capped list (multi-select filters)
function Parse-List($s,$max=50){ ,@(@("$s" -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique -First $max) }
# escape user text for a parameterised LIKE (bracket-escape the wildcards; no ESCAPE clause needed)
function Like-Esc($s){ "$s".Replace('[','[[]').Replace('%','[%]').Replace('_','[_]') }
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
  $parsed=$null; try{ $parsed=[IO.File]::ReadAllText($NotesPath)|ConvertFrom-Json }catch{ return @() }
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
  $today=Today-Str
  $dueNow=@($mineT|Where-Object{ $_.remindOn -and "$($_.remindOn)" -le $today }).Count
  @{ assigned=$assignedT; mine=$mineT; assignedOpen=@($assignedT).Count; dueNow=$dueNow; today=$today }
}
# jobs the user is involved in via notes (authored or mentioned) — folded into the worklist "mine" lens
function My-NoteJobs($me){ @(Read-Notes|Where-Object{ $_ -and (("$($_.user)" -eq $me) -or (@($_.mentions) -contains $me)) }|ForEach-Object{"$($_.job_no)"}|Where-Object{$_}|Select-Object -Unique) }

# ---------------- access scope (auth mode; every builder is a no-op when unrestricted/open) ----------------
# NB: these EMIT items (no leading-comma wrap) — every call site collects with @(Cur-...). A `,@()` return
# here + @() at the call site double-wraps: @( <inner array> ) has Count=1 even when the inner list is empty,
# which silently flipped open mode into the auth branch. (Found by the open-mode regression test.)
function Cur-Stations { @($script:CurUser.stations) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } }
function Cur-Pairs    { @($script:CurUser.access)   | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^(Air|Sea)-(Export|Import)$' } }
function Cur-Teams    { @($script:CurUser.teams)    | ForEach-Object { "$_".Trim() } | Where-Object { $_ } }
function Cur-Tier     { if($script:CurUser){ "$($script:CurUser.role)" } else { 'admin' } }
# The login name is the APP identity; the ERP pic_user/created_by values are free text and often different
# (turnover, shared codes like 'corp'). Each credential carries the ERP usernames it owns; "my work" matches
# the WHOLE alias list. Empty/unknown -> the login name itself (open-mode and sensible default).
function Erp-Aliases($username){   # emits items; collect with @(Erp-Aliases ...) at the call site
  $u= if($script:AuthOn){ Get-OpsUser $username } else { $null }
  $al=@(@($u.erpUsers) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
  if($al.Count){ $al } else { @("$username") }
}
function Scope-StationClause($p,$col='station',$prefix='sst'){
  $sts=@(Cur-Stations); if(-not $sts.Count){ return '' }
  $ins=@(); $i=0; foreach($s in $sts){ $ins+="@$prefix$i"; $p["$prefix$i"]=$s; $i++ }
  " AND $col IN ($($ins -join ',')) "
}
function Scope-PairClause($p){
  $prs=@(Cur-Pairs); if(-not $prs.Count){ return '' }
  $ors=@(); $i=0
  foreach($pr in $prs){ $parts="$pr" -split '-'; $ors+="(mode=@scpm$i AND bound=@scpb$i)"; $p["scpm$i"]=$parts[0]; $p["scpb$i"]=$parts[1]; $i++ }
  " AND ($($ors -join ' OR ')) "
}
# Registers the system-identity params once and returns matching expressions for pic_user and
# last_updated_by (reusing the same @su/@sup params in both columns is fine — one AddWithValue each).
function Sys-Exprs($p){
  if(-not ($SysUsers.Count -or $SysPrefixes.Count)){ return $null }
  $ins=@(); $i=0; foreach($v in $SysUsers){ $ins+="@su$i"; $p["su$i"]=$v; $i++ }
  for($j=0; $j -lt $SysPrefixes.Count; $j++){ $p["sup$j"]=(Like-Esc $SysPrefixes[$j])+'%' }
  $mk={ param($col)
    $t=@(); if($ins.Count){ $t+="$col IN ($($ins -join ','))" }
    for($k=0; $k -lt $SysPrefixes.Count; $k++){ $t+="$col LIKE @sup$k" }
    "(" + ($t -join ' OR ') + ")"
  }
  @{ pic=(& $mk 'pic_user'); lub=(& $mk 'last_updated_by') }
}
# Per-job scope check for the by-job endpoints (drawer, erp-detail, milestone-close): out-of-scope rows are
# reported 'not found' — indistinguishable from absent, no existence oracle.
function Test-JobScope($row){
  if(-not $script:CurUser){ return $true }
  $sts=@(Cur-Stations); if($sts.Count -and ($sts -notcontains "$($row.station)")){ return $false }
  $prs=@(Cur-Pairs);    if($prs.Count -and ($prs -notcontains "$($row.mode)-$($row.bound)")){ return $false }
  $true
}

# ---------------- SQL handlers (read only the small pgsops tables) ----------------
function Handle-Roster($cn){
  if($script:AuthOn){
    # auth mode: roster = the app's credential list. Operators see only colleagues sharing >=1 team
    # (plus themselves); admin/manager see everyone. Feeds the teammate picker, @-mentions and Assign.
    $meName="$($script:CurUser.username)"; $myTeams=@(Cur-Teams); $tier=Cur-Tier
    $vis=@($script:Users | Where-Object {
      $_.username -eq $meName -or $tier -in 'admin','manager' -or
      @(@($_.teams) | Where-Object { $myTeams -contains "$_".Trim() }).Count
    })
    return @{ users=@($vis | Sort-Object username | ForEach-Object {
      [pscustomobject]@{ username="$($_.username)"; displayName=$(if("$($_.displayName)".Trim()){"$($_.displayName)".Trim()}else{"$($_.username)"}); email="$($_.email)" } }) }
  }
  $ops=@(RunQ $cn "SELECT DISTINCT pic_user u FROM dbo.shipment_alerts WHERE NULLIF(pic_user,'') IS NOT NULL UNION SELECT DISTINCT created_by FROM dbo.shipment_alerts WHERE NULLIF(created_by,'') IS NOT NULL" @{}|ForEach-Object{"$($_.u)".Trim()})
  $noteUsers=@(); try{ $noteUsers=@(Read-Notes|ForEach-Object{ "$($_.user)"; $_.mentions }|Where-Object{$_ -and "$_".Trim() -ne ''}|ForEach-Object{"$_".Trim()}) }catch{}
  $all=@($ops+$noteUsers|Where-Object{$_ -and $_ -ne '(open)'}|Select-Object -Unique|Sort-Object)
  @{ users=@($all|ForEach-Object{ [pscustomobject]@{ username=$_; displayName=$_; email='' } }) }
}
# company picker: every company that appears (in any role) on an active shipment, with its resolved name.
function Handle-Companies($cn){
  $p=@{}
  $sc=Scope-StationClause $p 'a.station' 'cst'   # auth users only see companies on their stations' shipments
  $rows=@(RunQ $cn "SELECT c.code, c.name FROM dbo.company_dim c WHERE EXISTS (SELECT 1 FROM dbo.shipment_alerts a WHERE a.job_status='active' AND c.code IN (a.cust_code,a.shipper_code,a.consignee_code,a.agent_code,a.ctrl_code) $sc) ORDER BY CASE WHEN NULLIF(c.name,'') IS NULL THEN 1 ELSE 0 END, c.name, c.code" $p)
  @{ companies=@($rows|ForEach-Object{ [pscustomobject]@{ code=[string]$_.code; name=$(if("$($_.name)".Trim()){"$($_.name)".Trim()}else{"$($_.code)"}) } }) }
}
# Port pickers: the FULL port/airport master (pgsops.port_dim, ~5k rows with names/countries) so the client
# can type-ahead by name OR code, plus the distinct ACTIVE pol/pod codes (ranked first by the picker).
# The serialized payload is cached 15 min ($script:PortsJson) and hand-built with a StringBuilder —
# ConvertTo-Json over 5k objects takes seconds in PS 5.1 and this server is single-threaded.
function Send-Ports($ctx,$cn){
  if($script:PortsJson -and $script:PortsAt -and ((Get-Date)-$script:PortsAt).TotalMinutes -lt 15){ Send-JsonRaw $ctx $script:PortsJson; return }
  $all=@(RunQ $cn "SELECT code,module,name,country FROM dbo.port_dim" @{})
  $pol=@(RunQ $cn "SELECT DISTINCT pol code, mode FROM dbo.shipment_alerts WHERE job_status='active' AND NULLIF(pol,'') IS NOT NULL" @{})
  $pod=@(RunQ $cn "SELECT DISTINCT pod code, mode FROM dbo.shipment_alerts WHERE job_status='active' AND NULLIF(pod,'') IS NOT NULL" @{})
  $sb=New-Object System.Text.StringBuilder 524288
  [void]$sb.Append('{"ports":[')
  $first=$true
  foreach($r in $all){
    if(-not $first){ [void]$sb.Append(',') }; $first=$false
    [void]$sb.Append('{"code":"').Append((JEsc $r.code)).Append('","module":"').Append((JEsc $r.module)).Append('","name":"').Append((JEsc $r.name)).Append('","country":"').Append((JEsc $r.country)).Append('"}')
  }
  [void]$sb.Append('],"activePol":[')
  $first=$true
  foreach($r in $pol){ if(-not $first){ [void]$sb.Append(',') }; $first=$false
    [void]$sb.Append('{"code":"').Append((JEsc $r.code)).Append('","mode":"').Append((JEsc $r.mode)).Append('"}') }
  [void]$sb.Append('],"activePod":[')
  $first=$true
  foreach($r in $pod){ if(-not $first){ [void]$sb.Append(',') }; $first=$false
    [void]$sb.Append('{"code":"').Append((JEsc $r.code)).Append('","mode":"').Append((JEsc $r.mode)).Append('"}') }
  [void]$sb.Append(']}')
  $script:PortsJson=$sb.ToString(); $script:PortsAt=Get-Date
  Send-JsonRaw $ctx $script:PortsJson
}
# Inbound cross-station bookings destined to THIS station (reads only the small pgsops feed; no ERP/cross-DB).
# Station = config stationCode, with an optional ?station= override (HQ/testing). Ordered by urgency then ETD.
function Handle-Inbound($cn,$qs){
  $p=@{}
  $userSts=@(Cur-Stations)
  if($userSts.Count){
    # AUTH mode with station scope: pre-arrival is ALWAYS "what is coming to MY station(s)" — independent
    # of the worklist station picker (?station= is ignored on purpose).
    # Import-pair gate: only the modes the user may handle on the Import side; none -> nothing to show.
    $impModes=@(@(Cur-Pairs) | Where-Object { $_ -like '*-Import' } | ForEach-Object { ($_ -split '-')[0] } | Select-Object -Unique)
    if(@(Cur-Pairs).Count -and -not $impModes.Count){ return @{ station=($userSts -join ','); rows=@(); note='no import access' } }
    $ins=@(); $i=0; foreach($s in $userSts){ $ins+="@ist$i"; $p["ist$i"]=$s; $i++ }
    $w=" WHERE f.dest_station IN ($($ins -join ',')) AND f.feed_status<>'void' "
    if($impModes.Count){ $mins=@(); $i=0; foreach($m in $impModes){ $mins+="@ibm$i"; $p["ibm$i"]=$m; $i++ }; $w+=" AND f.mode IN ($($mins -join ',')) " }
    $st=($userSts -join ',')
  } else {
    # open mode / unrestricted user: config stationCode with ?station= override — today's behavior
    $st= if($qs['station']){ "$($qs['station'])".Trim() } else { $StationCode }
    if(-not $st){ return @{ station=''; rows=@(); note='no stationCode configured' } }
    $p['st']=$st; $w=" WHERE f.dest_station=@st AND f.feed_status<>'void' "
  }
  if($qs['mode']){ $w+=" AND f.mode=@md "; $p['md']="$($qs['mode'])" }
  if($qs['from']){ $w+=" AND (f.etd IS NULL OR f.etd>=@from) "; $p['from']="$($qs['from'])" }
  if($qs['to']){   $w+=" AND (f.etd IS NULL OR f.etd<=@to) ";   $p['to']="$($qs['to'])" }
  if($qs['status']){ $w+=" AND f.feed_status=@fs "; $p['fs']="$($qs['status'])" }
  # pre-arrival search: origin office(s), party (shipper/consignee/controlling customer name OR code),
  # POL/POD multi-select, and a free-text ref search (booking/spot/PO/HBL/MBL). All parameterised; the feed
  # table is small + IX_feed_dest seeks dest_station first, so LIKE refinement here is cheap.
  $origins=Parse-List $qs['origin']; if($origins.Count){ $ins=@(); $i=0; foreach($v in $origins){ $ins+="@og$i"; $p["og$i"]=$v; $i++ }; $w+=" AND f.source_station IN ($($ins -join ',')) " }
  $fpols=Parse-List $qs['pol']; if($fpols.Count){ $ins=@(); $i=0; foreach($v in $fpols){ $ins+="@fpl$i"; $p["fpl$i"]=$v; $i++ }; $w+=" AND f.pol IN ($($ins -join ',')) " }
  $fpods=Parse-List $qs['pod']; if($fpods.Count){ $ins=@(); $i=0; foreach($v in $fpods){ $ins+="@fpd$i"; $p["fpd$i"]=$v; $i++ }; $w+=" AND f.pod IN ($($ins -join ',')) " }
  if("$($qs['party'])".Trim()){
    $p['pty']='%'+(Like-Esc "$($qs['party'])".Trim())+'%'
    $w+=" AND (f.shipper_name LIKE @pty OR f.shipper_code LIKE @pty OR f.consignee_name LIKE @pty OR f.consignee_code LIKE @pty OR f.ctrl_name LIKE @pty OR f.ctrl_code LIKE @pty) "
  }
  if("$($qs['q'])".Trim()){
    $p['q']='%'+(Like-Esc "$($qs['q'])".Trim())+'%'
    $w+=" AND (f.booking_no LIKE @q OR f.spot_id LIKE @q OR f.po_no LIKE @q OR f.house_bill LIKE @q OR f.master_bill LIKE @q OR f.container_no LIKE @q) "
  }
  # default recency window: hide stale/departed clutter — keep upcoming departures (ETD today+) and recently-booked
  # new bookings (last 90d). showAll=1 reveals everything. (Operators think in weeks; this defaults to ~13 weeks.)
  if(-not $qs['showAll']){
    $today=(Today-Date).ToString('yyyy-MM-dd'); $cut90=(Today-Date).AddDays(-90).ToString('yyyy-MM-dd')
    $w+=" AND ( (f.etd IS NOT NULL AND f.etd>=@today) OR (f.etd IS NULL AND (f.booking_date IS NULL OR f.booking_date>=@cut90)) ) "
    $p['today']=$today; $p['cut90']=$cut90
  }
  # dedup vs Arrivals: if this origin HBL already exists as a local import job, it's been received -> show it under
  # the arrival worklist, not here. (Origin office + HBL; matched on the HBL the consignee receives.)
  $w+=" AND NOT EXISTS (SELECT 1 FROM dbo.shipment_alerts sa WHERE sa.station=f.dest_station AND sa.bound='Import' AND NULLIF(LTRIM(RTRIM(f.house_bill)),'') IS NOT NULL AND sa.house_bill=f.house_bill) "
  $sel="SELECT source_station,mode,booking_no,dest_station,source_jobn,master_bill,house_bill,shipper_code,shipper_name," +
    "ctrl_code,ctrl_name,agent_code,agent_name,consignee_code,consignee_name,cargo_type,service,container_no,po_no,spot_id,booking_qty,booking_wgt," +
    "pol,pod,carrier,vessel_flight,CONVERT(varchar(10),etd,23) etd," +
    "CONVERT(varchar(10),cargo_ready,23) cargo_ready,incoterm,cargo_summary,CONVERT(varchar(10),booking_date,23) booking_date," +
    "feed_status,assigned_to,linked_job_no,light FROM dbo.inbound_booking_feed f $w " +
    "ORDER BY CASE light WHEN 'R' THEN 0 WHEN 'A' THEN 1 ELSE 2 END, etd, source_station, source_jobn, booking_no"
  $rows=@(RunQ $cn $sel $p)
  @{ station=$st; rows=@($rows|ForEach-Object{ [pscustomobject]@{ sourceStation=[string]$_.source_station; mode=[string]$_.mode; bookingNo=[string]$_.booking_no; destStation=[string]$_.dest_station; sourceJobn=[string]$_.source_jobn; masterBill=[string]$_.master_bill; houseBill=[string]$_.house_bill; shipperCode=[string]$_.shipper_code; shipperName=[string]$_.shipper_name; ctrlCode=[string]$_.ctrl_code; ctrlName=[string]$_.ctrl_name; agentCode=[string]$_.agent_code; agentName=[string]$_.agent_name; consigneeCode=[string]$_.consignee_code; consigneeName=[string]$_.consignee_name; cargoType=[string]$_.cargo_type; service=[string]$_.service; containerNo=[string]$_.container_no; poNo=[string]$_.po_no; spotId=[string]$_.spot_id; bookingQty=[string]$_.booking_qty; bookingWgt=[string]$_.booking_wgt; pol=[string]$_.pol; pod=[string]$_.pod; carrier=[string]$_.carrier; vesselFlight=[string]$_.vessel_flight; etd=[string]$_.etd; cargoReady=[string]$_.cargo_ready; incoterm=[string]$_.incoterm; cargoSummary=[string]$_.cargo_summary; bookingDate=[string]$_.booking_date; feedStatus=[string]$_.feed_status; assignedTo=[string]$_.assigned_to; linkedJobNo=[string]$_.linked_job_no; light=[string]$_.light } }) }
}
# Local assignment of an inbound booking to an operator. Updates the feed and threads a note keyed by a
# synthetic FEED:<src>:<booking_no> job so the assignee's existing My-Tasks inbox/badge lights up (no new infra).
function Save-InboundAssign($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.source_station -or -not $j.mode -or -not $j.booking_no){ return @{error='invalid payload'} }
  # auth scope: the feed row must be destined to one of MY stations, and I need an Import pair for its mode
  if($script:CurUser){
    $fr=@(RunQ $cn "SELECT TOP 1 dest_station,mode FROM dbo.inbound_booking_feed WHERE source_station=@ss AND mode=@md AND booking_no=@bn" @{ ss="$($j.source_station)"; md="$($j.mode)"; bn="$($j.booking_no)" })
    if(-not $fr.Count){ return @{error='not found'} }
    $sts=@(Cur-Stations); if($sts.Count -and ($sts -notcontains "$($fr[0].dest_station)")){ return @{error='not found'} }
    $prs=@(Cur-Pairs);    if($prs.Count -and ($prs -notcontains "$($fr[0].mode)-Import")){ return @{error='not found'} }
  }
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
  # teammate lens (auth): operators may only view users sharing >=1 team; admin/manager see anyone
  if($script:AuthOn -and $lens -eq 'user' -and $who -ne $me -and (Cur-Tier) -notin 'admin','manager'){
    $tu=Get-OpsUser $who; $myTeams=@(Cur-Teams)
    $shared=@(@($tu.teams) | Where-Object { $myTeams -contains "$_".Trim() })
    if(-not $tu -or -not $shared.Count){ return @{ lens=$lens; who=$who; rows=@(); error='not a teammate' } }
  }
  $p=@{}; $w=" WHERE job_status='active' "
  # admin oversight: an admin sees every shipment without owning the ERP pic_user (no erpUser match needed).
  # 'all' lens is unfiltered for everyone; the teammate ('user') lens still narrows to the chosen person.
  if($lens -eq 'all' -or ($lens -ne 'user' -and (Cur-Tier) -eq 'admin')){ }
  else {
    # match the user's WHOLE ERP-alias list (login name != ERP pic_user; see Erp-Aliases)
    $als=@(Erp-Aliases $who)
    $ains=@(); $i=0; foreach($a in $als){ $ains+="@eu$i"; $p["eu$i"]=$a; $i++ }
    $ainl=$ains -join ','
    $clauses=@("pic_user IN ($ainl)","created_by IN ($ainl)","last_updated_by IN ($ainl)")
    $jobs=@(My-NoteJobs $who)   # notes are APP records -> keyed by the login name
    if($jobs.Count){ $ins=@(); $i=0; foreach($j in $jobs){ $ins+="@nj$i"; $p["nj$i"]=$j; $i++ }; $clauses+=("job_no IN ("+($ins -join ',')+")") }
    # system-identity broadcast: rows pic'd by API/EDI*/QUOTATION etc. belong to everyone until a real
    # user takes over (pic reassigned or last update by a real user). Station/pair scope still bounds it.
    $sx=Sys-Exprs $p
    if($sx){ $clauses += "($($sx.pic) AND (NULLIF(last_updated_by,'') IS NULL OR $($sx.lub)))" }
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
  # POL/POD accept comma-separated multi-select lists (chips UI) -> parameterised IN
  $pols=Parse-List $qs['pol']; if($pols.Count){ $ins=@(); $i=0; foreach($v in $pols){ $ins+="@pol$i"; $p["pol$i"]=$v; $i++ }; $w+=" AND pol IN ($($ins -join ',')) " }
  $pods=Parse-List $qs['pod']; if($pods.Count){ $ins=@(); $i=0; foreach($v in $pods){ $ins+="@pod$i"; $p["pod$i"]=$v; $i++ }; $w+=" AND pod IN ($($ins -join ',')) " }
  # auth-mode access scope (stations + mode-bound pairs) — applies to EVERY lens incl. 'all'
  $w += Scope-StationClause $p
  $w += Scope-PairClause $p
  $sel="SELECT job_no,station,mode,cargo_type,bound,lane,carrier,cust_code,salesman,pic_user,created_by,last_updated_by," +
    "CONVERT(varchar(10),anchor_date,23) anchor_date,CONVERT(varchar(10),etd,23) etd,CONVERT(varchar(10),eta,23) eta," +
    "CONVERT(varchar(10),atd,23) atd,CONVERT(varchar(10),ata,23) ata,worst_light,open_amber,open_red," +
    "CONVERT(varchar(10),next_due,23) next_due,auto_done,manual_done,consignee_name,shipper_name,cust_contact,cust_phone," +
    "cust_email,vessel_voyage,container_summary,container_count,total_weight,total_cbm,arrival_state," +
    "house_bill,master_bill,incoterm,cust_ref,container_no,liner_so,CONVERT(varchar(10),cargo_ready,23) cargo_ready," +
    "shipper_code,consignee_code,agent_code,ctrl_code," +
    "commodity,sono,route_summary,CONVERT(varchar(10),available_date,23) available_date," +
    "CONVERT(varchar(10),eta_delivery,23) eta_delivery,CONVERT(varchar(10),goods_delivery,23) goods_delivery," +
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
    else {
      # keep the LATEST chat note's text + milestone so the 💬 tooltip can show WHAT was written, not just "has a note"
      $cur=$chatJobs[$jk]
      if(-not ($cur -is [hashtable]) -or "$($nt.created)" -gt "$($cur.created)"){
        $txt="$($nt.note)"; if($txt.Length -gt 160){ $txt=$txt.Substring(0,160)+'...' }
        $chatJobs[$jk]=@{ text=$txt; code="$($nt.milestone_code)"; created="$($nt.created)" }
      }
    }
  } }catch{}
  # milestone code -> human name (keyed mode|bound|code; a code like A3 means different things per bound)
  $msName=@{}; try{ foreach($md in @(RunQ $cn "SELECT mode,bound,milestone_code,name FROM dbo.milestone_def")){ $msName[("$($md.mode)|$($md.bound)|$($md.milestone_code)").ToUpper()]=("$($md.name)").Trim() } }catch{}
  @{ lens=$lens; who=$who; rows=@($rows|ForEach-Object{ [pscustomobject]@{ jobNo=[string]$_.job_no; station=[string]$_.station; mode=[string]$_.mode; cargoType=[string]$_.cargo_type; bound=[string]$_.bound; lane=[string]$_.lane; carrier=[string]$_.carrier; custCode=[string]$_.cust_code; salesman=[string]$_.salesman; picUser=[string]$_.pic_user; createdBy=[string]$_.created_by; anchor=[string]$_.anchor_date; etd=[string]$_.etd; eta=[string]$_.eta; atd=[string]$_.atd; ata=[string]$_.ata; worst=[string]$_.worst_light; openAmber=[int]$_.open_amber; openRed=[int]$_.open_red; nextDue=[string]$_.next_due; autoDone=[int]$_.auto_done; manualDone=[int]$_.manual_done; consigneeName=[string]$_.consignee_name; shipperName=[string]$_.shipper_name; custContact=[string]$_.cust_contact; custPhone=[string]$_.cust_phone; custEmail=[string]$_.cust_email; vesselVoyage=[string]$_.vessel_voyage; containerSummary=[string]$_.container_summary; containerCount=[int]$_.container_count; totalWeight=[string]$_.total_weight; totalCbm=[string]$_.total_cbm; arrivalState=[string]$_.arrival_state; houseBill=[string]$_.house_bill; masterBill=[string]$_.master_bill; incoterm=[string]$_.incoterm; custRef=[string]$_.cust_ref; containerNo=[string]$_.container_no; linerSo=[string]$_.liner_so; cargoReady=[string]$_.cargo_ready; sortKey=[string]$_.sort_key; shipperCode=[string]$_.shipper_code; consigneeCode=[string]$_.consignee_code; agentCode=[string]$_.agent_code; ctrlCode=[string]$_.ctrl_code; commodity=[string]$_.commodity; sono=[string]$_.sono; routeSummary=[string]$_.route_summary; availableDate=[string]$_.available_date; etaDelivery=[string]$_.eta_delivery; goodsDelivery=[string]$_.goods_delivery; hasNotes=[bool]$chatJobs["$($_.job_no)"]; noteText=$(if($chatJobs["$($_.job_no)"]){[string]$chatJobs["$($_.job_no)"].text}else{''}); noteMilestone=$(if($chatJobs["$($_.job_no)"]){[string]$chatJobs["$($_.job_no)"].code}else{''}); hasUpdate=[bool]$updJobs["$($_.job_no)"]; updateMilestone=$(if($updJobs["$($_.job_no)"]){[string]$updJobs["$($_.job_no)"].code}else{''}); updateMilestoneName=$(if($updJobs["$($_.job_no)"]){ $uc=[string]$updJobs["$($_.job_no)"].code; [string]$msName[("$($_.mode)|$($_.bound)|$uc").ToUpper()] }else{''}) } }) }
}
function Handle-Shipment($cn,$qs){
  $job="$($qs['job'])".Trim(); if(-not $job){ return @{error='job required'} }
  $row=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound,milestone_checklist,route_json,detail_json,commodity,sono,route_summary,CONVERT(varchar(10),available_date,23) available_date,CONVERT(varchar(10),eta_delivery,23) eta_delivery,CONVERT(varchar(10),goods_delivery,23) goods_delivery,CONVERT(varchar(16),updated_at,120) updated_at FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $row.Count){ return @{error='not found'} }
  if(-not (Test-JobScope $row[0])){ return @{error='not found'} }
  $chk=$null; try{ $chk=("$($row[0].milestone_checklist)")|ConvertFrom-Json }catch{}
  # PS 5.1: ConvertFrom-Json emits a JSON array as ONE pipeline object — assign first, then enumerate,
  # or @(...) wraps the whole array as a single element and the client sees [[...]] instead of [...].
  $route=@(); try{ if("$($row[0].route_json)".Trim()){ $parsed=("$($row[0].route_json)")|ConvertFrom-Json; $route=@($parsed|Where-Object{$_}) } }catch{}
  $detail=$null; try{ if("$($row[0].detail_json)".Trim()){ $detail=("$($row[0].detail_json)")|ConvertFrom-Json } }catch{}
  $notes=(Handle-NoteList @{ job=$job }).records
  $extra=@{ commodity=[string]$row[0].commodity; sono=[string]$row[0].sono; routeSummary=[string]$row[0].route_summary;
            availableDate=[string]$row[0].available_date; etaDelivery=[string]$row[0].eta_delivery;
            goodsDelivery=[string]$row[0].goods_delivery; snapshotAt=[string]$row[0].updated_at }
  @{ jobNo=$job; checklist=$chk; notes=$notes; route=$route; detail=$detail; extra=$extra }
}

# ---------------- /api-ops/erp-detail — the ONE sanctioned ERP-on-request-path exception ----------------
# Explicit, user-clicked deep-dive: a single keyed header SELECT (PK ref / indexed jobn) + a TOP-10 child read
# on the station ERP, bounded by Connect Timeout=5 / CommandTimeout=8 so the single-threaded listener can't be
# held long. Display-only — nothing is written back (the next listener pass refreshes the pgsops snapshot).
$SrcAuthClause= if($auth -eq 'sql'){"User ID=$user;Password=$password"}else{"Integrated Security=True"}
$DbByStation=@{}; foreach($s in @($cfg.stations)){ if($s -and $s.code -and $s.database){ $DbByStation["$($s.code)".Trim().ToUpper()]="$($s.database)".Trim() } }
$script:ErpCols=@{}   # per (db|table) Filter-Cols cache so repeat clicks skip INFORMATION_SCHEMA
$SeaDetailCols="jobn,ref,blno,mobl,bound,routing,pol,pod,deli,dest,pol_name,pod_name,deli_name,dest_name,vessel_1,voyage_1,vessel_2,voyage_2,departure1,departure2,arrival1,arrival1d,arrival2,arrival2d,arrival3,available_date,eta_delivery,goods_delivery,cargoready,spotid,sono,t_book_qty,t_book_wgt,t_book_cbm,t_rece_qty,t_rece_wgt,t_rece_cbm,remark"
$AirDetailCols="jobn,ref,hawb,mawb,bound,routing,booking,po_no,pol,pod,to1,to3,dest,deli,pol_name,pod_name,to1_name,to3_name,dest_name,deli_name,flight1,flight2,flight3,f_date1,f_date2,f_date3,f_time1,f_time2,f_time3,fa_date1,fa_date2,fa_date3,rout_by_1,atd_date,ata_date,cargoready,goods_delivery,t_book_qty,t_book_wgt,t_book_cwt,t_book_cbm,t_rece_qty,t_rece_cbm,ttl_cwt,remark,special_remark"
function Get-ErpCols($srcCn,$db,$table,$wantCsv,[string[]]$ntextCols){
  $key="$db|$table"
  if($script:ErpCols[$key]){ return $script:ErpCols[$key] }
  $have=@{}; foreach($r in @(RunQ $srcCn "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t" @{ t=$table } 8)){ $have["$($r.COLUMN_NAME)".ToLower()]=1 }
  $keep=@(@($wantCsv -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $have[$_.ToLower()] })
  $csv=(@($keep | ForEach-Object { if($ntextCols -contains $_){ "CONVERT(nvarchar(4000),$_) AS $_" } else { $_ } }) -join ',')
  $script:ErpCols[$key]=$csv; $csv
}
function Handle-ErpDetail($cn,$qs){
  $job="$($qs['job'])".Trim(); if(-not $job){ return @{error='job required'} }
  $al=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound,erp_ref,vessel_voyage FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $al.Count){ return @{error='not found'} }
  if(-not (Test-JobScope $al[0])){ return @{error='not found'} }
  $a=$al[0]; $db=$DbByStation["$($a.station)".Trim().ToUpper()]
  if(-not $db){ return @{error="station '$($a.station)' has no ERP database mapped in config stations[]"} }
  $isAir=("$($a.mode)" -eq 'Air')
  $srcCn=New-Object System.Data.SqlClient.SqlConnection "Server=$server;Database=$db;$SrcAuthClause;TrustServerCertificate=True;Connect Timeout=5;Packet Size=512"
  try {
    $srcCn.Open()
    $tbl= if($isAir){'awbhead'}else{'blhead'}
    $cols=Get-ErpCols $srcCn $db $tbl $(if($isAir){$AirDetailCols}else{$SeaDetailCols}) @('remark','special_remark')
    if(-not $cols){ return @{error="$db.$tbl has none of the detail columns"} }
    # NB: assign @(RunQ...) INSIDE each branch — an `$x = if(){ @(...) }` assignment re-enumerates the array,
    # collapsing a 1-row result to a bare PSCustomObject whose .Count is $null in PS 5.1 (false "not found").
    $key="$($a.erp_ref)".Trim()
    if($key){ $hdr=@(RunQ $srcCn "SELECT TOP 1 $cols FROM dbo.$tbl WHERE ref=@k" @{ k=$key } 8) }
    else { $hdr=@(RunQ $srcCn "SELECT TOP 1 $cols FROM dbo.$tbl WHERE jobn=@k ORDER BY ref DESC" @{ k=$job } 8) }
    if(-not $hdr.Count){ return @{error="shipment not found in the ERP (may have been archived) [$db.$tbl $(if($key){"ref=$key"}else{"jobn=$job"})]"} }
    $b=$hdr[0]
    $itemTbl= if($isAir){'awbdetl'}else{'blitem'}
    $items=@(); try{
      $items=@(RunQ $srcCn "SELECT TOP 10 item_seq, CONVERT(nvarchar(400),good_desc1) AS good_desc1, CONVERT(nvarchar(400),good_desc2) AS good_desc2 FROM dbo.$itemTbl WHERE blh=@r ORDER BY item_seq" @{ r=$b.ref } 8)
    }catch{}
    $descField= if($isAir){'good_desc2'}else{'good_desc1'}
    $descs=@(); foreach($it in $items){ $dv=("$($it.$descField)").Trim(); if($dv -and $descs -notcontains $dv){ $descs+=$dv } }
    $bound= switch("$($b.bound)"){ 'O'{'Export'} 'I'{'Import'} default{"$($a.bound)"} }
    $routePts= if($isAir){ Get-AirRoutePoints $b } else { Get-SeaRoutePoints $b $bound "$($a.vessel_voyage)" }
    $cargo=Get-CargoBlock $b $(if($isAir){'Air'}else{'Sea'})
    $remark=("$($b.remark)").Trim(); $spec= if($isAir){ ("$($b.special_remark)").Trim() } else { '' }
    function _d10($x){ if($null -eq $x -or "$x" -eq ''){ $null } else { ([datetime]$x).ToString('yyyy-MM-dd') } }
    @{ jobNo=$job; live=$true; fetchedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm')
       remark=$(if($remark){$remark}else{$null}); specialRemark=$(if($spec){$spec}else{$null})
       commodity=@($descs | Select-Object -First 5); route=@($routePts); cargo=$cargo
       cargoReady=(_d10 $b.cargoready); availableDate=(_d10 $b.available_date)
       etaDelivery=(_d10 $b.eta_delivery); goodsDelivery=(_d10 $b.goods_delivery) }
  } catch {
    @{ error="ERP lookup failed: $($_.Exception.Message)" }
  } finally { try{ $srcCn.Close() }catch{} }
}
# Manual Tick & Confirm on a milestone: overlay bypass/reopen onto the stored checklist, recompute the rollup,
# persist, and drop a note (so it threads + can @-mention). Pure JSON — no ERP touched.
function Save-MilestoneClose($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.job_no -or -not $j.milestone_code){ return @{error='invalid payload'} }
  $job="$($j.job_no)"; $code="$($j.milestone_code)"; $reopen=($j.done -eq $false)
  $row=@(RunQ $cn "SELECT TOP 1 milestone_checklist,station,mode,bound FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $row.Count){ return @{error='not found'} }
  if(-not (Test-JobScope $row[0])){ return @{error='not found'} }
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

# ---------------- admin: user management (admin-gated; writes users.json; lifted from serve-dashboard) ----------------
$AuditPath = Join-Path $Root "admin-audit.log"
function Audit($who,$msg){
  try { [System.IO.File]::AppendAllText($AuditPath, ("{0}`t{1}`t{2}`r`n" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $who, $msg), (New-Object System.Text.UTF8Encoding($false))) } catch {}
}
# Serialize each user record INDIVIDUALLY (Write-Notes pattern) so PS 5.1 never mangles the users array.
function Save-Users {
  $parts=@($script:Users | ForEach-Object { $_ | ConvertTo-Json -Depth 6 -Compress })
  $json='{"_comment":"Control Tower logins. Gitignored. Manage with admin-ops.html. erpUsers = the ERP pic/created-by names this person owns (login name used when empty). Empty stations[]/access[] = unrestricted.","users":[' + ($parts -join ',') + ']}'
  [System.IO.File]::WriteAllText($UsersPath, $json, (New-Object System.Text.UTF8Encoding($false)))
  Reload-Users
}
$AccessPairs=@('Air-Export','Air-Import','Sea-Export','Sea-Import')
function Tag-List($a){ @($a) | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique }   # emits items; collect with @(Tag-List ...)
function Handle-OpsAdmin($ctx,$sess,$path){
  if(-not $sess.admin){ Send-Json $ctx @{ error="Admin only" } 403; return }
  $method=$ctx.Request.HttpMethod
  switch($path){
    "/api-ops/admin/users" {
      if($method -eq "POST"){
        $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
        $un="$($j.username)".Trim()
        if($un -notmatch '^[A-Za-z0-9_.-]+$'){ Send-Json $ctx @{ error="Invalid username (use letters, digits, . _ -)" } 400; return }
        $role="$($j.role)".Trim().ToLower()
        if($role -notin 'admin','manager','operator'){ Send-Json $ctx @{ error="Role must be admin, manager or operator" } 400; return }
        $em="$($j.email)".Trim()
        if($em -and ($script:Users | Where-Object { $_.username -ne $un -and "$($_.email)".Trim().ToLower() -eq $em.ToLower() })){ Send-Json $ctx @{ error="Email already assigned to another user" } 400; return }
        $isAdmin=[bool]$j.admin
        if($un -eq $sess.username -and -not $isAdmin){ Send-Json $ctx @{ error="You cannot remove your own admin rights" } 400; return }
        $stations=@(Tag-List $j.stations); $validSts=@($StationList | ForEach-Object { $_.code })
        $badSts=@($stations | Where-Object { $validSts -notcontains $_ })
        if($badSts.Count){ Send-Json $ctx @{ error="Unknown station(s): $($badSts -join ', ')" } 400; return }
        $prim="$($j.primaryStation)".Trim()
        if($stations.Count){ if(-not $prim -or ($stations -notcontains $prim)){ $prim=$stations[0] } } else { $prim='' }
        $access=@(Tag-List $j.access); $badAcc=@($access | Where-Object { $AccessPairs -notcontains $_ })
        if($badAcc.Count){ Send-Json $ctx @{ error="Unknown access pair(s): $($badAcc -join ', ')" } 400; return }
        $teams=@(Tag-List $j.teams); $erpUsers=@(Tag-List $j.erpUsers)
        $dn="$($j.displayName)".Trim()
        $users=[System.Collections.ArrayList]@($script:Users)
        $idx=-1; for($i=0;$i -lt $users.Count;$i++){ if($users[$i].username -eq $un){ $idx=$i; break } }
        if($idx -ge 0){
          $rec=$users[$idx]
          $new=[ordered]@{ username=$un; displayName=$dn; email=$em; salt=$rec.salt; pwdHash=$rec.pwdHash; role=$role; admin=$isAdmin; teams=$teams; stations=$stations; primaryStation=$prim; access=$access; erpUsers=$erpUsers }
          if($j.password){ $salt=New-Salt; $new.salt=$salt; $new.pwdHash=(Hash-Pwd $salt $j.password) }
          $users[$idx]=[pscustomobject]$new
          Audit $sess.username "update user $un (role=$role, admin=$isAdmin, stations=$($stations -join '/'), primary=$prim, access=$($access -join '/'), erp=$($erpUsers -join '/')$(if($j.password){', password reset'}))"
        } else {
          if(-not $j.password){ Send-Json $ctx @{ error="A password is required for a new user" } 400; return }
          $salt=New-Salt; $hash=(Hash-Pwd $salt $j.password)
          $new=[ordered]@{ username=$un; displayName=$dn; email=$em; salt=$salt; pwdHash=$hash; role=$role; admin=$isAdmin; teams=$teams; stations=$stations; primaryStation=$prim; access=$access; erpUsers=$erpUsers }
          [void]$users.Add([pscustomobject]$new)
          Audit $sess.username "create user $un (role=$role, admin=$isAdmin, stations=$($stations -join '/'), primary=$prim, access=$($access -join '/'), erp=$($erpUsers -join '/'))"
        }
        $script:Users=@($users); Save-Users
        Send-Json $ctx @{ ok=$true }
      } else {
        Send-Json $ctx @{ users=@($script:Users | ForEach-Object { @{
          username="$($_.username)"; displayName="$($_.displayName)"; email="$($_.email)"; role="$($_.role)"; admin=[bool]$_.admin
          teams=@(Tag-List $_.teams); stations=@(Tag-List $_.stations); primaryStation="$($_.primaryStation)"
          access=@(Tag-List $_.access); erpUsers=@(Tag-List $_.erpUsers); hasPwd=[bool]"$($_.pwdHash)" } }) }
      }
    }
    "/api-ops/admin/user-delete" {
      $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
      $un="$($j.username)".Trim()
      if($un -eq $sess.username){ Send-Json $ctx @{ error="You cannot delete your own account" } 400; return }
      $users=[System.Collections.ArrayList]@($script:Users)
      $idx=-1; for($i=0;$i -lt $users.Count;$i++){ if($users[$i].username -eq $un){ $idx=$i; break } }
      if($idx -lt 0){ Send-Json $ctx @{ error="No such user" } 404; return }
      $users.RemoveAt($idx); $script:Users=@($users); Save-Users; Audit $sess.username "delete user $un"
      Send-Json $ctx @{ ok=$true }
    }
    # ---- milestone & alert config (milestone_def in pgsops; the only admin endpoints that need SQL).
    # Edits drive the traffic lights every operator sees; they apply to a shipment at its NEXT evaluation
    # run (listener / seed-alerts), not retroactively.
    "/api-ops/admin/milestones" {
      $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
      try{
        if($method -eq "POST"){
          $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
          $code="$($j.code)".Trim().ToUpper(); $bound="$($j.bound)".Trim()
          if($code -notmatch '^[A-Z0-9]{1,12}$'){ Send-Json $ctx @{ error="Code: 1-12 letters/digits (e.g. M5, A3)" } 400; return }
          if($bound -notin 'Export','Import'){ Send-Json $ctx @{ error="Bound must be Export or Import" } 400; return }
          $mmode="$($j.mode)".Trim(); if($mmode -notin 'Sea','Air','Both'){ Send-Json $ctx @{ error="Mode must be Sea, Air or Both" } 400; return }
          $name="$($j.name)".Trim(); if(-not $name -or $name.Length -gt 60){ Send-Json $ctx @{ error="Name required (max 60 chars)" } 400; return }
          $seq=0; if(-not [int]::TryParse("$($j.seq)",[ref]$seq) -or $seq -lt 1){ Send-Json $ctx @{ error="Seq must be a positive number" } 400; return }
          $anchor="$($j.anchor)".Trim(); if($anchor -notin 'booking','etd','atd','eta','delivery'){ Send-Json $ctx @{ error="Phase anchor must be booking, etd, atd, eta or delivery" } 400; return }
          $slatype="$($j.slaType)".Trim(); if($slatype -notin 'baseline','fixed','none'){ Send-Json $ctx @{ error="Alert timing must be baseline, fixed or none" } 400; return }
          $offval=$null;$offunit=$null;$dir=$null;$slaanchor=$null
          if($slatype -eq 'fixed'){
            $ov=0; if(-not [int]::TryParse("$($j.slaOffsetVal)",[ref]$ov) -or $ov -lt 1){ Send-Json $ctx @{ error="Fixed alert needs an offset (e.g. 3)" } 400; return }
            $offval=$ov
            $offunit="$($j.slaOffsetUnit)".Trim(); if($offunit -notin 'day','hour'){ Send-Json $ctx @{ error="Offset unit must be day or hour" } 400; return }
            $dir="$($j.slaDirection)".Trim(); if($dir -notin 'before','after'){ Send-Json $ctx @{ error="Direction must be before or after" } 400; return }
            $slaanchor="$($j.slaAnchor)".Trim(); if($slaanchor -notmatch '^[A-Za-z0-9_]{1,12}$'){ Send-Json $ctx @{ error="Fixed alert needs an anchor field (e.g. atd_date)" } 400; return }
          }
          # rules: JSON {op:'AND'|'OR', conds:[...]} — blank falls back to safe defaults (always qualify / close on evidence)
          $qual="$($j.qualifyRule)"; if(-not $qual.Trim()){ $qual='{"op":"AND","conds":[]}' }
          $comp="$($j.completeRule)"; if(-not $comp.Trim()){ $comp='{"op":"OR","conds":[{"kind":"evidence"}]}' }
          foreach($pair in @(,@('Qualify rule',$qual)) + @(,@('Complete rule',$comp))){
            try{ $r=$pair[1]|ConvertFrom-Json; if("$($r.op)" -notin 'AND','OR'){ throw [Exception]"op must be AND or OR" } }
            catch{ Send-Json $ctx @{ error="$($pair[0]): invalid rule JSON - $($_.Exception.Message)" } 400; return }
          }
          $active=if($null -eq $j.active){1}else{[int][bool]$j.active}
          RunQ $cn @"
MERGE dbo.milestone_def AS t USING (SELECT @code code,@bound bound) s ON t.milestone_code=s.code AND t.bound=s.bound
WHEN MATCHED THEN UPDATE SET name=@name,seq=@seq,phase_anchor=@anchor,qualify_rule=@qual,complete_rule=@comp,
  sla_type=@slatype,sla_offset_val=@offval,sla_offset_unit=@offunit,sla_direction=@dir,sla_anchor=@slaanchor,mode=@mmode,active=@active
WHEN NOT MATCHED THEN INSERT(milestone_code,bound,name,seq,phase_anchor,qualify_rule,complete_rule,sla_type,sla_offset_val,sla_offset_unit,sla_direction,sla_anchor,mode,active)
  VALUES(@code,@bound,@name,@seq,@anchor,@qual,@comp,@slatype,@offval,@offunit,@dir,@slaanchor,@mmode,@active);
"@ @{ code=$code;bound=$bound;name=$name;seq=$seq;anchor=$anchor;qual=$qual;comp=$comp;slatype=$slatype;offval=$offval;offunit=$offunit;dir=$dir;slaanchor=$slaanchor;mmode=$mmode;active=$active } | Out-Null
          Audit $sess.username "upsert milestone $code/$bound (mode=$mmode, sla=$slatype, active=$active)"
          Send-Json $ctx @{ ok=$true }
        } else {
          $rows=@(RunQ $cn "SELECT milestone_code,bound,name,seq,phase_anchor,qualify_rule,complete_rule,sla_type,sla_offset_val,sla_offset_unit,sla_direction,sla_anchor,mode,active FROM dbo.milestone_def ORDER BY mode,bound,seq" @{})
          Send-Json $ctx @{ milestones=$rows }
        }
      } finally { $cn.Close() }
    }
    "/api-ops/admin/milestone-delete" {
      $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
      $code="$($j.code)".Trim(); $bound="$($j.bound)".Trim()
      if(-not $code -or -not $bound){ Send-Json $ctx @{ error="code + bound required" } 400; return }
      $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
      try{ RunQ $cn "DELETE FROM dbo.milestone_def WHERE milestone_code=@code AND bound=@bound" @{ code=$code; bound=$bound } | Out-Null } finally { $cn.Close() }
      Audit $sess.username "delete milestone $code/$bound"
      Send-Json $ctx @{ ok=$true }
    }
    default { Send-Json $ctx @{ error="unknown admin endpoint" } 404 }
  }
}

# ---------------- listener ----------------
$listener=New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://${Hostname}:$Port/")
try{ $listener.Start() }catch{ Write-Host "Failed to bind http://${Hostname}:$Port/ -- $($_.Exception.Message)" -ForegroundColor Red; throw }
Write-Host "$AppName service running at http://${Hostname}:$Port/  (Ctrl+C to stop)" -ForegroundColor Green
Write-Host "Serving from $Root  |  ops DB [$opsDb] on $opsServer" -ForegroundColor DarkGray

while($listener.IsListening){
  $ctx=$listener.GetContext(); $path=$ctx.Request.Url.AbsolutePath
  try{
    # SQL-free PUBLIC endpoints first (no session needed): login / logout / config
    if($path -eq "/api-ops/login"){ Handle-OpsLogin $ctx }
    elseif($path -eq "/api-ops/logout"){
      $c=$ctx.Request.Cookies['ops_sid']; if($c -and $Sessions[$c.Value]){ $Sessions.Remove($c.Value) }
      $ctx.Response.Headers["Set-Cookie"]="ops_sid=; Path=/; Max-Age=0"
      Send-Json $ctx @{ ok=$true }
    }
    elseif($path -eq "/api-ops/config"){ Send-Json $ctx (Config-Payload) }
    elseif($path -like "/api-ops/*"){
      # everything else requires a session in auth mode (open mode: pseudo-session from the header identity)
      $sess=Get-OpsSession $ctx
      if(-not $sess){ Send-Json $ctx @{ error="Authentication required" } 401 }
      else {
        $script:CurUser=$null; $ok=$true
        if($script:AuthOn){
          $cu=Get-OpsUser $sess.username   # live re-read: admin edits apply now; deleted user -> kill session
          if(-not $cu){
            $c=$ctx.Request.Cookies['ops_sid']; if($c -and $Sessions[$c.Value]){ $Sessions.Remove($c.Value) }
            Send-Json $ctx @{ error="Authentication required" } 401; $ok=$false
          } else { $script:CurUser=$cu }
        }
        if($ok){
          $me=$sess.username
          if($path -eq "/api-ops/me"){ Send-Json $ctx (Me-PayloadOps $sess) }
          elseif($path -eq "/api-ops/notes"){ if($ctx.Request.HttpMethod -eq 'POST'){ Send-Json $ctx (Save-Note $ctx $me) } else { Send-Json $ctx (Handle-NoteList $ctx.Request.QueryString) } }
          elseif($path -eq "/api-ops/note-done"){ Send-Json $ctx (Save-NoteDone $ctx $me) }
          elseif($path -like "/api-ops/admin/*"){ Handle-OpsAdmin $ctx $sess $path }
          else {
            $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
            try{
              $qs=$ctx.Request.QueryString
              switch($path){
                "/api-ops/roster"          { Send-Json $ctx (Handle-Roster $cn) }
                "/api-ops/companies"       { Send-Json $ctx (Handle-Companies $cn) }
                "/api-ops/ports"           { Send-Ports $ctx $cn }
                "/api-ops/erp-detail"      { Send-Json $ctx (Handle-ErpDetail $cn $qs) }
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
        }
      }
    }
    else {
      $rel= if($path -eq "/"){ "index.html" } else { $path.TrimStart("/") }
      if($rel -match "\.\."){ $ctx.Response.StatusCode=400; $ctx.Response.OutputStream.Close() }
      else { Send-File $ctx (Join-Path $Root $rel) }
    }
  } catch { try{ Send-Json $ctx @{ error=$_.Exception.Message } 500 }catch{} }
}
