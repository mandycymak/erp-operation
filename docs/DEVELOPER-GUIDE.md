# Control Tower — Developer & Coding-Standards Guide

**Audience:** any developer who clones this repo and changes the code — **especially if you use Claude (Claude
Code) on your own PC.** Read this first so your changes match the house style and the next person (or the next
Claude session) stays consistent.

The single most important rule: **match the existing code; do not re-architect it.** The stack: an **ASP.NET
Core (.NET 10) web tier in `server/`** (raw ADO, no Dapper), **PowerShell 5.1** off-path seeders, vanilla
ES5-ish JavaScript on the client (**no build step**), SQL Server for storage. Keep it that way.

> 🏗️ **Web tier = `server/` (.NET); `serve-ops.ps1` = legacy/rollback.** New API work goes in `server/`
> (`Handlers.*.cs`, one area per file; routes wired in `Program.cs`). Keep `serve-ops.ps1` in **parity** when you
> touch a shared contract so rollback stays valid — that's why several changes below land in both. JSON casing is
> **verbatim** (`PropertyNamingPolicy = null`); the client reads exact keys. The **off-path seeders stay
> PowerShell** (`seed-alerts.ps1`, `publish-bookings.ps1`, `seed-*`).

---

## 0. If you're driving with Claude Code — read this

The repo root carries **`CLAUDE.md`** (hard constraints + the critical gotchas) and **`BLUEPRINT.md`** (the
authoritative, approved design, section by section). Claude Code loads `CLAUDE.md` automatically. **Keep both
accurate** — when you change a convention, update them in the same commit. `PROJECT-SUMMARY.md` records what is
actually built and proven; update it when you ship something.

> When adding a feature, point Claude at the relevant `Handle-*` function (server) and the sibling
> **erp-dashboard** implementation — most of this app's plumbing was lifted from there and the patterns
> transfer almost verbatim.

---

## 1. The non-negotiables (inherited — respect them)

| Rule | Why |
|---|---|
| **`Packet Size=512` on every connection string** | The VPN MTU black-holes default 8 KB TDS packets on large responses → "semaphore timeout". |
| **VPN must be up** to hit SQL | The DB hosts are only reachable through the Swivel OpenVPN. |
| **Source ERP DBs are READ-ONLY** | All writes go to `erpops` or the gitignored JSON note store. Never `INSERT`/`UPDATE`/`ALTER` an ERP table. |
| **Bound every query; never read the ERP on a request path** | The .NET tier is **multi-threaded** with a **`dbGate`** semaphore (default 16) capping concurrent SQL so a burst can't stampede the small-MTU VPN box, and **per-request `ReqState`** carries row-level scope (the structural fix the .NET port was for). Still: bound every query with `CommandTimeout`; the UI reads only small `erpops` tables, never the ERP on a request path. (The legacy `serve-ops.ps1` was single-threaded — one `HttpListener` request at a time; that constraint applies only if you run it.) |
| **Secrets are gitignored** (`ops.config*.json`, `users.json`, `roles.json`, `ops-lists/`, `*.log`, `erp-mock/`, `backups/`) | Credentials / the ERP token / access policy. (`users.json` is now only a legacy import source/backup — the live user store is SQL `app_user`.) Commit only `*.example.json`. **Check `git status` before every commit.** |
| **All SQL is parameterised** | `SqlParameter` / `@name` — never string-build values from user input. |
| **Row-level scope is the security boundary** | Per-user scope must be AND-ed into *every* data query, not just the visible table. Out-of-scope rows return "not found" — no existence oracle. |
| **Dates are ISO `yyyy-mm-dd` everywhere** | Display, input, storage. **No native `<input type="date">`** — use a text input + `^\d{4}-\d{2}-\d{2}$` guard. SQL `CONVERT(...,23)`; PowerShell `.ToString('yyyy-MM-dd')`. |
| **`.ps1` files stay ASCII-only** | PS 5.1 runs a BOM-less script as ANSI; a non-ASCII byte (em-dash) can terminate a string and cause a runtime parse error. Read text/JSON with `[IO.File]::ReadAllText`, never bare `Get-Content`. |

---

## 2. Repository map

