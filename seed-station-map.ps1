<#
  seed-station-map.ps1  — build the station identity directory that powers the cross-station inbound feed.

  Populates two pgsops tables (off the request path):
    station_dim         — our group offices (from each source ERP's dbo.asw_station_list + config stations[]).
    station_route_map   — resolves an ORIGIN booking's destination code -> the importing station.

  The destination of a booking is encoded in the ORIGIN's own customer master as the destination agent code
  (blhead/awbhead.agn2_code) and controlling customer (rcustomer). The group convention links each office's
  agent code to a station via dbo.asw_station_list (CODE <-> FM3000_CODE). This script:
    1. seeds station_dim from asw_station_list (+ config database_name / name),
    2. for each origin station, maps distinct cross-station booking agent/ctrl codes -> dest station via that
       convention and upserts 'agent'/'ctrl' route rows,
    3. applies config-driven POD fallback (routePodMap) and manual overrides (routeManual),
    4. prints a DISCOVERY REPORT of cross-station codes it could NOT map (with names), for admin tagging.

  Source ERP is READ-ONLY; all writes go to pgsops. Two-server aware (mirrors seed-alerts.ps1).
  Usage: .\seed-station-map.ps1 [-ConfigPath .\ops.config.json] [-Mode Sea|Air|Both]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [ValidateSet('Sea','Air','Both')][string]$Mode='Both'
)
$ErrorActionPreference="Stop"
$cfg=Get-Content $ConfigPath -Raw|ConvertFrom-Json
function EnvOrConfig($n,$v){ $e=[Environment]::GetEnvironmentVariable($n); if($e -and $e.Trim()){$e}else{$v} }
$server=EnvOrConfig "DB_SERVER" $cfg.server; $auth=EnvOrConfig "DB_AUTH" $cfg.auth
$user=EnvOrConfig "DB_USER" $cfg.user; $pwd=EnvOrConfig "DB_PASSWORD" $cfg.password; $opsDb=EnvOrConfig "DB_OPS_DB" $cfg.opsDb
$masterDb=EnvOrConfig "DB_MASTER_DB" $cfg.masterDb; if(-not ("$masterDb".Trim())){ $masterDb='fm3kco' }
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
# resolve a small set of customer codes -> names from the master (custsub.code2 clustered seek; chunked)
function Resolve-Names($db,$codes){
  $map=@{}; $codes=@($codes|Where-Object{$_}|Select-Object -Unique)
  for($off=0; $off -lt $codes.Count; $off+=500){
    $chunk=@($codes[$off..([Math]::Min($off+499,$codes.Count-1))])
    $p=@{}; $ins=@(); $i=0; foreach($cd in $chunk){ $ins+="@c$i"; $p["c$i"]=$cd; $i++ }
    $rows=Query $db "SELECT code2, doc_e_name FROM dbo.custsub WHERE code2 IN ($($ins -join ','))" $p
    foreach($r in $rows){ $k="$($r.code2)".Trim(); if($k -and -not $map.ContainsKey($k)){ $map[$k]=("$($r.doc_e_name)").Trim() } }
  }
  $map
}

$dimMerge=@"
MERGE dbo.station_dim AS t USING (SELECT @code code) s ON t.code=s.code
WHEN MATCHED THEN UPDATE SET fm3000_code=@fm,name=COALESCE(@name,t.name),database_name=COALESCE(@db,t.database_name),active=1,updated_at=SYSDATETIME()
WHEN NOT MATCHED THEN INSERT(code,fm3000_code,name,database_name,active,updated_at) VALUES(@code,@fm,@name,@db,1,SYSDATETIME());
"@
$routeMerge=@"
MERGE dbo.station_route_map AS t
USING (SELECT @o origin_station,@k match_kind,@v match_value,@d dest_station) s
  ON t.origin_station=s.origin_station AND t.match_kind=s.match_kind AND t.match_value=s.match_value AND t.dest_station=s.dest_station
