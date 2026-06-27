# Stage 2 — Deploy an update (existing site)

For pushing **new code and/or new tables/columns** to a customer that is **already running**. The web tier is
**compiled** (.NET), so an update = **publish + recycle the app pool** (not a `git pull`); the client
`.html/.js/.css` are static (browser reload only).

> ⛔ **Do NOT run the first-install scripts on a live site.** `first-install\setup-database.bat` and
> `first-install\deploy-local-iis-demoerp.ps1` are the [Stage 1](2-SETUP-NEW-CUSTOMER.md) path — they recreate the pool/env and,
> with `OPS_ALLOW_SEED=1`, re-seed the default admin. Updates never need them.

> 🧭 **Patch one tenant first, watch it, then the rest.**

---

## The one-command routine update (recommended)

Run **`update-customer.bat`** on the server. Set `ROOT` / `CONFIG` / `POOL` at the top of the bat (or as env
vars). It runs only the **safe, additive** steps and self-verifies:

1. app offline (`app_offline.htm`) →
2. `setup-ops.ps1` — **additive** schema migration (adds any new tables/columns; **never** overwrites
   users / roles / `app_setting` / data) →
3. `seed-milestone-config.ps1` — **insert-missing-only** (preserves admin-edited milestones; `-Force` resets to
   defaults) →
4. `dotnet publish -c Release` in place + recycle the pool →
5. `verify-customer.ps1` — prints the resolved `Server` / `Database` + **user / table / milestone / shipment counts**.

```cmd
cd "<OPS_ROOT>"
update-customer.bat
```

**Read the verify line.** If it shows `app_user: 0 users` it stops with a red *"pointed at the WRONG/FRESH
database"* warning — the app's `OPS_CONFIG` / `OPS_ROOT` are off, **not** data loss. Fix the env vars and recycle;
do **not** re-seed. After every update, confirm your real users still appear in **Admin → Users**.

> **If the update added a new worklist *scan column***, run `seed-data.bat` afterward to backfill old rows (kept
> separate because it re-pulls operational data from the ERP).

---

## Why users can "disappear" after a deploy (and why they can't now)

The connection string is assembled at startup from `OPS_CONFIG` / `OPS_ROOT`. A redeploy that **loses those env
vars** or lands in a **fresh folder** points the app at a different/empty DB; the old behaviour then silently
re-seeded `admin/admin123`, making the customer's real users look "lost". Two guards prevent this now:

- **`OPS_ALLOW_SEED`** (off by default) makes an empty `app_user` **fail loudly** with a wrong-DB error instead of
  re-seeding. Only set it for a deliberate first install.
- The first startup log line **`[Config] ops DB target: Server=…; Database=…`** shows exactly which DB opened —
  check it after any deploy.

So the cause is environment (where the app points), never the store: logins/roles/scope live in SQL
(`dbo.app_user` + `dbo.app_user_scope`), and `setup-ops.ps1` is idempotent (`IF OBJECT_ID … IS NULL CREATE`) and
never drops or overwrites.

---

## Environment variables carry the config — keep them on the app pool

`dotnet publish` **regenerates `web.config`**, so settings written into `web.config` are lost on the next publish.
Set `OPS_ROOT` / `OPS_CONFIG` / `OPS_HTTPS` / … on the **app pool** (they persist across publishes). See
[2-SETUP-NEW-CUSTOMER.md §Environment variables](2-SETUP-NEW-CUSTOMER.md#environment-variables) for the list and
the `appcmd` command.

---

## Manual redeploy / rollback

When you want explicit control (or to keep the previous build for instant rollback):

1. **Build box:** `dotnet publish -c Release -o publish_new` — a **NEW** folder; keep the running `publish` for rollback.
2. **Server:** `"offline" > publish\app_offline.htm` (the app releases `Ops.dll`) → swap `publish_new` → `publish`
   (or repoint the site physical path) → delete `app_offline.htm` → `Restart-WebAppPool <pool>`.
3. **Smoke test:** `/api-ops/health` → `200` → login → one worklist read → reconcile one milestone against an ERP
   SQL read (house rule).
4. **Rollback:** repoint the site to the previous `publish` folder + recycle. Keep the last good publish around.

---

## Rollback to the legacy PowerShell server (last resort)

The legacy `serve-ops.ps1` reads the **same `erpops` DB** and is kept in-repo. If the .NET app misbehaves, point
the proxy / L!NK URL back at it (`restart-ops-{demoerp,local,network}.bat`) — no data migration is involved (both
serve the same database). **Do not run both on the same port.** (Note: the PowerShell server serves its static
root **unguarded** — keep its port off the internet while it runs. The .NET server blocks secrets.) The historical
PowerShell→.NET cutover runbook is in [`_archive/CUTOVER.md`](_archive/CUTOVER.md).

---

## After the update

Confirm: `https://<host>/` loads; `https://<host>/ops.config.json` → **404** (secret blocked); the language picker
works; **your real users still appear in Admin → Users**; reconcile a milestone light against a direct ERP SQL
query. Then take a fresh backup (`backup-ops.ps1`). Ongoing support: [4-OPERATE-SUPPORT.md](4-OPERATE-SUPPORT.md).
