# pgs-operation — Project Summary

Status snapshot of the Control Tower build. The authoritative design is **`BLUEPRINT.md`**; this file records
**what is actually built and proven** against real ERP data, plus the findings that shaped it. Read this first
when resuming. Operator-memory notes also live under `.claude/projects/.../memory/` (local + network DB setup).

## Status: working app — arrival-driven worklist, filters, multi-station, cross-station feed; Sea **and** Air

A clickable, end-to-end worklist app runs against real data on two test environments. The scheduled
`listener-engine.ps1` is still **deferred** — `seed-alerts.ps1` stands in for it (one-shot batch evaluator/upsert)
so the UI and Tick-&-Confirm loop can be exercised now.

**Latest session (2026-06-11b — demoerp connected + Sea worklist fixed — RESUME HERE).** Brought up the **demoerp**
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
**`pgsops`**, 23 `pgs*` stations. Data is a **frozen snapshot**: `shipment_alerts.sort_key` spans **2020-11-18 →
2023-05-12**, all 2,181 rows **Sea** (1,752 Export / 429 Import); **zero Air rows** (Air ingest still broken —
`awbhead` missing `comp_date`). Done this session:

- **Auth bootstrapped.** Created gitignored `users.json` with the first admin **`mandy`** (password stored only in the gitignored `users.json`; role admin,
  `admin:true`, empty stations/access = unrestricted). App is now in **real-auth mode** (login page on, sessions).
  Passwords are `SHA256("salt:password")`; new users get hashed automatically via `admin-ops.html`.
- **Fixed worklist 500 (schema drift).** The pulled `serve-ops.ps1` worklist SELECT referenced 6 columns missing from
  the live `pgsops.shipment_alerts` (`commodity, sono, route_summary, available_date, eta_delivery, goods_delivery`).
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

**Prior milestone (12-station seed + Air UX):** all **12 fm3k stations** seeded into `pgsops_net`; station picker +
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
station ERP DBs (READ-ONLY)                                  pgsops (operational state, writable)
  Sea: blhead / blcont / PIC      --- ops-eval.ps1 ------>    shipment_alerts, milestone_def (mode Sea|Air),
  Air: awbhead                       (mode-aware evaluator)   milestone_evidence_map, …
        |  (seed-alerts.ps1 -Mode Sea|Air = listener stand-in)        |  serve-ops.ps1 (HttpListener + JSON API)
        |                                                             v
        '------- READ ONLY, never written -------          browser (index.html / ops.js)  — reads only pgsops
