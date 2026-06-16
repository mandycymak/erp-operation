# erp-operation — Control Tower & Operational KPI Application: Blueprint

## Context

`erp-dashboard` is a **financial/sales analytics** dashboard: a nightly job (`refresh-warehouse.ps1`)
consolidates 23 station ERP DBs into the `pgsrpt` warehouse, and a single-threaded PowerShell HttpListener
service (`serve-dashboard.ps1`) serves a vanilla-JS UI. It answers *"how much did we ship and earn"*.

The new system answers a different question — *"what must an operator do **today** to keep each live shipment
on schedule, and where is cash leaking"*. This is an **operational control tower**, not analytics.

**Key finding from code exploration that shapes the whole design:** the milestone/event fields the matrix
needs (`epdate`, `pdate`, `eta`, `etd`, ATD, `ddate`, `ad_date`, `comp_date`, `cargoready`, `cargorece`,
`declaration_flag`, `broker_name`, `trucker_name`, `wh_code`) and the log tables (PIC, `print_log`, `sendlog`,
event file, EDI log) **do not exist in `pgsrpt`** and are **not referenced anywhere** in erp-dashboard. The
warehouse carries only money/volume/geo/agent/liner. Therefore `erp-operation` **reads the source station ERP
DBs directly** (the same cross-DB pattern `refresh-warehouse.ps1` already uses), and stores its own small
operational state in a **new `erpops` database** — never altering core ERP tables.

**Decisions locked with the user:**
1. **Stack = reuse.** PowerShell HttpListener + vanilla JS, new `erpops` MSSQL DB on the same server. No build
   step; the follow-up/auth/ETL/scheduling code lifts over. ("JSONB" in the spec → MSSQL `NVARCHAR(MAX)` + `OPENJSON`.)
2. **Field mapping = config-driven + admin screen.** The milestone matrix is data (rules), shipped with the
   spec's field names as defaults; an admin screen maps real ERP columns/doc-types — so a later-created document
   type can auto-close a milestone retroactively.
3. **Listener = persist only active shipments.** Each run pulls only OPEN/active jobs into `shipment_alerts`;
   the UI reads only that small table. Closed/void jobs age out automatically.

---

## Deployment recommendation (the meta-question you asked)

- **Create `erp-operation` as a sibling project** (new folder next to `erp-dashboard`). Do **not** embed in the
  dashboard — operations has a different cadence (2h/3×day vs nightly), a different audience (operators/ops
  managers vs sales/finance), and a different data source (live ERP vs `pgsrpt`). Coupling them would drag the
  control tower into the analytics release cycle and scope model.
- **Share, don't fork, the proven primitives.** Copy the connection/retry helpers (`ConnStr` w/ `Packet Size=512`,
  `Test-Transient`, `RunQ`/`RunMulti`, `Table-Exists`/`Column-Exists` with `@(...)` guards), the
  `Send-Json`/`Send-File` `no-store` plumbing, the session/auth model, and the **entire follow-up subsystem**
  (your "Tick & Confirm" + communication requirement is already built — see §1.4).
- **`erpops` is a new DB on the same SQL Server** (`18.136.126.101,1438`, over the VPN, `Packet Size=512`).
  All new tables live here. The source station DBs stay **read-only**.
- **Close this `erp-dashboard` chat and start a fresh chat in the new `erp-operation` folder.** Reasons:
  (a) the working directory / git repo will be the new project, so tools resolve correctly; (b) a clean context
  keeps the assistant focused on operations, not analytics; (c) this blueprint file is the handoff — open the new
  chat with *"read this blueprint"*. Keep `erp-dashboard` running unchanged.

---

## 1. Close Alert — baseline storage + active tracking

