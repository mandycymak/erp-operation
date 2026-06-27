# Book Now load test

Concurrency / throughput test for the **Book Now -> ERP** flow: fire N concurrent `POST /api-ops/book-now`, watch
the `BookingPusher` drain them to the ERP, and verify they land **with distinct booking numbers and no deadlocks**.

- **Script:** [`loadtest-booknow.ps1`](loadtest-booknow.ps1)
- **Results:** every run writes a markdown summary to [`results/`](results/) — **commit it** so other developers can
  see what was found.

## How to run

From the repo root, with the server running and the **VPN up**:

```powershell
# full burst (writes a result file under results\):
.\tools\loadtest\loadtest-booknow.ps1 -BaseUrl http://localhost:8079 -Email <login> -Password <pwd> -Count 100 -Note "OPS_BOOKING_WORKERS=5"

# quick harness check (no ERP-write wait):
.\tools\loadtest\loadtest-booknow.ps1 -BaseUrl http://localhost:8079 -Email <login> -Password <pwd> -Count 5 -SkipDrain
```

Key params: `-Count` (concurrent bookings), `-Concurrency` (max in-flight registrations), `-Mode Sea|Air`,
`-Note` (recorded in the result file — put the server's `OPS_BOOKING_WORKERS` here), `-ConfigPath` (defaults to
`ops.config.demoerp.json` at the repo root, used only to poll the ops DB for the drain).

## Prerequisites

- **Point it at demoerp, never a customer** — it writes **real bookings** to the target ERP (there is no
  booking-delete API, so the records persist).
- **`erpApi` mock must be OFF** (Admin -> ERP API) or it writes to `erp-mock\` instead of the ERP (the script warns).
- A **Control Tower login** with a station in scope (its `primary_station` receives the bookings).

## How to read a result

The result file reports three phases:
1. **Registration burst** - did all N clicks succeed, and how fast (this is the user-facing latency).
2. **ERP drain** - throughput (bookings/min) and how long to clear the queue.
3. **Verdict** - the safety check: **distinct booking numbers == confirmed count**, **0 deadlocks**, **0 terminal
   failures**. Any duplicate number or deadlock means the ERP is **not concurrency-safe** at that worker count.

## Known finding (2026-06-27)

demoerp's booking creation is **not concurrency-safe**: with `OPS_BOOKING_WORKERS=5`, a 100-booking burst produced
**duplicate booking numbers + SQL deadlocks** (the ERP's booking-number generation races under parallel
`/booking/update`). See [`results/booknow-2026-06-27-summary.md`](results/booknow-2026-06-27-summary.md).
**Go-live setting: `OPS_BOOKING_WORKERS=1` (serial).** Faster confirmation requires an ERP-side fix from Swivel.
