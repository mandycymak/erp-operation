# Control Tower — SQL & Data-Model Reference

**Audience:** developers and SQL analysts who need to understand the `erpops` operational schema, how it is
populated from the source ERP, and the **field map** from logical document boxes to real ERP `table.column`.

This is the companion to [6-DEVELOPER-GUIDE.md](6-DEVELOPER-GUIDE.md). It documents two things: (1) the small,
writable `erpops` state database the app reads, and (2) the **read-only** source ERP columns the listener /
seeder / draft-document engine pull from. The field map is the project's main unknown — every mapping below
was **verified by a direct SQL query** against a live station before it was trusted.

> 🔑 **The source ERP databases are READ-ONLY.** All writes go to `erpops` (or the gitignored JSON note
> store). Never `INSERT`/`UPDATE`/`ALTER` an ERP table.

> 🔑 **`Packet Size=512` on every connection string.** The VPN's small MTU black-holes default 8 KB TDS
> packets ("semaphore timeout"). Mandatory on every connection to the ERP **and** the ops DB.

---

## 1. The two databases

| | Source ERP (per station) | `erpops` (operational state) |
|---|---|---|
| Examples | `fm3khkg`, `fm3ksin`, … / `blhead`, `awbhead` | `erpops`, `erpops_net`, `demoerp` |
| Access | **read-only** | read + write |
| Collation | Chinese_HK | Latin1 |
| Reached on | listener / seeder / draft-creation only — **never** a UI request path | every UI request |
| Created by | the ERP vendor | `setup-ops.ps1` (idempotent) |

> ⚠️ **Cross-DB collation.** The ops DB is Latin1, the station DBs are Chinese_HK. Any text join **across
> databases** needs `COLLATE DATABASE_DEFAULT`. Within `erpops` (all tables same DB) no collation clause is
> needed.

**Two-server mode.** The read-only ERP and the writable `erpops` may live on different servers (the network
ERP login cannot `CREATE DATABASE`, so `erpops` is created locally on `localhost\SQLEXPRESS`). Config keys
`opsServer`/`opsAuth`/`opsUser`/`opsPassword` route the `master` + ops DB to the ops server; everything else
goes to the source. Single-server configs omit them and are unchanged.

> ℹ️ **Not in the DB.** Logins + row-level scope live in **`users.json`** (gitignored), not SQL — including the
> per-user UI **`language`** preference (`"" | en | zh-Hans | ja`). The translation dictionaries are flat
> `lang/<code>.json` files, not tables. So i18n adds **no** `erpops` schema; the stored shipment data and note
> text are never translated.

---

## 2. `erpops` tables (created by `setup-ops.ps1`, idempotent)

### Operational core

| Table | Grain | Purpose |
|---|---|---|
| `shipment_alerts` | one row per **active conveyance/shipment** (keyed `job_no`) | the worklist source — traffic-light status, arrival bucket, party names, cargo profile, bills, route. **The UI reads only this.** |
| `milestone_def` | one row per milestone (keyed `mode`/`bound`/`milestone_code`) | config-as-data: the milestone matrix (Sea Export/Import + Air), each with mode/bound/seq/phase, active flag, and **alert timing** (`baseline` / fixed offset / `none`). |
| `milestone_evidence_map` | one row per milestone→evidence rule | maps a milestone to the ERP/PIC/EDI evidence (`documentTypeCode`) that auto-closes it. Its distinct `documentTypeCode` values are also the **ERP-files upload** picker list (the API returns them as `uploadDoctypes`; the subset that would clear a milestone on a given shipment is `clearableDoctypes`). Maintained on the admin **Documents** tab. |
| `milestone_baselines` | one row per lane/milestone | 3-year average durations that back the `baseline` alert timing (built by `baseline-refresh.ps1` — **not yet built**; `baseline` falls back to fixed/none until then). |
| `milestone_event_log` | append-only | every milestone state change (audit). |
| `detention_watch` | one row per at-risk container | detention/demurrage listing source. |

### Reference / display dimensions

| Table | Purpose |
|---|---|
| `company_dim` | resolved company **names** by code (filled by a single chunked `custsub.code2` seek — never the heavy party views). Backs the name type-ahead. |
| `port_dim` | POL/POD list for the filter dropdowns. |

### Cross-station inbound booking feed

