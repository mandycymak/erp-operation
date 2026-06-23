<#
  serve-ops.ps1  — Control Tower web service (HttpListener + JSON API + static files).
  Reads ONLY the small erpops tables (shipment_alerts) — never the ERP on a request path.
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
. (Join-Path $PSScriptRoot "erp-doc-api.ps1") # ERP document-issue client (mock mode until the real API is mapped)
function EnvOrConfig($n,$v){ $e=[Environment]::GetEnvironmentVariable($n); if($e -and $e.Trim()){$e}else{$v} }
$server=EnvOrConfig "DB_SERVER" $cfg.server; $auth=EnvOrConfig "DB_AUTH" $cfg.auth
$user=EnvOrConfig "DB_USER" $cfg.user; $password=EnvOrConfig "DB_PASSWORD" $cfg.password; $opsDb=EnvOrConfig "DB_OPS_DB" $cfg.opsDb
if($Port -le 0){ if($env:DB_PORT -and $env:DB_PORT.Trim()){ $Port=[int]$env:DB_PORT } else { $Port=[int]$cfg.port } }
# the web service reads ONLY erpops, so it connects to the OPS server (may differ from the source ERP; falls back to source)
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
# SWIVEL L!NK (OAuth code flow) - the seam for embedding this app in SWIVEL L!NK. ENABLED only when the redeem
# (profile) URL is set: env SWIVEL_OAUTH_PROFILE_URL, else config swivelLink.profileUrl. There is NO
# client_id/secret - the one-time code authenticates itself; xSystem (env SWIVEL_OAUTH_XSYSTEM) is sent as the
# x-system header only for a uat-stage L!NK. autoProvision (default true) creates a default-role user on first
# L!NK sign-in when the profile email matches nobody. Inert (endpoint returns "not enabled") until configured.
$LinkProfileUrl=EnvOrConfig "SWIVEL_OAUTH_PROFILE_URL" $cfg.swivelLink.profileUrl
$LinkXSystem   =EnvOrConfig "SWIVEL_OAUTH_XSYSTEM"     $cfg.swivelLink.xSystem
$LinkEnabled   =[bool]("$LinkProfileUrl".Trim())
$LinkAutoProvision = if($null -ne $cfg.swivelLink.autoProvision){ [bool]$cfg.swivelLink.autoProvision } else { $true }
$LinkDefaultRole = if("$($cfg.swivelLink.defaultRole)".Trim()){ "$($cfg.swivelLink.defaultRole)".Trim().ToLower() } else { 'operator' }
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
# Email is the LOGIN / federation key (local password login AND SWIVEL L!NK both match on it). Case-insensitive;
# username stays the internal identity (sessions/notes/@-mentions/scope are unchanged). Returns $null if absent.
function Get-OpsUserByEmail($email){
  $e="$email".Trim().ToLower(); if(-not $e){ return $null }
  $script:Users | Where-Object { "$($_.email)".Trim().ToLower() -eq $e } | Select-Object -First 1
}
function Get-OpsSession($ctx){
  if(-not $script:AuthOn){ $u=Me-User $ctx; return @{ username=$u; displayName=$u; role='admin'; admin=$true; open=$true } }
  $c=$ctx.Request.Cookies['ops_sid']; if(-not $c){ return $null }
  $s=$Sessions[$c.Value]; if(-not $s){ return $null }
  if($s.expires -lt (Get-Date)){ $Sessions.Remove($c.Value); return $null }
  $s.expires=(Get-Date).AddHours(12); return $s            # 12h sliding window
}
# THE SESSION SEAM: build a session + set the cookie for an authenticated user record, whatever proved identity
# (local password or SWIVEL L!NK OAuth). Sessions key on the internal username; returns the public payload.
function New-OpsSession($ctx,$u){
  $dn= if("$($u.displayName)".Trim()){ "$($u.displayName)".Trim() } else { $u.username }
  $sid=[Guid]::NewGuid().ToString("N")
  $Sessions[$sid]=@{ username=$u.username; role="$($u.role)"; admin=[bool]$u.admin; displayName=$dn; expires=(Get-Date).AddHours(12) }
  $ctx.Response.Headers["Set-Cookie"]=(Session-Cookie $sid)
  @{ username=$u.username; displayName=$dn; role="$($u.role)"; admin=[bool]$u.admin }
}
function Handle-OpsLogin($ctx){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  # Email is the login key; accept the legacy 'username' field too so existing logins keep working, and fall back
  # to a username match when the identifier isn't an email on file (no lockout during the email-login switch).
  $id= if("$($j.email)".Trim()){ "$($j.email)".Trim() } else { "$($j.username)".Trim() }
  $u=Get-OpsUserByEmail $id; if(-not $u){ $u=Get-OpsUser $id }
  if(-not $u -or -not $u.pwdHash -or (Hash-Pwd $u.salt $j.password) -ne $u.pwdHash){ Send-Json $ctx @{ error="Invalid email or password" } 401; return }
  Send-Json $ctx (New-OpsSession $ctx $u)
}
# SWIVEL L!NK OAuth code-flow sign-in (the federation seam). L!NK opens this app in an iframe with a one-time
# #code&state in the URL fragment; the frontend POSTs them here. We redeem the code SERVER-SIDE at the profile
# URL (no client_id/secret - the code self-authenticates), verify the echoed state, match profile.email to a user
# (auto-provisioning a default-role user when enabled), then mint our OWN session. Inert (501) until configured.
function Handle-LinkOAuthLogin($ctx){
  if(-not $script:AuthOn){ Send-Json $ctx @{ error="L!NK sign-in needs auth mode (users.json present)" } 400; return }
  if(-not $LinkEnabled){ Send-Json $ctx @{ error="SWIVEL L!NK sign-in is not enabled on this instance" } 501; return }
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  $code="$($j.code)".Trim(); $state="$($j.state)".Trim()
  if(-not $code -or -not $state){ Send-Json $ctx @{ error="Missing OAuth code or state" } 400; return }
  $resp=$null   # redeem server-to-server: POST { code } -> { profile{email,displayName,userName,...}, state }
  try{
    $hdrs=@{}; if("$LinkXSystem".Trim()){ $hdrs['x-system']="$LinkXSystem".Trim() }
    $resp=Invoke-RestMethod -Method Post -Uri "$LinkProfileUrl".Trim() -Headers $hdrs -ContentType 'application/json; charset=utf-8' -Body (@{ code=$code }|ConvertTo-Json -Compress) -TimeoutSec 30
  }catch{ Send-Json $ctx @{ error="Invalid or expired L!NK sign-in" } 401; return }
  if("$($resp.state)".Trim() -ne $state){ Send-Json $ctx @{ error="Invalid or expired L!NK sign-in" } 401; return }   # state echo MUST match (code-binding guard)
  $prof=$resp.profile
  $email="$($prof.email)".Trim(); if(-not $email){ $email="$($prof.userName)".Trim() }
  if(-not $email){ Send-Json $ctx @{ error="L!NK profile has no email to match" } 401; return }
  $u=Get-OpsUserByEmail $email
  if(-not $u){
    if(-not $LinkAutoProvision){ Send-Json $ctx @{ error="No account for $email - ask an admin to add you" } 403; return }
    $u=Provision-LinkUser $email "$($prof.displayName)"
    if(-not $u){ Send-Json $ctx @{ error="Could not provision a L!NK account" } 500; return }
    Audit $u.username "L!NK auto-provisioned for $email (role=$LinkDefaultRole)"
  }
  Audit $u.username "L!NK sign-in ($email)"
  Send-Json $ctx (New-OpsSession $ctx $u)
}
# Create a minimal user record for a first-time L!NK sign-in (no local password). Username derived from the email
# local-part (sanitized + deduped); role = configured default; authProvider 'swivel'. Persisted via Save-Users.
function Provision-LinkUser($email,$displayName){
  $local=(("$email" -split '@')[0]) -replace '[^A-Za-z0-9_.-]',''; if(-not $local){ $local='user' }
  $un=$local.ToLower(); $n=1
  while($script:Users | Where-Object { $_.username -eq $un }){ $n++; $un="$local$n".ToLower() }
  $dn= if("$displayName".Trim()){ "$displayName".Trim() } else { $local }
  $rec=[pscustomobject][ordered]@{ username=$un; displayName=$dn; email="$email".Trim(); salt=''; pwdHash=''; role=$LinkDefaultRole; admin=$false; authProvider='swivel'; language=''; teams=@(); stations=@(); primaryStation=''; access=@(); erpUsers=@() }
  $users=[System.Collections.ArrayList]@($script:Users); [void]$users.Add($rec)
  $script:Users=@($users); Save-Users
  $rec
}
function Me-PayloadOps($sess){
  if(-not $script:AuthOn){ return @{ user=$sess.username; username=$sess.username; authOn=$false; today=(Today-Str) } }
  $u=Get-OpsUser $sess.username
  @{ user=$sess.username; username=$sess.username; authOn=$true; today=(Today-Str)
     displayName="$($sess.displayName)"; role="$($sess.role)"; admin=[bool]$sess.admin; language="$($u.language)".Trim()
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
# binary sibling of Send-File for DB-stored blobs (doc attachments) - same no-store headers
function Send-Blob($ctx,[byte[]]$bytes,$ctype,$name){
  $ctx.Response.StatusCode=200; $ctx.Response.ContentType=$ctype
  $ctx.Response.Headers["Content-Disposition"]=('inline; filename="' + ("$name" -replace '"','') + '"')
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
    # assign-then-pass, NOT a $(if...) subexpression: a subexpression ENUMERATES array values, turning a
    # byte[] (attachment blob) into Object[] which SqlClient cannot map to a provider type
    foreach($k in $params.Keys){ $v=$params[$k]; if($null -eq $v){ $v=[DBNull]::Value }; [void]$cmd.Parameters.AddWithValue("@$k",$v) }
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
# Draft-review alerts for the My-Tasks inbox: drafts a customer has acted on and that now await the
# operator - CUSTOMER_SUBMITTED (changes + an optional message) or CUSTOMER_APPROVED (ready to agree).
# Self-clearing: the moment the operator saves/agrees/issues, the status leaves these two values and the
# alert disappears. Scope: an operator sees drafts they created; admin/manager see all pending.
function Get-DraftAlerts($cn,$me){
  $tier=Cur-Tier; $p=@{}
  $where="d.status IN ('CUSTOMER_SUBMITTED','CUSTOMER_APPROVED')"
  if($tier -notin 'admin','manager'){ $where+=" AND d.created_by=@dme"; $p['dme']="$me" }
  $rows=@(RunQ $cn "SELECT d.doc_id,d.job_no,d.doc_type,d.status,d.customer_name,d.current_version,CONVERT(varchar(19),d.updated_at,120) updated_at,a.consignee_name FROM dbo.doc_draft d LEFT JOIN dbo.shipment_alerts a ON a.job_no=d.job_no WHERE $where ORDER BY d.updated_at DESC" $p)
  $out=@()
  foreach($r in $rows){
    $comment=''
    $ev=@(RunQ $cn "SELECT TOP 1 detail FROM dbo.doc_event_log WHERE doc_id=@d AND actor LIKE 'customer%' AND event IN ('submitted','approved') ORDER BY occurred_at DESC" @{ d="$($r.doc_id)" })
    if($ev.Count){ try{ $comment="$(($ev[0].detail|ConvertFrom-Json).comment)".Trim() }catch{} }
    $out+=[pscustomobject]@{ docId="$($r.doc_id)"; jobNo="$($r.job_no)"; docType="$($r.doc_type)"; status="$($r.status)"
      customerName="$($r.customer_name)"; consignee="$($r.consignee_name)"; version=[int]$r.current_version; comment=$comment; updatedAt="$($r.updated_at)" }
  }
  $out
}
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
  $draftAlerts=@(); try{ $draftAlerts=@(Get-DraftAlerts $cn $me) }catch{}
  @{ assigned=$assignedT; mine=$mineT; drafts=$draftAlerts; assignedOpen=@($assignedT).Count; dueNow=$dueNow; draftCount=@($draftAlerts).Count; today=$today }
}
# jobs the user is involved in via notes (authored or mentioned) — folded into the worklist "mine" lens
function My-NoteJobs($me){ @(Read-Notes|Where-Object{ $_ -and (("$($_.user)" -eq $me) -or (@($_.mentions) -contains $me)) }|ForEach-Object{"$($_.job_no)"}|Where-Object{$_}|Select-Object -Unique) }
# Jobs where I have an OPEN, real remark/reminder (mine or @-mentioning me) — the exact rule behind the worklist
# 💬 dot: done notes are excluded, and a silent milestone-tick (no remark) doesn't count. Backs the "My notes"
# filter, so a noted shipment leaves the list the moment its note is marked done.
function My-OpenNoteJobs($me){
  @(Read-Notes | Where-Object {
      $_ -and (("$($_.user)" -eq $me) -or (@($_.mentions) -contains $me)) -and (("$($_.status)" -eq '') -or ("$($_.status)" -eq 'open'))
    } | Where-Object {
      $kk="$($_.kind)"; $isMs=($kk -eq 'bypass' -or $kk -eq 'reopen'); $sil=$false
      if($_.PSObject.Properties['silent']){ $sil=[bool]$_.silent } elseif($isMs -and ("$($_.note)" -notmatch ':')){ $sil=$true }
      -not ($isMs -and $sil)
    } | ForEach-Object {"$($_.job_no)"} | Where-Object {$_} | Select-Object -Unique)
}

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

# ---------------- SQL handlers (read only the small erpops tables) ----------------
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
# Port pickers: the FULL port/airport master (erpops.port_dim, ~5k rows with names/countries) so the client
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
# Inbound cross-station bookings destined to THIS station (reads only the small erpops feed; no ERP/cross-DB).
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
  # identifier lookup ("find this file by its number"): when ?ref= is present we deliberately bypass BOTH the
  # ownership lens AND the date window, because the operator is chasing a specific job/BL/PO that is very likely
  # outside this week and/or owned by someone else. Station/pair access scope still applies (security).
  $ref="$($qs['ref'])".Trim()
  $refField="$($qs['refField'])"
  # "My notes" filter: show the shipments this user has noted/been @-mentioned in, regardless of date. The note
  # set IS the involvement, so (like ?ref=) it bypasses the ownership lens AND the date window; station/pair scope
  # still applies. Evaluated up front so the lens/date guards below can see it.
  $flagNotes = ("$($qs['flag'])" -match 'notes')
  $myNoteJobs = if($flagNotes){ @(My-OpenNoteJobs $who) } else { @() }
  # admin oversight: an admin sees every shipment without owning the ERP pic_user (no erpUser match needed).
  # 'all' lens is unfiltered for everyone; the teammate ('user') lens still narrows to the chosen person.
  if($ref -or $flagNotes -or $lens -eq 'all' -or ($lens -ne 'user' -and (Cur-Tier) -eq 'admin')){ }
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
  # date window = "needs my attention in this range". A row stays when ANY of these dates hits the window:
  #   sort_key    - it is MOVING then (ATA/ETA for import, ETD/cargo-ready for export)
  #   next_due    - WORK is due then (milestone due dates derive from ETD, so a booking sailing in 2-3
  #                 weeks still surfaces the week its early milestones fall due)
  #   anchor_date - it was CREATED then (a brand-new booking surfaces immediately, before any due date)
  # Plus: OVERDUE work (next_due in the last 30 days, still pending) stays visible in any window.
  # Older overdue = zombie jobs nobody closed (some date back years) - they only appear under "All dates",
  # otherwise they would drown the default week view (418 of 622 rows on the live test DB).
  # Rows with none of the three dates are kept so a window never silently hides a shipment.
  if(-not $ref -and -not $flagNotes -and ($qs['from'] -or $qs['to'])){
    $p['dlo']=$(if($qs['from']){"$($qs['from'])"}else{'0001-01-01'})
    $p['dhi']=$(if($qs['to']){"$($qs['to'])"}else{'9999-12-31'})
    $p['dtoday']=(Today-Date).ToString('yyyy-MM-dd')
    $w+=" AND ( (sort_key IS NULL AND next_due IS NULL AND anchor_date IS NULL) " +
        "OR sort_key BETWEEN @dlo AND @dhi OR next_due BETWEEN @dlo AND @dhi " +
        "OR (next_due<@dtoday AND next_due>=DATEADD(day,-30,CONVERT(date,@dtoday))) " +
        "OR anchor_date BETWEEN @dlo AND @dhi ) "
  }
  # identifier search: match one column (when a field is picked) or the whole identifier set (Any). The ops
  # table is small (~hundreds-thousands of rows) so a LIKE scan is cheap and bounded by CommandTimeout.
  if($ref){
    $p['ref']='%'+(Like-Esc $ref)+'%'
    # "Job No" matches BOTH the stored key and the human jobn (the key may be a synthetic for booking-stage rows)
    if($refField -eq 'job'){ $w+=" AND (job_no LIKE @ref OR erp_job_no LIKE @ref) " }
    else{
      # 'conv' = conveyance: vessel_voyage holds the sea vessel/voyage AND the air flight no, so one field serves both modes
      $col=@{ booking='sono'; po='cust_ref'; house='house_bill'; master='master_bill'; liner='liner_so'; container='container_no'; conv='vessel_voyage' }[$refField]
      if($col){ $w+=" AND $col LIKE @ref " }
      else{ $w+=" AND (job_no LIKE @ref OR erp_job_no LIKE @ref OR sono LIKE @ref OR house_bill LIKE @ref OR master_bill LIKE @ref OR cust_ref LIKE @ref OR container_no LIKE @ref OR liner_so LIKE @ref) " }
    }
  }
  # "My notes": restrict to the user's noted job_nos (empty set -> no rows rather than the whole worklist)
  if($flagNotes){
    if($myNoteJobs.Count){ $ins=@(); $i=0; foreach($j in $myNoteJobs){ $ins+="@nf$i"; $p["nf$i"]=$j; $i++ }; $w+=" AND job_no IN ("+($ins -join ',')+") " }
    else { $w+=" AND 1=0 " }
  }
  # company filter: match the picked code against ANY role the company may play on a shipment
  if($qs['company']){ $w+=" AND @co IN (cust_code,shipper_code,consignee_code,agent_code,ctrl_code) "; $p['co']="$($qs['company'])" }
  # POL/POD accept comma-separated multi-select lists (chips UI) -> parameterised IN
  $pols=Parse-List $qs['pol']; if($pols.Count){ $ins=@(); $i=0; foreach($v in $pols){ $ins+="@pol$i"; $p["pol$i"]=$v; $i++ }; $w+=" AND pol IN ($($ins -join ',')) " }
  $pods=Parse-List $qs['pod']; if($pods.Count){ $ins=@(); $i=0; foreach($v in $pods){ $ins+="@pod$i"; $p["pod$i"]=$v; $i++ }; $w+=" AND pod IN ($($ins -join ',')) " }
  # auth-mode access scope (stations + mode-bound pairs) — applies to EVERY lens incl. 'all'
  $w += Scope-StationClause $p
  $w += Scope-PairClause $p
  $sel="SELECT job_no,erp_job_no,station,mode,cargo_type,bound,lane,carrier,cust_code,salesman,pic_user,created_by,last_updated_by," +
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
  @{ lens=$lens; who=$who; rows=@($rows|ForEach-Object{ [pscustomobject]@{ jobNo=[string]$_.job_no; erpJobNo=[string]$_.erp_job_no; station=[string]$_.station; mode=[string]$_.mode; cargoType=[string]$_.cargo_type; bound=[string]$_.bound; lane=[string]$_.lane; carrier=[string]$_.carrier; custCode=[string]$_.cust_code; salesman=[string]$_.salesman; picUser=[string]$_.pic_user; createdBy=[string]$_.created_by; anchor=[string]$_.anchor_date; etd=[string]$_.etd; eta=[string]$_.eta; atd=[string]$_.atd; ata=[string]$_.ata; worst=[string]$_.worst_light; openAmber=[int]$_.open_amber; openRed=[int]$_.open_red; nextDue=[string]$_.next_due; autoDone=[int]$_.auto_done; manualDone=[int]$_.manual_done; consigneeName=[string]$_.consignee_name; shipperName=[string]$_.shipper_name; custContact=[string]$_.cust_contact; custPhone=[string]$_.cust_phone; custEmail=[string]$_.cust_email; vesselVoyage=[string]$_.vessel_voyage; containerSummary=[string]$_.container_summary; containerCount=[int]$_.container_count; totalWeight=[string]$_.total_weight; totalCbm=[string]$_.total_cbm; arrivalState=[string]$_.arrival_state; houseBill=[string]$_.house_bill; masterBill=[string]$_.master_bill; incoterm=[string]$_.incoterm; custRef=[string]$_.cust_ref; containerNo=[string]$_.container_no; linerSo=[string]$_.liner_so; cargoReady=[string]$_.cargo_ready; sortKey=[string]$_.sort_key; shipperCode=[string]$_.shipper_code; consigneeCode=[string]$_.consignee_code; agentCode=[string]$_.agent_code; ctrlCode=[string]$_.ctrl_code; commodity=[string]$_.commodity; sono=[string]$_.sono; routeSummary=[string]$_.route_summary; availableDate=[string]$_.available_date; etaDelivery=[string]$_.eta_delivery; goodsDelivery=[string]$_.goods_delivery; hasNotes=[bool]$chatJobs["$($_.job_no)"]; noteText=$(if($chatJobs["$($_.job_no)"]){[string]$chatJobs["$($_.job_no)"].text}else{''}); noteMilestone=$(if($chatJobs["$($_.job_no)"]){[string]$chatJobs["$($_.job_no)"].code}else{''}); hasUpdate=[bool]$updJobs["$($_.job_no)"]; updateMilestone=$(if($updJobs["$($_.job_no)"]){[string]$updJobs["$($_.job_no)"].code}else{''}); updateMilestoneName=$(if($updJobs["$($_.job_no)"]){ $uc=[string]$updJobs["$($_.job_no)"].code; [string]$msName[("$($_.mode)|$($_.bound)|$uc").ToUpper()] }else{''}) } }) }
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
# on the station ERP, bounded by Connect Timeout=15 / CommandTimeout=8 so the single-threaded listener can't be
# held long. Display-only — nothing is written back (the next listener pass refreshes the erpops snapshot).
$SrcAuthClause= if($auth -eq 'sql'){"User ID=$user;Password=$password"}else{"Integrated Security=True"}
$DbByStation=@{}; foreach($s in @($cfg.stations)){ if($s -and $s.code -and $s.database){ $DbByStation["$($s.code)".Trim().ToUpper()]="$($s.database)".Trim() } }
$script:ErpCols=@{}   # per (db|table) Filter-Cols cache so repeat clicks skip INFORMATION_SCHEMA
$script:OwnAgentByDb=@{}   # per-db cache of the own-office agent block (stable per station) - see Get-OwnOfficeAgent
$SeaDetailCols="jobn,ref,blno,mobl,bound,routing,pol,pod,deli,dest,pol_name,pod_name,deli_name,dest_name,vessel_1,voyage_1,vessel_2,voyage_2,departure1,departure2,arrival1,arrival1d,arrival2,arrival2d,arrival3,available_date,eta_delivery,goods_delivery,cargoready,spotid,sono,t_book_qty,t_book_wgt,t_book_cbm,t_rece_qty,t_rece_wgt,t_rece_cbm,remark"
$AirDetailCols="jobn,ref,hawb,mawb,bound,routing,booking,po_no,pol,pod,to1,to3,dest,deli,pol_name,pod_name,to1_name,to3_name,dest_name,deli_name,flight1,flight2,flight3,f_date1,f_date2,f_date3,f_time1,f_time2,f_time3,fa_date1,fa_date2,fa_date3,rout_by_1,atd_date,ata_date,cargoready,goods_delivery,t_book_qty,t_book_wgt,t_book_cwt,t_book_cbm,t_rece_qty,t_rece_cbm,ttl_cwt,remark,special_remark"
function Get-ErpCols($srcCn,$db,$table,$wantCsv,[string[]]$ntextCols){
  # key includes the want-list: erp-detail and the doc seeder ask for DIFFERENT columns of the same table,
  # and a db|table-only key would hand one caller the other's (possibly narrower) cached list
  $key="$db|$table|$wantCsv"
  if($script:ErpCols[$key]){ return $script:ErpCols[$key] }
  # We do NOT probe column metadata. INFORMATION_SCHEMA.COLUMNS / sys.columns are CATASTROPHICALLY slow for
  # the read-only login on the ERP's very wide tables (awbhead 465 cols / blhead 381 cols run 40-70s of
  # per-column permission checks - even a 1s CommandTimeout takes 6s+ and DROPS the connection), while the
  # keyed data SELECT is ~0.3s. That probe sat on the draft request path with RunQ's no-retry-on-timeout,
  # so its 8s timeout aborted the whole ERP seed -> drafts came back snapshot-only AND slow. The doc-seed
  # want-lists are core ERP columns present across the fm3k group, so we trust the want-list and let the
  # fast keyed SELECT run. If a schema-variant office genuinely lacks a wanted column, that one SELECT
  # throws and the caller's try/catch degrades to the snapshot seed - never a multi-second hang.
  $keep=@(@($wantCsv -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
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
  $srcCn=New-Object System.Data.SqlClient.SqlConnection "Server=$server;Database=$db;$SrcAuthClause;TrustServerCertificate=True;Connect Timeout=15;Packet Size=512"
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
# List the files the Swivel ERP holds for this shipment (browse only; download is a later round). The ERP file
# enquiry filters by bookingNo/3rdBookingID only, so we pick the best-available identifier off the snapshot by
# the ops priority - Air: HAWB -> booking -> MAWB ; Sea: booking(sono) -> HBL - and let Invoke-ErpFileEnquiry
# try it as bookingNo then 3rdBookingID. One bounded outbound HTTP call (same accepted cost as Handle-ErpDetail).
function Handle-ErpFiles($cn,$qs){
  $job="$($qs['job'])".Trim(); if(-not $job){ return @{error='job required'} }
  $al=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound,sono,house_bill,master_bill FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $al.Count){ return @{error='not found'} }
  if(-not (Test-JobScope $al[0])){ return @{error='not found'} }
  $a=$al[0]
  $isAir=("$($a.mode)" -eq 'Air'); $module= if($isAir){'AIR'}else{'SEA'}
  $sono="$($a.sono)".Trim(); $hbl="$($a.house_bill)".Trim(); $mbl="$($a.master_bill)".Trim()
  # ordered identifier candidates (ops rule): Air HAWB -> Booking -> MAWB ; Sea Booking(sono) -> HBL
  $cands= if($isAir){ @(@{kind='HAWB';val=$hbl},@{kind='Booking';val=$sono},@{kind='MAWB';val=$mbl}) } else { @(@{kind='Booking';val=$sono},@{kind='HBL';val=$hbl}) }
  if(-not @(@($cands)|Where-Object{ "$($_.val)".Trim() }).Count){ return @{ error='no booking / bill number on this shipment to query the ERP' } }
  $r=Invoke-ErpFileEnquiry $cfg.erpApi (Get-ErpApiMap) $module $cands (Resolve-ForwarderCode $a.station)
  # doctypes whose upload would clear a milestone on THIS shipment (derived from the evidence map, cached)
  $dmap=Get-MilestoneDoctypeMap $cn; $clearable=@()
  foreach($dt in $dmap.Keys){ foreach($ms in @($dmap[$dt])){ if($ms.bound -eq "$($a.bound)" -and ($ms.module -eq '' -or $ms.module -eq $module)){ $clearable+=$dt; break } } }
  # ALL configured ERP document types - so any document can be uploaded, not only one that clears an alert
  $allDt=@($dmap.Keys | Sort-Object)
  @{ keyUsed=[string]$r.keyUsed; keyKind=[string]$r.keyKind; keyField=[string]$r.keyField; mock=[bool]$r.mock; files=@($r.files); error=[string]$r.error; clearableDoctypes=@($clearable|Select-Object -Unique); uploadDoctypes=$allDt }
}
# Upload a missing document to the ERP and, on success, clear the milestone(s) that document satisfies. The
# successful upload IS the proof (the doctype -> milestone link is derived live from milestone_evidence_map, so it
# tracks admin edits). The file streams request-body -> ERP via /file/upload; nothing is stored locally. On ERP
# failure nothing clears. Body: { job, doctype, fileName, content_type, base64 }.
function Handle-ErpFileUpload($cn,$ctx,$me){
  if($ctx.Request.ContentLength64 -gt 7340032){ return @{ error='file too large (max 5 MB)' } }   # cap BEFORE reading body
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.job){ return @{ error='invalid payload' } }
  $job="$($j.job)".Trim(); $doctype="$($j.doctype)".Trim()
  if(-not $doctype){ return @{ error='choose a document type' } }
  $al=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound,sono,house_bill,master_bill FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $al.Count){ return @{ error='not found' } }
  if(-not (Test-JobScope $al[0])){ return @{ error='not found' } }
  $a=$al[0]
  $isAir=("$($a.mode)" -eq 'Air'); $module= if($isAir){'AIR'}else{'SEA'}
  # validate the file (pdf/png/jpeg, magic-byte, <=5MB) - same rules as draft-doc attachments
  $v=Doc-AttachValidate $j.fileName $j.content_type $j.base64
  if(-not $v.ok){ return @{ error=$v.err } }
  # which milestones would this doctype clear for this shipment? (derived, cached)
  $dmap=Get-MilestoneDoctypeMap $cn
  $codes=@(); foreach($ms in @($dmap[$doctype])){ if($ms.bound -eq "$($a.bound)" -and ($ms.module -eq '' -or $ms.module -eq $module)){ $codes+=$ms.code } }
  $codes=@($codes|Select-Object -Unique)
  # the doctype IS the ERP Document Type code (admin-maintained in milestone_evidence_map.match_value, kept to
  # match the ERP) - send it verbatim. Resolve the booking identity keys.
  $map=Get-ErpApiMap
  $dtc=$doctype
  $houseNo="$($a.house_bill)".Trim()
  $bookingNo= if("$($a.sono)".Trim()){ "$($a.sono)".Trim() } else { "$($a.master_bill)".Trim() }
  $remark="Uploaded via Control Tower by $me to clear '$doctype'"
  $up=Invoke-ErpFileUpload $cfg.erpApi $map $module $houseNo $bookingNo $dtc $v.name ([Convert]::ToBase64String($v.bytes)) $remark (Resolve-ForwarderCode $a.station)
  if(-not $up.ok){ Audit $me "erp-file-upload $job '$doctype' FAILED: $($up.error)"; return @{ error="ERP upload failed: $($up.error)" } }
  # success: the upload is the proof - clear the milestone(s) locally
  $cleared=@()
  if($codes.Count){
    $cr=Close-MilestonesFor $cn $job $codes "document: $doctype ($($v.name)) uploaded to ERP" $me
    if($cr.ok){ $cleared=@($cr.cleared) }
  }
  Audit $me "erp-file-upload $job '$doctype' ($($v.bytes.Length) bytes)$(if($up.mock){' [mock]'}) -> cleared [$($cleared -join ',')]"
  @{ ok=$true; mock=[bool]$up.mock; doctype=$doctype; fileName=$v.name; cleared=@($cleared) }
}
# Stream one ERP-held file's bytes (download round). Same identifier resolution as Handle-ErpFiles, then
# /file/download for the requested fileName. Returns $true when the blob is sent so the router skips JSON.
function Handle-ErpFileDownload($cn,$ctx,$qs){
  $job="$($qs['job'])".Trim(); $file="$($qs['file'])".Trim()
  if(-not $job){ return $false }
  $al=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound,sono,house_bill,master_bill FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $al.Count){ return $false }
  if(-not (Test-JobScope $al[0])){ return $false }
  $a=$al[0]
  $isAir=("$($a.mode)" -eq 'Air'); $module= if($isAir){'AIR'}else{'SEA'}
  $sono="$($a.sono)".Trim(); $hbl="$($a.house_bill)".Trim(); $mbl="$($a.master_bill)".Trim()
  $cands= if($isAir){ @(@{kind='HAWB';val=$hbl},@{kind='Booking';val=$sono},@{kind='MAWB';val=$mbl}) } else { @(@{kind='Booking';val=$sono},@{kind='HBL';val=$hbl}) }
  if(-not @(@($cands)|Where-Object{ "$($_.val)".Trim() }).Count){ return $false }
  $r=Invoke-ErpFileDownload $cfg.erpApi (Get-ErpApiMap) $module $cands $file (Resolve-ForwarderCode $a.station)
  if($r.mock -or -not $r.bytes){ return $false }
  $name= if("$($r.fileName)".Trim()){ "$($r.fileName)".Trim() } elseif($file){ $file } else { 'erp-file' }
  $ct= switch([IO.Path]::GetExtension($name).ToLower()){
    ".pdf"{"application/pdf"} ".png"{"image/png"} ".jpg"{"image/jpeg"} ".jpeg"{"image/jpeg"} ".gif"{"image/gif"}
    ".txt"{"text/plain; charset=utf-8"} ".csv"{"text/csv; charset=utf-8"} ".xml"{"application/xml"}
    ".doc"{"application/msword"} ".docx"{"application/vnd.openxmlformats-officedocument.wordprocessingml.document"}
    ".xls"{"application/vnd.ms-excel"} ".xlsx"{"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}
    default{"application/octet-stream"} }
  Send-Blob $ctx ([byte[]]$r.bytes) $ct $name
  $true
}

# ============================================================================================================
# ERP DATA CORRECTION (staff-internal). Show a shipment's current ERP master codes + values, let the operator
# pick the correct code from the live master (custsub/linermstr/portmstr/servmstr) or type a correction, and
# push ONLY the changed fields to /booking/update. Every save is audited in erp_edit_log (before->after).
# Reads use the same bounded pattern as Handle-ErpDetail (Connect Timeout=15 / CommandTimeout=8 / Packet=512).
# The dictionary (erp-edit-fields.json) maps each field to its ERP read column + master lookup + write key.
# ============================================================================================================
$ErpEditFieldsPath=Join-Path $Root "erp-edit-fields.json"
function ErpEdit-FieldDefs($mode){
  if(-not $script:ErpEditDict){
    $j=[IO.File]::ReadAllText($ErpEditFieldsPath)|ConvertFrom-Json
    $script:ErpEditDict=@{ SEA=@($j.SEA); AIR=@($j.AIR) }
  }
  @($script:ErpEditDict[$mode])
}
# Incoterms 2020 - the fixed master for the incoterm lookup (there is NO incoterm table in the ERP; the code
# lives free-text in blhead/awbhead.routing). Served by /api-ops/erp-master?kind=incoterm.
$script:IncotermList=@(
  @{ code='EXW'; name='Ex Works' }, @{ code='FCA'; name='Free Carrier' }, @{ code='FAS'; name='Free Alongside Ship' },
  @{ code='FOB'; name='Free On Board' }, @{ code='CFR'; name='Cost and Freight' }, @{ code='CIF'; name='Cost, Insurance and Freight' },
  @{ code='CPT'; name='Carriage Paid To' }, @{ code='CIP'; name='Carriage and Insurance Paid To' }, @{ code='DAP'; name='Delivered At Place' },
  @{ code='DPU'; name='Delivered At Place Unloaded' }, @{ code='DDP'; name='Delivered Duty Paid' }
)
# Clean + clamp incoming corrections against the erp-edit dictionary (mirror of Doc-CleanFields, different dict).
function ErpEdit-CleanFields($mode,$src){
  $o=[ordered]@{}
  foreach($f in (ErpEdit-FieldDefs $mode)){
    $c="$($f.code)"; $raw=$null
    if($src -is [hashtable]){ if($src.ContainsKey($c)){ $raw=$src[$c] } }
    elseif($src -and $src.PSObject.Properties[$c]){ $raw=$src.$c }
    if("$($f.kind)" -eq 'table'){
      $maxR=50; [void][int]::TryParse("$($f.maxRows)",[ref]$maxR); if($maxR -lt 1){ $maxR=50 }
      $rows=@()
      foreach($r in @($raw)){
        if($null -eq $r -or $r -is [string]){ continue }
        $row=[ordered]@{}
        foreach($col in @($f.columns)){
          $cc="$($col.code)"; $cv=$null
          if($r -is [hashtable]){ if($r.ContainsKey($cc)){ $cv=$r[$cc] } }
          elseif($r.PSObject.Properties[$cc]){ $cv=$r.$cc }
          $row[$cc]=Doc-CleanStr $cv $col.maxlen
        }
        $blank=$true; foreach($k in $row.Keys){ if("$($row[$k])".Trim()){ $blank=$false; break } }
        if(-not $blank){ $rows+=,$row }
        if($rows.Count -ge $maxR){ break }
      }
      $o[$c]=@($rows)
    } else {
      $o[$c]=Doc-CleanStr $raw $f.maxlen
    }
  }
  [pscustomobject]$o
}
# Single keyed master-name lookup for a code (used to label the current code in the seed).
function ErpMaster-Name($srcCn,$db,$kind,$code){
  $code="$code".Trim(); if(-not $code){ return '' }
  try{
    switch($kind){
      'custsub' { $r=@(RunQ $srcCn "SELECT TOP 1 doc_e_name,mal_e_name,city,country FROM dbo.custsub WHERE code2=@c AND ISNULL(isdel,0)=0" @{ c=$code } 8); if($r.Count){ $n="$($r[0].doc_e_name)".Trim(); if(-not $n){ $n="$($r[0].mal_e_name)".Trim() }; $loc=(@("$($r[0].city)".Trim(),"$($r[0].country)".Trim())|Where-Object{ $_ }) -join ', '; if($loc){ return "$n - $loc" }; return $n } }
      'liner'   { $r=@(RunQ $srcCn "SELECT TOP 1 name FROM dbo.linermstr WHERE code=@c" @{ c=$code } 8); if($r.Count){ return "$($r[0].name)".Trim() } }
      'port'    { $r=@(RunQ $srcCn "SELECT TOP 1 port_ldes1 FROM dbo.portmstr WHERE code=@c" @{ c=$code } 8); if($r.Count){ return "$($r[0].port_ldes1)".Trim() } }
      'service' { $r=@(RunQ $srcCn "SELECT TOP 1 desc1 FROM dbo.servmstr WHERE service=@c" @{ c=$code } 8); if($r.Count){ return "$($r[0].desc1)".Trim() } }
    }
  }catch{}
  ''
}
# Numeric column -> clean string (drop trailing .000 so "150.000"->"150", "2.500"->"2.5"); blank for null.
function ErpNumStr($v){
  if($null -eq $v -or $v -is [DBNull]){ return '' }
  $s="$v".Trim(); if($s -match '^-?\d+(\.\d+)?$'){ $s=$s -replace '(\.\d*?)0+$','$1'; $s=$s -replace '\.$','' }
  $s
}
# Seed the editor: current ERP value + resolved master name for every dict field on this shipment.
function Handle-ErpEditSeed($cn,$qs){
  $job="$($qs['job'])".Trim(); if(-not $job){ return @{error='job required'} }
  $al=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound,erp_ref,sono FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $al.Count){ return @{error='not found'} }
  if(-not (Test-JobScope $al[0])){ return @{error='not found'} }
  $a=$al[0]; $isAir=("$($a.mode)" -eq 'Air'); $modeKey= if($isAir){'AIR'}else{'SEA'}
  $db=$DbByStation["$($a.station)".Trim().ToUpper()]
  if(-not $db){ return @{error="station '$($a.station)' has no ERP database mapped in config stations[]"} }
  $defs=ErpEdit-FieldDefs $modeKey
  # column set to read from the header table (skip the container table; expand a 'base..5' address into 5 cols)
  $cols=@('ref')
  foreach($d in $defs){
    if("$($d.kind)" -eq 'table'){ continue }
    $rf="$($d.readFrom)".Trim(); if(-not $rf){ continue }
    if($rf -match '^(.+?)(\d+)\.\.(\d+)$'){ $pre=$Matches[1]; ([int]$Matches[2])..([int]$Matches[3]) | ForEach-Object { $cols+=($pre+"$_") } }
    else { $cols+=$rf }
  }
  # derived shipping-window source legs (etd/eta have readFrom='' so are not picked above): Import dep1/arr1,
  # Export dep2/arr2; Air ETD = f_date1 (no air ETA on this ERP). Resolved into etd/eta after the read.
  if($isAir){ $cols+='f_date1' } else { $cols+='departure1','departure2','arrival1','arrival2','vessel_1','vessel_2','voyage_1','voyage_2','deli' }
  $cols=@($cols | Select-Object -Unique)
  $srcCn=New-Object System.Data.SqlClient.SqlConnection "Server=$server;Database=$db;$SrcAuthClause;TrustServerCertificate=True;Connect Timeout=15;Packet Size=512"
  try{
    $srcCn.Open()
    $ownCode=Get-StationOwnCode $srcCn $db   # forwarderPartyCode for /booking/update (which office owns this booking)
    $tbl= if($isAir){'awbhead'}else{'blhead'}
    $key="$($a.erp_ref)".Trim()
    $csv=($cols -join ',')
    if($key){ $hdr=@(RunQ $srcCn "SELECT TOP 1 $csv FROM dbo.$tbl WHERE ref=@k" @{ k=$key } 8) }
    else { $hdr=@(RunQ $srcCn "SELECT TOP 1 $csv FROM dbo.$tbl WHERE jobn=@k ORDER BY ref DESC" @{ k=$job } 8) }
    if(-not $hdr.Count){ return @{error="shipment not found in the ERP [$db.$tbl $(if($key){"ref=$key"}else{"jobn=$job"})]"} }
    $b=$hdr[0]
    $fields=[ordered]@{}; $resolved=[ordered]@{}
    foreach($d in $defs){
      $code="$($d.code)"
      if("$($d.kind)" -eq 'table'){
        $crows=@(); try{ $crows=@(RunQ $srcCn "SELECT container,cont_type,seal,load_qty,pkgs_unit,load_wgt,load_cbm FROM dbo.blcont WHERE blh=@r ORDER BY ref" @{ r=$b.ref } 8) }catch{}
        $clist=@(); foreach($cr in $crows){ $clist+=,[ordered]@{ container_no="$($cr.container)".Trim(); cont_type="$($cr.cont_type)".Trim(); seal_no="$($cr.seal)".Trim(); qty=(ErpNumStr $cr.load_qty); qty_unit="$($cr.pkgs_unit)".Trim(); weight=(ErpNumStr $cr.load_wgt); cbm=(ErpNumStr $cr.load_cbm) } }
        $fields[$code]=@($clist)
        continue
      }
      $rf="$($d.readFrom)".Trim()
      if($rf -match '^(.+?)(\d+)\.\.(\d+)$'){
        $pre=$Matches[1]; $s=[int]$Matches[2]; $e=[int]$Matches[3]
        $parts=@(); $s..$e | ForEach-Object { $v="$($b.($pre+"$_"))".Trim(); if($v -and ($parts -notcontains $v)){ $parts+=$v } }
        $fields[$code]=($parts -join "`n")
      } elseif(-not $rf){
        $fields[$code]=''                                   # derived (etd/eta) - set after the loop
      } elseif("$($d.kind)" -eq 'bool'){
        $bv=$false; try{ $bv=[bool]$b.$rf }catch{}; $fields[$code]= if($bv){'true'}else{'false'}
      } elseif("$($d.kind)" -eq 'date'){
        $dv=$b.$rf; $fields[$code]= if($dv -is [datetime]){ $dv.ToString('yyyy-MM-dd') }else{ '' }
      } elseif("$($d.kind)" -eq 'number'){
        $fields[$code]=ErpNumStr $b.$rf
      } else {
        $fields[$code]="$($b.$rf)".Trim()
      }
      if("$($d.kind)" -eq 'code'){
        $lk="$($d.lookup)".Trim(); $cv="$($fields[$code])".Trim()
        if($cv -and $lk -ne 'incoterm'){ $nm=ErpMaster-Name $srcCn $db $lk $cv; if($nm){ $resolved[$code]=$nm } }
      }
    }
    # bound-aware shipping window (read-only display): the leg the operator plans against
    $isImport=("$($a.bound)" -eq 'Import')
    if($fields.Contains('etd')){
      $col= if($isAir){'f_date1'}elseif($isImport){'departure1'}else{'departure2'}
      $dv=$null; try{ $dv=$b.$col }catch{}; $fields['etd']= if($dv -is [datetime]){ $dv.ToString('yyyy-MM-dd') }else{ '' }
    }
    if($fields.Contains('eta')){
      $col= if($isImport){'arrival1'}else{'arrival2'}
      $dv=$null; try{ $dv=$b.$col }catch{}; $fields['eta']= if($dv -is [datetime]){ $dv.ToString('yyyy-MM-dd') }else{ '' }
    }
    # vessel / voyage (sea, bound-aware: Export vessel_2/voyage_2, Import vessel_1/voyage_1; vessel code -> veslmstr name)
    if(-not $isAir -and $fields.Contains('vessel_name')){
      $vcol= if($isImport){'vessel_1'}else{'vessel_2'}; $vcode="$($b.$vcol)".Trim(); $vname=$vcode
      if($vcode){ try{ $vr=@(RunQ $srcCn "SELECT TOP 1 short_name FROM dbo.veslmstr WHERE code=@c" @{ c=$vcode } 8); if($vr.Count){ $sn="$($vr[0].short_name)".Trim(); if($sn){ $vname=$sn } } }catch{} }
      $fields['vessel_name']=$vname
    }
    if(-not $isAir -and $fields.Contains('voyage_no')){
      $vycol= if($isImport){'voyage_1'}else{'voyage_2'}; $fields['voyage_no']="$($b.$vycol)".Trim()
    }
    # Air marks/description live on the detail line (awbdetl.mark2 / desc2), not the header (crmarking/wdesc are
    # blank), so seed them from there - desc falls back to good_desc1 when desc2 is empty.
    if($isAir){
      try{
        $adr=@(RunQ $srcCn "SELECT TOP 1 mark2, desc2, good_desc1 FROM dbo.awbdetl WHERE blh=@r ORDER BY ref" @{ r=$b.ref } 8)
        if($adr.Count){
          if($fields.Contains('ship_marks')){ $fields['ship_marks']="$($adr[0].mark2)".Trim() }
          if($fields.Contains('goods_desc')){ $gd="$($adr[0].desc2)".Trim(); if(-not $gd){ $gd="$($adr[0].good_desc1)".Trim() }; $fields['goods_desc']=$gd }
        }
      }catch{}
    }
    # Sea commodity / liner agent / container-size counts / marks / description live on the detail line (blitem),
    # not the header - seed them from there (blh=ref, first line). Mirrors the Air awbdetl block.
    if(-not $isAir){
      try{
        $bir=@(RunQ $srcCn "SELECT TOP 1 commodity, c20, c40, cq, c45, mark2, mark3, good_desc1, desc2, desc3 FROM dbo.blitem WHERE blh=@r ORDER BY ref" @{ r=$b.ref } 8)
        if($bir.Count){
          $bi=$bir[0]
          if($fields.Contains('commodity')){ $fields['commodity']="$($bi.commodity)".Trim() }
          if($fields.Contains('container20')){ $fields['container20']=ErpNumStr $bi.c20 }
          if($fields.Contains('container40')){ $fields['container40']=ErpNumStr $bi.c40 }
          if($fields.Contains('container_hq')){ $fields['container_hq']=ErpNumStr $bi.cq }
          if($fields.Contains('container_other')){ $fields['container_other']=ErpNumStr $bi.c45 }
          if($fields.Contains('ship_marks')){ $fields['ship_marks']=(@("$($bi.mark2)".Trim(),"$($bi.mark3)".Trim())|Where-Object{ $_ }) -join "`n" }
          if($fields.Contains('goods_desc')){ $gd="$($bi.good_desc1)".Trim(); if(-not $gd){ $gd=(@("$($bi.desc2)".Trim(),"$($bi.desc3)".Trim())|Where-Object{ $_ }) -join "`n" }; $fields['goods_desc']=$gd }
        }
      }catch{}
      # Liner agent: the booking party code on the container line (blcont.lagent), resolved to a company via custsub
      if($fields.Contains('liner_code')){
        $lc=''
        try{ $lcr=@(RunQ $srcCn "SELECT TOP 1 lagent FROM dbo.blcont WHERE blh=@r AND NULLIF(lagent,'') IS NOT NULL ORDER BY ref" @{ r=$b.ref } 8); if($lcr.Count){ $lc="$($lcr[0].lagent)".Trim() } }catch{}
        $fields['liner_code']=$lc
        if($lc){ $nm=ErpMaster-Name $srcCn $db 'custsub' $lc; if($nm){ $resolved['liner_code']=$nm } }
      }
      # Final Destination: dest is the field, but fall back to Place of Delivery (deli) when dest is blank
      if($fields.Contains('dest_code') -and -not "$($fields['dest_code'])".Trim()){
        $dv="$($b.deli)".Trim()
        if($dv){ $fields['dest_code']=$dv; $nm=ErpMaster-Name $srcCn $db 'port' $dv; if($nm){ $resolved['dest_code']=$nm } }
      }
      # Weight unit defaults to KGS when the ERP leaves it blank
      if($fields.Contains('cargo_wunit') -and -not "$($fields['cargo_wunit'])".Trim()){ $fields['cargo_wunit']='KGS' }
    }
    @{ jobNo=$job; mode="$($a.mode)"; bound="$($a.bound)"; dict=@($defs); fields=$fields; resolved=$resolved; ownCode=$ownCode }
  } catch {
    @{ error="ERP lookup failed: $($_.Exception.Message)" }
  } finally { try{ $srcCn.Close() }catch{} }
}
# Master type-ahead so the operator can find the CORRECT code. Bounded live LIKE seek (TOP 20, 8s). incoterm
# returns the fixed Incoterms list (no DB). custsub/liner/port/service read the station's master.
function Handle-ErpMasterSearch($cn,$qs){
  $job="$($qs['job'])".Trim(); $kind="$($qs['kind'])".Trim().ToLower(); $q="$($qs['q'])".Trim()
  if(-not $job){ return @{error='job required'} }
  $al=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $al.Count){ return @{error='not found'} }
  if(-not (Test-JobScope $al[0])){ return @{error='not found'} }
  $a=$al[0]; $isAir=("$($a.mode)" -eq 'Air')
  if($kind -eq 'incoterm'){
    $ql=$q.ToLower()
    $res=@($script:IncotermList | Where-Object { -not $ql -or "$($_.code)".ToLower().Contains($ql) -or "$($_.name)".ToLower().Contains($ql) } | ForEach-Object { [pscustomobject]@{ code=$_.code; name=$_.name } })
    return @{ kind='incoterm'; results=@($res) }
  }
  $db=$DbByStation["$($a.station)".Trim().ToUpper()]
  if(-not $db){ return @{error="station '$($a.station)' has no ERP database mapped"} }
  $like='%'+($q -replace '[%_\[\]]','')+'%'   # strip LIKE metachars (still parameterized) so it's a plain contains-search
  $srcCn=New-Object System.Data.SqlClient.SqlConnection "Server=$server;Database=$db;$SrcAuthClause;TrustServerCertificate=True;Connect Timeout=15;Packet Size=512"
  try{
    $srcCn.Open()
    $rows=@()
    switch($kind){
      'custsub' { $rows=@(RunQ $srcCn "SELECT TOP 20 code2 code, doc_e_name name, city, country FROM dbo.custsub WHERE ISNULL(isdel,0)=0 AND NULLIF(code2,'') IS NOT NULL AND (code2 LIKE @q OR doc_e_name LIKE @q) ORDER BY code2" @{ q=$like } 8) }
      'liner'   { $rows=@(RunQ $srcCn "SELECT TOP 20 code, name FROM dbo.linermstr WHERE NULLIF(code,'') IS NOT NULL AND (code LIKE @q OR name LIKE @q) ORDER BY code" @{ q=$like } 8) }
      'port'    { $mod= if($isAir){'AIR'}else{'SEA'}; $rows=@(RunQ $srcCn "SELECT TOP 20 code, port_ldes1 name FROM dbo.portmstr WHERE NULLIF(code,'') IS NOT NULL AND (NULLIF(module,'') IS NULL OR module=@m) AND (code LIKE @q OR port_ldes1 LIKE @q) ORDER BY code" @{ q=$like; m=$mod } 8) }
      'service' { $rows=@(RunQ $srcCn "SELECT TOP 20 service code, desc1 name FROM dbo.servmstr WHERE NULLIF(service,'') IS NOT NULL AND (service LIKE @q OR desc1 LIKE @q) ORDER BY service" @{ q=$like } 8) }
      default   { return @{error="unknown lookup kind '$kind'"} }
    }
    @{ kind=$kind; results=@($rows | ForEach-Object {
        $o=[ordered]@{ code="$($_.code)".Trim(); name="$($_.name)".Trim() }
        if($_.PSObject.Properties['city'] -or $_.PSObject.Properties['country']){
          $loc=(@("$($_.city)".Trim(),"$($_.country)".Trim())|Where-Object{ $_ }) -join ', '; if($loc){ $o['loc']=$loc }
        }
        [pscustomobject]$o }) }
  } catch {
    @{ error="master lookup failed: $($_.Exception.Message)" }
  } finally { try{ $srcCn.Close() }catch{} }
}
# Save: diff the corrected fields against the live ERP values, push ONLY the changed ones via /booking/update,
# and audit before->after in erp_edit_log. Client sends the FULL field set (seed overlaid with edits) so a
# field the operator never touched is never seen as cleared.
function Save-ErpEdit($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.job_no){ return @{error='invalid payload'} }
  $job="$($j.job_no)".Trim()
  $al=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound,erp_ref,sono FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $al.Count){ return @{error='not found'} }
  if(-not (Test-JobScope $al[0])){ return @{error='not found'} }
  $a=$al[0]; $isAir=("$($a.mode)" -eq 'Air'); $modeKey= if($isAir){'AIR'}else{'SEA'}
  $defs=ErpEdit-FieldDefs $modeKey
  # authoritative 'before' = re-read the live ERP values right now (never trust a client-sent baseline)
  $seed=Handle-ErpEditSeed $cn @{ job=$job }
  if($seed.error){ return @{ error="$($seed.error)" } }
  $current=$seed.fields
  $clean=ErpEdit-CleanFields $modeKey $j.fields
  $curJson=($current|ConvertTo-Json -Depth 6 -Compress)
  $changedCodes=@(Doc-Changed $curJson $clean)
  if(-not $changedCodes.Count){ return @{error='no changes to save'} }
  $defByCode=@{}; foreach($d in $defs){ $defByCode["$($d.code)"]=$d }
  # block a change to a read-only field (no writeKey) up front, with a clear message
  $blocked=@($changedCodes | Where-Object { -not "$($defByCode[$_].writeKey)".Trim() })
  if($blocked.Count){ return @{ error="these fields cannot be written to the ERP (no write key): $($blocked -join ', ')" } }
  $changed=[ordered]@{}; foreach($c in $changedCodes){ $changed[$c]=$clean.$c }
  # Booking key for /booking/update - this names the ONE house/booking to patch, so it MUST be house-level, never
  # the jobn (one jobn = many houses). NOTE the field name differs by mode: Sea = 'sono', Air = 'booking'. Air's
  # booking is often blank, so fall back through the bills. Chains (last resort = jobn, still better than the
  # internal synthetic key which the ERP can't resolve):  Sea  sono -> HBL(blno) -> jobn ;  Air  booking -> HAWB ->
  # MAWB -> jobn. Read from the fresh seed, whose codes are mode-mapped to the right ERP column (booking_no=sono/
  # booking, bl_no=blno/hawb, master_no=mobl/mawb, job_disp=jobn).
  $sf=$seed.fields
  $bkChain= if($isAir){ @('booking_no','bl_no','master_no','job_disp') } else { @('booking_no','bl_no','job_disp') }
  $bookingNo=''
  foreach($code in $bkChain){ $v="$($sf[$code])".Trim(); if($v){ $bookingNo=$v; break } }
  if(-not $bookingNo){ $bookingNo=$job }
  # forwarderPartyCode (owncode) - which office owns this booking; resolved from the seed (fm3kco.site), map fallback.
  $fwd="$($seed.ownCode)".Trim(); if(-not $fwd){ $fwd="$((Get-ErpApiMap).forwarderCode)".Trim() }
  $ident=@{ bookingNo=$bookingNo; module=$modeKey; bound="$($a.bound)"; forwarderCode=$fwd }
  $built=Build-ErpPatchPayload $changed $defs $ident (Get-ErpApiMap) $clean
  $erp=Invoke-ErpEditPush $built.payload $bookingNo $modeKey $me $fwd
  $changeRecs=@(); foreach($c in $changedCodes){ $changeRecs+=,@{ field=$c; writeKey="$($defByCode[$c].writeKey)"; before=(Doc-ValStr $current[$c]); after=(Doc-ValStr $clean.$c) } }
  $status= if($erp.mock){'mock'} elseif($erp.error){'error'} elseif($erp.rejected){'rejected'} else {'saved'}
  $ip="$($ctx.Request.RemoteEndPoint.Address)"
  RunQ $cn "INSERT INTO dbo.erp_edit_log(job_no,erp_ref,station,mode,bound,actor,ip,changed_json,erp_status,erp_steps,erp_error,occurred_at) VALUES(@j,@r,@s,@m,@b,@a,@ip,@cj,@st,@stp,@err,SYSDATETIME())" @{ j=$job; r="$($a.erp_ref)"; s="$($a.station)"; m="$($a.mode)"; b="$($a.bound)"; a=$me; ip=$ip; cj=(@($changeRecs)|ConvertTo-Json -Depth 5 -Compress); st=$status; stp=(@($erp.steps)|ConvertTo-Json -Compress); err="$($erp.error)" } | Out-Null
  Audit $me "erp-edit $job [$($changedCodes -join ',')] -> erp:$status$(if($erp.error){' ERR '+$erp.error})"
  @{ ok=$true; changed=@($changedCodes); sent=@($built.sent); status=$status; erp=@{ ok=[bool]$erp.ok; mock=[bool]$erp.mock; rejected=[bool]$erp.rejected; steps=@($erp.steps); error="$($erp.error)" } }
}
# Recompute the checklist rollup from its items (pending A/R lights count; bypass=manual, done=auto). Mutates
# $chk.rollup in place and returns the column values for the UPDATE. Shared by manual Tick and evidence-close so
# both paths stay consistent.
function Update-ChecklistRollup($chk){
  $amber=0;$red=0;$auto=0;$man=0;$nextDue=$null
  foreach($m in @($chk.milestones)){
    $st="$($m.state)"
    if($st -eq 'bypassed'){ $man++ } elseif($st -eq 'done'){ $auto++ }
    elseif($st -eq 'pending'){ if("$($m.light)" -eq 'A'){$amber++} elseif("$($m.light)" -eq 'R'){$red++}
      if($m.due){ $d=[datetime]"$($m.due)"; if(-not $nextDue -or $d -lt $nextDue){ $nextDue=$d } } }
  }
  $worst= if($red){'R'}elseif($amber){'A'}else{'G'}
  $nd=$(if($nextDue){$nextDue.ToString('yyyy-MM-dd')}else{$null})
  $chk.rollup.worst_light=$worst; $chk.rollup.open_amber=$amber; $chk.rollup.open_red=$red
  $chk.rollup.next_due=$nd; $chk.rollup.automation.manual=$man
  @{ worst=$worst; amber=$amber; red=$red; nextDue=$nd; man=$man }
}
# Cached doctype -> milestone map, derived from milestone_evidence_map (admin-editable). An uploaded document of
# type X clears every milestone whose pic_doctype evidence rule matches X for the shipment's bound/module. Built
# once; $script:MsDoctypeMap is reset to $null when an admin edits milestones so changes take effect with no
# restart and no per-request rule parse.
function Get-MilestoneDoctypeMap($cn){
  if($script:MsDoctypeMap){ return $script:MsDoctypeMap }
  $m=@{}
  foreach($r in @(RunQ $cn "SELECT em.match_value doctype, em.milestone_code, em.bound, em.module_match, d.name FROM dbo.milestone_evidence_map em LEFT JOIN dbo.milestone_def d ON d.milestone_code=em.milestone_code AND d.bound=em.bound WHERE em.active=1 AND em.source_kind='pic_doctype' AND NULLIF(em.match_value,'') IS NOT NULL" @{})){
    $dt="$($r.doctype)".Trim(); if(-not $dt){ continue }
    if(-not $m.ContainsKey($dt)){ $m[$dt]=@() }
    $m[$dt]+=@{ code="$($r.milestone_code)".Trim(); name="$($r.name)".Trim(); bound="$($r.bound)".Trim(); module=$(if($null -eq $r.module_match){''}else{"$($r.module_match)".Trim()}) }
  }
  $script:MsDoctypeMap=$m; $m
}
# Mark one or more milestones DONE on a shipment because the operator supplied real proof (a document uploaded to
# the ERP). Mirrors the Tick write path: overlay state='done' on the matched codes, recompute the rollup, persist,
# thread a (silent) evidence note. Returns @{ ok; cleared=@(codes); ... }.
function Close-MilestonesFor($cn,$job,$codes,$basis,$by){
  $want=@(@($codes)|Where-Object{ "$_".Trim() }|ForEach-Object{ "$_".Trim() }|Select-Object -Unique)
  if(-not $want.Count){ return @{ ok=$true; cleared=@() } }
  $row=@(RunQ $cn "SELECT TOP 1 milestone_checklist FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $row.Count){ return @{ ok=$false; error='shipment not found' } }
  $chk=$null; try{ $chk=("$($row[0].milestone_checklist)")|ConvertFrom-Json }catch{}
  if(-not $chk){ return @{ ok=$false; error='no checklist on this shipment' } }
  $cleared=@()
  foreach($m in @($chk.milestones)){
    if($want -contains "$($m.code)" -and "$($m.state)" -ne 'done'){
      $m.state='done'; $m.done_by=$by; $m.done_at=(Get-Date).ToString('o'); $m.light='G'; $m.basis=$basis
      $cleared+="$($m.code)"
    }
  }
  if(-not $cleared.Count){ return @{ ok=$true; cleared=@() } }
  $rr=Update-ChecklistRollup $chk
  RunQ $cn "UPDATE dbo.shipment_alerts SET milestone_checklist=@chk,worst_light=@w,open_amber=@a,open_red=@r,next_due=@nd,manual_done=@m,updated_at=SYSDATETIME() WHERE job_no=@j" @{ chk=($chk|ConvertTo-Json -Depth 8 -Compress); w=$rr.worst; a=$rr.amber; r=$rr.red; nd=$rr.nextDue; m=$rr.man; j=$job } | Out-Null
  $note=[pscustomobject]@{ id=[guid]::NewGuid().ToString(); created=(Get-Date).ToString('o'); user=$by; job_no=$job; milestone_code=($cleared -join ','); kind='evidence'; note=$basis; mentions=@(); status='open'; doneBy=''; doneAt=''; silent=$true }
  Write-Notes (@(Read-Notes) + $note)
  @{ ok=$true; cleared=@($cleared); worst=$rr.worst; openAmber=$rr.amber; openRed=$rr.red; nextDue=$rr.nextDue }
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
  $rr=Update-ChecklistRollup $chk
  $worst=$rr.worst; $amber=$rr.amber; $red=$rr.red; $nd=$rr.nextDue
  RunQ $cn "UPDATE dbo.shipment_alerts SET milestone_checklist=@chk,worst_light=@w,open_amber=@a,open_red=@r,next_due=@nd,manual_done=@m,updated_at=SYSDATETIME() WHERE job_no=@j" @{ chk=($chk|ConvertTo-Json -Depth 8 -Compress); w=$worst; a=$amber; r=$red; nd=$nd; m=$rr.man; j=$job } | Out-Null
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

# ============================================================================================================
#  DRAFT DOCUMENT REVIEW (House BL / HAWB customer agreement loop)
#  Staff create a draft from the shipment snapshot (+ a bounded ERP enrichment read at creation time only),
#  send the customer a tokenized link (/bl-review/<token>, no login), the customer edits the on-screen bill
#  and submits; staff diff/correct/resend until both sides agree, then erp-doc-api.ps1 issues the official
#  document. All state in erpops doc_* tables; every action appended to doc_event_log. Raw tokens are never
#  stored (SHA-256 at rest); every send revokes prior tokens; issue revokes all.
#  Status machine:
#    DRAFT -send-> SENT -submit-> CUSTOMER_SUBMITTED -staff save-> DRAFT (resend v+1)
#                    \-approve-> CUSTOMER_APPROVED -agree-> AGREED -issue-> ISSUED
#    ISSUED -amend(amend_count++, fee)-> AMEND_DRAFT -> (cycle repeats) -> ISSUED
# ============================================================================================================
$DocFieldsPath=Join-Path $Root "doc-fields.json"
function Doc-FieldDefs($type){
  if(-not $script:DocDict){
    $j=[IO.File]::ReadAllText($DocFieldsPath)|ConvertFrom-Json
    $script:DocDict=@{ HBL=@($j.HBL); HAWB=@($j.HAWB) }
  }
  @($script:DocDict[$type])
}
# Resolve a headless browser for print-to-PDF (config 'pdfEngine' override, else Edge/Chrome at the
# standard install paths). Cached; $null when none is installed (auto-PDF then silently skips).
function Resolve-PdfEngine {
  if($script:PdfEngineResolved){ return $script:PdfEngine }
  $script:PdfEngineResolved=$true
  $cands=@()
  $ovr="$($cfg.pdfEngine)".Trim(); if($ovr){ $cands+=$ovr }
  $cands+= (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
           (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
           (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
           (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
  $script:PdfEngine=@($cands | Where-Object { $_ -and (Test-Path $_) })[0]
  $script:PdfEngine
}
# Render the agreed bill to a PDF (base64) with headless Edge/Chrome, reusing the on-screen print layout
# (bl-review.css @media print + bl-form.js). Offline file: page - the dictionary + fields are injected, so
# no auth/fetch is needed. Returns $null on any failure (the issue then proceeds without an attachment).
function Doc-RenderPdf($head,$fields){
  $eng=Resolve-PdfEngine; if(-not $eng){ return $null }
  $htmlPath=$null; $pdfPath=$null
  try{
    $css=[IO.File]::ReadAllText((Join-Path $Root 'bl-review.css'))
    $js =[IO.File]::ReadAllText((Join-Path $Root 'bl-form.js'))
    $dictJson=[IO.File]::ReadAllText($DocFieldsPath)
    $fieldsJson=$fields|ConvertTo-Json -Depth 8 -Compress
    # neutralize any '</script>' breakout inside the injected JSON (valid JSON/JS unicode escapes)
    $bs=[char]92
    $dictJson=$dictJson.Replace('<',"${bs}u003c").Replace('>',"${bs}u003e")
    $fieldsJson=$fieldsJson.Replace('<',"${bs}u003c").Replace('>',"${bs}u003e")
    $type="$($head.doc_type)"
    # concatenation (not an interpolating here-string): css/js may contain '$' that must stay literal
    $html='<!DOCTYPE html><html><head><meta charset="utf-8"><style>'+$css+'</style></head><body><div class="page"><div id="doc"></div></div><script>'+$js+'</script><script>BLForm.setDict('+$dictJson+');BLForm.render(document.getElementById("doc"),"'+$type+'",'+$fieldsJson+',{editable:false});BLForm.setPrintSize("A4");</script></body></html>'
    $base=Join-Path ([IO.Path]::GetTempPath()) ('docpdf-'+[guid]::NewGuid().ToString('N'))
    $htmlPath="$base.html"; $pdfPath="$base.pdf"
    [IO.File]::WriteAllText($htmlPath,$html,(New-Object System.Text.UTF8Encoding($false)))
    $uri=([Uri]$htmlPath).AbsoluteUri
    $a=@('--headless=new','--disable-gpu','--no-sandbox','--no-pdf-header-footer','--virtual-time-budget=3000',"--print-to-pdf=$pdfPath",$uri)
    Start-Process -FilePath $eng -ArgumentList $a -NoNewWindow -PassThru -Wait | Out-Null
    if(Test-Path $pdfPath){ $bytes=[IO.File]::ReadAllBytes($pdfPath); if($bytes.Length -gt 100){ return [Convert]::ToBase64String($bytes) } }
    $null
  }catch{ $null }
  finally{ foreach($f in @($htmlPath,$pdfPath)){ if($f){ Remove-Item $f -ErrorAction SilentlyContinue } } }
}
function New-RawToken {
  $b=New-Object byte[] 32
  $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create()
  try{ $rng.GetBytes($b) } finally { $rng.Dispose() }
  ([Convert]::ToBase64String($b)).Replace('+','-').Replace('/','_').TrimEnd('=')   # base64url, 43 chars
}
function Token-Hash($raw){
  $sha=[System.Security.Cryptography.SHA256]::Create()
  try{ ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$raw")) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $sha.Dispose() }
}
function Doc-Event($cn,$docId,$ver,$evt,$actor,$tokenHash,$ip,$detail){
  RunQ $cn "INSERT INTO dbo.doc_event_log(doc_id,version_no,event,actor,token_hash,ip,detail,occurred_at) VALUES(@d,@v,@e,@a,@t,@i,@x,SYSDATETIME())" @{ d="$docId"; v=$ver; e="$evt"; a="$actor"; t=$tokenHash; i="$ip"; x=$detail } | Out-Null
}
# Whitelist + clamp incoming fields against the dictionary: ONLY known codes survive, each capped to maxlen.
# kind 'table' (container grid) / 'riders' (attachment pages) values are arrays of row objects: every row is
# REBUILT in dictionary column order (unknown keys dropped, per-cell maxlen clamp, all-blank rows removed,
# capped at maxRows) so the serialized JSON is canonical and diffs stay stable across save/parse round trips.
# Accepts a hashtable (server seed) or PSCustomObject (client JSON). Returns an ordered PSCustomObject.
function Doc-CleanStr($v,$maxlen){
  $s=''; if($null -ne $v){ $s="$v" }
  $s=$s.Replace("`r`n","`n").Replace("`r","`n")
  $ml=0; [void][int]::TryParse("$maxlen",[ref]$ml)
  if($ml -gt 0 -and $s.Length -gt $ml){ $s=$s.Substring(0,$ml) }
  $s
}
function Doc-CleanFields($type,$src){
  $o=[ordered]@{}
  foreach($f in (Doc-FieldDefs $type)){
    $c="$($f.code)"
    $raw=$null
    if($src -is [hashtable]){ if($src.ContainsKey($c)){ $raw=$src[$c] } }
    elseif($src -and $src.PSObject.Properties[$c]){ $raw=$src.$c }
    if("$($f.kind)" -in 'table','riders'){
      $maxR=10; [void][int]::TryParse("$($f.maxRows)",[ref]$maxR); if($maxR -lt 1){ $maxR=10 }
      $rows=@()
      foreach($r in @($raw)){
        if($null -eq $r -or $r -is [string]){ continue }   # legacy/garbage value -> skipped, never crashes
        $row=[ordered]@{}
        foreach($col in @($f.columns)){
          $cc="$($col.code)"; $cv=$null
          if($r -is [hashtable]){ if($r.ContainsKey($cc)){ $cv=$r[$cc] } }
          elseif($r.PSObject.Properties[$cc]){ $cv=$r.$cc }
          $row[$cc]=Doc-CleanStr $cv $col.maxlen
        }
        $blank=$true; foreach($k in $row.Keys){ if("$($row[$k])".Trim()){ $blank=$false; break } }
        if(-not $blank){ $rows+=,$row }
        if($rows.Count -ge $maxR){ break }
      }
      $o[$c]=@($rows)
    } else {
      $o[$c]=Doc-CleanStr $raw $f.maxlen
    }
  }
  [pscustomobject]$o
}
# canonical comparable string for a field value: strings as-is, structured values as compact JSON.
# NB: -InputObject (not pipeline) - piping a 1-row array to ConvertTo-Json unrolls it to a bare object.
function Doc-ValStr($v){
  if($null -eq $v){ return '' }
  if($v -is [string]){ return $v }
  ConvertTo-Json -InputObject $v -Depth 6 -Compress
}
# Field codes whose value differs between an old snapshot (JSON string) and a cleaned new object.
# EMITS items (no comma-wrap) - call sites collect with @(Doc-Changed ...). A `,@()` return here +
# @() at the call site double-wraps: Count is then always 1 and ConvertTo-Json nests the array.
function Doc-Changed($oldJson,$newObj){
  $old=$null; try{ $old="$oldJson"|ConvertFrom-Json }catch{}
  foreach($p in $newObj.PSObject.Properties){
    $ov=$null; if($old -and $old.PSObject.Properties[$p.Name]){ $ov=$old.($p.Name) }
    if((Doc-ValStr $ov) -ne (Doc-ValStr $p.Value)){ $p.Name }
  }
}
function Get-DocHead($cn,$docId){
  $r=@(RunQ $cn "SELECT TOP 1 doc_id,job_no,doc_type,station,mode,bound,status,current_version,customer_email,customer_name,erp_doc_no,CONVERT(varchar(19),issued_at,120) issued_at,amend_count,created_by,CONVERT(varchar(19),created_at,120) created_at,CONVERT(varchar(19),updated_at,120) updated_at FROM dbo.doc_draft WHERE doc_id=@d" @{ d="$docId" })
  if(-not $r.Count){ return $null }
  if(-not (Test-JobScope $r[0])){ return $null }   # out-of-scope = 'not found' (no existence oracle)
  $r[0]
}
function Doc-HeadProj($cn,$h){
  $tok=@(RunQ $cn "SELECT TOP 1 customer_email,customer_name,CONVERT(varchar(16),expires_at,120) expires_at,view_count,CONVERT(varchar(16),last_view_at,120) last_view_at FROM dbo.doc_review_token WHERE doc_id=@d AND revoked=0 AND expires_at>SYSDATETIME() ORDER BY created_at DESC" @{ d="$($h.doc_id)" })
  $t=$null
  if($tok.Count){ $t=@{ customerEmail=[string]$tok[0].customer_email; customerName=[string]$tok[0].customer_name; expiresAt=[string]$tok[0].expires_at; viewCount=[int]$tok[0].view_count; lastViewAt=[string]$tok[0].last_view_at } }
  [pscustomobject]@{ docId=[string]$h.doc_id; jobNo=[string]$h.job_no; docType=[string]$h.doc_type; station=[string]$h.station
    status=[string]$h.status; currentVersion=[int]$h.current_version; customerEmail=[string]$h.customer_email; customerName=[string]$h.customer_name
    erpDocNo=[string]$h.erp_doc_no; issuedAt=[string]$h.issued_at; amendCount=[int]$h.amend_count
    createdBy=[string]$h.created_by; createdAt=[string]$h.created_at; updatedAt=[string]$h.updated_at; activeToken=$t }
}
# the 'back to editing' status: plain DRAFT before first issue, AMEND_DRAFT once an amendment cycle started
function Doc-DraftState($h){ if([int]$h.amend_count -gt 0){ 'AMEND_DRAFT' } else { 'DRAFT' } }

# seed from the erpops shipment snapshot (always available; no ERP touch)
function Doc-SaSeed($a,$type){
  $f=@{}
  if($type -eq 'HBL'){
    $f['hbl_no']="$($a.house_bill)"; $f['shipper']="$($a.shipper_name)"; $f['consignee']="$($a.consignee_name)"
    $f['export_refs']="$($a.cust_ref)"; $f['vessel_voyage']="$($a.vessel_voyage)"
    $f['port_of_loading']="$($a.pol)"; $f['port_of_discharge']="$($a.pod)"
    $f['freight_terms']="$($a.incoterm)"; $f['date_of_issue']=(Today-Str)
    if("$($a.total_weight)".Trim()){ $f['gross_weight']="$($a.total_weight)".Trim()+' KGS' }
    if("$($a.total_cbm)".Trim()){ $f['measurement']="$($a.total_cbm)".Trim()+' CBM' }
    if("$($a.container_no)".Trim()){ $f['containers']=@(@{ container_no="$($a.container_no)".Trim() }) }   # fallback row; ERP seed replaces with the full blcont detail
    if("$($a.commodity)".Trim()){ $f['description']="$($a.commodity)".Trim() }
  } else {
    $f['hawb_no']="$($a.house_bill)"; $f['mawb_no']="$($a.master_bill)"
    $f['shipper']="$($a.shipper_name)"; $f['consignee']="$($a.consignee_name)"
    $f['airport_departure']="$($a.pol)"; $f['airport_destination']="$($a.pod)"
    $f['routing_to1']="$($a.pod)"; $f['executed_date']=(Today-Str)
    if("$($a.total_weight)".Trim()){ $f['gross_weight']="$($a.total_weight)".Trim() }
    if("$($a.commodity)".Trim()){ $f['nature_quantity_goods']="$($a.commodity)".Trim() }
  }
  $f
}
# party box text: name on the first line, then the address lines (Split-PartyBox in erp-doc-api.ps1
# reads it back the same way: first line = partyName, rest = address). Skips blanks and an address
# line that just repeats the name.
function Doc-PartyText($name,$adds){
  $ls=@(); $nv="$name".Trim(); if($nv){ $ls+=$nv }
  foreach($x in @($adds)){ $xv="$x".Trim(); if($xv -and $xv -ne $nv){ $ls+=$xv } }
  ($ls -join "`n")
}
# Carrier code from a flight number: the leading alpha prefix (e.g. 'SQ' from 'SQ7861'). awbhead.carr is
# usually blank in these copies, so the AWB 'By Carrier' code falls back to the flight's prefix.
function Awb-CarrierFromFlight($flight){
  $fl="$flight".Trim(); if(-not $fl){ return '' }
  $m=[regex]::Match($fl,'^[A-Za-z]+'); if($m.Success){ $m.Value.ToUpper() } else { '' }
}
# customer-master lookup (custsub): code -> "name\naddress" using the documentation English block,
# falling back to the mailing block. Returns '' when the code/table is absent (seed stays blank).
function Doc-CustLookup($srcCn,$db,$code){
  $code="$code".Trim(); if(-not $code){ return '' }
  $cols=Get-ErpCols $srcCn $db 'custsub' 'code,doc_e_name,doc_e_add1,doc_e_add2,doc_e_add3,doc_e_add4,doc_e_add5,mal_e_name,mal_e_add1,mal_e_add2,mal_e_add3,mal_e_add4,mal_e_add5' @()
  if(-not $cols){ return '' }
  $r=@(RunQ $srcCn "SELECT TOP 1 $cols FROM dbo.custsub WHERE code=@c" @{ c=$code } 8)
  if(-not $r.Count){ return '' }
  $b=$r[0]
  $t=Doc-PartyText $b.doc_e_name @($b.doc_e_add1,$b.doc_e_add2,$b.doc_e_add3,$b.doc_e_add4,$b.doc_e_add5)
  if(-not $t){ $t=Doc-PartyText $b.mal_e_name @($b.mal_e_add1,$b.mal_e_add2,$b.mal_e_add3,$b.mal_e_add4,$b.mal_e_add5) }
  $t
}
# Own issuing/forwarding office for a station = fm3kco.site dbname->owncode, resolved via custsub then a latest
# blhead agnt_* fallback. It's IDENTICAL for every draft of a station and stable over time, so resolve it at most
# once per server lifetime (PERF: removes 1-3 ERP round-trips from every draft create after the first; also
# stops the dev path - where fm3kco is absent - from paying 3 failing round-trips each time). Empty is cached too
# (a deployment-stable "can't resolve"); a server restart re-resolves if the office is set up later.
# The bare owncode for a station (e.g. S0001 = HKG), from fm3kco.site dbname->owncode. This is the ERP's
# forwarderPartyCode / forwarderCode: which office a booking belongs to (the "where the data goes" key for
# /booking/update + /booking/get). Cached per db (stable per station); empty cached too. Distinct from
# Get-OwnOfficeAgent, which resolves the same owncode into a full name+address party block.
$script:OwnCodeByDb=@{}
function Get-StationOwnCode($srcCn,$db){
  if($script:OwnCodeByDb.ContainsKey($db)){ return $script:OwnCodeByDb[$db] }
  $oc=''
  try{ $r=@(RunQ $srcCn "SELECT TOP 1 owncode FROM fm3kco.dbo.site WHERE dbname=@d" @{ d=$db } 8); if($r.Count){ $oc="$($r[0].owncode)".Trim() } }catch{}
  $script:OwnCodeByDb[$db]=$oc
  $oc
}
# The ERP forwarderCode (= office owncode, "where the data goes") for a station, NOT hard-coded: resolve the
# station's real owncode from fm3kco.site. Cache-first (Get-StationOwnCode); opens one short source connection
# only on a cache miss. Falls back to erp-api-map.json forwarderCode when the owncode can't be resolved (e.g.
# fm3kco absent / station not mapped). Used by every /file/* + /booking/* call so each routes to its own office.
function Resolve-ForwarderCode($station){
  $fallback="$((Get-ErpApiMap).forwarderCode)".Trim()
  $db=$DbByStation["$station".Trim().ToUpper()]
  if(-not $db){ return $fallback }
  if(-not $script:OwnCodeByDb.ContainsKey($db)){
    $srcCn=New-Object System.Data.SqlClient.SqlConnection "Server=$server;Database=$db;$SrcAuthClause;TrustServerCertificate=True;Connect Timeout=15;Packet Size=512"
    try{ $srcCn.Open(); [void](Get-StationOwnCode $srcCn $db) }catch{}finally{ try{ $srcCn.Close() }catch{} }
  }
  $oc="$($script:OwnCodeByDb[$db])".Trim()
  if($oc){ $oc } else { $fallback }
}
function Get-OwnOfficeAgent($srcCn,$db){
  if($script:OwnAgentByDb.ContainsKey($db)){ return $script:OwnAgentByDb[$db] }
  $own=''
  try{
    $oc=@(RunQ $srcCn "SELECT TOP 1 owncode FROM fm3kco.dbo.site WHERE dbname=@d" @{ d=$db } 8)
    if($oc.Count -and "$($oc[0].owncode)".Trim()){
      $ocv="$($oc[0].owncode)".Trim()
      $own=Doc-CustLookup $srcCn $db $ocv
      if(-not $own){
        $ob=@(RunQ $srcCn "SELECT TOP 1 agnt_name,agnt_add1,agnt_add2,agnt_add3,agnt_add4,agnt_add5 FROM dbo.blhead WHERE agn2_code=@c AND LTRIM(RTRIM(ISNULL(agnt_name,'')))<>'' ORDER BY ref DESC" @{ c=$ocv } 8)
        if($ob.Count){ $own=Doc-PartyText $ob[0].agnt_name @($ob[0].agnt_add1,$ob[0].agnt_add2,$ob[0].agnt_add3,$ob[0].agnt_add4,$ob[0].agnt_add5) }
      }
    }
  }catch{}
  $script:OwnAgentByDb[$db]=$own
  $own
}
# Best-effort ERP enrichment at DRAFT-CREATION time only (staff click; never on a customer request path).
# Same bounded pattern as Handle-ErpDetail: keyed seek, Connect Timeout=15, CommandTimeout=8, Packet Size=512.
# Returns '' on success or a note string; failure leaves the affected boxes on their snapshot/blank values.
function Doc-ErpSeed($a,$f){
  $db=$DbByStation["$($a.station)".Trim().ToUpper()]; if(-not $db){ return "no ERP database mapped for station $($a.station)" }
  $key="$($a.erp_ref)".Trim(); if(-not $key){ return 'no erp_ref on the snapshot' }
  $isAir=("$($a.mode)" -eq 'Air')
  $srcCn=New-Object System.Data.SqlClient.SqlConnection "Server=$server;Database=$db;$SrcAuthClause;TrustServerCertificate=True;Connect Timeout=15;Packet Size=512"
  try{
    $srcCn.Open()
    if($isAir){
      $cols=Get-ErpCols $srcCn $db 'awbhead' 'pol_name,pod_name,pod,dest,dest_name,to1,to1_name,deli,deli_name,to3,to3_name,flight1,flight2,flight3,f_date1,f_date2,f_date3,carr,iatacode,currency,frt_terms,oth_terms,v_carriage,v_customs,v_insurance,t_book_qty,t_rece_qty,t_book_wgt,ttl_cwt,wgt_unit,not_show_dim,commodity,handling,special_remark,shpr_name,shpr_add1,shpr_add2,shpr_add3,shpr_add4,shpr_add5,cgne_name,cgne_add1,cgne_add2,cgne_add3,cgne_add4,cgne_add5,agnt_name,agnt_add1,agnt_add2,agnt_add3,agnt_add4,agnt_add5,not1_name,not1_add1,not1_add2,not1_add3,not1_add4,not1_add5,issu_at' @('special_remark','commodity','handling')
      $hdr=@(); if($cols){ $hdr=@(RunQ $srcCn "SELECT TOP 1 $cols FROM dbo.awbhead WHERE ref=@k" @{ k=$key } 8) }
      if($hdr.Count){
        $b=$hdr[0]
        if("$($b.pol_name)".Trim()){ $f['airport_departure']="$($b.pol_name)".Trim() }
        # Airport of Destination = FINAL destination (dest_name), not the discharge/transfer (pod_name)
        $adest="$($b.dest_name)".Trim(); if(-not $adest){ $adest="$($b.pod_name)".Trim() }
        if($adest){ $f['airport_destination']=$adest }
        # party boxes print name + FULL address (awbhead carries the printed blocks denormalized)
        $stx=Doc-PartyText $b.shpr_name @($b.shpr_add1,$b.shpr_add2,$b.shpr_add3,$b.shpr_add4,$b.shpr_add5)
        if($stx){ $f['shipper']=$stx }
        $ctx=Doc-PartyText $b.cgne_name @($b.cgne_add1,$b.cgne_add2,$b.cgne_add3,$b.cgne_add4,$b.cgne_add5)
        if($ctx){ $f['consignee']=$ctx }
        # Destination Agent (awbhead agnt_* block) -> prints inside Accounting Information. The Issuing
        # Carrier's Agent box is OUR own office, set by the fm3kco.site owncode lookup below (blank if it
        # can't resolve - never the destination agent).
        $atx=Doc-PartyText $b.agnt_name @($b.agnt_add1,$b.agnt_add2,$b.agnt_add3,$b.agnt_add4,$b.agnt_add5)
        if("$($b.issu_at)".Trim()){ $f['executed_place']="$($b.issu_at)".Trim() }
        # Notify Party -> its own box under Consignee
        $ntx=Doc-PartyText $b.not1_name @($b.not1_add1,$b.not1_add2,$b.not1_add3,$b.not1_add4,$b.not1_add5)
        if($ntx){ $f['notify']=$ntx }
        # Accounting Information: freight payment term + Destination Agent
        $ftv="$($b.frt_terms)".Trim().ToUpper()
        $acc=@(); if($ftv){ $acc+= if($ftv -eq 'PP'){ 'FREIGHT PREPAID' } else { 'FREIGHT COLLECT' } }
        if($atx){ if($acc.Count){ $acc+='' }; $acc+='DESTINATION AGENT:'; $acc+=$atx }
        if($acc.Count){ $f['accounting_info']=($acc -join "`n") }
        if("$($b.iatacode)".Trim()){ $f['agent_iata_code']="$($b.iatacode)".Trim() }
        # freight currency + CHGS code (= freight term) + WT/VAL & Other prepaid/collect X marks
        if("$($b.currency)".Trim()){ $f['currency']="$($b.currency)".Trim() }
        if($ftv){ $f['chgs_code']=$ftv; if($ftv -eq 'PP'){ $f['wtval_ppd']='X' } else { $f['wtval_coll']='X' } }
        $otv="$($b.oth_terms)".Trim().ToUpper()
        if($otv -eq 'PP'){ $f['other_ppd']='X' } elseif($otv){ $f['other_coll']='X' }
        # declared values + amount of insurance (text fields; blank/0 insurance prints NIL)
        if("$($b.v_carriage)".Trim()){ $f['declared_value_carriage']="$($b.v_carriage)".Trim() }
        if("$($b.v_customs)".Trim()){ $f['declared_value_customs']="$($b.v_customs)".Trim() }
        $vi="$($b.v_insurance)".Trim(); $f['amount_of_insurance']= if($vi -and $vi -ne '0'){ $vi } else { 'NIL' }
        # routing strip To points = the routing legs to1 / deli / to3 (codes); By carriers = carr or the
        # flightN alpha prefix. The intermediate leg code is awbhead.deli (e.g. CHI); 'NUL'/blank = skipped.
        $to1="$($b.to1)".Trim(); if(-not $to1){ $to1="$($b.pod)".Trim() }
        if($to1){ $f['routing_to1']=$to1 }
        $deliC="$($b.deli)".Trim()
        if($deliC -and $deliC.ToUpper() -notin 'NUL','NULL'){ $f['routing_to2']=$deliC }
        $to3="$($b.to3)".Trim(); if($to3 -and $to3.ToUpper() -notin 'NUL','NULL'){ $f['routing_to3']=$to3 }
        $carr1="$($b.carr)".Trim(); if(-not $carr1){ $carr1=Awb-CarrierFromFlight $b.flight1 }
        if($carr1){ $f['routing_by1']=$carr1 }
        $c2=Awb-CarrierFromFlight $b.flight2; if($c2){ $f['routing_by2']=$c2 }
        $c3=Awb-CarrierFromFlight $b.flight3; if($c3){ $f['routing_by3']=$c3 }
        # Flight / Date box: flight1..3 with their dates, one per line
        $pairs=@(); $pairs+=,@($b.flight1,$b.f_date1); $pairs+=,@($b.flight2,$b.f_date2); $pairs+=,@($b.flight3,$b.f_date3)
        $fld=@()
        foreach($pr in $pairs){
          $fn="$($pr[0])".Trim(); if(-not $fn){ continue }
          $dt=''; if($pr[1]){ try{ $dt=([datetime]$pr[1]).ToString('yyyy-MM-dd') }catch{} }
          $fld+= if($dt){ "$fn / $dt" } else { $fn }
        }
        if($fld.Count){ $f['flight_date']=($fld -join "`n") }
        # No. of Pieces: booked qty, falling back to received qty (t_book_qty is often blank)
        $pcs="$($b.t_book_qty)".Trim(); if(-not $pcs -or $pcs -eq '0'){ $pcs="$($b.t_rece_qty)".Trim() }
        if($pcs -and $pcs -ne '0'){ $f['pieces']=$pcs }
        if("$($b.t_book_wgt)".Trim()){ $f['gross_weight']="$($b.t_book_wgt)".Trim() }
        if("$($b.ttl_cwt)".Trim()){ $f['chargeable_weight']="$($b.ttl_cwt)".Trim() }
        # kg/lb = weight-unit initial (KGS -> K, LBS -> L)
        $wu="$($b.wgt_unit)".Trim().ToUpper(); if($wu){ $f['kg_lb']=$wu.Substring(0,1) }
        # Handling Information = awbhead.handling, falling back to special_remark
        $hand="$($b.handling)".Trim(); if(-not $hand){ $hand="$($b.special_remark)".Trim() }
        if($hand){ $f['handling_info']=$hand }
        # Issuing Carrier's Agent = own office (cached per station; mode-independent). Blank if it can't resolve.
        $own=Get-OwnOfficeAgent $srcCn $db; if($own){ $f['issuing_carrier_agent']=$own }
      }
      # line items: Marks and Numbers = mark2; goods description = the FULL goods text desc2 (good_desc2 is
      # the short commodity summary); dimensions = dimension (L x W x H x Qty) unless suppressed (not_show_dim)
      $items=@(RunQ $srcCn "SELECT TOP 20 item_seq, CONVERT(nvarchar(2000),mark2) AS mk, CONVERT(nvarchar(2000),desc2) AS d2, CONVERT(nvarchar(2000),good_desc2) AS gd2, CONVERT(nvarchar(400),dimension) AS dim FROM dbo.awbdetl WHERE blh=@r ORDER BY item_seq" @{ r=$key } 8)
      $marks=@(); $goods=@(); $dims=@()
      foreach($it in $items){
        $mv="$($it.mk)".Trim(); if($mv -and $marks -notcontains $mv){ $marks+=$mv }
        $gv="$($it.d2)".Trim(); if(-not $gv){ $gv="$($it.gd2)".Trim() }
        if($gv -and $goods -notcontains $gv){ $goods+=$gv }
        $dv="$($it.dim)".Trim(); if($dv -and $dims -notcontains $dv){ $dims+=$dv }
      }
      if($marks.Count){ $f['marks_numbers']=($marks -join "`n") }
      if(-not $goods.Count -and $b -and "$($b.commodity)".Trim()){ $goods=@("$($b.commodity)".Trim()) }   # header commodity last resort
      if($goods.Count){ $f['nature_quantity_goods']=($goods -join "`n") }
      $showDim=$true; if($b -and $b.PSObject.Properties['not_show_dim']){ try{ $showDim = -not [bool]$b.not_show_dim }catch{} }
      if($showDim -and $dims.Count){ $f['dimensions']=($dims -join "`n") }
    } else {
      $cols=Get-ErpCols $srcCn $db 'blhead' 'pol_name,pod_name,deli_name,dest_name,t_book_qty,t_book_wgt,t_book_cbm,no_orig,telex_rel,frt_terms,shpr_name,shpr_add1,shpr_add2,shpr_add3,shpr_add4,shpr_add5,cgne_name,cgne_add1,cgne_add2,cgne_add3,cgne_add4,cgne_add5,not1_name,not1_add1,not1_add2,not1_add3,not1_add4,not1_add5,carr_name,rece_name,issu_at,payable_at,agn2_code,agnt_name,agnt_add1,agnt_add2,agnt_add3,agnt_add4,agnt_add5' @()
      $hdr=@(); if($cols){ $hdr=@(RunQ $srcCn "SELECT TOP 1 $cols FROM dbo.blhead WHERE ref=@k" @{ k=$key } 8) }
      if($hdr.Count){
        $b=$hdr[0]
        if("$($b.pol_name)".Trim()){ $f['port_of_loading']="$($b.pol_name)".Trim() }
        if("$($b.pod_name)".Trim()){ $f['port_of_discharge']="$($b.pod_name)".Trim() }
        if("$($b.deli_name)".Trim()){ $f['place_of_delivery']="$($b.deli_name)".Trim() }
        if("$($b.dest_name)".Trim()){ $f['final_destination']="$($b.dest_name)".Trim() }
        if("$($b.t_book_qty)".Trim()){ $f['num_pkgs']="$($b.t_book_qty)".Trim() }
        if("$($b.t_book_wgt)".Trim()){ $f['gross_weight']="$($b.t_book_wgt)".Trim()+' KGS' }
        if("$($b.t_book_cbm)".Trim()){ $f['measurement']="$($b.t_book_cbm)".Trim()+' CBM' }
        # GUARDRAIL: telex release means NO original B/L is issued -> the box must say 0
        $telex=$false; if($b.PSObject.Properties['telex_rel']){ try{ $telex=[bool]$b.telex_rel }catch{} }
        if($telex){ $f['num_originals']='0' }
        elseif("$($b.no_orig)".Trim()){ $f['num_originals']="$($b.no_orig)".Trim() }
        # freight terms presentation: PP -> FREIGHT PREPAID, else FREIGHT COLLECT, incoterm bracketed.
        # PRESENTATION-ONLY box: the user may erase the incoterm part; the ERP value is never written back.
        $ftv="$($b.frt_terms)".Trim().ToUpper()
        if($ftv){
          $ft= if($ftv -eq 'PP'){ 'FREIGHT PREPAID' } else { 'FREIGHT COLLECT' }
          $inco="$($a.incoterm)".Trim()
          $f['freight_terms']= if($inco){ "$ft ($inco)" } else { $ft }
        }
        # party boxes print name + FULL address (where the cargo comes from / delivers to) - blhead
        # carries each printed block denormalized: shpr_/cgne_/not1_/agnt_ name+add1..5
        $stx=Doc-PartyText $b.shpr_name @($b.shpr_add1,$b.shpr_add2,$b.shpr_add3,$b.shpr_add4,$b.shpr_add5)
        if($stx){ $f['shipper']=$stx }
        $ctx=Doc-PartyText $b.cgne_name @($b.cgne_add1,$b.cgne_add2,$b.cgne_add3,$b.cgne_add4,$b.cgne_add5)
        if($ctx){ $f['consignee']=$ctx }
        $ntx=Doc-PartyText $b.not1_name @($b.not1_add1,$b.not1_add2,$b.not1_add3,$b.not1_add4,$b.not1_add5)
        if($ntx){ $f['notify']=$ntx }
        if("$($b.carr_name)".Trim()){ $f['precarriage_by']="$($b.carr_name)".Trim() }
        if("$($b.rece_name)".Trim()){ $f['place_of_receipt']="$($b.rece_name)".Trim() }
        if("$($b.issu_at)".Trim()){ $f['place_of_issue']="$($b.issu_at)".Trim() }
        if("$($b.payable_at)".Trim()){ $f['freight_payable_at']="$($b.payable_at)".Trim() }
        # delivery agent: the blhead agent block (agnt_*) prints on the bill; fall back to the
        # customer-master record of agn2_code when the block is blank
        $datx=Doc-PartyText $b.agnt_name @($b.agnt_add1,$b.agnt_add2,$b.agnt_add3,$b.agnt_add4,$b.agnt_add5)
        if(-not $datx){ $datx=Doc-CustLookup $srcCn $db $b.agn2_code }
        if($datx){ $f['delivery_agent']=$datx }
      }
      # forwarding agent = OUR issuing office (cached per station; see Get-OwnOfficeAgent). fm3kco maps this
      # station db -> owncode -> custsub, falling back to the latest blhead agnt_* of the own office. fm3kco is
      # absent on the local dev server, so this leaves the box blank there (cached as empty after one attempt).
      $own=Get-OwnOfficeAgent $srcCn $db; if($own){ $f['forwarding_agent']=$own }
      # marks + description: blitem good_desc1 is often blank - the real text lives in the ntext pair
      # mark2/desc2 (mark3/desc3 = continuation). When the joined text overflows its on-bill box, the
      # FULL text seeds attachment/rider page 1 and the box prints the standard pointer instead.
      $icols=Get-ErpCols $srcCn $db 'blitem' 'item_seq,good_desc1,mark2,desc2,mark3,desc3' @('mark2','desc2','mark3','desc3')
      $items=@(); if($icols){ $items=@(RunQ $srcCn "SELECT TOP 10 $icols FROM dbo.blitem WHERE blh=@r ORDER BY item_seq" @{ r=$key } 8) }
      $marks=@(); $descs=@()
      foreach($it in $items){
        $mv=("$($it.mark2)".Trim()+"`n"+"$($it.mark3)".Trim()).Trim(); if($mv -and $marks -notcontains $mv){ $marks+=$mv }
        $dv="$($it.good_desc1)".Trim(); if(-not $dv){ $dv="$($it.desc2)".Trim() }
        $d3="$($it.desc3)".Trim(); if($d3){ $dv=("$dv`n$d3").Trim() }
        if($dv -and $descs -notcontains $dv){ $descs+=$dv }
      }
      $mtx=($marks -join "`n"); $dtx=($descs -join "`n")
      $mMax=1000; $dMax=2000   # box maxlens; read from the dictionary so a doc-fields.json change carries over
      foreach($dd in @(Doc-FieldDefs 'HBL')){
        if("$($dd.code)" -eq 'marks_numbers' -and $dd.maxlen){ $mMax=[int]$dd.maxlen }
        if("$($dd.code)" -eq 'description' -and $dd.maxlen){ $dMax=[int]$dd.maxlen }
      }
      # overflow moves marks AND description TOGETHER (their lines belong side by side on the rider);
      # the pointer prints in the Description box only - the Marks box goes blank, else the words
      # 'AS PER ATTACHED SHEET' would print twice side by side
      if(($mtx -and $mtx.Length -gt $mMax) -or ($dtx -and $dtx.Length -gt $dMax)){
        $pg=@{}
        if($mtx){ $pg['marks']=$mtx }
        if($dtx){ $pg['description']=$dtx }
        $f['marks_numbers']=''
        $f['description']='AS PER ATTACHED SHEET'
        $f['rider_pages']=@($pg)
      } else {
        if($mtx){ $f['marks_numbers']=$mtx }
        if($dtx){ $f['description']=$dtx }
      }
      # structured container particulars (table field 'containers'); columns guarded per station schema
      $ccols=Get-ErpCols $srcCn $db 'blcont' 'container,seal,cont_type,load_qty,pkgs_unit,load_wgt,load_cbm' @()
      $cont=@(); if($ccols){ $cont=@(RunQ $srcCn "SELECT TOP 50 $ccols FROM dbo.blcont WHERE blh=@r ORDER BY container" @{ r=$key } 8) }
      $crows=@()
      foreach($cr in $cont){
        $row=@{}
        $row['container_no']= if($cr.PSObject.Properties['container']){ "$($cr.container)".Trim() } else { '' }
        $row['seal_no']=      if($cr.PSObject.Properties['seal']){ "$($cr.seal)".Trim() } else { '' }
        $row['cont_type']=    if($cr.PSObject.Properties['cont_type']){ "$($cr.cont_type)".Trim() } else { '' }
        $row['qty']=          if($cr.PSObject.Properties['load_qty']){ "$($cr.load_qty)".Trim() } else { '' }
        $row['qty_unit']=     if($cr.PSObject.Properties['pkgs_unit']){ "$($cr.pkgs_unit)".Trim() } else { '' }
        $row['weight_kgs']=   if($cr.PSObject.Properties['load_wgt']){ "$($cr.load_wgt)".Trim() } else { '' }
        $row['cbm']=          if($cr.PSObject.Properties['load_cbm']){ "$($cr.load_cbm)".Trim() } else { '' }
        $hasAny=$false; foreach($k in $row.Keys){ if($row[$k]){ $hasAny=$true; break } }
        if($hasAny){ $crows+=,$row }
      }
      if($crows.Count){ $f['containers']=@($crows) }
    }
    ''
  }catch{ "ERP enrichment skipped: $($_.Exception.Message)" } finally{ try{ $srcCn.Close() }catch{} }
}

# ---- staff handlers (session-gated; routed inside the $cn switch) ----
function Handle-DocList($cn,$qs){
  $job="$($qs['job'])".Trim(); if(-not $job){ return @{error='job required'} }
  $rows=@(RunQ $cn "SELECT doc_id,job_no,doc_type,station,mode,bound,status,current_version,customer_email,customer_name,erp_doc_no,CONVERT(varchar(19),issued_at,120) issued_at,amend_count,created_by,CONVERT(varchar(19),created_at,120) created_at,CONVERT(varchar(19),updated_at,120) updated_at FROM dbo.doc_draft WHERE job_no=@j ORDER BY doc_type" @{ j=$job })
  $rows=@($rows|Where-Object{ Test-JobScope $_ })
  @{ jobNo=$job; docs=@($rows|ForEach-Object{ Doc-HeadProj $cn $_ }) }
}
function Save-DocCreate($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.job_no){ return @{error='invalid payload'} }
  $job="$($j.job_no)".Trim()
  $a=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound,erp_ref,house_bill,master_bill,shipper_name,consignee_name,vessel_voyage,incoterm,cust_ref,pol,pod,CONVERT(varchar(20),total_weight) total_weight,CONVERT(varchar(20),total_cbm) total_cbm,container_no,route_summary,commodity FROM dbo.shipment_alerts WHERE job_no=@j" @{ j=$job })
  if(-not $a.Count){ return @{error='not found'} }
  if(-not (Test-JobScope $a[0])){ return @{error='not found'} }
  $a=$a[0]
  $type= if("$($a.mode)" -eq 'Air'){ 'HAWB' } else { 'HBL' }   # doc type follows the shipment mode
  if($j.doc_type -and "$($j.doc_type)" -ne $type){ return @{error="this $($a.mode) shipment takes a $type document"} }
  $dup=@(RunQ $cn "SELECT TOP 1 doc_id FROM dbo.doc_draft WHERE job_no=@j AND doc_type=@t" @{ j=$job; t=$type })
  if($dup.Count){ return @{error='document already exists for this shipment'; docId=[string]$dup[0].doc_id} }
  $f=Doc-SaSeed $a $type
  $seedNote=Doc-ErpSeed $a $f
  $clean=Doc-CleanFields $type $f
  $fjson=$clean|ConvertTo-Json -Depth 6 -Compress
  $docId=[guid]::NewGuid().ToString()
  RunQ $cn "INSERT INTO dbo.doc_draft(doc_id,job_no,doc_type,station,mode,bound,status,current_version,created_by,created_at,updated_at) VALUES(@d,@j,@t,@s,@m,@b,'DRAFT',1,@u,SYSDATETIME(),SYSDATETIME())" @{ d=$docId; j=$job; t=$type; s="$($a.station)"; m="$($a.mode)"; b="$($a.bound)"; u=$me } | Out-Null
  RunQ $cn "INSERT INTO dbo.doc_version(doc_id,version_no,side,base_version,fields,comment,created_by,created_at) VALUES(@d,1,'staff',NULL,@f,@c,@u,SYSDATETIME())" @{ d=$docId; f=$fjson; c=$(if($seedNote){"seeded from shipment snapshot ($seedNote)"}else{'seeded from shipment + ERP'}); u=$me } | Out-Null
  Doc-Event $cn $docId 1 'created' $me $null '' (@{ seedNote=$seedNote }|ConvertTo-Json -Compress)
  Audit $me "doc-create $type for $job ($docId)$(if($seedNote){' - '+$seedNote})"
  @{ ok=$true; docId=$docId; docType=$type; status='DRAFT'; version=1; seedNote=$seedNote }
}
function Handle-DocGet($cn,$qs){
  $id="$($qs['id'])".Trim(); if(-not $id){ return @{error='id required'} }
  $h=Get-DocHead $cn $id; if(-not $h){ return @{error='not found'} }
  $vno=[int]$h.current_version
  if("$($qs['v'])".Trim() -match '^\d+$'){ $vno=[int]"$($qs['v'])".Trim() }
  $ver=@(RunQ $cn "SELECT TOP 1 version_no,side,base_version,fields,comment,created_by,CONVERT(varchar(19),created_at,120) created_at FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v" @{ d=$id; v=$vno })
  if(-not $ver.Count){ return @{error='version not found'} }
  $flds=$null; try{ $flds="$($ver[0].fields)"|ConvertFrom-Json }catch{}
  $baseNo=$null
  if("$($qs['base'])".Trim() -match '^\d+$'){ $baseNo=[int]"$($qs['base'])".Trim() }
  elseif($ver[0].base_version){ $baseNo=[int]$ver[0].base_version }
  $baseFlds=$null
  if($baseNo -and $baseNo -ne $vno){
    $bv=@(RunQ $cn "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v" @{ d=$id; v=$baseNo })
    if($bv.Count){ try{ $baseFlds="$($bv[0].fields)"|ConvertFrom-Json }catch{} }
  }
  $vers=@(RunQ $cn "SELECT version_no,side,base_version,comment,created_by,CONVERT(varchar(19),created_at,120) created_at FROM dbo.doc_version WHERE doc_id=@d ORDER BY version_no" @{ d=$id })
  @{ head=(Doc-HeadProj $cn $h)
     version=@{ no=[int]$ver[0].version_no; side=[string]$ver[0].side; baseVersion=$baseNo; fields=$flds; comment=[string]$ver[0].comment; createdBy=[string]$ver[0].created_by; createdAt=[string]$ver[0].created_at }
     baseFields=$baseFlds
     versions=@($vers|ForEach-Object{ [pscustomobject]@{ no=[int]$_.version_no; side=[string]$_.side; base=$_.base_version; comment=[string]$_.comment; createdBy=[string]$_.created_by; createdAt=[string]$_.created_at } }) }
}
function Handle-DocEvents($cn,$qs){
  $id="$($qs['id'])".Trim(); if(-not $id){ return @{error='id required'} }
  $h=Get-DocHead $cn $id; if(-not $h){ return @{error='not found'} }
  $rows=@(RunQ $cn "SELECT version_no,event,actor,ip,detail,CONVERT(varchar(19),occurred_at,120) occurred_at FROM dbo.doc_event_log WHERE doc_id=@d ORDER BY occurred_at,id" @{ d=$id })
  @{ docId=$id; events=@($rows|ForEach-Object{
      $det=$null; try{ if("$($_.detail)".Trim()){ $det="$($_.detail)"|ConvertFrom-Json } }catch{}
      [pscustomobject]@{ version=$_.version_no; event=[string]$_.event; actor=[string]$_.actor; ip=[string]$_.ip; detail=$det; at=[string]$_.occurred_at } }) }
}
function Save-DocSave($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.doc_id){ return @{error='invalid payload'} }
  $h=Get-DocHead $cn "$($j.doc_id)"; if(-not $h){ return @{error='not found'} }
  if("$($h.status)" -notin 'DRAFT','CUSTOMER_SUBMITTED','CUSTOMER_APPROVED','AMEND_DRAFT'){ return @{error="cannot edit while status is $($h.status)$(if("$($h.status)" -eq 'SENT'){' - revoke the customer link first'})"} }
  $clean=Doc-CleanFields "$($h.doc_type)" $j.fields
  $cur=@(RunQ $cn "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v" @{ d="$($h.doc_id)"; v=[int]$h.current_version })
  $changed=@(Doc-Changed $(if($cur.Count){"$($cur[0].fields)"}else{''}) $clean)
  if(-not $changed.Count){ return @{error='no changes to save'} }
  $newVer=[int]$h.current_version+1
  $cmt="$($j.comment)".Trim(); if($cmt.Length -gt 1000){ $cmt=$cmt.Substring(0,1000) }
  $newStatus=Doc-DraftState $h
  RunQ $cn "INSERT INTO dbo.doc_version(doc_id,version_no,side,base_version,fields,comment,created_by,created_at) VALUES(@d,@v,'staff',@b,@f,@c,@u,SYSDATETIME())" @{ d="$($h.doc_id)"; v=$newVer; b=[int]$h.current_version; f=($clean|ConvertTo-Json -Depth 6 -Compress); c=$cmt; u=$me } | Out-Null
  RunQ $cn "UPDATE dbo.doc_draft SET current_version=@v,status=@s,updated_at=SYSDATETIME() WHERE doc_id=@d" @{ v=$newVer; s=$newStatus; d="$($h.doc_id)" } | Out-Null
  Doc-Event $cn "$($h.doc_id)" $newVer 'edited' $me $null '' (@{ changed=@($changed); comment=$cmt }|ConvertTo-Json -Depth 4 -Compress)
  Audit $me "doc-save $($h.doc_type) $($h.job_no) v$newVer (changed: $($changed -join ','))"
  @{ ok=$true; version=$newVer; status=$newStatus; changed=@($changed) }
}
function Save-DocSend($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.doc_id){ return @{error='invalid payload'} }
  $h=Get-DocHead $cn "$($j.doc_id)"; if(-not $h){ return @{error='not found'} }
  if("$($h.status)" -notin 'DRAFT','AMEND_DRAFT','SENT','CUSTOMER_SUBMITTED','CUSTOMER_APPROVED'){ return @{error="cannot send while status is $($h.status)"} }
  $email="$($j.customer_email)".Trim(); $cname="$($j.customer_name)".Trim()
  if($email -and $email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$'){ return @{error='invalid customer email'} }
  $days=14; $pd=0; if([int]::TryParse("$($j.expires_days)",[ref]$pd) -and $pd -ge 1 -and $pd -le 90){ $days=$pd }
  # every send invalidates earlier links - exactly one live link per document
  $old=@(RunQ $cn "UPDATE dbo.doc_review_token SET revoked=1 OUTPUT INSERTED.token_hash WHERE doc_id=@d AND revoked=0" @{ d="$($h.doc_id)" })
  $raw=New-RawToken; $hash=Token-Hash $raw
  RunQ $cn "INSERT INTO dbo.doc_review_token(token_hash,doc_id,sent_version,customer_email,customer_name,expires_at,revoked,created_by,created_at,view_count) VALUES(@h,@d,@v,@e,@n,DATEADD(day,@days,SYSDATETIME()),0,@u,SYSDATETIME(),0)" @{ h=$hash; d="$($h.doc_id)"; v=[int]$h.current_version; e=$(if($email){$email}else{$null}); n=$(if($cname){$cname}else{$null}); days=$days; u=$me } | Out-Null
  RunQ $cn "UPDATE dbo.doc_draft SET status='SENT',customer_email=COALESCE(NULLIF(@e,''),customer_email),customer_name=COALESCE(NULLIF(@n,''),customer_name),updated_at=SYSDATETIME() WHERE doc_id=@d" @{ e=$email; n=$cname; d="$($h.doc_id)" } | Out-Null
  Doc-Event $cn "$($h.doc_id)" ([int]$h.current_version) 'sent' $me $hash '' (@{ to=$email; expiresDays=$days; revokedPrior=@($old).Count }|ConvertTo-Json -Compress)
  $base= if($cfg.publicBaseUrl -and "$($cfg.publicBaseUrl)".Trim()){ "$($cfg.publicBaseUrl)".Trim().TrimEnd('/') } else { "http://localhost:$Port" }
  $link="$base/bl-review/$raw"
  Audit $me "doc-send $($h.doc_type) $($h.job_no) v$($h.current_version) to '$email' (expires ${days}d)"
  @{ ok=$true; link=$link; expiresDays=$days; sentVersion=[int]$h.current_version; status='SENT' }
}
function Save-DocTokenRevoke($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.doc_id){ return @{error='invalid payload'} }
  $h=Get-DocHead $cn "$($j.doc_id)"; if(-not $h){ return @{error='not found'} }
  $old=@(RunQ $cn "UPDATE dbo.doc_review_token SET revoked=1 OUTPUT INSERTED.token_hash WHERE doc_id=@d AND revoked=0" @{ d="$($h.doc_id)" })
  $newStatus="$($h.status)"
  if($newStatus -eq 'SENT'){ $newStatus=Doc-DraftState $h; RunQ $cn "UPDATE dbo.doc_draft SET status=@s,updated_at=SYSDATETIME() WHERE doc_id=@d" @{ s=$newStatus; d="$($h.doc_id)" } | Out-Null }
  Doc-Event $cn "$($h.doc_id)" $null 'token_revoked' $me $null '' (@{ revoked=@($old).Count }|ConvertTo-Json -Compress)
  Audit $me "doc-token-revoke $($h.doc_type) $($h.job_no) ($(@($old).Count) link(s))"
  @{ ok=$true; revoked=@($old).Count; status=$newStatus }
}
function Save-DocAgree($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.doc_id){ return @{error='invalid payload'} }
  $h=Get-DocHead $cn "$($j.doc_id)"; if(-not $h){ return @{error='not found'} }
  if("$($h.status)" -ne 'CUSTOMER_APPROVED'){ return @{error="agree requires CUSTOMER_APPROVED (now $($h.status))"} }
  # push the AGREED data to the ERP booking now (so nobody retypes it). The agree itself never blocks on
  # the ERP: the push result is logged and shown, the workflow status is a fact between the two humans.
  $ver=@(RunQ $cn "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v" @{ d="$($h.doc_id)"; v=[int]$h.current_version })
  $flds=$null; if($ver.Count){ try{ $flds="$($ver[0].fields)"|ConvertFrom-Json }catch{} }
  $sa=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound,sono,carrier,pol,pod,commodity,master_bill,incoterm FROM dbo.shipment_alerts WHERE job_no=@j" @{ j="$($h.job_no)" })
  $saRow=$null; if($sa.Count){ $saRow=$sa[0] }
  $erp=Invoke-ErpDocAgree $h $flds $saRow $me
  RunQ $cn "UPDATE dbo.doc_draft SET status='AGREED',updated_at=SYSDATETIME() WHERE doc_id=@d" @{ d="$($h.doc_id)" } | Out-Null
  Doc-Event $cn "$($h.doc_id)" ([int]$h.current_version) 'agreed' $me $null '' $null
  if($erp.ok -and -not $erp.rejected){ Doc-Event $cn "$($h.doc_id)" ([int]$h.current_version) 'erp_booking_saved' $me $null '' (@{ mock=[bool]$erp.mock; steps=@($erp.steps) }|ConvertTo-Json -Depth 4 -Compress) }
  else { Doc-Event $cn "$($h.doc_id)" ([int]$h.current_version) 'erp_error' $me $null '' (@{ step='booking/update'; error="$(if($erp.error){$erp.error}else{@($erp.steps)[-1]})" }|ConvertTo-Json -Compress) }
  Audit $me "doc-agree $($h.doc_type) $($h.job_no) v$($h.current_version) [erp: $(@($erp.steps) -join '; ')$(if($erp.error){' ERR '+$erp.error})]"
  @{ ok=$true; status='AGREED'; erp=@{ ok=[bool]$erp.ok; mock=[bool]$erp.mock; rejected=[bool]$erp.rejected; steps=@($erp.steps); error="$($erp.error)" } }
}
function Save-DocIssue($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.doc_id){ return @{error='invalid payload'} }
  $h=Get-DocHead $cn "$($j.doc_id)"; if(-not $h){ return @{error='not found'} }
  if("$($h.status)" -ne 'AGREED'){ return @{error="issue requires AGREED (now $($h.status))"} }
  $ver=@(RunQ $cn "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v" @{ d="$($h.doc_id)"; v=[int]$h.current_version })
  $flds=$null; if($ver.Count){ try{ $flds="$($ver[0].fields)"|ConvertFrom-Json }catch{} }
  # the booking payload needs snapshot columns the head row does not carry (sono, port codes, carrier...)
  $sa=@(RunQ $cn "SELECT TOP 1 job_no,station,mode,bound,sono,carrier,pol,pod,commodity,master_bill,incoterm FROM dbo.shipment_alerts WHERE job_no=@j" @{ j="$($h.job_no)" })
  $saRow=$null; if($sa.Count){ $saRow=$sa[0] }
  # optional operator-attached agreed PDF (browser print-to-PDF), forwarded to /file/upload
  $att=$null
  if("$($j.pdf_base64)".Trim()){
    $nm="$($j.pdf_name)".Trim() -replace '[^\w.\- ]',''
    if(-not $nm){ $nm="agreed-$($h.doc_type)-$($h.job_no).pdf" }
    $att=@{ name=$nm; base64="$($j.pdf_base64)".Trim() }
  }
  if(-not $att){   # no operator-attached PDF -> auto-generate the agreed bill (headless print-to-PDF)
    $gen=Doc-RenderPdf $h $flds
    if($gen){ $att=@{ name="agreed-$($h.doc_type)-$($h.job_no).pdf"; base64=$gen } }
  }
  # every live rider attachment file goes to the ERP /file/upload as well
  $riders=@()
  foreach($ar in @(RunQ $cn "SELECT file_name,bytes FROM dbo.doc_attachment WHERE doc_id=@d AND deleted=0 ORDER BY uploaded_at" @{ d="$($h.doc_id)" })){
    $riders+=,@{ name="$($ar.file_name)"; base64=[Convert]::ToBase64String([byte[]]$ar.bytes) }
  }
  $r=Invoke-ErpDocIssue $h $flds $saRow $me $att $riders
  if(-not $r.ok){
    Doc-Event $cn "$($h.doc_id)" ([int]$h.current_version) 'erp_error' $me $null '' (@{ error="$($r.error)" }|ConvertTo-Json -Compress)
    return @{error="$($r.error)"}
  }
  RunQ $cn "UPDATE dbo.doc_draft SET status='ISSUED',erp_doc_no=@no,issued_at=SYSDATETIME(),updated_at=SYSDATETIME() WHERE doc_id=@d" @{ no="$($r.docNo)"; d="$($h.doc_id)" } | Out-Null
  RunQ $cn "UPDATE dbo.doc_review_token SET revoked=1 WHERE doc_id=@d AND revoked=0" @{ d="$($h.doc_id)" } | Out-Null
  Doc-Event $cn "$($h.doc_id)" ([int]$h.current_version) 'issued' $me $null '' (@{ erpDocNo="$($r.docNo)"; mock=[bool]$r.mock; steps=@($r.steps); pdfAttached=[bool]$att }|ConvertTo-Json -Depth 4 -Compress)
  Audit $me "doc-issue $($h.doc_type) $($h.job_no) v$($h.current_version) -> $($r.docNo)$(if($r.mock){' (MOCK)'}) [$(@($r.steps) -join '; ')]"
  @{ ok=$true; status='ISSUED'; erpDocNo="$($r.docNo)"; mock=[bool]$r.mock; steps=@($r.steps) }
}
function Save-DocAmend($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.doc_id){ return @{error='invalid payload'} }
  $h=Get-DocHead $cn "$($j.doc_id)"; if(-not $h){ return @{error='not found'} }
  if("$($h.status)" -ne 'ISSUED'){ return @{error="amend requires ISSUED (now $($h.status))"} }
  $reason="$($j.reason)".Trim()
  RunQ $cn "UPDATE dbo.doc_draft SET status='AMEND_DRAFT',amend_count=amend_count+1,updated_at=SYSDATETIME() WHERE doc_id=@d" @{ d="$($h.doc_id)" } | Out-Null
  Doc-Event $cn "$($h.doc_id)" ([int]$h.current_version) 'amend_opened' $me $null '' (@{ reason=$reason; feeApplies=$true; amendNo=([int]$h.amend_count+1) }|ConvertTo-Json -Compress)
  Audit $me "doc-amend $($h.doc_type) $($h.job_no) (amend #$([int]$h.amend_count+1), fee applies)$(if($reason){': '+$reason})"
  @{ ok=$true; status='AMEND_DRAFT'; amendCount=([int]$h.amend_count+1); feeApplies=$true }
}

# ---- attachment files (rider documents uploaded by staff OR customer; pushed to ERP /file/upload at issue) ----
# Body cap 7MB (5MB file as base64 + envelope); decoded max 5MB; pdf/png/jpeg only with magic-byte check.
$DocAttachMagic=@{ 'application/pdf'=@(0x25,0x50,0x44,0x46); 'image/png'=@(0x89,0x50,0x4E,0x47); 'image/jpeg'=@(0xFF,0xD8) }
function Doc-AttachValidate($fileName,$contentType,$b64){
  $name="$fileName".Trim() -replace '[^\w.\- ]',''
  if(-not $name){ return @{ ok=$false; err='file name required' } }
  $ct="$contentType".Trim().ToLower()
  if(-not $DocAttachMagic.ContainsKey($ct)){ return @{ ok=$false; err='only PDF, PNG or JPEG files are accepted' } }
  $bytes=$null; try{ $bytes=[Convert]::FromBase64String("$b64") }catch{ return @{ ok=$false; err='invalid file data' } }
  if(-not $bytes -or $bytes.Length -lt 16){ return @{ ok=$false; err='file is empty' } }
  if($bytes.Length -gt 5242880){ return @{ ok=$false; err='file too large (max 5 MB)' } }
  $magic=$DocAttachMagic[$ct]
  for($i=0;$i -lt $magic.Count;$i++){ if($bytes[$i] -ne $magic[$i]){ return @{ ok=$false; err='file content does not match its type' } } }
  @{ ok=$true; name=$name; ctype=$ct; bytes=$bytes }
}
# emits projection items - collect with @(Doc-AttachList ...) at call sites (house array rule)
function Doc-AttachList($cn,$docId){
  $rows=@(RunQ $cn "SELECT att_id,file_name,content_type,size_bytes,uploaded_side,uploaded_by,CONVERT(varchar(19),uploaded_at,120) uploaded_at FROM dbo.doc_attachment WHERE doc_id=@d AND deleted=0 ORDER BY uploaded_at" @{ d="$docId" })
  $rows|ForEach-Object{ [pscustomobject]@{ id=[string]$_.att_id; name=[string]$_.file_name; contentType=[string]$_.content_type; size=[int]$_.size_bytes; side=[string]$_.uploaded_side; by=[string]$_.uploaded_by; at=[string]$_.uploaded_at } }
}
function Save-DocAttach($cn,$ctx,$me){
  if($ctx.Request.ContentLength64 -gt 7340032){ return @{error='file too large (max 5 MB)'} }   # cap BEFORE reading body
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.doc_id){ return @{error='invalid payload'} }
  $h=Get-DocHead $cn "$($j.doc_id)"; if(-not $h){ return @{error='not found'} }
  if("$($h.status)" -eq 'ISSUED'){ return @{error='document is issued - open an amendment first'} }
  $cnt=@(RunQ $cn "SELECT COUNT(*) n FROM dbo.doc_attachment WHERE doc_id=@d AND deleted=0" @{ d="$($h.doc_id)" })
  if([int]$cnt[0].n -ge 20){ return @{error='attachment limit reached (20)'} }
  $v=Doc-AttachValidate $j.file_name $j.content_type $j.base64
  if(-not $v.ok){ return @{error=$v.err} }
  $attId=[guid]::NewGuid().ToString()
  RunQ $cn "INSERT INTO dbo.doc_attachment(att_id,doc_id,file_name,content_type,bytes,size_bytes,uploaded_side,uploaded_by,uploaded_at,deleted) VALUES(@a,@d,@n,@c,@b,@s,'staff',@u,SYSDATETIME(),0)" @{ a=$attId; d="$($h.doc_id)"; n=$v.name; c=$v.ctype; b=$v.bytes; s=$v.bytes.Length; u=$me } | Out-Null
  Doc-Event $cn "$($h.doc_id)" $null 'attach_added' $me $null '' (@{ name=$v.name; size=$v.bytes.Length }|ConvertTo-Json -Compress)
  Audit $me "doc-attach $($h.doc_type) $($h.job_no): $($v.name) ($($v.bytes.Length) bytes)"
  @{ ok=$true; id=$attId; attachments=@(Doc-AttachList $cn "$($h.doc_id)") }
}
function Handle-DocAttachListQ($cn,$qs){
  $id="$($qs['id'])".Trim(); if(-not $id){ return @{error='id required'} }
  $h=Get-DocHead $cn $id; if(-not $h){ return @{error='not found'} }
  @{ attachments=@(Doc-AttachList $cn $id) }
}
# streams the blob itself; returns $true on success so the router knows not to send JSON
function Handle-DocAttachFile($cn,$ctx,$qs){
  $id="$($qs['id'])".Trim(); $att="$($qs['att'])".Trim()
  if(-not $id -or -not $att){ return $false }
  $h=Get-DocHead $cn $id; if(-not $h){ return $false }
  $r=@(RunQ $cn "SELECT TOP 1 file_name,content_type,bytes FROM dbo.doc_attachment WHERE att_id=@a AND doc_id=@d AND deleted=0" @{ a=$att; d=$id })
  if(-not $r.Count){ return $false }
  Send-Blob $ctx ([byte[]]$r[0].bytes) "$($r[0].content_type)" "$($r[0].file_name)"
  $true
}
function Save-DocAttachDelete($cn,$ctx,$me){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  if(-not $j -or -not $j.doc_id -or -not $j.att_id){ return @{error='invalid payload'} }
  $h=Get-DocHead $cn "$($j.doc_id)"; if(-not $h){ return @{error='not found'} }
  if("$($h.status)" -eq 'ISSUED'){ return @{error='document is issued - attachments are locked'} }
  $old=@(RunQ $cn "UPDATE dbo.doc_attachment SET deleted=1 OUTPUT INSERTED.file_name WHERE att_id=@a AND doc_id=@d AND deleted=0" @{ a="$($j.att_id)"; d="$($h.doc_id)" })
  if(-not $old.Count){ return @{error='not found'} }
  Doc-Event $cn "$($h.doc_id)" $null 'attach_removed' $me $null '' (@{ name="$($old[0].file_name)" }|ConvertTo-Json -Compress)
  Audit $me "doc-attach-delete $($h.doc_type) $($h.job_no): $($old[0].file_name)"
  @{ ok=$true; attachments=@(Doc-AttachList $cn "$($h.doc_id)") }
}

