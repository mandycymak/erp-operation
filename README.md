# erp-operation — Control Tower & Operational KPI Application

A lightweight, event-driven operational control tower for a freight forwarding ERP group. It tracks
time-sensitive shipment milestones (Air + Sea, Export + Import), raises traffic-light alerts on the operator's
daily worklist and the management dashboard, and surfaces cash-flow leakage and staff-performance KPIs — while
**reading the core ERP read-only** and storing its own small state in a new `erpops` database.

Sibling project: **`..\erp-dashboard`** (financial / sales analytics). `erp-operation` deliberately reuses that
project's stack and proven helpers (PowerShell HttpListener + vanilla JS, the connection/retry/schema idioms,
and the follow-up / @-mention collaboration subsystem).

## Documentation

The guides under [`docs/`](docs/) are **numbered by lifecycle stage** — start at
**[`docs/1-OVERVIEW.md`](docs/1-OVERVIEW.md)**, which is also the full documentation map (which doc + which `.bat`
at each stage). For a map of **every file** in the repo (not just docs), see [`FILES.md`](FILES.md).

| Stage | File | Read it for |
|---|---|---|
| **0. Understand** | [`docs/1-OVERVIEW.md`](docs/1-OVERVIEW.md) | What it is, architecture, and the map to every other doc. |
| **1. Set up a new customer** | **[`docs/2-SETUP-NEW-CUSTOMER.md`](docs/2-SETUP-NEW-CUSTOMER.md)** | The one self-contained first-install playbook (config, DB+seed, IIS+HTTPS, users, scheduled jobs, backups) + install-time reference. |
| **2. Deploy an update** | **[`docs/3-DEPLOY-UPDATES.md`](docs/3-DEPLOY-UPDATES.md)** | Routine updates to an existing site: `update-customer.bat`, env-var persistence, redeploy + rollback. |
| **3. Operate & support** | **[`docs/4-OPERATE-SUPPORT.md`](docs/4-OPERATE-SUPPORT.md)** | After go-live: Audit & Health console, log map, troubleshooting, user/role admin, retention, backup/restore. |
| **Use the app** | [`docs/5-BUSINESS-GUIDE.md`](docs/5-BUSINESS-GUIDE.md) | End-user guide — worklist, drawer, Tick & Confirm, drafts, Edit ERP data, inbound feed, **UI language switch**. |
| **Change the code** | [`docs/6-DEVELOPER-GUIDE.md`](docs/6-DEVELOPER-GUIDE.md) | Coding standards + back-/front-end conventions, the .NET web tier, adding a UI language. |
| **Reference: schema** | [`docs/7-SQL-REFERENCE.md`](docs/7-SQL-REFERENCE.md) | The `erpops` schema + the verified ERP source field map. |
| **Reference: integration** | [`docs/8-API.md`](docs/8-API.md) | The third-party Find API (JWT bearer, natural-language search). |
| **Design of record** | `BLUEPRINT.md` | The authoritative, approved design — tables, milestone matrix, listener engine, KPI queries. |
| **Status / session log** | `PROJECT-SUMMARY.md` | What is actually built and proven. Read this when resuming. |
| **Claude Code context** | `CLAUDE.md` | Hard constraints (gotchas), the reuse map, repo layout. Auto-loaded in a Claude Code session. |

## Status

**Working app — built and proven against real ERP data** on two test environments (live `fm3k*` group + demoerp).
Air + Sea, Export + Import: arrival-driven worklist with traffic-light milestones, multi-station, cross-station
inbound feed, the draft HBL/HAWB customer-agreement loop, **Edit ERP data → live `/booking/update`**, and
**always-on ERP document upload** (upload any configured doctype; ones that also clear a milestone are flagged).
The UI is **localized — English + Simplified Chinese (中文) + Japanese (日本語)** with a per-user default and a
one-click switch. Sign-in is **by email**, with a seam for **SWIVEL L!NK** OAuth sign-on.

A **natural-language Find chat** (🔎 in the header) lets an operator locate a shipment by typing what they
remember — a company, lane, commodity, contact, booking/HBL/**ship-id**/**vessel**/container number, a message
someone sent them, or a date — across active **and** recently-closed files, always within their role scope. Each
message is a fresh search and the conversation stays on screen so searches can be compared.
Each hit is shown as a **full worklist-style card** (incoterm, cargo, commodity, ship-id, parties, dates) so the
right file can be picked at a glance. It's a rule-based parser (no LLM)
with an editable "Looking for:" summary; an **optional LLM fallback** (Claude / OpenAI / DeepSeek, **off by
default**, configured in the gitignored `llm` config block) can re-interpret a query that the rule parser
can't, without ever bypassing scope. Backing it, operator **notes now live in SQL** (`dbo.job_note`, migrated
from the old `ops-lists/job-notes.json`) so they're searchable like every other entity.

**The web tier now runs as an ASP.NET Core (.NET 10) app in [`server/`](server/)** (multi-threaded, per-request
scope isolation). The legacy PowerShell `serve-ops.ps1` is kept for rollback. The off-request-path PowerShell
jobs (`seed-alerts.ps1`, `publish-bookings.ps1`, …) still run under Task Scheduler. The scheduled
`listener-engine.ps1` is still deferred (`seed-alerts.ps1` stands in for it). See `PROJECT-SUMMARY.md` for the
running status, `docs/` for the guides, and **`docs/2-SETUP-NEW-CUSTOMER.md` to deploy**.

## Architecture

```
station ERP DBs (READ-ONLY) --seed-alerts.ps1 (listener stand-in) / Task Scheduler--> erpops (shipment_alerts, milestone_*, detention_watch)
                                                                                |  server/ (ASP.NET Core .NET 10, JSON API)  [serve-ops.ps1 = legacy/rollback]
                                                                                v
                                                                            browser (index.html / ops.js / i18n.js + lang/*.json)
```

Stack: **ASP.NET Core .NET 10** (web tier; raw ADO `Microsoft.Data.SqlClient`) · PowerShell 5.1 + .NET SqlClient
(off-path seeders) · vanilla JS, **no build step** (client + the i18n layer) · SQL Server over the Swivel VPN.
**The VPN must be up for any DB work**, and every connection string keeps `Packet Size=512`.

## Run / deploy (quick pointers)
- **Dev (Kestrel):** from `server/`, `OPS_CONFIG=ops.config.network.json OPS_HTTP_PORT=8079 dotnet run -c Release` → `http://localhost:8079/`.
- **Production (IIS + HTTPS):** `dotnet publish -c Release -o publish`, then follow **`docs/2-SETUP-NEW-CUSTOMER.md`**.
- **Local IIS rehearsal (demoerp):** run `first-install\deploy-local-iis-demoerp.ps1` (elevated) once; redeploy with `redeploy-demoerp.bat`.
