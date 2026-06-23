# Control Tower — SQL & Data-Model Reference

**Audience:** developers and SQL analysts who need to understand the `erpops` operational schema, how it is
populated from the source ERP, and the **field map** from logical document boxes to real ERP `table.column`.

This is the companion to [DEVELOPER-GUIDE.md](DEVELOPER-GUIDE.md). It documents two things: (1) the small,
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
| **Party contact name / email** (shipper, consignee) | blank-seeded (no verified ERP column) — editable | — | `…PartyContactName` / `…PartyContactEmail` |
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
> [DEVELOPER-GUIDE.md §4](DEVELOPER-GUIDE.md).

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
