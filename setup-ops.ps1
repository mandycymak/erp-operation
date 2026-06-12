<#
  setup-ops.ps1
  Creates the operational-state database (default 'pgsops') with the 6 control-tower
  tables and indexes that power the listener + UI (see BLUEPRINT.md §1, §2, §4):
    milestone_baselines · shipment_alerts · milestone_def · milestone_evidence_map
    detention_watch · milestone_event_log
  Idempotent: safe to re-run (creates DB/tables/indexes only if missing).
  Source station databases are NEVER modified — all writes go to pgsops only.
#>
param([string]$ConfigPath = (Join-Path $PSScriptRoot "ops.config.json"))
$ErrorActionPreference = "Stop"
$cfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json   # NOT Get-Content: PS5.1 reads BOM-less UTF-8 as ANSI
function EnvOrConfig($name, $cfgVal) { $v = [Environment]::GetEnvironmentVariable($name); if ($v -and $v.Trim() -ne "") { $v } else { $cfgVal } }
$server   = EnvOrConfig "DB_SERVER"   $cfg.server
$auth     = EnvOrConfig "DB_AUTH"     $cfg.auth
$user     = EnvOrConfig "DB_USER"     $cfg.user
$password = EnvOrConfig "DB_PASSWORD" $cfg.password
$opsDb    = EnvOrConfig "DB_OPS_DB"   $cfg.opsDb
$authClause = if ($auth -eq 'sql') { "User ID=$user;Password=$password" } else { "Integrated Security=True" }
# Optional separate OPS connection (two-server mode): pgsops can live on a different server than the read-only
# source ERP. Falls back to the source connection when not configured (single-server, backward compatible).
$opsServer   = EnvOrConfig "DB_OPS_SERVER"   $cfg.opsServer;   if (-not ("$opsServer".Trim()))   { $opsServer = $server }
$opsAuth     = EnvOrConfig "DB_OPS_AUTH"     $cfg.opsAuth;     if (-not ("$opsAuth".Trim()))     { $opsAuth = $auth }
$opsUser     = EnvOrConfig "DB_OPS_USER"     $cfg.opsUser;     if (-not ("$opsUser".Trim()))     { $opsUser = $user }
$opsPassword = EnvOrConfig "DB_OPS_PASSWORD" $cfg.opsPassword; if (-not ("$opsPassword".Trim())) { $opsPassword = $password }
$opsAuthClause = if ($opsAuth -eq 'sql') { "User ID=$opsUser;Password=$opsPassword" } else { "Integrated Security=True" }

# Packet Size=512: VPN tunnel MTU is small; default 8192-byte TDS packets stall on multi-packet responses.
# master + the ops DB route to the OPS server; everything else to the source server.
function ConnStr($db) {
  if ($db -eq $opsDb -or $db -eq 'master') { "Server=$opsServer;Database=$db;$opsAuthClause;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512" }
  else { "Server=$server;Database=$db;$authClause;TrustServerCertificate=True;Connect Timeout=30;Packet Size=512" }
}
function ExecSql($db, $sql) {
  $cn = New-Object System.Data.SqlClient.SqlConnection (ConnStr $db); $cn.Open()
  try { $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 120; [void]$c.ExecuteNonQuery() } finally { $cn.Close() }
}

Write-Host "Creating operational database [$opsDb] on $opsServer ..." -ForegroundColor Cyan
ExecSql "master" "IF DB_ID('$opsDb') IS NULL CREATE DATABASE [$opsDb]"

