<#
  publish-bookings.ps1  — cross-station inbound booking PUBLISHER (one origin station per invocation).

  Reads the origin ERP's OUTBOUND bookings (blhead bill_type='B' | awbhead awb_type='B', bound='O') that are
  destined to ANOTHER group station, resolves the destination station via pgsops.station_route_map, and UPSERTs
  one denormalized row per booking into pgsops.inbound_booking_feed. The destination station's app then reads
  ONLY feed rows addressed to it (no station ever queries another station's ERP). Incremental via feed_watermark.

  Source ERP is READ-ONLY; all writes go to pgsops. Two-server aware (mirrors seed-alerts.ps1).
  Usage: .\publish-bookings.ps1 -Station <originDb> -StationCode <ORIGIN> -Mode Sea|Air [-Since yyyy-mm-dd] [-Limit 500]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [Parameter(Mandatory=$true)][string]$Station,
  [Parameter(Mandatory=$true)][string]$StationCode,
  [ValidateSet('Sea','Air')][string]$Mode='Sea',
  [string]$Since='', [int]$Limit=1000
)
$ErrorActionPreference="Stop"
$cfg=Get-Content $ConfigPath -Raw|ConvertFrom-Json
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
function DOnly($d){ if($d -is [datetime]){ $d.ToString('yyyy-MM-dd') } else { $null } }

# ---- route map for this origin (+ global '*' rules); key "kind|value" -> @{dest;pri} ----
$routeRows = Query $opsDb "SELECT match_kind,match_value,dest_station,priority FROM dbo.station_route_map WHERE active=1 AND origin_station IN (@me,'*')" @{ me=$StationCode }
$routeByKV=@{}
foreach($r in $routeRows){
  $mv=("$($r.match_value)").Trim(); $k="$($r.match_kind)|$mv"
  if(-not $routeByKV.ContainsKey($k) -or [int]$r.priority -lt $routeByKV[$k].pri){ $routeByKV[$k]=@{ dest=("$($r.dest_station)").Trim(); pri=[int]$r.priority } }
}
function Resolve-Dest($agent,$ctrl,$roagent,$pod){
  $cands=@()
  foreach($pair in @(@{k='agent';v=$agent},@{k='ctrl';v=$ctrl},@{k='roagent';v=$roagent},@{k='pod';v=$pod})){
    if($pair.v){ $h=$routeByKV["$($pair.k)|$($pair.v)"]; if($h){ $cands+=$h } }
  }
  if(-not $cands.Count){ return $null }
  ($cands | Sort-Object pri | Select-Object -First 1).dest
}
if(-not $routeByKV.Count){ Write-Host "WARNING: no station_route_map rules for origin $StationCode - run seed-station-map.ps1 first." -ForegroundColor Yellow }

# watermark upsert (here-string; COALESCE preserves last_src_at when @lsa is NULL, e.g. an empty run)
$wmMerge=@"
MERGE dbo.feed_watermark AS t USING (SELECT @ws AS ss, @wm AS mm) x ON t.source_station=x.ss AND t.mode=x.mm
WHEN MATCHED THEN UPDATE SET last_src_at=COALESCE(@lsa,t.last_src_at),run_at=SYSDATETIME()
WHEN NOT MATCHED THEN INSERT(source_station,mode,last_src_at,run_at) VALUES(@ws,@wm,@lsa,SYSDATETIME());
"@

# ---- watermark (incremental): only bookings created/updated since last successful run ----
$wmSel=@"
SELECT CONVERT(varchar(19),last_src_at,126) lsa FROM dbo.feed_watermark WHERE source_station=@s AND mode=@m
"@
$wm = Query $opsDb $wmSel @{ s=$StationCode; m=$Mode }
$since = if($Since){ $Since } elseif($wm.Count -and $wm[0].lsa){ $wm[0].lsa } else { '2000-01-01' }

