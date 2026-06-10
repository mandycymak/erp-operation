# CLAUDE.md — project context for Claude Code (pgs-operation)

Read this first, then read **`BLUEPRINT.md`** — that is the authoritative, approved design for this entire
project. This file gives you the hard constraints and the orientation; `BLUEPRINT.md` gives you the what and the
how, section by section.

## Status: greenfield

**No code exists yet.** This repo currently contains only documentation. Every `.ps1` / `.js` / `.html` file
named below is *to be built*, following `BLUEPRINT.md`. Do not assume any handler, table, or endpoint exists
until you've created it. Build in the order in §"First build steps" below.

## What this is

`pgs-operation` is a lightweight, event-driven **Control Tower & Operational KPI application** for a freight
forwarding ERP group. It answers *"what must an operator do **today** to keep each live shipment on schedule,
and where is cash leaking"* — an **operational** tool, distinct from its sibling `pgs-dashboard` (financial /
sales **analytics**).

It does **not** alter the core ERP. A background "listener" reads the **read-only** source station ERP databases
directly (the same cross-DB way `..\pgs-dashboard\refresh-warehouse.ps1` does), evaluates a configurable
**milestone matrix** into traffic-light status, and stores only **active** shipments in a new **`pgsops`** MSSQL
database. The UI reads only that small operational state — never the ERP, never history.

```
station ERP DBs (READ-ONLY)  --listener-engine.ps1 (Air 2h / Sea 3x day)-->  pgsops
                                                                                  |  serve-ops.ps1 (HttpListener + JSON API)
                                                                                  v
                                                                              browser (index.html / ops.js)
   baseline-refresh.ps1 (monthly, 3-yr averages) --> pgsops.milestone_baselines (reference only)
```

**Stack** (deliberately identical to pgs-dashboard so patterns lift over): PowerShell 5.1 + .NET
SqlClient/HttpListener (server) · vanilla JS (client, no build step / no framework / no package manager) · SQL
Server (`18.136.126.101,1438`, reached over the Swivel VPN). "JSONB" in the original spec → MSSQL
`NVARCHAR(MAX)` + `OPENJSON`.

## Planned repo map (build per BLUEPRINT.md)

- `setup-ops.ps1` — create the `pgsops` schema (6 tables) idempotently. **Build first.**
- `listener-engine.ps1 -Mode <Sea|Air>` — the listener; pulls active jobs, evaluates milestones, upserts `shipment_alerts`, appends `milestone_event_log`.
- `baseline-refresh.ps1` — monthly rebuild of `milestone_baselines` over 3 years.
- `register-ops-tasks.ps1` — schedule Air-2h / Sea-3×day / baseline-monthly (Windows Task Scheduler).
- `seed-station-map.ps1` / `publish-bookings.ps1` — **cross-station inbound booking feed** (key finding 5): the
  station identity directory (`station_dim`/`station_route_map`) + the per-origin publisher that fans booking
  rows (destined to another station) into the central `inbound_booking_feed`. The importer reads only its own
  rows (`dest_station=stationCode`); served by `/api-ops/inbound` + `/api-ops/inbound-assign` (local assignment).
- `serve-ops.ps1` — the web service: auth, JSON API (worklist, alerts, KPIs, notes/roster/my-tasks, admin), static files.
- `index.html` / `ops.js` / `styles.css` — the UI (worklist, manager weekly plan, detention/demurrage listing, my-tasks inbox).
- `admin-ops.html` — admin-only milestone-def / evidence-map / field-alias-map editors.
- `ops.config.json` (gitignored) — server/auth/`pgsops` name/station list; copy from `ops.config.example.json`; env `DB_*` override.
- `users.json` / `roles.json` (gitignored) — auth + row-level scope; may be shared/copied from pgs-dashboard.

## Reuse, don't reinvent (sibling: `..\pgs-dashboard`)

These are proven and lift over almost verbatim — read them in `..\pgs-dashboard` before writing the equivalent:
- **Connection + retry:** `ConnStr` (with `Packet Size=512`), `Test-Transient`, `ExecSql` retry loop, `RunQ`/`RunMulti` (`CommandTimeout=45`, optional `$timeoutSec`), `Table-Exists`/`Column-Exists` with `@(...)` guards — all in `refresh-warehouse.ps1` / `serve-dashboard.ps1`.
- **Idempotent schema:** the `IF OBJECT_ID(...) IS NULL CREATE` / `IF COL_LENGTH(...) IS NULL ALTER` idiom in `setup-warehouse.ps1`.
- **Materialize pattern:** `TRUNCATE + INSERT…SELECT` summary builds (model for `baseline-refresh.ps1`).
- **Scheduling:** `register-nightly-task.ps1` (extend its trigger for 2h / 3×day / monthly).
- **Web plumbing:** `Send-Json`/`Send-File` with `no-store` headers; sessions/auth (`Handle-Login`, `Get-Session`, `Me-Payload`); the HttpListener routing loop with **SQL-free endpoints placed before the `$cn` DB-connection block**.
- **The entire follow-up subsystem = the "Tick & Confirm" + communication feature** — `Save-Followup`, `Handle-FollowupList`, `Handle-Roster`, `Save-FollowupDone`, `Handle-MyFollowups` (serve-dashboard.ps1) and the client `@`-mention popup / `wireFollowupDone` / inbox badge (`app.js`). Lift wholesale, keyed by `job_no` instead of company code.
- **Client robustness:** `arr()`/`arrFields()` coercion for PowerShell's 0-/1-row `ConvertTo-Json` quirk; `cache:"no-store"` on fetches.

