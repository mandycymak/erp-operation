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
| `CLAUDE.md` | Project context for Claude Code: hard constraints (gotchas), the reuse map, planned repo layout, and the unblocking build order. Auto-loaded in a Claude Code session. |

## Status

**Greenfield — design complete, implementation not started.** This repo currently holds documentation only. The
first build step is `setup-ops.ps1` (the `pgsops` schema); the main project risk is mapping the milestone/event
fields and log tables (PIC / print_log / sendlog / EDI) to their **real** ERP columns — see the "Open items" at
the foot of `BLUEPRINT.md`.

## Architecture (once built)

```
station ERP DBs (READ-ONLY) --listener-engine.ps1 (Air 2h / Sea 3x day)--> pgsops (shipment_alerts, milestone_*, detention_watch)
                                                                                |  serve-ops.ps1 (HttpListener + JSON API)
                                                                                v
                                                                            browser (index.html / ops.js)
```

Stack: PowerShell 5.1 + .NET SqlClient/HttpListener · vanilla JS (no build step) · SQL Server over the Swivel
VPN. **The VPN must be up for any DB work**, and every connection string keeps `Packet Size=512`.
