<#
  seed-milestone-config.ps1
  Seeds the milestone CONFIGURATION (data, not code) into pgsops:
    - milestone_def         : the Export + Import matrix (BLUEPRINT 2.3), rules expressed over the
                              REAL HKG-verified blhead columns. DATA-FIRST: qualify_rule / complete_rule
                              test ERP fields; PIC/EDI evidence is layered on as a SECONDARY way to close
                              (milestone_evidence_map, OR-ed in by the evaluator).
    - milestone_evidence_map: starter doctype/EDI rows (the "upload the right documentTypeCode to close
                              a hard-copy milestone" mechanism). Admin extends these later.
  Idempotent: MERGE by (milestone_code,bound) for defs; NOT-EXISTS guard for evidence rows.
  Re-runnable; does not touch the source ERP. Run setup-ops.ps1 first.
#>
param([string]$ConfigPath = (Join-Path $PSScriptRoot "ops.config.json"))
$ErrorActionPreference = "Stop"
$cfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
function EnvOrConfig($name, $cfgVal) { $v = [Environment]::GetEnvironmentVariable($name); if ($v -and $v.Trim() -ne "") { $v } else { $cfgVal } }
$server=EnvOrConfig "DB_SERVER" $cfg.server; $auth=EnvOrConfig "DB_AUTH" $cfg.auth
$user=EnvOrConfig "DB_USER" $cfg.user; $password=EnvOrConfig "DB_PASSWORD" $cfg.password
$opsDb=EnvOrConfig "DB_OPS_DB" $cfg.opsDb
$authClause = if ($auth -eq 'sql') { "User ID=$user;Password=$password" } else { "Integrated Security=True" }
# seeds only pgsops -> connect to the OPS server (two-server mode; falls back to source)
$opsServer=EnvOrConfig "DB_OPS_SERVER" $cfg.opsServer; if(-not ("$opsServer".Trim())){ $opsServer=$server }
$opsAuth=EnvOrConfig "DB_OPS_AUTH" $cfg.opsAuth; if(-not ("$opsAuth".Trim())){ $opsAuth=$auth }
$opsUser=EnvOrConfig "DB_OPS_USER" $cfg.opsUser; if(-not ("$opsUser".Trim())){ $opsUser=$user }
$opsPassword=EnvOrConfig "DB_OPS_PASSWORD" $cfg.opsPassword; if(-not ("$opsPassword".Trim())){ $opsPassword=$password }
$authClause = if ($opsAuth -eq 'sql') { "User ID=$opsUser;Password=$opsPassword" } else { "Integrated Security=True" }
$cs = "Server=$opsServer;Database=$opsDb;$authClause;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512"
$script:cn = New-Object System.Data.SqlClient.SqlConnection $cs; $script:cn.Open()
# VPN tunnel is flaky ("semaphore timeout" / transport errors); retry transient failures, reopening if the connection broke.
function Test-Transient($ex){ $m="$($ex.Message)"; $m -match 'semaphore timeout|transport-level|timeout period|deadlock|not currently available|forcibly closed' }
function Exec($sql, [hashtable]$p) {
  for($attempt=1; ; $attempt++){
    try {
      if ($script:cn.State -ne 'Open') { $script:cn.Close(); $script:cn=New-Object System.Data.SqlClient.SqlConnection $cs; $script:cn.Open() }
      $c=$script:cn.CreateCommand(); $c.CommandText=$sql; $c.CommandTimeout=60
      if ($p) { foreach($k in $p.Keys){ $v=$p[$k]; [void]$c.Parameters.AddWithValue("@$k", $(if($null -eq $v){[DBNull]::Value}else{$v})) } }
      [void]$c.ExecuteNonQuery(); return
    } catch {
      if ($attempt -ge 5 -or -not (Test-Transient $_.Exception)) { throw }
      Write-Host "  transient ($attempt/5): $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor DarkYellow
      try { $script:cn.Close() } catch {}; Start-Sleep -Seconds ($attempt*2)
    }
  }
}
# rule-builder helpers -> compact JSON (BLUEPRINT 2.2 cond kinds: field_notnull|field_eq|field_in|evidence|date_passed|mode_eq)
function Rule($op, [array]$conds){ (@{ op=$op; conds=$conds } | ConvertTo-Json -Compress -Depth 6) }
function Always(){ Rule 'AND' @() }                                  # empty AND = always true
function CNN($f){ @{ kind='field_notnull'; field=$f } }
function CEQ($f,$v){ @{ kind='field_eq'; field=$f; value=$v } }
function CIN($f,$set){ @{ kind='field_in'; field=$f; set=$set } }
function CEV(){ @{ kind='evidence' } }
function CMODE($v){ @{ kind='mode_eq'; value=$v } }
function Def($code,$bound,$name,$seq,$anchor,$qual,$comp,$slatype,$offval,$offunit,$dir,$slaanchor,$mode='Sea'){
  [pscustomobject]@{ code=$code;bound=$bound;name=$name;seq=$seq;anchor=$anchor;qual=$qual;comp=$comp;
    slatype=$slatype;offval=$offval;offunit=$offunit;dir=$dir;slaanchor=$slaanchor;mode=$mode }
}

# milestone_def rows (pscustomobjects so nested rule arrays don't flatten)
$defs = @(
 # ---- EXPORT (rules over real blhead columns; evidence OR-ed in by evaluator) ----
 (Def 'M1'  'Export' 'Booking Confirmation'         1 'booking'  (Always)                          (Rule 'OR' @((CNN 'blno'),(CNN 'picuser'),(CEV)))                          'baseline' $null $null $null $null)
 (Def 'M1b' 'Export' 'Space Confirmed'              2 'booking'  (Always)                          (Rule 'OR' @((CNN 'onboard'),(CEV)))                                       'baseline' $null $null $null $null)
 (Def 'M2'  'Export' 'Empty Container Release'      3 'etd'      (Rule 'AND' @((CMODE 'Sea'),(CEQ 'cargo_type' 'FCL')))  (Rule 'OR' @((CNN 'cargoready'),(CEV)))               'baseline' $null $null $null $null)
 (Def 'M3'  'Export' 'Origin Pickup'               4 'etd'      (Rule 'OR' @((CIN 'incoterm' @('EXW','FCA')),(CNN 'cargorece')))  (Rule 'OR' @((CNN 'cargorece'),(CEV)))       'baseline' $null $null $null $null)
 (Def 'M4'  'Export' 'Warehouse Receiving'         5 'etd'      (Rule 'OR' @((CEQ 'cargo_type' 'LCL')))  (Rule 'AND' @((CNN 'cargoready'),(CNN 'cargorece')))                  'baseline' $null $null $null $null)
 (Def 'M5'  'Export' 'Customs Clearance'           6 'etd'      (Rule 'AND' @((CEQ 'declaration' '1')))  (Rule 'OR' @((CNN 'customs_clearance'),(CEV)))                        'baseline' $null $null $null $null)
 (Def 'M6'  'Export' 'Shipping Instructions (SI)'  7 'etd'      (Rule 'AND' @((CMODE 'Sea')))     (Rule 'OR' @((CNN 'ts_blno'),(CEV)))                                       'baseline' $null $null $null $null)
 (Def 'M7'  'Export' 'Manifest Printing'           8 'etd'      (Always)                          (Rule 'OR' @((CEV)))                                                       'baseline' $null $null $null $null)
 (Def 'M8a' 'Export' 'Customs Manifest (AMS/ENS)'  9 'etd'      (Rule 'AND' @((CMODE 'Sea')))     (Rule 'OR' @((CNN 'ams_hbl'),(CNN 'edidate'),(CEV)))                       'fixed' 3 'day' 'before' 'onboard')
 (Def 'M9'  'Export' 'Agent EDI'                  10 'etd'      (Always)                          (Rule 'OR' @((CNN 'edidate'),(CEV)))                                       'baseline' $null $null $null $null)
 (Def 'M9b' 'Export' 'Departure (ATD)'            11 'atd'      (Always)                          (Rule 'OR' @((CNN 'atd_date')))                                            'baseline' $null $null $null $null)
 (Def 'M10' 'Export' 'Post-Dept. Invoicing'       12 'atd'      (Always)                          (Rule 'OR' @((CEV)))                                                       'fixed' 3 'day' 'after' 'atd_date')
 (Def 'M11' 'Export' 'Post-Dept. Monitor'         13 'delivery' (Rule 'AND' @((CNN 'eta_delivery')))  (Rule 'OR' @((CNN 'goods_delivery'),(CNN 'comp_date')))               'baseline' $null $null $null $null)
 # ---- IMPORT ----
 (Def 'M1'  'Import' 'Factory Booking Alert'       1 'booking'  (Always)                          (Rule 'OR' @((CEV)))                                                       'baseline' $null $null $null $null)
 (Def 'M2'  'Import' 'Transit Check'               2 'eta'      (Always)                          (Rule 'OR' @((CNN 'ata_date')))                                            'none' $null $null $null $null)
 (Def 'M3'  'Import' 'Import Documentation'        3 'eta'      (Always)                          (Rule 'OR' @((CIN 'status' @('Surrendered','Telex Released')),(CEV)))       'baseline' $null $null $null $null)
 (Def 'M4'  'Import' 'Arrival Notice'             4 'eta'      (Always)                          (Rule 'OR' @((CNN 'not1_date'),(CEV)))                                     'fixed' 3 'day' 'before' 'eta_delivery')
 (Def 'M4b' 'Import' 'Invoice from Liner'          5 'eta'      (Always)                          (Rule 'OR' @((CEV)))                                                       'baseline' $null $null $null $null)
 (Def 'M5'  'Import' 'Import Customs'              6 'eta'      (Rule 'AND' @((CNN 'broker')))    (Rule 'OR' @((CNN 'customs_clearance'),(CNN 'release_date'),(CIN 'status' @('Cleared','Released'))))  'baseline' $null $null $null $null)
 (Def 'M6'  'Import' 'Port/Airport Pickup'         7 'delivery' (Rule 'AND' @((CNN 'trucker')))   (Rule 'OR' @((CNN 'customer_pickup')))                                     'baseline' $null $null $null $null)
 (Def 'M7'  'Import' 'Warehouse Service'           8 'delivery' (Rule 'AND' @((CNN 'wh_code')))   (Rule 'OR' @((CNN 'ad_date'),(CNN 'ware_date')))                           'baseline' $null $null $null $null)
 (Def 'M8'  'Import' 'Final Delivery'              9 'delivery' (Rule 'AND' @((CNN 'pd_date')))   (Rule 'OR' @((CNN 'goods_delivery'),(CNN 'ad_date'),(CNN 'comp_date')))     'baseline' $null $null $null $null)
 (Def 'M9'  'Import' 'Invoice to Buyer'           10 'delivery' (Always)                          (Rule 'OR' @((CEV)))                                                       'fixed' 3 'day' 'after' 'ata_date')
 # ---- AIR EXPORT (rules over real awbhead columns; mode='Air') ----
 (Def 'A1' 'Export' 'Booking Confirmed'         1 'booking'  (Always)  (Rule 'OR' @((CNN 'hawb'),(CNN 'mawb'),(CNN 'picuser'),(CEV)))  'baseline' $null $null $null $null 'Air')
 (Def 'A2' 'Export' 'Flight / Space Confirmed'  2 'etd'      (Always)  (Rule 'OR' @((CNN 'flight1'),(CEV)))                           'baseline' $null $null $null $null 'Air')
 (Def 'A3' 'Export' 'Customs Declaration'       3 'etd'      (Always)  (Rule 'OR' @((CEQ 'declaration' '1'),(CEV)))                  'fixed' 1 'day' 'before' 'atd_date' 'Air')
 (Def 'A4' 'Export' 'AWB Issued'                4 'etd'      (Always)  (Rule 'OR' @((CNN 'mawb'),(CNN 'hawb'),(CEV)))                'baseline' $null $null $null $null 'Air')
 (Def 'A5' 'Export' 'Uplift / Departure (ATD)'  5 'atd'      (Always)  (Rule 'OR' @((CNN 'atd_date')))                               'baseline' $null $null $null $null 'Air')
 (Def 'A6' 'Export' 'Post-Departure Invoice'    6 'atd'      (Always)  (Rule 'OR' @((CEV)))                                          'fixed' 3 'day' 'after' 'atd_date' 'Air')
 (Def 'A7' 'Export' 'Arrival Confirmed'         7 'delivery' (Always)  (Rule 'OR' @((CNN 'ata_date'),(CNN 'comp_date')))            'baseline' $null $null $null $null 'Air')
 # ---- AIR IMPORT ----
 (Def 'A1' 'Import' 'Pre-Alert / Booking'       1 'booking'  (Always)  (Rule 'OR' @((CNN 'mawb'),(CNN 'hawb'),(CEV)))                'baseline' $null $null $null $null 'Air')
 (Def 'A2' 'Import' 'Flight Departed'           2 'eta'      (Always)  (Rule 'OR' @((CNN 'atd_date')))                               'none' $null $null $null $null 'Air')
 (Def 'A3' 'Import' 'Arrival (ATA)'             3 'eta'      (Always)  (Rule 'OR' @((CNN 'ata_date')))                               'baseline' $null $null $null $null 'Air')
 (Def 'A4' 'Import' 'Arrival Notice'            4 'eta'      (Always)  (Rule 'OR' @((CNN 'inform_cnee'),(CEV)))                      'baseline' $null $null $null $null 'Air')
 (Def 'A5' 'Import' 'Import Customs'            5 'eta'      (Always)  (Rule 'OR' @((CEQ 'declaration' '1'),(CEV)))                  'baseline' $null $null $null $null 'Air')
 (Def 'A6' 'Import' 'Pickup / Delivery'         6 'delivery' (Always)  (Rule 'OR' @((CNN 'cnee_pickup'),(CNN 'customer_pickup')))    'baseline' $null $null $null $null 'Air')
 (Def 'A7' 'Import' 'Invoice to Buyer'          7 'delivery' (Always)  (Rule 'OR' @((CEV)))                                          'fixed' 3 'day' 'after' 'ata_date' 'Air')
)

$mergeSql = @"
MERGE dbo.milestone_def AS t
USING (SELECT @code code,@bound bound) s ON t.milestone_code=s.code AND t.bound=s.bound
WHEN MATCHED THEN UPDATE SET name=@name,seq=@seq,phase_anchor=@anchor,qualify_rule=@qual,complete_rule=@comp,
  sla_type=@slatype,sla_offset_val=@offval,sla_offset_unit=@offunit,sla_direction=@dir,sla_anchor=@slaanchor,mode=@mode,active=1
WHEN NOT MATCHED THEN INSERT(milestone_code,bound,name,seq,phase_anchor,qualify_rule,complete_rule,sla_type,sla_offset_val,sla_offset_unit,sla_direction,sla_anchor,mode,active)
  VALUES(@code,@bound,@name,@seq,@anchor,@qual,@comp,@slatype,@offval,@offunit,@dir,@slaanchor,@mode,1);
"@
foreach($d in $defs){
  Exec $mergeSql @{ code=$d.code; bound=$d.bound; name=$d.name; seq=$d.seq; anchor=$d.anchor; qual=$d.qual; comp=$d.comp;
    slatype=$d.slatype; offval=$d.offval; offunit=$d.offunit; dir=$d.dir; slaanchor=$d.slaanchor; mode=$d.mode }
}
Write-Host "Seeded milestone_def: $($defs.Count) rows (Sea + Air, Export + Import)." -ForegroundColor Green

# ---- starter evidence map: documentTypeCode / EDI -> milestone (SECONDARY close path) ----
function Ev($code,$bound,$kind,$table,$field,$val,$mod){ [pscustomobject]@{code=$code;bound=$bound;kind=$kind;table=$table;field=$field;val=$val;mod=$mod} }
$evid = @(
 (Ev 'M1'  'Export' 'pic_doctype' 'PIC'    'doctype' 'Booking Photo'  'SEA')   # confirmed present in snapshot
 (Ev 'M6'  'Export' 'pic_doctype' 'PIC'    'doctype' 'HBL'            'SEA')   # user's example: upload HBL closes SI
 (Ev 'M8a' 'Export' 'edi_log'     'edilog' 'status'  'success'        $null)   # AMS via EDI ack
 (Ev 'M10' 'Export' 'pic_doctype' 'PIC'    'doctype' 'INVOICE'        'SEA')
 (Ev 'M4'  'Import' 'pic_doctype' 'PIC'    'doctype' 'Arrival Notice' $null)
)
$evSql = @"
IF NOT EXISTS (SELECT 1 FROM dbo.milestone_evidence_map
  WHERE milestone_code=@code AND bound=@bound AND source_kind=@kind
    AND ISNULL(source_field,'')=ISNULL(@field,'') AND ISNULL(match_value,'')=ISNULL(@val,''))
INSERT INTO dbo.milestone_evidence_map(milestone_code,bound,source_kind,source_table,source_field,match_value,module_match,active)
VALUES(@code,@bound,@kind,@table,@field,@val,@mod,1);
"@
foreach($e in $evid){
  Exec $evSql @{ code=$e.code; bound=$e.bound; kind=$e.kind; table=$e.table; field=$e.field; val=$e.val; mod=$e.mod }
}
Write-Host "Seeded milestone_evidence_map: $($evid.Count) starter rows." -ForegroundColor Green
$cn.Close()
Write-Host "Done. Inspect: SELECT milestone_code,bound,name,seq,sla_type FROM milestone_def ORDER BY bound,seq;" -ForegroundColor Cyan
