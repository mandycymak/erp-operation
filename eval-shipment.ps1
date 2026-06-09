<#
  eval-shipment.ps1  (read-only DEMO — NOT the listener)
  Evaluates ONE shipment against the seeded milestone config, as of a reference date, and prints a
  milestone card. Proves the completion model end-to-end without the scheduled listener:
    qualify (data-driven: not every milestone applies) -> complete via ERP DATA FIRST
    -> else PIC/EDI EVIDENCE (secondary) -> else PLANNED due-window (fixed offset / anchor proxy) -> light.
  Reads milestone_def + milestone_evidence_map from pgsops; reads ONE blhead row (+PIC) from a station DB.
  Source ERP is READ-ONLY.  Usage: .\eval-shipment.ps1 [-Station pgshkg] [-AsOf 2023-04-10] [-JobNo HKGSE2300xxx]
#>
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot "ops.config.json"),
  [string]$Station = "pgshkg",
  [datetime]$AsOf = [datetime]"2023-04-10",
  [string]$JobNo = "",
  [int]$DefaultLeadDays = 4          # planned fallback when no baseline: pre-departure milestones due ETD - N days
)
$ErrorActionPreference="Stop"
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
function Query($db,$sql,[hashtable]$p){   # returns array of pscustomobject, with transient retry
  for($a=1;;$a++){ try{
    $cn=New-Object System.Data.SqlClient.SqlConnection (CS $db); $cn.Open()
    $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=60
    if($p){foreach($k in $p.Keys){[void]$c.Parameters.AddWithValue("@$k",$p[$k])}}
    $r=$c.ExecuteReader(); $rows=@()
    while($r.Read()){ $o=[ordered]@{}; for($i=0;$i -lt $r.FieldCount;$i++){ $v=$r.GetValue($i); $o[$r.GetName($i)]= if($v -is [DBNull]){$null}else{$v} }; $rows+=[pscustomobject]$o }
    $r.Close(); $cn.Close(); return ,$rows
  } catch { if($a -ge 5 -or -not (Test-Transient $_.Exception)){throw}; Start-Sleep -Seconds ($a*2) } }
}

# ---- load config ----
$defs = Query $opsDb "SELECT milestone_code,bound,name,seq,phase_anchor,qualify_rule,complete_rule,sla_type,sla_offset_val,sla_offset_unit,sla_direction,sla_anchor FROM dbo.milestone_def WHERE active=1 ORDER BY bound,seq"
$evmap = Query $opsDb "SELECT milestone_code,bound,source_kind,source_table,source_field,match_value,module_match FROM dbo.milestone_evidence_map WHERE active=1"

# ---- pick the shipment (most-recent in-flight Export house bill as of AsOf, unless -JobNo given) ----
$asofS = $AsOf.ToString('yyyy-MM-dd')
if($JobNo){
  $shipRows = Query $Station "SELECT TOP 1 * FROM dbo.blhead WHERE jobn=@j AND bill_type='H'" @{ j=$JobNo }
} else {
  $shipRows = Query $Station "SELECT TOP 1 * FROM dbo.blhead WHERE bill_type='H' AND bound='O' AND crtdate<=@a AND (atd_date IS NULL OR atd_date>@a) ORDER BY crtdate DESC" @{ a=$asofS }
}
if(-not $shipRows -or $shipRows.Count -eq 0){ Write-Host "No matching shipment in $Station as of $asofS." -ForegroundColor Red; exit }
$b = $shipRows[0]
$bound = switch("$($b.bound)"){ 'O'{'Export'} 'I'{'Import'} default {'Other'} }
$cargo = switch -regex ("$($b.frttype)"){ 'CY|FCL'{'FCL'} 'CFS|LCL'{'LCL'} default {$null} }
$jobn = "$($b.jobn)"