Two tables in `erpops`, created with the idempotent `IF OBJECT_ID(...) IS NULL CREATE / IF COL_LENGTH(...) IS
NULL ALTER` pattern from `setup-warehouse.ps1`. **The baseline is reference-only** (the spec says "if there is
no such information is still ok") — when a lane/carrier has no baseline, the milestone falls back to its fixed
SLA rule or to *no time-gate* (status stays Green until the milestone is missed outright).

### 1.1 `milestone_baselines` — monthly historical averages

One row per **[trade lane × carrier × mode × milestone]**, recomputed monthly over the last **3 years** of
completed shipments (§3.3). The "duration" is **days from the milestone's anchor event to its completion**, so a
live shipment's expected due-date = `anchor_date + avg_days`. Percentiles let alerts use a robust window instead
of a single mean (same P50/P90 idea as the dashboard's freight P5/P95 envelope).

```sql
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
CREATE UNIQUE INDEX UX_baseline ON dbo.milestone_baselines(lane,carrier,mode,milestone_code);
```

### 1.2 `shipment_alerts` — active tracking (the lightweight UI table)

**One row per active shipment.** Denormalized scalar columns drive fast person/lane/customer filtering and the
manager rollups *without* opening the JSON; the `milestone_checklist` JSON column holds the full per-milestone
state. The UI and KPI queries read **only this table** — never the ERP, never history.

```sql
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
  milestone_checklist nvarchar(max) NULL,    -- JSON (see 1.3)
  updated_at      datetime2 NOT NULL,
  CONSTRAINT PK_shipment_alerts PRIMARY KEY (job_no)
);
CREATE INDEX IX_alerts_pic   ON dbo.shipment_alerts(pic_user)  INCLUDE(worst_light,next_due,job_status);
CREATE INDEX IX_alerts_light ON dbo.shipment_alerts(worst_light, next_due) INCLUDE(station,mode,bound);
CREATE INDEX IX_alerts_lane  ON dbo.shipment_alerts(lane, carrier);
```

### 1.3 `milestone_checklist` JSON — realistic payload (Export · Ocean · FCL)

Shows **automated** completions (with evidence), one **manual Tick & Confirm bypass** (reason + who/when + linked
note), pending milestones with traffic-light + `pct_elapsed`, and the **sequential auto-close** rule.

```json
{
  "shipment": { "job_no": "SIN-EX-2026-04412", "mode": "Sea", "bound": "Export",
                "cargo_type": "FCL", "lane": "SG-US", "carrier": "MAEU",
                "anchor": "2026-06-01", "etd": "2026-06-12", "eta": "2026-07-05", "atd": null },
  "milestones": [
    { "code":"M1","name":"Booking Confirmation","seq":1,"tracked":true,"state":"done",
      "done_by":"auto","done_at":"2026-06-02T09:14:00+08:00",
      "evidence":{"src":"erp_field","field":"house_bl_no","value":"MAEU0099112"},"light":"G" },
    { "code":"M2","name":"Empty Container Release","seq":2,"tracked":true,"state":"done",
      "done_by":"auto","done_at":"2026-06-04T11:02:00+08:00",
      "evidence":{"src":"erp_field","field":"blcont.lsono","value":"TGHU1234567"},"light":"G" },
    { "code":"M6","name":"Shipping Instructions (SI)","seq":4,"tracked":true,"state":"done",
      "done_by":"auto","done_at":"2026-06-07T16:40:00+08:00",
      "evidence":{"src":"print_log","doc":"SAMPLE_OB","ts":"2026-06-07T16:40:00+08:00"},"light":"G" },
    { "code":"M8a","name":"Customs Manifest (AMS)","seq":5,"tracked":true,"state":"bypassed",
      "done_by":"alice_op","done_at":"2026-06-09T10:00:00+08:00",
      "reason":"AMS filed via carrier portal; EDI ack not auto-captured",
      "note_id":"6f1c…","sla":{"type":"fixed","rule":"3d_before_onboard","due":"2026-06-09","breached":false},
      "light":"G" },
    { "code":"M7","name":"Manifest Printing","seq":6,"tracked":true,"state":"pending",
      "light":"A","pct_elapsed":0.82,"due":"2026-06-11" },
    { "code":"M9b","name":"Departure (ATD)","seq":7,"tracked":true,"state":"pending",
      "light":"G","pct_elapsed":0.40,"due":"2026-06-12" },
    { "code":"M10","name":"Post-Dept. Invoicing","seq":8,"tracked":true,"state":"pending",
      "light":"G","sla":{"type":"fixed","rule":"sea_1-3d_after_atd"} },
    { "code":"M11","name":"Post-Dept. Monitor (Delivery)","seq":9,"tracked":true,"state":"pending","light":"G" }
  ],
  "auto_close": { "rule":"sequential_anchor",
                  "note":"when ATD populated -> M1..M6 force-closed if still open; when delivery/comp_date set -> customs+pre-delivery force-closed" },
  "rollup": { "worst_light":"A","open_amber":1,"open_red":0,"next_due":"2026-06-11","automation":{"auto":3,"manual":1} }
}
```

### 1.4 Sequential auto-close (the "passed-ETD closes everything before it" rule)

Each milestone def carries a `seq` and a `phase_anchor` (`booking`/`etd`/`atd`/`eta`/`delivery`). After
evaluating completions, the listener applies **implied closure**:

- If a **later** anchor event has occurred, every **earlier** sequential milestone still `pending` is set to
  `state:"auto_closed"`, `done_by:"system_seq"`, with `evidence:{src:"implied", by:"<anchor>"}`.
- Concrete rules (config, editable):
  - `atd` populated → close `M1,M1b,M2,M3,M4,M5,M6,M7,M8a/b,M9` (all pre-departure).
  - delivery done (`ad_date`/`comp_date`) → close import `M2..M7` and export `M11` predecessors (e.g. customs clearance must have happened if it's delivered).
  - This prevents stale Reds on shipments that simply moved past a step the system didn't capture — directly
    serving your "system may miss a status but it isn't important / wasn't updated yet" concern.
- Auto-closed ≠ manual bypass: it does **not** count toward the automation-score manual tally, and is visually
  distinct (greyed ✓) so operators know it was inferred, not evidenced.

---

## 2. Automated Milestone Matrix — config-driven + admin screen

### 2.1 Why config, not hardcoded SQL

The matrix becomes **data**: a `milestone_def` row per milestone holds a **qualification rule** ("track this?")
and a **completion rule** ("done?"), each a small JSON expression over named *sources*. The listener has a
generic evaluator; the admin screen edits rules. This delivers your requirement that *"if a user later creates a
specific document type, the case can auto-close"* — they just add an evidence mapping, no code change, and the
next listener pass closes it.

```sql
IF OBJECT_ID('dbo.milestone_def') IS NULL
CREATE TABLE dbo.milestone_def (
  milestone_code  nvarchar(12) NOT NULL,
  bound           nvarchar(8)  NOT NULL,   -- 'Export'|'Import'|'Both'
  name            nvarchar(60) NOT NULL,
  seq             int          NOT NULL,
  phase_anchor    nvarchar(12) NOT NULL,   -- booking|etd|atd|eta|delivery
  qualify_rule    nvarchar(max) NOT NULL,  -- JSON (see 2.2)
  complete_rule   nvarchar(max) NOT NULL,  -- JSON (see 2.2)
  sla_type        nvarchar(12) NOT NULL,   -- 'baseline'|'fixed'|'none'
  sla_offset_val  int NULL,                -- e.g. 3
  sla_offset_unit nvarchar(6) NULL,        -- 'day'|'hour'
  sla_direction   nvarchar(8) NULL,        -- 'before'|'after'
  sla_anchor      nvarchar(12) NULL,       -- 'onboard'|'flight_dep'|'atd'|'ata'
  active          bit NOT NULL DEFAULT 1,
  CONSTRAINT PK_milestone_def PRIMARY KEY (milestone_code, bound)
);

-- Configurable evidence: a doc-type / log entry that satisfies a milestone.
-- Admin adds rows here so a *new* document type auto-closes a milestone retroactively.
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
```

### 2.2 Rule expression format (evaluated by the listener)

A rule is `{ "op":"AND|OR", "conds":[ <cond>, ... ] }` where each `<cond>` is one of:

| `kind` | Meaning | Example |
|---|---|---|
| `field_notnull` | ERP column is populated | `{kind:"field_notnull", field:"house_bl_no"}` |
| `field_eq` | ERP column equals value | `{kind:"field_eq", field:"frttype", value:"CY"}` |
| `field_in` | ERP column in set | `{kind:"field_in", field:"incoterm", set:["EXW","FCA"]}` |
| `evidence` | a row in `milestone_evidence_map` is satisfied (doc-type / print / send / EDI) | `{kind:"evidence"}` |
| `date_passed` | an anchor date is in the past | `{kind:"date_passed", field:"etd"}` |
| `mode_eq` | shipment mode | `{kind:"mode_eq", value:"Sea"}` |

The evaluator resolves each `field` through an **alias map** (config) → the real ERP column, so unknown real
names never block the design. Pseudo-code:

```
qualifies(ship, def)  = eval(def.qualify_rule, ship)         // "track this milestone?"
completed(ship, def)  = eval(def.complete_rule, ship)        // "auto-done?"
            || anyEvidence(ship, def)                        // doc-type/print/send/EDI rows
            || impliedBySequence(ship, def)                  // §1.4
light(ship, def, base) = G if completed
                         else dueWindow(ship, def, base) -> {G/A/R by pct elapsed & SLA}
```

### 2.3 The matrix translated to rules

Each cell below is a `milestone_def` seed. `qualify` = qualification rule; `complete` = completion rule (OR-ed
with any matching `milestone_evidence_map` rows). Field names are the **defaults**; the admin remaps to real ERP
columns. Items marked **⚠ not in dashboard** confirm the field must be sourced live from the station ERP (verify
the real column when wiring the alias map).

**EXPORT**

| Code | qualify | complete (default rule) | SLA |
|---|---|---|---|
| M1 Booking Conf. | always | `house_bl_no NOTNULL OR pic_user NOTNULL` | baseline |
| M1b Space Confirmed | always (booking phase) | empty-container-release status changed (evidence) | baseline |
| M2 Empty Container Release | `mode=Sea AND cargo_type=FCL` | `blcont.lsono NOTNULL OR container_no NOTNULL` ⚠`lsono` | baseline |
| M3 Origin Pickup | `incoterm IN(EXW,FCA) OR epdate NOTNULL` ⚠`epdate` | `pdate NOTNULL` ⚠`pdate` | baseline |
| M4 Warehouse Receiving | `cargo_type=LCL OR mode=Air Consol` | `cargoready NOTNULL AND cargorece NOTNULL` ⚠both | baseline |
| M5 Customs Clearance | `declaration_flag=TRUE` ⚠ | evidence: `pic_doctype='Customs' OR status_eq='RCL'` | baseline |
| M6 Shipping Instructions | `mode=Sea` | `master_bl_no NOTNULL OR print_log doc='SAMPLE_OB'` ⚠`print_log` | baseline |
| M7 Manifest Printing | always | evidence: `print_log 'Print Manifest' OR pdf ts` ⚠ | baseline |
| M8a Customs Manifest (AMS/ENS) | `mode=Sea AND dest_country IN(US,CA,EU)` | evidence: `edi_log success` ⚠ | **fixed: 3 day before onboard** |
| M8b E-AWB (FWB) | `mode=Air` | evidence: `edi_log success` ⚠ | **fixed: 3 hour before flight_dep** |
| M9 Agent EDI | `agent.edi_required=TRUE` ⚠ | evidence: `edi_log success` ⚠ | baseline |
| M9b Departure (ATD) | always | `actual_departure_date NOTNULL` ⚠ATD | baseline |
| M10 Post-Dept. Invoicing | always | invoice posted for job (evidence/`print_invoice`) | **fixed: Air same/next-day ATD; Sea 1–3 day ATD** |
| M11 Post-Dept. Monitor | `eddate NOTNULL` ⚠ | `ddate NOTNULL OR comp_date NOTNULL` ⚠both | baseline |

**IMPORT**

| Code | qualify | complete (default rule) | SLA |
|---|---|---|---|
| M1 Factory Booking Alert | always (origin) | origin links Buyer PO to active booking no. (evidence) | baseline |
| M2 Transit Check | always | **negative check:** `now>eta AND no arrival-notice log` → force Amber/Red ⚠ | n/a (continuous) |
| M3 Import Documentation | always | `hbl_status IN('Surrendered','Telex Released') OR sendlog has import job no.` ⚠ | baseline |
| M4 Arrival Notice | tracked 3 day before ETA | evidence: `print_log 'Arrival Notice'` ⚠ | **fixed: 3 day before ETA** |
| M4b Invoice from Liner | always | evidence: `print_log 'Payment Request'` ⚠ | baseline |
| M5 Import Customs | `broker_name NOTNULL` ⚠ | `status IN('Cleared','Released') OR not2_add1 NOTNULL` ⚠ | baseline |
| M6 Port/Airport Pickup | `trucker_name NOTNULL` ⚠ | container status `Gate Out`(sea)/`Picked Up`(air) ⚠ | baseline |
| M7 Warehouse Service | `wh_code NOTNULL` ⚠ | `ad_date NOTNULL` ⚠ | baseline |
| M8 Final Delivery | `pd_date NOTNULL` ⚠ | `ad_date NOTNULL OR comp_date NOTNULL` ⚠ | baseline |
| M9 Invoice to Buyer | always | `print_invoice ts logged` ⚠ | **fixed: 3 day after arrival** |

### 2.4 Traffic-light evaluation (Green / Amber / Red)

For each *tracked, not-completed* milestone with a due window (`due` = baseline `anchor+p90_days`, or the fixed
SLA date):

```
pct = (now - anchor) / (due - anchor)
trigger_empty = NOT completed(ship, def)
Green : completed OR pct < 0.70
Amber : 0.70 <= pct <= 0.90 AND trigger_empty      -> operator daily worklist
Red   : pct > 0.90 (or due missed / SLA breached)  AND trigger_empty -> management dashboard
```

Red is cleared by (a) the listener detecting completion, or (b) a manual **Tick & Confirm** bypass that writes
`state:"bypassed"` + `reason` + `done_by`/`done_at` and **links a note** (§ reuse follow-ups). Continuous
checks (Import M2) compute Amber/Red directly from `now vs eta` with no baseline.

### 2.5 Admin screen

A new `admin-ops.html` (mirror of `admin.html`, gated by `admin:true`) with three editors, all backed by
`/api-ops/admin/*` write-then-reload endpoints + an `ops-audit.log` append (exact `Handle-Admin`/`Save-*`
pattern):
1. **Milestone defs** — edit qualify/complete rules (a small condition-builder UI emitting the §2.2 JSON), SLA
   type/offset, seq, active.
2. **Evidence map** — map a doc-type / print-log / send-log / EDI value (and the real ERP table+column) to a
   milestone. *This is the "add a doc type so it auto-closes later" control.*
3. **Field alias map** — map each logical field (`epdate`, `atd`, `hbl_status`, …) to the real ERP table.column
   for each station (handles per-ERP schema drift, like `Agent-Col`'s `agn2_code`/`agen2_code` auto-detect).

### 2.6 Sea-Freight FCL Detention & Demurrage — special post-delivery listing

Detention (Sent-To-Consignee) and Empty-Return happen **after** delivery, so they sit outside the normal
milestone chain. Track them per **destination port**, alert **both origin and destination office**, and compute
**days-due** against the terminal/carrier free-time.

```sql
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
-- supporting config (admin-editable): free_time_config(dest_port, carrier, kind, free_days, daily_rate)
```

The listener creates DET/DEM rows for every Sea FCL shipment once delivery is reached, computes `days_over`
daily, and surfaces a dedicated **"Detention & Demurrage"** listing grouped by destination port (and mirrored to
the origin office via `origin_station`). Free-days/rates are config so the alert reflects each terminal/carrier.

---

## 3. Background Script Blueprint — the Listener Engine

### 3.1 `listener-engine.ps1 -Mode <Sea|Air>`

One parameterized script, two cadences. Reuses `ConnStr`(`Packet Size=512`), `Test-Transient` retry,
`Table/Column-Exists` `@(...)` guards from `refresh-warehouse.ps1`. Per run:

```
1. SELECT-active   : pull only OPEN/active jobs from the station ERP DBs for $Mode,
                     within a recent window (e.g. anchor_date >= today-120d) and NOT void/closed.
                     Delta-first: prefer rows whose ERP updated_at > last successful run watermark.
2. Load-config     : milestone_def + evidence_map + alias_map + baselines into memory once.
3. Per shipment    : for each def -> qualifies? completed?(field/evidence/implied) -> light/due.
4. Sequential close: apply §1.4 implied closure.
5. Det/Dem         : (Sea only) maintain detention_watch for delivered FCL.
6. Upsert          : MERGE into shipment_alerts (scalar rollups + milestone_checklist JSON);
                     append state CHANGES to milestone_event_log (§4).
7. Age-out         : mark/delete shipment_alerts rows now closed/void.
```

**Lightweight guarantees:** never scans `fact_job`/history; only active jobs enter `shipment_alerts`; the UI
reads only `shipment_alerts`/`detention_watch`. Evidence lookups (PIC/print/send/EDI) are filtered IN-list reads
keyed by the active job set (same "filtered read, no scan" rule as the dashboard's `/owners`).

### 3.2 Scheduling — `register-ops-tasks.ps1`

Extends `register-nightly-task.ps1`'s Task Scheduler pattern (Windows Task Scheduler; the SQL host has no Agent):

- **Air — every 2 hours:** `-Once -At 06:00 -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration (New-TimeSpan -Days 3650)` running `listener-engine.ps1 -Mode Air`. `ExecutionTimeLimit` ~30 min.
- **Sea — 3× daily:** three triggers (or one task with three `-At` triggers) at **07:00 / 13:00 / 19:00** running `-Mode Sea`.
- **Baseline — monthly:** `-Monthly` (1st, 03:00) running `baseline-refresh.ps1` (§3.3).
- All tasks `-StartWhenAvailable` so a missed run (laptop asleep / VPN down) fires on resume; each writes a
  one-line run log + watermark.

### 3.3 `baseline-refresh.ps1` — monthly 3-year averages

A `TRUNCATE + INSERT…SELECT` rebuild of `milestone_baselines` (the same materialize pattern as the dashboard's
`summary_*`/`kpi_landing` builds), over completed shipments in the last 3 years, grouped by
`[lane × carrier × mode × milestone]`, using `AVG`/`PERCENTILE_CONT(0.5|0.9)` on `DATEDIFF(day, anchor, completion)`.
Carrier rolls up to `'*'` as a fallback row when a specific carrier has `sample_size` below a threshold (so thin
lanes still get a baseline). Reconcile against a direct SQL spot-check before trusting (house rule).

---

## 4. Manager Analytics, KPI logic & the person-focused worklist

### 4.1 Event log (powers the KPIs cheaply)

Append-only, written by the listener on every state transition — small, indexed, never scanned wholesale:

```sql
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
CREATE INDEX IX_evt_pic_time ON dbo.milestone_event_log(pic_user, occurred_at) INCLUDE(to_state,from_light,to_light,done_by);
```

### 4.2 The three management metrics

**(1) Automation Score** — auto vs manual completions:
```sql
SELECT pic_user,
  SUM(CASE WHEN done_by='auto' THEN 1 ELSE 0 END)                      AS auto_done,
  SUM(CASE WHEN done_by NOT IN ('auto','system_seq') AND to_state='bypassed' THEN 1 ELSE 0 END) AS manual_bypass,
  1.0*SUM(CASE WHEN done_by='auto' THEN 1 ELSE 0 END)
      / NULLIF(SUM(CASE WHEN to_state IN ('done','bypassed') THEN 1 ELSE 0 END),0) AS automation_score
FROM dbo.milestone_event_log
WHERE occurred_at >= @from GROUP BY pic_user;   -- high = trusting automation; low = heavy manual override
```

**(2) Cash-Flow Leakage Monitor** — invoicing deadline breached vs ATD/ATA. Reads only `shipment_alerts`
(no scan): export **M10**, import **M9**, where ATD/ATA is set, the invoice milestone is still open, and the
SLA window has passed:
```sql
SELECT job_no, station, mode, bound, cust_code, salesman, pic_user,
       COALESCE(atd,ata) AS dep_arr_date,
       DATEDIFF(day, COALESCE(atd,ata), CAST(SYSDATETIME() AS date)) AS days_overdue
FROM dbo.shipment_alerts
WHERE job_status='active'
  AND ( (bound='Export' AND JSON_VALUE(milestone_checklist,'$.milestones[?(@.code=="M10")].state')<>'done'
         AND atd IS NOT NULL AND DATEDIFF(day, atd, SYSDATETIME()) > CASE WHEN mode='Air' THEN 1 ELSE 3 END)
     OR (bound='Import' AND ata IS NOT NULL AND DATEDIFF(day, ata, SYSDATETIME()) > 3
         /* M9 invoice not printed */) )
ORDER BY days_overdue DESC;
```
(JSON path filters are illustrative; in practice the listener also lifts an `invoice_state` scalar onto the row
so this query needs no `OPENJSON`.) Output = a leakage list with **days overdue** and **revenue at risk**
(join the dashboard's `pgsrpt.fact_job` revenue read-only, or carry `revenue` onto the alert row).

**(3) Operator SLA Adherence** — % of Amber tasks cleared **before** they hit Red:
```sql
WITH amber AS (   -- every time a milestone entered Amber
  SELECT job_no, milestone_code, pic_user, occurred_at AS amber_at
  FROM dbo.milestone_event_log WHERE to_light='A'),
fate AS (         -- did the NEXT transition resolve (done/bypassed) or escalate to Red?
  SELECT a.*, x.to_light AS next_light, x.to_state AS next_state
  FROM amber a CROSS APPLY (
     SELECT TOP 1 to_light, to_state FROM dbo.milestone_event_log e
     WHERE e.job_no=a.job_no AND e.milestone_code=a.milestone_code AND e.occurred_at>a.amber_at
     ORDER BY e.occurred_at) x)
SELECT pic_user,
  1.0*SUM(CASE WHEN next_state IN ('done','bypassed') AND ISNULL(next_light,'')<>'R' THEN 1 ELSE 0 END)
      / NULLIF(COUNT(*),0) AS sla_adherence
FROM fate WHERE amber_at >= @from GROUP BY pic_user;
```

### 4.3 Person-focused worklist (the daily/weekly UX — the heart of the app)

**Default lens = "my work":** `shipment_alerts WHERE pic_user=@me OR created_by=@me OR last_updated_by=@me`,
`job_status='active'` only (void/closed excluded by design). Then switchable lenses (reuse the dashboard scope
idea): **teammate** (pick from the user roster), **trade lane**, **customer**, **agent**. All read only the
small `shipment_alerts` table — fast, no ERP hit.

**ToDo categorization** (computed from `next_due` / `worst_light`):
- **🔴 Today / Critical** — `worst_light='R'` or `next_due <= today`. Sorted by overdue-most-first.
- **🟠 This Week** — `worst_light='A'` or `next_due within 7 days`, with a **weekend-console emphasis**: flag
  shipments whose ETD is the coming Sat/Sun and surface them hardest on **Tue & Thu** (the confirm-for-departure
  days you described) — a small `weekday`-aware sort weight, configurable.
- **🗂 Long-Outstanding bucket** — items open well past their window (e.g. Red > N days) that the operator can
  clear when free; these are the "system may have missed a status / not important" cases. Each is one-click
  **Tick & Confirm** (bypass with reason) — clears it off the live list while logging why.

**Manager weekly plan view:** group active shipments by **ETD week** → counts of files to prepare, status mix
(G/A/R), and **per-operator load** (`GROUP BY pic_user`) so the manager can **reassign** (an admin action that
sets `pic_user` on the alert row + logs it). All from `shipment_alerts` aggregates — no scan.

### 4.4 Tick & Confirm + communication = reuse the follow-up subsystem

Your spec explicitly points at the Company-Profile follow-up function — it is a near-exact fit and is already
built. Lift it wholesale, keyed by `job_no` instead of company code:

- **Store:** `ops-lists/job-notes.json` (shared, UTF8-no-BOM, read-modify-write on the single-threaded server) —
  same record shape: `{ id, created, user, job_no, note, mentions[], status, doneBy, doneAt }`.
- **Manual bypass = a note with a reason** + sets the milestone `state:"bypassed"` and stamps `done_by/done_at`
  (exactly `Save-FollowupDone`'s `doneBy/doneAt` mechanic).
- **Communicate with the user:** `@`-mention autocomplete off a SQL-free `/api-ops/roster`
  (`Handle-Roster` verbatim); a **"My Tasks" inbox** (`Handle-MyFollowups` pattern: *assigned-to-me* = notes
  others tagged me on, *raised-by-me* = waiting on others) + the **nav count badge**; the **✉ mailto** icon
  defaults `To:` to mentioned users' emails for people not on the system. The mentioned user "sees the task" via
  the inbox + badge — exactly the collaboration loop you asked for.

---

## Files to create (all new, in `erp-operation/`)

| File | Role | Reuses from erp-dashboard |
|---|---|---|
| `setup-ops.ps1` | Create `erpops` schema (the 6 tables above) idempotently | `setup-warehouse.ps1` guard idiom |
| `listener-engine.ps1` | The `-Mode Sea\|Air` listener (§3.1) | `ConnStr`/`Test-Transient`/`Table-Column-Exists` from `refresh-warehouse.ps1` |
| `baseline-refresh.ps1` | Monthly 3-yr baselines (§3.3) | `summary_*` materialize pattern |
| `register-ops-tasks.ps1` | Schedule Air-2h / Sea-3×day / baseline-monthly | `register-nightly-task.ps1` |
| `serve-ops.ps1` | HttpListener API: worklist, alerts, KPIs, notes/roster/my-tasks, admin | `serve-dashboard.ps1` (Send-Json/File, sessions, Handle-Roster/Followup*/Admin) |
| `index.html` / `ops.js` / `styles.css` | Vanilla-JS UI: worklist, manager plan, det/dem, my-tasks | `app.js` (`arr()`/`arrFields()`, mention popup, `wireFollowupDone`, badge) |
| `admin-ops.html` | Milestone-def / evidence-map / alias-map editors (§2.5) | `admin.html` |
| `ops.config.json` (gitignored) | server/auth/`erpops` name/station list (env `DB_*` override) | `warehouse.config.json` + `EnvOrConfig` |
| `users.json`/`roles.json` | auth/scope (can share the dashboard's) | as-is |

## Verification (when built)

1. **Schema:** run `setup-ops.ps1` against a temp DB; confirm all 6 tables + indexes via
   `INFORMATION_SCHEMA`. Re-run to prove idempotency (no errors, no dupes).
2. **Field alias map first:** with the user, map each ⚠ logical field to the real ERP `table.column` for one
   pilot station; spot-check 5 live shipments by direct SQL.
3. **Listener correctness:** run `listener-engine.ps1 -Mode Sea` on a temp port/DB for the pilot station; pick
   3 known shipments (one mid-flight, one departed, one delivered) and **reconcile the computed lights &
   auto-closes against a hand SQL query** of the source ERP (house rule).
4. **Lightweight proof:** confirm the worklist endpoint touches only `shipment_alerts` (no ERP connection in the
   request path) and returns sub-second; confirm closed/void jobs age out after a run.
5. **KPIs:** seed a few `milestone_event_log` transitions; verify Automation Score, Leakage list, and SLA
   Adherence against hand counts.
6. **Tick & Confirm loop:** bypass a Red with a reason + `@`-mention; confirm the note persists, the mentioned
   user's inbox badge increments, and the milestone shows `bypassed` with `done_by/done_at`.

## Open items / to confirm during build
- Real ERP table/column names for every ⚠ field, and where the **PIC table / print_log / sendlog / EDI log /
  event file** actually live (drives the alias + evidence maps).
- The stable `job_no` key across stations (the dashboard notes switch-bill shipments have **no shared key**
  across station DBs — operations tracking is per-station-leg, same limitation).
- Free-time days & daily rates per destination port × carrier for detention/demurrage.
- Whether `erp-operation` shares the dashboard's `users.json`/`roles.json` or maintains its own.
