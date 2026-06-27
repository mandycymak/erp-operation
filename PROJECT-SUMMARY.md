# erp-operation — Project Summary

Current status snapshot of the Control Tower build. The authoritative design is **`BLUEPRINT.md`**; this file
records **what is actually built and proven** against real ERP data, plus the current focus. Read this first when
resuming.

> **Full session-by-session history** (every build round to date) is archived at
> [`docs/_archive/PROJECT-SUMMARY-2026-06-27.md`](docs/_archive/PROJECT-SUMMARY-2026-06-27.md). This file was
> cleaned to the current status on 2026-06-27; consult the archive for the historical detail of any feature.

**Documentation lives in [`docs/`](docs/), numbered by lifecycle stage** (map: [1-OVERVIEW.md](docs/1-OVERVIEW.md)):
[2-SETUP-NEW-CUSTOMER.md](docs/2-SETUP-NEW-CUSTOMER.md) (first install) ·
[3-DEPLOY-UPDATES.md](docs/3-DEPLOY-UPDATES.md) (updates) ·
[4-OPERATE-SUPPORT.md](docs/4-OPERATE-SUPPORT.md) (run/admin) ·
[5-BUSINESS-GUIDE.md](docs/5-BUSINESS-GUIDE.md) (operators/managers) ·
[6-DEVELOPER-GUIDE.md](docs/6-DEVELOPER-GUIDE.md) (coding standards) ·
[7-SQL-REFERENCE.md](docs/7-SQL-REFERENCE.md) (`erpops` schema + the verified ERP field map) ·
[8-API.md](docs/8-API.md) (third-party Find API).

---

## Status: working app, in deployment

A clickable, end-to-end worklist app runs against real data on two test environments. **Air + Sea, Export +
Import.** The **web tier is an ASP.NET Core (.NET 10) app in [`server/`](server/)** — multi-threaded, per-request
scope isolation; the legacy PowerShell `serve-ops.ps1` is kept for rollback only. The client is **vanilla JS, no
build step**. Off-request-path jobs (`seed-alerts.ps1`, `publish-bookings.ps1`, seeders, governance) run under
**Windows Task Scheduler (PowerShell 5.1)**. The data store is the **`erpops`** ops DB on SQL Server, with the
read-only source ERP (`fm3k*`) reached over the Swivel VPN for remote/dev (on the LAN at a customer).

The scheduled `listener-engine.ps1` is **deferred** — `seed-alerts.ps1` (one-shot evaluator/upsert, with a
`-Delta` incremental mode) stands in for it.

---

## RESUME HERE — latest session (2026-06-27, deployment-safety hardening)

Goal: stop a re-run of setup / a mis-pointed redeploy from silently overwriting or "losing" customer users +
admin-edited config. Owner concern from a real incident: after a developer deploy, the customer's users vanished
and only `admin/admin123` worked. **Diagnosis (no bug in the store):** logins/roles/scope DO live in SQL
(`dbo.app_user` + `dbo.app_user_scope`); `setup-ops.ps1` is idempotent and never drops/overwrites. The real causes
were (a) a redeploy losing the app-pool `OPS_CONFIG`/`OPS_ROOT` env vars (or publishing to a fresh folder missing
the gitignored tenant config) → the app pointed at a **different/empty DB** → silent re-seed of `admin/admin123`;
and (b) `seed-milestone-config.ps1`'s `MERGE` resetting admin-edited milestones. **Committed `bec71c9`.** Fixes:

- **No-silent-seed guard (`server/Auth.cs`).** `SeedOrImport` is gated by **`OPS_ALLOW_SEED`**. On an empty
  `app_user` without the flag, the app **throws a clear wrong-DB error** naming the resolved `Server`/`Database`
  instead of quietly seeding `admin/admin123` or importing a stray `users.json`. A populated table is unaffected.
- **Startup DB log (`server/Config.cs`).** `Config.Load` logs `[Config] ops DB target: Server=…; Database=…;
  config=…; root=…` as the first line, so a mis-pointed deploy is visible immediately.
- **Non-destructive milestone re-seed (`seed-milestone-config.ps1`).** Default is **INSERT-MISSING-ONLY** (adds new
  defs, preserves admin edits); new `-Force` restores the old reset-to-defaults behaviour.
- **One-command routine update (`update-customer.bat` + `verify-customer.ps1`).** The single script run on a customer
  server after pulling new code: app-offline → `setup-ops.ps1` (additive) → `seed-milestone-config.ps1`
  (insert-only) → `dotnet publish` in place + recycle pool → `verify-customer.ps1` (read-only check that **exits
  non-zero with a red warning if `app_user` is empty**). It deliberately does NOT reseed users, reset milestones,
  recreate the IIS site/pool, or backfill data.

**Owner-side to confirm (needs a server):** run `update-customer.bat` on a tenant and confirm the verify line shows
users intact; set `OPS_ALLOW_SEED=1` only for a deliberate first install.