| Table | Purpose |
|---|---|
| `station_dim` | the station identity directory (seeded from `asw_station_list`). |
| `station_route_map` | origin→destination routing rules, built from the **intercompany convention** `fm3kco.site.owncode`↔`location` (e.g. `S0001`→`HKG`). |
| `inbound_booking_feed` | the central fan-in: each origin publishes its cross-station bookings here tagged with `dest_station`; the importer reads only `dest_station=stationCode`. |
| `feed_watermark` | per-station incremental publish cursor. |

### Draft document review (HBL / HAWB customer-agreement workflow)

| Table | Grain | Purpose |
|---|---|---|
| `doc_draft` | one live document per (`job_no` × `doc_type`) | the workflow head: status, current version, customer, `erp_doc_no`, `amend_count`. Unique index `UX_doc_job_type` on (`job_no`,`doc_type`). |
| `doc_version` | immutable snapshot per version | `fields` = flat JSON `{field_code: value}`; `side` = staff/customer; `comment`. |
| `doc_review_token` | one per customer link | SHA-256 **hash at rest**, expiry, revocation, view counters. Raw token never stored. |
| `doc_event_log` | append-only | full audit (created/viewed/submitted/approved/agreed/issued/…), with IP and `detail` JSON. |
| `doc_attachment` | one per uploaded file | rider files (pdf/images, ≤5 MB, magic-byte checked), `varbinary`. |

> ℹ️ **Status flow (`doc_draft.status`):**
> `DRAFT → SENT → CUSTOMER_SUBMITTED → DRAFT (resend v+1)` … `→ CUSTOMER_APPROVED → AGREED → ISSUED`;
> `ISSUED → AMEND_DRAFT → … → ISSUED`. The My-Tasks inbox surfaces `CUSTOMER_SUBMITTED` / `CUSTOMER_APPROVED`
> (self-clearing once the operator acts).

### Edit ERP data (master-code + field editor)

