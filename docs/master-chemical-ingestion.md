# Master Chemical Ingestion — Stages 3–4 (Australia)

**Status:** Stage 3 implemented 2026-08-19 (deployed). Stage 4 — official
label evidence — implemented 2026-08-20 (NOT yet deployed). Authoritative
ingestion pipeline inside the `chemical-info-lookup` edge function
(`supabase/functions/chemical-info-lookup/ingestion/`).
**Scope:** Australia (APVMA) only. NZ / GB / US are declared future adapters.
**Companions:** `docs/master-chemical-catalogue-design.md` (schema + trust model),
`docs/chemical-intelligence-json-contract.md` (wire contract, §12),
`docs/vineyard-country-contract.md` (supported vineyard countries),
`docs/chemical-custodia-parity-fixture.md` (the pinned regression fixture).
**Database changes:** NONE — sql/199 already carries every candidate,
provenance, conflict and version field both stages need.

## 1. Purpose

Verify a product once, not once per vineyard:

```
grower search
  → same-country APPROVED master lookup      (deterministic, free)
  → no approved match
  → authoritative source discovery           (jurisdiction's register)
  → structured candidate                     (sql/194 wire shapes)
  → registration-identity dedupe             (one row per registration)
  → master CANDIDATE (sql/199)               (never auto-approved)
  → admin review (existing portal queue)
  → approved master
  → every future grower receives the approved record instantly
```

## 2. Country source registry

`ingestion/registry.ts` is the single statement of which registration sources
VineTrack trusts, by jurisdiction. **The resolved vineyard country selects the
adapter; source selection is never an AI decision.**

| Country | Schemes | Register authority | Label authority | Adapter |
|---|---|---|---|---|
| AU | `apvma` | APVMA PubCRIS register extract (data.gov.au dataset, published weekly by the APVMA) | APVMA-approved label (label registration record; document confirmed at admin review) | **implemented** |
| NZ | `acvm`, `nz_epa` | MPI ACVM register | ACVM-registered label / EPA HSNO approval | future |
| GB | `other` | HSE plant protection products register | HSE-authorised label | future |
| US | `other` | US EPA pesticide product label system | EPA-stamped label | future |

Countries in the vineyard-country contract without a registry entry have no
wired register at all — vineyard-country support does **not** imply a chemical
register (contract §12.3). Ireland, Bulgaria, etc. therefore resolve honestly:
"no verified chemical registration source is currently wired for this
jurisdiction"; the AI/manual path continues to work, and nothing ever falls
back to GB or AU.

## 3. Australian evidence hierarchy

1. **Government registration (highest).** The APVMA-published PubCRIS dataset
   on data.gov.au (CKAN datastore API, CC-BY, refreshed weekly by the APVMA):
   - `product.csv` `b4bb5394-b60b-4602-8bde-2e206ffc498f` — pcode (APVMA
     product number), verbatim registered name, registrant, category,
     formulation, registration status + expiry.
   - `prodcon.csv` `eb08d8fc-bb61-4191-9a4b-a20ee44dac1f` — the product's
     active constituents with concentration + unit.
   - `constit.csv` `de913672-c51a-483a-b467-f2f9df51f671` — constituent code →
     constituent name.
   - `labelreg.csv` `a83d500d-b47a-4f03-9d77-4c0524217855` — the current
     approved label registration (approval number + date).
   Attributed `official_register`; every source entry carries the reproducible
   datastore query URL and retrieval timestamp.
