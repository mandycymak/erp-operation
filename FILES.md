# FILES.md — what every file in this repo is

A map of the repository so a developer, installer, or maintainer can find their way without guessing. For the
*why* and *how* of each area, follow the links into [`docs/`](docs/) (start at
[`docs/1-OVERVIEW.md`](docs/1-OVERVIEW.md)).

> ⚠️ **Why the root is "flat" (and why files are NOT freely movable).** This app has **no build step**. The .NET
> server serves the client UI and reads its config/field JSON **directly from the repo root**
> (`PhysicalFileProvider(Config.RepoRoot)` + `Path.Combine(RepoRoot, …)`); the `.bat` wrappers call `.ps1` in the
> **same folder** (`%~dp0`); and `register-ops-tasks.ps1` registers Windows scheduled tasks with the **absolute
> path** of each job script. So moving the client files, the config files, or the scheduled job scripts will
> **break a running site or its scheduled tasks**. Only the genuinely standalone first-install scripts were moved
> into [`first-install/`](first-install/). Each group below is tagged **[stays at root]** where moving it would break things.

---

## "Which script do I run?" (the short answer)

| I want to… | Run | Notes |
|---|---|---|
| Set up a **brand-new** customer | `first-install\setup-database.bat` → start app → `seed-data.bat` | First install only. The setup script detects a live DB and refuses by default. See [docs/2-SETUP](docs/2-SETUP-NEW-CUSTOMER.md). |
| **Update** an existing customer (new code) | `update-customer.bat` | The safe, additive path. **Never** re-run the `first-install\` scripts on a live site. See [docs/3-DEPLOY](docs/3-DEPLOY-UPDATES.md). |
| Stand the site up under **IIS** (first time) | `first-install\deploy-local-iis-demoerp.ps1` (elevated) | Recreates the pool/site/env — first install only. |
| Refresh the **worklist data** now | `seed-hkg.bat` (HKG) or `seed-data.bat` (all stations) | Ongoing refresh is scheduled by `register-ops-tasks.ps1`. |
| **Run the app** for dev | `start-dotnet.bat` | Kestrel on the config port. |
| **Redeploy** the demo IIS site after a code change | `redeploy-demoerp.bat` | Demo box only (hardcoded paths). |
| Roll back to the **legacy** PowerShell server | `restart-ops-{demoerp,local,network}.bat` | `serve-ops.ps1`; rollback only. |

---

## Client UI — the browser app  **[stays at root]**

Served flat from the repo root by the .NET server. Static; edit + reload, no rebuild. See [docs/5-BUSINESS-GUIDE](docs/5-BUSINESS-GUIDE.md) / [docs/6-DEVELOPER-GUIDE](docs/6-DEVELOPER-GUIDE.md).

- `index.html`, `ops.js`, `styles.css` — the worklist / drawer / My-Tasks / Find UI.
- `login.html` — sign-in page.
- `admin-ops.html` — admin console (Users / Milestones / Documents / Generate / ERP API / Audit & Health / Change log).
- `erp-edit.html`, `erp-edit.js`, `erp-edit-fields.json` — staff "Edit ERP data" editor + its field dictionary.
- `doc-editor.html`, `doc-editor.js` — staff draft-document editor.
- `bl-review.html`, `bl-review.js`, `bl-review.css`, `bl-form.js` — the public customer draft-review page + shared bill renderer.
- `doc-fields.json` — the draft HBL/HAWB layout dictionary (read by both the client and the server's PDF render).
- `i18n.js`, `lang/` — localization layer + `zh-Hans` / `ja` dictionaries.

## Web server (.NET — current) and how to run it

- `server/` — the **ASP.NET Core (.NET 10)** web tier (`Program.cs`, `Config.cs`, `Auth.cs`, `Handlers.*.cs`, …). The compiled app. See [docs/6-DEVELOPER-GUIDE](docs/6-DEVELOPER-GUIDE.md).
- `start-dotnet.bat` — dev run (`dotnet run` on the config port).
- `redeploy-demoerp.bat` — republish + recycle the demo IIS site (demo paths hardcoded).

## Web server (legacy PowerShell — rollback only)  **[stays at root]**

- `serve-ops.ps1` — the original single-threaded HttpListener server, kept for rollback. Reads the same `erpops` DB.
- `restart-ops-demoerp.bat` / `restart-ops-local.bat` / `restart-ops-network.bat` — start `serve-ops.ps1` for each config/port.
- `erp-doc-api.ps1` — the Swivel ERP API client used by the legacy server (Issue / Edit-ERP push, file up/download).

## First install  →  [`first-install/`](first-install/)

- `first-install/setup-database.bat` — create the ops DB + all tables + milestone config (detector-guarded).
- `first-install/deploy-local-iis-demoerp.ps1` — one-time elevated IIS bootstrap (confirmation-guarded).
- `first-install/check-installed.ps1` — read-only "is this DB already a live customer?" detector.
- `first-install/README.md` — what these are + when (and when NOT) to run them.

## Schema + routine update  **[stays at root — shared by install and update]**

- `setup-ops.ps1` — creates/migrates the `erpops` schema, **idempotent + additive** (never drops data). Called by both `first-install\setup-database.bat` and `update-customer.bat`.
- `seed-milestone-config.ps1` — seeds the 37 milestone definitions (insert-missing-only; `-Force` to reset).
- `update-customer.bat` — **the routine update path** (offline → schema migrate → milestone insert → publish → recycle → verify).
- `verify-customer.ps1` — read-only post-deploy check (prints the resolved DB + user/table/shipment counts; non-zero if `app_user` is empty).

## Data jobs (off the request path)  **[stays at root — scheduled by absolute path]**

Read the read-only source ERP, write `erpops`. Registered by `register-ops-tasks.ps1` via `Join-Path $PSScriptRoot`, and the resulting scheduled tasks store these scripts' absolute paths — **moving them breaks deployed tasks**.

- `seed-alerts.ps1` — the listener stand-in (worklist evaluator/upsert; `-Delta` for incremental refresh).
- `seed-data.ps1` + `seed-data.bat` — initial full fill: station map / ports / liners / inbound feed / worklist, all stations × Sea/Air.
- `seed-hkg.bat` — one-click HKG Sea+Air delta refresh.
- `publish-bookings.ps1` — cross-station inbound feed publisher.
- `watch-bookings.ps1` — new-booking → factory-alert watcher.
- `seed-station-map.ps1`, `seed-ports.ps1`, `seed-liners.ps1` — reference-dimension seeders.
- `ops-eval.ps1` — the milestone evaluator (used by the seeders).
- `eval-shipment.ps1` — read-only one-shot diagnostic for a single shipment.

## Governance / scheduling  **[stays at root]**

- `register-ops-tasks.ps1` — registers every scheduled task (publishers, worklist delta, booking watch, backup, healthcheck, purge). Run **elevated**.
- `backup-ops.ps1` — nightly ops-DB `.bak` + secrets copy.
- `ops-healthcheck.ps1` — watchdog (health checks + alerts).
- `purge-ops.ps1` — retention / aging + log rotation.

## Config & secrets  **[stays at root — read from RepoRoot]**

Gitignored except the `*.example` templates. Never commit the real ones.

- `ops.config.example.json` — config template (copy to `ops.config.<tenant>.json`).
- `ops.config.<tenant>.json` (e.g. `ops.config.demoerp.json`) — per-site config (gitignored).
- `users.example.json` / `users.json` — legacy user template / one-time import backup (live users are in SQL).
- `erp-api-map.json` — non-secret ERP deployment codes (tracked).

## Generated at runtime (gitignored)

- `*.log` (`admin-audit.log`, `ops-error.log`, `ops-health.log`, `ops-backup.log`) — audit / error / ops logs.
- `erp-mock/` — mock ERP payloads (mock mode).
- `backups/` — `backup-ops.ps1` output (`.bak` + secrets copies).

## Docs & design

- `README.md` — repo landing page.
- `docs/` — the stage-numbered guides (`1-OVERVIEW` … `8-API`) + `docs/_archive/`.
- `BLUEPRINT.md` — the approved design-of-record.
- `PROJECT-SUMMARY.md` — current status snapshot (full history archived under `docs/_archive/`).
- `CLAUDE.md` — project context/constraints for Claude Code.
- `milestone.md` — the end-user milestone-matrix reference.
- `FILES.md` — this file.

## Other

- `reusable/` — the extracted master-lookup module (drop-in for sibling projects).
- `tools/` — testers (`find-chat.html`, `find-api-test.ps1`, `parity-check.ps1`) and `tools/loadtest/` (the Book Now concurrency/throughput test + its `results/`).