Staff-internal editor (`erp-edit.html` / `erp-edit.js`, drawer panel **"Edit ERP data"** + a ✎ pen shortcut on
the drawer's first row) to fix wrong source data — a `DUMMY` party code, a `ZZZ` incoterm/port code, wrong
container booking qty, addresses, dates, carrier — and push **only the changed fields** to Swivel
`/booking/update`. Dictionary `erp-edit-fields.json`; endpoints `/api-ops/erp-edit` (seed current value +
resolved master name), `/api-ops/erp-master` (live master type-ahead), `/api-ops/erp-edit-save`
(diff → minimal `/booking/update` → audit). Payload built by `Build-ErpPatchPayload` (party-prefixed write keys
nest in `bookingParty`; `flexData.<sub>` keys nest in `flexData` for the IATA leg fields; container table →
`bookingContainers`), pushed by `Invoke-ErpEditPush` (same read-merge-write existence guard + best-effort/strict
as the agree flow).

> ℹ️ **Detail-line seeding.** Several fields live on the **line** table, not the header, and are seeded
> server-side from there (`Handle-ErpEditSeed`, keyed `blh = ref`, first line): **Air** marks/description from
> `awbdetl.mark2`/`desc2`; **Sea** commodity / container-size counts / marks / description from `blitem`, and the
> liner agent from `blcont.lagent`. This mirrors the draft-seed pattern.

| Table | Grain | Purpose |
|---|---|---|
| `erp_edit_log` | append-only, keyed by `job_no` | audit of every correction: `actor`, `ip`, `changed_json` = `[{field, writeKey, before, after}]`, `erp_status` (saved/rejected/error/mock), `erp_steps`, `erp_error`. |

**Field map verified on live `fm3khkg` (2026-06-13).** read column → master lookup → `/booking/update` write key:

| Field | Read — Sea (`blhead`/`blcont`/`blitem`) · Air (`awbhead`/`awbdetl`) | Master lookup | Write key |
|---|---|---|---|
| Shipper / consignee / notify code | `shpr_code` / `cgne_code` / `not1_code` (n8) | `custsub.code2 → doc_e_name` | `shipperPartyCode` / `consigneePartyCode` / `notifyPartyPartyCode` |
| Party name / address / phone / tax | `*_name` / `*_add1..5` / `sphone`·`cphone` / `*_txncode` | — | `…PartyName` / `…PartyAddress` / `…PartyContactPhone` / `…PartyTaxCode` |
| **Party contact name / email** (shipper, consignee) | **`scontact`/`semail`** (shipper) · **`ccontact`/`cemail`** (consignee) — on both `awbhead`/`blhead` (verified 2026-06-26; previously blank-seeded, so a saved value never displayed) | — | `…PartyContactName` / `…PartyContactEmail` |
| **HAWB / MAWB no.** (Air, editable) | `awbhead.hawb` / `awbhead.mawb` | — | `houseNo` / `masterNo` (verified writable 2026-06-26; a **consol-shared MAWB** is rejected — `Duplicated MAWB#`) |
| Delivery agent code (on HBL/HAWB) | `agn2_code` | `custsub` | `agentPartyCode` |
| **Liner agent** code (internal) | **Sea `blcont.lagent`** (party on the container line) → **`custsub`** · **Air `lin1_code`** → `linermstr` | `custsub` / `linermstr` | `linerAgentPartyCode` |
| **Carrier** code / name (best-effort) | **Sea `iliner`** · **Air `rout_by_1`** (`carr` is usually blank) | — | `carrierCode` / `carrierName` |
| Controlling customer code (internal) | `rcustomer` | `custsub` | `controllingCustomerPartyCode` |
| Incoterm | `routing` (free text, e.g. `FOB`) | **none** — fixed Incoterms-2020 list | `incoTermsCode` |
| Place of receipt / POL / POD | `rece` / `pol` / `pod` (Air `pod` = leg-1 discharge = `to1`) | `portmstr.code → port_ldes1` | `placeOfReceiptCode` / `portOfLoadingCode` / `portOfDischargeCode` |
| **Final destination** | `dest`; **Sea falls back to `deli`** (Place of Delivery) when `dest` is blank | `portmstr` | `finalDestinationCode` |
| Service type | `service` | `servmstr.service → desc1` | `serviceCode` |
| **Commodity** | **Sea `blitem.commodity`** (no commodity column on `blhead`) · **Air `awbhead.commodity`** (ntext) | — | `commodity` (maxlen 21) |
> ℹ️ **Worklist/Find commodity chip** (`seed-alerts.ps1`): **Sea** reads **`blitem.commodity`** (the operator-picked code, e.g. `FOOTWEAR`), falling back to the `good_desc1` description only when blank; **Air** reads **`awbdetl.good_desc2`** (unchanged). Earlier the Sea seed read `good_desc1` only, so the Sea commodity chip was blank wherever the description was empty — fixed 2026-06-23; a Sea reseed populates it.
| **Cargo qty / gross / chargeable / cbm / wt unit** | **Air** `t_rece_qty` / `ttl_gwt` / `ttl_cwt` / `t_rece_cbm` · **Sea** `t_book_*` totals, **wt unit defaults `KGS`** | — | `quantity` / `grossWeight` / `chargeableWeight` / `cbm` / `weightUnit` |
| **Marks / description** | **Sea `blitem.mark2`(+`mark3`) / `good_desc1`→`desc2`(+`desc3`)** · **Air `awbdetl.mark2` / `desc2`** | — | `shipMarks` / `goodsDescription` |
| **Air IATA flight legs** | leg 1 `flight1`+`to1` · leg 2 `flight2`+`deli` · leg 3 `flight3`+`to3` | `portmstr` (leg ports) | `voyageFlightNumber`+`portOfDischargeCode`; legs 2-3 → **`flexData.{2nd,3rd}LegFlightNumber` / `…PortOfDischargeCode`** |
| **Container-size counts** (Sea) | `blitem.c20` / `c40` / `cq` (HQ) / `c45` (Other) | — | `container20` / `container40` / `containerHQ` / `containerOthers` |
| Container particulars (Sea) | `blcont` (`container`,`cont_type`,`seal`,`load_qty`; link `blh = blhead.ref`) | — | `bookingContainers[]` (`containerNo`,`containerTypeCode`,`sealNo`,`quantity`) |

> All write keys **verified against the Swivel OpenAPI spec** (`3rd-erpapi.json` — `NewBooking.bookingParty`,
> top-level, and the `flexData` IATA-leg object); each is tunable in `erp-edit-fields.json` (`writeKey`) with no
> code change. A correction is only sent when the operator actually edits that field.
>
> **⚠️ AIR detail-line writes need the FULL cargo block (verified live 2026-06-26).** The ERP persists the air
> detail line (`awbdetl`: `mark2`/`desc2`/`good_desc2`/`rece_cbm`) **only** when `/booking/update` carries the WHOLE
> cargo block together — `quantity`+`quantityUnit`+`grossWeight`+`weightUnit`+`cbm`+`shipMarks`+`goodsDescription`. A
> minimal patch that changes only marks/desc/commodity/cbm is **silently dropped** (the ERP echoes the values back
> unchanged). So for AIR, `Erp.EditPush` **and** `ErpDoc.DocAgree` **read-merge the cargo block from the live
> `/booking/get`** (preserving JSON number types via `DeepClone`) whenever a detail field is edited. The **editor
> seeds air `cbm` from `awbdetl.rece_cbm`** (the header `t_rece_cbm` is always 0 for air). Gated on `module=="AIR"`
> (Sea writes its detail via `blitem`/`bookingContainers`). **Fill-from-master** uses `GET /api-ops/erp-master-detail`
> (full `custsub` party: `doc_e_name`/`doc_e_add1..5`/`contact`/`email1`/`phone`).
>
> **Routing identity (verified live 2026-06-15):** every `/booking/update` carries **`partyGroupCode`** (company
> code, e.g. `DEV`) and **`bookingParty.forwarderPartyCode`** = the office **owncode** (`fm3kco.site` dbname→owncode:
> HKG=`S0001`, SHA=`S0002`, SIN=`S0005`, BKK=`S0009`), resolved per station by `Resolve-ForwarderCode` — never a
> single hard-coded code (the ERP **422s a wrong forwarder code**). The push also **read-merges**
> `serviceCode`/`commodity`/POL/POD code+name from the live `/booking/get`, or the ERP **500s** "No such POL in job
> schedule". With the old payload-invariant rejection now gone, **`bookingUpdateMode` is `strict`** (a real
> rejection aborts and is captured in `erp_edit_log`). **Carrier still pushes best-effort** (the carrier master
> rejects raw ERP codes). **Trucker / customs broker / warehouse are dropped** — the booking API has no field for
> them; **No. of originals and PIC *name* have no write key** (PIC via `picId`/`picEmail`). The four
> `custsub`/`portmstr`/`servmstr`/`linermstr` masters exist in **both** the station DB (`fm3k<code>`) and corporate
> `fm3kco`; the editor reads the **station** DB.

