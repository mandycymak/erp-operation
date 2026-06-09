<#
  seed-alerts.ps1  — DEMO data seeder (stand-in for the deferred listener).
  Evaluates a batch of real station shipments (as of a reference date) and UPSERTs them into
  pgsops.shipment_alerts so the worklist UI has live-looking content. Reuses ops-eval.ps1 (the same
  evaluator eval-shipment.ps1 / the future listener use). Source ERP is READ-ONLY.
  Usage: .\seed-alerts.ps1 [-Station pgshkg] [-StationCode HKG] [-AsOf 2023-04-10] [-Limit 60] [-LeadDays 4]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [string]$Station="pgshkg", [string]$StationCode="HKG",
  [ValidateSet('Sea','Air')][string]$Mode='Sea',
  [datetime]$AsOf=[datetime]"2023-04-10", [int]$Limit=60, [int]$LeadDays=4
)
$ErrorActionPreference="Stop"
. (Join-Path $PSScriptRoot "ops-eval.ps1")
$cfg=Get-Content $ConfigPath -Raw|ConvertFrom-Json
function EnvOrConfig($n,$v){ $e=[Environment]::GetEnvironmentVariable($n); if($e -and $e.Trim()){$e}else{$v} }
$server=EnvOrConfig "DB_SERVER" $cfg.server; $auth=EnvOrConfig "DB_AUTH" $cfg.auth
$user=EnvOrConfig "DB_USER" $cfg.user; $pwd=EnvOrConfig "DB_PASSWORD" $cfg.password; $opsDb=EnvOrConfig "DB_OPS_DB" $cfg.opsDb
$ac= if($auth -eq 'sql'){"User ID=$user;Password=$pwd"}else{"Integrated Security=True"}
# two-server mode: ops DB may live on a different server than the read-only source ERP (falls back to source)
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

# ---- config ----
$defs = Query $opsDb "SELECT milestone_code,bound,name,seq,phase_anchor,qualify_rule,complete_rule,sla_type,sla_offset_val,sla_offset_unit,sla_direction,sla_anchor,mode FROM dbo.milestone_def WHERE active=1"
$evmap = Query $opsDb "SELECT milestone_code,bound,source_kind,source_table,source_field,match_value,module_match FROM dbo.milestone_evidence_map WHERE active=1"

# ---- candidate shipments: active house bills/AWBs as of AsOf, recent first (mode-specific source table) ----
if($Mode -eq 'Air'){
  # awbhead = the air waybill table; awb_type H=house, S=straight/direct are the operator's shipments (M=consol master, B=booking)
  $cols="jobn,hawb,mawb,bound,awb_type,flight1,carr,pol,pod,shpr_code,shpr_name,cgne_code,cgne_name,ref,picuser,crtuser,upduser,status,declaration_complete,atd_date,ata_date,inform_cnee,cnee_pickup,customer_pickup,comp_date,crtdate,t_book_qty,t_book_wgt,t_book_cwt"
  $ships = Query $Station "SELECT TOP $Limit $cols FROM dbo.awbhead WHERE awb_type IN('H','S') AND bound IN('O','I') AND crtdate<=@a AND comp_date IS NULL ORDER BY crtdate DESC" @{ a=$AsOf.ToString('yyyy-MM-dd') }
} else {
  $cols="jobn,blno,bound,frttype,routing,pol,pod,carr,salesman,picuser,crtuser,upduser,status,declaration,shpr_code,shpr_name,cgne_code,cgne_name,ref,vessel_1,voyage_1,onboard1,cargoready,cargorece,customs_clearance,ts_blno,ams_hbl,edidate,atd_date,eta_delivery,goods_delivery,comp_date,ata_date,not1_date,release_date,broker,customer_pickup,wh_code,ad_date,ware_date,pd_date,departure1,crtdate"
  $ships = Query $Station "SELECT TOP $Limit $cols FROM dbo.blhead WHERE bill_type='H' AND bound IN('O','I') AND crtdate<=@a AND comp_date IS NULL ORDER BY crtdate DESC" @{ a=$AsOf.ToString('yyyy-MM-dd') }
}
if(-not $ships.Count){ Write-Host "No candidate $Mode shipments in $Station as of $($AsOf.ToString('yyyy-MM-dd'))." -ForegroundColor Red; exit }

