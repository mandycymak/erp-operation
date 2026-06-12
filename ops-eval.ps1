<#
  ops-eval.ps1  — shared milestone-evaluation library (dot-sourced; no side effects on load).
  Pure evaluation: given a shipment field-context + the seeded config, produce each milestone's
  state/light and the row rollups. DATA-FIRST: complete_rule (ERP fields) is checked before PIC/EDI
  evidence; both before the planned due-window. Used by eval-shipment.ps1 (one card), seed-alerts.ps1
  (batch upsert into shipment_alerts), and later the listener. No DB calls here — callers pass picDocs.
#>

# Build the field-context hashtable the rules reference, from one blhead row. Pure (no DB).
function New-ShipContext($b){
  function D($x){ if($null -eq $x -or "$x" -eq ''){$null}else{[datetime]$x} }
  $routing = "$($b.routing)"
  $bnd = switch("$($b.bound)"){ 'O'{'Export'} 'I'{'Import'} default {'Other'} }
  $ob1=(D $b.onboard1); $ob2=(D $b.onboard2)   # Export rides leg-2 (onboard2); Import leg-1 (onboard1)
  @{
    mode='Sea'
    bound = $bnd
    cargo_type = switch -regex ("$($b.frttype)"){ 'CY|FCL'{'FCL'} 'CFS|LCL'{'LCL'} default {$null} }
    incoterm = $routing.Substring(0,[Math]::Min(8,$routing.Length)).Trim()
    jobn=$b.jobn; blno=$b.blno; picuser=("$($b.picuser)").Trim(); crtuser=("$($b.crtuser)").Trim()
    upduser=("$($b.upduser)").Trim(); status=$b.status
    declaration= if($b.declaration -eq $true){'1'}else{'0'}
    pol=$b.pol; pod=$b.pod; carr=$b.carr; salesman=("$($b.salesman)").Trim()
    onboard1=$ob1; onboard2=$ob2; onboard=$(if($bnd -eq 'Import'){$ob1}else{$ob2})
    cargoready=(D $b.cargoready); cargorece=(D $b.cargorece)
    customs_clearance=(D $b.customs_clearance); ts_blno=$b.ts_blno; ams_hbl=$b.ams_hbl; edidate=(D $b.edidate)
    atd_date=(D $b.atd_date); eta_delivery=(D $b.eta_delivery); goods_delivery=(D $b.goods_delivery)
    comp_date=(D $b.comp_date); ata_date=(D $b.ata_date); not1_date=(D $b.not1_date); release_date=(D $b.release_date)
    broker=("$($b.broker)").Trim(); customer_pickup=(D $b.customer_pickup); wh_code=("$($b.wh_code)").Trim()
    ad_date=(D $b.ad_date); ware_date=(D $b.ware_date); pd_date=(D $b.pd_date)
    departure1=(D $b.departure1); departure2=(D $b.departure2); arrival1=(D $b.arrival1); arrival2=(D $b.arrival2)
    crtdate=(D $b.crtdate)
    ref=$b.ref; vessel_1=("$($b.vessel_1)").Trim(); voyage_1=("$($b.voyage_1)").Trim()
  }
}

# Air variant: build the field-context from one awbhead row. Pure (no DB). mode='Air'.
function New-AirContext($b){
  function D($x){ if($null -eq $x -or "$x" -eq ''){$null}else{[datetime]$x} }
  @{
    mode='Air'
    bound = switch("$($b.bound)"){ 'O'{'Export'} 'I'{'Import'} default {'Other'} }
    cargo_type='AIR'
    jobn=$b.jobn; hawb=("$($b.hawb)").Trim(); mawb=("$($b.mawb)").Trim()
    incoterm=("$($b.routing)").Trim(); frt_terms=("$($b.frt_terms)").Trim(); po_no=("$($b.po_no)").Trim(); booking=("$($b.booking)").Trim()
    picuser=("$($b.picuser)").Trim(); crtuser=("$($b.crtuser)").Trim(); upduser=("$($b.upduser)").Trim(); status=$b.status
    declaration= if($b.declaration_complete -eq $true){'1'}else{'0'}
    pol=$b.pol; pod=$b.pod; carr=("$($b.carr)").Trim(); flight1=("$($b.flight1)").Trim()
    shpr_code=("$($b.shpr_code)").Trim(); cgne_code=("$($b.cgne_code)").Trim()
    atd_date=(D $b.atd_date); ata_date=(D $b.ata_date)
    cargoready=(D $b.cargoready); f_date1=(D $b.f_date1)
    inform_cnee=(D $b.inform_cnee); cnee_pickup=(D $b.cnee_pickup); customer_pickup=(D $b.customer_pickup)
    comp_date=(D $b.comp_date); crtdate=(D $b.crtdate); ref=$b.ref
  }
}

