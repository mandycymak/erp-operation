# Control Tower — Business User Guide

**Audience:** operations staff, branch/regional managers, and customer-service who **use** the Control Tower
to keep every live shipment on schedule and to drive the House BL / Air Waybill agreement with customers. No
technical knowledge needed.

This guide explains **what every screen and number means**, **how it is calculated** (so you can trust it),
and — most importantly — **what to do when you see it** (the "CTA" = call to action).

Open it at **http://localhost:8079/** (demo) and sign in.

---

## 1. The big picture — what the Control Tower answers

> *"What must I do **today** to keep each live shipment on schedule, and where is cash leaking?"*

This is an **operational** tool, not an analytics dashboard (that is its sibling, erp-dashboard). It looks at
**active shipments only** — never history — and turns each one into a **traffic light** against a configurable
**milestone matrix**: what should have happened by now, what has, and what is overdue. It also runs the
**draft document workflow** that gets a customer to agree the House BL / HAWB before you issue it to the ERP.

A background listener reads the station ERP databases, scores each milestone, and stores only the small
**active** state the screen needs. The screen never queries the ERP directly, so it stays fast.

---

## 2. The worklist — reading the traffic lights

The worklist is **arrival-driven and grouped by conveyance** — one card per **vessel/voyage** (sea) or
**airline+flight** (air), not one per shipment. Each conveyance gets **one** derived status:

| Light | Meaning | CTA |
|---|---|---|
| 🟢 **Green** | on track — milestones met or not yet due | nothing now; keep watching |
| 🟡 **Amber** | a milestone is due soon (inside its alert window) | prepare the next step (docs, booking, customs) |
| 🔴 **Red** | a milestone is **overdue** | act today — this is where delay and cost build up |

> **Business logic.** A milestone closes in priority order: **(1)** real ERP data → **(2)** PIC/EDI evidence
> → **(3)** the planned due-window (baseline or fixed offset) → **(4)** manual **Tick & Confirm**. Sparse
> data is handled by design — an operator can always close a step manually.

**Buckets.** Import groups into **Arrived / Arriving / Planning**; Export into **No-space /
Customs-window / Cargo-pending / On-track**. Groups are collapsible (collapse-all is available), sorted
**ETA-first**, falling back to time-in-transit.

**CTA:** Work the **Red** groups top-down. The reds that survive on old shipments are usually the **cash-leak
items** — overdue invoicing, delivery, detention/demurrage.

---

## 3. The cards, field by field

A card identifies the shipment at a glance so near-identical arrivals don't get confused:

- **Consignee / shipper name** and the **cargo profile** — sea FCL (`2×40HC`), LCL (weight + CBM), or **air
  (`N pcs · kg`)**.
- **Origin-office house bill** — the document the customer actually received (shown for import, not the
  internal job number).
- **Container / liner-SO** — to tell two boxes on the same vessel apart.
- **Incoterm** — who is responsible for delivery.
- **Customer ref / PO** — the customer's own reference.
- **Arrival chip**, **R/A severity**, and a **notes flag** (💬) when someone has left a note.
- A 🆕 **NEW** chip on rows created in the last 7 days; a quiet 🔄 marker when a milestone was just updated.

---

## 4. Filters & multi-station

The filter bar narrows the worklist to what you care about:

- **Station picker** — focus one office (e.g. `SHA`). The list of stations comes from the config.
- **🚢 Sea / ✈ Air** and **Import / Export** toggles.
- **Date window** — defaults to **this week's work**: a row shows when its movement date, its next due date,
  or its created date falls in the window, **plus** anything overdue up to 30 days. Use **All dates** to see
  history. (The 30-day bound matters — without it, long-dead "zombie" jobs never closed in the ERP would
  drown the week view.)
- **Company name** — a type-ahead that matches a company in **any** role (shipper, consignee, agent, or
  controlling customer). It searches resolved names, never the 300k-row master.
- **POL / POD** — surface, e.g., all China-origin shipments first.

**CTA:** Start your day on **This week**, your station, your mode. Switch to **All dates** only to chase old
reds.

---

## 5. The shipment drawer — milestones, arrangements, reminders

Click a card to open the drawer:

- **Milestones** — the full checklist with each light and why it is where it is. A 🔄 marker names the
  milestone that just changed.
- **🧭 Route & ERP detail** — the live leg-by-leg route (POL → transit(s) → DEST) with flights/dates, pulled
  fresh from the ERP on **🔄 Refresh from ERP**. (The "snapshot" line is the last seeded copy.)