---

## What's built and proven

All proven against live `fm3k*` data over the VPN (mock OFF where noted) unless marked.

- **Worklist** — arrival-driven, traffic-light milestones, grouped by vessel/voyage (Sea) or airline+flight (Air);
  multi-station; Import (Arrived/Arriving/Planning) + Export (No-space/Customs/Cargo-pending/On-track) buckets;
  booking-stage rows shown (BOOKING badge). Filters: station / mode / bound / ISO date window / company-name
  type-ahead / POL / POD / identifier search (job, booking/SO, HBL, MBL, container, PO, **ship-id**, **vessel-flight**).
  Delta refresh (`seed-alerts.ps1 -Delta`, Air ~5 min / Sea ~15 min) keeps it fresh.
- **Cross-station inbound feed** — publish/subscribe fan-in (`publish-bookings.ps1` → `inbound_booking_feed`,
  served by `/api-ops/inbound`); multi-station fan-out per involved office; **OFFSHORE** tag for off-bill roles;
  row-level scoped per station.
- **Draft HBL/HAWB customer review loop** — staff create a draft seeded from the shipment + a bounded ERP read,
  send a tokenized public review link, iterate a field-by-field diff, then **approve → agree → issue** to the live
  Swivel ERP (`/file/upload` BL_REVIEW PDF + `/event/update`), with a headless-Edge auto-PDF.
- **Edit ERP data** — staff data-correction editor → live `/booking/update` (read-merge existence guard,
  per-station `forwarderCode`, AIR full-cargo-block read-merge, HAWB+MAWB sent as a pair). Saved scan columns
  reflect in the worklist immediately.
- **Book Now** — create a booking in the ERP from minimal operator input (auto-generated Ref No, configurable
  format), async via a `BookingPusher` background service draining `book_pending`; shows in New-bookings instantly.
- **Generate document** — drawer box → `/document/generate` for an admin-configured documentTypeCode + houseTypeCode
  (`doc_generate_map`); the PDF returns inline and streams to the browser as a download.
- **ERP document upload (always-on)** — upload any configured doctype; ones that also clear a milestone are flagged.
- **Natural-language Find** — header 🔎 chat (rule parser, optional LLM fallback off by default); resolves
  names→codes (`port_dim`/`liner_dim`/`company_dim`); active + recently-closed, scoped; full worklist-style cards.
  Also exposed as a **third-party JWT-bearer API** (`/api-ops/find-text`, see [8-API.md](docs/8-API.md)).
- **Notes / collaboration** — operator notes in SQL (`dbo.job_note`), @-mentions (team/station-aware roster), My
  Tasks inbox, follow-ups, remind-me with due date.
- **Auth & identity** — SQL-backed `app_user` + `app_user_scope`; sign-in by email (username fallback); the
  `OPS_ALLOW_SEED` first-install guard; SWIVEL L!NK OAuth code-flow seam; JWT bearer for the third-party API.
- **i18n** — English / 中文 / 日本語, client-side, per-user default + per-device picker.
- **Admin console (`admin-ops.html`)** — Users · Milestones & alerts · Documents · Generate documents · ERP API
  (connection editable in-app, LIVE/MOCK) · **Audit & Health** (Health board + Storage) · **Change log** (change &
  access audit / server errors / ERP API calls, date-ranged + capped).
- **Governance / ops** — unified ERP API log (`erp_api_log`), `ops-error.log`, login audit; `backup-ops.ps1`
  (nightly), `ops-healthcheck.ps1` (watchdog, every 25 min, alerts), `purge-ops.ps1` (weekly retention + log
  rotation); `register-ops-tasks.ps1` schedules everything.

## Not yet built

- **`listener-engine.ps1`** (the scheduled listener) — `seed-alerts.ps1 -Delta` stands in.
- **`baseline-refresh.ps1`** (3-yr lane averages backing the `baseline` alert timing) — `baseline` milestones fall
  back to fixed/none until it exists.
- **`pic_user` ↔ app-user mapping**; **PBKDF2 password upgrade**; an **ERP push auto-retry queue** (deferred by choice).

---

## Architecture & key decisions

```
station ERP DBs (READ-ONLY) --seed-alerts.ps1 (listener stand-in) / Task Scheduler--> erpops
                                                                          |  server/ (ASP.NET Core .NET 10, JSON API)
                                                                          v
                                                                      browser (index.html / ops.js / i18n.js)
```

- **Why .NET.** The legacy PowerShell `serve-ops.ps1` was single-threaded for correctness — per-user row-level
  scope lived in shared `$script:` state, so serving concurrently would leak one user's scope into another's query
  (an auth-bypass). The .NET port resolves scope into a **per-request `ReqState`** (the structural fix) and bounds
  concurrent SQL with a **`dbGate` semaphore** (default 16).
