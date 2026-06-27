# Stage 1 — Set up a new customer (first install)

**This is the only document you need to deploy and onboard a customer for the first time.** Follow **Part A**
top to bottom; every step ends with a **You should now see** check — do not move on until you see it. **Part B**
is the install-time reference (config fields, two-server mode, IIS detail, VPN, ERP-API connection, language,
tenancy) that the steps point into.

Deploy is **one-time**. Once it is done, routine updates are [3-DEPLOY-UPDATES.md](3-DEPLOY-UPDATES.md) and the
day-to-day is [4-OPERATE-SUPPORT.md](4-OPERATE-SUPPORT.md).

- Run an **elevated** PowerShell (Right-click PowerShell → *Run as administrator*) for steps marked **[admin]**.
- Replace `<tenant>` with a short customer code (e.g. `acme`) and `<OPS_ROOT>` with the repo folder on the server
  (e.g. `C:\inetpub\erp-operation`). **One customer = one IIS site + one config file + one `erpops` database.**
- **Never commit secrets.** `ops.config.<tenant>.json`, `users.json`, `erp-api-map.json`, the `backups\` folder
  and the `*.log` files stay on the server only. Only `*.example.json` is tracked — check `git status` before any commit.

> **Fastest path — one command per stage.** `first-install\setup-database.bat` (schema + all tables + milestone config) → start
> the app once → `seed-data.bat` (the live-ERP fill). The numbered steps below are what those wrappers run, for
> when you need a stage by hand.

---

# Part A — The install checklist

## 0. What you are installing (one minute)

A web app (ASP.NET Core, runs under IIS) + a set of scheduled PowerShell jobs (Task Scheduler) + one SQL Server
database called the **ops DB** (`erpops`). The app only ever **READS** the customer's source ERP databases and
**WRITES** the ops DB. You will: create the DB, fill it, create the IIS site, create the first admin user, and
schedule the jobs — then prove each worked from the browser.

---

## 1. Prerequisites  (check before touching anything)

- [ ] **Windows Server** with the **IIS** role, and the **.NET 10 Hosting Bundle** installed
      (`https://dotnet.microsoft.com/download/dotnet/10.0` → "Hosting Bundle"; then run `iisreset`). The Hosting
      Bundle installs the .NET runtime + the **ASP.NET Core Module v2 (ANCM)** into IIS.