# ---- candidate bookings (mode-specific) ----
if($Mode -eq 'Air'){
  $sql="SELECT TOP $Limit jobn, mawb, agn2_code, rcustomer, pol, pod, carr, flight1, f_date1, cargoready, frt_terms, shpr_code, shpr_name, po_no, t_book_qty, t_book_wgt, crtdate, upddate FROM dbo.awbhead WHERE awb_type='B' AND bound='O' AND (crtdate>@since OR upddate>@since) ORDER BY crtdate DESC"
} else {
  $sql="SELECT TOP $Limit blno, jobn, mobl, agn2_code, rcustomer, roagent, pol, pod, carr, vessel_1, voyage_1, departure1, cargoready, routing, shpr_code, shpr_name, crtdate, upddate FROM dbo.blhead WHERE bill_type='B' AND bound='O' AND (crtdate>@since OR upddate>@since) ORDER BY crtdate DESC"
}
$bk = Query $Station $sql @{ since=$since }
Write-Host ("publish-bookings $StationCode/$Mode : {0} candidate booking line(s) since {1}." -f $bk.Count,$since) -ForegroundColor Cyan
if(-not $bk.Count){ Exec $wmMerge @{ ws=$StationCode; wm=$Mode; lsa=$null }; $opsCn.Close(); exit }

# resolve agent/ctrl names from the master once (chunked custsub.code2 clustered seek)
$codes=@(); foreach($b in $bk){ $codes+=("$($b.agn2_code)").Trim(); $codes+=("$($b.rcustomer)").Trim() }
$codes=@($codes|Where-Object{$_}|Select-Object -Unique)
$nameByCode=@{}
for($off=0; $off -lt $codes.Count; $off+=500){
  $chunk=@($codes[$off..([Math]::Min($off+499,$codes.Count-1))])
  $p=@{}; $ins=@(); $i=0; foreach($cd in $chunk){ $ins+="@c$i"; $p["c$i"]=$cd; $i++ }
  $rows=Query $Station "SELECT code2, doc_e_name FROM dbo.custsub WHERE code2 IN ($($ins -join ','))" $p
  foreach($r in $rows){ $k="$($r.code2)".Trim(); if($k -and -not $nameByCode.ContainsKey($k)){ $nameByCode[$k]=("$($r.doc_e_name)").Trim() } }
}

$feedMerge=@"
MERGE dbo.inbound_booking_feed AS t
USING (SELECT @ss source_station,@mode mode,@bn booking_no) s
  ON t.source_station=s.source_station AND t.mode=s.mode AND t.booking_no=s.booking_no
WHEN MATCHED THEN UPDATE SET dest_station=@dest,source_jobn=@jobn,master_bill=@mbl,house_bill=@hbl,
  shipper_code=@shc,shipper_name=@shn,ctrl_code=@ctc,ctrl_name=@ctn,agent_code=@agc,agent_name=@agn,
  pol=@pol,pod=@pod,carrier=@carr,vessel_flight=@vf,etd=@etd,cargo_ready=@cr,incoterm=@inco,
  cargo_summary=@cs,booking_date=@bd,light=@light,src_updated_at=@srcup,
  feed_status=CASE WHEN t.feed_status='consumed' THEN t.feed_status ELSE 'open' END,updated_at=SYSDATETIME()
WHEN NOT MATCHED THEN INSERT(source_station,mode,booking_no,dest_station,source_jobn,master_bill,house_bill,
  shipper_code,shipper_name,ctrl_code,ctrl_name,agent_code,agent_name,pol,pod,carrier,vessel_flight,etd,cargo_ready,
  incoterm,cargo_summary,booking_date,feed_status,assigned_to,linked_job_no,light,src_updated_at,updated_at)
  VALUES(@ss,@mode,@bn,@dest,@jobn,@mbl,@hbl,@shc,@shn,@ctc,@ctn,@agc,@agn,@pol,@pod,@carr,@vf,@etd,@cr,
  @inco,@cs,@bd,'open',NULL,NULL,@light,@srcup,SYSDATETIME());
"@

