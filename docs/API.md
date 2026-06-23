# Third-party Find API

Lets another application (e.g. **Swivel L!NK** or **Cargoclip**) run the operator **Find** search against this
Control Tower instance and get the results back as JSON. The caller authenticates **as a user** with a JWT bearer
token; every query is gated by that user's row-level scope (stations / mode-bound pairs / notes), so the caller
**only ever sees what that user is allowed to see**. No extra authorization wiring is needed — scope is the same
boundary the worklist uses.

## Authentication — JWT bearer

Send a signed JWT on every request:

```
Authorization: Bearer <jwt>
```

The token must carry the user's **email** (claim `email`, or `upn` / `preferred_username` as fallbacks). The
server validates signature + issuer + audience + expiry, then federates the email to a Control Tower user
(`users.json`). Unknown emails are auto-provisioned as a default-role user when `jwtAuth.autoProvision` is on.

Validation **fails closed**: a missing, malformed, expired, wrong-issuer, or wrong-audience token returns
**401**. CORS allows any origin for `/api-ops/*`; bearer auth uses no cookies, so cross-origin calls work.

### Enabling it (server side)

In `ops.config.<env>.json`, set the `jwtAuth` block (see `ops.config.example.json` for the full comment). It is
**off** until `enabled:true` **and** one piece of verification material is present:

| Field | Meaning |
|-------|---------|
| `signingKey` | HS256/384/512 shared secret |
| `jwksUrl` | RS*/ES* public keyset URL (fetched + cached) |
| `publicKey` | inline PEM public key (alternative to `jwksUrl`) |
| `issuer` / `audience` | expected `iss` / `aud` (`""` = skip that check) |
| `emailClaim` | claim holding the email (default `email`) |
| `autoProvision` | create a user on first unseen email (default follows L!NK) |
| `clockSkewSec` | clock-drift tolerance (default 120) |

Env overrides: `OPS_JWT_ISSUER`, `OPS_JWT_AUDIENCE`, `OPS_JWT_SIGNING_KEY`, `OPS_JWT_JWKS_URL`,
`OPS_JWT_PUBLIC_KEY`.

> **Confirm with the token issuer before enabling:** the signing scheme + key (HS256 secret vs RS256/JWKS), the
> `iss`, the `aud`, and the exact email claim name.

## Endpoint — natural-language search

```
POST /api-ops/find-text
Authorization: Bearer <jwt>
Content-Type: application/json

{ "text": "sea import from Shanghai FOOTWEAR last month", "useLlm": true }
```

- `text` — free-text query, the way an operator would describe a shipment.
- `useLlm` — optional (default `true`). When the rule parser finds nothing **and** the LLM fallback is enabled
  (`llm` config block), the query is re-interpreted by the configured provider and re-run. The LLM never sees DB
  rows and never bypasses scope. Set `false` to force rule-only parsing.

### Response

```json
{
  "query": "sea import from Shanghai FOOTWEAR last month",
  "source": "rule",
  "resolved": { "who": "", "pol": "Shanghai", "pod": "", "commodity": "FOOTWEAR",
                "mode": "Sea", "bound": "Import", "mine": true, "noteAuthor": "",
                "noteText": "", "tome": false, "from": "2026-05-01", "to": "2026-05-31" },
  "items": [ { "type": "shipment", "jobNo": "...", "humanId": "...", "lane": "...", ... },
             { "type": "note", "jobNo": "...", "author": "...", "note": "...", ... } ]
}
```

- `source` — `"rule"` (rule parser) or `"llm"` (LLM fallback produced the hits).
- `resolved` — the clue object the search actually used (so the caller can show/correct what was understood).
- `items` — up to 60 shipment and note results, recency-sorted, deduped by job (a shipment that also has a
  matching note is shown once with `hasNote:true`). Field shapes are in `server/Handlers.Find.cs`
  (`ShipItem` / `NoteItem`).

## Alternative — structured search

Callers that build the clues themselves can skip the parser and hit the existing endpoint directly (same JWT,
same scope, same item shapes):

```
GET /api-ops/find?mode=Sea&bound=Import&pol=Shanghai&commodity=FOOTWEAR&from=2026-05-01&to=2026-05-31
Authorization: Bearer <jwt>
```

Params: `who`, `pol`, `pod`, `commodity`, `mode` (`Sea`/`Air`), `bound` (`Import`/`Export`),
`ref` + `refField` (`booking`/`po`/`house`/`master`/`shipid`/`container`/`conv`/`job`),
`noteauthor`, `notetext`, `tome=1`, `mine=1`, `from`, `to` (ISO `yyyy-mm-dd`). All optional. An explicit `ref`
finds any in-scope file (bypasses the "mine" involvement lens). Returns `{ items, resolved }`.
