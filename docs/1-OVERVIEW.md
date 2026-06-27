# Control Tower (erp-operation) — Overview & Documentation Map

A lightweight, event-driven **operational control tower** for a freight-forwarding ERP group. It tracks
time-sensitive shipment milestones (Air + Sea, Export + Import), raises traffic-light alerts on the operator's
daily worklist, and surfaces cash-flow / staff KPIs — while **reading the core ERP read-only** and storing its
own small state in a new `erpops` database.

> **Authoritative companions:** `BLUEPRINT.md` (the approved design-of-record) and `PROJECT-SUMMARY.md` (what is
> actually built and proven — the live status log). This file is the entry point to the **how-to** guides under
> `docs/`.

---

## Documentation map — which document at which stage

The guides under `docs/` are numbered by lifecycle stage. Read the one for what you are doing:

| Stage | Document | Read it for |
|---|---|---|
| **0. Understand** | **[1-OVERVIEW.md](1-OVERVIEW.md)** (this file) | What the system is, the architecture, and where every other doc lives. |
| **1. Set up a new customer** | **[2-SETUP-NEW-CUSTOMER.md](2-SETUP-NEW-CUSTOMER.md)** | The one self-contained first-install playbook — config, DB + schema, IIS + HTTPS, seed, users, scheduled jobs, backups — plus the install-time reference (config fields, two-server mode, VPN, ERP-API connection, i18n, tenancy). |
| **2. Deploy an update** | **[3-DEPLOY-UPDATES.md](3-DEPLOY-UPDATES.md)** | Routine code/schema updates to an **existing** site: the one-command `update-customer.bat`, env-var persistence, manual redeploy + rollback. |
| **3. Operate & support** | **[4-OPERATE-SUPPORT.md](4-OPERATE-SUPPORT.md)** | Day-to-day after go-live: the in-app Audit & Health console, alerting, log map, troubleshooting, data refresh, user/role admin, retention, backup/restore, IIS-vs-container. |
| **Use the app** | **[5-BUSINESS-GUIDE.md](5-BUSINESS-GUIDE.md)** | End-user guide — worklist, drawer, Tick & Confirm, drafts, Edit ERP data, inbound feed, language switch. |
| **Change the code** | **[6-DEVELOPER-GUIDE.md](6-DEVELOPER-GUIDE.md)** | Coding standards, back-/front-end conventions, the .NET web tier, adding a UI language. |
| **Reference: schema** | **[7-SQL-REFERENCE.md](7-SQL-REFERENCE.md)** | The `erpops` schema + the verified ERP source field map. |
| **Reference: integration** | **[8-API.md](8-API.md)** | The third-party Find API (JWT bearer, natural-language search). |

> `docs/_archive/` holds historical docs (e.g. `CUTOVER.md`, the completed PowerShell→.NET migration runbook) —
> kept for reference, not part of the live stages.

### Which `.bat` runs at which stage

| Stage | Command | What it does |
|---|---|---|
| Set up (first install) | `first-install\setup-database.bat` | Creates the ops DB + all tables + seeds the milestone config. **Once, on a fresh deploy.** Refuses to run on an already-installed DB unless you type INSTALL. |
| Set up (first fill) | `seed-data.bat` | Live-ERP fill: station map / ports / liners / inbound feed / worklist, looping every station × Sea/Air. |
| Deploy an update | `update-customer.bat` | Safe, additive update of an existing site (schema migrate + insert-missing milestones + publish + verify). |
| Run for dev (.NET) | `start-dotnet.bat` | `dotnet run` the .NET web tier on the config port (Kestrel). |
| Run for dev (legacy PS) | `restart-ops-{demoerp,local,network}.bat` | Start the legacy `serve-ops.ps1` for the matching config (rollback only). |
| Ad-hoc reseed | `seed-hkg.bat` | One-click HKG Sea + Air delta refresh. |
| Local IIS rehearsal | `first-install\deploy-local-iis-demoerp.ps1` + `redeploy-demoerp.bat` | Stand the published app up under IIS on this PC (demoerp). |

---

## Architecture

```
station ERP DBs (READ-ONLY) --seed-alerts.ps1 (listener stand-in) / Task Scheduler--> erpops (shipment_alerts, milestone_*, ...)
                                                                                |  server/ (ASP.NET Core .NET 10, JSON API)  [serve-ops.ps1 = legacy/rollback]
                                                                                v
                                                                            browser (index.html / ops.js / i18n.js + lang/*.json)
```

The background jobs read the read-only station ERP DBs, score the milestone matrix, and upsert the small `erpops`
state DB. The browser only ever talks to `erpops` — never the ERP — so it stays fast.

**Stack:** ASP.NET Core .NET 10 (web tier; raw ADO `Microsoft.Data.SqlClient`) · PowerShell 5.1 + .NET SqlClient
(off-path seeders) · vanilla JS, **no build step** (client + the i18n layer) · SQL Server, reached over the
Swivel VPN for remote/dev (at the customer it is on the LAN). **Every connection string keeps `Packet Size=512`**
(the VPN's small MTU black-holes default 8 KB TDS packets).

## Status (summary)

**Working app, in deployment.** Air + Sea, Export + Import: arrival-driven worklist with traffic-light
milestones, multi-station, cross-station inbound feed, the draft HBL/HAWB customer-agreement loop, Edit ERP data →
live `/booking/update`, Book Now (create a booking in the ERP), Generate document, and always-on ERP document
upload. The UI is localized (English / 中文 / 日本語). Sign-in is by email, with a SWIVEL L!NK OAuth seam and a
JWT-bearer third-party Find API. The web tier runs as the .NET app in [`server/`](../server/); the legacy
PowerShell `serve-ops.ps1` is kept for rollback. The scheduled `listener-engine.ps1` is still deferred
(`seed-alerts.ps1` stands in). See `PROJECT-SUMMARY.md` for the running detail.