WHEN MATCHED THEN UPDATE SET priority=@p,active=1,note=@note,updated_at=SYSDATETIME()
WHEN NOT MATCHED THEN INSERT(origin_station,match_kind,match_value,dest_station,priority,active,note,updated_at)
  VALUES(@o,@k,@v,@d,@p,1,@note,SYSDATETIME());
"@

$stations=@($cfg.stations | Where-Object { $_ -and $_.database })
if(-not $stations.Count){ Write-Host "No stations with a 'database' in config." -ForegroundColor Red; $opsCn.Close(); exit }
# config code -> display name (for station_dim.name) and code -> database
$nameByCode=@{}; $dbByCode=@{}
foreach($s in $cfg.stations){ if($s.code){ $nameByCode["$($s.code)".Trim()]="$($s.name)".Trim(); $dbByCode["$($s.code)".Trim()]="$($s.database)".Trim() } }

# ---- 1) station_dim from asw_station_list (group office list; read from the first reachable station) ----
$fmToStation=@{}   # FM3000_CODE -> station CODE (the convention)
$asw=@()
foreach($s in $stations){
  try{ $asw=Query $s.database "SELECT CODE, FM3000_CODE FROM dbo.asw_station_list WHERE NULLIF(LTRIM(RTRIM(CODE)),'') IS NOT NULL" @{}; if($asw.Count){ break } }catch{}
}
foreach($a in $asw){
  $code="$($a.CODE)".Trim(); $fm="$($a.FM3000_CODE)".Trim(); if(-not $code){ continue }
  if($fm){ $fmToStation[$fm]=$code }
  Exec $dimMerge @{ code=$code; fm=$(if($fm){$fm}else{$null}); name=$(if($nameByCode[$code]){$nameByCode[$code]}else{$null}); db=$(if($dbByCode[$code]){$dbByCode[$code]}else{$null}) }
}
# ensure every configured station exists in station_dim even if not in asw_station_list
foreach($s in $stations){ $code="$($s.code)".Trim(); Exec $dimMerge @{ code=$code; fm=$null; name=$(if($nameByCode[$code]){$nameByCode[$code]}else{$null}); db="$($s.database)".Trim() } }
Write-Host ("station_dim: {0} office(s); convention map FM3000->station has {1} entr(ies)." -f $asw.Count, $fmToStation.Count) -ForegroundColor Cyan

# ---- authoritative convention map: <masterDb>.site.owncode -> station CODE ----------------------------------
# Each office is also a CUSTOMER in the group system; site.owncode is that office's system customer code (e.g.
# S0001 = Hong Kong) and site.location is its 3-letter station code (hkg). A booking's destination agent
# (agn2_code) / R-O agent (roagent) / controlling customer (rcustomer) carries this owncode. This is the real
# intercompany link (asw_station_list.FM3000_CODE lives in a different code space and never matches these).
$ownToStation=@{}
try{
  foreach($r in (Query $masterDb "SELECT owncode, location FROM dbo.site WHERE NULLIF(LTRIM(RTRIM(owncode)),'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(location)),'') IS NOT NULL")){
    $oc="$($r.owncode)".Trim().ToUpper(); $loc="$($r.location)".Trim().ToUpper(); if($oc -and $loc){ $ownToStation[$oc]=$loc }
  }
}catch{ Write-Host ("  [warn] could not read {0}.site: {1}" -f $masterDb,$_.Exception.Message) -ForegroundColor DarkYellow }
Write-Host ("convention map (site.owncode->station): {0} entr(ies)." -f $ownToStation.Count) -ForegroundColor Cyan

