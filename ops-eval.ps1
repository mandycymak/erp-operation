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
  @{
    mode='Sea'
    bound = switch("$($b.bound)"){ 'O'{'Export'} 'I'{'Import'} default {'Other'} }
    cargo_type = switch -regex ("$($b.frttype)"){ 'CY|FCL'{'FCL'} 'CFS|LCL'{'LCL'} default {$null} }
    incoterm = $routing.Substring(0,[Math]::Min(8,$routing.Length)).Trim()
    jobn=$b.jobn; blno=$b.blno; picuser=("$($b.picuser)").Trim(); crtuser=("$($b.crtuser)").Trim()
    upduser=("$($b.upduser)").Trim(); status=$b.status
    declaration= if($b.declaration -eq $true){'1'}else{'0'}
    pol=$b.pol; pod=$b.pod; carr=$b.carr; salesman=("$($b.salesman)").Trim()
    onboard1=(D $b.onboard1); cargoready=(D $b.cargoready); cargorece=(D $b.cargorece)
    customs_clearance=(D $b.customs_clearance); ts_blno=$b.ts_blno; ams_hbl=$b.ams_hbl; edidate=(D $b.edidate)
    atd_date=(D $b.atd_date); eta_delivery=(D $b.eta_delivery); goods_delivery=(D $b.goods_delivery)
    comp_date=(D $b.comp_date); ata_date=(D $b.ata_date); not1_date=(D $b.not1_date); release_date=(D $b.release_date)
    broker=("$($b.broker)").Trim(); customer_pickup=(D $b.customer_pickup); wh_code=("$($b.wh_code)").Trim()
    ad_date=(D $b.ad_date); ware_date=(D $b.ware_date); pd_date=(D $b.pd_date)
    departure1=(D $b.departure1); crtdate=(D $b.crtdate)
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
    picuser=("$($b.picuser)").Trim(); crtuser=("$($b.crtuser)").Trim(); upduser=("$($b.upduser)").Trim(); status=$b.status
    declaration= if($b.declaration_complete -eq $true){'1'}else{'0'}
    pol=$b.pol; pod=$b.pod; carr=("$($b.carr)").Trim(); flight1=("$($b.flight1)").Trim()
    shpr_code=("$($b.shpr_code)").Trim(); cgne_code=("$($b.cgne_code)").Trim()
    atd_date=(D $b.atd_date); ata_date=(D $b.ata_date)
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
  if("$($d.sla_type)" -eq 'fixed' -and $d.sla_anchor){
    $base=_FieldVal $S $d.sla_anchor; if(-not ($base -is [datetime])){ return $null }
    $off=[int]$d.sla_offset_val; if("$($d.sla_direction)" -eq 'before'){ $off=-$off }
    if("$($d.sla_offset_unit)" -eq 'hour'){ return $base.AddHours($off) } else { return $base.AddDays($off) }
  } elseif("$($d.sla_type)" -eq 'baseline'){
    if("$($d.phase_anchor)" -in 'booking','etd'){
      $etd = if("$($S.ship.mode)" -eq 'Air'){ $S.ship.atd_date } elseif($S.ship.departure1){$S.ship.departure1}elseif($S.ship.eta_delivery){$S.ship.eta_delivery}else{$null}
      if($etd -is [datetime]){ return $etd.AddDays(-$S.lead) }
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