# --- 1.1 milestone_baselines — monthly 3-year averages per [lane x carrier x mode x milestone] (reference only) ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.milestone_baselines') IS NULL
CREATE TABLE dbo.milestone_baselines (
  id              int IDENTITY(1,1) PRIMARY KEY,
  lane            nvarchar(40)  NOT NULL,   -- pol_country+'-'+pod_country (coarse) or port-pair
  carrier         nvarchar(12)  NOT NULL,   -- liner (sea) / airline (air); '*' = all carriers fallback
  mode            char(3)       NOT NULL,   -- 'Sea' | 'Air'
  milestone_code  nvarchar(12)  NOT NULL,   -- 'M1'..'M11', 'DET','DEM'
  anchor_event    nvarchar(20)  NOT NULL,   -- 'booking' | 'etd' | 'eta' | 'atd' (what avg_days is measured from)
  avg_days        decimal(7,2)  NOT NULL,   -- mean anchor->completion
  p50_days        decimal(7,2)  NULL,
  p90_days        decimal(7,2)  NULL,       -- the alert "expected" window (robust)
  sample_size     int           NOT NULL,
  window_from     date          NOT NULL,   -- 3-year window start
  computed_at     datetime2     NOT NULL
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_baseline' AND object_id=OBJECT_ID('dbo.milestone_baselines'))
  CREATE UNIQUE INDEX UX_baseline ON dbo.milestone_baselines(lane,carrier,mode,milestone_code);
"@

# --- 1.2 shipment_alerts — one row per active shipment (the lightweight UI/KPI table; UI reads ONLY this) ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.shipment_alerts') IS NULL
CREATE TABLE dbo.shipment_alerts (
  job_no          nvarchar(24) NOT NULL,    -- station+blno/hawb composite (stable key)
  station         nvarchar(8)  NOT NULL,
  mode            char(3)      NOT NULL,     -- 'Sea'|'Air'
  cargo_type      nvarchar(8)  NULL,         -- 'FCL'|'LCL'|'Consol'
  bound           nvarchar(8)  NOT NULL,     -- 'Export'|'Import'
  lane            nvarchar(40) NULL,
  carrier         nvarchar(12) NULL,
  cust_code       nvarchar(12) NULL,
  agent_code      nvarchar(12) NULL,
  salesman        nvarchar(20) NULL,
  pic_user        nvarchar(20) NULL,         -- operator / person-in-charge (ERP crtuser or PIC table)
  created_by      nvarchar(20) NULL,         -- booking creator
  last_updated_by nvarchar(20) NULL,         -- last ERP updater (for "the update is me")
  anchor_date     date NULL,                 -- booking/job date
  etd date NULL, eta date NULL, atd date NULL, ata date NULL,
  job_status      nvarchar(10) NOT NULL,     -- 'active'|'closed'|'void' (void/closed get aged out)
  worst_light     char(1) NOT NULL,          -- 'G'|'A'|'R' (precomputed rollup for fast dashboards)
  open_amber      int NOT NULL DEFAULT 0,
  open_red        int NOT NULL DEFAULT 0,
  next_due        date NULL,                 -- earliest pending milestone due-date
  auto_done       int NOT NULL DEFAULT 0,    -- automation-score numerator support
  manual_done     int NOT NULL DEFAULT 0,    -- manual "tick & confirm" count
  milestone_checklist nvarchar(max) NULL,    -- JSON (see BLUEPRINT 1.3)
  updated_at      datetime2 NOT NULL,
  CONSTRAINT PK_shipment_alerts PRIMARY KEY (job_no)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_alerts_pic'   AND object_id=OBJECT_ID('dbo.shipment_alerts'))
  CREATE INDEX IX_alerts_pic   ON dbo.shipment_alerts(pic_user)  INCLUDE(worst_light,next_due,job_status);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_alerts_light' AND object_id=OBJECT_ID('dbo.shipment_alerts'))
  CREATE INDEX IX_alerts_light ON dbo.shipment_alerts(worst_light, next_due) INCLUDE(station,mode,bound);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_alerts_lane'  AND object_id=OBJECT_ID('dbo.shipment_alerts'))
  CREATE INDEX IX_alerts_lane  ON dbo.shipment_alerts(lane, carrier);
"@

# --- 1.2b shipment_alerts enrichment (added in place): operator-facing display fields for the
#     arrival-driven worklist (consignee/shipper name+contact, vessel/voyage, cargo profile) and the
#     precomputed arrival bucket/sort. All populated off the request path by seed-alerts.ps1. ---
ExecSql $opsDb @"
IF COL_LENGTH('dbo.shipment_alerts','consignee_name')  IS NULL ALTER TABLE dbo.shipment_alerts ADD consignee_name  nvarchar(120) NULL;
IF COL_LENGTH('dbo.shipment_alerts','shipper_name')    IS NULL ALTER TABLE dbo.shipment_alerts ADD shipper_name    nvarchar(120) NULL;
IF COL_LENGTH('dbo.shipment_alerts','cust_contact')    IS NULL ALTER TABLE dbo.shipment_alerts ADD cust_contact    nvarchar(80)  NULL;
IF COL_LENGTH('dbo.shipment_alerts','cust_phone')      IS NULL ALTER TABLE dbo.shipment_alerts ADD cust_phone      nvarchar(40)  NULL;
IF COL_LENGTH('dbo.shipment_alerts','cust_email')      IS NULL ALTER TABLE dbo.shipment_alerts ADD cust_email      nvarchar(120) NULL;
IF COL_LENGTH('dbo.shipment_alerts','vessel_voyage')   IS NULL ALTER TABLE dbo.shipment_alerts ADD vessel_voyage   nvarchar(60)  NULL;
IF COL_LENGTH('dbo.shipment_alerts','container_summary') IS NULL ALTER TABLE dbo.shipment_alerts ADD container_summary nvarchar(80) NULL;
IF COL_LENGTH('dbo.shipment_alerts','container_count') IS NULL ALTER TABLE dbo.shipment_alerts ADD container_count int NULL;
IF COL_LENGTH('dbo.shipment_alerts','total_weight')    IS NULL ALTER TABLE dbo.shipment_alerts ADD total_weight    decimal(12,2) NULL;
IF COL_LENGTH('dbo.shipment_alerts','total_cbm')       IS NULL ALTER TABLE dbo.shipment_alerts ADD total_cbm       decimal(12,2) NULL;
IF COL_LENGTH('dbo.shipment_alerts','arrival_state')   IS NULL ALTER TABLE dbo.shipment_alerts ADD arrival_state   nvarchar(14)  NULL;
IF COL_LENGTH('dbo.shipment_alerts','sort_key')        IS NULL ALTER TABLE dbo.shipment_alerts ADD sort_key        date          NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_alerts_arrival' AND object_id=OBJECT_ID('dbo.shipment_alerts'))
  CREATE INDEX IX_alerts_arrival ON dbo.shipment_alerts(bound, arrival_state, sort_key);
"@

# --- 1.2c shipment_alerts reference fields (added in place): the documents the OPERATOR and the CUSTOMER
#     recognise — so near-identical arrivals can be told apart and responsibility is clear at a glance.
#       house_bill   = origin-office house BL/AWB (blhead.blno where bill_type='H' | awbhead.hawb) — the doc
#                      the import customer actually received; the internal job_no means nothing to them.
#       master_bill  = carrier/master BL/AWB (blhead.mobl | awbhead.mawb).
#       incoterm     = trade term (blhead.routing | awbhead.frt_terms): tells the operator if delivery is to
#                      the buyer's door or only to the port.
#       cust_ref     = customer PO / order ref (awbhead.po_no; no reliable sea field -> NULL for sea).
#       container_no = first container number (blcont.container) — the strongest sea differentiator.
#       liner_so     = liner shipping-order number (blcont.lsno) — fallback differentiator when no container.
#       cargo_ready  = cargo-ready date (cargoready) — export urgency even before a vessel/flight is booked.
ExecSql $opsDb @"
IF COL_LENGTH('dbo.shipment_alerts','house_bill')   IS NULL ALTER TABLE dbo.shipment_alerts ADD house_bill   nvarchar(40) NULL;
IF COL_LENGTH('dbo.shipment_alerts','master_bill')  IS NULL ALTER TABLE dbo.shipment_alerts ADD master_bill  nvarchar(40) NULL;
IF COL_LENGTH('dbo.shipment_alerts','incoterm')     IS NULL ALTER TABLE dbo.shipment_alerts ADD incoterm     nvarchar(12) NULL;
IF COL_LENGTH('dbo.shipment_alerts','cust_ref')     IS NULL ALTER TABLE dbo.shipment_alerts ADD cust_ref     nvarchar(40) NULL;
IF COL_LENGTH('dbo.shipment_alerts','container_no') IS NULL ALTER TABLE dbo.shipment_alerts ADD container_no nvarchar(40) NULL;
IF COL_LENGTH('dbo.shipment_alerts','liner_so')     IS NULL ALTER TABLE dbo.shipment_alerts ADD liner_so     nvarchar(40) NULL;
IF COL_LENGTH('dbo.shipment_alerts','cargo_ready')  IS NULL ALTER TABLE dbo.shipment_alerts ADD cargo_ready  date          NULL;
"@

# --- 1.2d shipment_alerts party/route fields (added in place): the companies a shipment touches and the
#     ports, so an operator can pull up "every shipment for company X" or "everything loading at CN port Y".
#       shipper_code / consignee_code / agent_code / ctrl_code = the four roles a company can play on a job
#         (ctrl_code = rcustomer, the controlling customer we actually serve). The worklist company filter
#         matches the picked code against ANY of these (a company may be shipper on one job, consignee on another).
#       pol / pod = port of loading / discharge codes (lane is the display string; these are for filtering).
ExecSql $opsDb @"
IF COL_LENGTH('dbo.shipment_alerts','shipper_code')   IS NULL ALTER TABLE dbo.shipment_alerts ADD shipper_code   nvarchar(12) NULL;
IF COL_LENGTH('dbo.shipment_alerts','consignee_code') IS NULL ALTER TABLE dbo.shipment_alerts ADD consignee_code nvarchar(12) NULL;
IF COL_LENGTH('dbo.shipment_alerts','ctrl_code')      IS NULL ALTER TABLE dbo.shipment_alerts ADD ctrl_code      nvarchar(12) NULL;
IF COL_LENGTH('dbo.shipment_alerts','pol')            IS NULL ALTER TABLE dbo.shipment_alerts ADD pol            nvarchar(12) NULL;
IF COL_LENGTH('dbo.shipment_alerts','pod')            IS NULL ALTER TABLE dbo.shipment_alerts ADD pod            nvarchar(12) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_alerts_pol' AND object_id=OBJECT_ID('dbo.shipment_alerts'))
  CREATE INDEX IX_alerts_pol ON dbo.shipment_alerts(pol);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_alerts_pod' AND object_id=OBJECT_ID('dbo.shipment_alerts'))
  CREATE INDEX IX_alerts_pod ON dbo.shipment_alerts(pod);
"@

# --- 1.2e shipment_alerts route/deep-detail fields (added in place): the full leg route the operator quotes
#     to stakeholders, plus the deep-detail snapshot for the drawer (refreshed each listener pass).
#       route_summary = point codes joined ' → ' (worklist-flat; e.g. 'HKHKG → USLAX → USCHI').
#       route_json    = JSON array of points {role,code,name,dep,arr,flight,vessel,voyage} (drawer only).
#       detail_json   = JSON {remark,special_remark,commodity[],cargo:{book,rece}} (drawer only).
#       commodity     = first goods description (sea blitem.good_desc1 | air awbdetl.good_desc2).
#       sono          = SO/booking number (blhead.sono | awbhead.booking) — stable from booking stage.
#       available_date / eta_delivery / goods_delivery = pickup-available / expected / actual delivery (sea).
#       erp_ref       = source header PK (blhead.ref | awbhead.ref) — keyed seek handle for the on-demand
#                       /api-ops/erp-detail lookup and the blitem/awbdetl child reads.
ExecSql $opsDb @"
IF COL_LENGTH('dbo.shipment_alerts','route_summary')  IS NULL ALTER TABLE dbo.shipment_alerts ADD route_summary  nvarchar(120) NULL;
IF COL_LENGTH('dbo.shipment_alerts','route_json')     IS NULL ALTER TABLE dbo.shipment_alerts ADD route_json     nvarchar(max) NULL;
IF COL_LENGTH('dbo.shipment_alerts','detail_json')    IS NULL ALTER TABLE dbo.shipment_alerts ADD detail_json    nvarchar(max) NULL;
IF COL_LENGTH('dbo.shipment_alerts','commodity')      IS NULL ALTER TABLE dbo.shipment_alerts ADD commodity      nvarchar(120) NULL;
IF COL_LENGTH('dbo.shipment_alerts','sono')           IS NULL ALTER TABLE dbo.shipment_alerts ADD sono           nvarchar(40)  NULL;
IF COL_LENGTH('dbo.shipment_alerts','available_date') IS NULL ALTER TABLE dbo.shipment_alerts ADD available_date date          NULL;
IF COL_LENGTH('dbo.shipment_alerts','eta_delivery')   IS NULL ALTER TABLE dbo.shipment_alerts ADD eta_delivery   date          NULL;
IF COL_LENGTH('dbo.shipment_alerts','goods_delivery') IS NULL ALTER TABLE dbo.shipment_alerts ADD goods_delivery date          NULL;
IF COL_LENGTH('dbo.shipment_alerts','erp_ref')        IS NULL ALTER TABLE dbo.shipment_alerts ADD erp_ref        nvarchar(24)  NULL;
"@

# --- 2.8 port_dim — full port/airport master copy (ERP portmstr: ~3.9k sea UN/LOCODEs + ~1.5k IATA codes)
#     so the UI port pickers can search by NAME as well as code (Tokyo -> TYO/HND/JPTYO) without the request
#     path touching the ERP. Refreshed weekly by seed-ports.ps1. PK (code,module): the same code can exist
#     in both modules. ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.port_dim') IS NULL
CREATE TABLE dbo.port_dim (
  code       nvarchar(8)  NOT NULL,
  module     char(3)      NOT NULL,        -- 'SEA'|'AIR' (portmstr.module)
  name       nvarchar(80) NULL,            -- portmstr.port_ldes1
  country    nvarchar(4)  NULL,
  updated_at datetime2    NOT NULL,
  CONSTRAINT PK_port_dim PRIMARY KEY (code, module)
);
"@

# --- 2.7 company_dim — code->name lookup so the UI's company filter can show real names without the request
#     path ever touching the ERP. Populated by seed-alerts.ps1 (resolves codes via the ERP party views once,
#     off the request path) for every company that appears as shipper/consignee/agent/controlling-customer. ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.company_dim') IS NULL
CREATE TABLE dbo.company_dim (
  code       nvarchar(12)  NOT NULL,
  name       nvarchar(120) NULL,
  updated_at datetime2     NOT NULL,
  CONSTRAINT PK_company_dim PRIMARY KEY (code)
);
"@

# --- 2.1 milestone_def — config-driven matrix: qualify/complete rules + SLA per [milestone x bound] ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.milestone_def') IS NULL
CREATE TABLE dbo.milestone_def (
  milestone_code  nvarchar(12) NOT NULL,
  bound           nvarchar(8)  NOT NULL,   -- 'Export'|'Import'|'Both'
  name            nvarchar(60) NOT NULL,
  seq             int          NOT NULL,
  phase_anchor    nvarchar(12) NOT NULL,   -- booking|etd|atd|eta|delivery
  qualify_rule    nvarchar(max) NOT NULL,  -- JSON (see BLUEPRINT 2.2)
  complete_rule   nvarchar(max) NOT NULL,  -- JSON (see BLUEPRINT 2.2)
  sla_type        nvarchar(12) NOT NULL,   -- 'baseline'|'fixed'|'none'
  sla_offset_val  int NULL,                -- e.g. 3
  sla_offset_unit nvarchar(6) NULL,        -- 'day'|'hour'
  sla_direction   nvarchar(8) NULL,        -- 'before'|'after'
  sla_anchor      nvarchar(12) NULL,       -- 'onboard'|'flight_dep'|'atd'|'ata'
  active          bit NOT NULL DEFAULT 1,
  CONSTRAINT PK_milestone_def PRIMARY KEY (milestone_code, bound)
);
-- mode (added in place): which transport mode a milestone applies to ('Sea'|'Air'|'Both'); evaluator filters by it.
IF COL_LENGTH('dbo.milestone_def','mode') IS NULL
  ALTER TABLE dbo.milestone_def ADD mode nvarchar(6) NOT NULL DEFAULT 'Sea';
"@

# --- 2.1 milestone_evidence_map — admin-mapped doc-type/log entry that satisfies a milestone (retroactive auto-close) ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.milestone_evidence_map') IS NULL
CREATE TABLE dbo.milestone_evidence_map (
  id int IDENTITY(1,1) PRIMARY KEY,
  milestone_code nvarchar(12) NOT NULL,
  bound          nvarchar(8)  NOT NULL,
  source_kind    nvarchar(16) NOT NULL,    -- 'erp_field'|'pic_doctype'|'print_log'|'send_log'|'edi_log'|'status_eq'
  source_table   nvarchar(40) NULL,        -- real ERP table (admin-mapped)
  source_field   nvarchar(40) NULL,        -- real ERP column / doc_type value
  match_value    nvarchar(40) NULL,        -- e.g. 'Customs','RCL','Surrendered'
  active bit NOT NULL DEFAULT 1
);
-- module_match (added in place): the ERP moduleTypeCode (e.g. 'SEA'|'AIR') a PIC doctype is scoped to; NULL = any module.
IF COL_LENGTH('dbo.milestone_evidence_map','module_match') IS NULL
  ALTER TABLE dbo.milestone_evidence_map ADD module_match nvarchar(8) NULL;
"@

# --- 2.6 detention_watch — post-delivery DET/DEM tracking per [job x container x kind], days-over vs free-time ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.detention_watch') IS NULL
CREATE TABLE dbo.detention_watch (
  job_no        nvarchar(24) NOT NULL,
  container_no  nvarchar(15) NOT NULL,
  dest_port     nvarchar(8)  NOT NULL,
  carrier       nvarchar(12) NULL,
  kind          char(3) NOT NULL,        -- 'DET' (to consignee) | 'DEM' (empty return)
  free_days     int NULL,                -- from free_time_config (port x carrier)
  free_until    date NULL,               -- last_free_date
  event_date    date NULL,               -- gate-out / empty-return actual (NULL = still running)
  days_over     int NULL,                -- computed: max(0, ref_date - free_until)
  est_charge    decimal(12,2) NULL,      -- days_over * daily_rate (config)
  light         char(1) NOT NULL,        -- A when approaching free_until, R when over
  origin_station nvarchar(8) NULL,       -- so both offices get the alert
  updated_at    datetime2 NOT NULL,
  CONSTRAINT PK_detention_watch PRIMARY KEY (job_no, container_no, kind)
);
"@

# --- 4.1 milestone_event_log — append-only state-transition log that powers the KPIs cheaply ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.milestone_event_log') IS NULL
CREATE TABLE dbo.milestone_event_log (
  id bigint IDENTITY(1,1) PRIMARY KEY,
  job_no nvarchar(24) NOT NULL, milestone_code nvarchar(12) NOT NULL,
  station nvarchar(8) NULL, pic_user nvarchar(20) NULL, mode char(3) NULL,
  from_state nvarchar(12) NULL, to_state nvarchar(12) NULL,   -- pending->done / amber->done / amber->red / pending->bypassed
  from_light char(1) NULL, to_light char(1) NULL,
  done_by nvarchar(20) NULL,                                  -- 'auto'|'system_seq'|<username>
  reason nvarchar(200) NULL, occurred_at datetime2 NOT NULL
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_evt_pic_time' AND object_id=OBJECT_ID('dbo.milestone_event_log'))
  CREATE INDEX IX_evt_pic_time ON dbo.milestone_event_log(pic_user, occurred_at) INCLUDE(to_state,from_light,to_light,done_by);
"@

# ============================================================================================================
#  CROSS-STATION INBOUND BOOKING FEED (publish/subscribe fan-in; see plan + project-summary key finding 5)
#  An ORIGIN station publishes its outbound bookings (whose destination office is another station) into the
#  central feed; the destination station's app reads ONLY rows addressed to it (dest_station=@stationCode).
#  No station ever queries another station's ERP; the request path reads only these small pgsops tables.
# ============================================================================================================

# --- X.1 station_dim — our own group offices (the destination vocabulary). Seeded from each source ERP's
#     dbo.asw_station_list (CODE + FM3000_CODE) joined to ops.config stations[] (database_name). ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.station_dim') IS NULL
CREATE TABLE dbo.station_dim (
  code          nvarchar(8)  NOT NULL,     -- our StationCode (HKG, SHA, SGN, BKK…)
  fm3000_code   nvarchar(12) NULL,         -- group/global office code (asw_station_list.FM3000_CODE)
  name          nvarchar(80) NULL,
  database_name nvarchar(64) NULL,         -- source ERP db for this station (from ops.config stations[])
  active        bit NOT NULL DEFAULT 1,
  updated_at    datetime2 NOT NULL,
  CONSTRAINT PK_station_dim PRIMARY KEY (code)
);
"@

# --- X.2 station_route_map — resolves an ORIGIN booking's destination code -> the importing station. The
#     destination is encoded in the origin's OWN master (agn2_code=dest agent, rcustomer=controlling cust),
#     so rows are keyed by origin_station; '*' origin = a global rule (e.g. a POD-port fallback). Match
#     precedence in the publisher: agent -> ctrl -> roagent -> pod, lowest priority wins. Admin-maintainable. ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.station_route_map') IS NULL
CREATE TABLE dbo.station_route_map (
  id             int IDENTITY(1,1) PRIMARY KEY,
  origin_station nvarchar(8)  NOT NULL,    -- StationCode whose master owns match_value; '*' = global rule
  match_kind     nvarchar(12) NOT NULL,    -- 'agent'|'ctrl'|'roagent'|'pod'
  match_value    nvarchar(20) NOT NULL,    -- agn2_code / rcustomer / roagent code, OR a pod port code
  dest_station   nvarchar(8)  NOT NULL,    -- importing StationCode this resolves to
  priority       int          NOT NULL DEFAULT 100,   -- lower wins when several rules match one booking
  active         bit          NOT NULL DEFAULT 1,
  note           nvarchar(120) NULL,
  updated_at     datetime2    NOT NULL
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_route' AND object_id=OBJECT_ID('dbo.station_route_map'))
  CREATE UNIQUE INDEX UX_route ON dbo.station_route_map(origin_station,match_kind,match_value,dest_station);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_route_origin' AND object_id=OBJECT_ID('dbo.station_route_map'))
  CREATE INDEX IX_route_origin ON dbo.station_route_map(origin_station,active) INCLUDE(match_kind,match_value,dest_station,priority);
"@

# --- X.3 inbound_booking_feed — one row per cross-station booking line, denormalized for the importer's
#     request path (reads ONLY this table by dest_station). PK leads with source_station so each origin's
#     MERGE touches a disjoint key range (no hot tail page). Publisher owns all columns EXCEPT
#     feed_status/assigned_to/linked_job_no, which the consuming station owns (local assignment). ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.inbound_booking_feed') IS NULL
CREATE TABLE dbo.inbound_booking_feed (
  source_station nvarchar(8)  NOT NULL,    -- origin StationCode that published
  mode           char(3)      NOT NULL,    -- 'Sea'|'Air'
  booking_no     nvarchar(40) NOT NULL,    -- origin booking ref (blhead.blno @ bill_type='B' | awbhead ref)
  dest_station   nvarchar(8)  NOT NULL,    -- resolved importing station (the consumer key)
  source_jobn    nvarchar(24) NULL,        -- origin internal job no (groups split bookings; reconciliation)
  master_bill    nvarchar(40) NULL,
  house_bill     nvarchar(40) NULL,
  shipper_code   nvarchar(12) NULL, shipper_name nvarchar(120) NULL,
  ctrl_code      nvarchar(12) NULL, ctrl_name    nvarchar(120) NULL,   -- controlling customer (rcustomer)
  agent_code     nvarchar(12) NULL, agent_name   nvarchar(120) NULL,   -- dest agent (agn2_code) at origin
  pol            nvarchar(12) NULL, pod          nvarchar(12) NULL,
  carrier        nvarchar(12) NULL, vessel_flight nvarchar(60) NULL,
  etd            date NULL, cargo_ready date NULL, incoterm nvarchar(12) NULL,
  cargo_summary  nvarchar(80) NULL, booking_date date NULL,            -- crtdate: how early we heard
  feed_status    nvarchar(12) NOT NULL DEFAULT 'open',   -- 'open'|'consumed'|'void'   (consumer-owned)
  assigned_to    nvarchar(20) NULL,                      -- LOCAL operator             (consumer-owned)
  linked_job_no  nvarchar(24) NULL,                      -- shipment_alerts.job_no once import job exists (consumer-owned)
  light          char(1) NOT NULL DEFAULT 'G',           -- pre-arrival urgency G/A/R
  src_updated_at datetime2 NULL,                         -- origin upddate (watermark source)
  updated_at     datetime2 NOT NULL,
  CONSTRAINT PK_inbound_feed PRIMARY KEY (source_station, mode, booking_no)
);
-- consignee-facing enrichment (in-place adds): the importer talks to the CONSIGNEE about the origin-side plan,
-- so surface who receives the cargo + service/qty/refs (some empty at booking stage, fill in as origin proceeds).
IF COL_LENGTH('dbo.inbound_booking_feed','consignee_code') IS NULL ALTER TABLE dbo.inbound_booking_feed ADD consignee_code nvarchar(12)  NULL;
IF COL_LENGTH('dbo.inbound_booking_feed','consignee_name') IS NULL ALTER TABLE dbo.inbound_booking_feed ADD consignee_name nvarchar(120) NULL;
IF COL_LENGTH('dbo.inbound_booking_feed','cargo_type')     IS NULL ALTER TABLE dbo.inbound_booking_feed ADD cargo_type     nvarchar(12)  NULL;  -- FCL|LCL|Mixed|Air
IF COL_LENGTH('dbo.inbound_booking_feed','service')        IS NULL ALTER TABLE dbo.inbound_booking_feed ADD service        nvarchar(20)  NULL;  -- raw blhead.service e.g. 'CY /CY'
IF COL_LENGTH('dbo.inbound_booking_feed','container_no')   IS NULL ALTER TABLE dbo.inbound_booking_feed ADD container_no   nvarchar(40)  NULL;
IF COL_LENGTH('dbo.inbound_booking_feed','po_no')          IS NULL ALTER TABLE dbo.inbound_booking_feed ADD po_no          nvarchar(60)  NULL;
IF COL_LENGTH('dbo.inbound_booking_feed','spot_id')        IS NULL ALTER TABLE dbo.inbound_booking_feed ADD spot_id        nvarchar(40)  NULL;  -- ship/spot id (blhead.spotid)
IF COL_LENGTH('dbo.inbound_booking_feed','booking_qty')    IS NULL ALTER TABLE dbo.inbound_booking_feed ADD booking_qty    nvarchar(40)  NULL;
IF COL_LENGTH('dbo.inbound_booking_feed','booking_wgt')    IS NULL ALTER TABLE dbo.inbound_booking_feed ADD booking_wgt    nvarchar(40)  NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_feed_dest' AND object_id=OBJECT_ID('dbo.inbound_booking_feed'))
  CREATE INDEX IX_feed_dest ON dbo.inbound_booking_feed(dest_station, feed_status, etd)
    INCLUDE(mode,light,source_station,booking_no,source_jobn,shipper_name,ctrl_name,agent_name,pol,pod,assigned_to);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_feed_assigned' AND object_id=OBJECT_ID('dbo.inbound_booking_feed'))
  CREATE INDEX IX_feed_assigned ON dbo.inbound_booking_feed(dest_station, assigned_to) INCLUDE(feed_status, etd);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_feed_link' AND object_id=OBJECT_ID('dbo.inbound_booking_feed'))
  CREATE INDEX IX_feed_link ON dbo.inbound_booking_feed(linked_job_no);
"@

# --- X.4 feed_watermark — high-water per (source_station, mode) so each publisher pass writes only the delta. ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.feed_watermark') IS NULL
CREATE TABLE dbo.feed_watermark (
  source_station nvarchar(8) NOT NULL,
  mode           char(3)     NOT NULL,
  last_src_at    datetime2   NULL,        -- MAX(upddate/crtdate) consumed so far
  run_at         datetime2   NOT NULL,
  CONSTRAINT PK_feed_watermark PRIMARY KEY (source_station, mode)
);
"@

# ============================================================================================================
#  DRAFT DOCUMENT REVIEW (House BL / HAWB customer agreement loop; see plan file)
#  Staff create a DRAFT document from shipment data, send the customer a tokenized review link (no login),
#  the customer edits the on-screen bill and submits; staff diff/correct/resend until both agree, then the
#  backend ERP API issues the official document. Versions are immutable JSON field snapshots; every action
#  is appended to doc_event_log. Raw tokens are NEVER stored - only their SHA-256 hash.
# ============================================================================================================

# --- D.1 doc_draft — one live document per (job x type); the workflow head row ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.doc_draft') IS NULL
CREATE TABLE dbo.doc_draft (
  doc_id          nvarchar(36)  NOT NULL,     -- guid
  job_no          nvarchar(24)  NOT NULL,
  doc_type        nvarchar(4)   NOT NULL,     -- 'HBL'|'HAWB'
  station         nvarchar(8)   NULL,         -- denormalized from shipment_alerts for row-level scope
  mode            char(3)       NULL,
  bound           nvarchar(8)   NULL,
  status          nvarchar(20)  NOT NULL,     -- DRAFT|SENT|CUSTOMER_SUBMITTED|CUSTOMER_APPROVED|AGREED|ISSUED|AMEND_DRAFT
  current_version int           NOT NULL DEFAULT 1,
  customer_email  nvarchar(120) NULL,
  customer_name   nvarchar(80)  NULL,
  erp_doc_no      nvarchar(40)  NULL,         -- official document number returned by the ERP at issue
  issued_at       datetime2     NULL,
  amend_count     int           NOT NULL DEFAULT 0,   -- >0 = amendment fee applies
  created_by      nvarchar(20)  NULL,
  created_at      datetime2     NOT NULL,
  updated_at      datetime2     NOT NULL,
  CONSTRAINT PK_doc_draft PRIMARY KEY (doc_id)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_doc_job_type' AND object_id=OBJECT_ID('dbo.doc_draft'))
  CREATE UNIQUE INDEX UX_doc_job_type ON dbo.doc_draft(job_no, doc_type);
"@

# --- D.2 doc_version — immutable field snapshots; fields = flat JSON {field_code: text} ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.doc_version') IS NULL
CREATE TABLE dbo.doc_version (
  doc_id       nvarchar(36)  NOT NULL,
  version_no   int           NOT NULL,
  side         nvarchar(8)   NOT NULL,        -- 'staff'|'customer'
  base_version int           NULL,            -- version this one was edited from (diff anchor)
  fields       nvarchar(max) NOT NULL,        -- flat JSON map of field_code -> value
  comment      nvarchar(1000) NULL,
  created_by   nvarchar(80)  NULL,            -- username | 'customer:<email>'
  created_at   datetime2     NOT NULL,
  CONSTRAINT PK_doc_version PRIMARY KEY (doc_id, version_no)
);
"@

# --- D.3 doc_review_token — customer access tokens (hash-at-rest; expiry + revocation; view counters) ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.doc_review_token') IS NULL
CREATE TABLE dbo.doc_review_token (
  token_hash     char(64)      NOT NULL,      -- SHA-256 hex of the raw URL token (raw never stored)
  doc_id         nvarchar(36)  NOT NULL,
  sent_version   int           NOT NULL,      -- the version the customer was sent
  customer_email nvarchar(120) NULL,
  customer_name  nvarchar(80)  NULL,
  expires_at     datetime2     NOT NULL,
  revoked        bit           NOT NULL DEFAULT 0,
  created_by     nvarchar(20)  NULL,
  created_at     datetime2     NOT NULL,
  view_count     int           NOT NULL DEFAULT 0,
  last_view_at   datetime2     NULL,
  CONSTRAINT PK_doc_token PRIMARY KEY (token_hash)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_doc_token_doc' AND object_id=OBJECT_ID('dbo.doc_review_token'))
  CREATE INDEX IX_doc_token_doc ON dbo.doc_review_token(doc_id) INCLUDE(revoked, expires_at);
"@

# --- D.5 doc_attachment — uploaded rider files for a draft document (pdf/images, max 5MB each).
#     Staff upload from the editor; the CUSTOMER may upload from the tokenized review link while the doc
#     is SENT. Soft-deleted rows stay for audit. At ISSUE every live row is pushed to the ERP /file/upload. ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.doc_attachment') IS NULL
CREATE TABLE dbo.doc_attachment (
  att_id        nvarchar(36)   NOT NULL,     -- guid
  doc_id        nvarchar(36)   NOT NULL,
  file_name     nvarchar(200)  NOT NULL,
  content_type  nvarchar(100)  NOT NULL,     -- application/pdf | image/png | image/jpeg
  bytes         varbinary(max) NOT NULL,
  size_bytes    int            NOT NULL,
  uploaded_side nvarchar(8)    NOT NULL,     -- 'staff' | 'customer'
  uploaded_by   nvarchar(80)   NULL,         -- username | 'customer:<email>'
  uploaded_at   datetime2      NOT NULL,
  deleted       bit            NOT NULL DEFAULT 0,
  CONSTRAINT PK_doc_attachment PRIMARY KEY (att_id)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_doc_att_doc' AND object_id=OBJECT_ID('dbo.doc_attachment'))
  CREATE INDEX IX_doc_att_doc ON dbo.doc_attachment(doc_id) INCLUDE(deleted);
"@

# --- D.4 doc_event_log — append-only lifecycle audit (mirror of milestone_event_log) ---
ExecSql $opsDb @"
IF OBJECT_ID('dbo.doc_event_log') IS NULL
CREATE TABLE dbo.doc_event_log (
  id          bigint IDENTITY(1,1) PRIMARY KEY,
  doc_id      nvarchar(36) NOT NULL,
  version_no  int          NULL,
  event       nvarchar(20) NOT NULL,   -- created|edited|sent|viewed|submitted|approved|agreed|issued|amend_opened|token_revoked|erp_error
  actor       nvarchar(80) NULL,       -- staff username | 'customer'
  token_hash  char(64)     NULL,
  ip          nvarchar(45) NULL,
  detail      nvarchar(max) NULL,      -- JSON: {changed:[codes], comment, erp:{...}}
  occurred_at datetime2    NOT NULL
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_docevt_doc' AND object_id=OBJECT_ID('dbo.doc_event_log'))
  CREATE INDEX IX_docevt_doc ON dbo.doc_event_log(doc_id, occurred_at);
"@

Write-Host "Operational database [$opsDb] ready (15 tables + indexes):" -ForegroundColor Green
Write-Host "  milestone_baselines, shipment_alerts, milestone_def, milestone_evidence_map, detention_watch," -ForegroundColor Green
Write-Host "  milestone_event_log, company_dim, port_dim, station_dim, station_route_map, inbound_booking_feed (+feed_watermark)" -ForegroundColor Green
Write-Host "  doc_draft, doc_version, doc_review_token, doc_event_log, doc_attachment (draft document review)" -ForegroundColor Green
Write-Host "Next: map the alias/evidence fields to real ERP columns, then run listener-engine.ps1 -Mode Sea on the pilot station." -ForegroundColor Cyan