# ---- batch PIC evidence for the selected jobns (one query) ----
$jobns=@($ships | ForEach-Object { "$($_.jobn)" } | Where-Object { $_ })
$picByJob=@{}
if($jobns.Count){
  $p=@{}; $ins=@(); $i=0; foreach($j in $jobns){ $ins+="@j$i"; $p["j$i"]=$j; $i++ }
  $pic = Query $Station "SELECT jobn, module, doctype, MIN(pdte) firstdate FROM dbo.PIC WHERE jobn IN ($($ins -join ',')) AND NULLIF(doctype,'') IS NOT NULL GROUP BY jobn, module, doctype" $p
  foreach($d in $pic){ $k="$($d.jobn)"; if(-not $picByJob.ContainsKey($k)){ $picByJob[$k]=@() }; $picByJob[$k]+=$d }
}

# ---- batch container profile for the selected blhead refs (sea only; air uses pieces/weight) ----
$contByRef=@{}
if($Mode -ne 'Air'){
  $refs=@($ships | ForEach-Object { $_.ref } | Where-Object { $null -ne $_ })
  if($refs.Count){
    $p=@{}; $ins=@(); $i=0; foreach($rf in $refs){ $ins+="@r$i"; $p["r$i"]=$rf; $i++ }
    $cont = Query $Station "SELECT blh, cont_type, load_wgt, load_cbm FROM dbo.blcont WHERE blh IN ($($ins -join ','))" $p
    foreach($d in $cont){ $k="$($d.blh)"; if(-not $contByRef.ContainsKey($k)){ $contByRef[$k]=@() }; $contByRef[$k]+=$d }
  }
}

# ---- batch consignee/shipper contact (join key is the views' code2) ----
$codes=@($ships | ForEach-Object { if("$($_.bound)" -eq 'I'){ "$($_.cgne_code)".Trim() } else { "$($_.shpr_code)".Trim() } } | Where-Object { $_ } | Select-Object -Unique)
$contactByCode=@{}
if($codes.Count){
  $p=@{}; $ins=@(); $i=0; foreach($cd in $codes){ $ins+="@c$i"; $p["c$i"]=$cd; $i++ }
  $inlist=$ins -join ','
  $ct = Query $Station "SELECT code2, contact1, phone1, email1 FROM dbo.consignee_view WHERE code2 IN ($inlist) UNION SELECT code2, contact1, phone1, email1 FROM dbo.shipper_view WHERE code2 IN ($inlist)" $p
  foreach($d in $ct){ $k="$($d.code2)".Trim(); if($k -and -not $contactByCode.ContainsKey($k)){ $contactByCode[$k]=$d } }
}

# build a "count×type + … " cargo summary + totals from a job's container rows
function ContSummary($rows){
  if(-not $rows -or -not $rows.Count){ return @{ summary=$null; count=0; wgt=$null; cbm=$null } }
  $byType=[ordered]@{}; $wgt=0.0; $cbm=0.0; $hasCbm=$false
  foreach($r in $rows){
    $t="$($r.cont_type)".Trim(); if(-not $t){ $t='?' }
    if($byType.Contains($t)){ $byType[$t]++ } else { $byType[$t]=1 }
    if($null -ne $r.load_wgt){ $wgt += [double]$r.load_wgt }
    if($null -ne $r.load_cbm){ $c=[double]$r.load_cbm; $cbm += $c; if($c -gt 0){ $hasCbm=$true } }
  }
  $parts=@(); foreach($k in $byType.Keys){ $parts += ("{0}x{1}" -f $byType[$k], $k) }
  @{ summary=($parts -join ' + '); count=$rows.Count; wgt=[math]::Round($wgt,2); cbm=$(if($hasCbm){[math]::Round($cbm,2)}else{$null}) }
}