- [ ] A **headless browser** present (Microsoft Edge or Google Chrome) — used to render issued bills to PDF.
- [ ] A **TLS certificate** for the site hostname (real CA cert or imported into `LocalMachine\My`).
- [ ] **Network reachability** from this server to: the **ops DB**, the customer's **source ERP SQL** host (port 1433,
      used by the scheduled seeders), and the **ERP HTTP API** host (used for push). **A VPN is only needed when you
      deploy from *outside* the customer network** (e.g. our remote test box — see [Part B §VPN](#vpn--the-swivel-tunnel)).
      Deployed **at the customer**, the server is already on their LAN — **no VPN**; it just needs to reach those
      three endpoints (the ops DB can be local).
- [ ] The build output (`server\publish\`) copied to the server, OR the .NET 10 **SDK** on a build box to publish.

**Run these and confirm:**
```powershell
# ERP / DB reachability (replace host,port with the customer's source ERP SQL host):
Test-NetConnection -ComputerName 192.168.5.2 -Port 1433 | Select-Object TcpTestSucceeded
# Hosting Bundle / ASP.NET Core Module present:
Test-Path "$env:windir\System32\inetsrv\aspnetcorev2.dll"
```
> **You should now see:** `TcpTestSucceeded : True` and `True`. If either is False, stop — fix the VPN / install
> the Hosting Bundle before continuing. (Verify ANCM in IIS Manager → server node → *Modules* lists `AspNetCoreModuleV2`.)

---

## 2. Folders & write permissions

The app reads its config and serves the client files from **`<OPS_ROOT>`**, and WRITES these there:
`users.json`, `admin-audit.log`, `ops-error.log`, `ops-health.log`, `ops-backup.log`, `ops-lists\`, and the
`backups\` folder. The IIS **app-pool identity** must be able to write to `<OPS_ROOT>`, and the **SQL Server service
account** must be able to write to the backup folder (SQL writes the `.bak`, not the script).

- [ ] **[admin]** Grant the app-pool identity Modify on `<OPS_ROOT>` (the deploy script in step 5 also does this):
```powershell
icacls "<OPS_ROOT>" /grant "IIS AppPool\<your-app-pool>:(OI)(CI)M"
```
- [ ] **[admin]** Create the backup folder and grant the SQL service account Modify (default account for a default
      SQL Express instance is `NT SERVICE\MSSQL$SQLEXPRESS`; for a full instance `NT SERVICE\MSSQLSERVER`):
```powershell
New-Item -ItemType Directory -Force "<OPS_ROOT>\backups" | Out-Null
icacls "<OPS_ROOT>\backups" /grant "NT SERVICE\MSSQL`$SQLEXPRESS:(OI)(CI)M"
```
**Verify** the app-pool identity can write:
```powershell
$f="<OPS_ROOT>\_perm_test.txt"; "ok" | Out-File $f; Remove-Item $f
```
> **You should now see:** no error from the write test, and `icacls` reporting `Successfully processed 1 files`.
> (If the SQL service account is wrong, you find out at step 9 when the backup runs — error 5 = Access denied.)

---

## 3. Configuration file

- [ ] Copy the template and edit it for this customer (it is gitignored):
```powershell
Copy-Item "<OPS_ROOT>\ops.config.example.json" "<OPS_ROOT>\ops.config.<tenant>.json"
```
- [ ] Set, at minimum — the full field reference is in [Part B §Config fields](#config-file-fields):
  - **Source ERP**: `server` (host,port), `auth` (`sql` or `integrated`), `user`/`password` (if sql).
  - **Ops DB**: `opsDb` (e.g. `erpops`). If it lives on a different SQL server than the ERP, also set
    `opsServer` / `opsAuth` / `opsUser` / `opsPassword` ([two-server mode](#two-server-mode)); otherwise it uses the source server.
  - **Branding**: `appName`, `instanceName`, `appSubtitle`. **`stationCode`** = the home station this instance serves.
  - **`stations[]`**: one entry per branch `{ code, name, country, database }` (the source ERP DB per branch).
  - **`erpApi`**: keep `"mock": true` until the customer's ERP write token is in hand (you can also set Base
    URL / token / mock later in **Admin → ERP API** — see [Part B §ERP-API connection](#erp-api-connection)).
  - **`publicBaseUrl`**: the **internet-facing HTTPS host** for customer document-review links. **Blank →
    `http://localhost:<port>`, which a customer cannot open.** Set it to e.g. `https://ops.customer.com` (or in
    **Admin → ERP API → Customer review link base URL**). Behind a reverse proxy this is the proxy's public host.
  - **`alerts`**: `webhookUrl` (Teams/Slack) and/or `smtp` for the watchdog (step 9). Empty = log only.
  - **`retention`**: the data-retention horizons — the example defaults are sensible; tune later if the auditor specifies.
  - Leave `jwtAuth` / `swivelLink` / `llm` off unless that integration is in scope.
> **You should now see:** the file parses — `(Get-Content "<OPS_ROOT>\ops.config.<tenant>.json" -Raw | ConvertFrom-Json).opsDb`
> prints your DB name.

---

## 4. Create the database + all tables  (you create NO tables by hand)

`setup-ops.ps1` creates the ops database (if it does not exist) and **all tables + indexes, idempotently** —
re-running it is safe. The only prerequisite is that the login in your config can create a database (or the empty
DB already exists and the login is `db_owner`).

**One command does it (recommended):** `first-install\setup-database.bat` creates the ops DB (if absent) + all tables
idempotently AND seeds the milestone matrix. Pass the tenant config through:
```cmd
cd "<OPS_ROOT>"
first-install\setup-database.bat -ConfigPath ".\ops.config.<tenant>.json"
```
(Or run the two scripts by hand: `.\setup-ops.ps1 -ConfigPath ...` then `.\seed-milestone-config.ps1 -ConfigPath ...`.)
> **You should now see:** `Operational database [...] ready (NN tables + indexes)` from setup, and a milestone
> count from the seeder. Confirm:
> ```powershell
> Invoke-Sqlcmd -ServerInstance "<opsServer>" -Database "<opsDb>" -Query "SELECT COUNT(*) AS tables FROM sys.tables; SELECT COUNT(*) AS milestones FROM dbo.milestone_def"
> ```
> `tables` >= 21 and `milestones` = 37. (No `Invoke-Sqlcmd`? Use SSMS, or you will also see the table list in the
> app's **Audit & Health → Storage** tab at step 10.)
>
> The logins/roles/scope live in SQL (`dbo.app_user` + `dbo.app_user_scope`), not a JSON file. The first time the
> app starts **with `OPS_ALLOW_SEED=1` set** it seeds a **default admin (admin / admin123)** into `app_user` (or, if
> a legacy `users.json` is present, imports it once and keeps the file only as a backup) — see step 10.

> 🔒 **`OPS_ALLOW_SEED` (first-install only).** The seed/import runs ONLY when `app_user` is empty AND
> `OPS_ALLOW_SEED=1`. This is a deliberate guard: without it, a later redeploy that accidentally points the app at
> the wrong/empty database would silently re-create `admin/admin123` and "lose" the customer's real users. Set
> `OPS_ALLOW_SEED=1` for the very first start, then **clear it** once your real admin exists. On any normal start
> (table already populated) it is ignored. If a deploy ever shows the error *"dbo.app_user is EMPTY … and
> OPS_ALLOW_SEED is not set"*, the app is pointed at the wrong DB — fix `OPS_CONFIG`/`OPS_ROOT`, do not just set
> the flag. The first startup line logs `[Config] ops DB target: Server=…; Database=…` so you can confirm which DB it opened.

---

## 5. Publish + create the IIS site

- [ ] **(build box)** Publish the app (needs the .NET 10 SDK; can be your dev box, not the server):
```powershell
cd "<OPS_ROOT>\server"
dotnet publish -c Release -o publish
```
  This produces `server\publish\` (`Ops.dll` + a generated `web.config` wired for in-process ANCM hosting).
  **Secrets are NOT in the publish folder** — they stay in `<OPS_ROOT>` (see [Part B §IIS deploy](#iis-deploy-reference)).
- [ ] **[admin]** Easiest path — run the bundled bootstrap once (enables IIS, checks the Hosting Bundle, creates
      the app pool, sets the pool env vars, grants DB + NTFS rights, creates the site). Adapt the paths inside it
      for this tenant, then:
```powershell
.\first-install\deploy-local-iis-demoerp.ps1
```
  **Or** do it by hand: app pool = **No Managed Code**; set these as **app-pool environment variables** (they
  survive a re-publish, unlike `web.config` — see [Part B §Environment variables](#environment-variables)):
  `OPS_ROOT=<OPS_ROOT>`, `OPS_CONFIG=ops.config.<tenant>.json`, `OPS_HTTPS=1`, `OPS_DB_GATE=16`; site physical
  path = `server\publish`; add the **https:443** binding + cert.
- [ ] **[admin]** Site **Authentication**: **Anonymous = ON, Windows = OFF** (the app does its own login).
- [ ] **[admin]** Remove **WebDAV** (it hijacks the `OPTIONS` verb and breaks the third-party API CORS preflight):
      Server Manager → remove *WebDAV Publishing*, or add the `<remove name="WebDAVModule"/>` block to `web.config`
      (see [Part B §Third-party Find API on IIS](#third-party-find-api-on-iis)).
> **You should now see:** browse `https://<host>/api-ops/health` → `{"ok":true,"db":"up",...}`. And
> `https://<host>/users.json` → **404** (secrets are blocked). If health shows `db:down`, the DB connection in the
> config is wrong or the app-pool identity has no DB access (step 6).

---

## 6. Grant the app database access

The app connects to the ops DB as the **app-pool identity** (when `auth=integrated`) — that login needs rights.
- [ ] **[admin]** In SQL (the `first-install\deploy-local-iis-demoerp.ps1` script does this for the demo pool):
```sql
CREATE LOGIN [IIS APPPOOL\<your-app-pool>] FROM WINDOWS;
USE [<opsDb>];
CREATE USER  [IIS APPPOOL\<your-app-pool>] FOR LOGIN [IIS APPPOOL\<your-app-pool>];
ALTER ROLE db_owner ADD MEMBER [IIS APPPOOL\<your-app-pool>];
```
> **You should now see:** `https://<host>/api-ops/health` → `"db":"up"`. (If you use SQL auth instead, set
> `opsAuth:"sql"` + `opsUser`/`opsPassword` in the config and skip this step.)

---

## 7. Fill the operational data (seed, in this order)

These read the **live ERP** (VPN must be up if remote) and write only the ops DB. Run once now; step 8 schedules the repeats.

**One command does it (recommended):** `seed-data.bat` runs all the seeders below in order, looping every station
in your config × Sea/Air:
```cmd
seed-data.bat -ConfigPath ".\ops.config.<tenant>.json"
```
Or run them by hand, per station (`-Station` = the source DB name, `-StationCode` = the branch code):

- [ ] **Station map** (cross-station routing): `.\seed-station-map.ps1 -ConfigPath ".\ops.config.<tenant>.json"`
- [ ] **Ports**: `.\seed-ports.ps1 -ConfigPath ".\ops.config.<tenant>.json"`
- [ ] **Liners/carriers**: `.\seed-liners.ps1 -ConfigPath ".\ops.config.<tenant>.json"`
- [ ] **Inbound feed** (per station + mode): `.\publish-bookings.ps1 -ConfigPath ".\ops.config.<tenant>.json" -Station <db> -StationCode <CODE> -Mode Sea` (then `-Mode Air`)
- [ ] **Worklist** (per station + mode): `.\seed-alerts.ps1 -ConfigPath ".\ops.config.<tenant>.json" -Station <db> -StationCode <CODE> -Mode Sea -AsOf (Get-Date -Format 'yyyy-MM-dd')` (then `-Mode Air`)
> **You should now see:** browse `https://<host>/` and the **worklist loads with shipments**. Confirm a non-zero
> count: `SELECT COUNT(*) FROM dbo.shipment_alerts` > 0. (`listener-engine.ps1` is not built yet; the scheduled
> `seed-alerts.ps1 -Delta` in step 8 is the stand-in that keeps the worklist fresh.)

> `seed-alerts.ps1` is the **listener stand-in** — a one-shot evaluator/upsert. Run it **once in full-snapshot
> mode (no `-Delta`)** to backfill, then the scheduled jobs use **`-Delta`** for cheap incremental refreshes. It
> also pulls booking-stage rows (`awb_type='B'`, stamped `bill_stage='booking'`), so a just-created booking appears
> in the worklist (a **BOOKING** badge) the moment it exists.

---

## 8. Schedule the recurring jobs  **[admin]**

`register-ops-tasks.ps1` registers every recurring job: the feed publishers (Sea 3×/day, Air 2h), the **delta
worklist refresh** (`Ops Worklist *` = `seed-alerts.ps1 -Delta`, Air ~5 min / Sea ~15 min), the **new-booking
factory-alert watcher** (`Ops Booking Watch *`, ~5 min), the weekly master refreshes, **and the three governance
jobs** — `Ops Backup` (nightly), `Ops Healthcheck` (every 25 min), `Ops Purge` (weekly). Cadence is tunable:
`-WorklistAirMins` / `-WorklistSeaMins` / `-BookingWatchMins`. It MUST run elevated (it exits otherwise). **Run the
full data fill (step 7) first** — the delta tasks only pull *changes* after that baseline.

The station set is taken from `stations[]`, so N stations → N task sets. **These jobs run on whatever host you
schedule them on and write the ops DB directly — in production that is the server (VPN up if remote), not a
workstation; the IIS app only reads the same DB.**

- [ ] Run it from an **elevated** shell:
```powershell
.\register-ops-tasks.ps1 -ConfigPath ".\ops.config.<tenant>.json"
```
> **You should now see:** `N task(s) registered, 0 failed`. Confirm:
> ```powershell
> Get-ScheduledTask -TaskName "Ops *" | Format-Table TaskName, State
> ```
> All show **Ready**. Within ~25 min `Ops Healthcheck` runs once and the app's **Health board** (step 10) goes
> green. To not wait, run it once now: `Start-ScheduledTask -TaskName "Ops Healthcheck"`.

---

## 9. First backup + alerting

- [ ] Run a backup now (do not wait for tonight):
```powershell
.\backup-ops.ps1 -ConfigPath ".\ops.config.<tenant>.json"
```
- [ ] Test alerting: set `alerts.webhookUrl` (or `smtp`) in the config, then run the watchdog and confirm a
      message arrives when a check fails:
```powershell
.\ops-healthcheck.ps1 -ConfigPath ".\ops.config.<tenant>.json"
```
> **You should now see:** `BACKUP ok: ...\backups\<opsDb>_<date>.bak (NN MB)`. If you instead see
> `Operating system error 5 (Access is denied)`, the SQL service account cannot write the backup folder — redo the
> `icacls` grant in step 2 with the correct service account, then re-run. After the watchdog runs, the **Health
> board** shows `backup` green with a fresh "last OK".

---

## 10. Sign in as the default admin, change its password, then add users

The app is **secure-by-default**: on first start (with `OPS_ALLOW_SEED=1` set) it seeded a **default admin** into
SQL, so there is no open/no-login mode to close. (If you migrated from an older deploy with a `users.json`, those
accounts were imported instead — sign in with an existing admin and skip the password step.)

- [ ] Browse `https://<host>/` and sign in with **`admin` / `admin123`**.
- [ ] **Clear `OPS_ALLOW_SEED`** now that the admin exists (remove the app-pool / shell env var), so it can't re-seed later.
- [ ] **Immediately change the password:** **Admin** (top-right) → **Users** tab → open `admin` → set a new
      password → Save. (You can also rename it / set a real email here.)
- [ ] Add the real users: **+ Add user** — set username, **email (required — it is the sign-in key)**, a password,
      Role, stations/access. Save. (Users persist in `dbo.app_user` / `dbo.app_user_scope`, not a file. The full
      role/scope model is in [4-OPERATE-SUPPORT.md §Users & roles](4-OPERATE-SUPPORT.md#managing-user-accounts--roles).)
> **You should now see (all in the browser, no database tools):**
> - The **Users** tab lists `admin` plus the user(s) you created.
> - **Admin → Audit & Health** tab: **Health** board (`app`, `db`, `backup`, `storage:*` green; `tasks` green
>   after the first watchdog run); **Storage & growth** (DB size, largest tables, free disk).
> - **Admin → Change log** tab (date-ranged, default today): a `create user …` line for the user you added, a
>   `login ok` line for your sign-in; **Server errors** empty; **ERP API calls** (tick *failures only* to see errors).

---

## 11. Go-live sign-off

- [ ] `https://<host>/api-ops/health` returns `200 {"ok":true,...}`.
- [ ] `https://<host>/users.json` returns **404**; `https://<host>/ops.config.json` returns **404** (secrets blocked).
- [ ] Login works and appears in **Change log → Change & access audit**.
- [ ] Worklist loads; open one shipment and **reconcile one milestone light against a direct ERP SQL read**
      (house rule — confirms the data is right, not just present).
- [ ] `Get-ScheduledTask "Ops *"` all **Ready**; **Health board** all green (or only expected ambers).
- [ ] One successful `.bak` exists in `<OPS_ROOT>\backups`, and an alert channel is configured.
- [ ] When the ERP write token is provided, set it in **Admin → ERP API** (Base URL + token, untick "use mock") —
      the status flips to **LIVE**, no restart — and re-test one Save-to-ERP. Confirm the call in **Change log → ERP API calls**.

**Handoff to support:** [4-OPERATE-SUPPORT.md](4-OPERATE-SUPPORT.md) (the daily glance is the **Audit & Health** tab).
**For the next code update:** [3-DEPLOY-UPDATES.md](3-DEPLOY-UPDATES.md) — do **not** re-run the first-install scripts on a live site.

---

# Part B — Install-time reference

## Config file fields

`ops.config.<tenant>.json` (copied from `ops.config.example.json`, gitignored). Env vars `DB_*` / `OPS_*` override
the file for headless runs.

| Field | What to put |
|---|---|
| `server` / `auth` / `user` / `password` | the source ERP SQL host + login (read-only) |
| `opsServer` / `opsAuth` / `opsUser` / `opsPassword` / `opsDb` | the **ops DB** host + creds (omit server to use the source server). See [two-server mode](#two-server-mode) |
| `masterDb` | the master DB (`fm3kco`) for the intercompany convention |
| `port` | the web port (dev/Kestrel; IIS bindings win in production) |
| `stationCode` / `stations[]` | the home station + the picker list (`{ code, name, country, database }` per branch) |
| `appName` / `instanceName` / `appSubtitle` | branding |
| `asOfDate` | optional ISO date — treat as "today" for a frozen snapshot; empty = real today |
| `erpApi` | the Swivel ERP API (`baseUrl` + bearer `token` + `mock`) — see [ERP-API connection](#erp-api-connection) |
| `publicBaseUrl` | internet-facing HTTPS host for `<publicBaseUrl>/bl-review/<token>` review links |
| `alerts` | `webhookUrl` (Teams/Slack) and/or `smtp` for the watchdog. Empty = log only |
| `retention` | data-retention horizons (see [4-OPERATE-SUPPORT.md](4-OPERATE-SUPPORT.md#data-retention--growth)) |
| `jwtAuth` / `swivelLink` / `llm` | optional integrations (third-party Find API / L!NK OAuth / LLM fallback) — off unless in scope |

## Two-server mode

When the network ERP login cannot `CREATE DATABASE`, the ops DB is created **locally** while the ERP is read remotely:

- Read the `fm3k*` ERP on the source server (login `dashboard`, read-only).
- Write `erpops` on `localhost\SQLEXPRESS` (or any ops server you control).

Set `opsServer` / `opsAuth` / `opsDb` in the config. All scripts route `master` + the ops DB to the ops server and
everything else to the source. **For office use**, point `opsServer` at an office-reachable SQL instance and re-run
`setup-ops.ps1` + the seeders there.

## IIS deploy reference

The web tier runs as the **ASP.NET Core app** (`server/`, .NET 10) hosted **in-process** behind IIS (ASP.NET Core
Module) terminating **TLS**. App↔IIS is loopback; only IIS faces the network. The same app runs standalone over
HTTP for dev: `server\start-dotnet.bat` (binds the config port; `OPS_HTTP_PORT` overrides).

**`web.config`** (generated by `dotnet publish`) is already wired for in-process ANCM:
```xml
<aspNetCore processPath="dotnet" arguments=".\Ops.dll" hostingModel="inprocess" stdoutLogEnabled="false" stdoutLogFile=".\logs\stdout" />
```

**`OPS_ROOT` — config + client files.** The app reads `ops.config.json` and serves the client files (`index.html`,
`ops.js`, `styles.css`, `admin-ops.html`, `bl-review.html`, `doc-fields.json`, **`i18n.js`, `lang/*.json`**, …)
from `OPS_ROOT`, and reads/writes `users.json`, `ops-lists/`, `erp-api-map.json`, `erp-mock/`, `*-audit.log` there
too. **`OPS_ROOT` must contain the `lang/` folder** or the UI silently falls back to English. If unset, the app
walks up from its own folder looking for the config — **set it explicitly for an IIS deploy** where `publish\` is elsewhere.

> **Static serving is auth-bypassing by design** (the client shell loads before login). The app **blocks**
> requests for `*.json` (except `doc-fields.json` and `lang/*.json`), `*.ps1`, `*.bat`, `*.log`, `*.cs`, `*.csproj`,
> and the `ops-lists/` `server/` `erp-mock/` `.git` paths — secrets in the root are never served.

**App pool.** New pool, **.NET CLR = "No Managed Code"** (the app self-hosts via ANCM). Start mode *AlwaysRunning*
to keep it warm. The pool **identity** needs read/write on `OPS_ROOT` and network access to the `erpops` DB + the
source ERP (over the VPN if remote). `ApplicationPoolIdentity` works if the VPN is machine-wide; use a
domain/service account if the VPN or a file share needs it.

### Environment variables

Set on the **app pool** (they persist across publishes — `dotnet publish` regenerates `web.config`, so env vars
written *into* `web.config` are lost on the next publish):

| Var | Purpose |
|---|---|
| `OPS_ROOT` | folder holding `ops.config.*.json` + client files + `lang/` |
| `OPS_CONFIG` | the per-tenant config file (e.g. `ops.config.acme.json`) |
| `OPS_HTTPS=1` | Secure cookies + HSTS |
| `OPS_IFRAME=1` | **only** for the L!NK iframe: `SameSite=None; Secure; Partitioned` cookies |
| `OPS_DB_GATE=16` | max concurrent SQL ops (tune to SQL/VPN) |
| `DB_*` | override the config DB settings (`DB_SERVER`, `DB_OPS_SERVER`, `DB_OPS_DB`, …) |
| `SWIVEL_OAUTH_*` / `OPS_JWT_*` | L!NK OAuth / JWT bearer config, if used |

Persist one on the pool:
```
appcmd set config -section:system.applicationHost/applicationPools /+"[name='<pool>'].environmentVariables.[name='OPS_CONFIG',value='ops.config.<tenant>.json']" /commit:apphost
```
`first-install\deploy-local-iis-demoerp.ps1` does exactly this. When hosted in IIS, **ANCM sets the listening URL** — the app's
own port binding (8078) is ignored, so the site's IIS bindings (443) are authoritative.

### HTTP→HTTPS redirect + HSTS

- The app emits **HSTS** on HTTPS responses when `OPS_HTTPS=1`, and honors `X-Forwarded-Proto`/`-For` from IIS (so
  `Request.IsHttps` + the client IP logged in `doc_event_log` are correct behind the proxy).
- For the **redirect**, install the IIS *URL Rewrite* module and add an `http→https` rule (or use *HTTP Redirect*).
  Keeping the redirect at IIS avoids an in-process redirect loop.

### Public review surface (`/bl-review/*` + `/api-doc/*`)

The customer draft-document review is **public** (the SHA-256 review token is the only authority — no login). If
you front the app with a separate public reverse proxy for customers, expose **only** `/bl-review/*`, `/api-doc/*`,
and the review assets (`bl-review.html`, `bl-review.css`, `bl-form.js`, `doc-fields.json`). Set `publicBaseUrl` to
the internet-facing HTTPS host so `doc-send` builds correct `<publicBaseUrl>/bl-review/<token>` links.

### Third-party Find API on IIS

`POST /api-ops/find-text` + `GET /api-ops/find` let an external app call Find with a **JWT bearer** (see [8-API.md](8-API.md)).
Two IIS settings break a fresh site even though the app handles them correctly:

1. **Remove WebDAV so the CORS preflight reaches the app (the critical one).** IIS's **WebDAVModule** intercepts
   the `OPTIONS` verb and returns **405**, killing the browser CORS preflight. Uninstall *WebDAV Publishing*
   (Server Manager → Web Server) — cleaner, survives republish — or add to the published `web.config`:
   ```xml
   <system.webServer>
     <modules><remove name="WebDAVModule" /></modules>
     <handlers><remove name="WebDAV" /></handlers>
     <security><requestFiltering><verbs allowUnlisted="true" /></requestFiltering></security>
   </system.webServer>
   ```
   A pure server-to-server caller sends no preflight, so it works without this; a **browser** client needs it.
2. **Anonymous Authentication ON, Windows Authentication OFF** — with Windows Auth on, IIS challenges the request
   and the `Authorization: Bearer …` header never reaches the app (401s).
3. **JWT config is config-only.** Put the `jwtAuth` block (provider public key, `issuer`, `emailClaim`) in the
   tenant config under `OPS_ROOT` (the public key is not a secret). For env, set `OPS_JWT_*` on the app pool.
4. **Outbound HTTPS only if you use `jwtAuth.jwksUrl`** (with an inline `publicKey`, nothing extra).
5. **HTTPS** — keep `OPS_HTTPS=1`.

> Name→code resolution uses `port_dim` / `liner_dim` / `company_dim`; seed them with `seed-ports.ps1` +
> `seed-liners.ps1` (the weekly refreshes are scheduled by `register-ops-tasks.ps1`).

### Concurrency / hosting notes

- Sessions are **in-process** (single server). The **dbGate** (default 16) bounds in-flight SQL so a burst can't
  stampede the small-MTU VPN SQL box; the large `ports` reference read self-caches (15 min). There is **no generic
  cross-user response cache** by design — ops reads are per-scope/write-volatile, so a shared cache would risk a
  cross-scope leak. Scaling to multiple IIS servers → sticky sessions (the handlers won't change).
- **Build/deploy is compiled** — re-`dotnet publish` + restart the app pool on each code change ([3-DEPLOY-UPDATES.md](3-DEPLOY-UPDATES.md)).
- The **SQL box over the VPN is the real ceiling**; the dbGate + active-only hot table keep it healthy.

## Tenancy (multiple customers)

Config-driven, **one deploy per customer**: same binaries, each customer runs its own IIS site (or app pool)
pointed at its own `OPS_ROOT` + `ops.config.<tenant>.json` (own server/creds/`opsDb`/`stations[]`/branding/
`erpApi`) and its own `erpops` database. Nothing is hardcoded, so isolation is structural (separate process +
separate DB) and there is no tenant code to maintain. One customer = one `erpops` DB shared across all its branches
(branches are rows tagged by the `station` column, not a DB per branch).

## VPN — the Swivel tunnel

When deploying **remotely** (e.g. our test box), the source-ERP SQL hosts are reachable **only** through the Swivel
OpenVPN tunnel. (At the customer site the server is on the LAN — no VPN.) There is a local **`swivel-vpn`** skill/helper:

```powershell
.\.claude\skills\swivel-vpn\scripts\swivel-vpn.ps1 -Check    # tunnel up? routes? reachability
.\.claude\skills\swivel-vpn\scripts\swivel-vpn.ps1 -Fix      # elevated: add the more-specific routes
```

> ⚠️ **Surfshark conflict.** If Surfshark is running it (1) throws a phantom "VPN being utilised by another Windows
> user" in OpenVPN Connect — **disconnect Surfshark in its app**; and (2) plants a competing `192.168.0.0/21` route
> that black-holes `192.168.5.2`. **Fix without disconnecting Surfshark:** add a more-specific route so
> longest-prefix-match wins — `New-NetRoute -DestinationPrefix '192.168.5.0/24' -InterfaceIndex <tunIfIndex>
> -NextHop <tunGateway> -RouteMetric 1` (elevated). The `-Fix` helper does this automatically.

Confirm with `Test-NetConnection 192.168.5.2 -Port 1433` (`TcpTestSucceeded = True`). `PingSucceeded` is often
False — ICMP is filtered; ignore it.

## ERP-API connection

The draft HBL/HAWB **Issue**, **Book Now**, **Edit ERP data** and **Generate document** features post to the
**Swivel 3rd-party ERP API**. Two config locations:

- **`erp-api-map.json` (tracked, non-secret)** — deployment codes that must match the ERP masters:
  **`partyGroupCode`** (the company code, e.g. `DEV` — also editable in the admin **ERP API** tab),
  **`forwarderCode`** (the *fallback* office owncode), `serviceCodeDefault`, `commodityFallback`, the `event`
  (`transportBill`), `documentTypeCode` (`BL_REVIEW`), and `bookingUpdateMode` (`strict` / `best-effort`).
- **`ops.config.json` → `erpApi` (gitignored, SECRET)** — `baseUrl` + the **bearer token** from Swivel. **Or set
  these in Admin → ERP API** (`dbo.app_setting`), which overrides the config at runtime — so at a customer the
  token need not sit in a file. The DB value wins; a blank DB value falls back to the config.

```json
"erpApi": { "baseUrl": "https://demoerp-api.swivelsoftware.com", "token": "<bearer token>", "mock": false }
```

> ⚠️ **No `erpApi` block (or blank token) = MOCK mode.** Writes go to `erp-mock/*.json` and **nothing reaches the
> ERP**. The UI flashes *"(MOCK mode)"*. Add the token to go live.

> 🧭 **`forwarderCode` is the office owncode — resolved PER STATION, not hard-coded.**
> `Resolve-ForwarderCode($station)` → `Get-StationOwnCode` reads `fm3kco.site` (dbname → owncode, e.g. HKG=`S0001`,
> SHA=`S0002`, SIN=`S0005`) and feeds `/booking/get`, `/booking/update` (`bookingParty.forwarderPartyCode`, always
> sent), `/file/*` and `/document/generate`. The ERP **422s a wrong forwarder code**, so a single static code would
> misroute every non-HQ station.

What each ERP button does is in [5-BUSINESS-GUIDE.md](5-BUSINESS-GUIDE.md); the admin tabs (Documents / Generate
documents / ERP API) are in [4-OPERATE-SUPPORT.md](4-OPERATE-SUPPORT.md#managing-user-accounts--roles).

## Language (i18n) — English / 中文 / 日本語

The operator UI is localized **client-side**; shipment **data, documents and notes stay as typed** (only captions
are translated). English is the source-of-truth and fallback.

- **Per-user default:** each user record carries a **`language`** field (`""` = follow the browser → English |
  `en` | `zh-Hans` | `ja`), set on the admin **Users** form. `/api-ops/me` returns it.
- **Per-device switch:** a header **language picker** lets anyone switch instantly (stored in `localStorage`, per device).
- **How it works:** `i18n.js` loads `lang/<code>.json` (English source string = key; a missing key falls back to
  English). The dictionaries are served statically — the static-secret guard is opened for `lang/*.json` only.
- **Adding a language:** see [6-DEVELOPER-GUIDE.md](6-DEVELOPER-GUIDE.md) — drop `lang/<code>.json`, add one line
  to `SUPPORTED` in `i18n.js`, add a font stack in `styles.css` if needed, add the code to the server allow-list.

> 🈶 Dictionaries are UTF-8 JSON. Keep `.ps1` ASCII-only (the dictionaries are external files, so no non-ASCII
> enters any script). HTML pages already have `<meta charset>`.
