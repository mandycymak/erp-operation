# Stage 3 — Operate & support (after go-live)

For the IT / support team running the app **after** go-live. First install is [2-SETUP-NEW-CUSTOMER.md](2-SETUP-NEW-CUSTOMER.md);
pushing updates is [3-DEPLOY-UPDATES.md](3-DEPLOY-UPDATES.md). **Support is ongoing** — this is how you keep it
healthy, prove who did what, manage users, control data growth, and know the moment something breaks.

**The one habit:** open **Admin → Audit & Health** in the app. Almost everything below is visible there without a
database login. Drop to SQL / log files only when you need to go deeper.

---

## 1. The daily glance (two admin tabs)

All read-only, admin-only. The light "at-a-glance" view and the heavy record lists are deliberately separate so a
busy day or an error storm can't swamp the page.

**Tab "Audit & Health"** — the daily glance:

| Section | Answers | What "good" looks like |
|---|---|---|
| **Health** | Is anything broken right now? Did it recover? | every check green; a red row with a recent **last OK** = it recovered |
| **Storage & growth** | Is the database growing toward a problem? | DB size flat/slow; free disk well above the warn line |

**Tab "Change log"** — the detailed records (each bounded by a **date range**, default *today*, and **capped**
server-side; a `truncated` notice means "narrow the range"):

| Section | Answers | What "good" looks like |
|---|---|---|
| **Change & access audit** | Who changed what / who logged in? (selector: changes & logins / ERP edits / documents / milestones) | every change attributable to a user + time |
| **Server errors** | What failed server-side, in the chosen window? | empty, or only benign 404s |
| **ERP API calls** | Every Swivel ERP call (read & write) with its result | tick *failures only* to see just errors |

The **Health** rows are written by the watchdog (`ops-healthcheck.ps1`, every 25 min) into `health_check_log`. A
check that fails then later passes leaves both rows, so you can see a problem **and** confirm the fix. Checks:
`app` (HTTP), `db`, `tasks` (scheduled-job results), `feed` (worklist freshness), `backup` (newest .bak age),
`storage:db`, `storage:disk`, `erp-vpn` (TCP 1433 to the ERP).

---

## 2. "How do we know it broke?" — alerting

When any watchdog check fails it (a) writes a red row to the Health board, (b) appends to `ops-health.log`, and
(c) sends an alert to the channel in the config `alerts` block — a **Teams/Slack webhook** (`alerts.webhookUrl`)
and/or **email** (`alerts.smtp`). The job's non-zero exit also shows as a failed task in Task Scheduler.

- Configure the channel in `ops.config.<tenant>.json` → `alerts` (see `ops.config.example.json`). Empty = log only.
- Test it: `.\ops-healthcheck.ps1 -ConfigPath .\ops.config.<tenant>.json` and confirm a message arrives.
- **Escalation:** `app`/`db` red = the app is down for users → page on-call. `feed` red = the worklist is stale (a
  seed job stalled) → data is old but the app works. `backup`/`storage` red = attend same day.

---

## 3. Log map (where everything is recorded)

All under `<OPS_ROOT>`. Rotated by `purge-ops.ps1` when over the size cap (default 16 MB, keeps 6 archives).