| File | Role |
|---|---|
| `setup-ops.ps1` | creates the `erpops` schema (operational + feed + draft-document tables), idempotent, two-server aware |
| `seed-milestone-config.ps1` | the milestone matrix as data (`milestone_def` + starter evidence map) |
| `ops-eval.ps1` | pure evaluator — `New-ShipContext` / `New-AirContext`, `Eval-Milestones`, the route-point builders (`Get-AirRoutePoints` / `Get-SeaRoutePoints`) |
| `seed-alerts.ps1` | the listener stand-in (`-Mode Sea\|Air`): reads `blhead`/`awbhead`, batches contacts, computes arrival/cargo/conveyance, upserts `shipment_alerts`. **`-Delta`** = incremental pull via the `alert_watermark` high-water (only rows whose ERP create/update moved); includes booking-stage rows (`bill_stage`) |
| `eval-shipment.ps1` | read-only one-shot card for one shipment (diagnostic) |
| `seed-station-map.ps1` / `publish-bookings.ps1` | the cross-station inbound feed (identity directory + publisher). The publisher **fans out one feed row per involved office** (destination agent / notify / consignee / routing / controlling) and sets the **`offshore`** flag for off-bill-only involvement |
| **`watch-bookings.ps1`** | new-export-booking watcher → `booking_alert`; resolves the factory(shipper) and alerts via the config `bookingAlert` block |
| `register-ops-tasks.ps1` | Task Scheduler registration (feed/worklist refresh — worklist now `seed-alerts -Delta`, Air ~5 min / Sea ~15 min — **`Ops Booking Watch`**, **+ the governance jobs `Ops Backup` / `Ops Healthcheck` / `Ops Purge`**) |
| **`setup-database.bat` / `seed-data.bat` (→ `seed-data.ps1`)** | one-command onboarding: schema+tables+milestone config, then the live-ERP fill looping every station x Sea/Air |
| **`backup-ops.ps1`** | nightly ops-DB `.bak` (COPY_ONLY) + gitignored-secrets copy + prune; non-zero exit on failure |
| **`ops-healthcheck.ps1`** | the watchdog — checks app/db/tasks/feed/backup/storage/disk/VPN → `health_check_log` + alert (config `alerts`: webhook/SMTP) on failure |
| **`purge-ops.ps1`** | data retention/aging (config `retention`) + log rotation — keeps the ops DB small over years (`-WhatIf` previews) |
| **`server/`** | **the .NET web tier (current)** — `Program.cs` (routing, no-store/CORS, static-secret guard, `dbGate`, the unauthenticated **`GET /api-ops/health`** probe), **`Auth.cs`** (backs onto SQL `app_user`+`app_user_scope`; `SeedOrImport` seeds default admin / imports legacy `users.json` once), **`Settings.cs`** (runtime ERP connection from `app_setting`, overrides `ops.config.json`), `Config.cs`, `Sql.cs`, `Filter.cs`, **`Log.cs`** (`Log.Error` → `ops-error.log`), **`ErpLog.cs`** (every ERP call → `erp_api_log`, `corr_id` scopes), and `Handlers.*.cs` (one area per file: Worklist/Shipment/**Find**/Notes/Tasks/Inbound/**Bookings**/Erp*/Doc/Admin/Misc). `Handlers.Admin.cs` also serves the read-only IT-Admin views (`/api-ops/admin/health` · `/storage` · `/audit` · `/errors` · `/erp-api`) and the ERP-connection editor; `Handlers.Bookings.cs` is the scoped **New bookings** endpoint. **`DoctypeMap.cs`** (upload-to-clear doctype→milestone map) and **`DocGenMap.cs`** (Generate-document documentTypeCode↔houseTypeCode map) are admin-editable caches reset on save. `Notes.cs` backs the SQL `job_note` store; **`Llm.cs`** is the optional, flag-gated Find fallback adapter. `dotnet publish -c Release` to deploy |
| `serve-ops.ps1` | the **legacy** web service (rollback) — same routes/contract as `server/`; keep in parity when a shared contract changes |
| **`i18n.js`** | the client localization layer — `tr(en, ctx?)`, `applyDom()`, `boot()`, `setLang()`, the `SUPPORTED` language list |
| **`lang/<code>.json`** | UI translation dictionaries (English source string = key). `lang/zh-Hans.json`, `lang/ja.json` |
| `erp-doc-api.ps1` | the Swivel 3rd-party ERP API client (agree / issue: booking/update, file/upload, event/update; `Build-ErpPatchPayload` / `Invoke-ErpEditPush` for the Edit-ERP-data push) |
| `erp-edit.html` / `erp-edit.js` / `erp-edit-fields.json` | **Edit ERP data** editor (HBL/AWB-grid layout) + its field dictionary (`writeKey` per field) |
| `index.html` / `ops.js` / `styles.css` | the operator UI |
| `admin-ops.html` / `login.html` | admin (Users · Milestones · **Documents** · **Generate documents** · ERP API · **Audit & Health** · **Change log** tabs) and login |
| `doc-editor.html` / `doc-editor.js` | staff draft editor (diff, send, agree, issue, amend) |
| `bl-review.html` / `bl-review.js` / `bl-review.css` | the public customer review page |
| `bl-form.js` | the **shared** bill renderer (used by both the staff editor and the customer page) |
| `doc-fields.json` | the field dictionary — the single source of truth for both server whitelist and client render |
| `erp-api-map.json` | non-secret ERP deployment codes |

