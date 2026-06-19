# erp-operation — Project Summary

Status snapshot of the Control Tower build. The authoritative design is **`BLUEPRINT.md`**; this file records
**what is actually built and proven** against real ERP data, plus the findings that shaped it. Read this first
when resuming. Operator-memory notes also live under `.claude/projects/.../memory/` (local + network DB setup).

**End-user / developer documentation lives in [`docs/`](docs/):**
[BUSINESS-GUIDE.md](docs/BUSINESS-GUIDE.md) (operators/managers) ·
[TECHNICAL-GUIDE.md](docs/TECHNICAL-GUIDE.md) (install/run/admin) ·
[DEVELOPER-GUIDE.md](docs/DEVELOPER-GUIDE.md) (coding standards) ·
[SQL-README.md](docs/SQL-README.md) (`erpops` schema + the verified ERP field map). This file remains the
session log / status snapshot.

## Status: working app — arrival-driven worklist, filters, multi-station, cross-station feed; Sea **and** Air. **Web tier now ported to ASP.NET Core (.NET 10) — `server/`.**

A clickable, end-to-end worklist app runs against real data on two test environments. The scheduled
`listener-engine.ps1` is still **deferred** — `seed-alerts.ps1` stands in for it (one-shot batch evaluator/upsert)
so the UI and Tick-&-Confirm loop can be exercised now.

**Latest session (2026-06-19 — demoerp brought up on this machine; admin login created; login accepts email OR username. RESUME HERE).**
An environment + auth session (no feature build): stood the .NET web tier up against demoerp on this PC and fixed an email-only login lockout.
- **demoerp running on :8079.** Recreated the gitignored **`ops.config.demoerp.json`** (two-server: source ERP `fm3k*` on `192.168.5.2`, read-only over the Swivel VPN + ops DB **`demoerp`** on local `localhost\SQLEXPRESS`, integrated). Both connections verified live (VPN up, `dashboard` creds valid). The local `demoerp` ops DB already held the 18-table schema + **1200 seeded `shipment_alerts` rows**; all 12 `fm3k*` stations reachable. Started from `server/` via `OPS_CONFIG=ops.config.demoerp.json dotnet run -c Release` -> Kestrel on :8079; worklist serves live (HKG Sea = 120 vessel groups / 120 shipments). `erpApi.mock=true` on this machine (no token -> ERP write/edit/file-upload mocked; all worklist/reads fully live).
- **Auth turned on + admin user created.** The working tree had no `users.json`, so the app was in **open/no-auth mode** (every visitor auto-admin — `Program.cs` GetSession returns `Admin=true` when `AuthOn` is false). Created admin **`mandy`** (email `mandy.mak@swivelsoftware.com`, password in the gitignored `users.json`); **creating the first user flips `AuthOn` true**, so login is now required. Gotcha confirmed: the admin Users form **requires an email** (it is the sign-in / L!NK key) — a user saved without one is rejected and never persists (this is what made it look like "no user in the DB").
- **Login now accepts email OR username (bug fix).** The server's `/api-ops/login` already falls back `FindUserByEmail(id) ?? FindUser(id)`, but `login.html` used `<input type="email">`, so the **browser** refused any value without `@` — the documented username fallback was unreachable from the UI. Changed to `type="text"` with label/placeholder **"Email or username"**; added the `Email or username` caption to `lang/zh-Hans.json` + `lang/ja.json` (no CJK regression). Verified both `mandy.mak@swivelsoftware.com` and `mandy` authenticate as admin. Static files — browser reload only, no rebuild.
- **Files (committed):** `login.html`, `lang/zh-Hans.json`, `lang/ja.json`, this summary. **Gitignored, not committed (per-machine):** `ops.config.demoerp.json`, `users.json`.

**Previous session (2026-06-18 — extracted the ERP master-lookup (port/customer/liner/service/incoterm) into a standalone, drop-in module for reuse in other projects).**
Pulled the master code-lookup out of the **Edit ERP data** editor into a self-contained kit under **`reusable/master-lookup/`**
(no framework, no build step) so it lifts cleanly into a sibling project. Two layers, sharing one `kind` contract
(`custsub`=customer · `port` · `liner` · `service` · `incoterm`) and the on-wire shape
`{ kind, results:[{code,name,loc?}] }`.
- **Source seams.** Client = `erp-edit.js` (`codeChip` / `openLookup` / `fmtMaster`) + the `erp-edit.html` chip/dropdown
  styles; server = `server/Handlers.Erp.cs` (`ErpMaster` + the fixed Incoterms-2020 list). Both lifted **verbatim** in
  behaviour; only the host coupling was stripped.
- **`master-lookup.js`** (`window.MasterLookup`): `chip()` (the editable `( CODE ) ...` chip → `{el,hintEl,value,changed}`),
  `open()` (the viewport-pinned + clamped type-ahead dropdown, preserved exactly — `position:fixed`, flips up near the
  bottom, focuses with `preventScroll`), `httpSearch()` (GET helper), `fmtMaster()`. **Transport-agnostic** — caller
  supplies `search(kind,q)`, so it works against the real API, a mock, or an in-memory list.
- **`MasterLookup.cs`** (`MasterLookup.Search(conn, kind, term, isAir)`): the same bounded `TOP 20` LIKE seek (8s),
  but **scope coupling removed** — no `shipment_alerts`/`ReqState`/`TestJobScope`/`Source`; takes an already-open
  source-ERP connection and inlines its own raw-ADO reader, so the **only** dependency is `Microsoft.Data.SqlClient`.
  Auth/scope is the caller's job in the endpoint wrapper (flagged in the README). Verbatim JSON casing via `JsonOpts`.
- **`master-lookup.css`** (chip + `.lookbox` styles, themed via CSS vars with standalone fallbacks), **`demo.html`**
  (every chip kind wired to an in-memory mock `search()` — opens in a browser, no backend), **`README.md`** (wiring for
  both ends + the `position:fixed` rationale). The widget's table/column names match the Swivel `fm3k*` masters — adjust
  the SQL strings if a target schema differs.
- **Note:** node/dotnet weren't on this session's PATH, so the automated `node --check` / build weren't run; the code is
  a faithful lift of already-live code. New files only (`reusable/master-lookup/*`); nothing in the running app changed.

**Previous session (2026-06-16c — UI internationalization (i18n): English + Simplified Chinese + Japanese; plus always-on ERP document upload).**
Added a lightweight, **no-build-step** localization layer so station staff can use the UI in their own language while
English stays the source-of-truth and one-click fallback. **Client-side captions only** (data, documents and user
notes stay as-is); scope = the operator-facing pages (`index.html`/`ops.js`/`login.html`). Verified live on :8079 via
headless-Edge DevTools (boot + translate + context-key + fallback) and a build.
- **New `i18n.js`** (shared, loaded before `ops.js`): `tr(en, ctx?)` with **English source string = key** (missing key
  falls back to English, never blank), `applyDom()` sweeps `data-i18n` / `data-i18n-title` / `-placeholder` /
  `-aria-label`, `boot(profileLang)` resolves language (**localStorage `lang` -> profile `ME.language` ->
  `navigator.language` -> en**), `setLang()` persists per-device + reloads. Mirrors the theme-toggle pattern. Context
  separator is the gettext `0004` written as the **escaped JSON text** (a raw control byte is invalid JSON — that bug
  was caught and fixed in verification).
- **Dictionaries** `lang/zh-Hans.json` + `lang/ja.json` (284 keys each, machine-draft for local staff to refine).
  Served statically — the `Program.cs` static-secret guard was opened for `lang/*.json` (it blocks all other `.json`).
  Adding a language later = drop `lang/<code>.json` + one line in `SUPPORTED` (+ the per-language font + server
  allow-list); `norm()` auto-detects any added language from `navigator.language` by primary subtag.
- **Retrofit:** `data-i18n*` attributes on static markup in `index.html`/`login.html`; `tr(...)` wraps the ~200 dynamic
  strings in `ops.js`; a header **language picker** (English / 中文 / 日本語). ISO dates and ERP/company data are never
  translated. `styles.css` gets per-language CJK font stacks (`html[lang="ja"]` JP fonts, `html[lang="zh-Hans"]` SC).
- **Profile plumbing:** a `language` field flows through `server/Auth.cs` (`UserRec`), `/api-ops/me` (`Program.cs`),
  admin user CRUD (`server/Handlers.Admin.cs` + the admin Users form `<select>`), `users.example.json`, and
  `serve-ops.ps1` (parity). Allow-list = `'' | en | zh-Hans | ja`.
- **UX note on caption length (measured):** Japanese/Chinese captions are *compact* (equal or shorter than English on
  the long labels; only short labels grow, at tiny absolute widths) -> **no overflow**. Spanish/European would be the
  expansion case; a one-time layout-robustness pass is the only thing those would need later.
- **Always-on ERP document upload (operator feedback).** The drawer's **ERP files** upload box was gated on a
  *clearable milestone* existing, so it hid on shipments (esp. **Air**) with files but no mapped milestone. Now it
  **always shows when the ERP is live**: server returns **`uploadDoctypes`** (all configured Document-tab types) beside
  `clearableDoctypes`; the picker lists every type and flags the milestone-clearing ones with a **`*`** (legend
  `* clears alert` in the caption, so the code reads e.g. `Booking*`, not `Booking (clears alert)`); free-text fallback
  if none configured. The upload handler already accepted any doctype — clearing stays a bonus. `Handlers.ErpFiles.cs` /
  `serve-ops.ps1` / `ops.js`.
- **Files:** new `i18n.js`, `lang/zh-Hans.json`, `lang/ja.json`; edited `index.html` `login.html` `ops.js` `styles.css`
  `admin-ops.html` `users.example.json` `server/{Auth,Program,Handlers.Admin,Handlers.ErpFiles}.cs` `serve-ops.ps1`.
  Admin/erp-edit/doc-editor/public bl-review pages are **not yet localized** (English) — the framework is ready for them.