# $S = @{ ship=<hashtable>; asof=<datetime>; lead=<int>; bound=<str>; evmap=<rows>; picDocs=<rows> }
function _FieldVal($S,$f){ if($S.ship.ContainsKey($f)){ $S.ship[$f] } else { $null } }
function _HasVal($S,$f){ $v=_FieldVal $S $f; $null -ne $v -and "$v" -ne '' }

function _EvidenceFor($S,$code){   # @{matched;date;via}
  foreach($e in @($S.evmap | Where-Object { $_.milestone_code -eq $code -and $_.bound -eq $S.bound })){
    if($e.source_kind -eq 'pic_doctype'){
      $hit = $S.picDocs | Where-Object { "$($_.doctype)" -eq "$($e.match_value)" -and ($null -eq $e.module_match -or "$($_.module)" -eq "$($e.module_match)") } | Select-Object -First 1
      if($hit){ return @{matched=$true; date=$hit.firstdate; via="PIC '$($e.match_value)'"} }
    }
    # edi_log / send_log etc.: mechanism present; unpopulated in the snapshot -> no match
  }
  @{matched=$false}
}
function _EvalCond($S,$cond,[bool]$allowEvidence,$code){
  switch("$($cond.kind)"){
    'field_notnull' { return (_HasVal $S $cond.field) }
    'field_eq'      { return ((_HasVal $S $cond.field) -and ("$(_FieldVal $S $cond.field)" -ieq "$($cond.value)")) }
    'field_in'      { $v="$(_FieldVal $S $cond.field)"; return (@($cond.set | Where-Object { "$_" -ieq $v }).Count -gt 0) }
    'mode_eq'       { return ("$($S.ship.mode)" -ieq "$($cond.value)") }
    'date_passed'   { $v=_FieldVal $S $cond.field; return ($v -is [datetime] -and $v -le $S.asof) }
    'evidence'      { if(-not $allowEvidence){return $false}; return (_EvidenceFor $S $code).matched }
    default         { return $false }
  }
}
function _EvalRule($S,$json,[bool]$allowEvidence,$code){
  if(-not $json){ return $true }
  $rule=$json|ConvertFrom-Json; $conds=@($rule.conds)
  if($conds.Count -eq 0){ return $true }
  $res = $conds | ForEach-Object { _EvalCond $S $_ $allowEvidence $code }
  if("$($rule.op)" -eq 'OR'){ return (@($res) -contains $true) } else { return -not (@($res) -contains $false) }
}
function _ClosingField($S,$json,$code){
  $rule=$json|ConvertFrom-Json
  foreach($c in @($rule.conds)){ if($c.kind -in 'field_notnull','field_eq','field_in' -and (_EvalCond $S $c $false $code)){ return $c.field } }
  $null
}
function _PlannedDue($S,$d){
  # ERP "empty" dates are stored as 1900-01-01 - a due derived from one is junk (it polluted next_due
  # with 1900-01-0x values and made every row "overdue"). Anything before 1990 is treated as no date.
  if("$($d.sla_type)" -eq 'fixed' -and $d.sla_anchor){
    $base=_FieldVal $S $d.sla_anchor; if(-not ($base -is [datetime]) -or $base.Year -lt 1990){ return $null }
    $off=[int]$d.sla_offset_val; if("$($d.sla_direction)" -eq 'before'){ $off=-$off }
    if("$($d.sla_offset_unit)" -eq 'hour'){ return $base.AddHours($off) } else { return $base.AddDays($off) }
  } elseif("$($d.sla_type)" -eq 'baseline'){
    if("$($d.phase_anchor)" -in 'booking','etd'){
      # Sea ETD anchor is bound-aware: Import legs run on departure1/arrival1, Export on departure2.
      $etd = if("$($S.ship.mode)" -eq 'Air'){ $S.ship.atd_date }
             elseif("$($S.bound)" -eq 'Import'){ if($S.ship.departure1){$S.ship.departure1}elseif($S.ship.arrival1){$S.ship.arrival1}elseif($S.ship.eta_delivery){$S.ship.eta_delivery}else{$null} }
             elseif($S.ship.departure2){$S.ship.departure2}elseif($S.ship.eta_delivery){$S.ship.eta_delivery}else{$null}
      if($etd -is [datetime] -and $etd.Year -ge 1990){ return $etd.AddDays(-$S.lead) }
    }
    return $null
  }
  $null
}
function _Light($S,$due){
  if(-not ($due -is [datetime])){ return 'G' }
  $start=$S.ship.crtdate; if(-not ($start -is [datetime])){ return $(if($S.asof -gt $due){'R'}else{'G'}) }
  if($due -le $start){ return $(if($S.asof -ge $due){'R'}else{'G'}) }
  $pct = ($S.asof - $start).TotalSeconds / ($due - $start).TotalSeconds
  if($pct -gt 0.9){'R'} elseif($pct -ge 0.7){'A'} else {'G'}
}

