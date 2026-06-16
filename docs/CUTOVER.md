# Cutover: retiring `serve-ops.ps1` for the .NET server

The strangler migration is complete: the .NET app (`server/`) serves **every** `/api-ops/*` + `/api-doc/*`
endpoint and `/bl-review/*` that `serve-ops.ps1` did (44/44 routes — verified by route inventory). This runbook
is the final flip: prove parity, click-test, point the L!NK iframe at the new host, retire the PowerShell
server. It is done **in the deployment environment** (the .NET app needs the VPN'd SQL + the source ERP; the
L!NK URL flip is a config change), not from a dev box.

The off-request-path PowerShell jobs (`seed-alerts.ps1`, `publish-bookings.ps1`, `seed-station-map.ps1`,
`seed-ports.ps1`, `seed-milestone-config.ps1`, `register-ops-tasks.ps1`) **stay** under Task Scheduler — they
only write `pgsops`, so they coexist with the new server unchanged. Only the **web tier** (`serve-ops.ps1`) is
retired.

## What's already verified (so you're not starting cold)
- **Route coverage: 100%** — every `serve-ops.ps1` route has a .NET counterpart (`/api-ops/*`, `/api-doc/*`,
  `/bl-review/*`).
- **Reads reconcile to source SQL** — worklist row count == direct SQL; `erp-edit` seed reconciled field-by-field
  against live `fm3khkg` (shipper/consignee/POL/POD/etd/eta/commodity/vessel/owncode).
- **ERP writes round-trip live** — `erp-edit-save` did a real `booking/get`→`booking/update` on demoerp with
  read-merge preserving POL/POD/service and **no duplicate created**; upload-to-clear flipped a milestone.
- **Draft-doc lifecycle end-to-end** — create (live ERP seed) → send → public view/submit/approve → agree →
  issue (with headless-Edge PDF) → amend; attachments up/download; full event-log trail.
- **Concurrency isolation PASSED** — 60 concurrent disjoint-scope requests, 0 cross-scope bleed (the structural
  reason for the migration).

## 1. Run the side-by-side parity diff
Stand both servers up against the **same `pgsops` DB** in the **same identity mode**, then diff every read.

```powershell
# legacy (open mode = no users.json in its root; identity via X-Ops-User)
.\serve-ops.ps1 -Port 8090
# new .NET (open mode too); from server\
$env:OPS_HTTP_PORT=5079; dotnet run -c Release      # or start-dotnet.bat with OPS_HTTP_PORT=5079
# diff (pick a real active job for the by-job endpoints)
.\tools\parity-check.ps1 -Ps http://localhost:8090 -Net http://localhost:5079 -Job HKG-S-R23474
```
`parity-check.ps1` compares **modulo array-coercion** (PS 5.1 renders a 0-row list as `{}` and a 1-row list as a
bare object; the .NET server emits real arrays — the client's `arr()` coerces both, so these are not real
differences) and ignores volatile timestamps. **Expect every endpoint `MATCH`.** Investigate any `DIFF` (it
prints the JSON path of the first divergence) before flipping.

> To diff under real scope instead of open mode: run both in auth mode (same `users.json`), log in as the same
> user on each, and pass `-Cookie "ops_sid=<sid>"`. The comparison logic is identical.

## 2. Click-test every screen on the .NET port
Browse the .NET server and exercise each surface (these have automated coverage above, but click them once on the
real deployment):
- **Worklist** — filters (station/mode/bound), the light counts, sorting.
- **Drawer** — open a shipment, **Tick & Confirm** a milestone (and reopen), notes + `@`-mention, the ERP-detail
  deep-dive.
- **ERP-edit** ("Edit ERP data") — open the grid, change a master code, save; confirm the change lands in the
  ERP (`erp_edit_log` row, and a `booking/get` shows it).
- **ERP files** — list, upload-to-clear a milestone, download.
- **Draft doc** — create → send (copy the `/bl-review/<token>` link) → open it (incognito, no login) → submit an
  edit → back in staff, resend → approve → agree → issue (the agreed PDF renders) → amend.
- **Manager weekly plan / detention-demurrage listing / my-tasks inbox** badge.
- **Admin** (admin-ops.html) — users, milestone-def, evidence-map, ERP-settings editors.
- **SWIVEL L!NK iframe** — boot the app inside the L!NK frame; confirm sign-in and that the `ops_sid` cookie is
  `SameSite=None; Secure; Partitioned`.

## 3. Stand the .NET app up on IIS/HTTPS
Follow `docs/IIS-DEPLOY.md`: publish, copy `server\publish\` to the IIS site, set `OPS_ROOT` + `OPS_HTTPS=1`
(+ `OPS_IFRAME=1` for the frame), bind 443 with the TLS cert, `iisreset`. Verify `https://<host>/` loads and
`https://<host>/ops.config.json` → **404** (secret blocked).

## 4. Phased route flip (optional, lowest-risk)
If your front proxy supports per-route rules, flip endpoints to .NET incrementally and keep the rest on
`serve-ops.ps1`, verifying each against §1 before flipping the next. When all routes are on .NET, proceed to §5.
(If you're confident from §1–§2, flip the whole site at once.)

## 5. Point the SWIVEL L!NK iframe at the new host
Update the L!NK profile's embedded app URL to the new HTTPS host/path. Confirm the app boots inside the frame
and sign-in works (the `Partitioned` cookie is required for the cross-site frame).

## 6. Set `publicBaseUrl`
In the deployed `ops.config.json`, set `publicBaseUrl` to the internet-facing HTTPS host so `doc-send` builds
correct `<publicBaseUrl>/bl-review/<token>` customer links. Send one test draft and open the link externally.

## 7. Retire `serve-ops.ps1`
- Stop the PowerShell HttpListener service / scheduled task that launched `serve-ops.ps1`.
- Leave the file in the repo for reference during the bedding-in period; remove it once the .NET app has run
  clean for a cycle.
- **Keep the off-path PowerShell jobs running** (they are not part of the web tier).

## Rollback
The cutover is just a URL/route flip — `serve-ops.ps1` reads the same `pgsops` DB and is unchanged. If anything
misbehaves, point the proxy / L!NK URL back at the PowerShell server; no data migration is involved (both serve
the same database).

## Security note (do during, or before, cutover)
`serve-ops.ps1` serves its static root **unguarded** — `/ops.config.json`, `/users.json`, `/erp-api-map.json`,
`/erp-edit-fields.json` are reachable on the PowerShell port. The .NET server **blocks** these (static-secret
guard). While both run in parallel, make sure the PowerShell port is not internet-exposed, or patch its static
handler. After cutover the exposure is closed.
