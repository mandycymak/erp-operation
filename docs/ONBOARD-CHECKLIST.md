# Control Tower - Customer Onboarding & Deployment Checklist

**This is the only document you need to deploy and onboard a customer.** Follow it top to bottom. Every step ends
with a **You should now see** check - do not move on until you see it. Deploy is one-time; once this is done the
day-to-day is covered by `docs/OPERATIONS-RUNBOOK.md`.

- Run an **elevated** PowerShell (Right-click PowerShell -> *Run as administrator*) for the steps marked **[admin]**.
- Replace `<tenant>` with a short customer code (e.g. `acme`) and `<OPS_ROOT>` with the repo folder on the server
  (e.g. `C:\inetpub\erp-operation`). One customer = one IIS site + one config file + one `erpops` database.
- **Never commit secrets.** `ops.config.<tenant>.json`, `users.json`, `erp-api-map.json`, the `backups\` folder
  and the `*.log` files stay on the server only.

---

## 0. What you are installing (one minute)

A web app (ASP.NET Core, runs under IIS) + a set of scheduled PowerShell jobs (Task Scheduler) + one SQL Server
database called the **ops DB** (`erpops`). The app only ever READS the customer's source ERP databases and WRITES
the ops DB. You will: create the DB, fill it, create the IIS site, create the first admin user, and schedule the
jobs - then prove each worked from the browser.

---

## 1. Prerequisites  (check before touching anything)

- [ ] **Windows Server** with the **IIS** role, and the **.NET 10 Hosting Bundle** installed
      (`https://dotnet.microsoft.com/download/dotnet/10.0` -> "Hosting Bundle"; then run `iisreset`).