# ---- public customer handlers (/api-doc/*: token IS the authority - no session, no cookies) ----
# Each validates the token SHAPE before touching SQL, opens its own short-lived connection, reads only
# doc_* tables (8s timeouts), and logs every access with IP. All failure modes return ONE generic message.
$DocLinkErr=@{ error='This review link is invalid, expired, or already closed. Please contact your forwarder for a fresh link.' }
function Get-DocByToken($cn,$raw){
  if("$raw" -notmatch '^[A-Za-z0-9_-]{40,64}$'){ return $null }
  $r=@(RunQ $cn "SELECT TOP 1 t.token_hash,t.doc_id,t.sent_version,t.customer_email,t.customer_name,t.expires_at,t.revoked,d.status,d.doc_type,d.job_no,d.current_version FROM dbo.doc_review_token t JOIN dbo.doc_draft d ON d.doc_id=t.doc_id WHERE t.token_hash=@h" @{ h=(Token-Hash $raw) } 8)
  if(-not $r.Count){ return $null }
  $t=$r[0]
  if([bool]$t.revoked){ return $null }
  if([datetime]$t.expires_at -lt (Get-Date)){ return $null }
  $t
}
function Client-Ip($ctx){ try{ "$($ctx.Request.RemoteEndPoint.Address)" }catch{ '' } }
function Handle-PublicDocView($ctx){
  $raw="$($ctx.Request.QueryString['t'])".Trim()
  if($raw -notmatch '^[A-Za-z0-9_-]{40,64}$'){ return $DocLinkErr }   # garbage rejected before any SQL
  $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
  try{
    $t=Get-DocByToken $cn $raw; if(-not $t){ return $DocLinkErr }
    if("$($t.status)" -notin 'SENT','CUSTOMER_SUBMITTED','CUSTOMER_APPROVED'){ return $DocLinkErr }
    $editable=("$($t.status)" -eq 'SENT')
    # while SENT the customer sees the version staff sent; after submitting they see their own (read-only)
    $vno= if($editable){ [int]$t.sent_version } else { [int]$t.current_version }
    $ver=@(RunQ $cn "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v" @{ d="$($t.doc_id)"; v=$vno } 8)
    if(-not $ver.Count){ return $DocLinkErr }
    $flds=$null; try{ $flds="$($ver[0].fields)"|ConvertFrom-Json }catch{}
    RunQ $cn "UPDATE dbo.doc_review_token SET view_count=view_count+1,last_view_at=SYSDATETIME() WHERE token_hash=@h" @{ h="$($t.token_hash)" } 8 | Out-Null
    Doc-Event $cn "$($t.doc_id)" $vno 'viewed' 'customer' "$($t.token_hash)" (Client-Ip $ctx) $null
    @{ docType=[string]$t.doc_type; jobNo=[string]$t.job_no; status=[string]$t.status; editable=$editable
       versionNo=$vno; fields=$flds; customerName=[string]$t.customer_name }
  } finally { $cn.Close() }
}
function Handle-PublicDocSubmit($ctx,$approveOnly){
  if($ctx.Request.ContentLength64 -gt 1048576){ return @{ error='request too large' } }   # 1MB cap BEFORE reading body (structured fields inflate the JSON; file uploads have their own route + cap)
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  $raw="$($j.t)".Trim()
  if($raw -notmatch '^[A-Za-z0-9_-]{40,64}$'){ return $DocLinkErr }
  $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
  try{
    $t=Get-DocByToken $cn $raw; if(-not $t){ return $DocLinkErr }
    if("$($t.status)" -ne 'SENT'){ return $DocLinkErr }   # customer can act only while SENT
    $cmt="$($j.comment)".Trim(); if($cmt.Length -gt 1000){ $cmt=$cmt.Substring(0,1000) }
    $by='customer'+$(if("$($t.customer_email)".Trim()){ ':'+"$($t.customer_email)".Trim() }else{ '' })
    if($approveOnly){
      RunQ $cn "UPDATE dbo.doc_draft SET status='CUSTOMER_APPROVED',updated_at=SYSDATETIME() WHERE doc_id=@d" @{ d="$($t.doc_id)" } 8 | Out-Null
      Doc-Event $cn "$($t.doc_id)" ([int]$t.sent_version) 'approved' $by "$($t.token_hash)" (Client-Ip $ctx) (@{ comment=$cmt }|ConvertTo-Json -Compress)
      return @{ ok=$true; status='CUSTOMER_APPROVED' }
    }
    $clean=Doc-CleanFields "$($t.doc_type)" $j.fields
    $sent=@(RunQ $cn "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v" @{ d="$($t.doc_id)"; v=[int]$t.sent_version } 8)
    $changed=@(Doc-Changed $(if($sent.Count){"$($sent[0].fields)"}else{''}) $clean)
    if(-not $changed.Count -and -not $cmt){ return @{ error='No changes were made. If the document is correct, use Approve instead.' } }
    $newVer=[int]$t.current_version+1
    RunQ $cn "INSERT INTO dbo.doc_version(doc_id,version_no,side,base_version,fields,comment,created_by,created_at) VALUES(@d,@v,'customer',@b,@f,@c,@u,SYSDATETIME())" @{ d="$($t.doc_id)"; v=$newVer; b=[int]$t.sent_version; f=($clean|ConvertTo-Json -Depth 6 -Compress); c=$cmt; u=$by } 8 | Out-Null
    RunQ $cn "UPDATE dbo.doc_draft SET status='CUSTOMER_SUBMITTED',current_version=@v,updated_at=SYSDATETIME() WHERE doc_id=@d" @{ v=$newVer; d="$($t.doc_id)" } 8 | Out-Null
    Doc-Event $cn "$($t.doc_id)" $newVer 'submitted' $by "$($t.token_hash)" (Client-Ip $ctx) (@{ changed=@($changed); comment=$cmt }|ConvertTo-Json -Depth 4 -Compress)
    @{ ok=$true; status='CUSTOMER_SUBMITTED'; version=$newVer; changed=@($changed) }
  } finally { $cn.Close() }
}
# customer attachment upload: only while SENT (the customer holds the pen); max 10 customer files per doc
function Handle-PublicDocAttach($ctx){
  if($ctx.Request.ContentLength64 -gt 7340032){ return @{ error='file too large (max 5 MB)' } }   # cap BEFORE reading body
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  $raw="$($j.t)".Trim()
  if($raw -notmatch '^[A-Za-z0-9_-]{40,64}$'){ return $DocLinkErr }
  $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
  try{
    $t=Get-DocByToken $cn $raw; if(-not $t){ return $DocLinkErr }
    if("$($t.status)" -ne 'SENT'){ return $DocLinkErr }
    $cnt=@(RunQ $cn "SELECT COUNT(*) n FROM dbo.doc_attachment WHERE doc_id=@d AND deleted=0 AND uploaded_side='customer'" @{ d="$($t.doc_id)" } 8)
    if([int]$cnt[0].n -ge 10){ return @{ error='attachment limit reached (10)' } }
    $v=Doc-AttachValidate $j.file_name $j.content_type $j.base64
    if(-not $v.ok){ return @{error=$v.err} }
    $by='customer'+$(if("$($t.customer_email)".Trim()){ ':'+"$($t.customer_email)".Trim() }else{ '' })
    $attId=[guid]::NewGuid().ToString()
    RunQ $cn "INSERT INTO dbo.doc_attachment(att_id,doc_id,file_name,content_type,bytes,size_bytes,uploaded_side,uploaded_by,uploaded_at,deleted) VALUES(@a,@d,@n,@c,@b,@s,'customer',@u,SYSDATETIME(),0)" @{ a=$attId; d="$($t.doc_id)"; n=$v.name; c=$v.ctype; b=$v.bytes; s=$v.bytes.Length; u=$by } 8 | Out-Null
    Doc-Event $cn "$($t.doc_id)" $null 'attach_added' $by "$($t.token_hash)" (Client-Ip $ctx) (@{ name=$v.name; size=$v.bytes.Length }|ConvertTo-Json -Compress)
    @{ ok=$true; id=$attId; attachments=@(Doc-AttachList $cn "$($t.doc_id)") }
  } finally { $cn.Close() }
}
function Handle-PublicDocAttachList($ctx){
  $raw="$($ctx.Request.QueryString['t'])".Trim()
  if($raw -notmatch '^[A-Za-z0-9_-]{40,64}$'){ return $DocLinkErr }
  $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
  try{
    $t=Get-DocByToken $cn $raw; if(-not $t){ return $DocLinkErr }
    if("$($t.status)" -notin 'SENT','CUSTOMER_SUBMITTED','CUSTOMER_APPROVED'){ return $DocLinkErr }
    @{ editable=("$($t.status)" -eq 'SENT'); attachments=@(Doc-AttachList $cn "$($t.doc_id)") }
  } finally { $cn.Close() }
}
function Handle-PublicDocAttachFile($ctx){
  $raw="$($ctx.Request.QueryString['t'])".Trim(); $att="$($ctx.Request.QueryString['id'])".Trim()
  if($raw -notmatch '^[A-Za-z0-9_-]{40,64}$' -or -not $att){ return $false }
  $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
  try{
    $t=Get-DocByToken $cn $raw; if(-not $t){ return $false }
    if("$($t.status)" -notin 'SENT','CUSTOMER_SUBMITTED','CUSTOMER_APPROVED'){ return $false }
    $r=@(RunQ $cn "SELECT TOP 1 file_name,content_type,bytes FROM dbo.doc_attachment WHERE att_id=@a AND doc_id=@d AND deleted=0" @{ a=$att; d="$($t.doc_id)" } 8)
    if(-not $r.Count){ return $false }
    Send-Blob $ctx ([byte[]]$r[0].bytes) "$($r[0].content_type)" "$($r[0].file_name)"
    $true
  } finally { $cn.Close() }
}
function Handle-PublicDocAttachDelete($ctx){
  $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
  $raw="$($j.t)".Trim()
  if($raw -notmatch '^[A-Za-z0-9_-]{40,64}$'){ return $DocLinkErr }
  $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
  try{
    $t=Get-DocByToken $cn $raw; if(-not $t){ return $DocLinkErr }
    if("$($t.status)" -ne 'SENT'){ return $DocLinkErr }
    # customers may remove ONLY their own uploads, never staff files
    $old=@(RunQ $cn "UPDATE dbo.doc_attachment SET deleted=1 OUTPUT INSERTED.file_name WHERE att_id=@a AND doc_id=@d AND deleted=0 AND uploaded_side='customer'" @{ a="$($j.id)"; d="$($t.doc_id)" } 8)
    if(-not $old.Count){ return @{ error='not found' } }
    $by='customer'+$(if("$($t.customer_email)".Trim()){ ':'+"$($t.customer_email)".Trim() }else{ '' })
    Doc-Event $cn "$($t.doc_id)" $null 'attach_removed' $by "$($t.token_hash)" (Client-Ip $ctx) (@{ name="$($old[0].file_name)" }|ConvertTo-Json -Compress)
    @{ ok=$true; attachments=@(Doc-AttachList $cn "$($t.doc_id)") }
  } finally { $cn.Close() }
}