# ship context: real blhead columns the rules reference + derived fields
function D($x){ if($null -eq $x -or "$x" -eq ''){$null}else{[datetime]$x} }
$ship = @{
  mode='Sea'; bound=$bound; cargo_type=$cargo
  incoterm = ("$($b.routing)").Substring(0,[Math]::Min(8,("$($b.routing)").Length)).Trim()
  blno=$b.blno; picuser=$b.picuser; status=$b.status; declaration= if($b.declaration -eq $true){'1'}else{'0'}
  onboard1=(D $b.onboard1); cargoready=(D $b.cargoready); cargorece=(D $b.cargorece)
  customs_clearance=(D $b.customs_clearance); ts_blno=$b.ts_blno; ams_hbl=$b.ams_hbl; edidate=(D $b.edidate)
  atd_date=(D $b.atd_date); eta_delivery=(D $b.eta_delivery); goods_delivery=(D $b.goods_delivery)
  comp_date=(D $b.comp_date); ata_date=(D $b.ata_date); not1_date=(D $b.not1_date); release_date=(D $b.release_date)
  broker=$b.broker; customer_pickup=(D $b.customer_pickup); wh_code=$b.wh_code; ad_date=(D $b.ad_date)
  ware_date=(D $b.ware_date); pd_date=(D $b.pd_date); departure1=(D $b.departure1); crtdate=(D $b.crtdate)
}
function FieldVal($f){ if($ship.ContainsKey($f)){ $ship[$f] } else { $null } }
function HasVal($f){ $v=FieldVal $f; $null -ne $v -and "$v" -ne '' }

# ---- PIC evidence present for this job (link by jobn; HKG SEA rows carry jobn) ----
$picDocs = @()
if($jobn){ $picDocs = Query $Station "SELECT module, doctype, MIN(pdte) firstdate FROM dbo.PIC WHERE jobn=@j AND NULLIF(doctype,'') IS NOT NULL GROUP BY module, doctype" @{ j=$jobn } }
function EvidenceFor($code){   # returns @{matched=$bool; date=..; via=..}
  $rows = $evmap | Where-Object { $_.milestone_code -eq $code -and $_.bound -eq $bound }
  foreach($e in $rows){
    if($e.source_kind -eq 'pic_doctype'){
      $hit = $picDocs | Where-Object { "$($_.doctype)" -eq "$($e.match_value)" -and ($null -eq $e.module_match -or "$($_.module)" -eq "$($e.module_match)") } | Select-Object -First 1
      if($hit){ return @{matched=$true; date=$hit.firstdate; via="PIC doctype '$($e.match_value)'"} }
    }
    # edi_log etc.: not populated in this snapshot; mechanism present, returns no match here
  }
  return @{matched=$false}
}

# ---- rule evaluator ----
function EvalCond($cond, [bool]$allowEvidence, $code){
  switch("$($cond.kind)"){
    'field_notnull' { return (HasVal $cond.field) }
    'field_eq'      { return ((HasVal $cond.field) -and ("$(FieldVal $cond.field)" -ieq "$($cond.value)")) }
    'field_in'      { $v="$(FieldVal $cond.field)"; return ($cond.set | Where-Object { "$_" -ieq $v }).Count -gt 0 }
    'mode_eq'       { return ("$($ship.mode)" -ieq "$($cond.value)") }
    'date_passed'   { $v=FieldVal $cond.field; return ($v -is [datetime] -and $v -le $AsOf) }
    'evidence'      { if(-not $allowEvidence){return $false}; return (EvidenceFor $code).matched }
    default         { return $false }
  }
}
function EvalRule($json, [bool]$allowEvidence, $code){
  if(-not $json){ return $true }
  $rule = $json | ConvertFrom-Json
  $conds = @($rule.conds)
  if($conds.Count -eq 0){ return $true }                       # empty AND/OR-> always (used for "always")
  $results = $conds | ForEach-Object { EvalCond $_ $allowEvidence $code }
  if("$($rule.op)" -eq 'OR'){ return ($results -contains $true) } else { return -not ($results -contains $false) }
}
# which data field closed it (for display)
function ClosingField($json,$code){
  $rule=$json|ConvertFrom-Json
  foreach($c in @($rule.conds)){ if($c.kind -in 'field_notnull','field_eq','field_in' -and (EvalCond $c $false $code)){ return $c.field } }
  return $null
}
function PlannedDue($d){
  # fixed: offset off its named anchor (e.g. AMS 3d before onboard). baseline w/ no baseline table yet:
  # planned fallback per user -> pre-departure milestones due ETD - DefaultLeadDays; if ETD unknown, NO time-gate.
  if("$($d.sla_type)" -eq 'fixed' -and $d.sla_anchor){
    $base = FieldVal $d.sla_anchor; if(-not ($base -is [datetime])){ return $null }
    $off = [int]$d.sla_offset_val; if("$($d.sla_direction)" -eq 'before'){ $off = -$off }
    if("$($d.sla_offset_unit)" -eq 'hour'){ return $base.AddHours($off) } else { return $base.AddDays($off) }
  } elseif("$($d.sla_type)" -eq 'baseline'){
    if("$($d.phase_anchor)" -in 'booking','etd'){
      $etd = if($ship.departure1){$ship.departure1}elseif($ship.eta_delivery){$ship.eta_delivery}else{$null}
      if($etd -is [datetime]){ return $etd.AddDays(-$DefaultLeadDays) }
    }
    return $null   # post-departure baseline, or ETD unknown -> no time-gate until real baselines exist
  }
  return $null     # 'none' = continuous / no time-gate
}
function Light($due){
  if(-not ($due -is [datetime])){ return 'G' }                 # no time-gate -> Green (per blueprint)
  $start=$ship.crtdate; if(-not ($start -is [datetime])){ return $(if($AsOf -gt $due){'R'}else{'G'}) }
  if($due -le $start){ return $(if($AsOf -ge $due){'R'}else{'G'}) }
  $pct = ($AsOf - $start).TotalSeconds / ($due - $start).TotalSeconds
  if($pct -gt 0.9){'R'} elseif($pct -ge 0.7){'A'} else {'G'}
}