# ---- 2) station_route_map agent/ctrl rows from the convention, per origin ----
$modes = if($Mode -eq 'Both'){ @('Sea','Air') } else { @($Mode) }
$unmapped=@{}   # "origin|code" -> name (discovery report)
$routeN=0
foreach($s in $stations){
  $origin="$($s.code)".Trim(); $db="$($s.database)".Trim()
  foreach($m in $modes){
    try{
      if($m -eq 'Air'){ $rows=Query $db "SELECT DISTINCT agn2_code, rcustomer FROM dbo.awbhead WHERE bound='O'" @{} }
      else            { $rows=Query $db "SELECT DISTINCT agn2_code, rcustomer, roagent FROM dbo.blhead WHERE bound='O'" @{} }
    } catch { Write-Host ("  [skip] {0}/{1}: {2}" -f $origin,$m,$_.Exception.Message) -ForegroundColor DarkYellow; continue }
    $codes=@(); foreach($r in $rows){ $codes+=("$($r.agn2_code)").Trim(); $codes+=("$($r.rcustomer)").Trim(); if($r.PSObject.Properties['roagent']){ $codes+=("$($r.roagent)").Trim() } }
    $codes=@($codes|Where-Object{$_}|Select-Object -Unique)
    foreach($r in $rows){
      $pairs=@(@{k='agent';v=("$($r.agn2_code)").Trim();pri=10}, @{k='ctrl';v=("$($r.rcustomer)").Trim();pri=20})
      if($r.PSObject.Properties['roagent']){ $pairs+=,@{k='roagent';v=("$($r.roagent)").Trim();pri=15} }
      foreach($pair in $pairs){
        $code=("$($pair.v)").Trim(); if(-not $code){ continue }
        $dest=$ownToStation[$code.ToUpper()]; if(-not $dest){ $dest=$fmToStation[$code] }
        if($dest -and $dest -ne $origin){
          Exec $routeMerge @{ o=$origin; k=$pair.k; v=$code; d=$dest; p=$pair.pri; note="auto: site.owncode" }; $routeN++
        } elseif(-not $dest){ $unmapped["$origin|$code"]=$null }
      }
    }
    # resolve names for the unmapped codes of this origin (for the discovery report)
    $u=@($unmapped.Keys | Where-Object { $_ -like "$origin|*" } | ForEach-Object { $_.Split('|',2)[1] })
    if($u.Count){ $nm=Resolve-Names $db $u; foreach($k in @($unmapped.Keys|Where-Object{ $_ -like "$origin|*" })){ $cd=$k.Split('|',2)[1]; if($nm.ContainsKey($cd)){ $unmapped[$k]=$nm[$cd] } } }
  }
}
Write-Host ("station_route_map: {0} convention (agent/ctrl) row(s) upserted." -f $routeN) -ForegroundColor Cyan

# ---- 3) config-driven POD fallback + manual overrides ----
$podN=0
if($cfg.routePodMap){ foreach($prop in $cfg.routePodMap.PSObject.Properties){ Exec $routeMerge @{ o='*'; k='pod'; v="$($prop.Name)".Trim(); d="$($prop.Value)".Trim(); p=200; note="config: routePodMap" }; $podN++ } }
$manN=0
if($cfg.routeManual){ foreach($row in @($cfg.routeManual)){ Exec $routeMerge @{ o=$(if($row.origin){"$($row.origin)".Trim()}else{'*'}); k="$($row.kind)".Trim(); v="$($row.value)".Trim(); d="$($row.dest)".Trim(); p=$(if($row.priority){[int]$row.priority}else{100}); note="config: routeManual" }; $manN++ } }
if($podN -or $manN){ Write-Host ("config rules: {0} POD fallback, {1} manual." -f $podN,$manN) -ForegroundColor Cyan }

# ---- 4) discovery report: cross-station codes we could not map (admin should add routeManual rows) ----
if($unmapped.Count){
  Write-Host "`nUNMAPPED destination codes on cross-station bookings (add to station_route_map / config.routeManual):" -ForegroundColor Yellow
  foreach($k in ($unmapped.Keys|Sort-Object)){ $o,$c=$k.Split('|',2); Write-Host ("  origin {0,-6} code {1,-10} {2}" -f $o,$c,$unmapped[$k]) -ForegroundColor Gray }
} else { Write-Host "`nNo unmapped destination codes." -ForegroundColor Green }
$opsCn.Close()