- [ ] A **headless browser** present (Microsoft Edge or Google Chrome) - used to render issued bills to PDF.
- [ ] A **TLS certificate** for the site hostname (real CA cert or imported into `LocalMachine\My`).
- [ ] The **VPN is up** and the customer's source ERP SQL host is reachable, and the **ops DB server** is reachable.
- [ ] The build output (`server\publish\`) copied to the server, OR the .NET 10 **SDK** on a build box to publish.

**Run these and confirm:**
```powershell
# ERP / DB reachability (replace host,port with the customer's source ERP SQL host):
Test-NetConnection -ComputerName 192.168.5.2 -Port 1433 | Select-Object TcpTestSucceeded
# Hosting Bundle / ASP.NET Core Module present:
Test-Path "$env:windir\System32\inetsrv\aspnetcorev2.dll"
```
> **You should now see:** `TcpTestSucceeded : True` and `True`. If either is False, stop - fix the VPN / install
> the Hosting Bundle before continuing.

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
> (If the SQL service account is wrong, you will find out at step 9 when the backup runs - error 5 = Access denied.)

---

## 3. Configuration file

- [ ] Copy the template and edit it for this customer (it is gitignored):
```powershell
Copy-Item "<OPS_ROOT>\ops.config.example.json" "<OPS_ROOT>\ops.config.<tenant>.json"
```
- [ ] Set, at minimum:
  - **Source ERP**: `server` (host,port), `auth` (`sql` or `integrated`), `user`/`password` (if sql).
  - **Ops DB**: `opsDb` (e.g. `erpops`). If it lives on a different SQL server than the ERP, also set
    `opsServer` / `opsAuth` / `opsUser` / `opsPassword` (two-server mode); otherwise it uses the source server.
  - **Branding**: `appName`, `instanceName`, `appSubtitle`. **`stationCode`** = the home station this instance serves.
  - **`stations[]`**: one entry per branch `{ code, name, country, database }` (the source ERP DB per branch).
  - **`erpApi`**: keep `"mock": true` until the customer's ERP write token is in hand.
  - **`alerts`**: `webhookUrl` (Teams/Slack) and/or `smtp` for the watchdog (step 9). Empty = log only.
  - **`retention`**: the data-retention horizons - the defaults in the example are sensible; tune later if the
    customer's auditor specifies different periods.
  - Leave `jwtAuth` / `swivelLink` / `llm` off unless that integration is in scope.
> **You should now see:** the file parses - `(Get-Content "<OPS_ROOT>\ops.config.<tenant>.json" -Raw | ConvertFrom-Json).opsDb`
> prints your DB name.

---

## 4. Create the database + all tables  (you create NO tables by hand)

`setup-ops.ps1` creates the ops database (if it does not exist) and **all ~18 tables + indexes, idempotently** -
re-running it is safe. The only prerequisite is that the login in your config can create a database (or the empty
DB already exists and the login is `db_owner`).

- [ ] Run it:
```powershell
cd "<OPS_ROOT>"
.\setup-ops.ps1 -ConfigPath ".\ops.config.<tenant>.json"
```
- [ ] Seed the milestone matrix (37 rule rows; reads config only, no ERP):
```powershell
.\seed-milestone-config.ps1 -ConfigPath ".\ops.config.<tenant>.json"
```
> **You should now see:** `Operational database [...] ready (18 tables + indexes)` from setup, and a milestone count
> from the seeder. Confirm:
> ```powershell
> Invoke-Sqlcmd -ServerInstance "<opsServer>" -Database "<opsDb>" -Query "SELECT COUNT(*) AS tables FROM sys.tables; SELECT COUNT(*) AS milestones FROM dbo.milestone_def"
> ```
> `tables` >= 18 and `milestones` = 37. (No `Invoke-Sqlcmd`? Use SSMS, or you will also see the table list in the
> app's **Audit & Health -> Storage** tab at step 10.)

---

## 5. Publish + create the IIS site

- [ ] **(build box)** Publish the app:
```powershell
cd "<OPS_ROOT>\server"
dotnet publish -c Release -o publish
```
- [ ] **[admin]** Easiest path - run the bundled bootstrap once (enables IIS, checks the Hosting Bundle, creates
      the app pool, sets the pool env vars, grants DB + NTFS rights, creates the site). Adapt the paths inside it
      for this tenant, then:
```powershell
.\deploy-local-iis-demoerp.ps1
```
  **Or** do it by hand: app pool = **No Managed Code**; set these as **app-pool environment variables** (they
  survive a re-publish, unlike `web.config`): `OPS_ROOT=<OPS_ROOT>`, `OPS_CONFIG=ops.config.<tenant>.json`,
  `OPS_HTTPS=1`, `OPS_DB_GATE=16`; site physical path = `server\publish`; add the **https:443** binding + cert.
- [ ] **[admin]** Site **Authentication**: **Anonymous = ON, Windows = OFF** (the app does its own login).
- [ ] **[admin]** Remove **WebDAV** (it hijacks the `OPTIONS` verb and breaks the third-party API CORS preflight):
      Server Manager -> remove *WebDAV Publishing*, or add the `<remove name="WebDAVModule"/>` block to `web.config`.
> **You should now see:** browse `https://<host>/api-ops/health` -> `{"ok":true,"db":"up",...}`. And
> `https://<host>/users.json` -> **404** (secrets are blocked). If health shows `db:down`, the DB connection in the
> config is wrong or the app-pool identity has no DB access (step 6).

---

## 6. Grant the app database access

The app connects to the ops DB as the **app-pool identity** (when `auth=integrated`) - that login needs rights.
- [ ] **[admin]** In SQL (the `deploy-local-iis-demoerp.ps1` script does this for the demo pool):
```sql
CREATE LOGIN [IIS APPPOOL\<your-app-pool>] FROM WINDOWS;
USE [<opsDb>];
CREATE USER  [IIS APPPOOL\<your-app-pool>] FOR LOGIN [IIS APPPOOL\<your-app-pool>];
ALTER ROLE db_owner ADD MEMBER [IIS APPPOOL\<your-app-pool>];
```
> **You should now see:** `https://<host>/api-ops/health` -> `"db":"up"`. (If you use SQL auth instead, set
> `opsAuth:"sql"` + `opsUser`/`opsPassword` in the config and skip this step.)

---

## 7. Fill the operational data (seed, in this order)

These read the **live ERP** (VPN must be up) and write only the ops DB. Run once now; step 8 schedules the repeats.
Run per station listed in your config (`-Station` = the source DB name, `-StationCode` = the branch code).

- [ ] **Station map** (builds the cross-station routing): `.\seed-station-map.ps1 -ConfigPath ".\ops.config.<tenant>.json"`
- [ ] **Ports**: `.\seed-ports.ps1 -ConfigPath ".\ops.config.<tenant>.json"`
- [ ] **Liners/carriers**: `.\seed-liners.ps1 -ConfigPath ".\ops.config.<tenant>.json"`
- [ ] **Inbound feed** (per station + mode): `.\publish-bookings.ps1 -ConfigPath ".\ops.config.<tenant>.json" -Station <db> -StationCode <CODE> -Mode Sea` (then `-Mode Air`)
- [ ] **Worklist** (per station + mode): `.\seed-alerts.ps1 -ConfigPath ".\ops.config.<tenant>.json" -Station <db> -StationCode <CODE> -Mode Sea -AsOf (Get-Date -Format 'yyyy-MM-dd')` (then `-Mode Air`)
> **You should now see:** browse `https://<host>/` and the **worklist loads with shipments**. Confirm a non-zero
> count: `SELECT COUNT(*) FROM dbo.shipment_alerts` > 0. (Note: `listener-engine.ps1` is not built yet; the
> scheduled `seed-alerts.ps1` in step 8 is the stand-in that keeps the worklist fresh.)

---

## 8. Schedule the recurring jobs  **[admin]**

`register-ops-tasks.ps1` registers every recurring job: the feed publishers (Sea 3x/day, Air 2h), the worklist
refresh, the weekly master refreshes, **and the three governance jobs** - `Ops Backup` (nightly), `Ops Healthcheck`
(every 25 min), `Ops Purge` (weekly). It MUST run elevated (it exits otherwise).

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
      message arrives when a check fails (it will report any real failure):
```powershell
.\ops-healthcheck.ps1 -ConfigPath ".\ops.config.<tenant>.json"
```
> **You should now see:** `BACKUP ok: ...\backups\<opsDb>_<date>.bak (NN MB)`. If you instead see
> `Operating system error 5 (Access is denied)`, the SQL service account cannot write the backup folder - redo the
> `icacls` grant in step 2 with the correct service account, then re-run. After the watchdog runs, the **Health
> board** shows `backup` green with a fresh "last OK".

---

## 10. Create the first user, then verify everything from the browser

Until a `users.json` exists the app is in **open mode** (no login). Creating the first admin turns auth ON.

- [ ] Browse `https://<host>/` -> you are auto-admin (open mode). Open **Admin** (top-right) -> **Users** tab ->
      **+ Add user**. Set username, **email (required - it is the sign-in key)**, a password, Role = admin, tick
      "may manage users". Save. (For many users, add them all here; the form writes `users.json`.)
- [ ] Sign out, then sign in with that email + password.
> **You should now see (all in the browser, no database tools):**
> - The **Users** tab lists the user(s) you created.
> - **Admin -> Audit & Health** tab:
>   - **Health** board: `app`, `db`, `backup`, `storage:*` green; `tasks` green after the first watchdog run.
>   - **Storage & growth**: the ops DB size, the largest tables (e.g. `shipment_alerts`), free disk.
> - **Admin -> Change log** tab (records are date-ranged, default today):
>   - **Change & access audit**: a `create user ...` line for the user you added, and a `login ok` line for your
>     sign-in (proof the audit trail is recording).
>   - **Server errors**: empty (or only benign entries). The date range + cap keep this readable even on a busy day.

---

## 11. Go-live sign-off

- [ ] `https://<host>/api-ops/health` returns `200 {"ok":true,...}`.
- [ ] `https://<host>/users.json` returns **404** (secrets blocked).
- [ ] Login works and appears in **Change log -> Change & access audit**.
- [ ] Worklist loads; open one shipment and **reconcile one milestone light against a direct ERP SQL read**
      (house rule - confirms the data is right, not just present).
- [ ] `Get-ScheduledTask "Ops *"` all **Ready**; **Health board** all green (or only expected ambers).
- [ ] One successful `.bak` exists in `<OPS_ROOT>\backups`, and an alert channel is configured.
- [ ] When the ERP write token is provided, set `erpApi.token` and `erpApi.mock=false`, recycle the app pool,
      and re-test one Save-to-ERP.

Handoff to support: **`docs/OPERATIONS-RUNBOOK.md`** (the daily glance is the **Audit & Health** tab).

---

### Redeploy a code fix later (safe pattern)
```powershell
# from the build box: publish to a NEW folder, keep the previous one for rollback
cd "<OPS_ROOT>\server"; dotnet publish -c Release -o publish_new
# on the server: take offline, swap, recycle
"offline" > "<OPS_ROOT>\server\publish\app_offline.htm"
# (copy publish_new over publish, or repoint the site physical path), then:
Remove-Item "<OPS_ROOT>\server\publish\app_offline.htm"
Restart-WebAppPool "<your-app-pool>"
# smoke test: /api-ops/health 200, login, worklist loads. Rollback = repoint to the previous publish + recycle.
```