# ---- evaluate every def for this bound ----
Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host (" Shipment {0}   {1} / Sea / {2}   station={3}   AS OF {4}" -f $jobn,$bound,$(if($cargo){$cargo}else{'?'}),$Station,$asofS) -ForegroundColor Cyan
Write-Host (" pol={0} pod={1} carrier={2} crtdate={3} atd={4} eta={5}" -f $b.pol,$b.pod,$b.carr,($ship.crtdate),($ship.atd_date),($ship.eta_delivery)) -ForegroundColor DarkCyan
Write-Host (" PIC docs on job: {0}" -f $(if($picDocs.Count){($picDocs|ForEach-Object{"$($_.module)/$($_.doctype)"}) -join ', '}else{'(none linked by jobn)'})) -ForegroundColor DarkCyan
Write-Host "========================================================================" -ForegroundColor Cyan
$bar=@{G='G ';A='A ';R='R '}
$rowsOut=@()
foreach($d in ($defs | Where-Object { $_.bound -eq $bound })){
  $code=$d.milestone_code
  if(-not (EvalRule $d.qualify_rule $false $code)){ $rowsOut += [pscustomobject]@{seq=$d.seq;code=$code;name=$d.name;light='-';state='n/a (not tracked)';basis=''}; continue }
  $dataDone = EvalRule $d.complete_rule $false $code
  if($dataDone){
    $f=ClosingField $d.complete_rule $code; $dt=FieldVal $f
    $rowsOut += [pscustomobject]@{seq=$d.seq;code=$code;name=$d.name;light='G';state='done (data)';basis="$f=$(if($dt -is [datetime]){$dt.ToString('yyyy-MM-dd')}else{$dt})"}; continue
  }
  $ev = EvidenceFor $code
  if($ev.matched){
    $rowsOut += [pscustomobject]@{seq=$d.seq;code=$code;name=$d.name;light='G';state='done (evidence)';basis="$($ev.via) @ $($ev.date)"}; continue
  }
  $due = PlannedDue $d
  $lt = Light $due
  $basis = if($due -is [datetime]){ "$($d.sla_type) due $($due.ToString('yyyy-MM-dd'))" } else { "no time-gate" }
  $rowsOut += [pscustomobject]@{seq=$d.seq;code=$code;name=$d.name;light=$lt;state='PENDING';basis=$basis}
}
$rowsOut | Format-Table @{l='#';e={$_.seq};w=3}, @{l='L';e={$_.light};w=2}, @{l='Code';e={$_.code};w=5}, @{l='Milestone';e={$_.name};w=28}, @{l='State';e={$_.state};w=18}, basis -Auto | Out-String | Write-Host
$worst = if($rowsOut.light -contains 'R'){'R'}elseif($rowsOut.light -contains 'A'){'A'}else{'G'}
$pend = ($rowsOut | Where-Object {$_.state -eq 'PENDING'}).Count
$na = ($rowsOut | Where-Object {$_.state -like 'n/a*'}).Count
Write-Host (" worst_light={0}   pending={1}   not-tracked={2}   done={3}" -f $worst,$pend,$na,(($rowsOut|Where-Object{$_.state -like 'done*'}).Count)) -ForegroundColor Yellow
