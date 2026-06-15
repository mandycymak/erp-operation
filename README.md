# pgs-operation — Control Tower & Operational KPI Application

A lightweight, event-driven operational control tower for a freight forwarding ERP group. It tracks
time-sensitive shipment milestones (Air + Sea, Export + Import), raises traffic-light alerts on the operator's
daily worklist and the management dashboard, and surfaces cash-flow leakage and staff-performance KPIs — while
**reading the core ERP read-only** and storing its own small state in a new `pgsops` database.

Sibling project: **`..\pgs-dashboard`** (financial / sales analytics). `pgs-operation` deliberately reuses that
project's stack and proven helpers (PowerShell HttpListener + vanilla JS, the connection/retry/schema idioms,
and the follow-up / @-mention collaboration subsystem).

## Documentation

| File | Read it for |
|---|---|
| **`BLUEPRINT.md`** | **The authoritative, approved design** — all 6 tables, the milestone matrix, the listener engine, the KPI queries, and the person-focused worklist. Start here. |
| **`PROJECT-SUMMARY.md`** | **What is actually built and proven** (the session log / status snapshot). Read this when resuming. |
| `docs/BUSINESS-GUIDE.md` | End-user guide — worklist, drawer, Tick & Confirm, drafts, Edit ERP data, inbound feed. |
| `docs/TECHNICAL-GUIDE.md` | Install / run / config / users & roles / ERP integration / SWIVEL L!NK / VPN / troubleshooting. |
| `docs/DEVELOPER-GUIDE.md` | Coding standards + back-/front-end conventions for extending the app. |
| `docs/SQL-README.md` | The `pgsops` schema + the verified ERP source field map. |
| `CLAUDE.md` | Project context for Claude Code: hard constraints (gotchas), the reuse map, repo layout. Auto-loaded in a Claude Code session. |

## Status

**Working app — built and proven against real ERP data** on two test environments (live `fm3k*` group + demoerp).
Air + Sea, Export + Import: arrival-driven worklist with traffic-light milestones, multi-station, cross-station
inbound feed, the draft HBL/HAWB customer-agreement loop, **Edit ERP data → live `/booking/update`**, and
**upload-a-document-to-clear-a-milestone**. Sign-in is **by email**, with a seam for **SWIVEL L!NK** OAuth
sign-on. The scheduled `listener-engine.ps1` is still deferred (`seed-alerts.ps1` stands in for it). See
`PROJECT-SUMMARY.md` for the running status and `docs/` for the guides.

## Architecture

```
station ERP DBs (READ-ONLY) --listener-engine.ps1 (Air 2h / Sea 3x day)--> pgsops (shipment_alerts, milestone_*, detention_watch)
                                                                                |  serve-ops.ps1 (HttpListener + JSON API)
                                                                                v
                                                                            browser (index.html / ops.js)
```

Stack: PowerShell 5.1 + .NET SqlClient/HttpListener · vanilla JS (no build step) · SQL Server over the Swivel
VPN. **The VPN must be up for any DB work**, and every connection string keeps `Packet Size=512`.
