<#
  erp-doc-api.ps1 - Swivel 3rd-party ERP API client (dot-sourced by serve-ops.ps1; shares its $cfg).
  Spec: https://documents.swivelsoftware.com/3rd-erpapi.html (OpenAPI: 3rd-erpapi.json, bearer auth).
  Call split (2026-06-12):
    staff AGREE  -> Invoke-ErpDocAgree: POST /booking/get (read-merge, abort if booking absent so an update
                    can never CREATE one) + POST /booking/update - the agreed data lands in the ERP the
                    moment both sides confirm, so nobody retypes it. bookingUpdateMode in erp-api-map.json:
                    'best-effort' logs an ERP rejection and the agree still completes (demoerp currently
                    rejects every update - Swivel ticket open); 'strict' reports it as an error.
    staff ISSUE  -> Invoke-ErpDocIssue: POST /file/upload per file (operator-attached agreed PDF + every
                    live doc_attachment rider file) + POST /event/update (default status 'transportBill' =
                    Transport Bill Confirm) + optional POST /document/generate.
  Live-call rules learned on demoerp (do not regress):
    - 3rdBookingID is a shipment LOOKUP key (Shipment Reference ID), never send our own ids.
    - Do not send carrierCode/vesselName/voyageFlightNumber on /booking/update (carrier master rejects raw
      ERP codes; vesselName triggers a schedule rebuild that fails once the ETD has passed).
    - incoTermsCode/freightTermsCode are ECHOED from the live booking, never derived from the draft boxes:
      the freight_terms box is presentation-only (the user may erase the incoterm from the printout).
    - Invoke-RestMethod returns a JSON array as ONE pipeline object - assign first, then @() to enumerate.
    - commodity max length is 21 (spec maxLength); internal-use field, truncate hard.
  Config split:
    ops.config.json (gitignored)  -> erpApi: { baseUrl, token, mock }   (the SECRET bearer token lives here)
    erp-api-map.json (tracked)    -> partyGroupCode, forwarderCode, serviceCodeDefault, commodityFallback,
                                     event, documentTypeCode, generateDocument, bookingUpdateMode,
                                     bookingOverrides (see that file's _comments)
  MOCK MODE (default when no baseUrl/token, or erpApi.mock=true): builds the exact same payloads and writes
  erp-mock\agree-<doc_id>.json / erp-mock\issue-<doc_id>.json instead of calling out.
  Returns hashtables: @{ ok; docNo?; mock; steps=@(...) } or @{ ok=$false; error; steps }
#>

$script:ErpApiMapPath = Join-Path $PSScriptRoot 'erp-api-map.json'
function Get-ErpApiMap {
  if(-not $script:ErpApiMap){
    if(Test-Path $script:ErpApiMapPath){ $script:ErpApiMap=[IO.File]::ReadAllText($script:ErpApiMapPath)|ConvertFrom-Json }
    else { $script:ErpApiMap=[pscustomobject]@{} }
  }
  $script:ErpApiMap
}
# first line of a multi-line box = the party NAME, the rest = the ADDRESS (the on-screen bill convention)
function Split-PartyBox($text){
  $t="$text".Replace("`r","").Trim()
  if(-not $t){ return @{ name=''; addr='' } }
  $lines=@($t -split "`n")
  @{ name=$lines[0].Trim(); addr=(@($lines | Select-Object -Skip 1) -join "`n").Trim() }
}
function FieldV($fields,$code){ if($fields -and $fields.PSObject.Properties[$code]){ "$($fields.$code)" } else { '' } }
function FieldRows($fields,$code){   # structured (table/riders) field value -> array of row objects
  if($fields -and $fields.PSObject.Properties[$code] -and $fields.$code -isnot [string]){ return @($fields.$code) }
  @()
}
# Merge the Qty column into the description, line by line (packing-list style): every output line is
# "<qty padded to the column width> <description line>" - lines without a qty get the same indent, so
# "12 ROLLS KNITTED MATERIAL" / "         100% COTTON" stay column-aligned in the ERP goodsDescription.
function Merge-QtyDesc($qty,$desc){
  $dt="$desc".Replace("`r",'')
  if(-not ("$qty".Trim())){ return $dt.Trim() }
  $q=@("$qty".Replace("`r",'') -split "`n"); $d=@($dt -split "`n")
  $w=0; foreach($x in $q){ $L=$x.TrimEnd().Length; if($L -gt $w){ $w=$L } }
  $n=[Math]::Max($q.Count,$d.Count); $out=@()
  for($i=0;$i -lt $n;$i++){
    $qv= if($i -lt $q.Count){ $q[$i].TrimEnd() } else { '' }
    $dv= if($i -lt $d.Count){ $d[$i].TrimEnd() } else { '' }
    $out+=(($qv.PadRight($w+1))+$dv).TrimEnd()
  }
  (($out -join "`n")).Trim()
}
# shipMarks / goodsDescription for the booking push: the on-bill boxes (when they hold real text, not
# the 'AS PER ATTACHED SHEET' pointer) followed by every attachment/rider page, qty column merged in.
function Build-MarksGoods($fields){
  $ptr='AS PER ATTACHED SHEET'
  $units=@()
  $bm=(FieldV $fields 'marks_numbers'); $bq=(FieldV $fields 'qty_detail'); $bd=(FieldV $fields 'description')
  if("$bm".Trim() -eq $ptr){ $bm='' }
  if("$bd".Trim() -eq $ptr){ $bd='' }
  if("$bm".Trim() -or "$bq".Trim() -or "$bd".Trim()){ $units+=,@{ m=$bm; q=$bq; d=$bd } }
  foreach($pg in @(FieldRows $fields 'rider_pages')){ $units+=,@{ m=(FieldV $pg 'marks'); q=(FieldV $pg 'qty'); d=(FieldV $pg 'description') } }
  $marks=@(); $goods=@()
  foreach($u in $units){
    $mv="$($u.m)".Replace("`r",'').Trim(); if($mv){ $marks+=$mv }
    $gv=Merge-QtyDesc $u.q $u.d; if($gv){ $goods+=$gv }
  }
  @{ marks=($marks -join "`n"); goods=($goods -join "`n") }
}

# Build the /booking/update payload from the doc head + agreed fields + the shipment snapshot row.
function Build-ErpBookingPayload($head,$fields,$sa,$map){
  $isAir=("$($head.doc_type)" -eq 'HAWB')
  $houseNo= if($isAir){ FieldV $fields 'hawb_no' } else { FieldV $fields 'hbl_no' }
  # Sea: marks/goods assembled from the boxes + rider pages with the Qty column merged into the
  # description lines (see Build-MarksGoods); Air keeps the single nature/quantity box as-is.
  $mg= if($isAir){ $null } else { Build-MarksGoods $fields }
  $goods= if($isAir){ FieldV $fields 'nature_quantity_goods' } else { $mg.goods }
  $commodity="$($sa.commodity)".Trim()
  if(-not $commodity -and "$goods".Trim()){ $commodity=(@("$goods".Replace("`r",'') -split "`n")[0]).Trim() }
  if(-not $commodity){ $commodity="$($map.commodityFallback)".Trim() }
  if($commodity.Length -gt 21){ $commodity=$commodity.Substring(0,21) }   # spec maxLength=21; internal-use field
  $p=[ordered]@{
    partyGroupCode="$($map.partyGroupCode)".Trim()
    bookingNo=$(if("$($sa.sono)".Trim()){ "$($sa.sono)".Trim() }else{ "$($head.job_no)" })
    houseNo=$houseNo
    masterNo=$(if($isAir){ FieldV $fields 'mawb_no' }else{ "$($sa.master_bill)".Trim() })
    moduleTypeCode=$(if($isAir){'AIR'}else{'SEA'})
    boundTypeCode=$(if("$($head.bound)" -eq 'Import'){'I'}else{'O'})
    serviceCode="$($map.serviceCodeDefault)".Trim()
    commodity=$commodity
    shipMarks=$(if($isAir){ FieldV $fields 'marks_numbers' }else{ $mg.marks })
    goodsDescription=$goods
    portOfLoadingCode="$($sa.pol)".Trim()
    portOfLoadingName=$(if($isAir){ FieldV $fields 'airport_departure' }else{ FieldV $fields 'port_of_loading' })
    portOfDischargeCode="$($sa.pod)".Trim()
    portOfDischargeName=$(if($isAir){ FieldV $fields 'airport_destination' }else{ FieldV $fields 'port_of_discharge' })
  }
  # incoTermsCode/freightTermsCode deliberately NOT derived from the draft (presentation-only boxes);
  # carrierCode/vesselName/voyageFlightNumber deliberately NOT sent (see header). bookingOverrides can
  # force any of them per deployment.
  # container particulars -> bookingContainers (API item carries NO weight/cbm - display-only on the bill)
  $cRows=@(FieldRows $fields 'containers')
  if($cRows.Count){
    $bc=@()
    foreach($r in $cRows){
      $cno=(FieldV $r 'container_no').Trim()
      if(-not $cno){ continue }
      $item=[ordered]@{ containerNo=$cno }
      $sl=(FieldV $r 'seal_no').Trim(); if($sl){ $item['sealNo']=$sl }
      $tp=(FieldV $r 'cont_type').Trim(); if($tp){ $item['containerTypeCode']=$tp }
      $q=0; if([int]::TryParse((FieldV $r 'qty').Trim(),[ref]$q) -and $q -gt 0){ $item['quantity']=$q }
      $bc+=,$item
    }
    if($bc.Count){ $p['bookingContainers']=@($bc) }
  }
  # address blocks: bookingParty uses FLAT prefixed keys (shipperPartyName/-Address, notifyPartyParty...)
  $party=[ordered]@{}
  $pairs=@(
    @{ box='shipper';   prefix='shipperParty' },
    @{ box='consignee'; prefix='consigneeParty' },
    @{ box='notify';    prefix='notifyPartyParty' }
  )
  foreach($pr in $pairs){
    if($isAir -and $pr.box -eq 'notify'){ continue }   # HAWB layout has no notify box
    $sp=Split-PartyBox (FieldV $fields $pr.box)
    if($sp.name){ $party[($pr.prefix+'Name')]=$sp.name; if($sp.addr){ $party[($pr.prefix+'Address')]=$sp.addr } }
  }
  if($party.Count){ $p['bookingParty']=$party }
  # declarative last-step overrides from erp-api-map.json: 'field:<code>' | 'sa:<col>' | 'const:<literal>'
  if($map.bookingOverrides){
    foreach($prop in $map.bookingOverrides.PSObject.Properties){
      $spec="$($prop.Value)"
      $v= if($spec -like 'field:*'){ FieldV $fields $spec.Substring(6) }
          elseif($spec -like 'sa:*'){ "$($sa.($spec.Substring(3)))" }
          elseif($spec -like 'const:*'){ $spec.Substring(6) }
          else { $spec }
      $p[$prop.Name]=$v
    }
  }
  $p
}

# Fetch the current booking (POST /booking/get accepts the same JSON body as the documented GET - verified
# live). The same bookingNo can exist once per module (SEA + AIR), so filter by moduleTypeCode.
function Invoke-ErpBookingGet($api,$map,$bookingNo,$moduleTypeCode){
  try{
    # NB: Invoke-RestMethod returns a JSON array as ONE pipeline object (like ConvertFrom-Json) - assign
    # first, then @() to enumerate. @(Invoke-ErpCall ...) directly would nest the array as a single item.
    $resp=Invoke-ErpCall $api '/booking/get' ([ordered]@{ partyGroupCode="$($map.partyGroupCode)".Trim(); forwarderCode="$($map.forwarderCode)".Trim(); bookingNo="$bookingNo" })
    $hit=@(@($resp) | Where-Object { $_ -and "$($_.moduleTypeCode)" -eq "$moduleTypeCode" })
    if($hit.Count){ $hit[0] } else { $null }
  }catch{ $null }
}
function Invoke-ErpCall($api,$path,$payload){
  $base="$($api.baseUrl)".Trim().TrimEnd('/')
  $tok="$($api.token)".Trim(); if(-not $tok){ $tok="$($api.apiKey)".Trim() }
  if($tok -match '^(?i)Bearer\s+'){ $tok=($tok -replace '^(?i)Bearer\s+','').Trim() }   # tolerate a pasted 'Bearer ' prefix
  $hdrs=@{ Authorization="Bearer $tok" }
  $body=$payload|ConvertTo-Json -Depth 8
  Invoke-RestMethod -Method Post -Uri ($base+$path) -Headers $hdrs -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 60
}
# Invoke-RestMethod's exception message is just "(422) Unprocessable Entity" - read the response body so
# the ERP's actual validation message (e.g. "Invalid carrier code") reaches the user and the event log.
function ErpErr($ex){
  try{
    if($ex.Response){
      $st=$ex.Response.GetResponseStream()
      if($st.CanSeek){ $st.Position=0 }   # Invoke-RestMethod already consumed the stream; rewind to re-read
      $sr=New-Object IO.StreamReader($st); $b=$sr.ReadToEnd(); $sr.Close()
      if("$b".Trim()){ try{ $j=$b|ConvertFrom-Json; if($j.error.error){ return "$($ex.Message) - $($j.error.error)" } }catch{}; return "$($ex.Message) - $b" }
    }
  }catch{}
  "$($ex.Message)"
}
function ErpMockMode($api){ (-not ($api -and "$($api.baseUrl)".Trim() -and ("$($api.token)".Trim() -or "$($api.apiKey)".Trim()))) -or [bool]$api.mock }
function ErpMockWrite($name,$obj){
  $dir=Join-Path $PSScriptRoot 'erp-mock'
  if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir | Out-Null }
  [IO.File]::WriteAllText((Join-Path $dir $name),($obj|ConvertTo-Json -Depth 10),(New-Object System.Text.UTF8Encoding($false)))
}

