# pgs-operation — Project Summary

Status snapshot of the Control Tower build. The authoritative design is **`BLUEPRINT.md`**; this file records
**what is actually built and proven** against real ERP data, plus the findings that shaped it. Read this first
when resuming. Operator-memory notes also live under `.claude/projects/.../memory/` (local + network DB setup).

## Status: working app — arrival-driven worklist, arrangements/reminders, Sea **and** Air

A clickable, end-to-end worklist app runs against real data on two test environments. The scheduled
`listener-engine.ps1` is still **deferred** — `seed-alerts.ps1` stands in for it (one-shot batch evaluator/upsert)
so the UI and Tick-&-Confirm loop can be exercised now.

```
station ERP DBs (READ-ONLY)                                  pgsops (operational state, writable)
  Sea: blhead / blcont / PIC      --- ops-eval.ps1 ------>    shipment_alerts, milestone_def (mode Sea|Air),
  Air: awbhead                       (mode-aware evaluator)   milestone_evidence_map, …
        |  (seed-alerts.ps1 -Mode Sea|Air = listener stand-in)        |  serve-ops.ps1 (HttpListener + JSON API)
        |                                                             v
        '------- READ ONLY, never written -------          browser (index.html / ops.js)  — reads only pgsops
```

**Two-server mode (added):** the read-only ERP and the writable `pgsops` may live on **different** servers.
Config gains optional `opsServer`/`opsAuth`/`opsUser`/`opsPassword` (fall back to the source connection when
absent — single-server configs unchanged). All scripts route `master`+ops-DB to the ops server, everything else
to the source. Used so the network ERP (read-only login) is read remotely while `pgsops` is created locally.

## Two test environments

| Env | Source ERP | Data | opsDb | Port | Notes |
|---|---|---|---|---|---|
| **Local** | `fibsbkk` on `localhost\SQLEXPRESS` (Win auth) | **frozen 2021** snapshot; as-of `2021-11-27` | `pgsops` (local) | 8078 | Only `fibsbkk` has the real 381-col schema; `fibsdemo_*` are stripped. Sea/BKK. Milestone fields empty → all-Red. |
| **Network** | `fm3khkg` on `192.168.5.2` (SQL login `dashboard`, read-only) | **LIVE to today**; as-of = today | `pgsops_net` (local, two-server) | 8079 | 420-col schema, operational fields populated → realistic light mix. Sister stations `fm3k*` exist for multi-station. Login can't `CREATE DATABASE` → two-server mode. |

Configs are gitignored: `ops.config.json` (local), `ops.config.network.json` (network), `.env.txt` (creds the
user pasted). Only `*.example.json` is tracked.

## Key findings (these shaped the build)

1. **Snapshot vs live.** `fibsbkk` is a frozen 2021 copy with empty operational fields (worklist skews Red);
   `fm3khkg` is live with fields populated (realistic Green/Amber/Red). Same code, different data maturity.
2. **Milestone completion resolves in priority order** (sparse data handled by design, not a blocker):
   **(1) ERP data** (`complete_rule` over real columns; qualification is data-driven) → **(2) PIC/EDI evidence**
   (configured `documentTypeCode`) → **(3) planned due-window** (baseline or fixed offset) → **(4) manual Tick &
   Confirm** (operator closes even with no data; un-tickable).
3. **Air freight is a separate table.** Sea = `blhead` (+`blcont` containers); Air = **`awbhead`** (465 cols).
   Air operator-shipments = `awb_type IN('H','S')` (H=house, S=direct; M=consol master & B=booking pipeline
   excluded). `carr` (carrier code) is empty in both → use vessel/voyage (sea) and airline+`flight1` (air).
4. **Carrier code & ETA are sparse/empty** in these copies; consignee/shipper **names** are ~100%. Container data
   (`blcont`) is rich for sea FCL; air uses pieces/weight (`t_book_qty`/`t_book_wgt`).
5. **Cross-station factory-booking** (advice, not yet built): at booking time there's no HBL/MBL, only the
   destination **station/site code** stamped on the origin's booking (`dest`/`agn2_code`). The plan: each origin
   publishes its outbound bookings into a shared `pgsops` feed keyed by destination code; the import station reads
   only `pgsops` (no cross-DB query on the request path). Needs a station-code identity directory.

## What's built

