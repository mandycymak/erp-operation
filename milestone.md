# Milestone Alerts — What Data / Files Each Step Needs

This is the **milestone matrix** that drives the Green / Amber / Red lights and the "you're missing
something" alerts. The alert function evaluates each live shipment against the steps below and turns a
step **Amber** (70–90% of the way to its due date) then **Red** (overdue) when the data or file that
proves the step is done is still missing.

> Source of truth: `pgsops` tables `milestone_def` (the steps + timing) and `milestone_evidence_map`
> (which documents/EDI satisfy a step). Everything here is editable on the **Admin → Milestones & alerts**
> tab. Reflects the demoerp config as of 2026-06-15.

## How a step clears (stays Green)

Checked in this order — the first one that matches wins:

1. **Manual tick** — you "Tick & Confirm" it in the worklist drawer (works even with no data).
2. **ERP data** — a specific ERP field gets populated as you work the file.
3. **A file / document** — a document logged in PIC (or an EDI success), per the evidence map.
4. **Superseded** — the leg already sailed / arrived, so a pre-departure step is no longer actionable.

## When does it actually alert?

The **"Alerts now?"** column matters. Timed alerts only fire for steps anchored at **booking / ETD**
(`baseline`) or with a **fixed** day offset. Steps anchored at *ETA / ATD / delivery* are configured as
`baseline`, but the 3-year baseline table (`baseline-refresh.ps1`) **isn't built yet**, so those don't
raise a timed light today — they stay Green until superseded or ticked. Those are marked **"Not yet\*"**.

---

## 🚢 Sea — Export

| #   | Step                       | What clears it (data field, or 📄 file)                                              | Alerts now?                      |
| --- | -------------------------- | ----------------------------------------------------------------------------------- | -------------------------------- |
| M1  | Booking Confirmation       | HBL no. (`blno`) **or** PIC assigned (`picuser`) **or** 📄 **BOOKING** doc in PIC     | Yes                              |
| M1b | Space Confirmed            | Carrier on-board confirmed (`onboard`)                                               | Yes                              |
| M2  | Empty Container Release    | Cargo-ready date (`cargoready`)                                                      | Yes                              |
| M3  | Origin Pickup              | Cargo received (`cargorece`)                                                         | Yes                              |
| M4  | Warehouse Receiving        | Cargo-ready **and** cargo-received both set                                          | Yes                              |
| M5  | Customs Clearance          | Customs cleared (`customs_clearance`)                                                | Yes                              |
| M6  | Shipping Instructions (SI) | Draft/SI BL (`ts_blno`) **or** 📄 **"HBL"** in PIC                                    | Yes                              |
| M7  | Manifest Printing          | _(no auto field)_ → **manual tick**                                                 | Yes                              |
| M8a | Customs Manifest (AMS/ENS) | AMS filed (`ams_hbl`) / EDI date (`edidate`) **or** 📄 **EDI "success"** log          | Yes — **due 3 days before sailing** |
| M9  | Agent EDI                  | EDI sent (`edidate`)                                                                 | Yes                              |
| M9b | Departure (ATD)            | Actual departure (`atd_date`)                                                        | No (info)                        |
| M10 | Post-Dept. Invoicing       | 📄 **"INVOICE"** in PIC                                                               | Yes — **due 3 days after ATD**   |
| M11 | Post-Dept. Monitor         | Delivery / job complete (`goods_delivery` / `comp_date`)                             | Not yet\*                        |

## 🚢 Sea — Import

| #   | Step                 | What clears it                                                       | Alerts now?                       |
| --- | -------------------- | ------------------------------------------------------------------- | --------------------------------- |
| M1  | Factory Booking Alert | from the inbound feed / **manual tick**                            | Yes                               |
| M2  | Transit Check        | Actual arrival (`ata_date`)                                         | No (info)                         |
| M3  | Import Documentation | BL Surrendered / Telex Released                                     | Not yet\*                         |
| M4  | Arrival Notice       | A/N sent (`not1_date`) **or** 📄 **"Arrival Notice"** in PIC         | Yes — **due 3 days before ETA**   |
| M4b | Invoice from Liner   | **manual tick**                                                     | Not yet\*                         |
| M5  | Import Customs       | Cleared (`customs_clearance` / `release_date` / status Cleared)     | Not yet\*                         |
| M6  | Port/Airport Pickup  | Customer pickup (`customer_pickup`)                                 | Not yet\*                         |
| M7  | Warehouse Service    | Arrival-at-door / warehouse date (`ad_date` / `ware_date`)          | Not yet\*                         |
| M8  | Final Delivery       | Delivered (`goods_delivery` / `ad_date` / `comp_date`)              | Not yet\*                         |
| M9  | Invoice to Buyer     | **manual tick**                                                     | Yes — **due 3 days after arrival** |

