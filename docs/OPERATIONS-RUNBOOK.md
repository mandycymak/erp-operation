# Control Tower - Operations & Support Runbook

For the IT / support team running the app **after** go-live. Deployment is one-time (see
`docs/ONBOARD-CHECKLIST.md`); **support is ongoing** - this is how you keep it healthy, prove who did what, control
data growth, patch safely, and know the moment something breaks.

**The one habit:** open **Admin -> Audit & Health** in the app. Everything below is visible there without a database
login. Drop to SQL / log files only when you need to go deeper.

---

## 1. The daily glance (two admin tabs)

All read-only, admin-only. The light "at-a-glance" view and the heavy record lists are deliberately separate so a
busy day or an error storm can't swamp the page.

**Tab "Audit & Health"** - the daily glance:

| Section | Answers | What "good" looks like |
|---|---|---|
| **Health** | Is anything broken right now? Did it recover? | every check green; a red row with a recent **last OK** = it recovered |
| **Storage & growth** | Is the database growing toward a problem? | DB size flat/slow; free disk well above the warn line |

**Tab "Change log"** - the detailed records (each bounded by a **date range**, default *today*, and **capped**
server-side; a `truncated` notice means "narrow the range"):

| Section | Answers | What "good" looks like |
|---|---|---|
| **Change & access audit** | Who changed what / who logged in? (source selector: changes & logins / ERP edits / documents / milestones) | every change attributable to a user + time |
| **Server errors** | What failed server-side, in the chosen window? | empty, or only benign 404s |

The **Health** rows are written by the watchdog (`ops-healthcheck.ps1`, every 25 min) into `health_check_log`. A
check that fails then later passes leaves both rows, so you can see a problem **and** confirm the fix - the support
follow-up trail. Checks: `app` (HTTP), `db`, `tasks` (scheduled-job results), `feed` (worklist freshness),
`backup` (newest .bak age), `storage:db`, `storage:disk`, `erp-vpn` (TCP 1433 to the ERP).

---

## 2. "How do we know it broke?" - alerting

When any watchdog check fails it (a) writes a red row to the Health board, (b) appends to `ops-health.log`, and
(c) sends an alert to the channel in the config `alerts` block - a **Teams/Slack webhook** (`alerts.webhookUrl`)
and/or **email** (`alerts.smtp`). The job's non-zero exit also shows as a failed task in Task Scheduler.

- Configure the channel in `ops.config.<tenant>.json` -> `alerts` (see `ops.config.example.json`). Empty = log only.
- Test it: `.\ops-healthcheck.ps1 -ConfigPath .\ops.config.<tenant>.json` and confirm a message arrives.
- **Escalation:** an `app`/`db` red = the app is down for users -> page on-call. A `feed` red = the worklist is
  stale (a seed job stalled) -> the data is old but the app works. `backup`/`storage` red = attend same day.

---

## 3. Log map (where everything is recorded)

All under `<OPS_ROOT>`. Rotated by `purge-ops.ps1` when over the size cap (default 16 MB, keeps 6 archives).