## CRITICAL gotchas (carried from pgs-dashboard — they caused real outages there)

- **`Packet Size=512` on every SQL connection string.** The VPN's small MTU black-holes default 8 KB TDS packets ("semaphore timeout"). Mandatory, no exceptions.
- **The server is single-threaded** (one `HttpListener` request at a time). A slow query blocks everything. Bound every query with `CommandTimeout`; the UI must read only the small `pgsops` tables, never the ERP on a request path.
- **`ConvertTo-Json` mangles 0- and 1-row arrays** in PS 5.1 (empty → `{}`, single → bare object). The client must coerce every list field back to an array (`arr()`); a `|| []` guard is *not* enough.
- **API + static responses are `no-store`** (`Cache-Control` / `Pragma` / `Expires`) — the app may run in a cross-site iframe; stale `ops.js`/data otherwise silently "don't take".
- **Cross-DB collation:** the reporting/ops DB is Latin1, station DBs are Chinese_HK. Text joins across DBs need `COLLATE DATABASE_DEFAULT`.
- **Secrets are gitignored — never commit them.** `ops.config.json`, `users.json`, `roles.json`, `ops-lists/`, `*-audit.log`. Verify with `git status` before any commit. Only `*.example.json` is tracked.
- **When killing test servers by command-line match, exclude `$PID`** or you kill your own shell.
- **The source station ERP DBs are READ-ONLY.** All writes go to `pgsops` only. Never `INSERT`/`UPDATE`/`ALTER` an ERP table.

## How to run (once built; mirrors pgs-dashboard)

1. **VPN must be up** — the SQL host is only reachable through the Swivel OpenVPN connection. If queries time out, check the VPN first.
2. Copy `ops.config.example.json` → `ops.config.json`, set server/SQL credentials + `pgsops` name + station list (env `DB_*` override for headless).
3. Run `setup-ops.ps1` once to create the schema. Then run the listener / start `serve-ops.ps1`.
4. Test server-side changes on a **temp port** so you don't disturb a running instance; syntax-check with `[PSParser]::Tokenize` (PS) and `node --check ops.js` (JS).

## Conventions (house rules — match pgs-dashboard)

1. **Think before coding** — state assumptions; surface alternatives; if unclear, ask.
2. **Simplicity first** — minimum code that solves the problem; no speculative abstractions.
3. **Surgical changes** — touch only what the request needs; match surrounding style.
4. **Goal-driven** — turn each task into a verifiable check. **Reconcile any computed milestone status / KPI against a direct SQL query of the source ERP before declaring it done.**
- **All SQL is parameterised** (`SqlParameter` / `@name`) — never string-build values from user input.
- **Row-level scope** carries over from the dashboard's model — route data reads through the scope clause so they stay scoped.
- **Dates are ISO `yyyy-mm-dd` everywhere** (e.g. `2023-12-31`) — display, input, and storage. This is the house standard; the locale-driven `mm/dd/yyyy` is wrong. **Do not use native `<input type="date">`** (it renders in the browser locale and forces a calendar popup the operators don't want) — use a plain `<input type="text">` with `placeholder="yyyy-mm-dd"` and a `^\d{4}-\d{2}-\d{2}$` guard. Server dates are emitted with `CONVERT(varchar(10), col, 23)` (ISO) and PowerShell with `.ToString('yyyy-MM-dd')`.
- Commit only when asked; never commit secrets.

## First build steps (the unblocking order)

1. `setup-ops.ps1` → create the 6 `pgsops` tables (see BLUEPRINT §1, §2, §4); confirm via `INFORMATION_SCHEMA`; re-run to prove idempotency.
2. **Resolve the ⚠ fields first** (BLUEPRINT "Open items"): map each logical field (`epdate`, `pdate`, `eta`, `atd`, `ddate`, `ad_date`, `comp_date`, `hbl_status`, `broker_name`, `trucker_name`, `wh_code`, …) and the **PIC / print_log / sendlog / EDI-log** tables to their **real** ERP `table.column` for one pilot station, verified by direct SQL. This is the project's main unknown — nothing downstream is trustworthy until it's done.
3. `listener-engine.ps1 -Mode Sea` on a temp DB/port for the pilot station → reconcile computed lights & auto-closes against hand SQL on 3 known shipments (mid-flight / departed / delivered).
4. `serve-ops.ps1` + UI → worklist reads only `shipment_alerts`; Tick & Confirm loop end-to-end.
