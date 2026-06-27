# CLAUDE.md — project context for Claude Code (erp-operation)

Read this first, then read **`PROJECT-SUMMARY.md`** — that is the live status anchor (what is actually built and
proven, plus the session log). **`BLUEPRINT.md`** is the original approved design-of-record (the what/how, section
by section); where the build diverged, PROJECT-SUMMARY is authoritative. This file gives you the hard constraints
and the orientation.

## Status: working app (built, in deployment)

**The app is fully built and runs against live data.** A clickable end-to-end worklist app works on two test
environments (Network `fm3k*` + demoerp); the web tier has been **ported from PowerShell `serve-ops.ps1` to an
ASP.NET Core (.NET 10) app in `server/`**, and a demoerp IIS deploy path exists. Do **not** treat this as
greenfield. Before changing anything, read PROJECT-SUMMARY.md for current state, then confirm the specific
handler/table/endpoint exists rather than assuming.

**Still not built (per PROJECT-SUMMARY):** the scheduled `listener-engine.ps1` (the one-shot `seed-alerts.ps1`
stands in for it) and `baseline-refresh.ps1` (so `baseline`-timed milestones fall back to fixed/none).

## What this is

`erp-operation` is a lightweight, event-driven **Control Tower & Operational KPI application** for a freight
forwarding ERP group. It answers *"what must an operator do **today** to keep each live shipment on schedule,
and where is cash leaking"* — an **operational** tool, distinct from its sibling `erp-dashboard` (financial /
sales **analytics**).

It does **not** alter the core ERP. A background "listener" reads the **read-only** source station ERP databases
directly (the same cross-DB way `..\erp-dashboard\refresh-warehouse.ps1` does), evaluates a configurable
**milestone matrix** into traffic-light status, and stores only **active** shipments in a new **`erpops`** MSSQL
database. The UI reads only that small operational state — never the ERP, never history.

```
station ERP DBs (READ-ONLY)  --listener-engine.ps1 (Air 2h / Sea 3x day)-->  erpops
                                                                                  |  serve-ops.ps1 (HttpListener + JSON API)
                                                                                  v
                                                                              browser (index.html / ops.js)
   baseline-refresh.ps1 (monthly, 3-yr averages) --> erpops.milestone_baselines (reference only)
```

**Stack.** Server tier = **ASP.NET Core (.NET 10) minimal API in `server/`** (one NuGet: `Microsoft.Data.SqlClient`,
raw ADO, no Dapper) — the multi-threaded replacement for the original single-threaded PowerShell HttpListener
(`serve-ops.ps1`, kept in-repo for rollback). Client = **vanilla JS** (no build step / no framework / no package
manager). Off-request-path jobs (`seed-alerts.ps1`, `publish-bookings.ps1`, seeders, Task Scheduler) remain
**PowerShell 5.1**. Data store = the **ops DB** on SQL Server — `erpops` / `erpops_net` (local `localhost\SQLEXPRESS`)
or `demoerp`, with the **read-only source ERP `fm3k*` reached over the Swivel VPN at `192.168.5.2`** (two-server
mode: read remote ERP, write local ops DB). "JSONB" in the original spec → MSSQL `NVARCHAR(MAX)` + `OPENJSON`.
(The old `18.136.126.101,1438` pgs env is retired.)

## Repo map (built — see PROJECT-SUMMARY.md "What's built" for status detail)

**Web tier (current) — `server/` (ASP.NET Core .NET 10):** `Program.cs` (routing, no-store/CORS, static-secret
guard, `dbGate` semaphore), `Config.cs`/`Auth.cs`/`Sql.cs`/`Source.cs`/`Filter.cs` (plumbing, per-request `ReqState`
scope), `Handlers.*.cs` (Worklist/Shipment/Notes/Tasks/Inbound/Erp*/Doc*/Public/Admin/Misc/Writes), `Erp.cs`/
`ErpDoc.cs` (Swivel ERP API client), `Pdf.cs`, `Doc*.cs`, `OpsEval.cs`, `Milestones.cs`. Build/run: `start-dotnet.bat`
or `dotnet run -c Release`; production = `dotnet publish` behind IIS. `serve-ops.ps1` is the **legacy** PowerShell
HttpListener server, kept for rollback only.

**Client (static):** `index.html` / `ops.js` / `styles.css` (worklist, manager plan, det/dem, my-tasks),
`login.html`, `admin-ops.html` (4 tabs: Users / Milestones / Documents / ERP API), `erp-edit.{html,js}` +
`erp-edit-fields.json` (staff ERP data-correction editor), `doc-editor.{html,js}` + `bl-review.{html,js}` +
`bl-form.js` + `doc-fields.json` (draft HBL/HAWB customer-review loop), `i18n.js` + `lang/{zh-Hans,ja}.json`
(English/SC/JP localization).