| Log / table | What | Read it via |
|---|---|---|
| `admin-audit.log` | user CRUD, milestone/ERP-settings edits, doc lifecycle, **logins + failed logins** | Change log -> "All changes & logins" |
| `ops-error.log` | every server-side exception (id, route, stack) | Change log -> "Server errors" |
| `ops-health.log` | watchdog failures (what alerted, when) | file |
| `ops-backup.log` | each backup run + prune result | file |
| `dbo.erp_edit_log` | ERP data corrections, **before -> after** per field | Change log -> "ERP data edits" |
| `dbo.erp_api_log` | **every** Swivel ERP API call (read & write): endpoint, result, error, timing, corr id | Change log -> "ERP API calls" |
| `dbo.doc_event_log` | draft document lifecycle (incl. customer IP) | Change log -> "Documents" |
| `dbo.milestone_event_log` | every milestone state change | Change log -> "Milestones" |
| `dbo.app_user` / `app_user_scope` | logins, roles, row-level scope (SQL is the source of truth) | Admin -> Users |
| `dbo.booking_alert` | new-booking -> factory(shipper) alerts: contact, lane, status, channel | SQL (`watch-bookings.ps1`) |
| `dbo.alert_watermark` | per-station delta high-water for the worklist refresh | SQL |
| `dbo.health_check_log` | watchdog results / history | Audit & Health -> Health board |
| IIS `logs\stdout`, Windows Event Log | ANCM startup failures (app won't start) | server |

---

## 4. Troubleshooting playbook

Start at the **Audit & Health** tab (health/storage) or **Change log** tab (records); go to SQL/logs only if needed.

- **App down / users see errors** -> Health `app`/`db` red. Check the app pool is started
  (`Get-WebAppPoolState`), the VPN is up (`erp-vpn` check), and the DB is reachable. `web.config` / Hosting Bundle
  problems show in the Windows Event Log + IIS `logs\stdout`.
- **"semaphore timeout" / transport errors** -> the VPN MTU. Every connection already uses `Packet Size=512`; if it
  reappears the VPN is flapping - check the tunnel, not the app.
- **A user reports a 500** -> ask for the time; set the **Change log -> Server errors** date range to that day and
  find it by the correlation id / route, read the stack. (A sudden spike of errors is bounded by the range + cap so
  the page stays usable - a `truncated` notice means narrow the window.)
- **ERP Save failed** -> **Change log -> ERP data edits**: the row shows `erp_status` (rejected/error) and
  `erp_error` with the ERP's message, plus the before->after fields.
- **"Which ERP API errored?" / a push or file upload/download didn't work** -> **Change log -> ERP API calls**,
  tick **failures only**. Every Swivel call is logged with its endpoint, HTTP status, the ERP's error message, and
  timing; rows sharing a **corr** id are one operation (e.g. an agree = `/booking/get` + `/booking/update`). Hover a
  row for the request/response. (Mock-mode calls are not logged - they never hit the ERP.) **No automatic retry**
  yet: a transient failure must be re-attempted from the UI.
- **Worklist looks stale** -> the worklist refreshes by **delta** (`seed-alerts.ps1 -Delta`): Air every ~5 min,
  Sea every ~15 min, per `Ops Worklist *` tasks. Check the task ran (Task Scheduler History / `LastTaskResult`) and
  that `dbo.alert_watermark` is advancing for that station/mode. To force a catch-up, run `seed-alerts.ps1 -Delta`
  for the station, or re-run the **full backfill** (without `-Delta`) if the watermark looks wrong. Tune the cadence
  with `register-ops-tasks.ps1 -WorklistAirMins / -WorklistSeaMins`. (Edits to shipments older than the first-run
  `-WindowDays` window are picked up via `upddate` on the next run; a one-off full backfill re-syncs everything.)
- **Factory didn't get a booking alert** -> check `dbo.booking_alert` for the booking (deduped by ERP ref): `status`
  shows pending/notified/failed and `channel` shows how it fired. Recording happens even with `bookingAlert.enabled`
  off (no send); to actually notify, set `bookingAlert.enabled=true` (+ `alerts.webhookUrl`/`smtp`, and
  `emailFactory=true` to email the shipper directly). `factory_email` blank = the customer master (`custsub`) has no
  email for that shipper.
- **Login problems / suspicious access** -> **Change log -> All changes & logins** shows `login ok` /
  `login FAILED` with IP. Repeated failures from one IP = brute-force; the account is unaffected (failures never
  create a session).

---

## 5. Data retention & growth (will storage be a problem?)

**Short answer:** no, once the retention job runs - and you can watch it on the **Storage & growth** tab.

The schema was designed to stay small (it holds only *active* operational state), but the aging was not enforced
until `purge-ops.ps1` (weekly `Ops Purge`). Tables fall into two groups:

- **Bounded** (refreshed in place, do not accumulate): the reference dimensions (`port_dim`, `liner_dim`,
  `company_dim`, `station_dim`, `station_route_map`), the config tables, and - **once purge runs** -
  `shipment_alerts` and `inbound_booking_feed` (rows not refreshed within the horizon are aged out / deleted).
- **Growing** (append-only, trimmed to a horizon by purge): the event/audit logs (`milestone_event_log`,
  `doc_event_log`, `erp_edit_log`), `health_check_log`, and **document attachments** (`doc_attachment`, blobs up to
  ~5 MB each, stored in the DB) - the single biggest per-row driver.

**Horizons** (config `retention`, with defaults): `staleDays 21` (a worklist row not refreshed in 21 days is marked
`closed`), `retainClosedDays 180` (closed/void deleted after ~6 months - kept >= the Find "recently-closed" window
so search isn't starved), `retainFeedDays 120`, `auditRetainMonths 24` (audit history), `healthRetainDays 90`,
`attachPurgeDays 60` (only **soft-deleted** attachments are reclaimed; **live attachments are never auto-deleted** -
legal retention). Tune these to the customer's / auditor's policy; they are pure config.

**How to know:** the **Storage & growth** tab shows DB size, the largest tables, total attachment bytes (and
reclaimable soft-deleted bytes), log-file sizes, and free disk. The watchdog raises an alert past
`dbSizeWarnMb` / `diskFreeWarnMb`. Preview a purge without changing data: `.\purge-ops.ps1 -ConfigPath ... -WhatIf`.

---

## 6. Backup & restore

- **Backup:** nightly `Ops Backup` runs `backup-ops.ps1` -> a dated `.bak` of the ops DB (COPY_ONLY, so it never
  disturbs a DBA's own backup chain) + a copy of the gitignored secrets (`ops.config.<tenant>.json`, `users.json`,
  `erp-api-map.json`) into `<OPS_ROOT>\backups`, pruned after `-RetainDays` (14). Failure -> non-zero exit ->
  watchdog `backup` red + alert. The `.bak` path must be writable by the **SQL service account** (not the app pool).
- **Restore (DB):**
  ```sql
  RESTORE DATABASE [<opsDb>] FROM DISK = N'<OPS_ROOT>\backups\<opsDb>_<date>.bak' WITH REPLACE, RECOVERY;
  ```
  Then recycle the app pool and confirm `/api-ops/health` -> `db:up`.
- **Restore (secrets / whole box lost):** copy `ops.config.<tenant>.json`, `users.json`, `erp-api-map.json` from the
  newest `backups\secrets_<date>\` back into `<OPS_ROOT>`, re-publish the app, recycle the pool. The source ERP is
  read-only and untouched, so only the ops DB + these files are ever at risk.

---

## 7. Patching a customer safely (redeploy + rollback)

The app is compiled - a code change means re-publish + recycle (the client `.html/.js/.css` are static, browser
reload only). Patch **one tenant first**, watch it, then the rest.

### 7a. The one-command routine update

For a normal update (new program code, and/or new tables/columns), run **`update-customer.bat`** on the server. Set
`ROOT` / `CONFIG` / `POOL` at the top of the bat (or as env vars). It runs only the **safe, additive** steps and
self-verifies:

1. app offline → 2. `setup-ops.ps1` (additive schema - never overwrites users/roles/`app_setting`/data) →
3. `seed-milestone-config.ps1` (**insert-missing-only** - preserves admin-edited milestones; `-Force` resets to
defaults) → 4. `dotnet publish` in place + recycle the pool → 5. `verify-customer.ps1` (prints the resolved
`Server`/`Database` + **user / table / milestone counts**).

**Read the verify line.** If it shows `app_user: 0 users` it stops with a red *"pointed at the WRONG/FRESH
database"* warning - the app's `OPS_CONFIG`/`OPS_ROOT` are off, **not** data loss. Fix the env vars and recycle;
do not re-seed. After every update, confirm your real users still appear in **Admin → Users**.

**Do NOT** run `setup-database.bat` or `deploy-local-iis-demoerp.ps1` on a live site - those are the **first-install**
path (they recreate the pool/env and, with `OPS_ALLOW_SEED=1`, re-seed the default admin). Updates never need them.
If the update added a new worklist **scan column**, run `seed-data.bat` afterward to backfill old rows (kept separate
because it re-pulls operational data).

> **Why users can "disappear" after a deploy** (and why they can't now): the connection string is assembled at
> startup from `OPS_CONFIG`/`OPS_ROOT`. A redeploy that loses those env vars or lands in a fresh folder points the app
> at a different/empty DB; the old behaviour then silently re-seeded `admin/admin123`. The **`OPS_ALLOW_SEED` guard**
> (off by default) now makes that case **fail loudly** instead, and the startup log line
> `[Config] ops DB target: Server=…; Database=…` shows exactly which DB opened.

### 7b. Manual redeploy / rollback

1. On the build box: `dotnet publish -c Release -o publish_new` (a NEW folder - keep the running `publish` for rollback).
2. On the server: `"offline" > publish\app_offline.htm` (the app releases its files), swap `publish_new` -> `publish`
   (or repoint the site physical path), delete `app_offline.htm`, `Restart-WebAppPool <pool>`.
3. **Smoke test:** `/api-ops/health` 200 -> login -> one worklist read -> reconcile one milestone vs ERP SQL.
4. **Rollback:** repoint the site to the previous `publish` folder + recycle. (Keep the last good publish around.)

Pool **environment variables** carry the config (`OPS_ROOT`/`OPS_CONFIG`/...). `dotnet publish` regenerates
`web.config`, so never store settings there - set them on the app pool (the deploy script does).

---

## 8. Deployment model - IIS vs containers (decision)

**Recommendation: stay on IIS for go-live.** The app is structurally coupled to Windows - IIS/ANCM in-process
hosting, Windows **Task Scheduler** for the jobs, **NTFS** permissions on `OPS_ROOT`, a **headless Edge/Chrome** for
PDF, **in-process sessions**, and a small-MTU **VPN** that forces `Packet Size=512`. A container would have to be a
**Windows** container and would still need the VPN, the scheduled jobs, and a browser solved out-of-band - high
effort, little benefit today. Tenancy is already clean without containers: one IIS site + one config + one ops DB
per customer, nothing hardcoded.

**Revisit containers only when** you need multi-host scale-out (then move sessions to a sticky/external store - the
handlers won't change) or a standardized CI/CD image-promotion pipeline. Note those prerequisites before committing.

---

## 9. SQL Server version changes

The schema uses only standard DDL (idempotent `IF OBJECT_ID ... CREATE`); no version-locked feature. SQL Express is
supported but has **no SQL Agent**, which is why the jobs run under **Windows Task Scheduler**. After any SQL Server
upgrade or a move to a new instance, re-test: (1) connectivity still works with `Packet Size=512`; (2) the cross-DB
**Latin1 <-> Chinese_HK** text joins still resolve (`COLLATE DATABASE_DEFAULT` is already in the queries); (3) run
`.\ops-healthcheck.ps1` and confirm all green. Then take a fresh backup.

---

## 10. Quick reference - the governance jobs

| Task (Task Scheduler) | Script | Cadence | Purpose |
|---|---|---|---|
| `Ops Healthcheck` | `ops-healthcheck.ps1` | every 25 min | health checks -> `health_check_log` + alert on failure |
| `Ops Backup` | `backup-ops.ps1` | nightly 02:00 | ops DB `.bak` + secrets copy + prune |
| `Ops Purge` | `purge-ops.ps1` | weekly Sun 04:00 | retention/aging + log rotation |

All three are registered by `register-ops-tasks.ps1` (elevated). Run any of them by hand for an immediate check;
each exits non-zero on failure so a manual run and the scheduler agree.
