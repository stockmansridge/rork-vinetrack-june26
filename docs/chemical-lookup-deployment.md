# Deploying `chemical-info-lookup` (diagnostics + server ranking)

Deployment instructions for the Step 1 (production diagnostics) and Step 2
(server-authoritative ranking) work. **Rork does not deploy this** — run these
yourself against the production project.

## What this deployment changes

| Change | Client impact |
|---|---|
| `diagnostics` envelope on every `search` / `structured` response | Additive. Older clients ignore an unknown key. |
| Candidates returned pre-ranked, with `rank_tier`, `rank_relevance`, `rank_score`, `rank_reason`, `register_order` | Additive fields. iOS switches to the served order automatically. |
| `ranking` summary block on `search` responses | Additive. |
| One `chemical_lookup_diagnostics` log line per lookup | Server-side only. |

No database migration. No schema change. No breaking wire change: every new key
is additive and every client decodes tolerantly, so **the function can be
deployed before or after any app release**.

## 1. Set `LOOKUP_GIT_SHA`

This is the single most important part of the deploy. Without it the diagnostics
report `lookup_version: "unknown"`, and a parity investigation cannot tell
"both platforms hit the same build" from "one hit an older deployment" — which
is one of the candidate explanations for the Hortitrol split.

The value must be **set at deploy time from the commit being deployed**, not
hardcoded in a file (a committed SHA is stale the moment the next commit lands).

Set it as a function secret immediately before deploying:

```bash
# From the repository root, on the commit you are deploying.
supabase secrets set LOOKUP_GIT_SHA="$(git rev-parse --short HEAD)" \
  --project-ref <YOUR_PROJECT_REF>
```

Verify:

```bash
supabase secrets list --project-ref <YOUR_PROJECT_REF> | grep LOOKUP_GIT_SHA
```

> **Why a secret and not a build flag:** Supabase Edge Functions read config
> from the environment, and secrets are the only deploy-time environment
> mechanism available. It is not sensitive — it is deliberately returned to
> clients — but it needs the same lifecycle as the deploy.

If `LOOKUP_GIT_SHA` is unset the function still works. It reports the literal
string `"unknown"` — deliberately stable, never a generated stand-in, so one
deployment cannot look like several different builds.

## 2. Deploy the function

```bash
supabase functions deploy chemical-info-lookup \
  --project-ref <YOUR_PROJECT_REF>
```

Keep the two commands adjacent. Setting the SHA *after* deploying leaves a
window in which the running build misreports its own version.

### Recommended one-liner

```bash
supabase secrets set LOOKUP_GIT_SHA="$(git rev-parse --short HEAD)" --project-ref <REF> \
  && supabase functions deploy chemical-info-lookup --project-ref <REF>
```

## 3. Verify the deploy

A single curl proves diagnostics, ranking and the build id at once:

```bash
curl -s -X POST \
  "https://<REF>.supabase.co/functions/v1/chemical-info-lookup" \
  -H "apikey: <ANON_KEY>" \
  -H "Authorization: Bearer <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "action": "search",
    "query": "Hortitrol winter oil",
    "country": "AU",
    "client": {
      "platform": "portal",
      "app_version": "verify",
      "app_build": "0",
      "correlation_id": "deploy-check-1"
    }
  }' | jq '{
    build: .diagnostics.server.lookup_version,
    project: .diagnostics.server.project_ref,
    method: .diagnostics.lookup_method,
    candidates: .diagnostics.candidate_registration_numbers,
    ranking: .ranking,
    degraded: .diagnostics.degraded
  }'
```

Expect:

- `build` — the short SHA you set (not `"unknown"`)
- `project` — your project ref
- `candidates` — an ordered array of registration numbers
- `ranking.ambiguous` / `ranking.exact_registration_number` present
- `degraded` — `[]` on a healthy call

### Reading the logs

```bash
supabase functions logs chemical-info-lookup --project-ref <REF> \
  | grep chemical_lookup_diagnostics
```

Each line is single-line JSON, filterable by `request_id` or `correlation_id`.

## 4. Post-deploy: the parity proof (still open)

The §14 parity check is **not closed by deploying**. Once this is live *and*
Portal is sending its `client` block, run the exact search from both platforms:

```text
query:   Hortitrol winter oil
country: AU
```

Then compare, from each platform's response:

1. `diagnostics.server.lookup_version` — must be identical (same build)
2. `diagnostics.server.project_ref` — must be identical (same project)
3. `diagnostics.candidate_registration_numbers` — must be identical **in order**
4. `diagnostics.degraded` — should be `[]` on both

iOS computes this comparison for you: `ChemicalLookupDiagnostics.parityFingerprint`
is `build|project|country|method|[ordered registrations]`. Two platforms with the
same fingerprint agree by construction. Send both fingerprints back and the
parity gate can be closed.

Then select the same registration on both and compare the structured payload:
identity, active ingredients, resistance classification, grapevine uses,
/100 L rates, /ha rates, restrictions, official label, manufacturer reference,
and that WHP/REI are `null` rather than `0` where the label is silent.

## Rollback

```bash
supabase functions deploy chemical-info-lookup --project-ref <REF>
```

from the previous commit. Nothing persistent is written by this change — no
migration, no table, no cached artefact — so rollback is just redeploying the
older source. Clients tolerate the absence of every new key, and iOS falls back
to its on-device ordering shim automatically.