```

**Two-server mode (added):** the read-only ERP and the writable `pgsops` may live on **different** servers.
Config gains optional `opsServer`/`opsAuth`/`opsUser`/`opsPassword` (fall back to the source connection when
absent — single-server configs unchanged). All scripts route `master`+ops-DB to the ops server, everything else
to the source. Used so the network ERP (read-only login) is read remotely while `pgsops` is created locally.

## Two test environments

| Env | Source ERP | Data | opsDb | Port | Notes |
|---|---|---|---|---|---|
| **Local** | `fibsbkk` on `localhost\SQLEXPRESS` (Win auth) | **frozen 2021** snapshot; as-of `2021-11-27` | `pgsops` (local) | 8078 | Only `fibsbkk` has the real 381-col schema; `fibsdemo_*` are stripped. Sea/BKK. Milestone fields empty → all-Red. |
| **Network** | `fm3k*` on `192.168.5.2` (SQL login `dashboard`, read-only) | **LIVE to today**; as-of = today | `pgsops_net` (local, two-server) | 8079 | **12 stations seeded** (YVR SHA HAM HKG JKT NRT JNB SIN BKK TPE LAX SGN), 618 rows. 414–420-col schemas vary by office → `Filter-Cols`. Login can't `CREATE DATABASE` → two-server mode. |
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
   excluded). `carr` (carrier code) is empty in both → use vessel/voyage (sea) and airline+`flight1` (air).
4. **Carrier code & ETA are sparse/empty** in these copies; consignee/shipper **names** are ~100%. Container data
   (`blcont`) is rich for sea FCL; air uses pieces/weight (`t_book_qty`/`t_book_wgt`).
5. **Cross-station factory-booking** (advice, not yet built): at booking time there's no HBL/MBL, only the
   destination **station/site code** stamped on the origin's booking (`dest`/`agn2_code`). The plan: each origin
   publishes its outbound bookings into a shared `pgsops` feed keyed by destination code; the import station reads
   only `pgsops` (no cross-DB query on the request path). Needs a station-code identity directory.

## What's built

| File | Role | State |
|---|---|---|
| `setup-ops.ps1` | Creates `pgsops` + base tables + `company_dim`; in-place ALTERs add worklist enrichment columns (consignee/shipper name+contact, vessel_voyage, container_summary/count, total_weight/cbm, arrival_state, sort_key) **plus the display/filter set: house_bill, master_bill, incoterm, cust_ref, container_no, liner_so, cargo_ready, shipper_code, consignee_code, ctrl_code, pol, pod** and `milestone_def.mode` | ✅ idempotent, two-server |
| `seed-milestone-config.ps1` | Config-as-data: **37** `milestone_def` rows — Sea (23, Export+Import) + **Air (14)** with `mode` — + starter evidence map | ✅ |
| `ops-eval.ps1` | Pure evaluator: `New-ShipContext` (sea) + **`New-AirContext`** (air); `Eval-Milestones` filters defs by bound **and mode**; planned-due anchor is mode-aware | ✅ |
| `eval-shipment.ps1` | Read-only one-shot card for one shipment (two-server aware) | ✅ |
| `seed-alerts.ps1` | Listener stand-in. **`-Mode Sea|Air`**: reads `blhead`/`blcont` or `awbhead`, batches PIC + consignee/shipper contacts, computes arrival bucket + cargo profile + conveyance, pulls **house/master bill, incoterm, container/liner-SO, cargo-ready, role codes + POL/POD**, resolves company **names** via a single chunked `custsub.code2` clustered seek (never the heavy party views) → `company_dim`, resolves **vessel code→name** via a chunked `veslmstr.code` seek (bound-aware: sea Export reads `vessel_2/voyage_2`, Import `vessel_1/voyage_1`), upserts `shipment_alerts`. **`Filter-Cols`** intersects wanted columns with the station's `INFORMATION_SCHEMA` so schema-variant offices (e.g. HAM `blhead` lacks `picuser`) seed without failing | ✅ |
| `serve-ops.ps1` | Web service: worklist (arrival-grouped, `&station=` filter), shipment detail, notes/arrangements/reminders, **enriched My-Tasks**, manual milestone-close, **`/api-ops/companies` (name type-ahead), `/api-ops/ports` (POL/POD lists)**. Config payload returns `stationCode` + `stations[]`. **Real auth** (`users.json` present → login/sessions/scope; absent → open/demo mode) + admin-gated `/api-ops/admin/*`: **`users`** CRUD and **`milestones`** CRUD (`GET/POST /admin/milestones` + `/admin/milestone-delete`, MERGE on `milestone_def`, validated, `admin-audit.log`). Config/JSON read via `[IO.File]::ReadAllText` (UTF-8 safe). Reads only `pgsops` | ✅ |
| `admin-ops.html` | Admin-only page, **two tabs**: **Users** (table + add/edit, **live search** over login/name/email/station/team/ERP-name for ~500 users) and **Milestones & alerts** (table + editor: name/mode/bound/seq/phase/active + **alert timing** baseline/fixed/none — what drives operator Green/Amber/Red). Non-admins 403 | ✅ |
| `login.html` / `users.example.json` | Login page + user-record template (logins are gitignored `users.json`) | ✅ |
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

**Cross-station inbound booking feed (key finding 5) — built (publish/subscribe fan-in).** An origin station's
scheduled `publish-bookings.ps1` writes its cross-station bookings into the central `pgsops.inbound_booking_feed`
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
- **10 stale `HK01` rows** in `pgsops_net.shipment_alerts` — harmless; a `DELETE … WHERE station='HK01'` was blocked by the
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
.\setup-ops.ps1                                                            # create pgsops (idempotent)
.\seed-milestone-config.ps1
.\seed-alerts.ps1 -Station fibsbkk -StationCode BKK -AsOf 2021-11-27 -Limit 120
.\serve-ops.ps1                                                            # http://localhost:8078/

# --- NETWORK (live fm3k*, two-server: read network ERP, write local pgsops_net) ---
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

## Constraints (do not violate)

- **`Packet Size=512`** on every SQL connection string (VPN MTU).
- HttpListener server is **single-threaded**; UI/request paths read only the small `pgsops` tables, never the ERP.
  All heavy ERP joins (containers, contacts) happen in `seed-alerts` off the request path.
- **Source ERP DBs are READ-ONLY** — all writes go to `pgsops`/`pgsops_net` or the gitignored JSON note store.
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
