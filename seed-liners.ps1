<#
  seed-liners.ps1 - copies the ERP liner/carrier master (linermstr: code + name) into erpops.liner_dim so the
  natural-language Find can resolve a typed carrier NAME ("ONE", "Maersk", "OOCL") to the code(s) actually stored
  in shipment_alerts.carrier (ONEY, MAEU, OOCL) - without the request path ever touching the ERP. The master
  barely changes - schedule it weekly alongside seed-ports.ps1. Source ERP is READ-ONLY; the refresh is
  transactional (DELETE + chunked multi-row INSERT) so readers never see an empty table.
  Usage: .\seed-liners.ps1 [-ConfigPath .\ops.config.json] [-Station fm3khkg]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [string]$Station=""
)
$ErrorActionPreference="Stop"
$cfg=[IO.File]::ReadAllText($ConfigPath)|ConvertFrom-Json
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
function Exec($db,$sql){
  $cn=New-Object System.Data.SqlClient.SqlConnection (CS $db); $cn.Open()
  try { $c=$cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=90; [void]$c.ExecuteNonQuery() } finally { $cn.Close() }
}

# default source station = first configured station DB (any office's linermstr carries the full master)
if(-not "$Station".Trim()){
  $first=@($cfg.stations)[0]
  if($first -and $first.database){ $Station="$($first.database)" } else { throw "No -Station given and no stations[] in config." }
}

# ensure the table exists (so this seeder can run before/without a full setup-ops.ps1)
Exec $opsDb @"
IF OBJECT_ID('dbo.liner_dim') IS NULL
CREATE TABLE dbo.liner_dim (
  code nvarchar(12) NOT NULL, name nvarchar(120) NULL, updated_at datetime2 NOT NULL,
  CONSTRAINT PK_liner_dim PRIMARY KEY (code)
);
"@

Write-Host "Reading liner master from $Station.linermstr ..." -ForegroundColor Cyan
$rows = Query $Station "SELECT code, name FROM dbo.linermstr WHERE NULLIF(code,'') IS NOT NULL"
if(-not $rows.Count){ Write-Host "linermstr returned 0 rows - aborting (liner_dim left untouched)." -ForegroundColor Red; exit 1 }

# normalize + dedupe on code (PK)
$liners=@{}
foreach($r in $rows){
  $code="$($r.code)".Trim().ToUpper(); if(-not $code -or $code.Length -gt 12){ continue }
  $name="$($r.name)".Trim(); if($name.Length -gt 120){ $name=$name.Substring(0,120) }
  $liners[$code]=@{ code=$code; name=$(if($name){$name}else{$null}) }
}
$list=@($liners.Values)
Write-Host "  $($rows.Count) master rows -> $($list.Count) distinct liner codes" -ForegroundColor Gray

# transactional refresh: DELETE + chunked multi-row INSERT (300 rows x 3 params = 900 params, under the 2100 cap)
$cn=New-Object System.Data.SqlClient.SqlConnection (CS $opsDb); $cn.Open()
$tx=$cn.BeginTransaction()
try {
  $c=$cn.CreateCommand(); $c.Transaction=$tx; $c.CommandTimeout=120
  $c.CommandText="DELETE FROM dbo.liner_dim"; [void]$c.ExecuteNonQuery()
  for($off=0; $off -lt $list.Count; $off+=300){
    $chunk=@($list[$off..([Math]::Min($off+299,$list.Count-1))])
    $vals=@(); $c=$cn.CreateCommand(); $c.Transaction=$tx; $c.CommandTimeout=120
    for($i=0; $i -lt $chunk.Count; $i++){
      $p=$chunk[$i]
      $vals+="(@c$i,@n$i,SYSDATETIME())"
      [void]$c.Parameters.AddWithValue("@c$i",$p.code)
      [void]$c.Parameters.AddWithValue("@n$i",$(if($null -eq $p.name){[DBNull]::Value}else{$p.name}))
    }
    $c.CommandText="INSERT INTO dbo.liner_dim(code,name,updated_at) VALUES $($vals -join ',')"
    [void]$c.ExecuteNonQuery()
  }
  $tx.Commit()
} catch { try{$tx.Rollback()}catch{}; throw } finally { $cn.Close() }

$n = (Query $opsDb "SELECT COUNT(*) n FROM dbo.liner_dim")[0].n
Write-Host "liner_dim refreshed: $n liners" -ForegroundColor Green