$merge=@"
MERGE dbo.shipment_alerts AS t USING (SELECT @job job_no) s ON t.job_no=s.job_no
WHEN MATCHED THEN UPDATE SET station=@station,mode=@mode,cargo_type=@cargo,bound=@bound,lane=@lane,carrier=@carrier,
  cust_code=@cust,salesman=@salesman,pic_user=@pic,created_by=@cby,last_updated_by=@uby,anchor_date=@anchor,
  etd=@etd,eta=@eta,atd=@atd,ata=@ata,job_status=@jstat,worst_light=@worst,open_amber=@amber,open_red=@red,
  next_due=@nextdue,auto_done=@auto,manual_done=@man,consignee_name=@cgname,shipper_name=@shipname,
  cust_contact=@ccontact,cust_phone=@cphone,cust_email=@cemail,vessel_voyage=@vv,container_summary=@csum,
  container_count=@ccount,total_weight=@twgt,total_cbm=@tcbm,arrival_state=@astate,sort_key=@skey,
  milestone_checklist=@chk,updated_at=SYSDATETIME()
WHEN NOT MATCHED THEN INSERT(job_no,station,mode,cargo_type,bound,lane,carrier,cust_code,salesman,pic_user,created_by,
  last_updated_by,anchor_date,etd,eta,atd,ata,job_status,worst_light,open_amber,open_red,next_due,auto_done,manual_done,
  consignee_name,shipper_name,cust_contact,cust_phone,cust_email,vessel_voyage,container_summary,container_count,
  total_weight,total_cbm,arrival_state,sort_key,milestone_checklist,updated_at)
  VALUES(@job,@station,@mode,@cargo,@bound,@lane,@carrier,@cust,@salesman,@pic,@cby,@uby,@anchor,@etd,@eta,@atd,@ata,
  @jstat,@worst,@amber,@red,@nextdue,@auto,@man,@cgname,@shipname,@ccontact,@cphone,@cemail,@vv,@csum,@ccount,
  @twgt,@tcbm,@astate,@skey,@chk,SYSDATETIME());
