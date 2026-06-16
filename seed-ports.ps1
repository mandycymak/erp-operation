<#
  seed-ports.ps1  — copies the ERP port/airport master (portmstr: ~3.9k sea UN/LOCODEs + ~1.5k IATA codes,
  with names + countries) into erpops.port_dim so the UI port pickers can search by NAME as well as code
  (Tokyo -> TYO/HND/JPTYO) without the request path ever touching the ERP. The master barely changes —
  scheduled weekly by register-ops-tasks.ps1. Source ERP is READ-ONLY; the refresh is transactional
  (DELETE + chunked multi-row INSERT) so readers never see an empty table.
  Usage: .\seed-ports.ps1 [-ConfigPath .\ops.config.json] [-Station fm3khkg]
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

# default source station = first configured station DB (any office's portmstr carries the full master)
if(-not "$Station".Trim()){
  $first=@($cfg.stations)[0]
  if($first -and $first.database){ $Station="$($first.database)" } else { throw "No -Station given and no stations[] in config." }
}

Write-Host "Reading port master from $Station.portmstr ..." -ForegroundColor Cyan
$rows = Query $Station "SELECT code, country, port_ldes1, module FROM dbo.portmstr WHERE NULLIF(code,'') IS NOT NULL"
if(-not $rows.Count){ Write-Host "portmstr returned 0 rows - aborting (port_dim left untouched)." -ForegroundColor Red; exit 1 }

# normalize + dedupe on (code,module); module inferred from code length when the master leaves it blank
$ports=@{}
foreach($r in $rows){
  $code="$($r.code)".Trim().ToUpper(); if(-not $code -or $code.Length -gt 8){ continue }
  $mod="$($r.module)".Trim().ToUpper()
  if($mod -notin 'SEA','AIR'){ $mod = if($code.Length -ge 5){'SEA'}else{'AIR'} }
  $name="$($r.port_ldes1)".Trim(); if($name.Length -gt 80){ $name=$name.Substring(0,80) }
  $ctry="$($r.country)".Trim().ToUpper(); if($ctry.Length -gt 4){ $ctry=$ctry.Substring(0,4) }
  $ports["$code|$mod"]=@{ code=$code; module=$mod; name=$(if($name){$name}else{$null}); country=$(if($ctry){$ctry}else{$null}) }
}
$list=@($ports.Values)
Write-Host "  $($rows.Count) master rows -> $($list.Count) distinct (code,module) ports" -ForegroundColor Gray

# transactional refresh: DELETE + chunked multi-row INSERT (250 rows x 4 params = 1000 params, under the 2100 cap)
$cn=New-Object System.Data.SqlClient.SqlConnection (CS $opsDb); $cn.Open()
$tx=$cn.BeginTransaction()
try {
  $c=$cn.CreateCommand(); $c.Transaction=$tx; $c.CommandTimeout=120
  $c.CommandText="DELETE FROM dbo.port_dim"; [void]$c.ExecuteNonQuery()
  for($off=0; $off -lt $list.Count; $off+=250){
    $chunk=@($list[$off..([Math]::Min($off+249,$list.Count-1))])
    $vals=@(); $c=$cn.CreateCommand(); $c.Transaction=$tx; $c.CommandTimeout=120
    for($i=0; $i -lt $chunk.Count; $i++){
      $p=$chunk[$i]
      $vals+="(@c$i,@m$i,@n$i,@y$i,SYSDATETIME())"
      [void]$c.Parameters.AddWithValue("@c$i",$p.code)
      [void]$c.Parameters.AddWithValue("@m$i",$p.module)
      [void]$c.Parameters.AddWithValue("@n$i",$(if($null -eq $p.name){[DBNull]::Value}else{$p.name}))
      [void]$c.Parameters.AddWithValue("@y$i",$(if($null -eq $p.country){[DBNull]::Value}else{$p.country}))
    }
    $c.CommandText="INSERT INTO dbo.port_dim(code,module,name,country,updated_at) VALUES $($vals -join ',')"
    [void]$c.ExecuteNonQuery()
  }
  $tx.Commit()
} catch { try{$tx.Rollback()}catch{}; throw } finally { $cn.Close() }

$counts = Query $opsDb "SELECT module, COUNT(*) n FROM dbo.port_dim GROUP BY module"
$summary = (@($counts) | ForEach-Object { "$($_.module)=$($_.n)" }) -join '  '
Write-Host "port_dim refreshed: $summary" -ForegroundColor Green
