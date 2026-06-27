# Book Now load test - 2026-06-27 (demoerp)

Validation of the Book Now -> ERP flow under concurrency, against **demoerp** (real ERP writes, mock OFF), with the
parallel `BookingPusher` enabled at `OPS_BOOKING_WORKERS=5`. Login: support / Leo (HKG).

## Run A - Count 20
- Registration: **20/20 ok, 0 failed**.
- ERP drain: all **20 confirmed**, **distinct booking numbers** (`HK012606016`-`035`), **0 failures**.
- Verdict: clean at this small size (collisions are probabilistic - 20 did not trigger one).

## Run B - Count 100  (the decisive run)
- Registration: **100/100 ok, 0 failed**; latency p50 5.6s / p95 9.4s / max 10.6s under the 100-concurrent burst.
- ERP drain (5 workers): 95 done in ~50s, then a long retry tail; final **99 done, 0 terminal-failed, 1 straggler**.
- **Deadlocks:** demoerp returned `(500) ... Transaction was deadlocked on lock resources` for a wave of calls
  (~28 retries at peak) - recovered by the retry/backoff.
- **DUPLICATE BOOKING NUMBERS (the key failure):** 99 confirmed but only **95 distinct** -> 4 numbers each assigned
  to two different bookings:
  - `HK012606083` <- HKGS2606270092, HKGS2606270093
  - `HK012606105` <- HKGS2606270119, HKGS2606270120
  - `HK012606110` <- HKGS2606270095, HKGS2606270099
  - `HK012606117` <- HKGS2606270110, HKGS2606270111

## Conclusion
- **Our app handles 100 concurrent Book Now clicks** cleanly (100/100 registered instantly).
- **demoerp's booking creation is NOT concurrency-safe**: its booking-number generation races under parallel
  `/booking/update`, producing duplicate numbers + DB deadlocks. This is an **ERP-side (Swivel) defect**; the same
  `fm3k*` codebase is used in production, so assume it applies there too.
- **Go-live: keep `OPS_BOOKING_WORKERS = 1` (serial).** Serial means the ERP only ever sees one create at a time, so
  no race / no duplicates / no deadlocks. More workers makes it worse, not faster.
- **Real fix (for Swivel):** make booking-number allocation atomic (sequence/`UPDATE ... OUTPUT` under lock), add a
  UNIQUE constraint on the booking number, and make the create transaction deadlock-safe.

## Notes
- ~120 real test bookings were created in demoerp during this session (persist - no delete API).
- The `support`/Leo Control Tower login was created for the test (kept).
