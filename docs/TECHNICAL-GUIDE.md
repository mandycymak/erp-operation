# Control Tower — Technical Operations Guide

**Audience:** IT / technical staff who install, run, refresh, and administer the Control Tower.
**You do not need to be a programmer** to follow this — every task is a copy-paste PowerShell command.

> ⚠️ **This system reads live operational data from the station ERP databases and writes a small operational
> state DB (`erpops`).** Several config files hold credentials or the ERP bearer token and are **never
> committed to git**. See [§8 Files that must never leave the server](#8-files-that-must-never-leave-the-server).

---

## 1. What this is (in one minute)

A small, self-contained web app. The **web tier is an ASP.NET Core (.NET 10) app in `server/`** — it serves the
JSON API and the static HTML/JS client (vanilla JS, **still no Node / no build step on the client**). A separate
PowerShell job (the listener/seeder) reads the read-only station ERP DBs, scores the milestone matrix, and
upserts the small `erpops` state database the UI reads. The browser only ever talks to `erpops` — never the ERP —
so it stays fast.

> 🏗️ **Web tier = `server/` (.NET).** The original single-threaded PowerShell server (`serve-ops.ps1`) is kept
> **for rollback only**; the .NET app is multi-threaded with per-request scope isolation. The **off-request-path
> PowerShell jobs** (`seed-alerts.ps1`, `publish-bookings.ps1`, `seed-*`, `register-ops-tasks.ps1`) are unchanged
> — they only write `erpops`. To **deploy to a real server**, see [§12](#12-deploying-to-a-real-server-iis) and
> [IIS-DEPLOY.md](IIS-DEPLOY.md).

> 🔑 **`Packet Size=512` is mandatory on every SQL connection string.** The Swivel VPN's small MTU
> black-holes default 8 KB TDS packets ("semaphore timeout"). It is already in the code — do not remove it.

> 🔑 **The source ERP DBs are READ-ONLY.** All writes go to `erpops` or the gitignored JSON note store.

---

## 2. Prerequisites

| Need | Why |
|---|---|
| **Windows + PowerShell 5.1** | the whole stack (`.ps1` + .NET `SqlClient`/`HttpListener`) |
| **Swivel OpenVPN up** *(dev/remote only)* | in **this dev setup** the SQL hosts (`18.136.126.101,1438` prod / `192.168.5.2` demoerp) are only reachable through the tunnel — see [§9](#9-vpn-the-swivel-tunnel). **At a customer site the VPN is not needed**: the server just needs network reach to the ops DB + the source ERP SQL (seeders) + the ERP API host (push), all on the customer LAN |
| **SQL Server reachable** | source ERP (read-only) + the ops DB host |
| **A SQL login** | read access to the station ERP DBs; create/write on the ops DB (or two-server mode — see [§3](#3-first-time-install)) |
| **Microsoft Edge or Google Chrome** | headless **print-to-PDF** for the agreed-document upload (auto-generated PDF). Optional — if absent, issue still posts the event, just no auto PDF |

---

## 3. First-time install

> ⚡ **Fastest path — one command per stage.** The manual steps below are wrapped by two self-documenting
> `.bat` files: **`setup-database.bat`** (creates the DB + all tables via `setup-ops.ps1` and seeds the milestone
> config) then, after the first app start, **`seed-data.bat`** (the live-ERP fill: station map / ports / liners /
> inbound feed / worklist, looping every config station x Sea/Air). After `setup-database.bat` + first app start,
> **all ~24 tables exist and `admin`/`admin123` works** (change that password immediately). The numbered steps
> below are what those wrappers run, for when you need to do one stage by hand. Full step-by-step:
> [`ONBOARD-CHECKLIST.md`](ONBOARD-CHECKLIST.md).

### Step 1 — create your config (holds credentials — gitignored)

Copy the template and fill it in:

```powershell
Copy-Item .\ops.config.example.json .\ops.config.json
notepad .\ops.config.json
```

| Field | What to put |
|---|---|
| `server` / `auth` / `user` / `password` | the source ERP SQL host + login |
| `opsServer` / `opsAuth` / `opsDb` | the **ops DB** host (omit to use the source server). Two-server mode reads the ERP remotely and writes `erpops` locally on `localhost\SQLEXPRESS` |
| `masterDb` | the master DB (`fm3kco`) for the intercompany convention |
| `port` | the web port (e.g. `8079`) |
| `stationCode` / `stations[]` | the local station + the picker list |
| `asOfDate` | optional ISO date — treat it as "today" for a frozen snapshot; empty = real today |
| `erpApi` | the Swivel ERP API for document issue — see [§7](#7-erp-document-integration-issue-to-the-erp) |

> 🔐 **`ops.config.json`, `ops.config.*.json`, `users.json`, `.env*`, `ops-lists/`, `*.log` are gitignored.**
> Only `*.example.json` is tracked. Check `git status` before every commit.

### Step 2 — build the `erpops` schema (idempotent, safe to re-run)

```powershell
.\setup-ops.ps1                                   # default config
.\setup-ops.ps1 -ConfigPath .\ops.config.demoerp.json
```

Creates the operational + feed + draft-document tables. Re-running only adds what is missing — existing data
is untouched. (If you ever see `Invalid object name 'dbo.doc_draft'`, your ops DB predates the draft-document
feature — just re-run `setup-ops.ps1`.)

### Step 3 — seed the milestone config and the worklist

```powershell
.\seed-milestone-config.ps1 -ConfigPath .\ops.config.demoerp.json     # the milestone matrix (config-as-data)
# Seed one station, both modes (db fm3k<code> -> StationCode <CODE>):
.\seed-alerts.ps1 -ConfigPath .\ops.config.demoerp.json -Station fm3khkg -StationCode HKG -Mode Sea -AsOf 2026-06-12 -Limit 150
.\seed-alerts.ps1 -ConfigPath .\ops.config.demoerp.json -Station fm3khkg -StationCode HKG -Mode Air -AsOf 2026-06-12 -Limit 150
.\seed-ports.ps1  -ConfigPath .\ops.config.demoerp.json              # POL/POD dropdowns
```

`seed-alerts.ps1` is the **listener stand-in** — a one-shot evaluator/upsert. Run it **once in full-snapshot mode
(no `-Delta`)** to backfill, then the scheduled jobs use **`-Delta`** for cheap incremental refreshes (only rows
whose ERP create/update date moved since the last run — see [§5](#5-refreshing-the-data)). Loop it over all
stations.

> 🆕 **Booking-stage records show too.** `seed-alerts.ps1` now also pulls booking-stage rows (`awb_type='B'`),
> stamped `bill_stage='booking'`, so a just-created booking appears in the worklist (a **BOOKING** badge) and in the
> scoped **New bookings** panel the moment it exists — not only once it becomes a house bill.

### Step 4 — start the web service (.NET)

```powershell
cd server
$env:OPS_CONFIG='ops.config.demoerp.json'; $env:OPS_HTTP_PORT='8079'
dotnet run -c Release                                 # http://localhost:8079/   (or: start-dotnet.bat)
```

`OPS_CONFIG` picks the tenant config; `OPS_HTTP_PORT` overrides the config `port`. For a compiled run use
`dotnet publish -c Release -o publish` then `dotnet publish\Ops.dll`. **For a real server (IIS + HTTPS) see
[§12](#12-deploying-to-a-real-server-iis).**

> 🔁 **Legacy fallback.** The old PowerShell server still works for rollback:
> `.\serve-ops.ps1 -ConfigPath .\ops.config.demoerp.json -Port 8079` (or the `restart-ops-*.bat`). It reads the
> same `erpops` DB, so you can switch back at any time. **Do not run both on the same port.**

> ⚡ The .NET server is multi-threaded with a **`dbGate`** (default 16) bounding concurrent SQL so a burst can't
> stampede the small-MTU VPN box; every query is bounded by `CommandTimeout`; the UI reads only the small
> `erpops` tables, never the ERP, so one request can't stall the rest. (The legacy PowerShell server was
> single-threaded — that shared-scope race is the structural reason for the .NET port.)

---

## 4. Two-server mode

The network ERP login cannot `CREATE DATABASE`, so the ops DB is created **locally**:

- Read the `fm3k*` ERP on `192.168.5.2` (login `dashboard`, read-only).
- Write `erpops` on `localhost\SQLEXPRESS`.

Set `opsServer`/`opsAuth`/`opsDb` in the config. All scripts route `master` + the ops DB to the ops server and
everything else to the source. **For office use**, point `opsServer` at an office-reachable SQL instance and
re-run `setup-ops.ps1` + the seeders there.

---

## 5. Refreshing the data (the recurring job)

Until the scheduled `listener-engine.ps1` is built, re-run `seed-alerts.ps1` per station/mode. To seed all
stations:

> 🆕 **One-click HKG refresh:** `seed-hkg.bat [config]` runs the HKG **Sea + Air** delta in one step (defaults to
> `ops.config.demoerp.json`) — handy on a box with **no scheduled `Ops *` tasks** (where the worklist must be
> seeded by hand). For unattended refresh, register the scheduled jobs with `register-ops-tasks.ps1` (elevated).

```powershell
$today = (Get-Date).ToString('yyyy-MM-dd')
$stations = @{ YVR='fm3kyvr'; SHA='fm3ksha'; HAM='fm3kham'; HKG='fm3khkg'; JKT='fm3kjkt'; NRT='fm3knrt';
               JNB='fm3kjnb'; SIN='fm3ksin'; BKK='fm3kbkk'; TPE='fm3ktpe'; LAX='fm3klax'; SGN='fm3ksgn' }
foreach ($code in $stations.Keys) {
  foreach ($m in 'Sea','Air') {
    .\seed-alerts.ps1 -ConfigPath .\ops.config.demoerp.json -Station $stations[$code] -StationCode $code -Mode $m -AsOf $today -Limit 150
  }
}
```

**Cross-station inbound feed** (publish/subscribe fan-in):

```powershell
.\seed-station-map.ps1                                                  # station_dim + route map
.\publish-bookings.ps1 -Station fm3khkg -StationCode HKG -Mode Sea      # publish HKG's cross-station bookings
```

**Automating it (Windows Task Scheduler):**

```powershell
# Run from an ELEVATED (Administrator) PowerShell — the script exits early otherwise.
.\register-ops-tasks.ps1 -ConfigPath .\ops.config.<env>.json   # [-WorklistLimit 120]
```

This registers, per configured station: **`Ops Publish Sea/Air`** (cross-station feed, Sea 3x/day · Air every 2h,
staggered); **`Ops Worklist Sea/Air`** (incremental worklist refresh via **`seed-alerts.ps1 -Delta`** — **Air every
`WorklistAirMins` (default 5)**, **Sea every `WorklistSeaMins` (default 15)**, staggered; its `-AsOf` is computed at
run time so it always seeds "today"); **`Ops Booking Watch Sea/Air`** (`watch-bookings.ps1`, every `BookingWatchMins`,
default 5 — detects new export bookings → `booking_alert`, alerts the factory when `bookingAlert.enabled`); weekly
`Ops Station Map Refresh` and `Ops Port Dim Refresh`; **and the three governance jobs `Ops Backup` (nightly),
`Ops Healthcheck` (every 25 min) and `Ops Purge` (weekly)** — see §5a. The station set is taken from `stations[]`
in the config, so N stations → N task sets. **These jobs run on whatever host you schedule them on and write the
ops DB directly — in production that is the server (with the VPN up), not a workstation; the IIS app only reads the
same DB.**

> 🆕 **Run the full backfill once before the delta tasks take over** (the `setup-database.bat` → start app →
> `seed-data.bat` flow does this). The delta jobs only pull rows that changed since the last watermark, so they
> assume the active set was already seeded in full.

---

## 5a. Operations, monitoring & backup (for go-live)

Three concerns the IT/support team owns after go-live — all visible **in the app** so no database access is needed,
and all detailed in **[`OPERATIONS-RUNBOOK.md`](OPERATIONS-RUNBOOK.md)**. The one-time install/onboarding is its own
self-contained checklist: **[`ONBOARD-CHECKLIST.md`](ONBOARD-CHECKLIST.md)**.

- **See problems & the audit trail — in the browser.** Sign in as an admin → **Admin**. Two tabs:
  - **Audit & Health** — a **Health board** (one row per check, with "last OK" so a red→green row shows a recovery)
    and a **Storage & growth** view (DB size, biggest tables, attachment bytes, free disk).
  - **Change log** — **who changed what / who logged in** and **server errors**, each bounded by a **date range**
    (default today) and capped so a busy day / error storm can't break the page.
  These read `health_check_log` + the audit tables/logs; nothing writes the ERP.
- **Know when something breaks.** `ops-healthcheck.ps1` (the `Ops Healthcheck` task) checks app / DB / scheduled
  tasks / feed freshness / backup age / DB size / disk / VPN every ~25 min, writes each to `health_check_log`, and
  on failure **alerts** via the config **`alerts`** block — a Teams/Slack `webhookUrl` and/or `smtp` email — and
  logs `ops-health.log`. The unauthenticated probe is `GET /api-ops/health` (`200 ok` / `503 db:down`) for any
  external uptime monitor.
- **Backup + retention.** `backup-ops.ps1` (`Ops Backup`, nightly) writes a dated `.bak` of the ops DB + a copy of
  the gitignored secrets, pruned after `RetainDays`. `purge-ops.ps1` (`Ops Purge`, weekly) ages out/trims the data
  per the config **`retention`** horizons and rotates the logs, so the DB stays small over years. **Gotcha:** the
  `.bak` folder must be writable by the **SQL Server service account** (not the app pool) — see the checklist's
  `icacls` step.

> Application errors are written to **`ops-error.log`** (route, correlation id, stack) — previously they were
> discarded. Login successes/failures are in **`admin-audit.log`**. Both surface in the **Change log** tab.

> 🔌 **Which ERP API call failed?** Every Swivel ERP call (push **and** the previously-silent reads) is logged to
> **`dbo.erp_api_log`** — endpoint, ok/HTTP-status, duration, the ERP's own error text, bounded req/resp summaries,
> and a **`corr_id`** linking the calls of one operation (a doc agree's get+update share an id). Surfaced as the
> **ERP API calls** panel in the **Change log** tab and the `/api-ops/admin/erp-api` endpoint (date-range + cap +
> "failures only"). Mock-mode calls aren't logged — they never reach the ERP. Trimmed by `purge-ops.ps1`.

---

## 6. Managing user accounts & roles

Sign in as an **admin** and open the **Admin** link (admins only). `admin-ops.html` has **four tabs**:

- **Users** — add/edit logins, with a live search over name/email/station/team/ERP-name (built for ~500 users).
  **Email is the required, unique sign-in key**; a **Sign-in** column shows each user's method. Logins/roles/scope
  live in **SQL** (`dbo.app_user` + `dbo.app_user_scope`) — **not** a JSON file. Passwords are stored hashed
  (`SHA256("salt:password")`); new users are hashed automatically.
- **Milestones & alerts** — CRUD over `milestone_def`: name, mode/bound/seq/phase, active, and the **alert
  timing** (`baseline` / fixed offset / `none`) that drives every operator's Green/Amber/Red. Edits apply at
  a shipment's **next evaluation run**, not retroactively.
- **Documents** — CRUD over the `milestone_evidence_map` doctype rows (the **ERP Document Type codes**). These
  populate the drawer's **ERP-files upload** picker: an operator can upload **any** of these doctypes to a shipment
  (the box is always shown when the ERP is live), and the ones that would also **clear a milestone** on that
  shipment are flagged with a `*`. Keep these matched to the ERP Document Type master, or `/file/upload` is
  rejected. (If the list is empty the picker falls back to a free-text doctype field.)
- **Generate documents** — CRUD over `doc_generate_map`: the **documentTypeCode + houseTypeCode** pairs (per
  module **AIR/SEA**) an operator may generate from a shipment (the drawer's **Generate document** box). One
  documentTypeCode can have several houseTypeCodes (one row each). **Master bill** keys the generate call on the
  master bill (master-level docs); **Invoice** prompts the operator for an invoice number. Both codes are sent
  **verbatim** to `/document/generate`, so they must match the ERP exactly. Changes apply immediately (cached, no
  restart). The generated PDF is returned **inline** and streamed to the operator as a download — the ERP does not
  file it, so it does not appear in the ERP-files list.
- **ERP API** — the ERP **connection**, editable at the customer site with no file edit and no restart: the
  **Base URL**, the **bearer token** (write-only — masked, "leave blank to keep"; never returned by the API) and
  the **mock** toggle, stored in **`dbo.app_setting`** and overriding `ops.config.json` at runtime, with a
  **LIVE / MOCK** status indicator. Plus the non-secret ERP identity codes from `erp-api-map.json`:
  **`partyGroupCode`** (the company code, e.g. `DEV`) and the fallback **`forwarderCode`** (office owncode). See §7.
  - 🆕 **Customer review link base URL** (`publicBaseUrl`, also in `app_setting`): the host prefix for the
    customer document-review links — `doc-send` builds `<publicBaseUrl>/bl-review/<token>`. **Blank → falls back to
    `http://localhost:<port>`, which a customer cannot open**, so at the customer site set this to the
    internet-facing **HTTPS** host (e.g. `https://ops.customer.com`). Applies immediately, no restart; the field
    shows whether the value is from SQL, the config file, or blank. (Behind a reverse proxy this is the proxy's
    public hostname, not the internal port — see the public-review-surface note in §8.)

**Auth model — users live in SQL, with a secure default admin.** Logins/roles/scope are stored in **`dbo.app_user`
+ `dbo.app_user_scope`** (created by `setup-ops.ps1`). On first start against an empty user table the app
**imports a legacy `users.json` once** (kept only as a backup) **or seeds a default `admin`/`admin123`** (the
console logs "change this password immediately"). Because a user always exists after bootstrap, the app is in
**real-auth mode** (login page, sessions, row-level scope) in production — the old "open/demo" mode (every visitor
auto-admin) **never triggers** unless someone manually empties the table. Users **sign in by email + password** (a
username also works as a fallback so no one is locked out during the switch). The **`username` stays the internal
identity** (notes, @-mentions, sessions, scope, and the ERP-username bridge are unchanged) — email is only the
credential. Each record carries `stations[]`, `access[]` (`Sea-Export`…), `teams[]`, `admin`, **`authProvider`**
(`local` | `swivel` | `both`), and the **ERP usernames** it owns (free-text ERP `pic_user` values). Admin/manager
see everything.

> 🔑 **A `swivel` user has no local password** — it signs in only via SWIVEL L!NK (below). A `local` user can be
> matched by L!NK too (federation is by email), so `both` is the common case once L!NK is live.

### 6a. SWIVEL L!NK sign-on (OAuth code flow)

The app can be embedded in **SWIVEL L!NK** as an iframe; L!NK signs the user in via OAuth **code flow**, federated
on **email**. It is **inert until configured** — the redeem URL must be set:

```
SWIVEL_OAUTH_PROFILE_URL=https://auth.swivelsoftware.asia/api/oauth/profile   # env (or config swivelLink.profileUrl)
SWIVEL_OAUTH_XSYSTEM=360uat                                                    # only for a uat-stage L!NK (x-system header)
```

or the `swivelLink` config block (`profileUrl`, `xSystem`, `autoProvision`, `defaultRole`). When enabled,
`/api-ops/config` reports `linkEnabled:true`. Flow: L!NK opens
`index.html?mode={light|dark}&site={CODE}#code={CODE}&state={STATE}`; the page reads the one-time `code`/`state`
from the URL **fragment**, POSTs them to `/api-ops/link-oauth-login`, which redeems the code **server-side**
(**no client_id/secret — the code self-authenticates**), verifies the echoed `state`, matches `profile.email` to a
user (**auto-provisions** a `defaultRole` user when none, if `autoProvision`), and mints the app's own session.
Register this app's redirect origin with Swivel; nothing else is needed to go live.

---

## 6b. Language (i18n) — English / 中文 / 日本語

The operator UI is localized **client-side**; the shipment **data, documents and free-text notes stay as
typed** (only captions are translated). English is the source-of-truth and the fallback.

- **Per-user default.** Each user record carries a **`language`** field (`""` = follow the browser, then
  English | `en` | `zh-Hans` | `ja`), set on the admin **Users** form. `/api-ops/me` returns it.
- **Per-device switch.** A header **language picker** lets anyone switch instantly (stored in `localStorage`,
  persists per device, overrides the profile default). So documents stay English while a China/Japan operator
  reads the chrome in their language.
- **How it works.** `i18n.js` loads `lang/<code>.json` (English source string = key; a missing key falls back
  to English, never blank) and translates the page. The dictionaries are served statically — the .NET
  static-secret guard is opened for `lang/*.json` only.
- **Adding a language** (see [DEVELOPER-GUIDE.md §8](DEVELOPER-GUIDE.md)): drop `lang/<code>.json`, add one line
  to `SUPPORTED` in `i18n.js`, add a CJK/locale font stack in `styles.css` if needed, and add the code to the
  server allow-list (`Handlers.Admin.cs` + `serve-ops.ps1`). No other code changes.

> 🈶 **Encoding.** Dictionaries are UTF-8 JSON (served `application/json`). Keep `.ps1` ASCII-only — the
> dictionaries are external files, so no non-ASCII enters any script. HTML pages already have `<meta charset>`.

---

## 7. ERP document integration (issue to the ERP)

The draft HBL/HAWB **Issue** posts to the **Swivel 3rd-party ERP API**. Two config locations:

- **`erp-api-map.json` (tracked, non-secret)** — deployment codes that must match the ERP masters:
  **`partyGroupCode`** (the company code, e.g. `DEV` — also editable in the admin **ERP API** tab),
  **`forwarderCode`** (the *fallback* office owncode), `serviceCodeDefault`, `commodityFallback`, the `event`
  (`transportBill` / "Transport Bill Confirm"), `documentTypeCode` (**`BL_REVIEW`** for HBL + HAWB), and
  `bookingUpdateMode` (`strict` / `best-effort`).
- **`ops.config.json` → `erpApi` (gitignored, SECRET)** — `baseUrl` + the **bearer token** from Swivel. **Or set
  these in the admin ERP API tab** (`dbo.app_setting`), which overrides the config at runtime — so at a customer
  the token need not sit in a file on the box (see §6). The DB value wins; a blank DB value falls back to the config.

> 🧭 **`forwarderCode` is the office owncode — "where the data goes" — and is resolved PER STATION, not
> hard-coded.** `Resolve-ForwarderCode($station)` → `Get-StationOwnCode` reads `fm3kco.site` (dbname → owncode,
> e.g. HKG=`S0001`, SHA=`S0002`, SIN=`S0005`, BKK=`S0009`) and feeds it to `/booking/get`, `/booking/update`
> (`bookingParty.forwarderPartyCode`, always sent — required by the schema), `/file/upload`, `/file/enquiry`,
> `/file/download` and `/document/generate`. The `erp-api-map.json` `forwarderCode` is only the fallback. The ERP
> **422s a wrong forwarder code**, so a single static code would misroute every non-HQ station.

```json
"erpApi": {
  "baseUrl": "https://demoerp-api.swivelsoftware.com",
  "token":   "<your Swivel bearer token>",
  "mock":    false
}
```

> ⚠️ **No `erpApi` block (or blank token) = MOCK mode.** The issue writes `erp-mock/issue-*.json` and **nothing
> reaches the ERP** — no event, no file. The Issue dialog flashes *"(MOCK mode)"*. Add the token to go live.

**What each button does** (see [BUSINESS-GUIDE.md §9](BUSINESS-GUIDE.md)):

| Button | ERP calls |
|---|---|
| **Agree – save data to ERP** | `/booking/get` (read-merge) → `/booking/update` (agreed data) |
| **Issue official document (ERP)** | `/file/upload` (auto-generated **BL_REVIEW** PDF) → `/event/update` (**Transport Bill Confirm**) [+ optional `/document/generate`] |

> 🔑 **`documentTypeCode: BL_REVIEW` must exist in the ERP Document Type master**, or `/file/upload` is
> rejected. Likewise `event.status` and `serviceCode` must match their ERP masters.

> 🖨️ **Generate document (operator, drawer).** Separate from Issue: `POST /api-ops/erp-doc-generate` calls
> `/document/generate` for an admin-configured `documentTypeCode` + `houseTypeCode` (the **Generate documents**
> tab → `doc_generate_map`). The booking/bill key is chosen by priority **houseBillNo → bookingNo → masterBillNo**
> (a *Master bill* row leads with the master bill), and **falls through on a "No corresponding shipment" 422** to
> the next identifier — so a typed-but-not-issued house bill still resolves via the booking number. `includeFile`
> returns the PDF **inline** (the ERP does **not** store it), so the endpoint streams the bytes back as a download.

> ℹ️ **Auto PDF.** On Issue, the server renders the agreed bill to PDF with headless Edge/Chrome (reusing the
> print layout) and uploads it. Set `pdfEngine` in the config to override the browser path; if no browser is
> found, the issue still posts the event without an attachment.

> ✅ **`/booking/update` works live (demoerp `HK012606010`).** The old payload-invariant rejection ("Departure date
> not active yet, Invalid carrier code") is gone, so `bookingUpdateMode` is back to **`strict`**. Two requirements
> baked in: `partyGroupCode` + `bookingParty.forwarderPartyCode` (owncode) must be present, and the call
> **read-merges** the schedule fields (`serviceCode`, `commodity`, POL/POD code+name) from the live `/booking/get`
> — sending only the changed field otherwise triggers `(500) "No such POL in job schedule"`.

---

## 8. Files that must never leave the server

| File | Holds |
|---|---|
| `ops.config.json`, `ops.config.*.json` | SQL credentials + the ERP bearer token (token may instead live in `app_setting`) |
| `users.json`, `roles.json` | **legacy** logins (hashed) + scope — now only a one-time import source / backup; the live store is SQL (`app_user`) |
| `ops-lists/`, `*-audit.log`, `*.log` | operational lists + audit trail |
| `erp-mock/` | mock issue payloads (may contain booking data) |

All are **gitignored**. Only `*.example.json` is tracked. **Check `git status` before every commit.**

---

## 9. VPN — the Swivel tunnel

The SQL hosts are reachable **only** through the Swivel OpenVPN tunnel. There is a local **`swivel-vpn`**
skill/helper:

```powershell
.\.claude\skills\swivel-vpn\scripts\swivel-vpn.ps1 -Check    # tunnel up? routes? reachability
.\.claude\skills\swivel-vpn\scripts\swivel-vpn.ps1 -Fix      # elevated: add the more-specific routes
```

> ⚠️ **Surfshark conflict.** If Surfshark is running it (1) throws a phantom "VPN being utilised by another
> Windows user" in OpenVPN Connect — **disconnect Surfshark in its app** (killing the service respawns it);
> and (2) plants a competing `192.168.0.0/21` route that black-holes `192.168.5.2`. **Fix without
> disconnecting Surfshark:** add a more-specific route so longest-prefix-match wins —
> `New-NetRoute -DestinationPrefix '192.168.5.0/24' -InterfaceIndex <tunIfIndex> -NextHop <tunGateway> -RouteMetric 1`
> (elevated). The `-Fix` helper does this automatically.

Confirm with `Test-NetConnection 192.168.5.2 -Port 1433` (`TcpTestSucceeded = True`). `PingSucceeded` is often
False — ICMP is filtered; ignore it.

---

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "semaphore timeout" / "transport-level" | VPN dropped or `Packet Size=512` removed. Reconnect VPN (see [§9](#9-vpn-the-swivel-tunnel)); confirm the route to the SQL host wins over Surfshark. |
| "ERP lookup failed: … pre-login handshake … wait operation timed out" (opening Edit ERP data / detail drawer) | The VPN's SSL handshake was slower than the connect timeout. The source-ERP `Connect Timeout` is **15 s** (raised from 5 s; the handshake runs ~4 s). If it still times out the **tunnel itself is slow/down** — check the VPN (see [§9](#9-vpn-the-swivel-tunnel)). |
| `Test-NetConnection 192.168.5.2` fails | Surfshark route black-hole — run the `swivel-vpn -Fix`. |
| `Invalid object name 'dbo.doc_draft'` | ops DB predates the draft-document feature — re-run `setup-ops.ps1`. |
| Draft create is slow / comes back snapshot-only | This was the `awbhead` column-metadata stall — fixed (the seeder no longer probes metadata). If it recurs, confirm the VPN and that `Get-ErpCols` is the metadata-free version. |
| Issue shows "(MOCK mode)" / nothing in the ERP backend | No `erpApi` block / blank token — add the bearer token to `ops.config.*.json` and restart ([§7](#7-erp-document-integration-issue-to-the-erp)). |
| Event posted but no PDF attachment | No browser for headless print, **or** the operator picked their own (empty) file. Install Edge/Chrome or set `pdfEngine`. |
| `/file/upload` rejected | `documentTypeCode` (`BL_REVIEW`) not in the ERP Document Type master. |
| Worklist all-Red | Sparse operational fields on a frozen snapshot, or the bound-mapping (`onboard1` vs `onboard2`) — confirm you re-seeded on current code. |
| Mojibake (`â€”`) on screen | A config/JSON file read with `Get-Content` instead of `[IO.File]::ReadAllText` — already handled in code; keep new `.ps1` ASCII-only. |

---

## 11. Quick reference

```powershell
# Bring up demoerp end-to-end (one command per stage)
.\.claude\skills\swivel-vpn\scripts\swivel-vpn.ps1 -Check      # VPN
.\setup-database.bat       .\ops.config.demoerp.json           # schema + all tables + milestone config
cd server; $env:OPS_CONFIG='ops.config.demoerp.json'; dotnet run -c Release   # .NET web tier (seeds default admin)
# ...back in repo root, with the app started:
.\seed-data.bat           .\ops.config.demoerp.json           # live-ERP fill (all stations x Sea/Air)

# Restart after a code/config change (port-scoped, excludes own PID)
.\restart-ops-demoerp.bat                                      # legacy PS server; for .NET re-run dotnet / redeploy-demoerp.bat
```

> The manual long-hand (`setup-ops.ps1` / `seed-milestone-config.ps1` / per-station `seed-alerts.ps1` /
> `serve-ops.ps1` rollback) is in §3–§5; the `.bat` wrappers above just chain those in order.

See [DEVELOPER-GUIDE.md](DEVELOPER-GUIDE.md) for code changes and [SQL-README.md](SQL-README.md) for the schema
and ERP field map.

---

## 12. Deploying to a real server (IIS)

The web tier is **compiled** (.NET), so deploying an update = **publish + copy + restart the app pool** (not a
`git pull`). The full step-by-step (prereqs, app pool, HTTPS, env vars, tenancy) is in
**[IIS-DEPLOY.md](IIS-DEPLOY.md)**; the strangler-flip runbook is [CUTOVER.md](CUTOVER.md). In short:

1. **Build (on a dev box with the .NET 10 SDK):**
   ```powershell
   cd server
   dotnet publish -c Release -o publish        # produces server\publish\ (Ops.dll + web.config)
   ```
2. **On the server (once):** install **IIS** + the **ASP.NET Core 10 Hosting Bundle** (gives ANCM); create an
   app pool (**No Managed Code**) and a site whose physical path is the `publish` folder; bind **443** with a
   TLS cert.
3. **Point it at the config + client files** via env vars on the app pool (they survive re-publish, unlike
   `web.config`): **`OPS_ROOT`** = the folder holding `ops.config.*.json` + the client files + `lang/`,
   **`OPS_CONFIG`** = the tenant config, **`OPS_HTTPS=1`** (Secure cookies + HSTS), `OPS_IFRAME=1` only for the
   L!NK iframe. `DB_*` env vars can override the config.
4. **The app-pool identity needs** read/write on `OPS_ROOT`, network to the `erpops` DB + the source ERP over
   the VPN, and (for integrated `opsAuth`) a SQL login + `db_owner` on the ops DB.
5. **Redeploy later** = re-`dotnet publish` to the same folder (drop `app_offline.htm` first so the running app
   releases `Ops.dll`) and recycle the pool.
6. **Verify:** `https://<host>/` loads; `https://<host>/ops.config.json` → **404** (secret blocked); the
   language picker works; reconcile a milestone light against a direct ERP SQL query.

> 🧪 **Rehearse locally first.** `deploy-local-iis-demoerp.ps1` (run **elevated**, once) stands the *published*
> app up under IIS on this PC pointed at `ops.config.demoerp.json` — IIS features, Hosting-Bundle check, app
> pool + env vars, the SQL login/grant for the pool identity, and an `http://localhost:8080` site.
> `redeploy-demoerp.bat` is the minimal-effort redeploy. The real-server steps above are the same shape, plus a
> TLS binding. (Both helper scripts contain paths only — no secrets.)

> 🌐 **Public review surface.** If customers reach the draft-review page, expose only `/bl-review/*` + `/api-doc/*`
> (+ the review assets) and set `publicBaseUrl` to the internet-facing HTTPS host so review links are correct.