# ---- AGREE: save the agreed booking data (read-merge-write). Returns @{ ok; mock; steps; error? } ----
function Invoke-ErpDocAgree($head,$fields,$sa,$by){
  $api=$cfg.erpApi
  $map=Get-ErpApiMap
  $mock=ErpMockMode $api
  if(-not $sa){ return @{ ok=$false; mock=$mock; steps=@(); error='shipment snapshot row not found - cannot build the booking payload' } }
  $isAir=("$($head.doc_type)" -eq 'HAWB')
  $houseNo= if($isAir){ FieldV $fields 'hawb_no' } else { FieldV $fields 'hbl_no' }
  if(-not "$houseNo".Trim()){ return @{ ok=$false; mock=$mock; steps=@(); error="the $($head.doc_type) number box is empty - fill it in before agreeing" } }
  $booking=Build-ErpBookingPayload $head $fields $sa $map
  if($mock){
    try{
      ErpMockWrite "agree-$($head.doc_id).json" ([ordered]@{ at=(Get-Date).ToString('o'); agreedBy="$by"; docId="$($head.doc_id)"; jobNo="$($head.job_no)"; booking=$booking; fields=$fields })
      return @{ ok=$true; mock=$true; steps=@('booking/update (mock)') }
    }catch{ return @{ ok=$false; mock=$true; steps=@(); error="mock agree failed: $($_.Exception.Message)" } }
  }
  # READ-MERGE-WRITE: fetch the live booking first. Abort if absent - /booking/update is "New Booking /
  # Update Booking" and a key mismatch would silently CREATE a duplicate. Echo serviceCode + the terms
  # codes from the live booking (presentation-only draft boxes must never change them).
  $cur=Invoke-ErpBookingGet $api $map "$($booking['bookingNo'])" "$($booking['moduleTypeCode'])"
  if(-not $cur){ return @{ ok=$false; mock=$false; steps=@(); error="booking '$($booking['bookingNo'])' ($($booking['moduleTypeCode'])) not found via /booking/get - aborting so the update cannot create a new booking. Check partyGroupCode/forwarderCode in erp-api-map.json and the booking number." } }
  if("$($cur.serviceCode)".Trim()){ $booking['serviceCode']="$($cur.serviceCode)".Trim() }
  if("$($cur.incoTermsCode)".Trim()){ $booking['incoTermsCode']="$($cur.incoTermsCode)".Trim() }
  if("$($cur.freightTermsCode)".Trim()){ $booking['freightTermsCode']="$($cur.freightTermsCode)".Trim() }
  # re-apply overrides AFTER the echo so a deployment can still force these fields
  if($map.bookingOverrides){
    foreach($prop in $map.bookingOverrides.PSObject.Properties){
      if($prop.Name -in 'serviceCode','incoTermsCode','freightTermsCode'){
        $spec="$($prop.Value)"
        $booking[$prop.Name]= if($spec -like 'field:*'){ FieldV $fields $spec.Substring(6) } elseif($spec -like 'sa:*'){ "$($sa.($spec.Substring(3)))" } elseif($spec -like 'const:*'){ $spec.Substring(6) } else { $spec }
      }
    }
  }
  $missing=@()
  foreach($req in 'partyGroupCode','bookingNo','serviceCode','commodity','portOfLoadingCode','portOfLoadingName','portOfDischargeCode','portOfDischargeName'){
    if(-not "$($booking[$req])".Trim()){ $missing+=$req }
  }
  if($missing.Count){ return @{ ok=$false; mock=$false; steps=@('booking/get ok'); error="booking/update payload incomplete: $($missing -join ', ') - check erp-api-map.json (partyGroupCode/serviceCodeDefault) and the shipment data" } }
  $bestEffort=("$($map.bookingUpdateMode)".Trim().ToLower() -eq 'best-effort')
  $steps=@('booking/get ok (exists, serviceCode + terms echoed)')
  try{
    [void](Invoke-ErpCall $api '/booking/update' $booking)
    $steps+='booking/update ok'
    @{ ok=$true; mock=$false; steps=$steps }
  }catch{
    $msg=ErpErr $_.Exception
    if($bestEffort){ $steps+="booking/update REJECTED by ERP validation (best-effort): $msg"; @{ ok=$true; mock=$false; steps=$steps; rejected=$true } }
    else { @{ ok=$false; mock=$false; steps=$steps; error="booking/update failed: $msg" } }
  }
}