- **Local IIS deploy rehearsal for `demoerp`.** To make the real deploy "copy the published version", set up the
  PC as IIS: created `ops.config.demoerp.json` (source ERP = same live `fm3k*`/`dashboard` as network; **opsDb
  `demoerp` on `localhost\SQLEXPRESS`**, integrated), ran `setup-ops.ps1` + `seed-milestone-config.ps1` (DB + 37
  defs), `dotnet publish -c Release -o server\publish`. Two new tracked helper scripts: **`deploy-local-iis-demoerp.ps1`**
  (one-time, **elevated**: enable IIS, ensure ASP.NET Core 10 Hosting Bundle, grant the app-pool identity
  `db_owner` on `demoerp`, NTFS on `OPS_ROOT`, app pool "No Managed Code" with **pool-level** `OPS_ROOT`/`OPS_CONFIG`
  env vars so re-publish doesn't clobber them, site on `http://localhost:8080`) and **`redeploy-demoerp.bat`**
  (`app_offline` -> publish in place -> recycle pool). **Connectivity confirmed** from this PC: VPN route
  `192.168.0.0/21`, `192.168.5.2` ping + TCP 1433 open. Remaining for the user: run the elevated script (needs
  admin; this session's shell wasn't), then seed stations (live-ERP reads). Committed `3611878`.
- **Docs refreshed for all of the above** (this turn): `README.md`, `docs/{TECHNICAL,DEVELOPER,BUSINESS}-GUIDE.md`,
  `docs/SQL-README.md`, `docs/IIS-DEPLOY.md` — .NET web tier as current, i18n (incl. "how to add a language"),
  always-on upload, and a real-server **Deploy** section (TECHNICAL-GUIDE §12 + IIS-DEPLOY) with the helper scripts.

**Previous session (2026-06-16b — operator-feedback round on the .NET port: erp-edit dropdown/UX, Sea/Air ERP-edit field-map fixes, team-aware @mentions. Committed `85a6fd5`).**
All work was on the **live .NET server** (`server/`, port 8079, network config = live `fm3k*` on 192.168.5.2 + local `erpops_net`), driven by hands-on testing of the staff **ERP-edit** editor. Server was rebuilt+restarted on 8079 after each `.cs` change; client files are static (reload only).
- **erp-edit master-lookup dropdown no longer shoves the form sideways.** `.lookbox` was anchor-relative `position:absolute; left:0`, so a right-side field (controlling cust / liner agent) spilled past the right edge, widened the page and pushed the shipper column off-screen; a naive leftward flip then spilled off the left. Rewritten to **viewport-fixed + clamped** (opens down, flips up near the bottom, clamps left/right, caps height with internal scroll) and focuses the search box with `preventScroll`; `.wrap{overflow-x:clip}` guard. `erp-edit.js` / `erp-edit.html`.
- **doc-editor: copy-link icon** beside the generated customer review link (`navigator.clipboard` + execCommand fallback, "Copied" flash). `doc-editor.js`.
- **ERP save "Liner cannot be blank" (500) fixed.** A Sea `/booking/update` carrying `bookingContainers` is rejected unless the booking's Liner = **carrierCode** is set; the patch omitted it so the ERP blanked the carrier. Now **read-merge the EXISTING carrierCode/carrierName** from `/booking/get` when containers are present, **SEA ONLY** (`module=="SEA"`; Air has no container table). Confirmed via `erp_edit_log`: identical edit failed WITH containers, saved WITHOUT. `server/Erp.cs EditPush`.
- **Liner agent recall (Sea only).** The editor read it only from `blcont.lagent`, blank when a booking has no container line. Now reads **`blcont.lagent` -> `blitem.lagent2` -> `blhead.ilagent`**, then a **"last saved here" overlay** from `erp_edit_log` when the BL read diverges/blank — because the ERP keeps the edited `linerAgentPartyCode` in its booking store and **never echoes it back** (not in `/booking/get`, not in the BL columns), which made operators re-enter it. Labelled "ERP read-back pending". `server/Handlers.ErpEdit.cs`.
- **Air commodity** now seeds from **`awbdetl.good_desc2`** (detail-line short cargo desc), distinct from Sea's `blitem.commodity`; header `awbhead.commodity` kept as fallback. Air-only branch. `server/Handlers.ErpEdit.cs`.
- **Team-aware @-mentions.** `/api-ops/roster` now returns **team + primary station** per user; the mention picker labels each colleague `@user - Name - Team / Station` and **matches on name/team/station** (so `@HKG` / `@HK-Import` narrows the ~500-user list). The **Arrangements +reminder** field — previously a plain text box with NO lookup, which is why mentions there "didn't find" anyone — now uses the **same picker** as the note composer. Typing a team is only a search filter (you still pick an individual; no team broadcast was requested). `server/Handlers.Misc.cs` / `ops.js` / `styles.css`.
- **NEXT CHAT = language / i18n.** The UI strings are **hard-coded English** throughout (`index.html`, `ops.js`, `erp-edit.html`/`erp-edit.js`, `admin-ops.html`, `login.html`, `bl-*`, server-side default strings); there is **no i18n layer** yet. Note the house encoding rule (keep `.ps1` ASCII-only; HTML pages need `<meta charset="utf-8">`; read files with `[IO.File]::ReadAllText`) — relevant once non-ASCII (e.g. Chinese) strings enter.

**Previous session (2026-06-16 — web tier migrated from `serve-ops.ps1` to an ASP.NET Core .NET 10 app in `server/`; all 7 stages built + verified live against demoerp).**
The single-threaded PowerShell `HttpListener` (`serve-ops.ps1`, ~2,288 lines, 44 routes) is **reimplemented as a
multi-threaded ASP.NET Core minimal-API** (`server/`, `net10.0`, one NuGet: `Microsoft.Data.SqlClient`, **raw ADO,
no Dapper**), mirroring the completed sibling migration at `..\erp-dashboard\server`. **Strangler, web tier only** —
the vanilla-JS client (`index.html`/`ops.js`/`admin-ops.html`/`bl-*`), every `/api-ops/*` + `/api-doc/*` JSON
contract, the `erpops` schema, and the off-request-path PowerShell jobs (`seed-alerts`/`publish-bookings`/etc.,
Task Scheduler) are **unchanged**. Plan: `.claude/plans/…single-effervescent-forest.md`.
- **Why .NET.** The PS server was single-threaded **for correctness, not just speed**: the current user's row-level
  scope lived in shared `$script:` state (`Cur-Stations`/`Cur-Pairs`/`Test-JobScope`/…), so serving requests
  concurrently would leak one user's data scope into another's query — an **authorization bypass**. The .NET port
  resolves scope into a **per-request `ReqState`** (never shared), the structural fix. Multi-customer = **config-driven
  deploy-per-customer** (one IIS site + `ops.config.<tenant>.json` + own `erpops` DB per customer; nothing hardcoded).
- **What's in `server/` (~40 `.cs` files, one area per file).** `Config.cs`/`Auth.cs`/`Sql.cs` (raw-ADO `Db.RunQ`/
  `RunMulti` reader loop, `Packet Size=512`, two-server source-ERP conn, transient retry)/`Filter.cs` (scope/where
  port)/`Program.cs` (no-store+CORS, ForwardedHeaders, HSTS, **static-secret guard**, `MapData`/`MapAuthed`,
  **`dbGate` SemaphoreSlim** default 16). Handlers: `Worklist`/`Shipment`/`Notes`/`Tasks`/`Inbound`/`Erp*`/`Doc`/
  `Public`/`Admin`/`Misc`. Net-new: **`Erp.cs`/`ErpDoc.cs`** (Swivel `HttpClient`: booking get/update, file
  enquiry/download/upload, event/update, read-merge-write guard, mock mode, per-station `forwarderCode`/owncode
  routing, all the live-call gotchas ported with comments), **`Pdf.cs`** (headless Edge/Chrome `--print-to-pdf`),
  **`Doc*.cs`** (draft-doc review + public token endpoints + `varbinary` attachments + SHA-256 tokens).