$today=(Get-Date).Date
$n=0; $skipSelf=0; $skipNoRoute=0; $maxSrc=$null
foreach($b in $bk){
  # track high-water across ALL candidates (so skipped rows still advance the watermark)
  foreach($d in @($b.crtdate,$b.upddate)){ if($d -is [datetime] -and (-not $maxSrc -or $d -gt $maxSrc)){ $maxSrc=$d } }
  $agent=("$($b.agn2_code)").Trim(); $ctrl=("$($b.rcustomer)").Trim()
  $roagent= if($Mode -eq 'Air'){ '' } else { ("$($b.roagent)").Trim() }
  $pod=("$($b.pod)").Trim()
  $dest=Resolve-Dest $agent $ctrl $roagent $pod
  if(-not $dest){ $skipNoRoute++; continue }
  if($dest -eq $StationCode){ $skipSelf++; continue }
  $bn= if($Mode -eq 'Air'){ $j=("$($b.mawb)").Trim(); if($j){$j}else{("$($b.jobn)").Trim()} } else { ("$($b.blno)").Trim() }
  if(-not $bn){ $bn=("$($b.jobn)").Trim() }
  if($Mode -eq 'Air'){
    $fl=("$($b.flight1)").Trim(); $cr=("$($b.carr)").Trim(); $vf= if($cr -and $fl){"$cr $fl"}elseif($fl){$fl}elseif($cr){$cr}else{''}
    $etd=$b.f_date1; $mbl=("$($b.mawb)").Trim(); $inco=("$($b.frt_terms)").Trim()
    $q=[int]("0"+"$($b.t_book_qty)"); $w=[double]("0"+"$($b.t_book_wgt)"); $cs= if($q -gt 0 -or $w -gt 0){ (@($(if($q){"$q pcs"}), $(if($w){("{0} kg" -f [math]::Round($w,0))}))|Where-Object{$_}) -join ' / ' } else { $null }
  } else {
    $vsl=("$($b.vessel_1)").Trim(); $voy=("$($b.voyage_1)").Trim(); $vf= if($vsl -and $voy){"$vsl / $voy"}elseif($vsl){$vsl}elseif($voy){$voy}else{''}
    $etd=$b.departure1; $mbl=("$($b.mobl)").Trim(); $inco=("$($b.routing)").Trim(); $cs=$null
  }
  # pre-arrival urgency: R if ETD within 3 days, A within a week, else G (importer can prep earlier than arrival)
  $light='G'; if($etd -is [datetime]){ $days=($etd.Date - $today).TotalDays; if($days -le 3){ $light='R' } elseif($days -le 7){ $light='A' } }
  Exec $feedMerge @{
    ss=$StationCode; mode=$Mode; bn=$bn; dest=$dest; jobn=("$($b.jobn)").Trim()
    mbl=$(if($mbl){$mbl}else{$null}); hbl=$null
    shc=$(if(("$($b.shpr_code)").Trim()){("$($b.shpr_code)").Trim()}else{$null}); shn=$(if(("$($b.shpr_name)").Trim()){("$($b.shpr_name)").Trim()}else{$null})
    ctc=$(if($ctrl){$ctrl}else{$null}); ctn=$(if($nameByCode.ContainsKey($ctrl)){$nameByCode[$ctrl]}else{$null})
    agc=$(if($agent){$agent}else{$null}); agn=$(if($nameByCode.ContainsKey($agent)){$nameByCode[$agent]}else{$null})
    pol=$(if(("$($b.pol)").Trim()){("$($b.pol)").Trim()}else{$null}); pod=$(if($pod){$pod}else{$null})
    carr=$(if(("$($b.carr)").Trim()){("$($b.carr)").Trim()}else{$null}); vf=$(if($vf){$vf}else{$null})
    etd=(DOnly $etd); cr=(DOnly $b.cargoready); inco=$(if($inco){$inco}else{$null})
    cs=$cs; bd=(DOnly $b.crtdate); light=$light; srcup=$b.upddate
  }
  $n++
}
# advance watermark to the max source date seen this run
Exec $wmMerge @{ ws=$StationCode; wm=$Mode; lsa=$(if($maxSrc){$maxSrc}else{$null}) }
$opsCn.Close()
Write-Host ("Published {0} cross-station booking(s) to inbound_booking_feed. (skipped: {1} self, {2} no-route)" -f $n,$skipSelf,$skipNoRoute) -ForegroundColor Green