# ---- ISSUE: upload files (agreed PDF + rider attachments) + stamp the event (+ optional generate) ----
# $attachment: optional @{ name; base64 } (operator-attached agreed PDF)
# $riderAtts:  array of @{ name; base64 } (live doc_attachment rows)
function Invoke-ErpDocIssue($head,$fields,$sa,$by,$attachment,$riderAtts){
  $api=$cfg.erpApi
  $map=Get-ErpApiMap
  $mock=ErpMockMode $api
  if(-not $sa){ return @{ ok=$false; error='shipment snapshot row not found' } }
  $isAir=("$($head.doc_type)" -eq 'HAWB')
  $houseNo= if($isAir){ FieldV $fields 'hawb_no' } else { FieldV $fields 'hbl_no' }
  if(-not "$houseNo".Trim()){ return @{ ok=$false; error="the $($head.doc_type) number box is empty - fill it in before issuing" } }
  $bookingNo= if("$($sa.sono)".Trim()){ "$($sa.sono)".Trim() }else{ "$($head.job_no)" }
  $module=$(if($isAir){'AIR'}else{'SEA'})
  $dtc="$($map.documentTypeCode.($head.doc_type))".Trim()
  $evStatus="$($map.event.status)".Trim(); if(-not $evStatus){ $evStatus='transportBill' }
  # one upload payload per file: bounded request sizes, attributable failures
  $files=@()
  if($attachment -and "$($attachment.base64)".Trim()){ $files+=,@{ name="$($attachment.name)"; base64="$($attachment.base64)"; remark="Customer-agreed $($head.doc_type) v$($head.current_version)" } }
  foreach($ra in @($riderAtts)){ if($ra -and "$($ra.base64)".Trim()){ $files+=,@{ name="$($ra.name)"; base64="$($ra.base64)"; remark="Rider attachment for $($head.doc_type) v$($head.current_version)" } } }
  $evPayload=[ordered]@{
    partyGroupCode="$($map.partyGroupCode)".Trim()
    moduleTypeCode=$module
    houseNo=$houseNo
    bookingNo=$bookingNo
    status=$evStatus
    isEstimated=$false
    statusDate=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    statusDescription="$($map.event.description)"
    remark=("Customer-agreed draft v$($head.current_version) issued by $by" + $(if([int]$head.amend_count -gt 0){ " (amendment #$($head.amend_count), fee applies)" }else{ '' }))
  }
  $generate=$null
  if([bool]$map.generateDocument){
    $generate=[ordered]@{
      partyGroupCode="$($map.partyGroupCode)".Trim()
      forwarderCode="$($map.forwarderCode)".Trim()
      moduleTypeCode=$module
      documentTypeCode=$dtc
      bookingNo=$bookingNo
      houseBillNo=$houseNo
    }
  }
  if($mock){
    try{
      ErpMockWrite "issue-$($head.doc_id).json" ([ordered]@{ at=(Get-Date).ToString('o'); issuedBy="$by"; docId="$($head.doc_id)"; jobNo="$($head.job_no)"
        files=@($files|ForEach-Object{ [ordered]@{ name=$_.name; bytes=[int]([Math]::Ceiling(("$($_.base64)").Length*0.75)); remark=$_.remark } })
        event=$evPayload; generate=$generate; fields=$fields })
      $steps=@(); foreach($fl in $files){ $steps+="file/upload (mock): $($fl.name)" }; $steps+='event/update (mock)'
      if($generate){ $steps+='document/generate (mock)' }
      return @{ ok=$true; docNo="$houseNo"; mock=$true; steps=$steps }
    }catch{ return @{ ok=$false; error="mock issue failed: $($_.Exception.Message)" } }
  }
  $steps=@()
  foreach($fl in $files){
    $up=[ordered]@{
      partyGroupCode="$($map.partyGroupCode)".Trim()
      forwarderCode="$($map.forwarderCode)".Trim()
      moduleTypeCode=$module
      houseNo=$houseNo
      bookingNo=$bookingNo
      attachments=@([ordered]@{ documentTypeCode=$dtc; fileName="$($fl.name)"; base64="$($fl.base64)"; remark="$($fl.remark)" })
    }
    try{ [void](Invoke-ErpCall $api '/file/upload' $up); $steps+="file/upload ok: $($fl.name)" }
    catch{ return @{ ok=$false; error="file/upload failed for $($fl.name): $(ErpErr $_.Exception)"; steps=$steps } }
  }
  try{ [void](Invoke-ErpCall $api '/event/update' $evPayload); $steps+="event/update ok ($evStatus)" }
  catch{ return @{ ok=$false; error="event/update failed: $(ErpErr $_.Exception)"; steps=$steps } }
  if($generate){
    try{ [void](Invoke-ErpCall $api '/document/generate' $generate); $steps+='document/generate ok' }
    catch{ return @{ ok=$false; error="document/generate failed (files + event were saved): $(ErpErr $_.Exception)"; steps=$steps } }
  }
  @{ ok=$true; docNo="$houseNo"; mock=$false; steps=$steps }
}
