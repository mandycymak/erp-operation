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
# Keep only the wanted columns that actually exist in this station's table (ERP schema drifts slightly between
# stations, e.g. HAM's blhead lacks 'picuser'). Missing columns are dropped from the SELECT; New-*Context then
# sees them as $null. Table names are hardcoded literals (safe to interpolate).
function Filter-Cols($db,$table,$wantCsv){
  $want=@($wantCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $have=@{}; foreach($r in (Query $db "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='$table'")){ $have["$($r.COLUMN_NAME)".ToLower()]=1 }
  $keep=@($want | Where-Object { $have[$_.ToLower()] })
  $miss=@($want | Where-Object { -not $have[$_.ToLower()] })
  if($miss.Count){ Write-Host "  [schema] $db.$table missing (dropped): $($miss -join ',')" -ForegroundColor DarkYellow }
  ($keep -join ',')
}

# ---- config ----
$defs = Query $opsDb "SELECT milestone_code,bound,name,seq,phase_anchor,qualify_rule,complete_rule,sla_type,sla_offset_val,sla_offset_unit,sla_direction,sla_anchor,mode FROM dbo.milestone_def WHERE active=1"
$evmap = Query $opsDb "SELECT milestone_code,bound,source_kind,source_table,source_field,match_value,module_match FROM dbo.milestone_evidence_map WHERE active=1"

# ---- candidate shipments: active house bills/AWBs as of AsOf, recent first (mode-specific source table) ----
if($Mode -eq 'Air'){
  # awbhead = the air waybill table; awb_type H=house, S=straight/direct are the operator's shipments (M=consol master, B=booking)
  $cols="jobn,hawb,mawb,po_no,frt_terms,routing,booking,bound,awb_type,flight1,carr,pol,pod,shpr_code,shpr_name,cgne_code,cgne_name,agn2_code,rcustomer,ref,picuser,crtuser,upduser,status,declaration_complete,atd_date,ata_date,cargoready,f_date1,inform_cnee,cnee_pickup,customer_pickup,comp_date,crtdate,t_book_qty,t_book_wgt,t_book_cwt,t_rece_qty,ttl_cwt"
  $cols=Filter-Cols $Station 'awbhead' $cols
  $ships = Query $Station "SELECT TOP $Limit $cols FROM dbo.awbhead WHERE awb_type IN('H','S') AND bound IN('O','I') AND crtdate<=@a AND comp_date IS NULL ORDER BY crtdate DESC" @{ a=$AsOf.ToString('yyyy-MM-dd') }
} else {
  $cols="jobn,blno,mobl,bound,frttype,routing,pol,pod,carr,salesman,picuser,crtuser,upduser,status,declaration,shpr_code,shpr_name,cgne_code,cgne_name,agn2_code,rcustomer,ref,vessel_1,voyage_1,vessel_2,voyage_2,onboard1,cargoready,cargorece,customs_clearance,ts_blno,ams_hbl,edidate,atd_date,eta_delivery,goods_delivery,comp_date,ata_date,not1_date,release_date,broker,customer_pickup,wh_code,ad_date,ware_date,pd_date,departure2,crtdate"
  $cols=Filter-Cols $Station 'blhead' $cols
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
    $cont = Query $Station "SELECT blh, cont_type, load_wgt, load_cbm, container, lsno, liner FROM dbo.blcont WHERE blh IN ($($ins -join ','))" $p
    foreach($d in $cont){ $k="$($d.blh)"; if(-not $contByRef.ContainsKey($k)){ $contByRef[$k]=@() }; $contByRef[$k]+=$d }
  }
}

