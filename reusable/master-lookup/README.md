# master-lookup — drop-in master code lookup (port / customer / liner / service / incoterm)

A self-contained, framework-free widget extracted from `erp-operation`'s **Edit ERP data** editor. It gives you
the editable `( CODE ) ...` chip plus a viewport-pinned, fully-clamped type-ahead dropdown that searches an ERP
master and writes the picked code back. Server side is a dependency-free search over the Swivel `fm3k*` masters.

| File | Layer | What it is |
|------|-------|-----------|
| `master-lookup.js` | client | The chip + dropdown UI and positioning logic. Exposes `window.MasterLookup`. No deps. |
| `master-lookup.css` | client | Styles for the chip + dropdown. Themes via CSS custom props (with standalone fallbacks). |
| `MasterLookup.cs` | server | `MasterLookup.Search(conn, kind, term, isAir)` — bounded `TOP 20` LIKE seek. Only needs `Microsoft.Data.SqlClient`. |
| `demo.html` | demo | Open in a browser — wires every chip kind against an in-memory mock `search()`. No backend needed. |

**`kind`** is one of `custsub` (customer master), `port`, `liner`, `service`, `incoterm`. It is the contract
shared by both ends — the client passes it, the server switches on it.

The JSON shape on the wire: `{ "kind": "...", "results": [ { "code": "...", "name": "...", "loc": "city, country" } ] }`
(`loc` only for `custsub`), or `{ "error": "..." }`.

---

## Server (ASP.NET Core / .NET)

1. Copy `MasterLookup.cs` into your project (adjust the `namespace`). It assumes the source tables
   `custsub` / `portmstr` / `linermstr` / `servmstr` — edit the SQL strings if your schema differs.
2. Map an endpoint. You provide an **open connection to the read-only source ERP db**; the handler owns nothing else:

```csharp
using MasterLookupKit;

app.MapGet("/api-ops/erp-master", (string kind, string? q, bool air, HttpContext ctx) =>
{
    // resolve + open YOUR source-ERP connection (per request, per station/scope as your app requires)
    using var src = OpenSourceErp(/* db name for this request */);
    var payload = MasterLookup.Search(src, kind, q, air);
    return Results.Json(payload, MasterLookup.JsonOpts);   // JsonOpts keeps verbatim key casing
});
```

> **Note on auth/scope:** the original `ErpMaster` resolved the source db from a `shipment_alerts` row and ran a
> row-level-scope check (`TestJobScope`). That coupling was intentionally removed here. Apply your own
> authorization in the endpoint wrapper (auth filter, scope check) **before** calling `Search`.

## Client (vanilla JS)

1. Include the CSS + JS (JS before your own script):

```html
<link rel="stylesheet" href="master-lookup.css">
<script src="master-lookup.js"></script>
```

2. Build a `search(kind, q)` function — use the helper for the standard GET endpoint:

```js
const search = MasterLookup.httpSearch({
  url: '/api-ops/erp-master',
  params: { air: false },                       // extra query params (e.g. job id, station)
  headers: { 'X-Ops-User': localStorage.getItem('opsUser') || '(open)' },
  on401: () => location.href = 'login.html',     // optional
});
```

3. Make a chip and place it:

```js
const c = MasterLookup.chip({
  kind: 'custsub',          // customer master ; or 'port' / 'liner' / 'service' / 'incoterm'
  value: 'DUMMY',           // initial code
  search,                   // the fn from step 2
  onSelect: (code, row) => console.log('picked', code, row),
  onChange: (code) => {},   // fires on type or pick
  // disabled: true,        // render read-only (no find button)
  // hint: 'ACME CO - HK',  // initial resolved-name line
});
captionEl.appendChild(c.el);       // the ( CODE ) ... chip
captionEl.appendChild(c.hintEl);   // optional resolved-name line (place anywhere)

// read state later:
c.value      // current code string
c.changed    // true once edited away from the seeded value
```

`search` is transport-agnostic — skip `httpSearch` and pass any `async (kind, q) => ({results})` (e.g. an
in-memory list, a different API, a mock).

---

## Why the dropdown is `position:fixed`

Anchor-relative `absolute` positioning spilled off the **right** for right-side fields, and a naive leftward flip
then spilled off the **left**. `master-lookup.js` pins the box to the viewport and clamps it on-screen (opens
down, flips up near the bottom, caps height with internal scroll), and `fixed` also escapes any `overflow:clip`
on a host form. Focus is set with `preventScroll` so opening it never jumps the page.

## Source of truth

Lifted from `erp-operation`: client `erp-edit.js` (`codeChip` / `openLookup` / `fmtMaster`) + `erp-edit.html`
styles; server `server/Handlers.Erp.cs` (`ErpMaster` + the Incoterms table).