**Schema + listener stand-in + feed (PowerShell):** `setup-ops.ps1` (creates the **~18-table** `erpops` schema
idempotently, two-server aware), `seed-milestone-config.ps1` (37 `milestone_def` rows), `ops-eval.ps1` (Sea+Air
evaluator), `seed-alerts.ps1 -Mode Sea|Air` (**listener stand-in** — the scheduled `listener-engine.ps1` is not yet
built), `eval-shipment.ps1`, `seed-ports.ps1`, `erp-doc-api.ps1` (ERP push payload builders), `seed-station-map.ps1`
+ `publish-bookings.ps1` (cross-station inbound feed → `inbound_booking_feed`, served by `/api-ops/inbound` +
`/api-ops/inbound-assign`), `register-ops-tasks.ps1` (Task Scheduler). `baseline-refresh.ps1` is not yet built.

**Config / secrets (gitignored):** `ops.config.json` + `ops.config.<env>.json` (network/demoerp), `users.json`
(`roles.json` is not used — roles live inline per user); copy from `ops.config.example.json` / `users.example.json`;
env `DB_*`/`OPS_*` override. `erp-api-map.json` (tracked) holds non-secret ERP deployment codes.

**Deploy / ops:** `first-install/deploy-local-iis-demoerp.ps1` (one-time elevated IIS bootstrap), `redeploy-demoerp.bat`,
`restart-ops-{network,local,demoerp}.bat`, `docs/` (BUSINESS/TECHNICAL/DEVELOPER-GUIDE, SQL-README, IIS-DEPLOY, CUTOVER).

## Reuse, don't reinvent (sibling: `..\erp-dashboard`)

These are proven and lift over almost verbatim — read them in `..\erp-dashboard` before writing the equivalent:
- **Connection + retry:** `ConnStr` (with `Packet Size=512`), `Test-Transient`, `ExecSql` retry loop, `RunQ`/`RunMulti` (`CommandTimeout=45`, optional `$timeoutSec`), `Table-Exists`/`Column-Exists` with `@(...)` guards — all in `refresh-warehouse.ps1` / `serve-dashboard.ps1`.
- **Idempotent schema:** the `IF OBJECT_ID(...) IS NULL CREATE` / `IF COL_LENGTH(...) IS NULL ALTER` idiom in `setup-warehouse.ps1`.
- **Materialize pattern:** `TRUNCATE + INSERT…SELECT` summary builds (model for `baseline-refresh.ps1`).
- **Scheduling:** `register-nightly-task.ps1` (extend its trigger for 2h / 3×day / monthly).
- **Web plumbing:** `Send-Json`/`Send-File` with `no-store` headers; sessions/auth (`Handle-Login`, `Get-Session`, `Me-Payload`); the HttpListener routing loop with **SQL-free endpoints placed before the `$cn` DB-connection block**.
- **The entire follow-up subsystem = the "Tick & Confirm" + communication feature** — `Save-Followup`, `Handle-FollowupList`, `Handle-Roster`, `Save-FollowupDone`, `Handle-MyFollowups` (serve-dashboard.ps1) and the client `@`-mention popup / `wireFollowupDone` / inbox badge (`app.js`). Lift wholesale, keyed by `job_no` instead of company code.
- **Client robustness:** `arr()`/`arrFields()` coercion for PowerShell's 0-/1-row `ConvertTo-Json` quirk; `cache:"no-store"` on fetches.

## CRITICAL gotchas (carried from erp-dashboard — they caused real outages there)

- **`Packet Size=512` on every SQL connection string.** The VPN's small MTU black-holes default 8 KB TDS packets ("semaphore timeout"). Mandatory, no exceptions.
- **Request-path discipline.** The UI must read only the small `erpops` tables, never the ERP on a request path; bound every query with `CommandTimeout`. The .NET `server/` is **multi-threaded** with a `dbGate` semaphore (default 16) and **per-request `ReqState`** for row-level scope (the structural fix for the auth-bypass risk that forced the legacy PS server to be single-threaded). The legacy `serve-ops.ps1` was single-threaded (one `HttpListener` request at a time) — a slow query blocked everything; that constraint applies only if you run the legacy server.
- **`ConvertTo-Json` mangles 0- and 1-row arrays** in PS 5.1 (empty → `{}`, single → bare object). The client must coerce every list field back to an array (`arr()`); a `|| []` guard is *not* enough.
- **API + static responses are `no-store`** (`Cache-Control` / `Pragma` / `Expires`) — the app may run in a cross-site iframe; stale `ops.js`/data otherwise silently "don't take".
- **Cross-DB collation:** the reporting/ops DB is Latin1, station DBs are Chinese_HK. Text joins across DBs need `COLLATE DATABASE_DEFAULT`.
- **Secrets are gitignored — never commit them.** `ops.config.json`, `users.json`, `roles.json`, `ops-lists/`, `*-audit.log`. Verify with `git status` before any commit. Only `*.example.json` is tracked.
- **When killing test servers by command-line match, exclude `$PID`** or you kill your own shell.
- **Never read a text/JSON file with bare `Get-Content`** — PS 5.1 decodes BOM-less UTF-8 as ANSI, turning
  `—`/`·` into `â€”`/`Â·` mojibake on screen (this bit the config subtitle). Read with
  `[IO.File]::ReadAllText($path)` (UTF-8 + BOM detection) and write with
  `[IO.File]::WriteAllText($path, $s, (New-Object System.Text.UTF8Encoding($false)))`. Every new HTML page
  needs `<meta charset="utf-8">` (and `Ctype` already sends `charset=utf-8`). Prefer plain ASCII separators
  (`-`, not `—`/`·`) in user-visible default strings. **The same applies to `.ps1` source itself**: PS 5.1
  runs BOM-less scripts as ANSI, and an em-dash's last byte decodes to a smart quote (`”`) that *terminates
  the string* — a runtime parse error that `PSParser`-on-decoded-text won't catch. Keep `.ps1` files
  ASCII-only.