# Evaluate every def for this bound -> @{ items=@(per-milestone); worst; open_amber; open_red; next_due; auto_done; manual_done }
# $manual = optional hashtable code-> @{reason;by;at} of manual bypasses (from notes) to overlay.
function Eval-Milestones($S,$defs,$manual){
  if(-not $manual){ $manual=@{} }
  $items=@(); $amber=0; $red=0; $auto=0; $man=0; $nextDue=$null
  # Leg-passed flags (bound/mode-aware): once the origin leg has DEPARTED (or destination ARRIVED), the
  # pre-departure / pre-arrival operational milestones are moot for a "what to do today" board. We supersede
  # them rather than leave them Red on sparse data. Keys off the reliable departure/arrival dates (not ETA).
  $isImp = ("$($S.bound)" -eq 'Import')
  $depDate = if("$($S.ship.mode)" -eq 'Air'){ $S.ship.atd_date } elseif($isImp){ $S.ship.departure1 } else { $S.ship.departure2 }
  $arrDate = if("$($S.ship.mode)" -eq 'Air'){ $S.ship.ata_date } elseif($isImp){ $S.ship.arrival1 }   else { $S.ship.arrival2 }
  $onb     = if("$($S.ship.mode)" -eq 'Air'){ $S.ship.atd_date } else { $S.ship.onboard }
  $departed = ($onb -is [datetime]) -or ($depDate -is [datetime] -and $depDate -le $S.asof)
  $arrived  = ($S.ship.ata_date -is [datetime]) -or ($arrDate -is [datetime] -and $arrDate -le $S.asof)
  foreach($d in @($defs | Where-Object { $_.bound -eq $S.bound -and ("$($_.mode)" -eq "$($S.ship.mode)" -or "$($_.mode)" -eq 'Both' -or "$($_.mode)" -eq '') } | Sort-Object seq)){
    $code=$d.milestone_code
    $row=[ordered]@{ code=$code; name=$d.name; seq=[int]$d.seq; phase_anchor=$d.phase_anchor; tracked=$true; state='pending'; light='G'; done_by=''; done_at=''; due=''; basis='' }
    # manual bypass overlay wins (operator ticked it) — even with no ERP data
    if($manual.ContainsKey($code)){
      $m=$manual[$code]; $row.state='bypassed'; $row.tracked=$true; $row.done_by="$($m.by)"; $row.done_at="$($m.at)"; $row.light='G'; $row.basis="manual: $($m.reason)"; $man++
      $items+=[pscustomobject]$row; continue
    }
    if(-not (_EvalRule $S $d.qualify_rule $false $code)){ $row.tracked=$false; $row.state='n/a'; $row.light='-'; $items+=[pscustomobject]$row; continue }
    if(_EvalRule $S $d.complete_rule $false $code){
      $f=_ClosingField $S $d.complete_rule $code; $dt=_FieldVal $S $f
      $row.state='done'; $row.done_by='auto'; $row.light='G'; $row.basis="data:$f"
      if($dt -is [datetime]){ $row.done_at=$dt.ToString('o') }; $auto++; $items+=[pscustomobject]$row; continue
    }
    $ev=_EvidenceFor $S $code
    if($ev.matched){
      $row.state='done'; $row.done_by='auto'; $row.light='G'; $row.basis="evidence:$($ev.via)"
      if($ev.date){ $row.done_at=([datetime]$ev.date).ToString('o') }; $auto++; $items+=[pscustomobject]$row; continue
    }
    # pending, but its phase already passed (ship departed / arrived) -> superseded, not actionable today
    $sup = switch("$($d.phase_anchor)"){ 'booking'{$departed} 'etd'{$departed} 'eta'{$arrived} default {$false} }
    if($sup){
      $row.state='done'; $row.done_by='superseded'; $row.light='G'; $row.basis='superseded: leg passed'
      $auto++; $items+=[pscustomobject]$row; continue
    }
    # pending -> planned light
    $due=_PlannedDue $S $d; $lt=_Light $S $due
    $row.light=$lt
    if($due -is [datetime]){ $row.due=$due.ToString('yyyy-MM-dd'); $row.basis="$($d.sla_type) due"; if(-not $nextDue -or $due -lt $nextDue){ $nextDue=$due } }
    else { $row.basis='no time-gate' }
    if($lt -eq 'A'){ $amber++ } elseif($lt -eq 'R'){ $red++ }
    $items+=[pscustomobject]$row
  }
  $worst = if($red){'R'}elseif($amber){'A'}else{'G'}
  @{ items=$items; worst=$worst; open_amber=$amber; open_red=$red; next_due=$(if($nextDue){$nextDue.ToString('yyyy-MM-dd')}else{$null}); auto_done=$auto; manual_done=$man }
}