- **Arrangements** — who to contact (consignee/shipper with `tel:`/`mailto:` from the ERP), plus your own
  **Trucker / Broker / Warehouse / Customer** tasks with status. Stored as notes — no ERP write.
- **🔔 Remind-me** — set a due date; overdue/today reminders are highlighted and counted in your badge.
- **ERP files** — the documents the ERP already holds for this shipment (with **Download**), and an **upload
  box** to send a document straight to the ERP. Pick the document type, choose a PDF/PNG/JPEG (≤5 MB), **Upload**.
  The box is **always available** (for Sea and Air, whether or not files already exist). Types marked with a
  **`*`** ("`* clears alert`") will also turn a milestone **green** when uploaded — that's the fast way to clear
  an overdue document alert. (The document types come from the admin **Documents** tab; keep them matched to the
  ERP.)

---

## 6. Tick & Confirm

When a step is done but the ERP/EDI hasn't recorded it yet, **Tick & Confirm** flips the milestone to done,
threads a note, and is **un-tickable**. Use it so the worklist reflects reality and the light goes green.

> **Caveat:** Tick & Confirm is an operator override — it never writes to the ERP. It records *your*
> confirmation in the ops state only.

---

## 7. My Tasks — your inbox

The **My Tasks** panel (badge in the header) collects everything waiting on you:

- **📄 Draft reviews** — a customer has **replied with changes (and a message)** or **approved** one of your
  drafts. Shown first because it's the most actionable; click to open the shipment and its draft panel. The
  item **clears itself** once you save/agree/issue.
- **🔔 Reminders from others** — @-mentions colleagues raised for you.
- **📌 My follow-ups** — reminders you set, with overdue/today highlighting.

**CTA:** Clear **Draft reviews** first — a waiting customer reply or approval is blocking an issue.

---

## 8. Inbound bookings (pre-arrival)

The **📥 Inbound bookings** panel (Import view) shows shipments **another station has booked to you** before
any bill exists — led by the consignee, with cargo-ready / ETD dates and the source station. No station ever
queries another station's ERP; each origin publishes its cross-station bookings into a shared feed and you
read only the rows addressed to you.

**CTA:** **Assign** an inbound booking to a colleague — it threads a task into their My-Tasks inbox so the
pre-arrival prep starts before the cargo lands.

---

## 9. Draft House BL / Air Waybill — the customer-agreement workflow

This is how you get a customer to **agree** the bill before it is issued, and then push the agreed result
back to the ERP.

**The lifecycle:**

1. **Create draft** — from the shipment's **📄 Draft review** panel. The bill is seeded from the shipment
   snapshot **and** a bounded read of the ERP (parties, routing, charges, marks, goods, dimensions, …). The
   Air Waybill renders in the **IATA Neutral Air Waybill** layout; the ocean bill as a House B/L.
2. **Send the customer a link** — a **tokenized link** (no login, expires in 14 days, revoked on resend/issue).
   The customer **edits the bill on screen** and **submits changes with a message**, or **approves**.
3. **Review the diff** — you see a field-by-field **was → now** of what the customer changed, and their
   message. Iterate versions until both sides agree.
4. **Agree → Issue** — the two buttons below.

> ℹ️ **The dynamic Marks ↔ Nature divider (Air).** In the lower goods block, drag the divider to give Marks
> more width when marks are heavy, or let the goods description take the middle space when marks are light.
> The split is saved with the document and prints exactly as positioned.

### The two buttons — which does what

| Button | Appears when | What it does in the ERP |
|---|---|---|
| **Agree – save data to ERP** | the customer has approved | **Updates the DATA only** — `/booking/update` (the agreed parties, marks/goods, ports, vessel/flight, …). |
| **Issue official document (ERP)** | after Agree | **Uploads the FILE + stamps the EVENT** — `/file/upload` (the agreed PDF, filed as **BL_REVIEW**) **and** `/event/update` (**Transport Bill Confirm**). |

So: **Agree** saves the data; **Issue** uploads the document and confirms the event. The order is enforced —
you must Agree before Issue becomes available.

> ℹ️ **The PDF is auto-generated.** On Issue, the agreed bill is rendered to PDF automatically and uploaded as
> the BL_REVIEW attachment — you do **not** have to print and attach it. (A file picker remains only if you
> want to upload your own PDF instead.)

