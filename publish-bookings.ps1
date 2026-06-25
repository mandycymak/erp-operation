<#
  publish-bookings.ps1  — cross-station inbound booking PUBLISHER (one origin station per invocation).

  Reads the origin ERP's OUTBOUND shipments (blhead/awbhead bound='O' — no bill/awb-type filter; the destination
  office decides what's cross-station, not the doc stage) that are destined to ANOTHER group station, resolves
  the destination station via erpops.station_route_map (built from fm3kco.site.owncode), and UPSERTs
  one denormalized row per booking into erpops.inbound_booking_feed. The destination station's app then reads
  ONLY feed rows addressed to it (no station ever queries another station's ERP). Incremental via feed_watermark.

  Source ERP is READ-ONLY; all writes go to erpops. Two-server aware (mirrors seed-alerts.ps1).
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
function DOnly($d){ if($d -is [datetime]){ $d.ToString('yyyy-MM-dd') } else { $null } }
# derive FCL/LCL from blhead.service (e.g. 'CY /CY' -> FCL, 'CFS/CFS' -> LCL, mixed -> 'Mixed'); CY=container yard, CFS=container freight station
function CargoType($svc){ $u="$svc".ToUpper(); $cy=$u -match 'CY'; $cfs=$u -match 'CFS'; if($cy -and -not $cfs){'FCL'}elseif($cfs -and -not $cy){'LCL'}elseif($cy -and $cfs){'Mixed'}else{$null} }
# "count x type" container summary + first container no from a job's blcont rows (lifted from seed-alerts.ps1)
function ContSummary($rows){
  if(-not $rows -or -not $rows.Count){ return @{ summary=$null; first_cont=$null } }
  $byType=[ordered]@{}; $firstCont=$null
  foreach($r in $rows){ $t=("$($r.cont_type)").Trim(); if($t){ if($byType.Contains($t)){$byType[$t]++}else{$byType[$t]=1} }
    if(-not $firstCont){ $cn=("$($r.container)").Trim(); if($cn){ $firstCont=$cn } } }
  $parts=@(); foreach($k in $byType.Keys){ $parts += ("{0}x{1}" -f $byType[$k], $k) }
  @{ summary=$(if($parts.Count){$parts -join ' + '}else{$null}); first_cont=$firstCont }
}

# ---- route map for this origin (+ global '*' rules); key "kind|value" -> @{dest;pri} ----
$routeRows = Query $opsDb "SELECT match_kind,match_value,dest_station,priority FROM dbo.station_route_map WHERE active=1 AND origin_station IN (@me,'*')" @{ me=$StationCode }
$routeByKV=@{}
foreach($r in $routeRows){
  $mv=("$($r.match_value)").Trim(); $k="$($r.match_kind)|$mv"
  if(-not $routeByKV.ContainsKey($k) -or [int]$r.priority -lt $routeByKV[$k].pri){ $routeByKV[$k]=@{ dest=("$($r.dest_station)").Trim(); pri=[int]$r.priority } }
}
# NB: destination resolution + the offshore decision are done inline in the per-booking loop now (a booking can fan
# out to SEVERAL stations), so the old single-winner Resolve-Dest/RouteHit helpers were removed. The route map is
# still keyed "kind|value" -> @{dest;pri} in $routeByKV below.
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

# keep only columns that exist in this station's table (ERP schema drifts slightly between stations)
function Filter-Cols($db,$table,$wantCsv){
  $want=@($wantCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $have=@{}; foreach($r in (Query $db "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='$table'")){ $have["$($r.COLUMN_NAME)".ToLower()]=1 }
  $miss=@($want | Where-Object { -not $have[$_.ToLower()] })
  if($miss.Count){ Write-Host "  [schema] $db.$table missing (dropped): $($miss -join ',')" -ForegroundColor DarkYellow }
  (@($want | Where-Object { $have[$_.ToLower()] }) -join ',')
}
# ---- candidate bookings (mode-specific) ----
if($Mode -eq 'Air'){
  $cols=Filter-Cols $Station 'awbhead' "booking, jobn, mawb, hawb, agn2_code, rcustomer, cgne_code, cgne_name, not1_code, pol, pod, carr, flight1, f_date1, cargoready, routing, frt_terms, shpr_code, shpr_name, po_no, t_book_qty, t_book_wgt, crtdate, upddate"
  # No bill/awb-type filter: the destination office (resolved below) decides what's cross-station, not the doc
  # stage. (The bill_type='B' filter belongs to the dashboard's de-dup, not to this feed.)
  $sql="SELECT TOP $Limit $cols FROM dbo.awbhead WHERE bound='O' AND (crtdate>@since OR upddate>@since) ORDER BY crtdate DESC"
} else {
  $cols=Filter-Cols $Station 'blhead' "sono, blno, jobn, mobl, agn2_code, rcustomer, roagent, cgne_code, cgne_name, not1_code, service, spotid, t_book_qty, t_book_wgt, ref, pol, pod, carr, vessel_1, voyage_1, departure2, cargoready, routing, shpr_code, shpr_name, crtdate, upddate"
  $sql="SELECT TOP $Limit $cols FROM dbo.blhead WHERE bound='O' AND (crtdate>@since OR upddate>@since) ORDER BY crtdate DESC"
}
$bk = Query $Station $sql @{ since=$since }
Write-Host ("publish-bookings $StationCode/$Mode : {0} candidate booking line(s) since {1}." -f $bk.Count,$since) -ForegroundColor Cyan
if(-not $bk.Count){ Exec $wmMerge @{ ws=$StationCode; wm=$Mode; lsa=$null }; $opsCn.Close(); exit }

# batch container rows for the selected sea bookings (keyed by blhead.ref); empty at booking stage, fills in later
$contByRef=@{}
if($Mode -ne 'Air'){
  $refs=@($bk | ForEach-Object { $_.ref } | Where-Object { $null -ne $_ -and "$_".Trim() } | Select-Object -Unique)
  for($off=0; $off -lt $refs.Count; $off+=500){
    $chunk=@($refs[$off..([Math]::Min($off+499,$refs.Count-1))])
    $p=@{}; $ins=@(); $i=0; foreach($rf in $chunk){ $ins+="@r$i"; $p["r$i"]=$rf; $i++ }
    foreach($d in (Query $Station "SELECT blh, cont_type, container FROM dbo.blcont WHERE blh IN ($($ins -join ','))" $p)){ $k="$($d.blh)"; if(-not $contByRef.ContainsKey($k)){ $contByRef[$k]=@() }; $contByRef[$k]+=$d }
  }
}

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
USING (SELECT @ss source_station,@mode mode,@bn booking_no,@dest dest_station) s
  ON t.source_station=s.source_station AND t.mode=s.mode AND t.booking_no=s.booking_no AND t.dest_station=s.dest_station
WHEN MATCHED THEN UPDATE SET source_jobn=@jobn,master_bill=@mbl,house_bill=@hbl,
  shipper_code=@shc,shipper_name=@shn,ctrl_code=@ctc,ctrl_name=@ctn,agent_code=@agc,agent_name=@agn,
  consignee_code=@cgnc,consignee_name=@cgnn,cargo_type=@ctype,service=@svc,container_no=@cno,po_no=@pono,
  spot_id=@spot,booking_qty=@bqty,booking_wgt=@bwgt,
  pol=@pol,pod=@pod,carrier=@carr,vessel_flight=@vf,etd=@etd,cargo_ready=@cr,incoterm=@inco,
  cargo_summary=@cs,booking_date=@bd,light=@light,src_updated_at=@srcup,offshore=@offshore,dest_role=@drole,
  feed_status=CASE WHEN t.feed_status='consumed' THEN t.feed_status ELSE 'open' END,updated_at=SYSDATETIME()
WHEN NOT MATCHED THEN INSERT(source_station,mode,booking_no,dest_station,source_jobn,master_bill,house_bill,
  shipper_code,shipper_name,ctrl_code,ctrl_name,agent_code,agent_name,consignee_code,consignee_name,cargo_type,
  service,container_no,po_no,spot_id,booking_qty,booking_wgt,pol,pod,carrier,vessel_flight,etd,cargo_ready,
  incoterm,cargo_summary,booking_date,feed_status,assigned_to,linked_job_no,light,src_updated_at,offshore,dest_role,updated_at)
  VALUES(@ss,@mode,@bn,@dest,@jobn,@mbl,@hbl,@shc,@shn,@ctc,@ctn,@agc,@agn,@cgnc,@cgnn,@ctype,@svc,@cno,@pono,
  @spot,@bqty,@bwgt,@pol,@pod,@carr,@vf,@etd,@cr,@inco,@cs,@bd,'open',NULL,NULL,@light,@srcup,@offshore,@drole,SYSDATETIME());
"@

$today=(Get-Date).Date
$n=0; $skipSelf=0; $skipNoRoute=0; $offshoreN=0; $maxSrc=$null
foreach($b in $bk){
  # track high-water across ALL candidates (so skipped rows still advance the watermark)
  foreach($d in @($b.crtdate,$b.upddate)){ if($d -is [datetime] -and (-not $maxSrc -or $d -gt $maxSrc)){ $maxSrc=$d } }
  $agent=("$($b.agn2_code)").Trim(); $ctrl=("$($b.rcustomer)").Trim()
  $roagent= if($Mode -eq 'Air'){ '' } else { ("$($b.roagent)").Trim() }   # Air has no routing-agent field
  $notify=("$($b.not1_code)").Trim(); $consignee=("$($b.cgne_code)").Trim()
  $pod=("$($b.pod)").Trim()
  # A booking can concern SEVERAL stations: the destination agent's office AND any office named as notify/consignee/
  # routing/controlling agent. Fan out one feed row PER involved station. Per station, OFFSHORE = it is named ONLY in
  # an off-bill role (controlling/routing agent) and in NO bill-visible role (destination agent/notify/consignee) -
  # those off-bill roles don't print on the HBL/HAWB, so it's a cross-trade move we coordinate, not a real import to us.
  $involved=@{}
  foreach($pr in @(
    @{role='agent';    v=$agent;     pri=10; bill=$true},
    @{role='notify';   v=$notify;    pri=12; bill=$true},
    @{role='consignee';v=$consignee; pri=14; bill=$true},
    @{role='roagent';  v=$roagent;   pri=15; bill=$false},
    @{role='ctrl';     v=$ctrl;      pri=20; bill=$false})){
    $rv="$($pr.v)".Trim(); if(-not $rv){ continue }
    $h=$routeByKV["$($pr.role)|$rv"]; if(-not $h){ continue }
    $st=$h.dest; if(-not $st -or $st -eq $StationCode){ continue }
    if(-not $involved.ContainsKey($st)){ $involved[$st]=@{ billVisible=$false; offBill=$false; bestPri=9999; bestRole='' } }
    $e=$involved[$st]
    if($pr.bill){ $e.billVisible=$true } else { $e.offBill=$true }
    if([int]$pr.pri -lt [int]$e.bestPri){ $e.bestPri=[int]$pr.pri; $e.bestRole=$pr.role }
  }
  # POD fallback ONLY when no party role routed anywhere (POD = physical discharge port -> a real arrival, not offshore)
  if($involved.Count -eq 0 -and $pod){ $h=$routeByKV["pod|$pod"]; if($h -and $h.dest -and $h.dest -ne $StationCode){ $involved[$h.dest]=@{ billVisible=$true; offBill=$false; bestPri=200; bestRole='pod' } } }
  if($involved.Count -eq 0){ $skipNoRoute++; continue }
  # key the feed on the SO number (sono/booking) — the stable id that exists from booking stage onward; at booking
  # time blno/mawb/jobn are still empty, so keying on those would collide every booking-stage row onto one feed row.
  $bn= if($Mode -eq 'Air'){ ("$($b.booking)").Trim() } else { ("$($b.sono)").Trim() }
  if(-not $bn){ $bn= if($Mode -eq 'Air'){ ("$($b.mawb)").Trim() } else { ("$($b.blno)").Trim() } }
  if(-not $bn){ $bn=("$($b.jobn)").Trim() }
  # consignee = the party who receives the cargo at destination (who the importer coordinates with)
  $cgnc=("$($b.cgne_code)").Trim(); $cgnn=("$($b.cgne_name)").Trim()
  $q=[int]("0"+"$($b.t_book_qty)"); $w=[double]("0"+"$($b.t_book_wgt)")
  $bwgt= if($w -gt 0){ ("{0} kg" -f [math]::Round($w,0)) } else { $null }
  if($Mode -eq 'Air'){
    $fl=("$($b.flight1)").Trim(); $cr=("$($b.carr)").Trim(); $vf= if($cr -and $fl){"$cr $fl"}elseif($fl){$fl}elseif($cr){$cr}else{''}
    $etd=$b.f_date1; $mbl=("$($b.mawb)").Trim(); $inco=("$($b.routing)").Trim()   # air Incoterm is in routing (like sea); frt_terms is PP/CC payment terms
    $cs= if($q -gt 0 -or $w -gt 0){ (@($(if($q){"$q pcs"}), $(if($w){("{0} kg" -f [math]::Round($w,0))}))|Where-Object{$_}) -join ' / ' } else { $null }
    $ctype='Air'; $svc=$null; $cno=$null; $pono=("$($b.po_no)").Trim(); $spot=$null
    $bqty= if($q -gt 0){ "$q pcs" } else { $null }
    $hbl=("$($b.hawb)").Trim()   # house AWB — the doc the consignee receives; lets the importer dedup vs arrivals
  } else {
    $vsl=("$($b.vessel_1)").Trim(); $voy=("$($b.voyage_1)").Trim(); $vf= if($vsl -and $voy){"$vsl / $voy"}elseif($vsl){$vsl}elseif($voy){$voy}else{''}
    $etd=$b.departure2; $mbl=("$($b.mobl)").Trim(); $inco=("$($b.routing)").Trim()
    $svc=("$($b.service)").Trim(); $ctype=(CargoType $svc)
    $cp=ContSummary @($contByRef["$($b.ref)"]); $cno=$cp.first_cont; $cs=$cp.summary
    $pono=$null; $spot=("$($b.spotid)").Trim()
    $bqty= if($q -gt 0){ "$q pkgs" } else { $null }
    $hbl=("$($b.blno)").Trim()   # house BL (origin's HBL) — empty at booking stage, fills in when the bill issues
  }
  # pre-arrival urgency: R if ETD within 3 days, A within a week, else G (importer can prep earlier than arrival)
  $light='G'; if($etd -is [datetime]){ $days=($etd.Date - $today).TotalDays; if($days -le 3){ $light='R' } elseif($days -le 7){ $light='A' } }
  foreach($destSt in @($involved.Keys)){
    $e=$involved[$destSt]
    $offshore = if($e.offBill -and -not $e.billVisible){ 1 } else { 0 }
    Exec $feedMerge @{
      ss=$StationCode; mode=$Mode; bn=$bn; dest=$destSt; jobn=("$($b.jobn)").Trim()
      mbl=$(if($mbl){$mbl}else{$null}); hbl=$(if($hbl){$hbl}else{$null})
      shc=$(if(("$($b.shpr_code)").Trim()){("$($b.shpr_code)").Trim()}else{$null}); shn=$(if(("$($b.shpr_name)").Trim()){("$($b.shpr_name)").Trim()}else{$null})
      ctc=$(if($ctrl){$ctrl}else{$null}); ctn=$(if($nameByCode.ContainsKey($ctrl)){$nameByCode[$ctrl]}else{$null})
      agc=$(if($agent){$agent}else{$null}); agn=$(if($nameByCode.ContainsKey($agent)){$nameByCode[$agent]}else{$null})
      cgnc=$(if($cgnc){$cgnc}else{$null}); cgnn=$(if($cgnn){$cgnn}else{$null})
      ctype=$(if($ctype){$ctype}else{$null}); svc=$(if($svc){$svc}else{$null}); cno=$(if($cno){$cno}else{$null})
      pono=$(if($pono){$pono}else{$null}); spot=$(if($spot){$spot}else{$null})
      bqty=$(if($bqty){$bqty}else{$null}); bwgt=$(if($bwgt){$bwgt}else{$null})
      pol=$(if(("$($b.pol)").Trim()){("$($b.pol)").Trim()}else{$null}); pod=$(if($pod){$pod}else{$null})
      carr=$(if(("$($b.carr)").Trim()){("$($b.carr)").Trim()}else{$null}); vf=$(if($vf){$vf}else{$null})
      etd=(DOnly $etd); cr=(DOnly $b.cargoready); inco=$(if($inco){$inco}else{$null})
      cs=$cs; bd=(DOnly $b.crtdate); light=$light; srcup=$b.upddate; offshore=$offshore; drole=$e.bestRole
    }
    $n++; if($offshore){ $offshoreN++ }
  }
}
# advance watermark to the max source date seen this run
Exec $wmMerge @{ ws=$StationCode; wm=$Mode; lsa=$(if($maxSrc){$maxSrc}else{$null}) }
$opsCn.Close()
Write-Host ("Published {0} cross-station booking(s) to inbound_booking_feed ({3} offshore). (skipped: {1} self, {2} no-route)" -f $n,$skipSelf,$skipNoRoute,$offshoreN) -ForegroundColor Green
