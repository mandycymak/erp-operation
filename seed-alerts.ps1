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
  [datetime]$AsOf=[datetime]"2023-04-10", [int]$Limit=60, [int]$LeadDays=4
)
$ErrorActionPreference="Stop"
. (Join-Path $PSScriptRoot "ops-eval.ps1")
$cfg=Get-Content $ConfigPath -Raw|ConvertFrom-Json
function EnvOrConfig($n,$v){ $e=[Environment]::GetEnvironmentVariable($n); if($e -and $e.Trim()){$e}else{$v} }
$server=EnvOrConfig "DB_SERVER" $cfg.server; $auth=EnvOrConfig "DB_AUTH" $cfg.auth
$user=EnvOrConfig "DB_USER" $cfg.user; $pwd=EnvOrConfig "DB_PASSWORD" $cfg.password; $opsDb=EnvOrConfig "DB_OPS_DB" $cfg.opsDb
$ac= if($auth -eq 'sql'){"User ID=$user;Password=$pwd"}else{"Integrated Security=True"}
function CS($db){ "Server=$server;Database=$db;$ac;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512" }
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
$defs = Query $opsDb "SELECT milestone_code,bound,name,seq,phase_anchor,qualify_rule,complete_rule,sla_type,sla_offset_val,sla_offset_unit,sla_direction,sla_anchor FROM dbo.milestone_def WHERE active=1"
$evmap = Query $opsDb "SELECT milestone_code,bound,source_kind,source_table,source_field,match_value,module_match FROM dbo.milestone_evidence_map WHERE active=1"

# ---- candidate shipments: house bills as of AsOf, still active (not completed), recent first ----
$cols="jobn,blno,bound,frttype,routing,pol,pod,carr,salesman,picuser,crtuser,upduser,status,declaration,shpr_code,cgne_code,onboard1,cargoready,cargorece,customs_clearance,ts_blno,ams_hbl,edidate,atd_date,eta_delivery,goods_delivery,comp_date,ata_date,not1_date,release_date,broker,customer_pickup,wh_code,ad_date,ware_date,pd_date,departure1,crtdate"
$ships = Query $Station "SELECT TOP $Limit $cols FROM dbo.blhead WHERE bill_type='H' AND bound IN('O','I') AND crtdate<=@a AND comp_date IS NULL ORDER BY crtdate DESC" @{ a=$AsOf.ToString('yyyy-MM-dd') }
if(-not $ships.Count){ Write-Host "No candidate shipments in $Station as of $($AsOf.ToString('yyyy-MM-dd'))." -ForegroundColor Red; exit }

# ---- batch PIC evidence for the selected jobns (one query) ----
$jobns=@($ships | ForEach-Object { "$($_.jobn)" } | Where-Object { $_ })
$picByJob=@{}
if($jobns.Count){
  $p=@{}; $ins=@(); $i=0; foreach($j in $jobns){ $ins+="@j$i"; $p["j$i"]=$j; $i++ }
  $pic = Query $Station "SELECT jobn, module, doctype, MIN(pdte) firstdate FROM dbo.PIC WHERE jobn IN ($($ins -join ',')) AND NULLIF(doctype,'') IS NOT NULL GROUP BY jobn, module, doctype" $p
  foreach($d in $pic){ $k="$($d.jobn)"; if(-not $picByJob.ContainsKey($k)){ $picByJob[$k]=@() }; $picByJob[$k]+=$d }
}

$merge=@"
MERGE dbo.shipment_alerts AS t USING (SELECT @job job_no) s ON t.job_no=s.job_no
WHEN MATCHED THEN UPDATE SET station=@station,mode=@mode,cargo_type=@cargo,bound=@bound,lane=@lane,carrier=@carrier,
  cust_code=@cust,salesman=@salesman,pic_user=@pic,created_by=@cby,last_updated_by=@uby,anchor_date=@anchor,
  etd=@etd,eta=@eta,atd=@atd,ata=@ata,job_status=@jstat,worst_light=@worst,open_amber=@amber,open_red=@red,
  next_due=@nextdue,auto_done=@auto,manual_done=@man,milestone_checklist=@chk,updated_at=SYSDATETIME()
WHEN NOT MATCHED THEN INSERT(job_no,station,mode,cargo_type,bound,lane,carrier,cust_code,salesman,pic_user,created_by,
  last_updated_by,anchor_date,etd,eta,atd,ata,job_status,worst_light,open_amber,open_red,next_due,auto_done,manual_done,milestone_checklist,updated_at)
  VALUES(@job,@station,@mode,@cargo,@bound,@lane,@carrier,@cust,@salesman,@pic,@cby,@uby,@anchor,@etd,@eta,@atd,@ata,
  @jstat,@worst,@amber,@red,@nextdue,@auto,@man,@chk,SYSDATETIME());
"@
function DOnly($d){ if($d -is [datetime]){ $d.ToString('yyyy-MM-dd') } else { $null } }
$n=0; $dist=@{G=0;A=0;R=0}
foreach($b in $ships){
  $ship=New-ShipContext $b
  $S=@{ ship=$ship; asof=$AsOf; lead=$LeadDays; bound=$ship.bound; evmap=$evmap; picDocs=@($picByJob["$($b.jobn)"]) }
  $res=Eval-Milestones $S $defs $null
  $cust = if($ship.bound -eq 'Import'){ "$($b.cgne_code)".Trim() } else { "$($b.shpr_code)".Trim() }
  $pic  = if($ship.picuser){$ship.picuser}else{$ship.crtuser}
  $lane = (("$($b.pol)").Trim()+ ' -> ' + ("$($b.pod)").Trim())
  $checklist = @{ shipment=@{ job_no="$($b.jobn)"; mode='Sea'; bound=$ship.bound; cargo_type=$ship.cargo_type; lane=$lane;
                    carrier=("$($b.carr)").Trim(); anchor=(DOnly $ship.crtdate); etd=(DOnly $ship.departure1); eta=(DOnly $ship.eta_delivery); atd=(DOnly $ship.atd_date) };
                  milestones=$res.items; rollup=@{ worst_light=$res.worst; open_amber=$res.open_amber; open_red=$res.open_red; next_due=$res.next_due; automation=@{auto=$res.auto_done; manual=$res.manual_done} } }
  Exec $merge @{ job="$($b.jobn)"; station=$StationCode; mode='Sea'; cargo=$ship.cargo_type; bound=$ship.bound; lane=$lane;
    carrier=("$($b.carr)").Trim(); cust=$cust; salesman=$ship.salesman; pic=$pic; cby=$ship.crtuser; uby=$ship.upduser;
    anchor=(DOnly $ship.crtdate); etd=(DOnly $ship.departure1); eta=(DOnly $ship.eta_delivery); atd=(DOnly $ship.atd_date); ata=(DOnly $ship.ata_date);
    jstat='active'; worst=$res.worst; amber=$res.open_amber; red=$res.open_red; nextdue=$res.next_due; auto=$res.auto_done; man=$res.manual_done;
    chk=($checklist | ConvertTo-Json -Depth 8 -Compress) }
  $dist[$res.worst]++; $n++
}
$opsCn.Close()
Write-Host "Seeded $n shipment_alerts rows for $StationCode (as of $($AsOf.ToString('yyyy-MM-dd')))." -ForegroundColor Green
Write-Host ("  worst_light:  R={0}  A={1}  G={2}" -f $dist.R,$dist.A,$dist.G) -ForegroundColor Cyan