- **Two-server mode.** Read the remote `fm3k*` ERP, write `erpops` locally (the network ERP login can't
  `CREATE DATABASE`). Config `opsServer`/`opsAuth`/`opsDb`.
- **Multi-customer = one deploy per customer** — one IIS site + one `ops.config.<tenant>.json` + one `erpops` DB;
  nothing hardcoded.
- **ERP field map verified** against live SQL — see [7-SQL-REFERENCE.md](docs/7-SQL-REFERENCE.md). Reconcile any new
  field against live SQL before trusting it (house rule).
- **Schema:** ~27 tables in `erpops` (idempotent `setup-ops.ps1`); 37 `milestone_def` rows. Full table list +
  ERP field map in [7-SQL-REFERENCE.md](docs/7-SQL-REFERENCE.md).

## Environments

| Env | Source ERP | Ops DB | Web tier | Notes |
|---|---|---|---|---|
| **demoerp** (current) | `fm3k*` on `192.168.5.2` over the Swivel VPN (read-only `dashboard`) | `demoerp` on local `localhost\SQLEXPRESS` (two-server) | .NET on :8079 | Primary working env on this PC. `erpApi.mock` toggled per test. |
| **Network** | live `fm3k*` (two-server) | `erpops_net` (local) | .NET / legacy PS | 12 stations. |
| **Local** | frozen `fibsbkk` snapshot | `erpops` (local) | legacy PS | Historical; sparse fields → skews Red. |

Legacy PowerShell server `serve-ops.ps1` reads the same `erpops` DB and is kept for rollback (`restart-ops-*.bat`).

## How to run

Full matrix in [2-SETUP-NEW-CUSTOMER.md](docs/2-SETUP-NEW-CUSTOMER.md). Quick (demoerp, one command per stage):

```powershell
.\.claude\skills\swivel-vpn\scripts\swivel-vpn.ps1 -Check         # VPN up (remote only)
.\first-install\setup-database.bat -ConfigPath .\ops.config.demoerp.json   # ops DB + all tables + milestone config (detector-guarded)
cd server; $env:OPS_CONFIG='ops.config.demoerp.json'; $env:OPS_ALLOW_SEED='1'; dotnet run -c Release   # .NET web tier (first start seeds default admin)
# ...back in repo root, with the app started:
.\seed-data.bat -ConfigPath .\ops.config.demoerp.json             # live-ERP fill (all stations x Sea/Air)
```

- **Update an existing site:** `update-customer.bat` (see [3-DEPLOY-UPDATES.md](docs/3-DEPLOY-UPDATES.md)). Do **not**
  re-run `first-install\setup-database.bat` on a live site.
- **Restart after a change:** `.cs` → rebuild/restart (`redeploy-demoerp.bat` for IIS); client `.html/.js/.css`
  are static (reload only); legacy PS → `restart-ops-*.bat`.
- **Sanity checks before declaring done:** `.cs` → `dotnet build` (0 warnings); `.ps1` → `[PSParser]::Tokenize`;
  `.js` → `node --check`. Test on a temp port so a running instance isn't disturbed.

---

## Constraints (do not violate)

- **`Packet Size=512`** on every SQL connection string (the VPN's small MTU black-holes default 8 KB TDS packets).
- **The .NET server is multi-threaded** with `dbGate` + per-request `ReqState`. The UI/request paths read only the
  small `erpops` tables, never the ERP; heavy ERP joins happen in `seed-alerts` off the request path. (The legacy
  PS server was single-threaded — that constraint applies only if you run it.)
- **Source ERP DBs are READ-ONLY** — all writes go to `erpops` only. Never `INSERT`/`UPDATE`/`ALTER` an ERP table.
- **Secrets are gitignored** (`ops.config*.json`, `users.json`, `roles.json`, `ops-lists/`, `*.log`, `erp-mock/`,
  `backups/`); verify with `git status` before any commit. Only `*.example.json` is tracked.
- **Read config/JSON with `[IO.File]::ReadAllText`, not `Get-Content -Raw`** — PS 5.1 decodes a BOM-less UTF-8 file
  as ANSI (mojibake `â€”`/`Â·`). Keep `.ps1` source **ASCII-only** (a non-ASCII byte can terminate a string →
  runtime parse error). New HTML pages need `<meta charset="utf-8">`.
- **Cross-DB collation:** the ops DB is Latin1, station DBs are Chinese_HK — text joins across DBs need
  `COLLATE DATABASE_DEFAULT`.
- **Dates are ISO `yyyy-mm-dd` everywhere** — never the locale `mm/dd/yyyy`, and **no native `<input type="date">`**
  (locale format + unwanted calendar popup); use a `text` input with `placeholder="yyyy-mm-dd"` + a regex guard.
- **All SQL is parameterised** (`SqlParameter`/`@name`); route every data read through the row-level scope clause.
- **When killing test servers by command-line match, exclude `$PID`** or you kill your own shell.
- Commit only when asked; never commit secrets.