2. **Label authority (Stage 4 — machine-consumed).** The APVMA-approved
   label. The register extract points at the current approval
   (`label_version` = "APVMA label approval NNNN (date)") **and publishes the
   label's claim content**, which `ingestion/label.ts` consumes as official
   label evidence attributed `manufacturer_label` (the contract's
   registrant's-approved-label kind, §5.3 — already authoritative):
   - `produse.csv` `80289270-0681-44fd-be6e-0473bb4ab9a0` — the approved
     label's registered use claims (pcode × host × pest).
   - `host.csv` `2927e1dd-b064-411c-bc90-1e2c05b6822f` / `pest.csv`
     `1365af46-a3db-4d54-9f25-e41f7dfce5d2` — verbatim crop/target wording.
   - `prodcom.csv` `98e956e0-8d60-47cd-8bed-1d4da4c9826d` — the label's
     statements (withholding periods, re-entry, restrictions), shipped as
     fixed-width 40-char chunks reassembled by `seq`. The publication trims
     chunk-edge whitespace, so reassembly restores a boundary space only
     where the slice-width deficit proves one was trimmed ("…AFTER" +
     "APPLICATION…" → "AFTER APPLICATION"); mid-word splits ("GRAP" +
     "EVINES") join bare, and unspendable deficit (a stripped `\r`,
     line-edge whitespace) is dropped — whitespace is never invented.
   Strict parsing only: "DO NOT HARVEST FOR n DAYS/WEEKS" and (inside a
   withholding section) "NOT REQUIRED WHEN USED AS DIRECTED" → WHP;
   explicit re-entry hours/days → re-entry period; anything else keeps its
   verbatim wording and resolves nothing. **The register publishes NO
   machine-readable rate table** — label rates stay unresolved per crop
   (`rates:<CROP>`) for the admin to confirm against the label document at
   review, or ride along AI-attributed. `label_reference` (the document URL)
   remains unresolved until a real label document is recorded. Fail-soft: any
   label-source failure keeps register identity/chemistry intact and leaves
   label fields unresolved or AI-attributed — never invented.
3. **Supporting evidence.** Registrant/manufacturer label mirrors
   (`manufacturer_label`) and the AWRI viticulture registrations list
   (`viticulture_reference`) — admissible at review, never authoritative alone.
4. **Discovery only.** AI extraction / web search (`ai_interpretation`). The
   model may LOCATE a product — a name, a possible registration number — and
   may contribute label-side detail (uses, rates) under its own attribution.
   It can never elevate itself to authoritative evidence, and a number it
   suggests is only a pointer that the register must confirm.

## 4. Adapter interface

```ts
interface SourceAdapter {
  id: string;       // "apvma"
  country: string;  // "AU"
  scheme: string;   // sql/194 registration_scheme value
  discover(query, hintRegistrationNumber, deps): Promise<DiscoveryResult>;
}
// DiscoveryResult.outcome:
//   resolved | unresolved | ambiguous | source_unavailable | not_supported | no_country
```

Adding a jurisdiction later = implement one adapter + fill its registry slot.
The master_chemicals schema needs no change: identity is already
country-scoped (`AU:apvma:66541`).

**Name discipline (deterministic, never fuzzy):**

- exact normalised name equality wins first;
- else the *formulation-suffix* rule: the register name may extend the query
  by ONLY ignorable tokens (pack numbers, formulation codes SC/EC/WG/…,
  category words like FUNGICIDE). "FORTE", "ULTRA", "DUO" are deliberately
  not ignorable — they denote different registered products;
- any tie at either tier is ambiguous and fails closed;
- a registration-number hint is re-verified: the row must exist AND its name
  must correspond — a hallucinated or mistyped number can never bind the
  wrong product;
- substring matching is structurally impossible ("custodia" can never reach
  "Custodia Forte").

The registered product name is stored **verbatim from the register**; the
grower's search term and the register name become lower-cased exact-match
search aliases (`common_names`), which never establish identity.

## 5. Ingestion result — one canonical contract

The ingestion result IS the sql/194 structured payload plus identity and
provenance, mapping 1:1 onto sql/199 columns (`ingestion/contract.ts`). There
is no second Chemical Intelligence model. Register-backed actives carry
`identity_source: "official_register"`; groups resolve through the SAME
authoritative FRAC/HRAC/IRAC table as everything else (`group_source:
"authoritative_classification"`); mixture actives stay separate objects with
their own concentration, unit and group.

**Never invented:** WHP, re-entry hours, rate values/units, registered uses,
concentrations, targets. A fact no authoritative source provided is listed in
`verification_unresolved_fields`. Narrative label statements ("do not re-enter
until the spray has dried") stay narrative in `restrictions` — they are never
converted into numbers.

**Conflicts:** where the register and the extraction disagree on a
register-asserted fact (concentration, registration number, active set), the
register value is served AND a structured `verification_conflicts` entry
records both sides with their attributions; the evidence state becomes
`conflict`. Software never silently picks a winner.

## 6. Candidate lifecycle, dedupe and refresh policy

- Automation can only ever write `review_status = 'candidate'` — pinned by a
  typed literal in the payload, by sql/199's approval-provenance CHECK, and by
  the live PATCH filter `review_status=eq.candidate` (an approved/retired row
  is untouchable at the database even if handed the wrong id).
- **Dedupe order:** exact `country:scheme:number` identity across ALL review
  states first. Approved → served as the master answer (ingestion never
  re-runs for it). Retired → left alone. Candidate → refresh policy:
  1. *authority upgrade* — an `ai_interpretation` candidate is replaced in
     place by register-backed content;
  2. *material change* — register-backed fields differ → content refresh;
  3. *stale evidence* — content identical but evidence older than **7 days**
     → evidence re-stamp (sources + retrieved_at);
  4. otherwise → reuse; at most a search-alias merge.
  AI evidence never overwrites an authoritative candidate.
- One candidate per canonical registration identity: 20 vineyards searching
  the same unresolved product still yield exactly one row (identity
  uniqueness + `resolution=ignore-duplicates` + re-select on race).

## 7. Cache policy (§L)

`ingestion/cache.ts` — in-memory, per-isolate, deliberately SEPARATE from
`master_chemicals`. A cached source response is never an approved master and
is never served as catalogue data.

- Keys and entries are country + source scoped and re-checked on read; an AU
  request can structurally never be served from another country's cached
  search. Entries retain country, source, retrieval timestamp and the
  registration identity when known.
- **Staleness policy:** resolved identities 6 h · unresolved/ambiguous 1 h ·
  source_unavailable 5 min · 256 entries, oldest evicted. Edge isolates are
  ephemeral, so these are upper bounds; cross-instance protection against
  repeated external fetches comes from the catalogue itself (an existing
  fresh candidate short-circuits to "reused" without new register calls
  beyond the cached discovery).

## 8. Update / version flow (§G)

`ingestion/refresh.ts` — `refreshMasterRow(row)` re-checks one master row
against its jurisdiction's sources and returns exactly one of:

| Outcome | Meaning | Candidate apply | Approved rows |
|---|---|---|---|
| `no_material_change` | register agrees; evidence fresh | no write | no write |
| `evidence_refreshed` | content identical; stored evidence stale, re-confirmed | evidence columns only | **never written** |
| `material_change` | register asserts different non-chemistry facts | register-backed scalars + evidence | **never written** — returned diff is the reviewable update |
| `conflict` | register disagrees about CHEMISTRY | conflict recorded, status `conflict`, chemistry NOT replaced | **never written** |
| `source_unavailable` | register unreachable — says nothing about the product | no write | no write |

The `master_refresh` action (below) exposes this to the portal. An approved
master with new authoritative information follows: refresh returns the diff →
admin reviews → admin applies through the EXISTING admin write path → the
sql/199 trigger mints the next `catalogue_version` (revision 4 → accept →
revision 5) and appends history → linked Saved Chemicals detect
`master_revision > master_source_revision` through Re-verify. A label update
for the same registration updates the same identity/version; a different
registration number is a different product and is surfaced, never re-keyed.
`saved_chemicals` and spray snapshots are never touched by any refresh path.

## 9. Lookup response envelope (§J — additive, JSON contract §12.1)

- `match_source` gains `"authoritative_candidate"`: register-backed identity,
  NOT approved. Old clients treat it exactly like `ai_candidate` (they only
  special-case `"master"`), which is the intended behaviour.
- `candidate` block (additive): `{ master_chemical_id, candidate_revision,
  catalogue_status: "candidate", registration_identity_key }` — present when
  a candidate row backs the lookup.
- `discovery` block (additive): `{ adapter, outcome,
  registration_identity_key?, register_status?, error_category? }` — honest
  provenance of what authoritative discovery did, including
  `source_unavailable` (which is NOT "product not registered").
- `master` remains reserved for APPROVED matches only. Both apps additionally
  harden `isMasterMatch`: a master block carrying a non-approved
  `catalogue_status` never reads as a master match (pinned in
  `ChemicalCustodiaParityTests.swift` / `ChemicalCustodiaParityTest.kt`).
- The grower can still save an authoritative-candidate result through the
  existing unverified/partially-verified Saved Chemical flow — master
  approval and the vineyard's own record are separate concerns; Re-verify
  links them once the master is approved.

## 10. Jurisdiction boundaries (§K)

- Every ingestion request requires a resolved vineyard country. No country →
  `no_country`, no source fetch (asserted by test). No locale fallback ever.
- The AU adapter only queries the AU government register (tests reject any
  non-`data.gov.au` host). If an AU product cannot be established, the
  outcome is `unresolved` — never a foreign register, never a foreign
  manufacturer site as AU label authority.
- Foreign registrations of the same brand stay separate products forever
  (GB Custodia `GB:other:16393` can never merge with `AU:apvma:66541`).

## 11. Failure behaviour (§M)

- Register unreachable/unparseable → `source_unavailable` + error category;
  the AI lookup proceeds unchanged; the Chemical Store never fails because
  ingestion failed (belt-and-braces catch around the whole pipeline).
- Register row found but details unparseable → identity stands, the gap is
  recorded (`active_ingredients` etc. in unresolved fields), nothing is
  fabricated, the source reference is retained.
- AI unavailable but register resolved → a register-only structured result is
  served (identity + chemistry; uses honestly empty and unresolved).

## 12. Observability (§P)

One structured, secret-free log line per ingestion (`evt:
"chemical_ingestion"`): jurisdiction, adapter, outcome, registration
identity, master existing/new, candidate created/reused/refreshed(+reason),
unresolved count, conflict count, duration ms, cache hit/miss, error
category. `master_refresh` logs `evt: "master_refresh"` with outcome, change
count and applied flag. No vineyard/user data, no secrets.

## 13. Admin queue (§I)

Candidates land in the SAME sql/199 queue the portal Admin already reads —
no second queue exists. New candidate metadata worth surfacing in the
existing UI (no schema change; all existing columns): `source_kind =
official_register`, `source_reference` (reproducible register query URL),
`label_version` (current label approval), register-vs-AI
`verification_conflicts`, `verification_unresolved_fields`, `retrieved_at`,
and the merged `common_names`.

## 14. `master_refresh` action

```
POST /functions/v1/chemical-info-lookup
{ "action": "master_refresh", "masterChemicalId": "<uuid>", "apply": false }
```

- Caller must be a system admin: the function forwards the caller's JWT to
  `rpc/is_system_admin`; anyone else gets 403.
- Response: `{ outcome, changes[], applied, master: { master_chemical_id,
  catalogue_status, master_revision, registration_identity_key } }`.
- `apply: true` writes ONLY candidate rows (per §8); approved rows are never
  written by this action regardless of flags.

## 15. Tests

```
deno test supabase/functions/chemical-info-lookup/ingestion/ingestion_test.ts
```

36 deno tests (all executed and passing). Stage 3 matrix: AU resolution +
provenance (40), Custodia chemistry through the normal evidence path (23),
similar-name protection incl. the lapsed-register case (24/43),
approved-master short-circuit (41), candidate dedupe/upgrade (42), repeated
lookups → one candidate (48), foreign/missing jurisdiction (44/45), partial
extraction honesty (46), register-vs-AI conflict (47), refresh outcomes and
approved-row immutability (49), source-unavailable semantics (36), candidate
envelope (28), cache scoping/TTL (33/34), and candidate-only writes (10).
Stage 4 label evidence (49–59): strict statement parsing (49), Custodia Forte
91636 claims/WHP from live-mirrored PubCRIS label data (50), label-backed
merge with field-level provenance and AI rates carried-never-promoted (51),
WHP disagreement → structured conflict with the label value served (52),
AI-only uses dropped as conflicts (53), distinct grape uses never collapsed
(54), re-entry never fabricated (55), fail-soft on label-source outages (56),
register-only lookups serving claims with empty rates (57), refresh label
drift as material change preserving stored rates + Master UUID and never
touching approved rows (58), and 66541 fail-closed with Forte evidence
present (59). Register + label facts live in mocked APVMA documents inside
the test file (mirroring live PubCRIS bytes for 91636) — the implementation
hard-codes none of them. Mobile: 2 pinned parity tests per platform assert a
candidate can never read as an approved master.

## 16. Deployment

Changed function: `chemical-info-lookup` only. From the repo root (Windows
PowerShell):

```powershell
supabase login   # once
.\scripts\deploy-edge-functions.ps1 -Functions @("chemical-info-lookup")
# or directly:
supabase functions deploy chemical-info-lookup --project-ref tbafuqwruefgkbyxrxyb
```

The CLI bundles the function folder's full module graph (`ingestion/*.ts`),
exactly as it already does for `vinetrack-webhook-dispatch/lib.ts` and the
`_shared/email` imports. Pasting `index.ts` alone into the dashboard editor
is no longer a supported deployment method for this function. No database
migration accompanies this stage.

## 17. Stage 5 — AWRI "Dog Book" 2026/27 seed (dry run complete, no writes)

Coverage seeding for AU viticulture from the AWRI booklet *Agrochemicals
registered for use in Australian viticulture 2026/27* (compiled 1 June 2026).
AWRI is a `viticulture_reference` source ONLY — it nominates which products
are worth seeding and never supplies registration, label, chemistry, WHP,
re-entry, or rate facts. The APVMA register remains the sole authority.

Pieces (all under `ingestion/` unless noted):

- `seeds/extract_awri_dogbook.py` — versioned extractor. Table 2 + the
  cancelled-products list are hand-transcribed (PDF column extraction is
  unreliable) and every transcribed product string is mechanically verified
  against the squashed booklet text; a transcription typo fails the build.
  Variant expansion is deterministic: `Parent (V1, V2)` → `Parent V1`,
  `Parent V2`; the bare parent is also emitted only when the parentheses
  hold exactly one letter-initial variant (e.g. `Custodia (Forte)`).
- `seeds/awri_dogbook_2026_27.json` — the deterministic seed manifest
  (666 unique product names, 5 cancelled-list rows, PDF SHA-256 provenance).
  The booklet publishes NO APVMA numbers, so every entry carries
  `apvma_registration_number: null` — identity can only come from the
  register.
- `seed_awri.ts` — pure dry-run module. Resolves each name against a
  PubCRIS product snapshot using the adapter's own discipline verbatim
  (`normaliseProductName`/`selectProductRow`: exact tier → formulation-suffix
  tier → ties fail closed; substring/fuzzy structurally impossible).
  Classification: `resolved_current` (regcode R), `resolved_not_current`
  (archived/suspended → conflict bucket), `unresolved_no_match`,
  `unresolved_ambiguous`. Names on AWRI's cancelled list classify as
  conflicts even when a current register row matches (e.g. Jasper 520 EC,
  Fyfanon 440 EW) — never candidate-eligible, never silently swapped.
  Dedupe is by `AU:apvma:<number>` ONLY. Idempotent: same manifest + same
  snapshot ⇒ byte-identical output (test 65).
- `seeds/run_awri_dryrun.ts` — read-only runner. Snapshots the PubCRIS
  product resource (public CKAN), writes the dry-run artifact
  (`seeds/awri_dogbook_2026_27.dryrun.json`) and the manual comparison SQL
  (`sql/stage5_awri_dryrun_compare.sql`). It contains no database client;
  "Already in Master" stays pending until an operator runs that SQL in the
  Supabase SQL Editor.
- Tests 61–66 (`seed_awri_test.ts`): manifest invariants, resolution
  discipline, cancelled/lapsed fail-safe, identity dedupe, idempotence +
  read-only SQL, empty-register fail-closed posture.

Dry-run result (register snapshot 2026-08-20, 18,809 rows: 12,980 R /
5,829 A): 666 unique products; 198 names resolved → 199 identities;
197 candidate-eligible; 468 unresolved (466 no deterministic match — mostly
registrant-prefixed or generic register names, deliberately fail-closed and
NOT "not registered"; 2 ambiguous); 5 conflicts/cancelled; 0 duplicate
identities. Live proof of the fail-closed rule: bare `Custodia` stayed
unresolved rather than resolving to `CUSTODIA FORTE FUNGICIDE`.

Manual comparison (operator-run read-only SQL, 2026-08-20): of the 197
candidate-eligible identities, 1 already exists in Master — `AU:apvma:91636`
(CUSTODIA FORTE FUNGICIDE, review_status `candidate`, the Stage 4 pilot
ingestion row); 0 approved, 0 retired; 196 identities are not in Master and
would be created as candidates. The pre-existing 91636 candidate is the live
idempotence proof: the seed skips it — no duplicate, no update. Result is
recorded in `seeds/awri_dogbook_2026_27.dryrun.json` under
`manual_comparison`.

Next step (NOT yet run — dry-run counts are confirmed, but execution still
requires explicit operator approval): bulk candidate creation by feeding each
candidate-eligible
registration number through the existing pipeline (`ingest.ts`, register-
number-verified path) — candidates only, tagged with AWRI
`viticulture_reference` provenance, never auto-approved, duplicate-safe on
the identity key so rerunning the same edition creates nothing new.

## 18. Future jurisdictions (New Zealand, not implemented)

To add NZ later: implement `SourceAdapter` for the MPI ACVM register (and the
EPA HSNO approval reference the label quotes), decide the identity scheme
precedence between `acvm` and `nz_epa` for the identity key, apply the same
deterministic name discipline, fill the `NZ` registry slot, and add an
NZ regression fixture mirroring Custodia. No master_chemicals schema change
is required — identity is already country-scoped and the candidate columns
are jurisdiction-neutral.