"@
function DOnly($d){ if($d -is [datetime]){ $d.ToString('yyyy-MM-dd') } else { $null } }
$n=0; $dist=@{G=0;A=0;R=0}
foreach($b in $ships){
  $ship= if($Mode -eq 'Air'){ New-AirContext $b } else { New-ShipContext $b }
  $S=@{ ship=$ship; asof=$AsOf; lead=$LeadDays; bound=$ship.bound; evmap=$evmap; picDocs=@($picByJob["$($b.jobn)"]) }
  $res=Eval-Milestones $S $defs $null
  $cust = if($ship.bound -eq 'Import'){ "$($b.cgne_code)".Trim() } else { "$($b.shpr_code)".Trim() }
  $pic  = if($ship.picuser){$ship.picuser}else{$ship.crtuser}
  $lane = (("$($b.pol)").Trim()+ ' -> ' + ("$($b.pod)").Trim())
  $cgname=("$($b.cgne_name)").Trim(); $shipname=("$($b.shpr_name)").Trim()
  $contact=$contactByCode[$cust]
  $ccontact = if($contact){ ("$($contact.contact1)").Trim() } else { '' }
  $cphone   = if($contact){ ("$($contact.phone1)").Trim() } else { '' }
  $cemail   = if($contact){ ("$($contact.email1)").Trim() } else { '' }
  # mode-specific: conveyance (vessel/voyage | airline+flight), cargo profile, departure/arrival anchors
  if($Mode -eq 'Air'){
    $fl=("$($b.flight1)").Trim(); $cr=("$($b.carr)").Trim()
    $vv = if($fl -and $cr){ "$cr $fl" } elseif($fl){ $fl } elseif($cr){ $cr } else { '' }
    $q=[int]("0"+"$($b.t_book_qty)"); $w=[double]("0"+"$($b.t_book_wgt)")
    $cp = @{ summary=$(if($q -gt 0){"$q pcs"}else{$null}); count=$q; wgt=$(if($w -gt 0){[math]::Round($w,2)}else{$null}); cbm=$null }
    $etdV=$null; $etaV=$null; $atdV=$ship.atd_date; $ataV=$ship.ata_date
    $dep=$ship.atd_date; $eta=$null; $assigned=($fl -ne '' -or $cr -ne '')
  } else {
    $vsl=("$($b.vessel_1)").Trim(); $voy=("$($b.voyage_1)").Trim()
    $vv = if($vsl -and $voy){ "$vsl / $voy" } elseif($vsl){ $vsl } elseif($voy){ $voy } else { '' }
    $cp = ContSummary @($contByRef["$($b.ref)"])
    $etdV=$ship.departure1; $etaV=$ship.eta_delivery; $atdV=$ship.atd_date; $ataV=$ship.ata_date
    $dep=$ship.departure1; $eta=$ship.eta_delivery; $assigned=($vsl -ne '' -or $voy -ne '')
  }
  # arrival bucket + sort_key (import: ETA-first then time-in-transit; export: space/customs/cargo)
  $ata=$ship.ata_date
  if($ship.bound -eq 'Import'){
    if($ata -is [datetime]){ $astate='arrived'; $skey=$ata }
    elseif($dep -is [datetime]){ $astate='arriving'; $skey=$(if($eta -is [datetime]){$eta}else{$dep}) }
    else { $astate='planning'; $skey=$ship.crtdate }
  } else {
    if(-not $assigned){ $astate='no_space'; $skey=$dep }
    elseif($dep -is [datetime] -and ($dep - $AsOf).TotalDays -le 3 -and $ship.declaration -ne '1'){ $astate='customs_window'; $skey=$dep }
    elseif($Mode -ne 'Air' -and -not ($ship.cargoready -is [datetime])){ $astate='cargo_pending'; $skey=$dep }
    else { $astate='on_track'; $skey=$dep }
  }
  if(-not $cgname){$cgname=$null}; if(-not $shipname){$shipname=$null}
  if(-not $ccontact){$ccontact=$null}; if(-not $cphone){$cphone=$null}; if(-not $cemail){$cemail=$null}; if(-not $vv){$vv=$null}
  $checklist = @{ shipment=@{ job_no="$($b.jobn)"; mode=$Mode; bound=$ship.bound; cargo_type=$ship.cargo_type; lane=$lane;
                    carrier=("$($b.carr)").Trim(); anchor=(DOnly $ship.crtdate); etd=(DOnly $etdV); eta=(DOnly $etaV); atd=(DOnly $atdV); ata=(DOnly $ataV);
                    consignee_name=$cgname; shipper_name=$shipname; cust_contact=$ccontact; cust_phone=$cphone; cust_email=$cemail;
                    vessel_voyage=$vv; container_summary=$cp.summary; container_count=$cp.count; total_weight=$cp.wgt; total_cbm=$cp.cbm; arrival_state=$astate };
                  milestones=$res.items; rollup=@{ worst_light=$res.worst; open_amber=$res.open_amber; open_red=$res.open_red; next_due=$res.next_due; automation=@{auto=$res.auto_done; manual=$res.manual_done} } }
  Exec $merge @{ job="$($b.jobn)"; station=$StationCode; mode=$Mode; cargo=$ship.cargo_type; bound=$ship.bound; lane=$lane;
    carrier=("$($b.carr)").Trim(); cust=$cust; salesman=$ship.salesman; pic=$pic; cby=$ship.crtuser; uby=$ship.upduser;
    anchor=(DOnly $ship.crtdate); etd=(DOnly $etdV); eta=(DOnly $etaV); atd=(DOnly $atdV); ata=(DOnly $ataV);
    jstat='active'; worst=$res.worst; amber=$res.open_amber; red=$res.open_red; nextdue=$res.next_due; auto=$res.auto_done; man=$res.manual_done;
    cgname=$cgname; shipname=$shipname; ccontact=$ccontact; cphone=$cphone; cemail=$cemail; vv=$vv;
    csum=$cp.summary; ccount=$cp.count; twgt=$cp.wgt; tcbm=$cp.cbm; astate=$astate; skey=(DOnly $skey);
    chk=($checklist | ConvertTo-Json -Depth 8 -Compress) }
  $dist[$res.worst]++; $n++
}
$opsCn.Close()
Write-Host "Seeded $n $Mode shipment_alerts rows for $StationCode (as of $($AsOf.ToString('yyyy-MM-dd')))." -ForegroundColor Green
Write-Host ("  worst_light:  R={0}  A={1}  G={2}" -f $dist.R,$dist.A,$dist.G) -ForegroundColor Cyan