# ---- resolve vessel codes -> names from the veslmstr master (sea only). One chunked keyed seek on
#      veslmstr.code (its PK), same shape as the custsub seek below; the request path never reads the
#      master. Export carries the ocean vessel in vessel_2, Import the arriving vessel in vessel_1 — we
#      collect both code columns so either bound resolves. ----
$vslByCode=@{}
if($Mode -ne 'Air'){
  $vslCodes=@($ships | ForEach-Object { ("$($_.vessel_1)").Trim(); ("$($_.vessel_2)").Trim() } | Where-Object { $_ } | Select-Object -Unique)
  for($off=0; $off -lt $vslCodes.Count; $off+=500){
    $chunk=@($vslCodes[$off..([Math]::Min($off+499,$vslCodes.Count-1))])
    $p=@{}; $ins=@(); $i=0; foreach($cd in $chunk){ $ins+="@v$i"; $p["v$i"]=$cd; $i++ }
    $rows = Query $Station "SELECT code, short_name FROM dbo.veslmstr WHERE code IN ($($ins -join ','))" $p
    foreach($d in $rows){ $k="$($d.code)".Trim(); if($k -and -not $vslByCode.ContainsKey($k)){ $vslByCode[$k]=("$($d.short_name)").Trim() } }
  }
}

# ---- resolve EVERY involved company (shipper/consignee/agent/controlling-customer) from the customer master
#      in ONE indexed seek on custsub.code2 (its clustered PK). We deliberately do NOT use
#      consignee_view/shipper_view/agent_view here: each wraps custsub with a usermstr join + per-row scalar
#      UDFs (dbo.cgagent ×3, dbo.portname) + correlated subqueries (airquoh/qsh/custsubd/zpa), which force
#      row-by-row execution and would crawl on a 300k-row master. A keyed IN-seek of only the codes on the
#      active worklist stays fast at any master size. This one result feeds BOTH the per-shipment contact card
#      and the company_dim picker. Chunked to respect SQL's ~2100-parameter cap (active companies are bounded
#      by active shipments, so this is 1-to-few chunks). The UI/request path never reads the master at all.
$allCodes=@($ships | ForEach-Object { ("$($_.shpr_code)").Trim(); ("$($_.cgne_code)").Trim(); ("$($_.agn2_code)").Trim(); ("$($_.rcustomer)").Trim() } | Where-Object { $_ } | Select-Object -Unique)
$custByCode=@{}
for($off=0; $off -lt $allCodes.Count; $off+=500){
  $chunk=@($allCodes[$off..([Math]::Min($off+499,$allCodes.Count-1))])
  $p=@{}; $ins=@(); $i=0; foreach($cd in $chunk){ $ins+="@c$i"; $p["c$i"]=$cd; $i++ }
  $rows = Query $Station "SELECT code2, doc_e_name, contact1, phone1, email1 FROM dbo.custsub WHERE code2 IN ($($ins -join ',')) AND ISNULL(isdel,0)=0" $p
  foreach($d in $rows){ $k="$($d.code2)".Trim(); if($k -and -not $custByCode.ContainsKey($k)){ $custByCode[$k]=$d } }
}
$contactByCode=$custByCode   # per-shipment contact card reads .contact1/.phone1/.email1 off the same custsub row

# ---- company_dim: upsert code->name for every involved company. Names were already resolved above in the
#      single custsub seek (no extra master query here), so the picker shows real names while the request
#      path only ever reads the small pgsops.company_dim. ----
if($allCodes.Count){
  $compMerge=@"
MERGE dbo.company_dim AS t USING (SELECT @code code) s ON t.code=s.code
WHEN MATCHED THEN UPDATE SET name=@name,updated_at=SYSDATETIME()
WHEN NOT MATCHED THEN INSERT(code,name,updated_at) VALUES(@code,@name,SYSDATETIME());
"@
  foreach($cd in $allCodes){ $nm=$(if($custByCode.ContainsKey($cd)){("$($custByCode[$cd].doc_e_name)").Trim()}else{''}); if(-not $nm){$nm=$null}; Exec $compMerge @{ code=$cd; name=$nm } }
}