### Operator notes, arrangements & reminders (`job_note`)

Per-shipment notes, arrangement records, and reminders — **migrated from the old shared JSON file
`ops-lists/job-notes.json` into SQL** (2026-06-22) so they're queryable like every other entity (the
natural-language **Find** tab searches them under role scope). `server/Notes.cs` is the only accessor; its
`NoteRec` shape and method signatures are unchanged, so My-Tasks, the worklist chat-dot, and note-add/note-done
were untouched by the move.

| Table | Grain | Purpose |
|---|---|---|
| `job_note` | one row per note / arrangement / reminder (keyed `id`, GUID) | `job_no` (the shipment), `[user]` = author (**bracketed — reserved word**), `kind` (`note`/`bypass`/`reopen`/…), `note` text, **`mentions`** = comma-delimited `@`-usernames (clean `(','+mentions+',') LIKE '%,me,%'` for mention search), `status` (`open`/`done`) + `done_by`/`done_at`, the arrangement fields `arr_type`/**`party`**/`contact`/`arr_status`, `remind_on` (yyyy-mm-dd), `silent` (bit, nullable), `created` (ISO-8601 string — preserves the file ordering). Indexes on `job_no`, `[user]`, `created`. |

> ℹ️ **One-time import.** `setup-ops.ps1` §2.9 creates the table and, **only when it's empty**, imports any
> existing `ops-lists/job-notes.json` (the file is kept as a backup, not deleted). A fresh install simply starts
> with an empty table.
>
> ℹ️ **Find's note search is scope-safe.** `job_note` has no scope columns of its own; the Find endpoint
> (`/api-ops/find`) gates every note hit with `EXISTS (SELECT 1 FROM dbo.shipment_alerts s WHERE s.job_no =
> n.job_no <Scope.StationClause + Scope.PairClause>)`, so a note is only visible when its **parent shipment** is
> in the caller's station/mode scope. The arrangement `party`/`contact` columns are also what lets Find match a
> free-text contact like *"Rainbow Transportation"* to the shipment it was recorded on.

