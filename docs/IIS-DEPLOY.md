# Deploying erp-operation (Control Tower) on IIS with HTTPS

The web tier now runs as an **ASP.NET Core app** (`server/`, .NET 10) instead of `serve-ops.ps1`. It is
multi-threaded (Kestrel) with **per-request row-level scope isolation** (the structural fix for the
single-threaded PowerShell server's shared-scope race) and a bounded DB-concurrency gate. This guide hosts it
behind **IIS** (in-process, ASP.NET Core Module) terminating **TLS**. App↔IIS is loopback; only IIS faces the
network.

> The same app still runs standalone over HTTP for dev/testing: `server\start-dotnet.bat` (binds the
> `ops.config.json` port, default 8078; `OPS_HTTP_PORT` overrides). IIS is only for the production HTTPS deploy.

The off-request-path PowerShell jobs (`seed-alerts.ps1`, `publish-bookings.ps1`, `seed-station-map.ps1`,
`seed-ports.ps1`, `seed-milestone-config.ps1`, `register-ops-tasks.ps1`) keep running under Task Scheduler —
they only write `erpops`, so they coexist with the new server unchanged.

## 1. Prerequisites (on the server, once)
1. **IIS** with the *Web Server (IIS)* role.
2. **.NET 10 Hosting Bundle** — installs the .NET runtime + the **ASP.NET Core Module v2 (ANCM)** into IIS.
   Download: <https://dotnet.microsoft.com/download/dotnet/10.0> → "Hosting Bundle". Then `iisreset`.
   Verify: IIS Manager → server node → *Modules* lists `AspNetCoreModuleV2`.
3. A **TLS certificate** for the site's hostname (a real CA cert, or import an existing one into
   `LocalMachine\My`).
4. The **Swivel VPN** reachable from the server — the source ERP SQL host (`18.136.126.101,1438` or the
   per-customer ERP server) is only reachable through it. The customer's `erpops` DB must also be reachable
   (it may live on the ERP server or a separate ops server — two-server mode, see `ops.config.json`).
5. A **headless browser** (Microsoft Edge or Google Chrome) installed on the server — used by `doc-issue` to
   render the agreed bill to PDF (`--print-to-pdf`). Optional: the issue proceeds without an auto-PDF if none is
   found. Override the path with the `pdfEngine` config key if it's installed somewhere non-standard.

