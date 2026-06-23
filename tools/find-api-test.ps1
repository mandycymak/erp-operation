<#
.SYNOPSIS
  Test the third-party Find API (POST /api-ops/find-text) end to end: mint a JWT carrying a user's email,
  send a free-text query, print the JSON the server returns. Simulates a third-party caller (Swivel L!NK /
  Cargoclip / your own chat interface).

.DESCRIPTION
  The server must have the jwtAuth block enabled (ops.config.<env>.json: jwtAuth.enabled=true with a signingKey
  for HS256). This script mints an HS256 token locally with the SAME signingKey, so it only works for testing /
  HS256 setups. In production the token is issued by the identity provider (L!NK / Cargoclip), not by this script.

.EXAMPLE
  ./tools/find-api-test.ps1 -BaseUrl http://localhost:8085 `
      -Email mandy.mak@swivelsoftware.com `
      -Secret 'test-secret-please-change-0123456789-abcdef' `
      -Issuer 'https://swivel-link.test' -Audience 'control-tower' `
      -Text 'everyone air export shipments'
#>
[CmdletBinding()]
param(
  [string]$BaseUrl  = 'http://localhost:8085',
  [Parameter(Mandatory)] [string]$Email,
  [Parameter(Mandatory)] [string]$Secret,     # must equal jwtAuth.signingKey on the server (HS256)
  [string]$Issuer   = '',                     # must equal jwtAuth.issuer   ('' if the server leaves issuer unchecked)
  [string]$Audience = '',                     # must equal jwtAuth.audience ('' if unchecked)
  [string]$Text     = 'everyone air export shipments',
  [switch]$UseLlm,                            # allow the LLM fallback (only if llm.enabled on the server)
  [int]$ExpiresInSec = 3600
)

function ConvertTo-B64Url([byte[]]$b) {
  [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function New-Hs256Jwt {
  param([string]$Email,[string]$Secret,[string]$Issuer,[string]$Audience,[int]$ExpiresInSec)
  $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $claims = @{ email = $Email; sub = $Email; iat = $now; exp = ($now + $ExpiresInSec) }
  if ($Issuer)   { $claims.iss = $Issuer }
  if ($Audience) { $claims.aud = $Audience }
  $hdr = ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes((@{ alg='HS256'; typ='JWT' } | ConvertTo-Json -Compress)))
  $pl  = ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress)))
  $data = "$hdr.$pl"
  $hmac = New-Object System.Security.Cryptography.HMACSHA256
  $hmac.Key = [Text.Encoding]::UTF8.GetBytes($Secret)
  $sig = ConvertTo-B64Url ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($data)))
  "$data.$sig"
}

$token = New-Hs256Jwt -Email $Email -Secret $Secret -Issuer $Issuer -Audience $Audience -ExpiresInSec $ExpiresInSec
$body  = @{ text = $Text; useLlm = [bool]$UseLlm } | ConvertTo-Json -Compress

Write-Host "POST $BaseUrl/api-ops/find-text" -ForegroundColor Cyan
Write-Host "Authorization: Bearer <jwt for $Email>"
Write-Host "Body: $body`n"

try {
  $resp = Invoke-WebRequest "$BaseUrl/api-ops/find-text" -Method POST `
            -Headers @{ Authorization = "Bearer $token" } `
            -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 40
  $o = $resp.Content | ConvertFrom-Json
  Write-Host "HTTP $($resp.StatusCode)  source=$($o.source)  items=$($o.items.Count)" -ForegroundColor Green
  Write-Host "resolved: $($o.resolved | ConvertTo-Json -Compress)`n"
  $o.items | Select-Object -First 5 |
    Format-Table type, humanId, mode, bound, station, lane, eta -AutoSize
  Write-Host "`nFull response JSON (first item shown in detail):"
  if ($o.items.Count -gt 0) { $o.items[0] | ConvertTo-Json -Depth 6 }
}
catch {
  $r = $_.Exception.Response
  if ($r) {
    $sr = New-Object IO.StreamReader($r.GetResponseStream())
    Write-Host "HTTP $($r.StatusCode.value__): $($sr.ReadToEnd())" -ForegroundColor Red
  } else { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
}