> ⚠️ **After Issue, edits require an Amendment** (`amend_count`, flagged as a fee). The customer link is
> revoked on issue.

**CTA:** When a **📄 Draft review** appears in My-Tasks, open it, review the diff, **Agree**, then **Issue**.
Confirm in the ERP backend that the **Transport Bill Confirm** event and the **BL_REVIEW** attachment landed.

---

## 10. Edit ERP data — fixing bad source data

Operators routinely spot **wrong data in the ERP** they can't fix from the ERP UI — a `DUMMY` party code, a
`ZZZ`/`ZZZZZ` incoterm or port code, a wrong address, date, carrier, or container count. These silently corrupt
reports downstream. **Edit ERP data** lets you correct them at source.

**How to open it:** in the shipment drawer, click the **✎ pen** on the top line (next to ETD/ETA/ATD) or the
**Edit ERP data** button. It opens in its own tab, laid out like the bill (Sea House B/L grid / Air Neutral Air
Waybill), seeded with the **current** ERP values.

**What you can fix:** the party boxes (shipper / consignee / notify / delivery agent — name, address, phone,
tax, and now **contact name + email**); each master **code** is a chip in the box caption — click **`…`** to
search the master for the correct code, or type it. Plus incoterm, the routing ports, **carrier**, service,
dates, cargo (qty / weight / CBM / **marks** / **description**), the container list, and — for **Air** — the
**Flights / IATA legs** (flight 1/2/3 and their destinations) shown compactly under Job No. **Sea** shows the
familiar Place of Receipt | Port of Loading | Port of Discharge | Final Destination row and the
20'/40'/HQ/Other container counts.

**How it saves:** **Save changes to ERP** pushes **only the fields you actually changed** back to the ERP (the
right company + office identity are added automatically for your station), and records a full before→after audit.
Nothing else is touched. The save is **live and confirmed** — a real ERP rejection now stops the save and shows
you the reason.

> ⚠️ **A few fields can't be pushed** (the ERP booking has no field for them): **trucker, customs broker,
> warehouse**, the **No. of originals**, and the PIC *name* (correct the PIC via its ID/email instead). The
> **carrier still saves "best-effort"** (the ERP rejects raw carrier codes) — if rejected you'll see the reason and
> it's logged. Everything else saves normally.

**CTA:** When you see a `DUMMY`/`ZZZ` code or any wrong value on a card or in the drawer, open **Edit ERP data**,
fix it, and **Save changes to ERP** — don't let bad source data flow into the reports.

---

## 11. Day-to-day playbook (quick CTAs)

- **Start of day:** This-week / your station / your mode → work **Red** groups first.
- **My Tasks badge lit:** clear **Draft reviews**, then reminders.
- **A draft says "customer replied":** review the diff and message → Agree → Issue.
- **An inbound booking arrives:** Assign it to start pre-arrival prep.
- **A step done but light still amber/red:** **Tick & Confirm** it — or, if a **document** is the missing
  evidence, upload it in the drawer's **ERP files** box (a `*` type clears the alert on upload).
- **You spot a DUMMY/ZZZ code or wrong source data:** open **Edit ERP data** (✎), fix it, Save to ERP.
- **Old reds under All-dates:** chase overdue invoicing / delivery / detention — that's the cash leak.

---

## 12. Good to know

- **Language.** The screen can be shown in **English, 中文 (Simplified Chinese), or 日本語 (Japanese)** — use the
  **language picker** in the top bar (next to the theme button). Your admin can set your **default** language on
  your profile, and you can switch any time on your own device; the choice sticks. Only the **captions** change —
  shipment data and the bills stay in English (the working language of the documents), so you always see the real
  values. Don't worry about losing anything: English is one click away.
- **Signing in is by email** (your work email + password). If your company uses **SWIVEL L!NK**, open the Control
  Tower from L!NK and you're signed in automatically — same account, matched on your email; no separate password.
- **Dates are always ISO** `yyyy-mm-dd` — display, input, and storage. Type dates in that format.
- **The screen reads only the small operational state**, never the live ERP, so it is fast even over the VPN.
  Heavy ERP work (routing, contacts, the draft seed) happens off the request path.
- **An "as-of" testing clock** may be set so a frozen data snapshot behaves like a live day; when set, the app
  treats that date as "today" for all date logic.
- **Admin** sees every shipment; operators see their stations/modes (row-level scope). The teammate lens
  narrows the worklist to one person.