# ============================================================================================================
#  ROUTE / CARGO builders — pure, shared by seed-alerts.ps1 (snapshot) and serve-ops.ps1 (/api-ops/erp-detail).
#  Each returns plain hashtable "points" {role,code,name,dep,arr,flight,vessel,time}; blank-code points are
#  omitted and consecutive duplicate codes merged, so sparse ERP rows degrade to POL -> POD gracefully.
#  Tolerates missing columns (schema-variant stations): a dropped column reads as $null.
# ============================================================================================================
function _RS([object]$x){ $s = "$x".Trim(); if($s){ $s } else { $null } }   # string-or-null (DBNull-safe)
function _RD([object]$x){ if($null -eq $x -or $x -is [System.DBNull] -or "$x" -eq ''){ $null } else { ([datetime]$x).ToString('yyyy-MM-dd') } }
function _RN([object]$x){ if($null -eq $x -or $x -is [System.DBNull] -or "$x" -eq ''){ $null } else { try { [math]::Round([double]$x,2) } catch { $null } } }

function _RoutePack($pts){
  # drop blank codes; merge consecutive duplicates (later point's non-null props fill the kept one)
  $out=@()
  foreach($p in @($pts)){
    if(-not $p.code){ continue }
    $prev = if($out.Count){ $out[$out.Count-1] } else { $null }
    if($prev -and $prev.code -eq $p.code){
      foreach($k in @($p.Keys)){ if($null -ne $p[$k] -and ($null -eq $prev[$k] -or $k -eq 'role')){ $prev[$k]=$p[$k] } }
      continue
    }
    # strip null-valued keys so the stored JSON stays compact
    $q=[ordered]@{}; foreach($k in 'role','code','name','dep','time','arr','flight','vessel'){ if($null -ne $p[$k]){ $q[$k]=$p[$k] } }
    $out += ,$q
  }
  ,$out
}

