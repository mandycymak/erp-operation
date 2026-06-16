<#
  parity-check.ps1 - Cutover parity harness: diff every GET /api-ops/* JSON response between the legacy
  PowerShell server (serve-ops.ps1) and the new .NET server, over a fixed query set. The comparison is
  "modulo array-coercion" (PS 5.1 ConvertTo-Json renders a 0-row list as {} and a 1-row list as a bare
  object; the .NET server emits proper arrays - the client coerces both with arr(), so these are NOT real
  differences). Volatile fields (timestamps) are ignored.

  HOW TO RUN (both servers in the SAME mode against the SAME pgsops DB):
    1. Start the legacy server:   .\serve-ops.ps1 -Port 8090
    2. Start the .NET server:     server\start-dotnet.bat   (or: OPS_HTTP_PORT=5079 dotnet run)  -> 5079
       Run BOTH from a root WITHOUT users.json (open mode) so identity = the X-Ops-User header on both,
       giving identical unrestricted scope. (Or run both in auth mode and pass -Cookie for a logged-in
       session - the diff logic is the same.)
    3. .\tools\parity-check.ps1 -Ps http://localhost:8090 -Net http://localhost:5079 -Job <a real job_no>

  A clean cutover shows every endpoint MATCH. Any DIFF prints the JSON path of the first divergence.
#>
param(
  [string]$Ps  = "http://localhost:8090",
  [string]$Net = "http://localhost:5079",
  [string]$User = "tester",
  [string]$Job = "",                      # a real job_no for the by-job endpoints (shipment/erp-*/docs)
  [string]$Cookie = ""                    # optional "ops_sid=..." for auth-mode testing
)
$ErrorActionPreference = "Stop"

# volatile keys whose value legitimately differs call-to-call (timestamps, generated clocks) - ignored.
$VolatileKeys = @('fetchedAt','today','generatedAt','serverTime','at','lastViewAt')

function Get-Json($base, $path) {
  $h = @{ 'X-Ops-User' = $User }
  if ($Cookie) { $h['Cookie'] = $Cookie }
  try {
    $r = Invoke-WebRequest -Uri "$base$path" -Headers $h -UseBasicParsing -TimeoutSec 60
    return $r.Content | ConvertFrom-Json
  } catch {
    $resp = $_.Exception.Response
    if ($resp) { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); return [pscustomobject]@{ __httperror = [int]$resp.StatusCode; __body = $sr.ReadToEnd() } }
    return [pscustomobject]@{ __error = $_.Exception.Message }
  }
}

# coerce a value the PS side may have collapsed (null/empty-string/empty-object/single-object) into an array
function Coerce-Array($v) {
  if ($null -eq $v) { return @() }
  if ($v -is [array]) { return $v }
  if ($v -is [string] -and $v -eq '') { return @() }
  if ($v -is [pscustomobject] -and @($v.PSObject.Properties).Count -eq 0) { return @() }   # PS empty list -> {}
  return @($v)                                                                              # PS 1-row list -> bare object
}

# recursive, coercion-tolerant deep compare. Returns $null on match, else the path of the first difference.
function Compare-Json($a, $b, $path) {
  $aArr = $a -is [array]; $bArr = $b -is [array]
  if ($aArr -or $bArr) {
    $ca = @(Coerce-Array $a); $cb = @(Coerce-Array $b)
    if ($ca.Count -ne $cb.Count) { return "$path : array length $($ca.Count) (PS) vs $($cb.Count) (.NET)" }
    for ($i = 0; $i -lt $ca.Count; $i++) { $d = Compare-Json $ca[$i] $cb[$i] "$path[$i]"; if ($d) { return $d } }
    return $null
  }
  $aObj = $a -is [pscustomobject]; $bObj = $b -is [pscustomobject]
  if ($aObj -or $bObj) {
    if (-not $aObj) { return "$path : PS is scalar, .NET is object" }
    if (-not $bObj) { return "$path : PS is object, .NET is scalar" }
    $keys = @($a.PSObject.Properties.Name) + @($b.PSObject.Properties.Name) | Sort-Object -Unique
    foreach ($k in $keys) {
      if ($VolatileKeys -contains $k) { continue }
      $av = $a.PSObject.Properties[$k]; $bv = $b.PSObject.Properties[$k]
      # a key present one side but absent the other is OK only if that side's value coerces to empty
      if (-not $av) { if (@(Coerce-Array $bv.Value).Count -ne 0) { return "$path.$k : missing on PS" }; continue }
      if (-not $bv) { if (@(Coerce-Array $av.Value).Count -ne 0) { return "$path.$k : missing on .NET" }; continue }
      $d = Compare-Json $av.Value $bv.Value "$path.$k"; if ($d) { return $d }
    }
    return $null
  }
  # scalars: normalize numbers, compare as strings
  $as = "$a"; $bs = "$b"
  $an = 0.0; $bn = 0.0
  if ([double]::TryParse($as, [ref]$an) -and [double]::TryParse($bs, [ref]$bn)) { if ($an -ne $bn) { return "$path : '$as' (PS) vs '$bs' (.NET)" }; return $null }
  if ($as -ne $bs) { return "$path : '$as' (PS) vs '$bs' (.NET)" }
  return $null
}

# the GET endpoint set (read-only; safe to hit on both). By-job endpoints only run when -Job is supplied.
$endpoints = @(
  '/api-ops/config', '/api-ops/me', '/api-ops/roster', '/api-ops/companies', '/api-ops/ports',
  '/api-ops/inbound', '/api-ops/my-tasks', '/api-ops/worklist',
  '/api-ops/worklist?mode=Sea', '/api-ops/worklist?mode=Air', '/api-ops/notes'
)
if ($Job) {
  $endpoints += "/api-ops/shipment?job=$Job", "/api-ops/docs?job=$Job",
                "/api-ops/erp-detail?job=$Job", "/api-ops/erp-edit?job=$Job",
                "/api-ops/erp-master?job=$Job&kind=port&q=HK"
}

$pass = 0; $fail = 0
foreach ($ep in $endpoints) {
  $a = Get-Json $Ps $ep
  $b = Get-Json $Net $ep
  $diff = Compare-Json $a $b "root"
  if ($diff) { Write-Host ("DIFF  {0}`n        {1}" -f $ep, $diff) -ForegroundColor Red; $fail++ }
  else { Write-Host ("MATCH {0}" -f $ep) -ForegroundColor Green; $pass++ }
}
Write-Host ""
Write-Host ("PARITY: {0} match, {1} diff (of {2} endpoints)" -f $pass, $fail, $endpoints.Count) -ForegroundColor $(if ($fail) { 'Yellow' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