| Log / table | What | Read it via |
|---|---|---|
| `admin-audit.log` | user CRUD, milestone/ERP-settings edits, doc lifecycle, **logins + failed logins** | Change log → "All changes & logins" |
| `ops-error.log` | every server-side exception (id, route, stack) | Change log → "Server errors" |
| `ops-health.log` | watchdog failures (what alerted, when) | file |
| `ops-backup.log` | each backup run + prune result | file |
| `dbo.erp_edit_log` | ERP data corrections, **before → after** per field | Change log → "ERP data edits" |
| `dbo.erp_api_log` | **every** Swivel ERP API call (read & write): endpoint, result, error, timing, corr id | Change log → "ERP API calls" |
| `dbo.doc_event_log` | draft document lifecycle (incl. customer IP) | Change log → "Documents" |
| `dbo.milestone_event_log` | every milestone state change | Change log → "Milestones" |
| `dbo.app_user` / `app_user_scope` | logins, roles, row-level scope (SQL is the source of truth) | Admin → Users |
| `dbo.booking_alert` | new-booking → factory(shipper) alerts: contact, lane, status, channel | SQL (`watch-bookings.ps1`) |
| `dbo.alert_watermark` | per-station delta high-water for the worklist refresh | SQL |
| `dbo.health_check_log` | watchdog results / history | Audit & Health → Health board |
| IIS `logs\stdout`, Windows Event Log | ANCM startup failures (app won't start) | server |

---

## 4. Troubleshooting playbook

Start at the **Audit & Health** tab (health/storage) or **Change log** tab (records); go to SQL/logs only if needed.

- **App down / users see errors** → Health `app`/`db` red. Check the app pool is started (`Get-WebAppPoolState`),
  the VPN is up (`erp-vpn` check), and the DB is reachable. `web.config` / Hosting Bundle problems show in the
  Windows Event Log + IIS `logs\stdout`.
- **"semaphore timeout" / transport errors** → the VPN MTU. Every connection already uses `Packet Size=512`; if it
  reappears the VPN is flapping — check the tunnel, not the app (see [2-SETUP §VPN](2-SETUP-NEW-CUSTOMER.md#vpn--the-swivel-tunnel)).
- **"ERP lookup failed: … pre-login handshake … wait operation timed out"** (opening Edit ERP data / detail drawer)
  → the VPN's SSL handshake was slower than the connect timeout (source-ERP `Connect Timeout` is 15 s). If it still
  times out the **tunnel itself is slow/down** — check the VPN.
- **`Test-NetConnection 192.168.5.2` fails** → Surfshark route black-hole — run `swivel-vpn -Fix`.
- **A user reports a 500** → ask for the time; set **Change log → Server errors** to that day and find it by
  correlation id / route, read the stack. (Bounded by range + cap; a `truncated` notice means narrow the window.)
- **ERP Save failed** → **Change log → ERP data edits**: the row shows `erp_status` (rejected/error) + `erp_error`
  (the ERP's message), plus the before→after fields.
- **"Which ERP API errored?" / a push or file upload/download didn't work** → **Change log → ERP API calls**, tick
  **failures only**. Rows sharing a **corr** id are one operation (an agree = `/booking/get` + `/booking/update`).
  Hover a row for the request/response. (Mock-mode calls are not logged.) **No automatic retry** yet — re-attempt
  from the UI.
- **Worklist looks stale** → the worklist refreshes by **delta** (`seed-alerts.ps1 -Delta`): Air ~5 min, Sea ~15
  min, per `Ops Worklist *` tasks. Check the task ran (Task Scheduler History / `LastTaskResult`) and that
  `dbo.alert_watermark` is advancing for that station/mode. To force a catch-up, run `seed-alerts.ps1 -Delta` for
  the station (or `seed-hkg.bat` for HKG), or re-run the **full backfill** (no `-Delta`) if the watermark looks
  wrong. Tune cadence with `register-ops-tasks.ps1 -WorklistAirMins / -WorklistSeaMins`.
- **`Invalid object name 'dbo.doc_draft'`** (or similar missing table) → the ops DB predates a feature; re-run
  `setup-ops.ps1` (or `update-customer.bat`).
- **Issue shows "(MOCK mode)" / nothing in the ERP** → no `erpApi` block / blank token — set Base URL + token in
  **Admin → ERP API** (untick mock) or in `ops.config.*.json`.
- **Event posted but no PDF attachment** → no headless browser, or the operator picked their own (empty) file.
  Install Edge/Chrome or set `pdfEngine`.
- **`/file/upload` rejected** → `documentTypeCode` (`BL_REVIEW`) not in the ERP Document Type master.
- **Factory didn't get a booking alert** → check `dbo.booking_alert` (deduped by ERP ref): `status` shows
  pending/notified/failed, `channel` shows how it fired. Recording happens even with `bookingAlert.enabled` off; to
  send, set `bookingAlert.enabled=true` (+ `alerts.webhookUrl`/`smtp`, and `emailFactory=true` to email the shipper).
- **Login problems / suspicious access** → **Change log → All changes & logins** shows `login ok` / `login FAILED`
  with IP. Repeated failures from one IP = brute-force; the account is unaffected (failures never create a session).
- **Mojibake (`â€”`) on screen** → a config/JSON file read with `Get-Content` instead of `[IO.File]::ReadAllText`
  (already handled in code; keep new `.ps1` ASCII-only).

---

## Managing user accounts & roles

Sign in as an **admin** and open the **Admin** link. `admin-ops.html` has these tabs:

- **Users** — add/edit logins, with a live search over name/email/station/team/ERP-name (built for ~500 users).
  **Email is the required, unique sign-in key**; a **Sign-in** column shows each user's method. Logins/roles/scope
  live in **SQL** (`dbo.app_user` + `dbo.app_user_scope`) — **not** a JSON file. Passwords are stored hashed
  (`SHA256("salt:password")`). Each record carries `stations[]`, `access[]` (`Sea-Export`…), `teams[]`, `admin`,
  **`authProvider`** (`local` | `swivel` | `both`), a **`language`** default, and the **ERP usernames** it owns
  (free-text ERP `pic_user` values). Admin/manager see everything.
- **Milestones & alerts** — CRUD over `milestone_def`: name, mode/bound/seq/phase, active, and the **alert timing**
  (`baseline` / fixed offset / `none`) that drives every operator's Green/Amber/Red. Edits apply at a shipment's
  **next evaluation run**, not retroactively.
- **Documents** — CRUD over the `milestone_evidence_map` doctype rows (the **ERP Document Type codes**). These
  populate the drawer's **ERP-files upload** picker; the ones that also **clear a milestone** are flagged with `*`.
  Keep these matched to the ERP Document Type master, or `/file/upload` is rejected.
- **Generate documents** — CRUD over `doc_generate_map`: the **documentTypeCode + houseTypeCode** pairs (per module
  AIR/SEA) an operator may generate from a shipment. Both codes are sent **verbatim** to `/document/generate`, so
  they must match the ERP exactly. Changes apply immediately (cached, no restart).
- **ERP API** — the ERP **connection**, editable at the customer site with no file edit / no restart: **Base URL**,
  the **bearer token** (write-only — masked, never returned), the **mock** toggle, and the **Customer review link
  base URL** (`publicBaseUrl`) — stored in `dbo.app_setting`, overriding the config at runtime, with a **LIVE /
  MOCK** indicator. Plus the non-secret ERP identity codes (`partyGroupCode`, fallback `forwarderCode`). See the
  ERP-API connection reference in [2-SETUP-NEW-CUSTOMER.md](2-SETUP-NEW-CUSTOMER.md#erp-api-connection).

**Auth model.** Users **sign in by email + password** (a username also works as a fallback). The **`username` is
the internal identity** (notes, @-mentions, sessions, scope, the ERP-username bridge) — email is only the
credential. Because a user always exists after bootstrap, the app is in **real-auth mode** in production; the old
"open/demo" mode (every visitor auto-admin) never triggers unless someone manually empties the table.

> 🔑 A `swivel` user has no local password — it signs in only via SWIVEL L!NK. A `local` user can be matched by
> L!NK too (federation is by email), so `both` is common once L!NK is live.

### SWIVEL L!NK sign-on (OAuth code flow)

The app can be embedded in **SWIVEL L!NK** as an iframe; L!NK signs the user in via OAuth **code flow**, federated
on **email**. It is **inert until configured** — set the redeem URL:

```
SWIVEL_OAUTH_PROFILE_URL=https://auth.swivelsoftware.asia/api/oauth/profile   # env (or config swivelLink.profileUrl)
SWIVEL_OAUTH_XSYSTEM=360uat                                                    # only for a uat-stage L!NK
```

or the `swivelLink` config block (`profileUrl`, `xSystem`, `autoProvision`, `defaultRole`). When enabled,
`/api-ops/config` reports `linkEnabled:true`. L!NK opens
`index.html?mode={light|dark}&site={CODE}#code={CODE}&state={STATE}`; the page POSTs the one-time `code`/`state` to
`/api-ops/link-oauth-login`, which redeems the code **server-side** (no client_id/secret), verifies `state`,
matches `profile.email` to a user (auto-provisions a `defaultRole` user if `autoProvision`), and mints the app's
own session. For the iframe, set `OPS_IFRAME=1` so `ops_sid` is `SameSite=None; Secure; Partitioned`. Register
this app's redirect origin with Swivel.

---

## Patching safely

The one-command routine update and the manual redeploy/rollback are in [3-DEPLOY-UPDATES.md](3-DEPLOY-UPDATES.md).
In short: `update-customer.bat` does the safe additive sequence (schema migrate + insert-missing milestones +
publish + verify) and confirms users are intact. **Never** run the first-install scripts on a live site.

---

## Data retention & growth

**Short answer:** storage stays bounded once the retention job runs — watch it on the **Storage & growth** tab.

The schema holds only *active* operational state, but aging is enforced by `purge-ops.ps1` (weekly `Ops Purge`):

- **Bounded** (refreshed in place): the reference dimensions (`port_dim`, `liner_dim`, `company_dim`, `station_dim`,
  `station_route_map`), the config tables, and — once purge runs — `shipment_alerts` and `inbound_booking_feed`
  (rows not refreshed within the horizon are aged out / deleted).
- **Growing** (append-only, trimmed to a horizon): the event/audit logs (`milestone_event_log`, `doc_event_log`,
  `erp_edit_log`), `health_check_log`, and **document attachments** (`doc_attachment`, blobs up to ~5 MB each in
  the DB) — the biggest per-row driver.

**Horizons** (config `retention`, with defaults): `staleDays 21` (a worklist row not refreshed in 21 days → `closed`),
`retainClosedDays 180` (closed/void deleted after ~6 months — kept ≥ the Find "recently-closed" window),
`retainFeedDays 120`, `auditRetainMonths 24`, `healthRetainDays 90`, `attachPurgeDays 60` (only **soft-deleted**
attachments are reclaimed; **live attachments are never auto-deleted** — legal retention). Tune to the auditor's
policy; they are pure config. Preview without changing data: `.\purge-ops.ps1 -ConfigPath ... -WhatIf`.

---

## Backup & restore

- **Backup:** nightly `Ops Backup` runs `backup-ops.ps1` → a dated `.bak` of the ops DB (COPY_ONLY, so it never
  disturbs a DBA's own chain) + a copy of the gitignored secrets (`ops.config.<tenant>.json`, `users.json`,
  `erp-api-map.json`) into `<OPS_ROOT>\backups`, pruned after `-RetainDays` (14). Failure → non-zero exit →
  watchdog `backup` red + alert. The `.bak` path must be writable by the **SQL service account** (not the app pool).
- **Restore (DB):**
  ```sql
  RESTORE DATABASE [<opsDb>] FROM DISK = N'<OPS_ROOT>\backups\<opsDb>_<date>.bak' WITH REPLACE, RECOVERY;
  ```
  Then recycle the app pool and confirm `/api-ops/health` → `db:up`.
- **Restore (secrets / whole box lost):** copy `ops.config.<tenant>.json`, `users.json`, `erp-api-map.json` from
  the newest `backups\secrets_<date>\` back into `<OPS_ROOT>`, re-publish, recycle. The source ERP is read-only and
  untouched, so only the ops DB + these files are ever at risk.

---

## Deployment model — IIS vs containers (decision)

**Recommendation: stay on IIS for go-live.** The app is structurally coupled to Windows — IIS/ANCM in-process
hosting, Windows **Task Scheduler** for the jobs, **NTFS** permissions on `OPS_ROOT`, a **headless Edge/Chrome** for
PDF, **in-process sessions**, and a small-MTU **VPN** forcing `Packet Size=512`. A container would have to be a
**Windows** container and would still need the VPN, the scheduled jobs, and a browser solved out-of-band — high
effort, little benefit today. Tenancy is already clean: one IIS site + one config + one ops DB per customer.

**Revisit containers only when** you need multi-host scale-out (then move sessions to a sticky/external store — the
handlers won't change) or a standardized CI/CD image-promotion pipeline.

---

## SQL Server version changes

The schema uses only standard DDL (idempotent `IF OBJECT_ID … CREATE`); no version-locked feature. SQL Express is
supported but has **no SQL Agent**, which is why the jobs run under **Windows Task Scheduler**. After any SQL Server
upgrade or move, re-test: (1) connectivity still works with `Packet Size=512`; (2) the cross-DB **Latin1 ↔
Chinese_HK** text joins still resolve (`COLLATE DATABASE_DEFAULT` is in the queries); (3) run `.\ops-healthcheck.ps1`
and confirm all green. Then take a fresh backup.

---

## Quick reference — the governance jobs

| Task (Task Scheduler) | Script | Cadence | Purpose |
|---|---|---|---|
| `Ops Healthcheck` | `ops-healthcheck.ps1` | every 25 min | health checks → `health_check_log` + alert on failure |
| `Ops Backup` | `backup-ops.ps1` | nightly 02:00 | ops DB `.bak` + secrets copy + prune |
| `Ops Purge` | `purge-ops.ps1` | weekly Sun 04:00 | retention/aging + log rotation |

Plus the data jobs: `Ops Publish *` (cross-station feed), `Ops Worklist *` (delta worklist refresh), `Ops Booking
Watch *` (new-booking factory alerts), and the weekly master refreshes. All registered by `register-ops-tasks.ps1`
(elevated — see [2-SETUP §8](2-SETUP-NEW-CUSTOMER.md#8-schedule-the-recurring-jobs--admin)). Run any by hand for an
immediate check; each exits non-zero on failure so a manual run and the scheduler agree.
