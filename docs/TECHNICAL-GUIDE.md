# Control Tower — Technical Operations Guide

**Audience:** IT / technical staff who install, run, refresh, and administer the Control Tower.
**You do not need to be a programmer** to follow this — every task is a copy-paste PowerShell command.

> ⚠️ **This system reads live operational data from the station ERP databases and writes a small operational
> state DB (`pgsops`).** Several config files hold credentials or the ERP bearer token and are **never
> committed to git**. See [§8 Files that must never leave the server](#8-files-that-must-never-leave-the-server).

---

## 1. What this is (in one minute)

A small, self-contained web app. **No IIS, no Node, no build step.** A PowerShell `HttpListener` serves a JSON
API and static HTML/JS; a separate PowerShell job (the listener/seeder) reads the read-only station ERP DBs,
scores the milestone matrix, and upserts the small `pgsops` state database the UI reads. The browser only ever
talks to `pgsops` — never the ERP — so it stays fast.

> 🔑 **`Packet Size=512` is mandatory on every SQL connection string.** The Swivel VPN's small MTU
> black-holes default 8 KB TDS packets ("semaphore timeout"). It is already in the code — do not remove it.

> 🔑 **The source ERP DBs are READ-ONLY.** All writes go to `pgsops` or the gitignored JSON note store.

---

## 2. Prerequisites

| Need | Why |
|---|---|
| **Windows + PowerShell 5.1** | the whole stack (`.ps1` + .NET `SqlClient`/`HttpListener`) |
| **Swivel OpenVPN up** | the SQL hosts (`18.136.126.101,1438` prod / `192.168.5.2` demoerp) are only reachable through the tunnel — see [§9](#9-vpn-the-swivel-tunnel) |
| **SQL Server reachable** | source ERP (read-only) + the ops DB host |
| **A SQL login** | read access to the station ERP DBs; create/write on the ops DB (or two-server mode — see [§3](#3-first-time-install)) |
| **Microsoft Edge or Google Chrome** | headless **print-to-PDF** for the agreed-document upload (auto-generated PDF). Optional — if absent, issue still posts the event, just no auto PDF |

---

## 3. First-time install

### Step 1 — create your config (holds credentials — gitignored)

Copy the template and fill it in:

```powershell
Copy-Item .\ops.config.example.json .\ops.config.json
notepad .\ops.config.json
```

| Field | What to put |
|---|---|
| `server` / `auth` / `user` / `password` | the source ERP SQL host + login |
| `opsServer` / `opsAuth` / `opsDb` | the **ops DB** host (omit to use the source server). Two-server mode reads the ERP remotely and writes `pgsops` locally on `localhost\SQLEXPRESS` |
| `masterDb` | the master DB (`fm3kco`) for the intercompany convention |
| `port` | the web port (e.g. `8079`) |
| `stationCode` / `stations[]` | the local station + the picker list |
| `asOfDate` | optional ISO date — treat it as "today" for a frozen snapshot; empty = real today |
| `erpApi` | the Swivel ERP API for document issue — see [§7](#7-erp-document-integration-issue-to-the-erp) |

> 🔐 **`ops.config.json`, `ops.config.*.json`, `users.json`, `.env*`, `ops-lists/`, `*.log` are gitignored.**
> Only `*.example.json` is tracked. Check `git status` before every commit.

### Step 2 — build the `pgsops` schema (idempotent, safe to re-run)

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

`seed-alerts.ps1` is the **listener stand-in** — a one-shot evaluator/upsert. Loop it over all stations (see
[§5](#5-refreshing-the-data)).

### Step 4 — start the web service

```powershell
.\serve-ops.ps1 -ConfigPath .\ops.config.demoerp.json -Port 8079     # http://localhost:8079/
```

Or double-click the matching **restart bat** (`restart-ops-demoerp.bat` / `restart-ops-network.bat` /
`restart-ops-local.bat`) — it stops any instance on that port (excluding itself) and starts a fresh one.

> ⚡ The server is **single-threaded** (one `HttpListener` request at a time). Every query is bounded by
> `CommandTimeout`; the UI reads only the small `pgsops` tables, never the ERP, so one request can't stall the
> rest.

---

## 4. Two-server mode

The network ERP login cannot `CREATE DATABASE`, so the ops DB is created **locally**:

- Read the `fm3k*` ERP on `192.168.5.2` (login `dashboard`, read-only).
- Write `pgsops` on `localhost\SQLEXPRESS`.

Set `opsServer`/`opsAuth`/`opsDb` in the config. All scripts route `master` + the ops DB to the ops server and
everything else to the source. **For office use**, point `opsServer` at an office-reachable SQL instance and
re-run `setup-ops.ps1` + the seeders there.

---

## 5. Refreshing the data (the recurring job)

Until the scheduled `listener-engine.ps1` is built, re-run `seed-alerts.ps1` per station/mode. To seed all
stations:

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
.\register-ops-tasks.ps1     # publish per station (Sea 3x/day, Air 2h, staggered) + weekly map refresh
```

---

## 6. Managing user accounts & roles

Sign in as an **admin** and open the **Admin** link (admins only). `admin-ops.html` has **four tabs**:

- **Users** — add/edit logins, with a live search over name/email/station/team/ERP-name (built for ~500 users).
  **Email is the required, unique sign-in key**; a **Sign-in** column shows each user's method. Passwords are
  stored hashed (`SHA256("salt:password")`); new users are hashed automatically.
- **Milestones & alerts** — CRUD over `milestone_def`: name, mode/bound/seq/phase, active, and the **alert
  timing** (`baseline` / fixed offset / `none`) that drives every operator's Green/Amber/Red. Edits apply at
  a shipment's **next evaluation run**, not retroactively.
- **Documents** — CRUD over the `milestone_evidence_map` doctype rows (the **ERP Document Type codes** that, when
  uploaded against a shipment, clear a milestone). Keep these matched to the ERP master.
- **ERP API** — the non-secret ERP identity codes in `erp-api-map.json`: **`partyGroupCode`** (the company code,
  e.g. `DEV`) and the fallback **`forwarderCode`** (office owncode). The bearer token is **not** here. See §7.

**Auth model.** With `users.json` present the app runs in **real-auth mode** (login page, sessions, row-level
scope). Without it, open/demo mode. Users **sign in by email + password** (a username also works as a fallback so
no one is locked out during the switch). The **`username` stays the internal identity** (notes, @-mentions,
sessions, scope, and the ERP-username bridge are unchanged) — email is only the credential. Each record carries
`stations[]`, `access[]` (`Sea-Export`…), `teams[]`, `admin`, **`authProvider`** (`local` | `swivel` | `both`),
and the **ERP usernames** it owns (free-text ERP `pic_user` values). Admin/manager see everything.

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

## 7. ERP document integration (issue to the ERP)

The draft HBL/HAWB **Issue** posts to the **Swivel 3rd-party ERP API**. Two config locations:

- **`erp-api-map.json` (tracked, non-secret)** — deployment codes that must match the ERP masters:
  **`partyGroupCode`** (the company code, e.g. `DEV` — also editable in the admin **ERP API** tab),
  **`forwarderCode`** (the *fallback* office owncode), `serviceCodeDefault`, `commodityFallback`, the `event`
  (`transportBill` / "Transport Bill Confirm"), `documentTypeCode` (**`BL_REVIEW`** for HBL + HAWB), and
  `bookingUpdateMode` (`strict` / `best-effort`).
- **`ops.config.json` → `erpApi` (gitignored, SECRET)** — `baseUrl` + the **bearer token** from Swivel.

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
| `ops.config.json`, `ops.config.*.json` | SQL credentials + the ERP bearer token |
| `users.json`, `roles.json` | logins (hashed) + row-level scope |
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
# Bring up demoerp end-to-end
.\.claude\skills\swivel-vpn\scripts\swivel-vpn.ps1 -Check      # VPN
.\setup-ops.ps1            -ConfigPath .\ops.config.demoerp.json
.\seed-milestone-config.ps1 -ConfigPath .\ops.config.demoerp.json
# ...seed all stations (see §5)...
.\serve-ops.ps1           -ConfigPath .\ops.config.demoerp.json -Port 8079

# Restart after a code/config change (port-scoped, excludes own PID)
.\restart-ops-demoerp.bat
```

There is **no build and no deploy pipeline** — "deploying an update" means `git pull` on the host, then
restart `serve-ops.ps1`. See [DEVELOPER-GUIDE.md](DEVELOPER-GUIDE.md) for code changes and
[SQL-README.md](SQL-README.md) for the schema and ERP field map.
