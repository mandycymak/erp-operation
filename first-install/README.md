# first-install\ — FIRST INSTALL ONLY

⛔ **The scripts in this folder are for setting up a BRAND-NEW customer (an empty database).**
**Do NOT run them to update or maintain a site that is already live.**

If a customer is already using the app and you are pushing new code, **close this folder** and run
**`..\update-customer.bat`** (one folder up). That is the safe, additive update path — it never recreates the
IIS pool, never resets environment variables, and never re-seeds users.

These scripts were put in their own folder on purpose: the #1 deployment incident was staff double-clicking a
"set up" script on a live site. They now also **detect a live database and stop** unless you explicitly type
`INSTALL`.

| File | What it does | When to run |
|---|---|---|
| `setup-database.bat` | Creates the ops database + all tables + seeds the milestone config. **Detector first checks the DB and refuses (asks you to type `INSTALL`) if it already has users/shipments.** | **Once**, on a brand-new install, before the first app start. Run from the repo root: `first-install\setup-database.bat -ConfigPath .\ops.config.<tenant>.json` |
| `deploy-local-iis-demoerp.ps1` | One-time **elevated** IIS bootstrap: enables IIS, installs the Hosting Bundle, creates the app pool + site, grants SQL + NTFS rights, sets the pool env vars. Asks you to type `INSTALL` first (it recreates the pool/env). | **Once**, when first standing the site up under IIS. Adapt the paths inside it per tenant. |
| `check-installed.ps1` | Read-only helper used by `setup-database.bat` — reports whether the target ops DB is fresh or already a live customer. Touches nothing. | Called automatically; you don't run it directly. |

**Full first-install walkthrough:** [`..\docs\2-SETUP-NEW-CUSTOMER.md`](../docs/2-SETUP-NEW-CUSTOMER.md).
**Routine updates:** [`..\docs\3-DEPLOY-UPDATES.md`](../docs/3-DEPLOY-UPDATES.md).
**What every file in the repo is:** [`..\FILES.md`](../FILES.md).