# build a "count×type + … " cargo summary + totals from a job's container rows
function ContSummary($rows){
  if(-not $rows -or -not $rows.Count){ return @{ summary=$null; count=0; wgt=$null; cbm=$null; first_cont=$null; liner_so=$null; liner=$null } }
  $byType=[ordered]@{}; $wgt=0.0; $cbm=0.0; $hasCbm=$false; $firstCont=$null; $linerSo=$null; $liner=$null
  foreach($r in $rows){
    $t="$($r.cont_type)".Trim(); if(-not $t){ $t='?' }
    if($byType.Contains($t)){ $byType[$t]++ } else { $byType[$t]=1 }
    if($null -ne $r.load_wgt){ $wgt += [double]$r.load_wgt }
    if($null -ne $r.load_cbm){ $c=[double]$r.load_cbm; $cbm += $c; if($c -gt 0){ $hasCbm=$true } }
    $cnum="$($r.container)".Trim(); if($cnum -and -not $firstCont){ $firstCont=$cnum }
    $lso="$($r.lsno)".Trim();      if($lso  -and -not $linerSo){ $linerSo=$lso }
    $ln="$($r.liner)".Trim();      if($ln   -and -not $liner){ $liner=$ln }
  }
  $parts=@(); foreach($k in $byType.Keys){ $parts += ("{0}x{1}" -f $byType[$k], $k) }
  @{ summary=($parts -join ' + '); count=$rows.Count; wgt=[math]::Round($wgt,2); cbm=$(if($hasCbm){[math]::Round($cbm,2)}else{$null}); first_cont=$firstCont; liner_so=$linerSo; liner=$liner }
}

$merge=@"
MERGE dbo.shipment_alerts AS t USING (SELECT @job job_no) s ON t.job_no=s.job_no
WHEN MATCHED THEN UPDATE SET station=@station,mode=@mode,cargo_type=@cargo,bound=@bound,lane=@lane,carrier=@carrier,
  cust_code=@cust,salesman=@salesman,pic_user=@pic,created_by=@cby,last_updated_by=@uby,anchor_date=@anchor,
  etd=@etd,eta=@eta,atd=@atd,ata=@ata,job_status=@jstat,worst_light=@worst,open_amber=@amber,open_red=@red,
  next_due=@nextdue,auto_done=@auto,manual_done=@man,consignee_name=@cgname,shipper_name=@shipname,
  cust_contact=@ccontact,cust_phone=@cphone,cust_email=@cemail,vessel_voyage=@vv,container_summary=@csum,
  container_count=@ccount,total_weight=@twgt,total_cbm=@tcbm,arrival_state=@astate,sort_key=@skey,
  house_bill=@house,master_bill=@master,incoterm=@inco,cust_ref=@cref,container_no=@cno,liner_so=@lso,cargo_ready=@cready,
  shipper_code=@shpr,consignee_code=@cgne,agent_code=@agent,ctrl_code=@ctrl,pol=@pol,pod=@pod,
  milestone_checklist=@chk,updated_at=SYSDATETIME()