# Sea: Export rides leg-2 fields (departure2/arrival2, place-of-delivery arrival2d, final dest arrival3);
# Import rides leg-1 (departure1/arrival1/arrival1d). pol/pod/deli are ERP-mandatory, dest optional.
# $vesselDisplay: resolved "NAME / VOY" from the caller's veslmstr map (falls back to raw code+voyage).
function Get-SeaRoutePoints($b,$bound,$vesselDisplay){
  $exp = ("$bound" -eq 'Export')
  $vsl = _RS $vesselDisplay
  if(-not $vsl){
    $vc = if($exp){ _RS $b.vessel_2 } else { _RS $b.vessel_1 }
    $vy = if($exp){ _RS $b.voyage_2 } else { _RS $b.voyage_1 }
    if($vc){ $vsl = (@($vc,$vy) | Where-Object { $_ }) -join ' / ' }
  }
  $pts = @(
    @{ role='POL';  code=(_RS $b.pol);  name=(_RS $b.pol_name);  dep=(_RD $(if($exp){$b.departure2}else{$b.departure1})); vessel=$vsl },
    @{ role='POD';  code=(_RS $b.pod);  name=(_RS $b.pod_name);  arr=(_RD $(if($exp){$b.arrival2}else{$b.arrival1})) },
    @{ role='DELI'; code=(_RS $b.deli); name=(_RS $b.deli_name); arr=(_RD $(if($exp){$b.arrival2d}else{$b.arrival1d})) },
    @{ role='DEST'; code=(_RS $b.dest); name=(_RS $b.dest_name); arr=(_RD $b.arrival3) }
  )
  _RoutePack $pts
}

# Air: stops pol -> to1 -> to3 -> dest; flightN/f_dateN/f_timeN belong to the DEPARTING stop of leg N and
# fa_dateN is that leg's arrival at the NEXT stop. Airline is embedded in the flight no (CX909); rout_by_1
# only confirms leg-1's carrier. deli appended when it differs from dest.
function Get-AirRoutePoints($b){
  $pts = @(
    @{ role='POL';  code=(_RS $b.pol);  name=(_RS $b.pol_name);  flight=(_RS $b.flight1); dep=(_RD $b.f_date1); time=(_RS $b.f_time1) },
    @{ role='VIA';  code=(_RS $b.to1);  name=(_RS $b.to1_name);  arr=(_RD $b.fa_date1); flight=(_RS $b.flight2); dep=(_RD $b.f_date2); time=(_RS $b.f_time2) },
    @{ role='VIA';  code=(_RS $b.to3);  name=(_RS $b.to3_name);  arr=(_RD $b.fa_date2); flight=(_RS $b.flight3); dep=(_RD $b.f_date3); time=(_RS $b.f_time3) },
    @{ role='DEST'; code=(_RS $(if(_RS $b.dest){$b.dest}else{$b.pod})); name=(_RS $(if(_RS $b.dest){$b.dest_name}else{$b.pod_name})); arr=(_RD $(if($b.fa_date3){$b.fa_date3}else{$b.ata_date})) },
    @{ role='DELI'; code=(_RS $b.deli); name=(_RS $b.deli_name) }
  )
  _RoutePack $pts
}

# Booked-vs-received cargo block for detail_json / erp-detail: {book:{qty,wgt,cbm,cwt}, rece:{...}} (nulls dropped).
function Get-CargoBlock($b,$mode){
  function _pack($pairs){ $h=[ordered]@{}; foreach($k in $pairs.Keys){ $v=_RN $pairs[$k]; if($null -ne $v){ $h[$k]=$v } }; $h }
  $book = _pack ([ordered]@{ qty=$b.t_book_qty; wgt=$b.t_book_wgt; cbm=$b.t_book_cbm; cwt=$b.t_book_cwt })
  $rece = _pack ([ordered]@{ qty=$b.t_rece_qty; wgt=$b.t_rece_wgt; cbm=$b.t_rece_cbm; cwt=$b.ttl_cwt })
  $out=[ordered]@{}
  if($book.Count){ $out.book=$book }
  if($rece.Count){ $out.rece=$rece }
  $out
}

# PS 5.1: ConvertTo-Json flattens a 1-element array to a bare object — serialize each element and join.
function ConvertTo-JsonArray($items,[int]$depth=6){
  $parts = @($items) | Where-Object { $null -ne $_ } | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth $depth }
  '[' + ($parts -join ',') + ']'
}