---

## 3. Back-end conventions (`serve-ops.ps1`)

### Structure & SQL

- **Routing loop.** SQL-free endpoints are placed **before** the `$cn` DB-connection block; DB handlers
  after. Each handler is `Handle-*` / `Save-*` and returns a hashtable that `Send-Json` serializes with
  `no-store` headers.
- **`RunQ $cn $sql $params $timeoutSec`** is the query helper: parameterised, retries one genuine transient
  drop, **throws immediately on a timeout** (does not retry — a slow query just holds the single-threaded
  server). `Reset-Conn` reopens a dropped connection.
- **Idempotent schema** uses `IF OBJECT_ID(...) IS NULL CREATE` / `IF COL_LENGTH(...) IS NULL ALTER`.

> **Gotcha — `ConvertTo-Json` and arrays (PS 5.1).** A 0-row array serializes to nothing, a 1-row array to a
> bare object. Pass `-InputObject` (not the pipeline), serialize JSON-store records individually, and coerce
> `$null`→`[DBNull]::Value` for SQL params. The client re-coerces every list with `arr()`.

### Reading the ERP (off the request path only)

The draft seed, the detail drawer, and the **Edit ERP data** seed/master-search are the only paths that touch
the ERP, and only at staff-click time — bounded (`Connect Timeout=15`, `CommandTimeout=8`, `Packet Size=512`),
keyed seeks. (`Connect Timeout` was raised 5→15s: the VPN's SSL pre-login handshake runs ~4 s and was
intermittently timing out the open.)

> ℹ️ **Edit ERP data subsystem.** `Handle-ErpEditSeed` seeds current values + resolved master names from the
> header **and the line table** (Air `awbdetl`, Sea `blitem`/`blcont`, keyed `blh = ref`, first line);
> `Save-ErpEdit` re-reads the live ERP for the authoritative *before*, diffs, and pushes **only changed fields**
> via `Build-ErpPatchPayload` (party keys → `bookingParty`; `flexData.<sub>` → `flexData`; container table →
> `bookingContainers`). Fields are added/retargeted in `erp-edit-fields.json` (`readFrom` / `writeKey`) — no
> code change for a simple remap; a column on the **line** table needs a line read in `Handle-ErpEditSeed`.

> ⚠️ **AIR detail-line saves need the WHOLE cargo block (verified live 2026-06-26).** The ERP writes the air
> `awbdetl` line (`mark2`/`desc2`/`good_desc2`/`rece_cbm` ← `shipMarks`/`goodsDescription`/`commodity`/`cbm`) **only
> when `/booking/update` carries the full cargo block together** — `quantity,quantityUnit,grossWeight,weightUnit,cbm,
> shipMarks,goodsDescription`. A minimal patch that changes one detail field is silently dropped (the ERP echoes it
> back unchanged). So `Erp.EditPush` **and** `ErpDoc.DocAgree` **read-merge the cargo block from the live
> `/booking/get`** when `module=="AIR"` (preserve number types — `PropCI(...).DeepClone()`). The editor seeds air
> `cbm` from `awbdetl.rece_cbm` (header `t_rece_cbm` is always 0 for air). HAWB/MAWB ARE writable (`houseNo`/
> `masterNo`) — but a **consol-shared MAWB** is rejected (`Duplicated MAWB#`). **Fill-from-master** is a separate
> `GET /api-ops/erp-master-detail` (full `custsub` party) wired to a ↻ icon in `erp-edit.js` (overwrite on click only).