- **Faithful-to-PS decisions baked in:** **verbatim JSON casing** (`PropertyNamingPolicy = null` — the client reads
  exact keys); **no generic cross-user cache** (ops reads are per-scope/write-volatile — only the big `ports` ref read
  self-caches 15 min); **NLS collation** (`InvariantGlobalization=false` + `System.Globalization.UseNls=true` in the
  csproj) so culture-aware sorts match PS 5.1 `Sort-Object` exactly (the @-mention roster's punctuation order);
  **CRLF asymmetry** (seed returns raw ERP `\r\n`, save normalizes to `\n`) preserved; **CHIPS cookie**
  (`SameSite=None; Secure; Partitioned`) for the cross-site L!NK iframe; source-ERP reads bounded `CommandTimeout=8`.
- **Verified LIVE end-to-end against demoerp + live `fm3k*` (192.168.5.2) + `erpops_net`** (NOT the frozen fibsbkk —
  fibsbkk lacks columns fm3k has): **Stage 4b** `erp-edit-save` did a real `/booking/get`→`/booking/update` on
  `HKG-S-R23474`, read-merge preserved POL/POD/service, **no duplicate created**, then restored. **Stage 5** full
  draft-doc lifecycle (create→send→public view/submit→approve→agree→issue **with headless-Edge PDF**→amend; attachments
  up/download). **Stage 6** concurrency isolation — **60 concurrent disjoint-scope requests, 0 cross-scope bleed**.
  **Stage 7** parity harness **16/16 MATCH** (after the NLS fix caught a real roster sort DIFF) + **route coverage
  44/44**. All builds 0 errors/0 warnings.
- **New tracked files:** `server/` (the whole project), **`docs/IIS-DEPLOY.md`** (IIS/ANCM/HTTPS deploy + tenancy),
  **`docs/CUTOVER.md`** (the strangler flip runbook), **`tools/parity-check.ps1`** (coercion-tolerant JSON differ),
  **`start-dotnet.bat`**; `.gitignore` adds `server/bin|obj|publish/` + `*.user`. **Run:** from `server/`,
  `start-dotnet.bat` (or `OPS_CONFIG=ops.config.network.json OPS_HTTP_PORT=8079 dotnet run -c Release`) → Kestrel on
  the config port; **production = `dotnet publish -c Release` behind IIS** (the app is compiled, unlike the `.ps1`).
- **Remaining (operational, done in the deployment env — see `docs/CUTOVER.md`):** click-test each screen on the .NET
  port, stand it up on IIS/HTTPS, point the SWIVEL L!NK iframe URL + `publicBaseUrl` at the new host, retire
  `serve-ops.ps1` (left in-repo for rollback; off-path PowerShell jobs keep running). The .NET server was left
  **running live on http://localhost:8079** (auth mode, live demoerp) for hands-on testing at session end.

**Previous session (2026-06-15c — ERP-API routing identity made per-station (not hard-coded) + Save-data-to-ERP works live + login by email + SWIVEL L!NK OAuth seam).**
Two threads: getting the ERP `/booking/update` + file calls to route to the right office, and reworking sign-in.
- **ERP routing identity, resolved per station (never hard-coded).** Every Swivel call now carries the right
  `partyGroupCode` (the company/customer group = **`DEV`** on demoerp; now editable in the admin **ERP API** tab,
  stored in `erp-api-map.json` via `Set-ErpApiMap`) **and** the right **`forwarderCode` / `bookingParty.forwarderPartyCode`**
  = the office **owncode** ("where the data goes"). Owncodes are **distinct per office** (verified by SQL on
  `fm3kco.site`: HKG=`S0001`, SHA=`S0002`, SIN=`S0005`, BKK=`S0009`) — the old static `S0001` silently misrouted
  every non-HKG station, and the ERP **422s a wrong forwarder code**. New `Resolve-ForwarderCode($station)` →
  `Get-StationOwnCode` (cached `fm3kco.site` dbname→owncode, map fallback) feeds `/booking/get`, `/booking/update`
  (`forwarderPartyCode` is **always** injected — required by `NewBooking.bookingParty`), `/file/upload`,
  `/file/enquiry`, `/file/download`, and `/document/generate`.
- **Save-data-to-ERP proven LIVE (demoerp `HK012606010`).** The old payload-invariant blocker ("Departure date
  not active yet, Invalid carrier code") is **GONE** → `bookingUpdateMode` flipped back to **`strict`**.
  `/booking/update` now **read-merges** the schedule fields (`serviceCode`, `commodity`, POL/POD code+name) from
  the live `/booking/get` so an edit to one field no longer trips the ERP's `(500) "No such POL in job schedule"`.
  Document **upload** re-verified live (file lands + appears in `/file/enquiry`). `erp-doc-api.ps1` / `serve-ops.ps1`.
- **Sign-in is now by EMAIL** (username stays the internal identity — notes/@-mentions/sessions/`erpUsers`
  unchanged; username still works at login as a fallback so no one is locked out). `email` is required + unique.
  New `Get-OpsUserByEmail` + a `New-OpsSession` seam shared by every sign-in path. Per-user **`authProvider`**
  (`local` | `swivel` | `both`). admin-ops.html Users tab: email required, a **Sign-in** column + selector.
- **SWIVEL L!NK OAuth code-flow seam (scaffolded; env-gated, inert until configured).** `/api-ops/link-oauth-login`
  redeems the one-time `code` server-side at **`SWIVEL_OAUTH_PROFILE_URL`** (no client_id/secret — the code
  self-authenticates; for uat add the `SWIVEL_OAUTH_XSYSTEM` → `x-system` header), verifies the echoed `state`,
  **federates on `profile.email`**, auto-provisions a default-role user if none, then mints our own session.
  Frontend `linkBoot()` (`ops.js`) reads `?mode&site#code&state` from the L!NK iframe URL, redeems, scrubs the
  fragment. Profile endpoint = **`https://auth.swivelsoftware.asia/api/oauth/profile`** (the auth host, not the
  ERP host). Verified locally end-to-end with a mock profile server (gating, state-mismatch 401, email match,
  auto-provision). `swivelLink` config block; `/api-ops/config` exposes `linkEnabled`.
- Two logins set up in `users.json`: `mandy` (admin) email → `mandy.mak@swivelsoftware.com`; new `support`
  (manager, HKG) email `support@swivelsoftware.com`.
- Files: `serve-ops.ps1` `erp-doc-api.ps1` `erp-api-map.json` `admin-ops.html` `login.html` `ops.js`
  `users.example.json` `ops.config.example.json`. ERP-routing round committed `e4800b2`.

**Previous session (2026-06-15b — clear a milestone by uploading the missing document to the ERP + admin "Documents" tab to maintain the doctype↔milestone map. Committed `6a87a0a`).**
Operator-feedback round on milestone clearing: instead of only a manual Tick, an operator can now **upload the missing document straight to the ERP** and have the alert go green.
- **Upload-to-clear (the feature).** From the worklist drawer's **ERP files** panel: pick a document type + file → base64 in the browser → `POST /api-ops/erp-file-upload` (`Handle-ErpFileUpload`) → live Swivel **`/file/upload`** via the new standalone **`Invoke-ErpFileUpload`** (extracted from `Invoke-ErpDocIssue`; issue flow refactored to reuse it). **Nothing stored locally; the successful upload IS the proof** — on success `Close-MilestonesFor` flips the matching milestone(s) done (same checklist/rollup write-path as the manual Tick, via the extracted `Update-ChecklistRollup`). We do **not** wait for a re-seed (the evaluator reads `dbo.PIC`, a different store/code-space than `/file/upload`). `erp-doc-api.ps1` / `serve-ops.ps1` / `ops.js` / `styles.css`.
- **Derived, not hard-coded.** The doctype→milestone link is built by **`Get-MilestoneDoctypeMap`** (cached `$script:MsDoctypeMap`) from **`milestone_evidence_map`**, reset on any admin milestone/evidence edit — so admin changes flow through with no restart and no per-request parse. `Handle-ErpFiles` returns `clearableDoctypes` (the types that would clear an alert on that shipment) to populate the upload dropdown.
- **Admin "Documents" tab (new, 3rd tab in `admin-ops.html`).** CRUD over the `milestone_evidence_map` `pic_doctype` rows: **Document type (= ERP Document Type code, must match the ERP exactly)**, **Clears milestone** (code+bound dropdown), Module (SEA/AIR/any), Active. Backed by admin-gated **`/api-ops/admin/evidence`** (GET list + milestone_def list / POST upsert by `id`) + **`/admin/evidence-delete`**; both reset the cached map. This is the single source of truth for the upload dropdown — keep it matched to the ERP.
- **Doctype = the ERP code.** The document type string is sent **verbatim** as `/file/upload`'s `documentTypeCode`; the redundant `evidenceDocTypeCode` indirection was removed. **Renamed the M1 doctype "Booking Photo" → "BOOKING"** (the real ERP code, seen live in `/file/enquiry`) in the demoerp data AND `seed-milestone-config.ps1`.
- **Live-verified on demoerp:** `/file/upload` accepts all four evidence doctypes (`BOOKING`/`HBL`/`INVOICE`/`Arrival Notice`) **verbatim** and they appear in `/file/enquiry`; derived map + admin CRUD SQL correct; routes auth-gated (401 unauth); syntax clean (PSParser + `node --check` on the admin inline JS). **Still UI-click-untested** (needs an admin login, which the agent can't drive): verify the Documents tab + the drawer Upload flow turning M6 green. **Note:** left 4 probe test files (`ct-test-*.pdf` / `control-tower-test.pdf`, remark "safe to delete") on demo booking `HK012606010` — no `/file/delete` is built to remove them.
- New end-user reference **`milestone.md`** (tracked): the full alert matrix (what data/file each step needs) + the upload-to-clear flow.
- Files: `erp-doc-api.ps1` `serve-ops.ps1` `ops.js` `styles.css` `admin-ops.html` `seed-milestone-config.ps1` `milestone.md`. **Committed `6a87a0a`.**

**Previous session (2026-06-15 — house-level ERP-update key; filter declutter (Alerts/My-notes icons after POD); Vessel/Flight search; Air-Export flight number from the MASTER record).**
Operator-feedback round, triggered by checking job `SEHKG260100001` (which showed "no ERP data") and traced to the non-uniqueness of the ERP job number.
- **ERP-update key is now house-level, never the (one-to-many) `jobn`.** A single ERP `jobn` covers many houses (e.g. `SEHKG260100001` = the house `HK01SE6010001` **and** a master/console leg `…M01`), so keying `/booking/update` on it is ambiguous. `Save-ErpEdit` now derives the booking key from the freshly-read seed, mode-aware: **Sea `sono` → HBL (`blno`) → `jobn`** ; **Air `booking` → HAWB (`hawb`) → MAWB (`mawb`) → `jobn`** (the field name itself differs by mode — Sea calls it `sono`, Air calls it `booking`). Reads were already correct (keyed on the unique `erp_ref`); this fixes the **write** when `sono` is blank. `serve-ops.ps1`.
- **Filter declutter.** **Alerts** and **My notes** moved to the **end of the filter row (after POD)** and reduced to icons — **⚠** (Alerts) / **💬** (My notes) — full text kept in the tooltip + `aria-label`; new `.iconbtn` style. `index.html` / `styles.css` (toggle wiring in `ops.js` unchanged — it keys off the element id).
- **Search by Vessel / Flight.** New search-field option **"Vessel / Flight"** (`conv`) → matches `shipment_alerts.vessel_voyage`, the one column that holds the **sea vessel/voyage AND the air flight no**, so it serves both modes. Like the other identifier searches it ignores the date window + ownership lens. `index.html` / `ops.js` / `serve-ops.ps1`.
- **Air-Export flight number — from the MASTER record (key finding).** Air Import showed the flight but Export often went blank. Root cause: for a **consolidated** export the house (`awb_type H/S`) has an empty `flight1` — the flight lives on the **master** (`awb_type M/B`) row that owns the MAWB (verified: house `DT-35005` blank → master `235-63057046` = `TK071`). And `carr` is **always empty** on this ERP (airline is in `rout_by_1`). Since the worklist already groups Air by MAWB, the conveyance is now **house `flight1` → master `flight1` (looked up by MAWB) → blank** — the real flight number the operator needs, never the bare airline code ("CX" can't say which of many daily CX flights). `$assigned` (space-confirmed) is now flight-based, matching milestone A2. `seed-alerts.ps1` (added a chunked `masterFltByMawb` precompute mirroring the `veslmstr` seek). Existing `erpops_net` data recomputed in place: Air **0** airline-code-only rows; Export 199/299 + Import 150/154 now carry a real flight no (remaining blanks have no flight on house **or** master yet).
- Files: `serve-ops.ps1` `seed-alerts.ps1` `index.html` `ops.js` `styles.css`.

**Previous session (2026-06-14b — Edit-ERP-data UX rename + pen shortcut + contact fields; Air IATA flight legs + corrected cargo cols; Sea blitem/blcont field map; VPN connect-timeout fix. Committed `4b43832`).**
Operator-feedback round on the ERP data editor, every mapping reconciled against live `fm3khkg` SQL + the Swivel `3rd-erpapi.json`.
- **Rename + UX.** "Correct ERP data" -> **"Edit ERP data"** everywhere ("correct" read as negative); dropped the description blurb;
  added a **pen (edit) shortcut** at the end of the drawer's first row (ETD/ETA/ATD | auto/manual) that opens the editor; the
  editor header now shows the **service in bold** (e.g. "Sea Import") instead of the static title. Removed the container
  booking-stage note.
- **Party contacts.** Added editable **Contact name + Contact email** for shipper & consignee
  (`shipper/consigneePartyContactName/Email`), under phone/tax.
- **Air (verified live on HAWB `HKGAE6060004` / job `HKG-A-R62885`).** Carrier from **`rout_by_1`** (`carr` is empty). New
  compact **"Flights / IATA legs"** block tucked under **Job No.** (small font): `flight1/flight2/flight3` with discharges
  `to1`(display-only, =pod)/`deli`/`to3` - legs 2-3 push via **`flexData`** (`2nd/3rdLegFlightNumber` +
  `2nd/3rdLegPortOfDischargeCode`, verified in the spec); leg 1 = `voyageFlightNumber`. **Chargeable** weight
  (`ttl_cwt` -> `chargeableWeight`) **replaces Wt unit**; **qty=`t_rece_qty`, gross=`ttl_gwt`, cbm=`t_rece_cbm`**; marks/desc
  seeded from **`awbdetl.mark2`/`desc2`** (header `crmarking`/`wdesc` are empty). Standard **4-chip routing row restored**
  (Place of Receipt | Port of Loading | Port of Discharge | Final Destination) - the simple route view most shipments use.
- **Sea (verified live on sono `HK012606010` / ref 24625).** Carrier from **`iliner`**; **liner agent from `blcont.lagent`**
  (party code on the container line) **resolved to a company name via `custsub`** (e.g. A0002 -> APL CO PTE LTD); Final
  Destination **`dest` -> `deli` (Place of Delivery) fallback** when blank; **commodity=`blitem.commodity`** (no commodity
  column in `blhead`), **container counts 20'/40'/HQ/Other = `blitem.c20`/`c40`/`cq`/`c45`**, marks=`blitem.mark2`(+`mark3`),
  desc=`blitem.good_desc1` else `desc2`(+`desc3`); **Wt unit defaults to KGS** when blank. All line-level fields seeded
  server-side from `blitem`/`blcont` (blh=ref, first line), mirroring the Air `awbdetl` pattern.
- **Plumbing.** `Build-ErpPatchPayload` gains **`flexData` nesting** (writeKey `flexData.<sub>`); `Handle-ErpEditSeed` gains
  the Air `awbdetl` + Sea `blitem`/`blcont` detail-line seeding. **VPN fix:** bumped the four source-ERP connections'
  **`Connect Timeout` 5 -> 15s** - the VPN's SSL pre-login handshake runs ~4s and was intermittently timing out the
  erp-edit seed / master-search / detail / doc-seed (`serve-ops.ps1`).
- Files: `erp-edit-fields.json` `erp-edit.html` `erp-edit.js` `ops.js` `serve-ops.ps1` `erp-doc-api.ps1`. **Committed `4b43832`.**

**Previous session (2026-06-14 — staff-internal ERP data-correction editor: fix bad source data, push only changed fields to `/booking/update`).**
The app *read* ERP data and trusted it; operators routinely spot bad source data they cannot fix from the ERP UI
(most importantly **`DUMMY` party codes** and **`ZZZ`/`ZZZZZ` incoterm/port codes** that silently corrupt reports,
but also wrong addresses, dates, carrier, container counts). New **"Correct ERP data"** pop-out, opened from the
worklist drawer (`erpEditPanel` → `erp-edit.html?job=<job_no>`). It seeds each field's current ERP value, lets the
operator fix it (master lookup or free type), and pushes **only the changed fields** to Swivel `/booking/update`,
with a full audit row in the new **`erp_edit_log`** table. New files: `erp-edit.html` / `erp-edit.js` /
`erp-edit-fields.json` (field dictionary). Reuses the draft-HBL ERP machinery (mock mode, read-merge-write existence
guard, best-effort/strict). Staff-internal — **no customer-approval loop** (unlike the draft-HBL agree flow).
- **Laid out like the bill (Sea HBL / Air AWB), verified by headless-Edge screenshots both modes.** Two-column
  upper region: parties stack on the **left** (shipper / consignee / notify / delivery agent, each a combined box —
  **line 1 = name, the rest = address**); the **right** holds References + Stakeholders, the **SERVICE DETAIL**
  4-column grid, and an **Internal Remark** box. Below: a routing row (Place of Receipt | Port of Loading | Port of
  Discharge | Final Destination), a one-line **Cargo Information** row, **Marks | Description** side by side, and the
  container table. Each master code is a chip **in the caption** — `SHIPPER ( DUMMY )` — click **`...`** to search the
  master or type it; resolved name shows as **`NAME (CODE) - city, country`** (custsub `city`/`country`).
- **Field map verified on live `fm3khkg`; ALL write keys verified against the Swivel OpenAPI spec**
  (`3rd-erpapi.json`, fetched as raw JSON, parsed with node — PS `ConvertFrom-Json` chokes on its dup case-only keys).
  Editable & pushable: the 6 party codes + name/address/phone/tax (`bookingParty.*`), `incoTermsCode`, `serviceCode`,
  `placeOfReceiptCode`/`portOfLoadingCode`/`portOfDischargeCode`/`finalDestinationCode`, `carrierCode`/`carrierName`,
  PO (→ `bookingReference[]` `{refName:'PO'}`), **ETD/ETA + flight time folded into one `departureDateEstimated`
  datetime** (`<date>T<hh:mm>` — the API has no separate time field), `cargoReady/ReceiptDateEstimated`,
  `telexRelease`/`isDirect`/`dangerousGood` (real JSON booleans), `divisionCode`/`team`/`picId`/`picEmail`,
  `commodity` + `quantity`/`quantityUnit`/`grossWeight`/`weightUnit`/`cbm` (real numbers), `shipMarks`/
  `goodsDescription`, `remark`, `bookingContainers[]` (a **type+qty row is valid with no container number** — for
  booking-stage counts), and the four sea aggregates `container20`/`container40`/`containerHQ`/`containerOthers`.
- **Read columns derived bound-aware** where the ERP splits by leg: ETD/ETA = `departure2/arrival2` (Export) /
  `departure1/arrival1` (Import), Air ETD = `f_date1`; vessel/voyage = `vessel_2/voyage_2` (Export) /
  `vessel_1/voyage_1` (Import) with the code resolved to a name via `veslmstr.short_name`. Numbers strip trailing
  zeros, bits → `true`/`false`, datetimes → ISO.
- **Hard API limits (surfaced, not faked):** **trucker / customs broker / warehouse have NO field in
  `/booking/update`** (only 8 party types exist) → dropped from the UI; **No. of originals** and **PIC name** have no
  write key → removed (PIC corrected via `picId`/`picEmail`). **Carrier + the estimated dates push best-effort** (the
  carrier master rejects raw ERP codes; demoerp still rejects date-touching updates — open Swivel ticket) and any
  rejection is captured verbatim in `erp_edit_log`.
- Server: `Handle-ErpEditSeed` / `Handle-ErpMasterSearch` (live `TOP 20` LIKE over custsub/portmstr/servmstr/
  linermstr + fixed Incoterms-2020 list) / `Save-ErpEdit` (re-reads the live ERP for the authoritative *before*,
  diffs via `Doc-Changed`, blocks read-only edits) + routes `/api-ops/erp-edit`, `/api-ops/erp-master`,
  `/api-ops/erp-edit-save` (`serve-ops.ps1`). `Build-ErpPatchPayload` + `Invoke-ErpEditPush` (`erp-doc-api.ps1`).
  `erp_edit_log` table added idempotently to `setup-ops.ps1`. Verified end-to-end: seed SELECT validity (Sea+Air,
  no invalid columns), payload shape (party nesting, bool/number/date/bookingReference/container array, ETD+time
  fold), and the two-mode screenshots.
- Committed: `f2a1bf2`/`74e3e17`/`9aadbe1` (the first three editor rounds); the HBL-grid 2-column redesign, the
  routing/cargo/marks/container-count/vessel/flight rounds, and the trucker-removal / picEmail / note cleanup round
  were committed in **`4b43832`** (alongside the 2026-06-14b work above).

**Previous session (2026-06-13 — booking-stage identity fix + UI declutter/theme/mobile + draft speed/UX + ERP-files browse & download).**
- **Early-booking identity fix (the `job_no` collapse).** The listener keyed `shipment_alerts` on the raw ERP
  `jobn`, which is blank at booking stage AND **non-unique once issued** (one job number can cover many house
  bills — `SEHKG220800007` = **200** HBLs), so distinct shipments collapsed onto one card (HKG Sea stored only
  ~30 of 120). Fixed by keying identity on the **immutable ERP `ref`**: `job_no` = synthetic `<STN>-<S|A>-R<ref>`;
  added column **`erp_job_no`** (raw human jobn, for display/search). Card headline now leads with the
  per-shipment id (house bill → booking → job no), never the synthetic key; a same-`ref` cleanup DELETE absorbs
  the booking→job transition; unbooked-export bucket relabelled "Awaiting booking / space". **Full reseed of all
  12 stations → 1200 rows, 1200 distinct, 0 collapse, 344 booking-stage shipments now visible.** Retrieval
  (`/api-ops/erp-detail`, draft seed) and the future delta listener already key on `erp_ref`, so this is the
  correct production foundation. **Existing notes keyed by the old jobn-style keys detach** (user chose to
  re-make rather than migrate). `seed-alerts.ps1`/`setup-ops.ps1`/`serve-ops.ps1`/`ops.js`.
- **UI declutter + light/dark + mobile.** Stripped decorative emoji (kept the Sea/Air toggle, R/A/G colour, and
  control glyphs ✕ ✓ ↻ ▾); **light is now the default palette with dark via `prefers-color-scheme` + an
  Auto/Light/Dark header toggle** (remembered, flash-free boot script); responsive `@media` (≤860/≤560: side
  panel stacks, filters go fluid, drawer full-screen, header subtitle hidden). `styles.css`/`index.html`/`login.html`/`admin-ops.html`/`ops.js`.
- **Unified search + quick filters.** The filter box gained a **field selector** (Company type-ahead | Job No |
  Booking/SO | PO | House B/L | Master B/L). Identifier search hits the server (`ref`/`refField`) and **ignores
  the date window AND the ownership lens** (still station/mode-scoped) so any file is findable by its number —
  "Job No" matches both the synthetic key and `erp_job_no`. Added **"My notes"** (shipments with an OPEN note of
  mine, any date — clears when the note is marked done) and **"Alerts"** (R/A only) toggles; removed the
  redundant "All dates" button; added a **"Hide filters"** toggle that collapses the whole view-control row
  (saves mobile space). Restored the My-Tasks card icons; the red `R` severity badge is bolder.
- **Draft create — speed + UX.** Cached the own-office "issuing/forwarding agent" per station
  (`Get-OwnOfficeAgent`, `$script:OwnAgentByDb`): it was 1–3 ERP round-trips recomputed on **every** draft
  (incl. a `blhead … ORDER BY ref DESC` scan, since the `S0001` own-code isn't in `custsub`) — now resolved once
  per station/run. The **+ Create draft** button now opens the editor tab **immediately** on click (user
  gesture, so the browser doesn't block it) showing a "preparing…" placeholder, then navigates it to the editor
  when ready, with honest "Creating… / Draft ready" button feedback (the old code called `window.open` *after*
  the await → silently popup-blocked → the operator saw a spinner forever). `serve-ops.ps1`/`ops.js`.
- **ERP files browse panel (new).** A drawer panel lists the files the ERP already holds for a shipment
  (document type · file name · remark), via new `Invoke-ErpFileEnquiry` (`erp-doc-api.ps1`) + session-gated
  `/api-ops/erp-files` (`Handle-ErpFiles`, Test-JobScope) + `erpFilesPanel` (`ops.js`). **KEY FINDING (resolves
  open item c):** `/file/enquiry` matches on **`3rdBookingID` = our booking number (`sono`)** — `bookingNo`/`houseNo`
  return "No corresponding data". It tries `3rdBookingID` first, then `bookingNo`, across the identifier
  candidates in priority order (Sea: `sono`→HBL ; Air: HAWB→booking→MAWB) and returns the first hit. Works the
  **same for Air** (`moduleTypeCode=AIR`, HAWB→booking→MAWB) as Sea. **Live-verified** on demoerp (2 files for
  booking `HK012606010`). The internal `3rdBookingID` detail is **no longer shown** in the panel heading (now
  just `ERP files - <kind> <id>`), and the ERP's `(422) No corresponding data` reply is treated as the empty
  state ("No files in the ERP for this booking") rather than surfaced as an error.
- **ERP file download (new).** Each listed file now has a **Download** button. `Invoke-ErpFileDownload`
  (`erp-doc-api.ps1`) POSTs `/file/download` (same candidate/field order + optional `fileName`), decodes the
  returned `base64`; session-gated `/api-ops/erp-file-download` (`Handle-ErpFileDownload`, Test-JobScope) infers
  the Content-Type from the extension and `Send-Blob`s the bytes; `downloadErpFile` (`ops.js`) fetches it through
  the authed `fetch` (carries cookie/`X-Ops-User` in either auth mode) and triggers a browser download with the
  real filename. Upload/delete still deferred.

**Previous session (2026-06-12d — Neutral Air Waybill + verified Air field map + LIVE ERP issue + auto-PDF + docs).**
Driven by the user's head-to-toe test of the **Draft HAWB** review on demoerp booking `HKGAE6060004`
(job `AEHKG260600006`, ref 62885, HKG->SEL->CHI->LAX). All Air mappings reconciled against live `fm3khkg`
`awbhead`/`awbdetl`.
- **HAWB renders as the IATA Neutral Air Waybill** (dedicated layout in `bl-form.js`; the ocean HBL keeps the
  generic grid). Dynamic **Marks <-> Nature divider** (`goods_split`, draggable, persisted + printed),
  prepaid/collect **charges summary**, the routing strip, and a **Dimensions** box. Rate line single.
- **Verified Air field map** (see [docs/SQL-README.md](docs/SQL-README.md) §4): Airport of Destination =
  `dest_name` (final, not `pod_name`); routing legs **`to1` / `deli` / `to3`** (`deli` = the MIDDLE leg, e.g.
  CHI); carriers from `carr`|flight-prefix; pieces `t_book_qty`->`t_rece_qty`; kg/lb from `wgt_unit`; Marks =
  `awbdetl.mark2`; goods = `awbdetl.desc2` (full text, NOT `good_desc2`/`commodity`); Dimensions =
  `awbdetl.dimension` (gated by `not_show_dim`); Handling = `awbhead.handling`; Accounting = freight term +
  Destination Agent (`agnt_*`); Notify own box; Issuing Carrier's Agent = own office; WT/VAL & Other PPD/COLL
  `X` from `frt_terms`/`oth_terms`; declared values + insurance.
- **Detail-drawer route leg order fixed** (`Get-AirRoutePoints` in `ops-eval.ps1`): pol -> to1 -> **deli** ->
  to3/dest, so the middle leg (CHI) shows in sequence.
- **Performance fix** (`Get-ErpCols`): dropped the column-metadata probe. `INFORMATION_SCHEMA`/`sys.columns`
  for the read-only login on the 465-col `awbhead` runs 40-70s and drops the connection, which aborted the
  whole ERP seed (drafts came back snapshot-only AND slow). Now trusts the curated want-list. Draft seed
  ~11-14s+fail -> **~4s**.
- **LIVE ERP issue proven.** `documentTypeCode` -> **`BL_REVIEW`** (HBL+HAWB) in `erp-api-map.json`; event
  already `transportBill`/"Transport Bill Confirm". The agreed PDF is now **auto-generated** on Issue
  (`Doc-RenderPdf`/`Resolve-PdfEngine` -> headless Edge/Chrome print-to-PDF of the offline bill via
  `BLForm.setDict`; verified 73 KB valid PDF in ~3s). Root cause of "nothing in ERP": **mock mode** - the
  demoerp config had no `erpApi` block. Added `erpApi` (baseUrl + bearer token) to `ops.config.demoerp.json`;
  token **verified live** via read-only `/booking/get` (booking HKG2606004 found). **The two buttons:**
  *Agree - save data to ERP* = `/booking/update` (data); *Issue official document* = `/file/upload`
  (BL_REVIEW PDF) + `/event/update` (Transport Bill Confirm). To re-issue the mock-issued `AEHKG260600006`,
  Amend it first.
- **My-Tasks draft-review alerts** (`Get-DraftAlerts`): drafts in `CUSTOMER_SUBMITTED`/`CUSTOMER_APPROVED`
  surface in the inbox (with the customer's message), count toward the badge, self-clearing, scoped.
- **Docs** created under `docs/` (BUSINESS/TECHNICAL/DEVELOPER/SQL-README), mirroring erp-dashboard's structure.
- Committed: `7c86958` (HAWB layout + field map + perf + alerts). Uncommitted: the deli/desc2/handling
  follow-ups, auto-PDF, `BL_REVIEW`, docs, and the gitignored `ops.config.demoerp.json erpApi` token.

**Previous session (2026-06-12c — worklist "this week's work" window + HBL seed completion + Qty column).**
Driven by the user's first head-to-toe run on a fresh demoerp booking (12073 -> job `SEHKG260600006`).
(1) **Worklist date window redefined**: a row now matches when ANY of `sort_key` (moving), `next_due`
(work due in the window), or `anchor_date` (created in the window) hits it, plus work **overdue up to 30
days** always shows. The 30-day bound matters: the live DB held 418/622 active rows with overdue
`next_due` (zombie jobs never closed in the ERP, some since 2018) that would have drowned the week view -
older overdue appears only under "All dates". New **🆕 NEW chip** on rows created in the last 7 days;
date-box/This-week tooltips + empty-state text explain the semantics. (2) **Two real bugs**:
`seed-alerts.ps1` compared `crtdate<=@a` against a midnight date string, so bookings created TODAY never
seeded (now `crtdate<DATEADD(day,1,@a)`); `ops-eval.ps1` derived milestone dues from the ERP's 1900-01-01
"empty date" producing permanently-overdue junk (dates <1990 now treated as no-date; stored junk cleared).
(3) **HBL seed completion** (every box reconciled against `fm3khkg` SQL on job `SEHKG260600006`): party
boxes now carry name + FULL address blocks (`shpr_/cgne_/not1_` name+add1..5); **delivery agent** from the
`agnt_*` block with `custsub` lookup by `agn2_code` as fallback; **forwarding agent = own office** via
`fm3kco.site` dbname->owncode (HK01 -> fm3khkg -> S0001) then custsub, falling back to the latest blhead
whose agn2 IS the own office (the S-codes have no reachable custsub master); plus `carr_name`
(pre-carriage), `rece_name`, `issu_at`, `payable_at`; **marks finally seed** from `blitem.mark2(+mark3)`
ntext and description falls back `good_desc1 -> desc2(+desc3)` (good_desc1 is often blank). HAWB gets the
same party/address + `issu_at` treatment. Bug fixed en route: `Doc-FieldDefs` called without its type arg
nulled the whole enrichment. (4) **Marks overflow / move-to-attachment**: when the ERP text overflows its
box, marks+description move TOGETHER to rider page 1 with the FULL text - the Description box prints
`AS PER ATTACHED SHEET`, the Marks box goes BLANK (pointer must not print twice). The editor's "+ Add
attachment / rider page" button MOVES the current box text onto page 1 the same way (dictionary `moveFrom`
map), and **removing that page restores the text** into still-blank/pointer boxes. (5) **Qty column
(packing-list style)**: new `qty_detail` box between Marks and Description on the bill and a matching
`qty` column on every rider page; all three columns render in the same monospace font/line-height so line
N aligns on screen and print. The ERP push (`Build-MarksGoods` + `Merge-QtyDesc` in erp-doc-api.ps1)
assembles `shipMarks`/`goodsDescription` from the real boxes (pointer text skipped) + all rider pages,
folding the qty column into each description line with padded alignment
("12 ROLLS KNITTED MATERIAL" / "         100% COTTON").

**Previous session (2026-06-12b — HBL refinements: containers table, rider pages, file attachments, save-on-Agree).**
Operator-feedback round on the doc-review feature, all mock-verified on fibsbkk (live demoerp retest pending
the Swivel /booking/update fix). (1) **Seeding**: `num_originals` from `blhead.no_orig` with the **telex
guardrail** (telex_rel set -> '0'); `freight_terms` box renders `blhead.frt_terms` as "FREIGHT PREPAID" /
"FREIGHT COLLECT (FOB)" and is **presentation-only** - `incoTermsCode`/`freightTermsCode` are never derived
from it, only echoed from the live booking at push time (erasing the incoterm on the printout cannot touch
the ERP). (2) **Structured fields** in `doc_version.fields`: dictionary kinds `table` (HBL `containers`:
container/seal/type/qty/unit/kgs/cbm, <=50 rows, seeded from `blcont`, replaces the old `container_info`
text box) and `riders` (`rider_pages`: marks|description attachment pages, printed page-per-page, A4/F4
toggle via `BLForm.setPrintSize`). Both editable by staff AND customer, cell-level diff highlights,
canonical serialization keeps "no changes to save" exact. Pushed as API `bookingContainers`
(containerNo/sealNo/containerTypeCode/quantity - the API item has NO weight/cbm). (3) **Attachment files**
(`doc_attachment` table, varbinary): staff + customer upload (customer only while SENT, max 5MB,
pdf/png/jpeg with magic-byte check, 7MB body cap, customer can delete only own files), served via
`Send-Blob`; ALL live files go to ERP `/file/upload` at issue. (4) **ERP call split**: staff **Agree** now
runs `/booking/get` read-merge + `/booking/update` (never blocks the agree; result logged as
`erp_booking_saved`/`erp_error`); **Issue** = per-file `/file/upload` + `/event/update` transportBill
(+ optional generate). `commodity` truncated to **21** (spec maxLength). Two PS 5.1 traps fixed:
`RunQ` param binding used a `$(if...)` subexpression that ENUMERATED `byte[]` into Object[] ("No mapping
exists..."); `Get-ErpCols` cache key now includes the want-list (erp-detail vs doc-seed asked different
columns of the same table and poisoned each other's cache).

**Previous session (2026-06-12 — draft HBL/HAWB customer review loop).** Built the full
draft-document agreement workflow (plan: `.claude/plans/` "draft HBL/HAWB customer review"): staff create a
draft House BL / HAWB seeded from the shipment snapshot + a bounded ERP read (`Doc-ErpSeed`, same pattern as
erp-detail), send the customer a **tokenized link** (`/bl-review/<token>`, no login, SHA-256 at rest, 14d
expiry, revoke-on-resend/issue), the customer **edits the bill on screen** (`bl-review.html` + shared
`bl-form.js` renderer, layout from `doc-fields.json`), staff review a **field-by-field diff**
(`doc-editor.html`), iterate versions until **approve → agree → issue** via `erp-doc-api.ps1`
(mapped to the **Swivel 3rd-party ERP API**, see below; mock mode writes `erp-mock/issue-<id>.json`); after issue,
edits require an **amendment** (`amend_count`, fee flagged). 4 new erpops tables (`doc_draft`, `doc_version`,
`doc_review_token`, `doc_event_log` — append-only audit with IP), staff endpoints `/api-ops/doc*`, public
endpoints `/api-doc/*` (token-shape regex before any SQL, 256KB body cap, single generic failure message),
drawer **📄 Draft review** panel in ops.js. **Proven end-to-end** on local fibsbkk data: Sea
`SIBKK211000012` (full lifecycle incl. the MADE IN TAIWAN → "MADE IN TAIWAN, CHINA" correction cycle, mock
issue, amendment; event log + demo doc left in local erpops) and Air `AIBKK210200001`; every seeded field
reconciled against direct `blhead`/`blcont`/`blitem` / `awbhead`/`awbdetl` SQL.

**ERP integration = the Swivel 3rd-party ERP API** (docs: documents.swivelsoftware.com/3rd-erpapi.html, spec
`3rd-erpapi.json`, base `https://demoerp-api.swivelsoftware.com`, **bearer token** from Swivel). Issue runs
4 calls in `erp-doc-api.ps1`: **`/booking/update`** (agreed data: `bookingParty` flat keys
`shipperPartyName/Address`, `consigneePartyName/Address`, `notifyPartyParty*` = the address blocks;
`shipMarks`, `goodsDescription`, vessel/voyage, `incoTermsCode`, POL/POD code+name - both REQUIRED, plus
`partyGroupCode`/`serviceCode`/`commodity`), optional **`/file/upload`** (operator-attached agreed PDF,
base64, `documentTypeCode`), **`/event/update`** (`status: transportBill` = "Transport Bill Confirm",
`3rdBookingID`=doc guid), optional **`/document/generate`**. Required fields are validated before any real
call; party boxes split first-line=name / rest=address; official `erp_doc_no` = the agreed house number.
Deployment codes live in **`erp-api-map.json`** (tracked: `partyGroupCode`, `forwarderCode`,
`serviceCodeDefault`, event + document type codes, `bookingOverrides` field:/sa:/const: syntax); the secret
token in `ops.config.json erpApi.token` (gitignored). Mock payloads verified shape-exact against the spec.

**LIVE full round PROVEN on demoerp (2026-06-12).** Token in `ops.config.network.json` (works; code strips a
pasted `Bearer ` prefix). Test booking **HK012606010** (job `SEHKG260600005`, HBL `HKGSE6060001`,
SEMARANG->TACOMA): draft seeded live from `fm3khkg`, full customer round (incl. the MADE IN TAIWAN ->
"MADE IN TAIWAN, CHINA" correction), **ISSUED for real**: `/file/upload` ok (agreed PDF in ERP files),
`/event/update` ok (`transportBill` stamped). Live-call findings baked into `erp-doc-api.ps1`:
(1) `Invoke-RestMethod` returns a JSON array as ONE object - assign-then-`@()` (same family as the
ConvertFrom-Json trap); (2) do NOT send `carrierCode`/`vesselName` on update (carrier master rejects raw
codes; vessel triggers schedule rebuild); (3) **`3rdBookingID` is a LOOKUP key** (Shipment Reference ID) -
sending our doc guid made upload/event 422 ("No corresponding data"-style), key by `houseNo`+`bookingNo`
instead; (4) `ErpErr` rewinds the consumed response stream so the ERP's real validation text reaches the
event log; (5) read-merge-write: `/booking/get` (POST works) before update - abort if booking absent (update
would CREATE one), reuse live `serviceCode`.
**Raise with Swivel:** (a) `/booking/update` on demoerp rejects EVERY payload with
"Departure date not active yet, Invalid carrier code" - payload-invariant (fails even with required-only
fields, master-listed carrier APLU, future ETD+ETA) -> `bookingUpdateMode: best-effort` in
`erp-api-map.json` logs the rejection and continues with upload+event; flip to `strict` once fixed.
(b) `/event/get` returns a server SQL error ("Ambiguous column name 'seq'"). (c) **RESOLVED 2026-06-13:**
`/file/enquiry` (and `/file/download`) key on **`3rdBookingID`** (= our booking number / `sono`), NOT
`bookingNo`/`houseNo` (those return "No corresponding data"); used by the new ERP-files browse panel.

**Open items:** Swivel answers above, public exposure (reverse proxy for `/bl-review/*` + `/api-doc/*` only)
+ `publicBaseUrl` (configurable, never hard-coded), optional SMTP (today: copy link / mailto prefill).

**Previous session (2026-06-11b — demoerp connected + Sea worklist fixed).** Brought up the **demoerp**
environment end-to-end and fixed the all-Red Sea worklist. Commits on `main`: **`90bc63b`** (Sea fix) + **`734b7f1`**
(gitignore `.claude/`).

- **demoerp connected (two-server).** Auto-discovered `192.168.5.2`: the SQL login **`dashboard`** can read **only the
  fm3k group** (15 DBs); every `pgs*` DB is **denied**. So **demoerp = the fm3k group** (12 stations + `fm3kco` master)
  — the same group as the old "Network" env. The login **can't `CREATE DATABASE`** there → **two-server mode**: read
  fm3k* remotely, write the ops DB **`demoerp`** locally on **`localhost\SQLEXPRESS`** (SQL Server 2025). Rewrote the
  gitignored **`ops.config.demoerp.json`** with the real DBs (station codes/names taken from `fm3kco.site`), ran
  `setup-ops.ps1`, seeded milestone config + all 12 stations (Sea+Air). Login as `mandy` (admin), worklist serves on **:8079**.
- **VPN route fix (Surfshark coexistence).** The Swivel tunnel now pushes `192.168.0.0/21`, but Surfshark plants a
  competing `/21` (metric 1) that black-holes `192.168.5.2`. Fix **without** disconnecting Surfshark: add a
  more-specific route — `New-NetRoute -DestinationPrefix '192.168.5.0/24' -InterfaceIndex 5 -NextHop 10.8.1.13 -RouteMetric 1`
  (elevated; longest-prefix-match wins). Captured as a **local skill** `.claude/skills/swivel-vpn/` (gitignored; a
  `-Check`/`-Fix` helper). The Swivel client is **OpenVPN Connect**; use the `VPNConfig_2026_splittunnel.ovpn` profile.
- **Sea worklist all-Red -> realistic (committed `90bc63b`).** SQL reconciliation found two causes: (1) **bound-mapping
  bug** — Export milestones keyed off the dead `_1` leg; `onboard1` is 0% populated while `onboard2` is 95%; and (2)
  **sparse operational fields** (`ts_blno`/`edidate`/`atd_date` ~0%) left pre-departure milestones perpetually overdue.
  Fix in `ops-eval.ps1` (+ `seed-milestone-config.ps1`, `seed-alerts.ps1`): a bound-aware **`onboard`** field
  (Export->`onboard2`, Import->`onboard1`) **plus a departed/arrived supersede** — pending booking/etd milestones close
  once the leg has sailed, eta milestones once arrived; `atd`/`delivery` stay open (the cash-leak items the tool exists
  to surface), marked `done_by='superseded'`. Plus an **ETA date-sanity guard** (null any arrival <= departure). Result:
  Sea **366R/0G -> 344G/22R**, **0** impossible ETD>=ETA rows; pilot `SEHKG260600003` reconciled (M1b via `data:onboard`,
  M6/M7/M9 superseded). The 22 reds are legitimate overdue invoice/delivery on old shipments.

**Open items for next chat:** (a) **`job_no` collapse** — the seed *processes* 120 shipments/station but stores ~30
distinct rows: many raw `blhead` rows have a **blank `jobn`** so they upsert onto the same key. Investigate the job_no
derivation so all ~120 surface as distinct cards. (b) `eval-shipment.ps1` (standalone diagnostic) still duplicates the
old `onboard1` logic — optional consistency follow-up. (c) demoerp ops DB lives on **this PC's** `localhost\SQLEXPRESS`;
for office use, point `opsServer` at an office-reachable instance and re-run `setup-ops.ps1` + seeders there.

**Prior session (2026-06-11a, pgs env).** Worked against the **pgs** ERP group, not the fibsbkk/fm3k envs in
the table below — the working-tree `ops.config.json` points at **`18.136.126.101,1438`** (SQL login `swivel`), opsDb
**`erpops`**, 23 `pgs*` stations. Data is a **frozen snapshot**: `shipment_alerts.sort_key` spans **2020-11-18 →
2023-05-12**, all 2,181 rows **Sea** (1,752 Export / 429 Import); **zero Air rows** (Air ingest still broken —
`awbhead` missing `comp_date`). Done this session:

- **Auth bootstrapped.** Created gitignored `users.json` with the first admin **`mandy`** (password stored only in the gitignored `users.json`; role admin,
  `admin:true`, empty stations/access = unrestricted). App is now in **real-auth mode** (login page on, sessions).
  Passwords are `SHA256("salt:password")`; new users get hashed automatically via `admin-ops.html`.
- **Fixed worklist 500 (schema drift).** The pulled `serve-ops.ps1` worklist SELECT referenced 6 columns missing from
  the live `erpops.shipment_alerts` (`commodity, sono, route_summary, available_date, eta_delivery, goods_delivery`).
  Fix: re-ran idempotent **`setup-ops.ps1`** to ALTER-add them. ⚠ These 6 (+`route_json, detail_json, erp_ref`) are
  **NULL on the existing 2,181 rows** — re-run `seed-alerts.ps1 -Mode Sea` to populate route/commodity detail on cards.
- **Admin no longer gated by erpUser** (`serve-ops.ps1` `Handle-Worklist`): an **admin** role sees every shipment on the
  `mine` lens without owning the ERP `pic_user` — condition is `lens='all' OR (lens!='user' AND Cur-Tier='admin')`.
  The teammate (`user`) lens still narrows to the chosen person; operators unchanged.
- **As-of testing clock** (config-driven, live-safe). New `ops.config.json` key **`asOfDate`** (yyyy-mm-dd). When set,
  the app treats it as "today" for **all operational date logic** (worklist date window, inbound recency, task overdue);
  empty/absent = real today (program logic identical). Server: `$AsOfDate` + `Today-Str`/`Today-Date`, used at the tasks
  `today`, inbound recency, and exposed as `today` in `/api-ops/me`. Client: `currentWeek()` uses `ME.today` instead of
  the browser clock. **Set to `2023-04-15`** so the 2023 snapshot behaves like a live day. *(Verified: `/me today`=2023-04-15;
  worklist `mine`==`all`==2181; default week 04-10..04-16 → 342 Sea rows; a 2026 window → 0.)* Files syntax-clean
  (`PSParser` + `node --check`); server running on **8078**.
- **demoerp env scaffolded but NOT usable yet.** New gitignored **`ops.config.demoerp.json`** (server `192.168.5.2`,
  SQL login `dashboard` / `SwivelDash-8704`, port **8079**) + **`restart-ops-demoerp.bat`**. Blocked: `192.168.5.2` is
  **unreachable** from this PC (different subnet, not via the Swivel split-tunnel — needs LAN/VPN to `192.168.5.x`). Its
  `opsDb`/`masterDb`/`stations[]` are **placeholders copied from pgs** — auto-discover the real DB list once reachable,
  then run `setup-ops.ps1` against it.
- **VPN/network gotchas (cost real time — record for next time).** The SQL host is reached only over the **Swivel
  OpenVPN** split-tunnel (routes just `18.136.126.101/32`). **Surfshark conflicts two ways:** (1) its running OpenVPN
  tunnel makes OpenVPN Connect throw the *phantom* `PRE_CONNECT_CHECK_FAILURE: VPN Connection is being utilised by
  another Windows user` (only one Windows user is actually logged in) — fix: **disconnect Surfshark in its app** (killing
  the service just auto-respawns); (2) Surfshark plants a Wi-Fi `/32` route to the SQL host (metric 55) that **beats** the
  tunnel route (257) and black-holes traffic — fix: `Remove-NetRoute -DestinationPrefix '18.136.126.101/32' -InterfaceIndex 8`.

**Open items for the new chat:** (a) re-seed Sea to fill the 6 NULL columns; (b) Air ingest still produces 0 rows;
(c) demoerp needs network access + DB-layout discovery; (d) temp VPN-fix scripts/logs left in `C:\Users\mandy\`
(`vpn-*.ps1`/`.log`) — deletable. Nothing committed this session (changes in tracked `serve-ops.ps1`, `ops.js`;
`ops.config.json`/`users.json`/`ops.config.demoerp.json` gitignored).

**Prior (admin page):** **admin page now manages milestones, not just users.** `admin-ops.html` is split into
two tabs — **Users** (with a live search box over login/name/email/station/team/ERP-name, for ~500-user scale) and
**Milestones & alerts** (CRUD over `milestone_def`: name, mode/bound/seq/phase, active, and the **alert timing** —
`baseline` / `fixed` offset / `none` — that drives every operator's Green/Amber/Red). Backed by admin-gated
`/api-ops/admin/milestones` (GET/POST) + `/admin/milestone-delete`; edits apply at a shipment's **next evaluation
run**, not retroactively. Header **Admin** link (admins only). Two **restart bats** (`restart-ops-network.bat` 8079 /
`restart-ops-local.bat` 8078) stop-then-start the web service, port-scoped, excluding `$PID`. **Encoding fix:** all
config/JSON reads use `[IO.File]::ReadAllText` (PS 5.1's `Get-Content -Raw` decodes BOM-less UTF-8 as ANSI →
mojibake in the subtitle); `.ps1` kept ASCII-only. Last commit on `main`: `bade065`.

**Prior milestone (12-station seed + Air UX):** all **12 fm3k stations** seeded into `erpops_net`; station picker +
filter bar (week-default date window, company-name search, POL/POD); **schema-drift resilient** seeding (`Filter-Cols`).

**This session's work (cross-station inbound feed made real + Air-freight UX):**
- **Convention join RESOLVED** — the feed routes a booking to its destination station via `fm3kco.site.owncode`→`location`
  (each office's system customer code, e.g. `S0001`=HK, carried on `agn2_code`/`roagent`/`rcustomer`). Replaced the old
  `asw_station_list.FM3000_CODE` guess (wrong code space). Feed is keyed on **`sono`/`booking`** (the SO number, stable
  from booking stage when `blno`/`mawb` are still empty). `bill_type='B'` publisher filter removed.
- **Inbound panel is consignee-facing** — new feed columns (consignee, cargo_type FCL/LCL, service, container_no, po_no,
  spot_id, booking_qty/wgt, house_bill); card led by `cgne:`, prominent cargo-ready/ETD dates, ref line; **grouped by
  stage** (🆕 new booking vs 🚢 scheduled) for sea, **by flight no** for air; **recency filter** (ETD today+ OR booked
  ≤90d) with a **show-all** toggle; **dedup vs Arrivals** (suppress a feed row whose origin HBL already exists as a local
  import job — needs live EDI-linked data to fire).
- **Field-mapping fixes (also fix the worklist):** Sea ETD = `blhead.departure2` (mandatory; `departure1` is dead);
  Air Incoterm = `awbhead.routing` (EXW/CIF…, not `frt_terms` PP/CC); Air cargo falls back to actual `t_rece_qty`/`ttl_cwt`
  when `t_book_*` are empty.
- **Worklist UX:** milestone update-marker (🔄) shows the milestone **name** not the code; **Air groups by MAWB** (flights
  repeat weekly); no-MAWB bucket sorts by routing+consignee for consolidation; import master = OBL/MAWB with job-no fallback;
  a bare milestone tick shows a quiet 🔄 marker, not a misleading 💬.

```
station ERP DBs (READ-ONLY)                                  erpops (operational state, writable)
  Sea: blhead / blcont / PIC      --- ops-eval.ps1 ------>    shipment_alerts, milestone_def (mode Sea|Air),
  Air: awbhead                       (mode-aware evaluator)   milestone_evidence_map, …
        |  (seed-alerts.ps1 -Mode Sea|Air = listener stand-in)        |  serve-ops.ps1 (HttpListener + JSON API)
        |                                                             v
        '------- READ ONLY, never written -------          browser (index.html / ops.js)  — reads only erpops
```

**Two-server mode (added):** the read-only ERP and the writable `erpops` may live on **different** servers.
Config gains optional `opsServer`/`opsAuth`/`opsUser`/`opsPassword` (fall back to the source connection when
absent — single-server configs unchanged). All scripts route `master`+ops-DB to the ops server, everything else
to the source. Used so the network ERP (read-only login) is read remotely while `erpops` is created locally.

## Two test environments

| Env | Source ERP | Data | opsDb | Port | Notes |
|---|---|---|---|---|---|
| **Local** | `fibsbkk` on `localhost\SQLEXPRESS` (Win auth) | **frozen 2021** snapshot; as-of `2021-11-27` | `erpops` (local) | 8078 | Only `fibsbkk` has the real 381-col schema; `fibsdemo_*` are stripped. Sea/BKK. Milestone fields empty → all-Red. |
| **Network** | `fm3k*` on `192.168.5.2` (SQL login `dashboard`, read-only) | **LIVE to today**; as-of = today | `erpops_net` (local, two-server) | 8079 | **12 stations seeded** (YVR SHA HAM HKG JKT NRT JNB SIN BKK TPE LAX SGN), 618 rows. 414–420-col schemas vary by office → `Filter-Cols`. Login can't `CREATE DATABASE` → two-server mode. |
| **demoerp** (current) | `fm3k*` on `192.168.5.2` (SQL login `dashboard`, read-only) | **LIVE to today** | `demoerp` (local `localhost\SQLEXPRESS`, two-server) | 8079 | Same fm3k group as Network, own ops DB. Config `ops.config.demoerp.json`; reach `192.168.5.2` over Swivel VPN — see the `swivel-vpn` skill for the Surfshark route fix. Sea fix (`90bc63b`) applied + all 12 stations seeded → Sea 344G/22R. |

**Stations & access.** Group offices are same-ERP databases `fm3k<code>` on `192.168.5.2`. Seeded: 12 (above).
**Excluded:** `fm3kco` is the master DB (no `blhead`). **Blocked — need a DBA grant:** the `dashboard` login is
**denied read** on `demoerp` and `fm3kjfk`; both can be added as stations once read access is granted. Each station
is seeded with its own `-StationCode` (3-letter office code, e.g. `HKG`, `SHA`); the station picker reads the list
from config (`stations[]`) via the config payload.

Configs are gitignored: `ops.config.json` (local), `ops.config.network.json` (network), `.env.txt` (creds the
user pasted). Only `*.example.json` is tracked.

## Key findings (these shaped the build)

1. **Snapshot vs live.** `fibsbkk` is a frozen 2021 copy with empty operational fields (worklist skews Red);
   `fm3khkg` is live with fields populated (realistic Green/Amber/Red). Same code, different data maturity.
2. **Milestone completion resolves in priority order** (sparse data handled by design, not a blocker):
   **(1) ERP data** (`complete_rule` over real columns; qualification is data-driven) → **(2) PIC/EDI evidence**
   (configured `documentTypeCode`) → **(3) planned due-window** (baseline or fixed offset) → **(4) manual Tick &
   Confirm** (operator closes even with no data; un-tickable).
3. **Air freight is a separate table.** Sea = `blhead` (+`blcont` containers); Air = **`awbhead`** (465 cols).
   Air operator-shipments = `awb_type IN('H','S')` (H=house, S=direct; M=consol master & B=booking pipeline
   excluded). `carr` (carrier code) is **always empty** → conveyance = vessel/voyage (sea) and **`flight1`** (air);
   for a **consolidated** house `flight1` is blank and the flight lives on the **MASTER** (`awb_type M/B`) row,
   looked up by MAWB. The airline code is in `rout_by_1` (not a substitute for the flight number).
4. **Carrier code & ETA are sparse/empty** in these copies; consignee/shipper **names** are ~100%. Container data
   (`blcont`) is rich for sea FCL; air uses pieces/weight (`t_book_qty`/`t_book_wgt`).
5. **Cross-station factory-booking** (advice, not yet built): at booking time there's no HBL/MBL, only the
   destination **station/site code** stamped on the origin's booking (`dest`/`agn2_code`). The plan: each origin
   publishes its outbound bookings into a shared `erpops` feed keyed by destination code; the import station reads
   only `erpops` (no cross-DB query on the request path). Needs a station-code identity directory.

## What's built

| File | Role | State |
|---|---|---|
| `setup-ops.ps1` | Creates `erpops` + base tables + `company_dim`; in-place ALTERs add worklist enrichment columns (consignee/shipper name+contact, vessel_voyage, container_summary/count, total_weight/cbm, arrival_state, sort_key) **plus the display/filter set: house_bill, master_bill, incoterm, cust_ref, container_no, liner_so, cargo_ready, shipper_code, consignee_code, ctrl_code, pol, pod** and `milestone_def.mode` | ✅ idempotent, two-server |
| `seed-milestone-config.ps1` | Config-as-data: **37** `milestone_def` rows — Sea (23, Export+Import) + **Air (14)** with `mode` — + starter evidence map | ✅ |
| `ops-eval.ps1` | Pure evaluator: `New-ShipContext` (sea) + **`New-AirContext`** (air); `Eval-Milestones` filters defs by bound **and mode**; planned-due anchor is mode-aware | ✅ |
| `eval-shipment.ps1` | Read-only one-shot card for one shipment (two-server aware) | ✅ |
| `seed-alerts.ps1` | Listener stand-in. **`-Mode Sea|Air`**: reads `blhead`/`blcont` or `awbhead`, batches PIC + consignee/shipper contacts, computes arrival bucket + cargo profile + conveyance, pulls **house/master bill, incoterm, container/liner-SO, cargo-ready, role codes + POL/POD**, resolves company **names** via a single chunked `custsub.code2` clustered seek (never the heavy party views) → `company_dim`, resolves **vessel code→name** via a chunked `veslmstr.code` seek (bound-aware: sea Export reads `vessel_2/voyage_2`, Import `vessel_1/voyage_1`), upserts `shipment_alerts`. **`Filter-Cols`** intersects wanted columns with the station's `INFORMATION_SCHEMA` so schema-variant offices (e.g. HAM `blhead` lacks `picuser`) seed without failing | ✅ |
| `serve-ops.ps1` | Web service: worklist (arrival-grouped, `&station=` filter), shipment detail, notes/arrangements/reminders, **enriched My-Tasks**, manual milestone-close, **`/api-ops/companies` (name type-ahead), `/api-ops/ports` (POL/POD lists)**. Config payload returns `stationCode` + `stations[]` + `linkEnabled`. **Auth: login by EMAIL** (`Get-OpsUserByEmail` + the `New-OpsSession` seam; username fallback; `users.json` present → login/sessions/scope, absent → open/demo) + **SWIVEL L!NK** OAuth seam (`/api-ops/link-oauth-login`, env-gated, federates on email, auto-provision). Per-station ERP routing via `Resolve-ForwarderCode`→`Get-StationOwnCode` (`fm3kco.site` owncode). Admin-gated `/api-ops/admin/*`: **`users`** (now incl. `authProvider`), **`milestones`**, **`evidence`**, and **`erp-settings`** (`Set-ErpApiMap` — partyGroupCode/forwarderCode). **Upload-to-clear**: `/api-ops/erp-file-upload`. Config/JSON read via `[IO.File]::ReadAllText` (UTF-8 safe). Reads only `erpops` | ✅ |
| `admin-ops.html` | Admin-only page, **four tabs**: **Users** (add/edit + live search; email is the required sign-in key, a **Sign-in** column + `authProvider` selector, "User name" = internal id), **Milestones & alerts** (CRUD over `milestone_def` + alert timing), **Documents** (CRUD over `milestone_evidence_map` pic_doctype rows = ERP Document Type codes), and **ERP API** (`partyGroupCode` + fallback `forwarderCode`, via `/api-ops/admin/erp-settings`). Non-admins 403 | ✅ |
| `login.html` / `users.example.json` | Login page (**Email + password**) + user-record template incl. `authProvider`; logins are the gitignored `users.json` | ✅ |
| `restart-ops-network.bat` / `restart-ops-local.bat` | One-double-click **restart** of the web service (8079 network / 8078 local): stop-then-start, **port-scoped**, kill excludes `$PID` | ✅ |
| `seed-ports.ps1` | Seeds the POL/POD port list for the filter dropdowns | ✅ |
| `index.html`/`ops.js`/`styles.css` | UI: 🚢Sea/✈Air toggle, Import/Export toggle, **station picker**, **filter bar** (text `yyyy-mm-dd` date window default = current week, **company name** type-ahead across any role, POL/POD), **vessel/flight-grouped** collapsible worklist, mini-cards (house bill, container/liner-SO, incoterm, cust-ref), shipment drawer w/ milestones + **🔔 Remind-me** + **Arrangements** panel, custom in-page dialogs (no native `prompt`), My-Tasks | ✅ |
| `ops.config.example.json` | Config template | ✅ |
| `setup-ops.ps1` (feed) | +4 tables for the cross-station feed: `station_dim`, `station_route_map`, `inbound_booking_feed`, `feed_watermark` | ✅ idempotent |
| `seed-station-map.ps1` | Seeds `station_dim` from `asw_station_list` + builds `station_route_map` from the **authoritative intercompany convention** `fm3kco.site.owncode`↔`location` (e.g. `S0001`→`HKG`) — the office's system customer code, carried on a booking's `agn2_code`/`roagent`/`rcustomer` — with POD fallback + **unmapped-code discovery report** | ✅ |
| `publish-bookings.ps1` | **Publisher** (one origin/invocation): reads outbound shipments (`bound='O'`, **no bill/awb-type filter** — destination office decides cross-station, not the doc stage) destined to another station, resolves `dest_station` via `station_route_map`, keys the feed on **`sono`/`booking`** (the SO number, stable from booking stage when `blno`/`mawb` are still empty), UPSERTs `inbound_booking_feed`; **incremental** via `feed_watermark` | ✅ |
| `serve-ops.ps1` (feed) | `/api-ops/inbound` (reads only the feed by `dest_station=stationCode`) + `/api-ops/inbound-assign` (local assign → threads a `FEED:` note into the assignee's My-Tasks); `stationCode` in config payload | ✅ |
| `ops.js`/`index.html` (feed) | **📥 Inbound bookings (pre-arrival)** panel (Import bound only): light-grouped cards (source station, shipper, controlling customer, agent, POL→POD, ETD/cargo-ready) with **Assign** → roster picker | ✅ |
| `register-ops-tasks.ps1` | Task Scheduler: `publish-bookings` per station (Sea 3×/day, Air 2h, **staggered**) + weekly `seed-station-map` | ✅ |
| `erp-edit.html`/`erp-edit.js`/`erp-edit-fields.json` | **Staff-internal ERP data-correction editor** (pop-out from the worklist drawer). HBL/AWB-grid layout; fixes bad source data (DUMMY/ZZZ codes, addresses, dates, carrier, container counts) and pushes **only changed fields** to Swivel `/booking/update`. Field dictionary mirrors `doc-fields.json`; every write key verified against the OpenAPI spec | ✅ verified live + screenshots |
| `serve-ops.ps1` (erp-edit) | `Handle-ErpEditSeed` (bound-aware ETD/ETA + vessel/voyage derivation, master-name resolve), `Handle-ErpMasterSearch` (live custsub/port/service/liner + Incoterms list), `Save-ErpEdit` (authoritative re-read, diff, audit) + routes `/api-ops/erp-edit`, `/erp-master`, `/erp-edit-save` | ✅ |
| `erp-doc-api.ps1` (erp-edit) | `Build-ErpPatchPayload` (only-changed; `bookingParty` nesting; bool/number/date/`bookingReference`/container-array handling; ETD+flight-time fold into `departureDateEstimated`) + `Invoke-ErpEditPush` (mock + live read-merge-write existence guard, best-effort) | ✅ |
| `setup-ops.ps1` (erp-edit) | +`erp_edit_log` audit table (job_no, before→after `changed_json`, erp_status/steps/error), idempotent | ✅ |

**Cross-station inbound booking feed (key finding 5) — built (publish/subscribe fan-in).** An origin station's
scheduled `publish-bookings.ps1` writes its cross-station bookings into the central `erpops.inbound_booking_feed`
tagged with `dest_station`; the importing station's app reads ONLY rows addressed to it (`dest_station=stationCode`,
indexed seek) and assigns them locally. No station ever queries another station's ERP; the request path never
touches the ERP. Scales linearly with stations (each publishes its own delta).
**Route map (convention join — CONFIRMED on live `fm3k*`):** the destination office is carried on the origin's
booking as the destination **agent code** (`agn2_code`, primary) / **R-O agent** (`roagent`) / controlling customer
(`rcustomer`), holding that office's **system customer code** (e.g. `S0001`=HK). `fm3kco.site` maps
`owncode`→`location` (the 3-letter StationCode), so `S0001`→`HKG`. Verified end-to-end: SIN booking `SINHKG000002`
(`agn2_code=S0001`, `SGSIN→HKHKG`, no bill yet) surfaces under HKG's `/api-ops/inbound`. (The old guess via
`asw_station_list.FM3000_CODE` was a different code space and never matched — replaced. The frozen `fibsbkk`
snapshot still has no intragroup bookings, so its local testing keeps the POD-fallback `AUSYD→SYD`.)

**Not yet built:** real `listener-engine.ps1` (scheduled), `baseline-refresh.ps1` (3-yr lane averages that back the
`baseline` alert timing — until it exists, `baseline` milestones fall back to fixed/none), and `pic_user`↔app-user
mapping. (**Built since last summary:** `admin-ops.html` + real auth + milestone-admin + restart bats.)

**Feed reconciliation (Phase 5) — mechanism in place, needs live data.** `/api-ops/inbound` already suppresses a feed
row whose **origin HBL** matches a local import job (`shipment_alerts.house_bill`, bound=Import) — so received shipments
show under Arrivals, not Inbound. In the current ERP **copy** the bookings and import jobs are independent fabricated
records (different HBL numbers) so it matches 0; on live EDI-linked data (import job carries the origin HBL) it will fire.
If the live import job stores the origin HBL in another column (or you prefer MBL / origin-office+job), point the match there.

**Loose ends when resuming:**
- **All 12 stations published to the feed (Sea+Air)** and **worklist re-seeded** on the fixed code (`departure2` ETD,
  `routing` Air incoterm, actual air cargo). Feed default-hides stale via the recency window; use **show all** to see history.
- **10 stale `HK01` rows** in `erpops_net.shipment_alerts` — harmless; a `DELETE … WHERE station='HK01'` was blocked by the
  auto-permission classifier, so still present. Clear when convenient (data only, not in git).
- **`JNB`** publishes 0 cross-station rows ("no route rules") — its intragroup bookings are Air-only and don't hit the Sea
  route discovery; run `seed-station-map.ps1 -Mode Both` to cover it.
- **`demoerp` / `fm3kjfk`** await a DBA read grant for the `dashboard` login before they can be seeded as stations.
- UI changes are **API-/data-verified but not browser-clicked** in this env (no Node/browser) — give them a click on :8079.

## Proven behaviour (tested live)

- **Worklist is arrival-driven, grouped by vessel/voyage (sea) or airline+flight (air)** — not one card per
  shipment. Sea group headers show the **vessel NAME** (resolved from `veslmstr`), not the raw code — bound-aware:
  Export reads the ocean vessel `vessel_2/voyage_2`, Import the arriving vessel `vessel_1/voyage_1` (e.g.
  `🚢 YM WISH / 038W`); this also lifts sea vessel coverage from ~12% (old `vessel_1`-only) to ~100%. Import
  buckets: **Arrived / Arriving / Planning**; Export: **No-space / Customs-window / Cargo-pending
  / On-track**. Each conveyance gets ONE derived status (a vessel isn't split across buckets). Collapsible groups +
  collapse-all. Sorted ETA-first, falling back to time-in-transit.
- **Richer cards:** consignee/shipper name, cargo profile (FCL `2×40HC`; LCL weight+CBM; **air `N pcs · kg`**),
  conveyance, arrival chip, R/A severity, notes flag, plus **origin-office house bill** (the doc the customer
  received — shown for import, not the internal job no), **container / liner-SO** (to tell near-identical sea
  arrivals apart), **incoterm** (delivery responsibility), and **customer ref / PO** (`spotid`).
- **Filters & multi-station (tested):** station picker filters the worklist to one office (`?station=SHA` → 124
  SHA-only rows; config returns 12 stations). Date window defaults to the **current week** (This-week / All-dates
  buttons). **Company filter is name-searchable** (type-ahead against `company_dim`, never the 300k master) and
  matches a company in **any** role — shipper, consignee, agent, or controlling customer. POL/POD dropdowns let an
  operator surface, e.g., all China-origin shipments first.
- **Arrangements panel** (per shipment): who-to-contact (consignee/shipper + `tel:`/`mailto:` from the ERP views),
  and operator-recorded Trucker/Broker/Warehouse/Customer tasks with status — stored in the JSON note store as
  `kind='arrangement'` (no ERP write).
- **My-Tasks reworked:** "Reminders from others" (@-mentions) + "My follow-ups" (notes/reminders you raised);
  excludes completion records; cards enriched with consignee + shipment info; **🔔 Remind-me with a due date**
  (overdue/today highlighted, badge counts them); compact cards (click to open, ✓ to clear).
- **Manual Tick & Confirm** flips the rollup, threads a note, is un-tickable. Custom themed dialog (no
  "localhost says" browser prompt).
- **Air & Sea both seed and render**; cross-mode `job_no` distinct (air `AEHKG`/`AIHKG`, sea `SEHKG`/`SIHKG`).

## How to run

```powershell
# --- LOCAL (frozen 2021 snapshot, BKK, sea) ---
.\setup-ops.ps1                                                            # create erpops (idempotent)
.\seed-milestone-config.ps1
.\seed-alerts.ps1 -Station fibsbkk -StationCode BKK -AsOf 2021-11-27 -Limit 120
.\serve-ops.ps1                                                            # http://localhost:8078/

# --- NETWORK (live fm3k*, two-server: read network ERP, write local erpops_net) ---
.\setup-ops.ps1            -ConfigPath .\ops.config.network.json
.\seed-milestone-config.ps1 -ConfigPath .\ops.config.network.json
$today = (Get-Date).ToString('yyyy-MM-dd')
# Seed all 12 stations (db fm3k<code> -> StationCode <CODE>), both modes:
$stations = @{ YVR='fm3kyvr'; SHA='fm3ksha'; HAM='fm3kham'; HKG='fm3khkg'; JKT='fm3kjkt'; NRT='fm3knrt';
               JNB='fm3kjnb'; SIN='fm3ksin'; BKK='fm3kbkk'; TPE='fm3ktpe'; LAX='fm3klax'; SGN='fm3ksgn' }
foreach ($code in $stations.Keys) {
  foreach ($m in 'Sea','Air') {
    .\seed-alerts.ps1 -ConfigPath .\ops.config.network.json -Station $stations[$code] -StationCode $code -Mode $m -AsOf $today -Limit 120
  }
}
.\serve-ops.ps1            -ConfigPath .\ops.config.network.json -Port 8079   # http://localhost:8079/
# In the UI: pick the All lens, use the station picker to focus one office; toggle 🚢Sea/✈Air, Import/Export,
# and the filter bar (date window, company name, POL/POD).

# --- CROSS-STATION INBOUND BOOKING FEED ---
.\setup-ops.ps1                          # creates the 4 feed tables (idempotent)
.\seed-station-map.ps1                    # station_dim + route map; prints UNMAPPED codes to curate
.\publish-bookings.ps1 -Station fibsbkk -StationCode BKK -Mode Sea   # publish BKK's cross-station bookings
# Importer view: set "stationCode" in config to the destination station; the 📥 Inbound panel (Import bound)
# shows rows where dest_station=stationCode. Locally the POD rule AUSYD->SYD routes BKK bookings to "SYD".
# Schedule it all: .\register-ops-tasks.ps1   (publish per station, staggered; weekly map refresh)

# --- RESTART the web service after a code/config change (stop-then-start, port-scoped) ---
# Double-click restart-ops-network.bat (8079, ops.config.network.json) or restart-ops-local.bat (8078, ops.config.json).
# Switching machines/DBs: copy a config to ops.config.<env>.json and point a bat (or -ConfigPath) at it; env DB_* override too.
```

## Deploy: ASP.NET Core (.NET 10) to demoerp on IIS

The web tier is ported to ASP.NET Core (`server/`, project `Ops.csproj`, `net10.0`, in-process ANCM). demoerp is
the IIS-hosted target: `server\publish\` served by IIS site/pool **`erpops-demoerp`** on **http://localhost:8080**
(8079 is the dev PS HttpListener instance; the `port` in config is informational for a self-hosted run only).

**Readiness (verified 2026-06-16):** code is publish-ready — `dotnet publish -c Release -o publish` builds clean
(exit 0) and emits a valid IIS artifact: `Ops.dll`, `Microsoft.Data.SqlClient.dll`, locale satellites, and a
`web.config` with the `AspNetCoreModuleV2` in-process handler. `.NET 10 SDK 10.0.301` + ASP.NET Core runtime
`10.0.9` are installed.

**Config — two-server split** (`ops.config.demoerp.json`, gitignored; pool sets `OPS_CONFIG` to it):
- **Ops DB** `demoerp` on `localhost\SQLEXPRESS`, `opsAuth=integrated` — no password; the deploy script grants
  `db_owner` on `demoerp` to the pool identity `IIS APPPOOL\erpops-demoerp`.
- **Source ERP** `fm3k*` on the VPN'd SQL host, `auth=sql` (read-only) — set `user`/`password` before go-live.
- Fill in real `stations[].database` names and confirm `stationCode`; `erpApi.mock=true` keeps doc-issue offline
  until a token is set. `Config.cs` resolves the repo root from `OPS_ROOT` (the pool env), else walks up to find
  the config file.

**Prerequisites / blockers on a fresh machine:**
- **IIS + ASP.NET Core Hosting Bundle (ANCM)** must be installed, and the `erpops-demoerp` site/pool created — run
  the one-time, **elevated** `deploy-local-iis-demoerp.ps1` (enables IIS features, installs the Hosting Bundle via
  winget, grants the pool SQL `db_owner` + NTFS rights, creates the pool/site on 8080). `redeploy-demoerp.bat` does
  **not** bootstrap these — it assumes they exist.
- **`ops.config.demoerp.json`** must exist in the repo root (gitignored → absent on a fresh clone; the app throws
  `FileNotFoundException` at startup without it).
- **`setup-ops.ps1`** must have created the `demoerp` schema on `localhost\SQLEXPRESS`.
- **`users.json`** absent → app runs in **open/no-auth mode** (anyone auto-sessioned); add it for real auth.
  (`roles.json` is not used — roles live inline on each user record.)

```powershell
# --- demoerp: ONE-TIME IIS bootstrap (elevated PowerShell) ---
powershell -ExecutionPolicy Bypass -File .\deploy-local-iis-demoerp.ps1   # IIS + Hosting Bundle + pool/site on 8080
.\setup-ops.ps1 -ConfigPath .\ops.config.demoerp.json                     # create the demoerp schema (idempotent)

# --- demoerp: REDEPLOY after a code change ---
.\redeploy-demoerp.bat        # app_offline -> dotnet publish -c Release -o publish -> recycle pool -> http://localhost:8080/
# Secrets check: http://localhost:8080/ops.config.json must return 404.  HTTP 500.3x/500.19 => Hosting Bundle
# installed before IIS: run dotnet-hosting...exe /repair (or re-run deploy-local-iis-demoerp.ps1). VPN must be up.
```

## Constraints (do not violate)

- **`Packet Size=512`** on every SQL connection string (VPN MTU).
- HttpListener server is **single-threaded**; UI/request paths read only the small `erpops` tables, never the ERP.
  All heavy ERP joins (containers, contacts) happen in `seed-alerts` off the request path.
- **Source ERP DBs are READ-ONLY** — all writes go to `erpops`/`erpops_net` or the gitignored JSON note store.
- **Secrets gitignored** (`ops.config.json`, `ops.config.*.json`, `.env*`, `users.json`, `roles.json`,
  `ops-lists/`, `*.log`); verify with `git status` before any commit. Only `*.example.json` is tracked.
- PS 5.1 traps: coerce `$null`→`[DBNull]::Value` for SQL params; serialize JSON-store records individually (never
  hand `ConvertTo-Json` a whole array). Client coerces 0/1-row arrays via `arr()`; responses are `no-store`.
- **Read config/JSON with `[IO.File]::ReadAllText`, not `Get-Content -Raw`** — PS 5.1 decodes a BOM-less UTF-8 file
  as ANSI, so `—`/`·` arrive as mojibake (`â€”`/`Â·`). Keep `.ps1` source **ASCII-only**: a non-ASCII byte in a
  BOM-less script can terminate a string and cause a runtime parse error. New HTML pages need `<meta charset="utf-8">`.
- **Dates are ISO `yyyy-mm-dd` everywhere** (e.g. `2023-12-31`) — never the locale `mm/dd/yyyy`, and **no native
  `<input type="date">`** (locale format + unwanted calendar popup). Use a `text` input with `placeholder="yyyy-mm-dd"`
  + a `^\d{4}-\d{2}-\d{2}$` guard; SQL `CONVERT(...,23)`; PowerShell `.ToString('yyyy-MM-dd')`.
- Verify any computed light/KPI against a direct read-only SQL query of the source ERP before declaring done.