$StationList=@(@($cfg.stations)|Where-Object{ $_ -and $_.code }|ForEach-Object{ [pscustomobject]@{ code="$($_.code)".Trim(); name="$($_.name)".Trim() } })
function Config-Payload { @{ appName=$AppName; instanceName=$InstanceName; appSubtitle=$AppSubtitle; stationCode=$StationCode; stations=$StationList; linkEnabled=$LinkEnabled } }

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
        if($un -notmatch '^[A-Za-z0-9_.@+-]+$'){ Send-Json $ctx @{ error="Invalid username (use letters, digits and . _ - @ +)" } 400; return }
        $role="$($j.role)".Trim().ToLower()
        if($role -notin 'admin','manager','operator'){ Send-Json $ctx @{ error="Role must be admin, manager or operator" } 400; return }
        $em="$($j.email)".Trim()
        # email is the login / SWIVEL L!NK federation key -> required, well-formed, and unique
        if(-not $em){ Send-Json $ctx @{ error="Email is required (it is the login / L!NK sign-in key)" } 400; return }
        if($em -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$'){ Send-Json $ctx @{ error="Enter a valid email address" } 400; return }
        if($script:Users | Where-Object { $_.username -ne $un -and "$($_.email)".Trim().ToLower() -eq $em.ToLower() }){ Send-Json $ctx @{ error="Email already assigned to another user" } 400; return }
        $authProvider="$($j.authProvider)".Trim().ToLower(); if($authProvider -notin 'local','swivel','both'){ $authProvider='local' }
        $language="$($j.language)".Trim(); if($language -notin '','en','zh-Hans','ja'){ $language='' }
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
          $new=[ordered]@{ username=$un; displayName=$dn; email=$em; salt=$rec.salt; pwdHash=$rec.pwdHash; role=$role; admin=$isAdmin; authProvider=$authProvider; language=$language; teams=$teams; stations=$stations; primaryStation=$prim; access=$access; erpUsers=$erpUsers }
          if($j.password){ $salt=New-Salt; $new.salt=$salt; $new.pwdHash=(Hash-Pwd $salt $j.password) }
          $users[$idx]=[pscustomobject]$new
          Audit $sess.username "update user $un (role=$role, admin=$isAdmin, stations=$($stations -join '/'), primary=$prim, access=$($access -join '/'), erp=$($erpUsers -join '/')$(if($j.password){', password reset'}))"
        } else {
          # a 'swivel' (L!NK-only) user signs in via OAuth, so no local password is needed; everyone else needs one
          if(-not $j.password -and $authProvider -ne 'swivel'){ Send-Json $ctx @{ error="A password is required for a new user (or set Sign-in to SWIVEL L!NK)" } 400; return }
          $salt=''; $hash=''; if($j.password){ $salt=New-Salt; $hash=(Hash-Pwd $salt $j.password) }
          $new=[ordered]@{ username=$un; displayName=$dn; email=$em; salt=$salt; pwdHash=$hash; role=$role; admin=$isAdmin; authProvider=$authProvider; language=$language; teams=$teams; stations=$stations; primaryStation=$prim; access=$access; erpUsers=$erpUsers }
          [void]$users.Add([pscustomobject]$new)
          Audit $sess.username "create user $un (role=$role, admin=$isAdmin, stations=$($stations -join '/'), primary=$prim, access=$($access -join '/'), erp=$($erpUsers -join '/'))"
        }
        $script:Users=@($users); Save-Users
        Send-Json $ctx @{ ok=$true }
      } else {
        Send-Json $ctx @{ users=@($script:Users | ForEach-Object { @{
          username="$($_.username)"; displayName="$($_.displayName)"; email="$($_.email)"; role="$($_.role)"; admin=[bool]$_.admin
          authProvider=$(if("$($_.authProvider)".Trim()){"$($_.authProvider)".Trim().ToLower()}else{'local'})
          language="$($_.language)".Trim()
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
    # ---- milestone & alert config (milestone_def in erpops; the only admin endpoints that need SQL).
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
          $script:MsDoctypeMap=$null   # milestone config changed -> rebuild the derived doctype map on next use
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
      $script:MsDoctypeMap=$null   # milestone config changed -> rebuild the derived doctype map on next use
      Audit $sess.username "delete milestone $code/$bound"
      Send-Json $ctx @{ ok=$true }
    }
    "/api-ops/admin/evidence" {
      # Document types that clear a milestone (the milestone_evidence_map pic_doctype rows). The match_value MUST
      # equal the ERP Document Type code so /file/upload accepts it and the worklist upload dropdown matches the ERP.
      $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
      try{
        if($method -eq "POST"){
          $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
          $doctype="$($j.doctype)".Trim()
          if(-not $doctype -or $doctype.Length -gt 64){ Send-Json $ctx @{ error="Document type required (max 64 chars) - must match the ERP Document Type code exactly" } 400; return }
          $code="$($j.milestone_code)".Trim().ToUpper(); $bound="$($j.bound)".Trim()
          if($bound -notin 'Export','Import'){ Send-Json $ctx @{ error="Bound must be Export or Import" } 400; return }
          $mod="$($j.module)".Trim().ToUpper(); if($mod -and $mod -notin 'SEA','AIR'){ Send-Json $ctx @{ error="Module must be SEA, AIR or blank (any)" } 400; return }
          $modVal= if($mod){ $mod } else { [DBNull]::Value }
          if(-not @(RunQ $cn "SELECT TOP 1 1 ok FROM dbo.milestone_def WHERE milestone_code=@c AND bound=@b" @{ c=$code; b=$bound }).Count){ Send-Json $ctx @{ error="No milestone $code ($bound) - pick one from the list" } 400; return }
          $active=if($null -eq $j.active){1}else{[int][bool]$j.active}
          $id=0; [void][int]::TryParse("$($j.id)",[ref]$id)
          if($id -gt 0){
            RunQ $cn "UPDATE dbo.milestone_evidence_map SET milestone_code=@c,bound=@b,match_value=@v,module_match=@m,active=@a WHERE id=@id AND source_kind='pic_doctype'" @{ c=$code; b=$bound; v=$doctype; m=$modVal; a=$active; id=$id } | Out-Null
          } else {
            RunQ $cn "INSERT INTO dbo.milestone_evidence_map(milestone_code,bound,source_kind,source_table,source_field,match_value,module_match,active) VALUES(@c,@b,'pic_doctype','PIC','doctype',@v,@m,@a)" @{ c=$code; b=$bound; v=$doctype; m=$modVal; a=$active } | Out-Null
          }
          $script:MsDoctypeMap=$null
          Audit $sess.username "upsert evidence doc '$doctype' -> $code/$bound (mod=$(if($mod){$mod}else{'any'}), active=$active)"
          Send-Json $ctx @{ ok=$true }
        } else {
          $rows=@(RunQ $cn "SELECT id,milestone_code,bound,match_value,module_match,active FROM dbo.milestone_evidence_map WHERE source_kind='pic_doctype' ORDER BY bound,match_value" @{})
          $defs=@(RunQ $cn "SELECT milestone_code,bound,name,mode FROM dbo.milestone_def WHERE active=1 ORDER BY mode,bound,seq" @{})
          Send-Json $ctx @{ docs=$rows; milestones=$defs }
        }
      } finally { $cn.Close() }
    }
    "/api-ops/admin/evidence-delete" {
      $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
      $id=0; [void][int]::TryParse("$($j.id)",[ref]$id)
      if($id -le 0){ Send-Json $ctx @{ error="id required" } 400; return }
      $cn=New-Object System.Data.SqlClient.SqlConnection $ConnStr; $cn.Open()
      try{ RunQ $cn "DELETE FROM dbo.milestone_evidence_map WHERE id=@id AND source_kind='pic_doctype'" @{ id=$id } | Out-Null } finally { $cn.Close() }
      $script:MsDoctypeMap=$null
      Audit $sess.username "delete evidence doc id=$id"
      Send-Json $ctx @{ ok=$true }
    }
    "/api-ops/admin/erp-settings" {
      # The non-secret ERP API identity codes in erp-api-map.json. partyGroupCode = the company/customer group
      # (e.g. DEV) sent on every call. forwarderCode = the default office owncode used when a station's owncode
      # can't be resolved from fm3kco.site (per-station owncode otherwise wins). The bearer token is NOT here
      # (it lives in the gitignored config). Edits apply immediately (cache reset by Set-ErpApiMap).
      if($method -eq "POST"){
        $j=$null; try{ $j=(Read-Body $ctx)|ConvertFrom-Json }catch{}
        $pg="$($j.partyGroupCode)".Trim()
        if(-not $pg -or $pg.Length -gt 32){ Send-Json $ctx @{ error="Party group code required (max 32 chars) - the company code, e.g. DEV" } 400; return }
        $upd=@{ partyGroupCode=$pg }
        if($j.PSObject.Properties['forwarderCode']){
          $fc="$($j.forwarderCode)".Trim()
          if($fc.Length -gt 32){ Send-Json $ctx @{ error="Forwarder code too long (max 32 chars)" } 400; return }
          $upd['forwarderCode']=$fc
        }
        Set-ErpApiMap $upd
        Audit $sess.username "erp-settings partyGroupCode=$pg$(if($upd.ContainsKey('forwarderCode')){' forwarderCode='+$upd['forwarderCode']})"
        Send-Json $ctx @{ ok=$true }
      } else {
        $m=Get-ErpApiMap
        Send-Json $ctx @{ partyGroupCode="$($m.partyGroupCode)".Trim(); forwarderCode="$($m.forwarderCode)".Trim() }
      }
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
    # SQL-free PUBLIC endpoints first (no session needed): login / link-oauth-login / logout / config
    if($path -eq "/api-ops/login"){ Handle-OpsLogin $ctx }
    elseif($path -eq "/api-ops/link-oauth-login"){
      if($ctx.Request.HttpMethod -ne 'POST'){ Send-Json $ctx @{ error='POST required' } 405 } else { Handle-LinkOAuthLogin $ctx }
    }
    elseif($path -eq "/api-ops/logout"){
      $c=$ctx.Request.Cookies['ops_sid']; if($c -and $Sessions[$c.Value]){ $Sessions.Remove($c.Value) }
      $ctx.Response.Headers["Set-Cookie"]="ops_sid=; Path=/; Max-Age=0"
      Send-Json $ctx @{ ok=$true }
    }
    elseif($path -eq "/api-ops/config"){ Send-Json $ctx (Config-Payload) }
    # PUBLIC customer review namespace (no session; token in the URL/body is the authority). Kept fully
    # separate from /api-ops/* so a reverse proxy can expose ONLY /bl-review/* + /api-doc/* + the review
    # static assets to the internet while the staff app stays LAN-only.
    elseif($path -like "/bl-review/*"){ Send-File $ctx (Join-Path $Root "bl-review.html") }   # SQL-free; page JS reads the token from the URL
    elseif($path -eq "/api-doc/view"){ Send-Json $ctx (Handle-PublicDocView $ctx) }
    elseif($path -eq "/api-doc/submit"){
      if($ctx.Request.HttpMethod -ne 'POST'){ Send-Json $ctx @{ error='POST required' } 405 } else { Send-Json $ctx (Handle-PublicDocSubmit $ctx $false) }
    }
    elseif($path -eq "/api-doc/approve"){
      if($ctx.Request.HttpMethod -ne 'POST'){ Send-Json $ctx @{ error='POST required' } 405 } else { Send-Json $ctx (Handle-PublicDocSubmit $ctx $true) }
    }
    elseif($path -eq "/api-doc/attach"){
      if($ctx.Request.HttpMethod -ne 'POST'){ Send-Json $ctx @{ error='POST required' } 405 } else { Send-Json $ctx (Handle-PublicDocAttach $ctx) }
    }
    elseif($path -eq "/api-doc/attach-list"){ Send-Json $ctx (Handle-PublicDocAttachList $ctx) }
    elseif($path -eq "/api-doc/attach-file"){ if(-not (Handle-PublicDocAttachFile $ctx)){ Send-Json $ctx $DocLinkErr 404 } }
    elseif($path -eq "/api-doc/attach-delete"){
      if($ctx.Request.HttpMethod -ne 'POST'){ Send-Json $ctx @{ error='POST required' } 405 } else { Send-Json $ctx (Handle-PublicDocAttachDelete $ctx) }
    }
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
                "/api-ops/erp-files"       { Send-Json $ctx (Handle-ErpFiles $cn $qs) }
                "/api-ops/erp-file-download" { if(-not (Handle-ErpFileDownload $cn $ctx $qs)){ Send-Json $ctx @{ error='file not available' } 404 } }
                "/api-ops/erp-file-upload" { Send-Json $ctx (Handle-ErpFileUpload $cn $ctx $me) }
                "/api-ops/erp-edit"        { Send-Json $ctx (Handle-ErpEditSeed $cn $qs) }
                "/api-ops/erp-master"      { Send-Json $ctx (Handle-ErpMasterSearch $cn $qs) }
                "/api-ops/erp-edit-save"   { Send-Json $ctx (Save-ErpEdit $cn $ctx $me) }
                "/api-ops/inbound"         { Send-Json $ctx (Handle-Inbound $cn $qs) }
                "/api-ops/inbound-assign"  { Send-Json $ctx (Save-InboundAssign $cn $ctx $me) }
                "/api-ops/my-tasks"        { Send-Json $ctx (Handle-MyTasks $cn $me) }
                "/api-ops/worklist"        { Send-Json $ctx (Handle-Worklist $cn $qs $me) }
                "/api-ops/shipment"        { Send-Json $ctx (Handle-Shipment $cn $qs) }
                "/api-ops/milestone-close" { Send-Json $ctx (Save-MilestoneClose $cn $ctx $me) }
                "/api-ops/docs"            { Send-Json $ctx (Handle-DocList $cn $qs) }
                "/api-ops/doc"             { Send-Json $ctx (Handle-DocGet $cn $qs) }
                "/api-ops/doc-events"      { Send-Json $ctx (Handle-DocEvents $cn $qs) }
                "/api-ops/doc-create"      { Send-Json $ctx (Save-DocCreate $cn $ctx $me) }
                "/api-ops/doc-save"        { Send-Json $ctx (Save-DocSave $cn $ctx $me) }
                "/api-ops/doc-send"        { Send-Json $ctx (Save-DocSend $cn $ctx $me) }
                "/api-ops/doc-token-revoke"{ Send-Json $ctx (Save-DocTokenRevoke $cn $ctx $me) }
                "/api-ops/doc-agree"       { Send-Json $ctx (Save-DocAgree $cn $ctx $me) }
                "/api-ops/doc-issue"       { Send-Json $ctx (Save-DocIssue $cn $ctx $me) }
                "/api-ops/doc-amend"       { Send-Json $ctx (Save-DocAmend $cn $ctx $me) }
                "/api-ops/doc-attach"      { Send-Json $ctx (Save-DocAttach $cn $ctx $me) }
                "/api-ops/doc-attach-list" { Send-Json $ctx (Handle-DocAttachListQ $cn $qs) }
                "/api-ops/doc-attach-file" { if(-not (Handle-DocAttachFile $cn $ctx $qs)){ Send-Json $ctx @{ error='not found' } 404 } }
                "/api-ops/doc-attach-delete" { Send-Json $ctx (Save-DocAttachDelete $cn $ctx $me) }
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