WHEN NOT MATCHED THEN INSERT(job_no,station,mode,cargo_type,bound,lane,carrier,cust_code,salesman,pic_user,created_by,
  last_updated_by,anchor_date,etd,eta,atd,ata,job_status,worst_light,open_amber,open_red,next_due,auto_done,manual_done,
  consignee_name,shipper_name,cust_contact,cust_phone,cust_email,vessel_voyage,container_summary,container_count,
  total_weight,total_cbm,arrival_state,sort_key,house_bill,master_bill,incoterm,cust_ref,container_no,liner_so,cargo_ready,
  shipper_code,consignee_code,agent_code,ctrl_code,pol,pod,milestone_checklist,updated_at)
  VALUES(@job,@station,@mode,@cargo,@bound,@lane,@carrier,@cust,@salesman,@pic,@cby,@uby,@anchor,@etd,@eta,@atd,@ata,
  @jstat,@worst,@amber,@red,@nextdue,@auto,@man,@cgname,@shipname,@ccontact,@cphone,@cemail,@vv,@csum,@ccount,
  @twgt,@tcbm,@astate,@skey,@house,@master,@inco,@cref,@cno,@lso,@cready,
  @shpr,@cgne,@agent,@ctrl,@pol,@pod,@chk,SYSDATETIME());
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
  # mode-specific: conveyance (vessel/voyage | airline+flight), cargo profile, departure/arrival anchors,
  # reference docs (house/master bill, incoterm, customer PO, container/liner-SO), cargo-ready date.
  if($Mode -eq 'Air'){
    $fl=("$($b.flight1)").Trim(); $cr=("$($b.carr)").Trim()
    $vv = if($fl -and $cr){ "$cr $fl" } elseif($fl){ $fl } elseif($cr){ $cr } else { '' }
    # booking estimates (t_book_*) are empty once an AWB is issued — fall back to actual received pcs / total
    # chargeable weight so shipped air jobs still show their cargo profile
    $q=[int]("0"+"$($b.t_book_qty)"); if($q -le 0){ $q=[int]("0"+"$($b.t_rece_qty)") }
    $w=[double]("0"+"$($b.t_book_wgt)"); if($w -le 0){ $w=[double]("0"+"$($b.ttl_cwt)") }
    $cp = @{ summary=$(if($q -gt 0){"$q pcs"}else{$null}); count=$q; wgt=$(if($w -gt 0){[math]::Round($w,2)}else{$null}); cbm=$null; first_cont=$null; liner_so=$null; liner=$null }
    $etdV=$ship.f_date1; $etaV=$null; $atdV=$ship.atd_date; $ataV=$ship.ata_date
    $dep=$ship.atd_date; $eta=$null; $assigned=($fl -ne '' -or $cr -ne '')
    $houseBill=$ship.hawb; $masterBill=$ship.mawb; $incoterm=$ship.incoterm; $custRef=$ship.po_no
    $cargoReady=$ship.cargoready; $carrierVal=$cr
  } else {
    # Export carries the ocean vessel in vessel_2/voyage_2; Import the arriving vessel in vessel_1/voyage_1.
    if($ship.bound -eq 'Export'){ $vcode=("$($b.vessel_2)").Trim(); $voy=("$($b.voyage_2)").Trim() }
    else                        { $vcode=("$($b.vessel_1)").Trim(); $voy=("$($b.voyage_1)").Trim() }
    $vsl = if($vcode -and $vslByCode[$vcode]){ $vslByCode[$vcode] } else { $vcode }   # name, fallback to code
    $vv = if($vsl -and $voy){ "$vsl / $voy" } elseif($vsl){ $vsl } elseif($voy){ $voy } else { '' }
    $cp = ContSummary @($contByRef["$($b.ref)"])
    $etdV=$ship.departure2; $etaV=$ship.eta_delivery; $atdV=$ship.atd_date; $ataV=$ship.ata_date
    $dep=$ship.departure2; $eta=$ship.eta_delivery; $assigned=($vsl -ne '' -or $voy -ne '')
    $houseBill=("$($b.blno)").Trim(); $masterBill=("$($b.mobl)").Trim(); $incoterm=$ship.incoterm; $custRef=''
    $cargoReady=$ship.cargoready
    $carrierVal=("$($b.carr)").Trim(); if(-not $carrierVal -and $cp.liner){ $carrierVal=$cp.liner }   # carr is empty in these copies -> use blcont.liner
  }
  $containerNo=$cp.first_cont; $linerSo=$cp.liner_so
  # party/port codes for the worklist filters (company filter matches the picked code against ANY role)
  $shprCode=("$($b.shpr_code)").Trim(); $cgneCode=("$($b.cgne_code)").Trim()
  $agentCode=("$($b.agn2_code)").Trim(); $ctrlCode=("$($b.rcustomer)").Trim()
  $polCode=("$($b.pol)").Trim(); $podCode=("$($b.pod)").Trim()
  # arrival bucket + sort_key (import: ETA-first then time-in-transit; export: space/customs/cargo).
  # Export sort falls back dep -> cargo-ready -> booking date so even un-booked jobs sort by real urgency.
  $ata=$ship.ata_date
  $expSort=$(if($dep -is [datetime]){$dep}elseif($cargoReady -is [datetime]){$cargoReady}else{$ship.crtdate})
  if($ship.bound -eq 'Import'){
    if($ata -is [datetime]){ $astate='arrived'; $skey=$ata }
    elseif($dep -is [datetime]){ $astate='arriving'; $skey=$(if($eta -is [datetime]){$eta}else{$dep}) }
    else { $astate='planning'; $skey=$ship.crtdate }
  } else {
    if(-not $assigned){ $astate='no_space'; $skey=$expSort }
    elseif($dep -is [datetime] -and ($dep - $AsOf).TotalDays -le 3 -and $ship.declaration -ne '1'){ $astate='customs_window'; $skey=$dep }
    elseif($Mode -ne 'Air' -and -not ($ship.cargoready -is [datetime])){ $astate='cargo_pending'; $skey=$expSort }
    else { $astate='on_track'; $skey=$dep }
  }
  if(-not $cgname){$cgname=$null}; if(-not $shipname){$shipname=$null}
  if(-not $ccontact){$ccontact=$null}; if(-not $cphone){$cphone=$null}; if(-not $cemail){$cemail=$null}; if(-not $vv){$vv=$null}
  if(-not $houseBill){$houseBill=$null}; if(-not $masterBill){$masterBill=$null}; if(-not $incoterm){$incoterm=$null}
  if(-not $custRef){$custRef=$null}; if(-not $containerNo){$containerNo=$null}; if(-not $linerSo){$linerSo=$null}
  if(-not $shprCode){$shprCode=$null}; if(-not $cgneCode){$cgneCode=$null}; if(-not $agentCode){$agentCode=$null}
  if(-not $ctrlCode){$ctrlCode=$null}; if(-not $polCode){$polCode=$null}; if(-not $podCode){$podCode=$null}
  $checklist = @{ shipment=@{ job_no="$($b.jobn)"; mode=$Mode; bound=$ship.bound; cargo_type=$ship.cargo_type; lane=$lane;
                    carrier=$carrierVal; anchor=(DOnly $ship.crtdate); etd=(DOnly $etdV); eta=(DOnly $etaV); atd=(DOnly $atdV); ata=(DOnly $ataV);
                    consignee_name=$cgname; shipper_name=$shipname; cust_contact=$ccontact; cust_phone=$cphone; cust_email=$cemail;
                    vessel_voyage=$vv; container_summary=$cp.summary; container_count=$cp.count; total_weight=$cp.wgt; total_cbm=$cp.cbm; arrival_state=$astate;
                    house_bill=$houseBill; master_bill=$masterBill; incoterm=$incoterm; cust_ref=$custRef; container_no=$containerNo; liner_so=$linerSo; cargo_ready=(DOnly $cargoReady) };
                  milestones=$res.items; rollup=@{ worst_light=$res.worst; open_amber=$res.open_amber; open_red=$res.open_red; next_due=$res.next_due; automation=@{auto=$res.auto_done; manual=$res.manual_done} } }
  Exec $merge @{ job="$($b.jobn)"; station=$StationCode; mode=$Mode; cargo=$ship.cargo_type; bound=$ship.bound; lane=$lane;
    carrier=$carrierVal; cust=$cust; salesman=$ship.salesman; pic=$pic; cby=$ship.crtuser; uby=$ship.upduser;
    anchor=(DOnly $ship.crtdate); etd=(DOnly $etdV); eta=(DOnly $etaV); atd=(DOnly $atdV); ata=(DOnly $ataV);
    jstat='active'; worst=$res.worst; amber=$res.open_amber; red=$res.open_red; nextdue=$res.next_due; auto=$res.auto_done; man=$res.manual_done;
    cgname=$cgname; shipname=$shipname; ccontact=$ccontact; cphone=$cphone; cemail=$cemail; vv=$vv;
    csum=$cp.summary; ccount=$cp.count; twgt=$cp.wgt; tcbm=$cp.cbm; astate=$astate; skey=(DOnly $skey);
    house=$houseBill; master=$masterBill; inco=$incoterm; cref=$custRef; cno=$containerNo; lso=$linerSo; cready=(DOnly $cargoReady);
    shpr=$shprCode; cgne=$cgneCode; agent=$agentCode; ctrl=$ctrlCode; pol=$polCode; pod=$podCode;
    chk=($checklist | ConvertTo-Json -Depth 8 -Compress) }
  $dist[$res.worst]++; $n++
}
$opsCn.Close()
Write-Host "Seeded $n $Mode shipment_alerts rows for $StationCode (as of $($AsOf.ToString('yyyy-MM-dd')))." -ForegroundColor Green
Write-Host ("  worst_light:  R={0}  A={1}  G={2}" -f $dist.R,$dist.A,$dist.G) -ForegroundColor Cyan