| File | Role | State |
|---|---|---|
| `setup-ops.ps1` | Creates `pgsops` + 6 tables; in-place ALTERs add the worklist enrichment columns (consignee/shipper name+contact, vessel_voyage, container_summary/count, total_weight/cbm, arrival_state, sort_key) and `milestone_def.mode` | ✅ idempotent, two-server |
| `seed-milestone-config.ps1` | Config-as-data: **37** `milestone_def` rows — Sea (23, Export+Import) + **Air (14)** with `mode` — + starter evidence map | ✅ |
| `ops-eval.ps1` | Pure evaluator: `New-ShipContext` (sea) + **`New-AirContext`** (air); `Eval-Milestones` filters defs by bound **and mode**; planned-due anchor is mode-aware | ✅ |
| `eval-shipment.ps1` | Read-only one-shot card for one shipment (two-server aware) | ✅ |
| `seed-alerts.ps1` | Listener stand-in. **`-Mode Sea|Air`**: reads `blhead`/`blcont` or `awbhead`, batches PIC + consignee/shipper contacts, computes arrival bucket + cargo profile + conveyance, upserts `shipment_alerts` | ✅ |
| `serve-ops.ps1` | Web service: worklist (arrival-grouped), shipment detail, notes/arrangements/reminders, **enriched My-Tasks**, manual milestone-close. Reads only `pgsops` | ✅ |
| `index.html`/`ops.js`/`styles.css` | UI: 🚢Sea/✈Air toggle, Import/Export toggle, **vessel/flight-grouped** collapsible worklist, mini-cards, shipment drawer w/ milestones + **🔔 Remind-me** + **Arrangements** panel, custom in-page dialogs (no native `prompt`), My-Tasks | ✅ |
| `ops.config.example.json` | Config template | ✅ |

**Not yet built:** real `listener-engine.ps1`, `baseline-refresh.ps1`, `register-ops-tasks.ps1`, `admin-ops.html`,
real auth (runs open/demo mode), the cross-station booking feed (§key finding 5), and `pic_user`↔app-user mapping.

## Proven behaviour (tested live)

- **Worklist is arrival-driven, grouped by vessel/voyage (sea) or airline+flight (air)** — not one card per
  shipment. Import buckets: **Arrived / Arriving / Planning**; Export: **No-space / Customs-window / Cargo-pending
  / On-track**. Each conveyance gets ONE derived status (a vessel isn't split across buckets). Collapsible groups +
  collapse-all. Sorted ETA-first, falling back to time-in-transit.
- **Richer cards:** consignee/shipper name, cargo profile (FCL `2×40HC`; LCL weight+CBM; **air `N pcs · kg`**),
  conveyance, arrival chip, R/A severity, notes flag.
- **Arrangements panel** (per shipment): who-to-contact (consignee/shipper + `tel:`/`mailto:` from the ERP views),
  and operator-recorded Trucker/Broker/Warehouse/Customer tasks with status — stored in the JSON note store as
  `kind='arrangement'` (no ERP write).
- **My-Tasks reworked:** "Reminders from others" (@-mentions) + "My follow-ups" (notes/reminders you raised);
  excludes completion records; cards enriched with consignee + shipment info; **🔔 Remind-me with a due date**
  (overdue/today highlighted, badge counts them); compact cards (click to open, ✓ to clear).
- **Manual Tick & Confirm** flips the rollup, threads a note, is un-tickable. Custom themed dialog (no
  "localhost says" browser prompt).
- **Air & Sea both seed and render**; cross-mode `job_no` distinct (air `AEHKG`/`AIHKG`, sea `SEHKG`/`SIHKG`).

## How to run

```powershell
# --- LOCAL (frozen 2021 snapshot, BKK, sea) ---
.\setup-ops.ps1                                                            # create pgsops (idempotent)
.\seed-milestone-config.ps1
.\seed-alerts.ps1 -Station fibsbkk -StationCode BKK -AsOf 2021-11-27 -Limit 120
.\serve-ops.ps1                                                            # http://localhost:8078/

# --- NETWORK (live fm3khkg, two-server: read network ERP, write local pgsops_net) ---
.\setup-ops.ps1            -ConfigPath .\ops.config.network.json
.\seed-milestone-config.ps1 -ConfigPath .\ops.config.network.json
$today = (Get-Date).ToString('yyyy-MM-dd')
.\seed-alerts.ps1 -ConfigPath .\ops.config.network.json -Station fm3khkg -StationCode HK01 -Mode Sea -AsOf $today -Limit 120
.\seed-alerts.ps1 -ConfigPath .\ops.config.network.json -Station fm3khkg -StationCode HK01 -Mode Air -AsOf $today -Limit 120
.\serve-ops.ps1            -ConfigPath .\ops.config.network.json -Port 8079   # http://localhost:8079/
# In the UI: pick the All lens (or an operator), toggle 🚢Sea/✈Air and Import/Export.
```

## Constraints (do not violate)

- **`Packet Size=512`** on every SQL connection string (VPN MTU).
- HttpListener server is **single-threaded**; UI/request paths read only the small `pgsops` tables, never the ERP.
  All heavy ERP joins (containers, contacts) happen in `seed-alerts` off the request path.
- **Source ERP DBs are READ-ONLY** — all writes go to `pgsops`/`pgsops_net` or the gitignored JSON note store.
- **Secrets gitignored** (`ops.config.json`, `ops.config.*.json`, `.env*`, `users.json`, `roles.json`,
  `ops-lists/`, `*.log`); verify with `git status` before any commit. Only `*.example.json` is tracked.
- PS 5.1 traps: coerce `$null`→`[DBNull]::Value` for SQL params; serialize JSON-store records individually (never
  hand `ConvertTo-Json` a whole array). Client coerces 0/1-row arrays via `arr()`; responses are `no-store`.
- Verify any computed light/KPI against a direct read-only SQL query of the source ERP before declaring done.
