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
| **Single-threaded server** | One `HttpListener` request at a time. Bound every query with `CommandTimeout`; the UI reads only small `erpops` tables, never the ERP on a request path. |
| **Secrets are gitignored** (`ops.config*.json`, `users.json`, `roles.json`, `ops-lists/`, `*.log`, `erp-mock/`) | Credentials / the ERP token / access policy. Commit only `*.example.json`. **Check `git status` before every commit.** |
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
| `seed-alerts.ps1` | the listener stand-in (`-Mode Sea\|Air`): reads `blhead`/`awbhead`, batches contacts, computes arrival/cargo/conveyance, upserts `shipment_alerts` |
| `eval-shipment.ps1` | read-only one-shot card for one shipment (diagnostic) |
| `seed-station-map.ps1` / `publish-bookings.ps1` | the cross-station inbound feed (identity directory + publisher) |
| `register-ops-tasks.ps1` | Task Scheduler registration |
| **`server/`** | **the .NET web tier (current)** — `Program.cs` (routing, no-store/CORS, static-secret guard, `dbGate`), `Auth.cs`, `Config.cs`, `Sql.cs`, `Filter.cs`, and `Handlers.*.cs` (one area per file: Worklist/Shipment/**Find**/Notes/Tasks/Inbound/Erp*/Doc/Admin/Misc). `Notes.cs` backs the SQL `job_note` store; **`Llm.cs`** is the optional, flag-gated Find fallback adapter. `dotnet publish -c Release` to deploy |
| `serve-ops.ps1` | the **legacy** web service (rollback) — same routes/contract as `server/`; keep in parity when a shared contract changes |
| **`i18n.js`** | the client localization layer — `tr(en, ctx?)`, `applyDom()`, `boot()`, `setLang()`, the `SUPPORTED` language list |
| **`lang/<code>.json`** | UI translation dictionaries (English source string = key). `lang/zh-Hans.json`, `lang/ja.json` |
| `erp-doc-api.ps1` | the Swivel 3rd-party ERP API client (agree / issue: booking/update, file/upload, event/update; `Build-ErpPatchPayload` / `Invoke-ErpEditPush` for the Edit-ERP-data push) |
| `erp-edit.html` / `erp-edit.js` / `erp-edit-fields.json` | **Edit ERP data** editor (HBL/AWB-grid layout) + its field dictionary (`writeKey` per field) |
| `index.html` / `ops.js` / `styles.css` | the operator UI |
| `admin-ops.html` / `login.html` | admin (users + milestones) and login |
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
