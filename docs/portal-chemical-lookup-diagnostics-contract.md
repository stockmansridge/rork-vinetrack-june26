# Portal instruction — send client diagnostics on chemical lookups

**Owner:** Lovable (Portal call-sites)
**Scope:** diagnostics only. This change adds four strings to two request
bodies. It adds **no** Portal logic.

## Why

VineTrack cannot currently prove that the Portal and the iOS app receive the
same answer from the shared `chemical-info-lookup` function. Searching
`Hortitrol winter oil` (country `AU`) resolves to APVMA **50067** on the Portal
and **33182** on iOS, and today neither request records which client asked or
which server build answered — so the two observations cannot be compared.

The server now returns a `diagnostics` envelope on every lookup. It records the
client that asked, using whatever the client tells it. Without this change the
Portal is logged as `platform: "unknown"` and the parity comparison stays weak.

## The change

Add a `client` object to the JSON body of **both** existing calls to
`chemical-info-lookup`.

### `action: "search"`

```jsonc
{
  "action": "search",
  "query": "Hortitrol winter oil",
  "country": "AU",
  "client": {
    "platform": "portal",
    "app_version": "1.4.2",
    "app_build": "318",
    "correlation_id": "b6f0c1e2-..."
  }
}
```

### `action: "structured"`

```jsonc
{
  "action": "structured",
  "productName": "HORTITROL WINTER OIL",
  "country": "AU",
  "registrationNumber": "50067",
  "client": {
    "platform": "portal",
    "app_version": "1.4.2",
    "app_build": "318",
    "correlation_id": "9d2a7f45-..."
  }
}
```

### Field rules

| Field | Value |
|---|---|
| `platform` | The literal string `"portal"`. Never derived from the browser or user agent. |
| `app_version` | Portal release/marketing version. Whatever your build already exposes. |
| `app_build` | Build or commit identifier. A short git SHA is ideal. |
| `correlation_id` | A **fresh UUID per request**. Not per session, not per user. |

All four are optional and bounded to 64 characters server-side (80 for
`correlation_id`). A missing or malformed block never fails a lookup — it just
degrades the diagnostics.

`correlation_id` is echoed back as `diagnostics.correlation_id`, which is what
lets a Portal console log and a server log line be joined for one request.
Please log it Portal-side alongside the request.

## What the server now returns

Both responses gain a `diagnostics` object, and `search` also gains a `ranking`
summary. Both are **additive** — ignoring them is valid.

```jsonc
{
  "results": [ /* … already ordered — see below … */ ],
  "ranking": {
    "ambiguous": false,
    "strong_candidate_count": 1,
    "exact_registration_number": "50067",
    "demoted_count": 2
  },
  "diagnostics": {
    "request_id": "…",
    "correlation_id": "b6f0c1e2-…",
    "client": { "platform": "portal", "app_version": "1.4.2", "app_build": "318" },
    "server": { "lookup_version": "a1b2c3d", "project_ref": "…" },
    "action": "search",
    "country": { "requested": "AU", "resolved_code": "AU" },
    "query": "Hortitrol winter oil",
    "candidate_registration_numbers": ["50067", "33182", "12345"],
    "candidates": [ { "registrationNumber": "50067", "name": "…",
                      "source": "official_register", "score": 100,
                      "reason": "exact_name" } ],
    "selected_registration": null,
    "lookup_method": "official_register",
    "cache": "miss",
    "duration_ms": 812,
    "degraded": []
  }
}
```

## Ranking is now server-authoritative — please rely on it

Each row in `results` now carries:

- `rank_tier` — `approved_master` | `official_register` | `suggestion` | `weak_match`
- `rank_relevance` — `exact_name` | `leading_product_name` | `leading_token` | `contained_phrase` | `incidental` | `unrelated`
- `rank_score` — 0–100
- `rank_reason` — `"<relevance>/<tier>"`
- `register_order` — the row's position **before** ranking

**`results` arrives in the order it should be displayed.** Please render that
order verbatim.

Specifically, the Portal must not:

- re-sort, re-score or fuzzy-match candidates
- filter rows out of the list (`weak_match` rows are demoted, never deleted —
  show them under a heading such as "Other register matches")
- auto-select a product because it happens to be first
- parse rates, resolve identity, or verify anything locally

If the Portal needs a heading per group, use `rank_tier`. If it needs to explain
an order to a user, use `rank_reason`.

### Auto-selection rule

Use `ranking.exact_registration_number`:

- **non-null** → exactly one candidate is an unambiguous exact identity, and it
  is safe to select automatically.
- **null** → a human must choose, even if the first row scores highest.

`ranking.ambiguous` is `true` when several credible products answer the query.
An ambiguous search should keep showing its ~2–5 candidates; do not collapse it
to one.

## Explicitly out of scope

- No Portal-side ranking, matching, rate parsing or verification.
- Do not branch on `diagnostics` — it is observational. The server ignores
  `platform`, `app_version`, `app_build` and `correlation_id` when deciding an
  answer, and the Portal must do the same, or the parity guarantee both sides
  are trying to prove is destroyed.

## Verification

After deploying, run the search below and send back
`diagnostics.server.lookup_version`, `diagnostics.server.project_ref` and
`diagnostics.candidate_registration_numbers`:

```text
query:   Hortitrol winter oil
country: AU
```

Those three values will be compared against the iOS run. They must match
exactly, including the order of the registration numbers.