## 2. Publish the app
From the repo (needs the .NET 10 SDK on the build machine — can be your dev box, not the server):
```
cd server
dotnet publish -c Release -o publish
```
This produces `server\publish\` containing `Ops.dll` + a generated **`web.config`** already wired for in-process
ANCM hosting:
```xml
<aspNetCore processPath="dotnet" arguments=".\Ops.dll" hostingModel="inprocess" stdoutLogEnabled="false" stdoutLogFile=".\logs\stdout" />
```
Copy `server\publish\` to the server (e.g. `C:\inetpub\erp-operation\`). **Secrets are NOT in the publish
folder** — they stay with the repo working copy (see `OPS_ROOT` below), so the web-facing folder holds only
binaries + the client static files served from `OPS_ROOT`.

## 3. Config + client files location (`OPS_ROOT`)
The app reads `ops.config.json` and serves the client files (`index.html`, `ops.js`, `styles.css`,
`admin-ops.html`, `bl-review.html`, `bl-form.js`, `doc-fields.json`, **`i18n.js`, `lang/*.json`**, …) from a
**root directory**, and reads/writes `users.json`, `roles.json`, `ops-lists/`, `erp-api-map.json`, `erp-mock/`,
`*-audit.log` there too. **`OPS_ROOT` must contain the `lang/` folder** or the UI silently falls back to English.
Point it at the repo working copy on the server:
```
OPS_ROOT = C:\path\to\erp-operation      (the folder holding ops.config.json + index.html)
```
If unset, the app walks up from its own folder looking for the config file — fine if `publish\` sits under the
repo, but **set `OPS_ROOT` explicitly for an IIS deploy** where `publish\` is elsewhere. To run a specific
tenant config, set `OPS_CONFIG` (e.g. `ops.config.acme.json`).

> **Static serving is auth-bypassing by design** (the client shell loads before login). The app **blocks**
> requests for `*.json` (except `doc-fields.json` and the **`lang/*.json`** UI dictionaries), `*.ps1`, `*.bat`,
> `*.log`, `*.cs`, `*.csproj`, and the `ops-lists/` `server/` `erp-mock/` `.git` paths — secrets in the root are
> never served. **This closes a real exposure in `serve-ops.ps1`, which served the static root unguarded**
> (`/ops.config.json`, `/users.json`, `/erp-api-map.json` were reachable). Patch the PS server too if it stays
> exposed during the cutover.

## 4. Create the IIS site
1. **App pool**: new pool, **.NET CLR version = "No Managed Code"** (the app self-hosts via ANCM). Start mode
   *AlwaysRunning* to keep it warm. The pool **identity** needs: read/write to `OPS_ROOT` and network access to
   the `erpops` DB + the source ERP over the VPN. `ApplicationPoolIdentity` works if the VPN is machine-wide;
   use a domain/service account if the VPN or a file share needs it.
2. **Site**: physical path = the `publish` folder you copied (e.g. `C:\inetpub\erp-operation`).
3. **Bindings**: add an **https** binding on 443, select the TLS certificate. (Optionally bind http:80 and
   redirect — step 6.)

## 5. Environment variables (set on the app pool or in web.config)
Easiest: add to `web.config` inside `<aspNetCore>`:
```xml
<aspNetCore processPath="dotnet" arguments=".\Ops.dll" hostingModel="inprocess">
  <environmentVariables>
    <environmentVariable name="OPS_ROOT"     value="C:\path\to\erp-operation" />
    <environmentVariable name="OPS_CONFIG"   value="ops.config.json" />        <!-- per-tenant config file -->
    <environmentVariable name="OPS_HTTPS"    value="1" />                       <!-- Secure cookies + HSTS -->
    <environmentVariable name="OPS_IFRAME"   value="1" />                       <!-- ONLY for the L!NK iframe: SameSite=None; Secure; Partitioned -->
    <environmentVariable name="OPS_DB_GATE"  value="16" />                      <!-- max concurrent SQL ops (tune to SQL/VPN) -->
    <!-- DB_* override the config if you prefer env over ops.config.json: DB_SERVER, DB_AUTH, DB_USER, DB_PASSWORD,
         DB_OPS_SERVER, DB_OPS_DB, DB_OPS_AUTH, DB_OPS_USER, DB_OPS_PASSWORD -->
    <!-- SWIVEL_OAUTH_PROFILE_URL / SWIVEL_OAUTH_XSYSTEM for L!NK OAuth sign-in, as today -->
  </environmentVariables>
</aspNetCore>
```
When hosted in IIS, **ANCM sets the listening URL** — the app's own port binding (8078) is ignored, so the
site's IIS bindings (443) are authoritative.

> ♻️ **`dotnet publish` regenerates `web.config`** — so env vars written *into* `web.config` are lost on the next
> publish. For a repeatable redeploy, set them on the **app pool** instead (they persist across publishes):
> `appcmd set config -section:system.applicationHost/applicationPools /+"[name='<pool>'].environmentVariables.[name='OPS_CONFIG',value='ops.config.<tenant>.json']" /commit:apphost`.
> The local-rehearsal script below does exactly this. Redeploy = re-`dotnet publish` to the same folder (drop a
> `app_offline.htm` first so the running app releases `Ops.dll`) and recycle the pool.

> 🧪 **Rehearse the whole thing locally first.** `deploy-local-iis-demoerp.ps1` (repo root, run **elevated**,
> once) installs IIS, checks the Hosting Bundle, grants the app-pool identity `db_owner` on the demoerp ops DB,
> sets `OPS_ROOT`/`OPS_CONFIG` as **pool env vars**, and creates an `http://localhost:8080` site pointing at
> `server\publish\`. `redeploy-demoerp.bat` is the minimal-effort redeploy. The production steps here are the
> same shape plus a 443 TLS binding + `OPS_HTTPS=1`. Both helper scripts hold paths only — no secrets.

## 6. HTTP→HTTPS redirect + HSTS
- The app emits **HSTS** (`Strict-Transport-Security`) on HTTPS responses when `OPS_HTTPS=1`, and honors
  `X-Forwarded-Proto`/`-For` from IIS (so `Request.IsHttps` + the client IP logged in `doc_event_log` are
  correct behind the proxy).
- For the **redirect**, install the IIS *URL Rewrite* module and add an `http→https` rule (or use the *HTTP
  Redirect* feature). Keeping the redirect at IIS avoids an in-process redirect loop.

## 7. Public review surface (`/bl-review/*` + `/api-doc/*`)
The customer draft-document review is **public** (the SHA-256 review token is the only authority — no login).
If you front the app with a separate public reverse proxy for customers, expose **only**:
- `/bl-review/*` (the review page) and `/api-doc/*` (the token API), plus the review assets
  (`bl-review.html`, `bl-review.css`, `bl-form.js`, `doc-fields.json`).
- Set `publicBaseUrl` in `ops.config.json` to the internet-facing HTTPS host so `doc-send` builds correct
  `<publicBaseUrl>/bl-review/<token>` links. Empty = `http://localhost:<port>` (testing only).

## 8. Verify
- Browse `https://<host>/` → the Control Tower loads; logging in works; the `ops_sid` cookie shows `Secure`.
- `https://<host>/ops.config.json` → **404** (secret blocked); `https://<host>/users.json` → **404**.
- Worklist, the drawer Tick-&-Confirm, the ERP-edit save, and the draft-doc lifecycle all work.
- For the L!NK iframe: confirm `ops_sid` is `SameSite=None; Secure; Partitioned` and sign-in works inside the
  frame. Point the L!NK iframe URL at the new HTTPS host if the host/port changed.
- Reconcile a couple of milestone lights / KPIs against a direct read-only ERP SQL query (CLAUDE.md house rule).

## Tenancy (multiple customers)
Config-driven, **one deploy per customer**: same binaries, each customer runs its own IIS site (or app pool)
pointed at its own `OPS_ROOT` + `ops.config.<tenant>.json` (own server/creds/`opsDb`/`stations[]`/branding/
`erpApi`) and its own `erpops` database. Nothing is hardcoded, so isolation is structural (separate process +
separate DB) and there is no tenant code to maintain. One customer = one `erpops` DB shared across all its
branches (branches are rows tagged by the `station` column, not a DB per branch).

## Notes
- **Concurrency**: sessions are in-process (single server, as chosen). The **dbGate** bounds in-flight SQL so a
  burst of users can't stampede the small-MTU-VPN SQL box; the large `ports` reference read self-caches (15 min).
  There is **no generic cross-user response cache** by design — ops reads are per-user/write-volatile, so a
  shared cache would risk a cross-scope leak. If you ever scale to multiple IIS servers behind a load balancer,
  switch to sticky sessions; the handlers won't change.
- **Build/deploy is compiled** (unlike `serve-ops.ps1`): re-`dotnet publish` + restart the app pool on each code
  change. The everyday dev loop stays `start-dotnet.bat` (Kestrel, no IIS).
- **The SQL box over the VPN remains the real ceiling.** The dbGate + the active-only hot table keep it healthy;
  if peak concurrency still saturates SQL, that's a SQL-infrastructure question, out of scope for the app.
