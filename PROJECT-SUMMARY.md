# pgs-operation — Project Summary

Status snapshot of the Control Tower build. The authoritative design is **`BLUEPRINT.md`**; this file records
**what is actually built and proven** against the live ERP, plus the key findings that shaped it.

## Status: working vertical slice built (listener deferred by decision)

A clickable, end-to-end worklist app runs against real data. The scheduled listener is intentionally **not yet
built** — its job is stood in for by a one-shot demo seeder so the UI and the Tick-&-Confirm loop can be exercised
now.

```
station ERP DBs (READ-ONLY)                         pgsops (operational state)
  blhead / PIC / blcont / edilog  --- ops-eval.ps1 (shared evaluator) --->  shipment_alerts, milestone_def,
        |   (seed-alerts.ps1 = demo stand-in for the listener)               milestone_evidence_map, …
        |                                                                          |  serve-ops.ps1 (HttpListener + JSON API)
        |                                                                          v
        '------------- READ ONLY, never written -------------               browser (index.html / ops.js)
```

## Key findings (these shaped the whole build)

1. **The ERP databases are a frozen ~2023-04-30 snapshot**, not a live feed — zero shipments in the last 150
   days across all 23 stations. Development runs against the snapshot with a configurable **as-of date of
   2023-04-10**, treated as "today", so shipments are genuinely mid-flight.
2. **The milestone fields are real but largely empty in this snapshot.** Almost every matrix field maps to a real
   `blhead` column (and the "PIC table" is one real table carrying doc/print/send evidence), but the operational
   columns are ~0% populated here (only `atd_date`/`departure1`/`status` carry data; PIC is ~72% "Booking Photo").
   The rich `documentTypeCode` evidence the design relies on exists in **production**, not this test copy.
3. **Sparse data is handled by design, not a blocker.** Milestone completion resolves in priority order:
   **(1) ERP data first** (`complete_rule` over real fields; qualification is also data-driven — *not every
   milestone applies to every shipment*, and conditions can be OR'd), **(2) PIC/EDI evidence** (upload the
   configured `documentTypeCode` to close a hard-copy milestone), **(3) planned due-window** (trade-lane baseline,
   or a fixed-offset fallback like "N days before ETD" when baselines are too thin), **(4) manual Tick & Confirm**
   (operator closes a tag even with no ERP data; un-tickable and visually marked).

## What's built

| File | Role | State |
|---|---|---|
| `setup-ops.ps1` | Creates `pgsops` + the 6 tables idempotently (+`module_match` on the evidence map) | ✅ live, idempotent |
| `seed-milestone-config.ps1` | Seeds the config as data: 23 `milestone_def` rows (Export+Import matrix) + starter `milestone_evidence_map`, rules over real `blhead` columns | ✅ seeded |
| `ops-eval.ps1` | Shared milestone evaluator (pure, no DB): `New-ShipContext` + `Eval-Milestones` | ✅ reused by the two scripts below |
| `eval-shipment.ps1` | Read-only one-shot card: evaluates one shipment as of a date, prints its milestone states | ✅ proven on HKG |
| `seed-alerts.ps1` | **Demo stand-in for the listener** — evaluates a batch of real shipments and upserts `shipment_alerts` (60 active HKG shipments seeded) | ✅ |
| `serve-ops.ps1` | Web service: worklist, shipment detail, notes (keyed by `job_no`), my-tasks, manual milestone-close. Lifts the dashboard's plumbing + follow-up subsystem | ✅ proven end-to-end |
| `index.html` / `ops.js` / `styles.css` | Worklist UI: cards by traffic light, shipment drawer with milestone checklist + Tick/Un-tick, @-mention note composer, My-Tasks inbox + badge | ✅ |
| `ops.config.example.json` | Config template (real `ops.config.json` is gitignored) | ✅ |

**Not yet built:** the real `listener-engine.ps1`, `baseline-refresh.ps1`, `register-ops-tasks.ps1`,
`admin-ops.html` (milestone-def / evidence / field-alias editors), real auth (runs in open/demo mode), and the
`pic_user` ↔ app-user identity mapping (a blueprint open item).

## Proven behaviour (tested live)

- **Worklist** reads only `shipment_alerts` (never the ERP on a request path); lenses = my work / teammate / all,
  bucketed Critical / This Week / Monitor by traffic light.
- **Collaboration loop:** operator A posts a note `@`-mentioning B → B's My-Tasks badge increments → B
  acknowledges (✓ Tick & Confirm) → it clears off B's inbox. Notes are keyed by `job_no`.
- **Manual Tick & Confirm** on a milestone flips the shipment's rollup (e.g. R→G), threads a "bypass" note, and is
  **un-tickable** (restores the original planned light). Pure JSON overlay — the ERP is never touched.
- **Cash-leak signal** works: a departed shipment with no invoice goes **Red at ATD+3** (the fixed-SLA window).

## How to run (VPN must be up)

```powershell
Copy-Item ops.config.example.json ops.config.json   # set server/creds/opsDb (reuses the pgs-dashboard SQL login)
.\setup-ops.ps1                 # create the 6 pgsops tables (idempotent)
.\seed-milestone-config.ps1     # seed the milestone matrix + evidence map (config-as-data)
.\seed-alerts.ps1               # demo: evaluate real HKG shipments -> shipment_alerts (stand-in for the listener)
.\serve-ops.ps1                 # web app at http://localhost:8078/  (pick an operator, top-right)
# inspect one shipment's milestones without the server:
.\eval-shipment.ps1 -JobNo <HKG job> -AsOf 2023-05-03
```

## Constraints carried from pgs-dashboard (do not violate)

- **`Packet Size=512`** on every SQL connection string (VPN MTU black-holes default 8 KB TDS packets).
- The HttpListener server is **single-threaded**; the UI reads only the small `pgsops` tables, never the ERP.
- **Source ERP DBs are READ-ONLY** — all writes go to `pgsops` (or the gitignored JSON note store).
- **Secrets are gitignored** (`ops.config.json`, `users.json`, `roles.json`, `ops-lists/`, `*.log`); verify with
  `git status` before any commit. Only `*.example.json` is tracked.
- PS 5.1 traps fixed here: coerce `$null`→`[DBNull]::Value` for SQL params; never hand `ConvertTo-Json` a whole
  array/ArrayList for a JSON store (it nests `{value,Count}` wrappers) — serialize records individually and join.