> ⚠️ **Never probe column metadata on a request path.** `INFORMATION_SCHEMA.COLUMNS` / `sys.columns` for the
> read-only login on the **465-column** `awbhead` runs **40–70 s** (per-column permission checks) and can drop
> the connection, while the keyed data SELECT is ~0.3 s. **`Get-ErpCols` does not probe metadata** — it trusts
> a curated want-list; a genuinely-missing column makes one SELECT throw and the caller's try/catch degrades
> to the snapshot seed. Add new ERP columns to the want-list, never a metadata round-trip.

### Auth, roles & scope

`Cur-Stations` / `Cur-Pairs` / `Cur-Teams` / `Cur-Tier` emit the current user's scope; `Scope-StationClause`
/ `Scope-PairClause` AND it into queries; `Test-JobScope` gates by-job endpoints. Admin/manager bypass scope.
Builders **emit items** (no leading-comma wrap) — collect with `@(Cur-...)`.

**Sign-in is by email; `username` stays the internal identity.** `email` is the login / federation key (required +
unique); `username` keys notes/@-mentions/sessions/scope/`erpUsers` — **don't** switch those to email. The seam:
`Get-OpsUserByEmail` (case-insensitive) + **`New-OpsSession $ctx $u`** (builds the session + cookie, returns the
public payload) — every sign-in path calls `New-OpsSession`. `Handle-OpsLogin` matches email, with a `Get-OpsUser`
(username) fallback. Per-user `authProvider` (`local` | `swivel` | `both`); a `swivel` user has no salt/pwdHash.

> 🗄️ **The user store is SQL, not a file (`.NET`).** `server/Auth.cs` reads/writes **`dbo.app_user` +
> `dbo.app_user_scope`** (whole-store rewrite in a transaction on save, like `Notes.cs`); every public signature and
> the `UserRec` shape are unchanged, so Filter/Program/Handlers.Admin are untouched. **`SeedOrImport`** (called from
> `LoadAll`) seeds a default `admin`/`admin123` on an empty table, or imports a legacy `users.json` once (kept as a
> backup). `HashPwd` is the same salted-SHA256 as erp-dashboard, so imported hashes verify with no lockout. Because a
> user always exists after bootstrap, the open/auto-admin branch (`!AuthOn`) never triggers in production.

### Observability & the IT-Admin views (.NET)

- **Log handler exceptions, never swallow them.** Every `catch (Exception ex)` that returns a 500 calls
  `Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex)` first (`server/Log.cs` → `ops-error.log`, defensive
  like `Auth.Audit`, never throws). Add new write/data handlers the same way so a failure is diagnosable. The
  client response shape is unchanged (sanitizing the client-facing message is a deferred hardening item).
- **Audit the security-relevant actions.** `Auth.Audit(who, msg)` (→ `admin-audit.log`) already records user CRUD,
  milestone/ERP edits, doc lifecycle, and **logins/failed-logins**; keep new admin mutations audited.