### Operations & governance (`health_check_log`)

| Table | Grain | Purpose |
|---|---|---|
| `health_check_log` | append-only, one row per watchdog check per run | written by `ops-healthcheck.ps1` (every ~25 min): `check_name` (`app`/`db`/`tasks`/`feed`/`backup`/`storage:db`/`storage:disk`/`erp-vpn`/`purge`), `status` (`ok`/`fail`), `detail`, `metric_num` (a numeric value for the storage/age trend), `occurred_at`. The in-app **Audit & Health** board reads the *latest row per `check_name`* for current state and `MAX(occurred_at WHERE status='ok')` for "last OK" — a `fail` then later `ok` makes a **recovery** visible. Indexed on `(check_name, occurred_at)`. |

> ℹ️ **The other audit trails are not new tables** — they already existed: `milestone_event_log`, `doc_event_log`,
> `erp_edit_log` (all append-only, who/when, `erp_edit_log` carries before→after per field), plus the file logs
> `admin-audit.log` (change + **login/failed-login** audit) and `ops-error.log` (every server-side exception). The
> **Change log** admin tab reads all of these, bounded by a date range + a row cap.

### Logins, roles & scope (`app_user` + `app_user_scope`)

| Table | Grain | Purpose |
|---|---|---|
| `app_user` | one row per user (PK `username`) | credentials + role + flags: `email` (the sign-in / L!NK federation key), `[role]` (admin/manager/operator), `is_admin`, `salt` + `pwd_hash` (`SHA256('salt:pwd')` lowercase hex), `auth_provider` (local/swivel/both), `language`, `primary_station`. |
| `app_user_scope` | one row per (user, dim, code) | the row-level scope arrays, normalized: `dim` ∈ `team` / `station` / `access` / `erpuser`. |

> Logins **used to live in the gitignored `users.json`**; they now live in SQL (ported from the sibling
> erp-dashboard), so the customer maintains them in MSSQL and no credential file sits on the box. On first start the
> .NET server (`server/Auth.cs` `SeedOrImport`) seeds a **default admin / admin123** when `app_user` is empty, or
> imports a legacy `users.json` once (the file is then kept only as a backup). Because a user always exists after
> bootstrap, the old open/auto-admin mode never triggers in production. Admin **Users** CRUD writes these tables
> (whole-store rewrite in a transaction). `HashPwd` is unchanged from the file era, so imported hashes verify with no
> lockout (a PBKDF2 upgrade is a possible later hardening pass).

### Delta refresh + new-booking alerts (`alert_watermark`, `booking_alert`)

| Table | Grain | Purpose |
|---|---|---|
| `alert_watermark` | per (station, mode) | the high-water `MAX(crtdate/upddate)` consumed by `seed-alerts.ps1 -Delta`, so each worklist refresh pulls only shipments created OR edited since the last run. This is what makes a tight refresh cadence (Air ~5 min, Sea ~15 min) cheap on the read-only ERP. Mirrors `feed_watermark` (which is keyed by the publishing origin). |
| `booking_alert` | one per (station, mode, erp_ref) | one row per newly-received EXPORT booking detected by `watch-bookings.ps1`, deduped by the ERP ref so a booking is alerted once. Holds the resolved factory(shipper) contact/email, lane, `src_created`, and `status` (pending/notified/skipped/failed) + `channel`. Doubles as the audit/queue for the factory notification. |

> **Why delta, not just "run more often":** the old full-fetch pulled the newest-N by *create* date, so an ETA/vessel edit on an older shipment was never refreshed. The delta filter `(crtdate>@since OR upddate>@since)` catches **new AND edited** rows, oldest-change first so a TOP cap never skips one. Measured on a live station: a delta query is ~10-50 ms (full active set is ~2,900 rows / 6 ms), so 30 stations x 2 modes every few minutes is light. Run the **full backfill once** (`seed-data.bat` / `seed-alerts` without `-Delta`) to populate history; the scheduled `-Delta` tasks then keep it fresh.

### Runtime settings (`app_setting`)

