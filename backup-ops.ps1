<#
  backup-ops.ps1 - nightly backup of the ops (erpops) database + the gitignored secrets.
  - BACKUP DATABASE [opsDb] (COPY_ONLY, so it never breaks a DBA's backup chain) to a dated .bak.
  - Copies the per-machine secrets (the config file, users.json, erp-api-map.json) to a dated folder.
  - Prunes .bak files and secret folders older than -RetainDays.
  - Appends a result line to ops-backup.log and EXITS NON-ZERO on any failure (so Task Scheduler shows it
    failed and ops-healthcheck.ps1 raises an alert).

  NOTE: the .bak path must be writable by the SQL Server service account (SQL writes the file, not this script).
  For local SQLEXPRESS the default <root>\backups works once that account has Modify there (see ONBOARD-CHECKLIST).
  Usage: .\backup-ops.ps1 [-ConfigPath .\ops.config.json] [-BackupDir C:\Backup\erpops] [-RetainDays 14]
#>
param(
  [string]$ConfigPath=(Join-Path $PSScriptRoot "ops.config.json"),
  [string]$BackupDir=(Join-Path $PSScriptRoot "backups"),
  [int]$RetainDays=14
)
$ErrorActionPreference="Stop"
$stamp=(Get-Date).ToString('yyyyMMdd_HHmmss')
$logPath=Join-Path $PSScriptRoot "ops-backup.log"
function Log($msg){ $line="{0}`t{1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),$msg; [IO.File]::AppendAllText($logPath,$line+"`r`n",(New-Object System.Text.UTF8Encoding($false))); Write-Host $msg }

try {
  $cfg=[IO.File]::ReadAllText($ConfigPath)|ConvertFrom-Json
  function EnvOrConfig($n,$v){ $e=[Environment]::GetEnvironmentVariable($n); if($e -and $e.Trim()){$e}else{$v} }
  $server=EnvOrConfig "DB_SERVER" $cfg.server; $auth=EnvOrConfig "DB_AUTH" $cfg.auth
  $user=EnvOrConfig "DB_USER" $cfg.user; $pwd=EnvOrConfig "DB_PASSWORD" $cfg.password
  $opsDb=EnvOrConfig "DB_OPS_DB" $cfg.opsDb
  $opsServer=EnvOrConfig "DB_OPS_SERVER" $cfg.opsServer; if(-not ("$opsServer".Trim())){ $opsServer=$server }
  $opsAuth=EnvOrConfig "DB_OPS_AUTH" $cfg.opsAuth; if(-not ("$opsAuth".Trim())){ $opsAuth=$auth }
  $opsUser=EnvOrConfig "DB_OPS_USER" $cfg.opsUser; if(-not ("$opsUser".Trim())){ $opsUser=$user }
  $opsPwd=EnvOrConfig "DB_OPS_PASSWORD" $cfg.opsPassword; if(-not ("$opsPwd".Trim())){ $opsPwd=$pwd }
  $opsAc= if($opsAuth -eq 'sql'){"User ID=$opsUser;Password=$opsPwd"}else{"Integrated Security=True"}
  $cs="Server=$opsServer;Database=master;$opsAc;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512"

  if(-not (Test-Path $BackupDir)){ New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
  $bak=Join-Path $BackupDir ("{0}_{1}.bak" -f $opsDb,$stamp)

  # --- database backup (COPY_ONLY so we don't disturb any existing differential/log chain) ---
  $cn=New-Object System.Data.SqlClient.SqlConnection $cs; $cn.Open()
  $c=$cn.CreateCommand(); $c.CommandTimeout=0
  $c.CommandText="BACKUP DATABASE [$opsDb] TO DISK=@p WITH COPY_ONLY, INIT, NAME=@n, STATS=10"
  [void]$c.Parameters.AddWithValue("@p",$bak)
  [void]$c.Parameters.AddWithValue("@n","$opsDb ops backup $stamp")
  [void]$c.ExecuteNonQuery(); $cn.Close()
  $mb=[Math]::Round((Get-Item $bak).Length/1MB,1)
  Log "BACKUP ok: $bak ($mb MB)"

  # --- secrets copy (per-machine, gitignored - lost forever if the box dies) ---
  $secDir=Join-Path $BackupDir ("secrets_{0}" -f $stamp)
  New-Item -ItemType Directory -Path $secDir -Force | Out-Null
  foreach($f in @($ConfigPath,(Join-Path $PSScriptRoot "users.json"),(Join-Path $PSScriptRoot "erp-api-map.json"))){
    if(Test-Path $f){ Copy-Item $f $secDir -Force }
  }
  Log "SECRETS copied: $secDir"

  # --- prune old backups + secret folders ---
  $cut=(Get-Date).AddDays(-$RetainDays)
  $delBak=@(Get-ChildItem -Path $BackupDir -Filter "*.bak" -File | Where-Object { $_.LastWriteTime -lt $cut })
  foreach($x in $delBak){ Remove-Item $x.FullName -Force }
  $delSec=@(Get-ChildItem -Path $BackupDir -Directory | Where-Object { $_.Name -like "secrets_*" -and $_.LastWriteTime -lt $cut })
  foreach($x in $delSec){ Remove-Item $x.FullName -Recurse -Force }
  Log "PRUNE: removed $($delBak.Count) .bak + $($delSec.Count) secret folder(s) older than $RetainDays day(s)"

  Write-Host "Backup complete." -ForegroundColor Green
  exit 0
}
catch {
  Log "BACKUP FAILED: $($_.Exception.Message)"
  Write-Host "Backup FAILED: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