- **IT-Admin read views** live in the admin-gated `Handlers.Admin` switch (`sess.Admin` check) and are **read-only,
  no scope** (admin sees the whole instance): `/api-ops/admin/health` (latest `health_check_log` per check + last-OK),
  `/storage` (`sys.dm_db_partition_stats` / `sys.database_files`), `/audit`, `/errors` and **`/erp-api`** (all
  **date-range + row-capped** with a `truncated` flag so a large log can't swamp the UI). The `Admin(...)` signature
  takes a `Qs` for these query params. The unauthenticated `GET /api-ops/health` (DB `SELECT 1`, 200/503) is the
  watchdog probe.
- **Log every ERP call at the choke point (`server/ErpLog.cs`).** `Erp.Call` wraps every Swivel request — success
  AND failure, incl. the previously-silent reads — into **`dbo.erp_api_log`** (endpoint, ok/HTTP-status, duration,
  the ERP's error text, bounded req/resp summaries). **`ErpLog.Begin(actor, station, ref)`** opens an `AsyncLocal`
  scope so the calls of one operation share a **`corr_id`** (a doc agree's `/booking/get` + `/booking/update`); the
  scopes live in `EditPush`/`DocAgree`/`DocIssue` and the ErpFiles/ErpEdit handlers. Logging **never throws** (falls
  back to `Log.Error`). Mock-mode calls are not logged. Surfaced via `/api-ops/admin/erp-api`.
- **ERP connection at runtime (`server/Settings.cs`).** `Settings.ErpBaseUrl`/`ErpToken`/`ErpMock` read **`dbo.app_setting`**
  (admin **ERP API** tab), overriding `ops.config.json` so the connection is fixable on-site with no file edit or
  restart (`Settings.Load()` at startup, reloaded on save). The token is **never returned** by the API (GET reports
  only `erpTokenSet`).

**SWIVEL L!NK** (`/api-ops/link-oauth-login` → `Handle-LinkOAuthLogin`, an SQL-free public route): redeems the
one-time `code` server-side at `SWIVEL_OAUTH_PROFILE_URL` (no client_id/secret), **verifies the echoed `state`**,
federates on `profile.email`, auto-provisions via `Provision-LinkUser` when enabled, then `New-OpsSession`. Gated
by `$LinkEnabled` (env `SWIVEL_OAUTH_PROFILE_URL`/`SWIVEL_OAUTH_XSYSTEM` or the `swivelLink` config block);
`/api-ops/config` exposes `linkEnabled`. Frontend `linkBoot()` (runs before `init()`) reads `mode`/`site` +
`#code&state`, redeems, then scrubs the fragment.

### Natural-language Find (`.NET only` — `Handlers.Find.cs`) + optional LLM seam

A feature added **after** the .NET port, so it has **no `serve-ops.ps1` parity** (don't back-port it). The
parser is **rule-based and client-side** (`parseOpsQuery` in `ops.js` — ports quotation's `parseDateWindow` /
`stripPlaceNoise` / stop-word approach, no LLM); the server just receives the extracted clue params.

The client UI (the header **🔎 Find** overlay in `index.html` / `ops.js`) is a **chat transcript**: each Send is
an independent search — `runOpsFind` appends a `me` bubble, then a pending **Find** bubble (`findBubble`) it fills
via `fillFindAnswer` with the `opsFindSummary` "Looking for:" line + the cards (`renderFindItem` → `findShipRow`
/ note row). History is kept on screen; rows still deep-link into the drawer. (A self-contained external tester,
`tools/find-chat.html`, drives the JWT-authed `POST /api-ops/find-text` instead — same server-side find.)

- **`GET /api-ops/find` (`Handlers.Find`).** A scoped `shipment_alerts` query (party / lane / commodity /
  carrier / the existing identifier field→column map, **plus** an `EXISTS dbo.job_note` branch so the "who" clue
  also matches a note's arrangement `party`/`contact`) **merged** with a `job_note` search (author / body /
  `@`-mention), deduped by `job_no`, recency-sorted, `TOP 60`. Searches **active + recently-closed** (closed gated
  to ~6 months when no date window). **Involvement ("mine") is the default** — it reuses the **worklist lens**
  (`Scope.ErpAliases` pic/created/updated + `Notes.MyNoteJobs` + `Scope.SysExprs` broadcast); a **note-only**
  query (note clues, no shipment clue) **skips that lens** so system-broadcast rows don't drown the message; an
  explicit identifier **bypasses** it. **Scope is the security boundary** — `Scope.StationClause` +
  `Scope.PairClause` exactly as the worklist, and the note search inherits it via a scoped `EXISTS` on the parent
  shipment (`job_note` has no scope columns of its own). `Scope.PairClause` took an optional column-alias arg
  (backward-compatible) so it can be aliased (`s.mode`/`s.bound`) inside that subquery.
- **`POST /api-ops/parse-find` (`Llm.cs`) — optional, OFF by default.** Returns **501** unless `Config.LlmEnabled`
  (the `llm.enabled` flag **and** an API key, env `OPS_LLM_API_KEY`). When on, it re-interprets the free text into
  the **same clue object** and the client re-runs `/api-ops/find` — the LLM **never** touches the DB or scope.
  Provider-pluggable (`llm.provider` = **claude | openai | deepseek**) via one raw-HTTP adapter (Claude = Messages
  API `output_config.format`, default `claude-haiku-4-5`; OpenAI/DeepSeek = chat-completions). Fails **open** (any
  error → `null` → client falls back to the rule parse). The client (`opsFindLlmFallback`) calls it **only** on a
  zero-result rule parse and flags the result **✨ AI-assisted**. Shared prompt/clue-schema intent mirrors
  quotation's `/api-quote/parse-shipment` so both apps parse to one contract.

> ⚠️ **Don't apply the involvement lens to a note-only query** without the broadcast-skip — `Scope.SysExprs`
> broadcasts API/EDI/QUOTATION-created rows into everyone's "mine", which silently floods a "Leo messaged me…"
> search with dozens of unrelated shipments. `noteOnly` (note clue present, no shipment clue) gates this.

### The draft-document subsystem

This is the largest feature; it is keyed by `job_no`/`doc_id`:

- **Whitelist + clamp.** `Doc-CleanFields $type $src` rebuilds incoming fields against `doc-fields.json` —
  only known codes survive, each clamped to `maxlen`; structured kinds (`table`, `riders`) rebuilt in column
  order. The server **never** trusts a raw client field.
- **Seed.** `Doc-SaSeed` (snapshot) then `Doc-ErpSeed` (bounded ERP read). The Air mappings live here — see
  [SQL-README.md §4](SQL-README.md). `Doc-CustLookup` resolves the own office via `fm3kco.site` owncode.
- **Versioning.** Every save/submit inserts an immutable `doc_version`; `Doc-Changed` (canonical JSON compare)
  drives the "no changes" guard and the staff diff.
- **Public path.** `/api-doc/*` validates the token **shape** (regex) before any SQL, caps the body, and
  returns a single generic failure message (no existence oracle).
- **My-Tasks.** `Get-DraftAlerts` surfaces `CUSTOMER_SUBMITTED`/`CUSTOMER_APPROVED` drafts; self-clearing.

### ERP document API (`erp-doc-api.ps1`)

`Invoke-ErpDocAgree` = `/booking/get` (read-merge) → `/booking/update`. `Invoke-ErpDocIssue` = per-file
`/file/upload` (documentTypeCode from `erp-api-map.json`) → `/event/update` (transportBill). `Invoke-ErpEditPush`
= the **Edit ERP data** save path (`/booking/get` existence guard → `/booking/update` of only the changed fields).
Mode-aware (`moduleTypeCode` AIR/SEA). `ErpMockMode` returns true when no `baseUrl`+token → writes `erp-mock/`.

**Routing identity is per-station, never hard-coded.** `partyGroupCode` comes from `erp-api-map.json`
(`Set-ErpApiMap` lets the admin **ERP API** tab edit it). The **`forwarderCode` / `bookingParty.forwarderPartyCode`**
(= office owncode) comes from `Resolve-ForwarderCode($station)` → `Get-StationOwnCode` (`fm3kco.site`, cached, map
fallback) — threaded through `Invoke-ErpBookingGet`, `Invoke-ErpEditPush`, and the three `Invoke-ErpFile*`
functions; `Build-ErpPatchPayload` **always** injects `forwarderPartyCode`. `Invoke-ErpEditPush` also **read-merges**
`serviceCode`/`commodity`/POL/POD from the live booking (the ERP validates POL against the job schedule).

> **Gotcha — live-call findings (baked in):** `Invoke-RestMethod` returns a JSON array as ONE object
> (assign-then-`@()`); do **not** send `carrierCode`/`vesselName` on update; the ERP **422s a wrong forwarder code**
> and **500s a missing POL** ("No such POL in job schedule") — hence per-station owncode + the schedule read-merge;
> key `/file/upload` + `/event/update` by `houseNo`+`bookingNo` (the doc guid 422s); `ErpErr` rewinds the consumed
> response stream to surface the ERP's real validation text.

> **AIR HAWB+MAWB are a PAIR on update (.NET `Erp.BuildPatchPayload`).** The ERP keys an AWB on `houseNo`+`masterNo`
> together; pushing only one (a MAWB-only edit) is read as a different job → "job duplicate". So for **AIR**, when
> either `bl_no`/`master_no` is changed, **both** `houseNo`+`masterNo` are sent — the unchanged one read-merged from
> the seeded form set (same idea as the AIR cargo-block read-merge: `quantity/…/shipMarks/goodsDescription`).

**Generate document (.NET-only — `Erp.DocGenerate` + `Handlers.ErpDocGenerate`).** A user-triggered
`/document/generate` (the drawer **Generate document** box), distinct from `DocIssue`'s optional generate
side-effect (untouched). The `(module, documentTypeCode, houseTypeCode)` combo is validated against **`DocGenMap`**
(cached over `doc_generate_map`, admin-editable via the **Generate documents** tab; `Reset()` on save). The
booking/bill key follows priority **houseBillNo → bookingNo → masterBillNo → 3rdBookingID** (a `use_master_bill`
row leads with the master bill) and **iterates the candidates, falling through on a "No corresponding" 422** to the
next — mirroring `Erp.FileEnquiry`/`FileDownload`. `includeFile=true` returns the PDF **inline** under the
top-level `file[].base64` (verified live: the ERP does **not** file it, `/file/enquiry` 422s), so the endpoint is a
**custom streaming route** in `Program.cs` (like `erp-file-download`) — `DocGenHttp` carries bytes on success, JSON
on error/mock; the client `fetch`es and triggers the download.

### Headless PDF (`Doc-RenderPdf`)

On Issue, the agreed bill is rendered to PDF by injecting `doc-fields.json` + the saved fields into an offline
HTML page (no auth/fetch — uses `BLForm.setDict`), printed by headless Edge/Chrome (`Resolve-PdfEngine`),
reusing `bl-review.css`'s `@media print`. Returns `$null` (issue proceeds) on any failure.

---

## 4. Front-end conventions (`ops.js`, `bl-form.js`)

- **Vanilla JS, no framework, no build, no package manager.** Keep it that way. `node --check` is the only
  gate.
- **`arr()` / `arrFields()`** coerce PS 5.1's 0-/1-row `ConvertTo-Json` quirk back to arrays — a `|| []` guard
  is **not** enough.
- **`cache:"no-store"`** on every fetch; responses are `no-store` (the app may run in a cross-site iframe).
- **`bl-form.js` is shared** by the staff editor and the customer page, so both always see the identical
  layout. The layout comes from `doc-fields.json` (order = layout order, `w` = grid span of 12, `multiline`,
  `mono`, structured `kind` = `table`/`riders`). HAWB has a dedicated Neutral Air Waybill layout; HBL uses the
  generic grid. `collect()`/`diff()` are layout-agnostic (they scan by `data-code`), so a custom layout never
  breaks save/diff.
- **No native dialogs** for data entry — custom in-page dialogs (no "localhost says").
- **i18n: wrap user-facing captions in `tr('English text')`** (from `i18n.js`; English source string = the key).
  Static markup uses `data-i18n` / `data-i18n-title` / `data-i18n-placeholder` / `data-i18n-aria-label`. **Do
  NOT** translate ERP/company data, free-text notes, or ISO dates. New strings must be added to every
  `lang/<code>.json`. See §8.

---

## 5. CSS conventions

`styles.css` (operator UI) and `bl-review.css` (the bill). Match the existing selectors; the bill uses
`.blf-*` / `.awb-*` classes with an outer top+left border and per-box right+bottom borders (so stacked rows
never double a line). Every print rule lives in the `@media print` block — the same CSS produces the
auto-generated PDF.

---

## 6. Data-model cheat-sheet

So your SQL is correct, read [SQL-README.md](SQL-README.md): the `erpops` tables, the **bound-aware** sea
fields (`onboard2`/`departure2`/`vessel_2`), and the verified Air field map (`to1`/`deli`/`to3` routing,
`dest_name`, `desc2` goods, `mark2` marks, `dimension`, `handling`, `t_rece_qty`, `wgt_unit`, the PPD/COLL
terms). New HTML pages need `<meta charset="utf-8">`.

Note **`job_note`** (operator notes/arrangements/reminders) is now a **SQL table**, not the old
`ops-lists/job-notes.json` file — accessed only via `Notes.cs` (`[user]` is bracketed; `mentions` is
comma-delimited; `created` is an ISO string). It carries no scope columns, so any cross-shipment read of it
**must** gate on the parent shipment's scope (see the Find note search). See [SQL-README.md §2](SQL-README.md).

Two **admin-config** tables drive the ERP-document features: **`milestone_evidence_map`** (`pic_doctype` rows →
the upload-to-clear doctypes, cached in `DoctypeMap`) and **`doc_generate_map`** (`module`, `document_type_code`,
`house_type_code`, `use_master_bill`, `invoice_required`, `active` — the Generate-document combos, cached in
`DocGenMap`). Both caches `Reset()` on any admin save/delete so edits apply with no restart.

---

## 7. Definition of done

- [ ] **Reconcile every computed light / KPI / seeded field against a direct read-only SQL query of the source
      ERP** before declaring it done. This is the house rule — the field map is the project's main unknown.
- [ ] Syntax-check: `[PSParser]::Tokenize` for `.ps1`, `node --check` for `.js`, `ConvertFrom-Json` for JSON.
- [ ] All new SQL parameterised; scope AND-ed in; bounded by `CommandTimeout`.
- [ ] No ERP write; no metadata probe on a request path; `Packet Size=512` present.
- [ ] Secrets still gitignored — `git status` clean of `ops.config*`, `users.json`, `erp-mock/`, `*.log`.
- [ ] `.ps1` ASCII-only; dates ISO; client list fields coerced with `arr()`.
- [ ] Test server-side changes on a **temp port** so a running instance is undisturbed.
- [ ] Update `CLAUDE.md` / `BLUEPRINT.md` / `PROJECT-SUMMARY.md` if a convention or capability changed.
- [ ] New UI captions wrapped in `tr()` / `data-i18n*` **and** added to every `lang/<code>.json` (§8).

---

## 8. Adding a UI language (i18n)

The localization layer is **no-build, client-side, English-source-as-key** (`i18n.js`): `tr(en)` returns the
translation of the English string, or the English itself if missing — so a partial dictionary never blanks the
UI. Only **operator-facing** pages are localized today (`index.html`, `ops.js`, `login.html`); admin / erp-edit /
doc-editor / public bl-review are still English (the framework is ready for them).

**To add a language (e.g. Spanish `es`):**

1. **Dictionary** — copy `lang/zh-Hans.json` to `lang/es.json` and translate the values (keys stay the exact
   English source strings). Keep the gettext context key form `lens<U+0004>All` as the **escaped JSON text**
   `lens0004All` — a *raw* control byte is invalid JSON (it silently fails the fetch → falls back to English).
   Validate it parses with the same key count as the others.
2. **Register it** — add one entry to `SUPPORTED` in `i18n.js` (`'es': 'Español'`). `norm()` already maps a
   browser `navigator.language` like `es-MX` to `es` by primary subtag, so auto-detect works with no further edit.
3. **Font (only if non-Latin)** — add a `html[lang="es"] body { font-family: … }` rule in `styles.css`
   (CJK languages need this; Latin ones use the default stack). JP/SC already have rules.
4. **Server allow-list** — add the code in `server/Handlers.Admin.cs` (`AdminUserUpsert`) **and** `serve-ops.ps1`
   so admins can set it as a user's profile default; add an `<option>` in the `admin-ops.html` Users form.
5. **Layout check** — European languages run ~15–30 % longer than English (CJK is *shorter*), so eyeball the
   longest captions (worklist buckets, the filter row) for overflow; let tight cells wrap/ellipsis if needed.

**Resolution order** (`i18n.js` `resolve()`): localStorage `lang` (per-device pick) → profile `ME.language` →
`navigator.language` → `en`. `setLang()` persists the pick and reloads. English needs **no** dictionary fetch
(the HTML ships English). Verify with headless Edge: `I18N.boot('es').then(...)` then read a translated node, and
confirm a missing key falls back to English.