| Table | Grain | Purpose |
|---|---|---|
| `app_setting` | key/value (PK `name`) | runtime-editable settings that **override `ops.config.json`** so a customer-site admin can correct the **ERP connection** from the admin **ERP API** tab without editing a file or restarting: `erpBaseUrl`, `erpToken` (the bearer token — stored here so no secret sits in a file on the box; the DB is the access boundary), `erpMock`. A key absent/blank falls back to the config value. Read via `server/Settings.cs` (snapshot loaded at startup, reloaded on save). The token is **never returned** by the API — the admin GET reports only whether one is set. |

> Real ERP calls happen only when an effective **Base URL** and **token** are set **and** `erpMock` is off
> (`Erp.MockMode()` reads these via `Settings`); otherwise calls are mocked. The admin tab shows a **LIVE / MOCK**
> status so you can see which mode you're in.

### ERP API call log (`erp_api_log`)

| Table | Grain | Purpose |
|---|---|---|
| `erp_api_log` | append-only, one row per Swivel ERP API call (read **and** write) | written at the single `Erp.Call` choke point (`server/Erp.cs`): `endpoint` (`/booking/update`, `/file/upload`, `/booking/get`, …), `direction` (read/write), `ok`, `http_status`, `duration_ms`, `error` (the ERP's own validation message), `actor`/`station`/`[ref]` (attribution), `corr_id` (links a multi-call operation — a doc agree = `/booking/get` + `/booking/update`), and bounded `req_summary`/`resp_summary`. Surfaced read-only via **Change log → ERP API calls** (`/api-ops/admin/erp-api`, date-range + cap + `failures only`). Answers "which ERP API errored and why" in one place. Indexed on `(occurred_at)` and `(corr_id)`. (Mock-mode calls are not logged — they never reach the ERP. No automatic retry yet.) |

### Data retention / growth (`purge-ops.ps1`)

The schema is meant to hold only **active** operational state, but the aging was not enforced until
`purge-ops.ps1` (weekly `Ops Purge`). It uses the timestamp/status columns already in the schema, all horizons from
the config `retention` block:

| Table | Aged by | Default horizon |
|---|---|---|
| `shipment_alerts` | `updated_at` stale → `job_status='closed'`; then closed/void deleted | `staleDays 21` → `retainClosedDays 180` (≥ Find's recently-closed window) |
| `inbound_booking_feed` | `updated_at` stale → deleted | `retainFeedDays 120` |
| `milestone_event_log` / `doc_event_log` / `erp_edit_log` / `erp_api_log` | `occurred_at` older than horizon | `auditRetainMonths 24` |
| `booking_alert` | `detected_at` older than horizon | `auditRetainMonths 24` |
| `health_check_log` | `occurred_at` older than horizon | `healthRetainDays 90` |
| `doc_attachment` | **only soft-deleted** (`deleted=1`) blobs by `uploaded_at` | `attachPurgeDays 60` (live attachments are never auto-deleted) |

> The on-disk logs (`admin-audit.log`, `ops-error.log`, `ops-health.log`, `ops-backup.log`) are **rotated** by the
> same job (over `logRotateMb`, keeping `logKeep` archives). The **Storage & growth** admin tab + the watchdog
> thresholds (`dbSizeWarnMb`/`diskFreeWarnMb`) tell you if growth is getting out of hand.

---

## 3. ERP source field map — Sea (`blhead` + `blcont` + `blitem`)

`blhead` is the sea master (one row per shipment). Operator shipments are `bound IN ('O','I')`; the listener
keys on the **stable** SO number (`sono`/`booking`) at booking stage when `blno` is still empty.

| Logical field | ERP column | Notes |
|---|---|---|
| House bill | `blhead.blno` | the doc the customer received |
| ETD (sea) | `blhead.departure2` | **mandatory** — `departure1` is the dead `_1` leg |
| On-board (bound-aware) | Export `onboard2` / Import `onboard1` | `onboard1` is 0% populated for Export — the bound-mapping bug fix |
| Vessel / voyage | Export `vessel_2/voyage_2`, Import `vessel_1/voyage_1` | resolved code→name via a chunked `veslmstr.code` seek |
| Shipper / consignee / notify | `shpr_name`+`shpr_add1..5`, `cgne_*`, `not1_*` | denormalized printed blocks |
| Delivery agent | `agnt_name`+`agnt_add1..5`, else `custsub` by `agn2_code` | |
| Forwarding agent (own office) | `fm3kco.site` dbname→`owncode` → `custsub`, else latest `blhead` whose `agn2` is the own office | the S-codes have no reachable custsub master |
| POL / POD / delivery / final dest | `pol_name` / `pod_name` / `deli_name` / `dest_name` | |
| Freight terms | `frt_terms` (`PP`→PREPAID else COLLECT) | presentation-only on the bill |
| Originals | `no_orig`; **guardrail:** `0` when `telex_rel` is set | |
| Marks / description | `blitem.mark2(+mark3)` (ntext) / `good_desc1`→`desc2(+desc3)` | `good_desc1` is often blank |
| Containers | `blcont` (container/seal/type/qty/unit/kgs/cbm) | |
| **Carrier** (Edit ERP data) | `blhead.iliner` | `carr`/`carr_name` are usually blank |
| **Liner agent** (Edit ERP data) | `blcont.lagent` → company name via `custsub` | party code on the container line (e.g. `A0002`→APL CO PTE LTD) |
| **Final destination** (Edit ERP data) | `blhead.dest`, **else `blhead.deli`** (Place of Delivery) when blank | |
| **Commodity** (Edit ERP data) | `blitem.commodity` | there is **no** commodity column on `blhead` |
| **Container-size counts** (Edit ERP data) | `blitem.c20` / `c40` / `cq` (HQ) / `c45` (Other) | the booking-stage size summary (distinct from `blcont` particulars) |

---

## 4. ERP source field map — Air (`awbhead` + `awbdetl`)

`awbhead` is the air master (**465 columns**). Operator shipments are `awb_type IN ('H','S')` (H=house,
S=direct; M=consol master, B=booking pipeline excluded). The line items are in `awbdetl` (FK `blh = awbhead.ref`).

> ⚠️ **`carr` (carrier code) is usually blank** in these copies. On the bill, derive the carrier from the
> **alpha prefix of the flight number** (`SQ7861` → `SQ`); the **Edit ERP data** editor reads the verified
> **`rout_by_1`** (routed-by-first-carrier code, e.g. `CX`) instead.

### `awbhead` (header) — verified mappings

| AWB box | ERP column | Notes |
|---|---|---|
| Airport of Departure | `pol_name` | |
| Airport of Destination | `dest_name` | the **final** destination, **not** `pod_name` (discharge) |
| Routing To1 / To2 / To3 | `to1` / `deli` / `to3` (codes) | **`deli` holds the middle leg** (e.g. `CHI`), not a delivery point |
| By first carrier / onward | `rout_by_1` (verified) or alpha-prefix of `flight1` / `flight2` / `flight3` | |
| Flight / date (1–3) | `flight1..3` + `f_date1..3` | one line per flight |
| **IATA flight legs** (Edit ERP data) | leg 1 `flight1`+`to1` (=`pod`); leg 2 `flight2`+`deli`; leg 3 `flight3`+`to3` | legs 2-3 push via **`flexData.{2nd,3rd}LegFlightNumber` / `…PortOfDischargeCode`** |
| Currency (freight) | `currency` | |
| CHGS Code | `frt_terms` | the freight term `PP`/`CC` |
| WT/VAL · Other (PPD/COLL X) | `frt_terms` → WT/VAL ; `oth_terms` → Other | `X` in PPD when `PP`, COLL when `CC` |
| Declared Value for Carriage / Customs | `v_carriage` / `v_customs` | text (e.g. `N.V.D.` / `AS PER INV.`) |
| Amount of Insurance | `v_insurance` | blank/`0` prints `NIL` |
| Agent's IATA Code | `iatacode` | |
| No. of Pieces | `t_book_qty` → `t_rece_qty` | `t_book_qty` is often blank |
| Gross / chargeable weight | `ttl_gwt` / `ttl_cwt` | `t_book_wgt` and the per-leg `f*_wgt` are usually blank |
| kg/lb | `wgt_unit` initial | `KGS`→`K`, `LBS`→`L` |
| Handling Information | `handling` (ntext) → `special_remark` | |
| Notify | `not1_name`+`not1_add1..5` | own box (under Consignee) |
| Issuing Carrier's Agent | own office (`fm3kco.site` owncode → `custsub`) | **not** `agnt_*` (that's the destination agent) |
| Accounting Information | `frt_terms` text + Destination Agent (`agnt_*`) | |
| Executed at (place) | `issu_at` | |

### `awbdetl` (line items) — verified mappings

| AWB box | ERP column | Notes |
|---|---|---|
| Marks and Numbers | `mark2` (ntext) | per item, joined |
| Nature & Quantity of Goods | `desc2` (ntext) | the **full** goods text; `good_desc2` is the short commodity summary; `commodity` is the operator-picked code (often blank) |
| Dimensions (L×W×H×Qty) | `dimension` (ntext) | e.g. `10x30x50cm(9);20x30x40cm(1)`; suppressed when `awbhead.not_show_dim` is set |

> ⚠️ **Catalog-metadata is catastrophically slow for the read-only login on wide tables.**
> `INFORMATION_SCHEMA.COLUMNS` / `sys.columns` for `awbhead` (465 cols) runs **40–70 s** (per-column
> permission checks) and can drop the connection, while the keyed data SELECT is ~0.3 s. The seeder
> (`Get-ErpCols`) therefore **does not probe column metadata** — it trusts the curated want-list and lets a
> genuinely-missing column degrade gracefully. Never put a metadata query on a request path. See
> [6-DEVELOPER-GUIDE.md §4](6-DEVELOPER-GUIDE.md).

---

## 4b. ERP field coverage — go-live reconciliation (the "what's missing" check)

The pull/push field maps above are verified, but a few fields are **legitimately blank in the source ERP** or are
**not echoed back** by the write API. Reconcile these against live SQL **per pilot station** before go-live (house
rule: verify computed fields against the source ERP), and accept the residual gaps knowingly:

| Area | Field | Known gap / what to check |
|---|---|---|
| Pull (Sea) | commodity | reads `blitem.commodity` (not the description column); blank for bookings with no commodity code — expected, not a bug. |
| Pull (Air) | flight no. | a consolidated export house has an empty `flight1`; the seeder falls back to the **master** row's flight by MAWB. Confirm export flights populate. |
| Pull (Air) | carrier | `awbhead.carr` is always empty on this ERP; the airline lives in `rout_by_1`. |
| Push | every `writeKey` in `erp-edit-fields.json` | confirm each maps to a field `/booking/update` accepts; the read-merge guard (`Erp.cs EditPush`) re-sends the NewBooking-required keys (serviceCode/commodity/POL/POD, + carrier for Sea container edits) so editing one field never blanks the rest. |
| Push | `linerAgentPartyCode` | the ERP stores it but **does not echo it back** in `/booking/get` or the BL columns; the editor overlays the last value from `erp_edit_log` and labels it "ERP read-back pending". |

> After go-live, the **Change log → ERP API calls** tab (`erp_api_log`) shows every push and its result, so any
> field the ERP silently rejects surfaces there as a failed `/booking/update` with the ERP's own message.

---

## 5. Common query patterns

```sql
-- Active worklist for one station (the only table the UI reads)
SELECT job_no, consignee_name, vessel_voyage, arrival_state, sort_key
FROM   dbo.shipment_alerts
WHERE  station = @station
ORDER BY sort_key;

-- Keyed ERP read (fast — index seek; bounded by CommandTimeout)
SELECT TOP 1 <curated-want-list>
FROM   dbo.awbhead WHERE ref = @ref;          -- never SELECT * on a 465-col table

-- Inbound feed for the importing station (indexed seek, never a cross-DB join)
SELECT * FROM dbo.inbound_booking_feed WHERE dest_station = @stationCode;

-- Drafts awaiting an operator (My-Tasks)
SELECT d.doc_id, d.job_no, d.status
FROM   dbo.doc_draft d
WHERE  d.status IN ('CUSTOMER_SUBMITTED','CUSTOMER_APPROVED');
```

---

## 6. Schema changes

`setup-ops.ps1` is **idempotent**: it uses the `IF OBJECT_ID(...) IS NULL CREATE` / `IF COL_LENGTH(...) IS
NULL ALTER` idiom (lifted from the dashboard's `setup-warehouse.ps1`). To add a column, add the guarded
`ALTER` to `setup-ops.ps1` and re-run it — existing data and tables are untouched. Confirm with
`INFORMATION_SCHEMA` and re-run to prove idempotency.

> ℹ️ When you add a draft-document field, you only edit **`doc-fields.json`** (the dictionary) — the server
> uses it as the edit whitelist and the client renders from it. No schema change is needed for document
> fields; they live as JSON in `doc_version.fields`.