## ✈ Air — Export

| #  | Step                     | What clears it                                  | Alerts now?                          |
| -- | ------------------------ | ----------------------------------------------- | ------------------------------------ |
| A1 | Booking Confirmed        | HAWB/MAWB no. **or** PIC assigned (`picuser`)   | Yes                                  |
| A2 | Flight / Space Confirmed | Flight no. (`flight1`)                          | Yes                                  |
| A3 | Customs Declaration      | Declared (`declaration=1`)                      | Yes — **due 1 day before departure** |
| A4 | AWB Issued               | MAWB **or** HAWB no.                            | Yes                                  |
| A5 | Uplift / Departure (ATD) | Actual departure (`atd_date`)                   | No (info)                            |
| A6 | Post-Departure Invoice   | **manual tick**                                 | Yes — **due 3 days after ATD**       |
| A7 | Arrival Confirmed        | Arrival (`ata_date` / `comp_date`)              | Not yet\*                            |

## ✈ Air — Import

| #  | Step               | What clears it                                                  | Alerts now?                        |
| -- | ------------------ | -------------------------------------------------------------- | ---------------------------------- |
| A1 | Pre-Alert / Booking | HAWB/MAWB no.                                                  | Yes                                |
| A2 | Flight Departed    | Departure (`atd_date`)                                         | No (info)                          |
| A3 | Arrival (ATA)      | Arrival (`ata_date`)                                           | Not yet\*                          |
| A4 | Arrival Notice     | Consignee informed (`inform_cnee`)                            | Not yet\*                          |
| A5 | Import Customs     | Declared (`declaration=1`)                                    | Not yet\*                          |
| A6 | Pickup / Delivery  | Consignee/customer pickup (`cnee_pickup` / `customer_pickup`) | Not yet\*                          |
| A7 | Invoice to Buyer   | **manual tick**                                                | Yes — **due 3 days after arrival** |

\* **Not yet** = the step is configured as `baseline` but no due date computes until `baseline-refresh.ps1`
builds the 3-year lane averages — so it won't flash Amber/Red today.

---

## 📄 The only documents / files the system actively checks for

Right now just **5 evidence rules** are configured (everything else clears from ERP data fields or a
manual tick). These document types are maintained on the **Admin → Documents** tab — each row's name
**must match the ERP Document Type code exactly** (it is sent verbatim to the ERP on upload and is the
value shown in the worklist's Upload dropdown), and you choose which milestone each one clears:

| Step                                | File / evidence it looks for       | Where    |
| ----------------------------------- | ---------------------------------- | -------- |
| Sea Export M1 — Booking Confirmation | **BOOKING** document               | PIC      |
| Sea Export M6 — Shipping Instructions | **HBL** document                 | PIC      |
| Sea Export M8a — Customs Manifest   | EDI transmission **"success"**     | EDI log  |
| Sea Export M10 — Post-Dept. Invoicing | **INVOICE** document             | PIC      |
| Sea Import M4 — Arrival Notice      | **Arrival Notice** document        | PIC      |

## In practice

- Keep the ERP fields above filled as you work each shipment.
- To clear a document alert, open a shipment's **ERP files** panel in the worklist drawer, pick the
  document type, and **Upload** the file — it goes straight to the ERP and the milestone turns green.
- Steps with no data source (Manifest printing, the various invoices) you close with a **manual tick**.
- You can also correct bad source data through the **"Edit ERP data"** pop-out in the worklist drawer.
- **Admin → Documents** maintains the document types (kept in sync with the ERP) and which milestone each
  clears; **Admin → Milestones & alerts** edits the steps and their timing.