- **The source station ERP DBs are READ-ONLY.** All writes go to `erpops` only. Never `INSERT`/`UPDATE`/`ALTER` an ERP table.

## How to run (see PROJECT-SUMMARY.md "How to run" + docs/2-SETUP-NEW-CUSTOMER.md for the full matrix)

1. **VPN must be up** — the source ERP (`192.168.5.2`) is only reachable through the Swivel OpenVPN connection. If
   queries time out, check the VPN first (see the `swivel-vpn` skill for the Surfshark route conflict fix).
2. Copy `ops.config.example.json` → `ops.config.<env>.json`, set source-ERP + ops-DB connection (two-server keys
   `opsServer`/`opsAuth`/…), `erpops` name + station list (env `DB_*`/`OPS_*` override for headless).
3. One-time: `setup-ops.ps1 -ConfigPath …` (schema), `seed-milestone-config.ps1`, then `seed-alerts.ps1 -Mode Sea|Air`
   per station to populate `shipment_alerts`.
4. **Run the web tier from `server/`**: `start-dotnet.bat` (or `OPS_CONFIG=… OPS_HTTP_PORT=8079 dotnet run -c Release`)
   → Kestrel on the config port. Production = `dotnet publish -c Release` behind IIS (`redeploy-demoerp.bat`).
5. Syntax/sanity checks before declaring done: `.cs` → `dotnet build` (0 warnings); `.ps1` → `[PSParser]::Tokenize`;
   `.js` → `node --check ops.js`. Test on a **temp port** so you don't disturb a running instance.

## Conventions (house rules — match erp-dashboard)

1. **Think before coding** — state assumptions; surface alternatives; if unclear, ask.
2. **Simplicity first** — minimum code that solves the problem; no speculative abstractions.
3. **Surgical changes** — touch only what the request needs; match surrounding style.
4. **Goal-driven** — turn each task into a verifiable check. **Reconcile any computed milestone status / KPI against a direct SQL query of the source ERP before declaring it done.**
- **All SQL is parameterised** (`SqlParameter` / `@name`) — never string-build values from user input.
- **Row-level scope** carries over from the dashboard's model — route data reads through the scope clause so they stay scoped.
- **Dates are ISO `yyyy-mm-dd` everywhere** (e.g. `2023-12-31`) — display, input, and storage. This is the house standard; the locale-driven `mm/dd/yyyy` is wrong. **Do not use native `<input type="date">`** (it renders in the browser locale and forces a calendar popup the operators don't want) — use a plain `<input type="text">` with `placeholder="yyyy-mm-dd"` and a `^\d{4}-\d{2}-\d{2}$` guard. Server dates are emitted with `CONVERT(varchar(10), col, 23)` (ISO) and PowerShell with `.ToString('yyyy-MM-dd')`.
- Commit only when asked; never commit secrets.

## Where to start (resuming work)

The app is built; there is no greenfield build order. To resume:
1. Read **`PROJECT-SUMMARY.md`** (latest-session block at the top = current focus / "RESUME HERE").
2. The ⚠ ERP field map that BLUEPRINT flagged as the main unknown is **resolved** — the verified ERP `table.column`
   map lives in **`docs/7-SQL-REFERENCE.md`**. Reconcile any new field against live SQL before trusting it (house rule).
3. Most work now happens in the .NET `server/`; the client is static (reload, no rebuild). Restart the server after
   a `.cs` change (`restart-ops-*.bat` / `redeploy-demoerp.bat`).
4. Largest remaining gaps: the scheduled `listener-engine.ps1` and `baseline-refresh.ps1` (see PROJECT-SUMMARY
   "Not yet built").
