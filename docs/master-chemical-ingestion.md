# Master Chemical Ingestion — Stages 3–4 (Australia)

**Status:** Stage 3 implemented 2026-08-19 (deployed). Stage 4 — official
label evidence — implemented 2026-08-20 (NOT yet deployed). Stage LD-1 —
official label DOCUMENT discovery + provenance — implemented 2026-08-20
(NOT yet deployed; §21). Authoritative ingestion pipeline inside the
`chemical-info-lookup` edge function
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
| AU | `apvma` | APVMA PubCRIS register extract (data.gov.au dataset, published weekly by the APVMA) | APVMA-approved label (label registration record + eLabels label DOCUMENT discovered via the PubCRIS portal — §21) | **implemented** |
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

### Stage 5B — apply mechanism (implemented; NOT yet executed)

The reviewed seed is applied through the DEPLOYED pipeline, one identity per
call — never bulk SQL. Pieces:

- `ingestion/seed_apply.ts` — server-side apply module behind the new
  `seed_apply` action in `index.ts` (system admins only, same
  `is_system_admin` gate as `master_refresh`). INSERT-ONLY by construction:
  it receives a narrowed ops surface with no update capability, so an
  existing row in ANY review state comes back `already_exists` untouched —
  the Stage 4 pilot candidate `AU:apvma:91636` can never be modified by
  seeding. For a missing identity it re-verifies name↔number LIVE via the
  adapter's `register_number_verified` path (the reviewed number is only a
  pointer; the resolved identity must equal the requested identity or
  nothing is written), refuses register drift (`conflict` when the row is
  no longer current, `unresolved` when the name no longer verifies), builds
  a register-only structured result (NO AI call; register + label evidence
  only), appends exactly one `viticulture_reference` evidence entry for the
  AWRI booklet (metadata only — never a fact; row `source_kind` stays
  `official_register`, keeping rows approvable under sql/199's provenance
  gate), and inserts via the duplicate-safe candidate insert.
- `ingestion/seed_awri_apply.ts` — pure batch logic: the batch is built from
  the reviewed artifact's `candidate_identities` ONLY (tampering — adding a
  conflict or an unreviewed identity — throws); operator-verified existing
  rows are pre-marked and never sent; terminal outcomes
  (created / already_exists / unresolved / conflict) are never re-sent on a
  rerun; only `failed` retries; per-item failures are contained so one
  product never aborts the batch.
- `ingestion/seeds/run_awri_apply.ts` — operator CLI. PLAN mode by default
  (zero network, zero writes). `--execute` performs the batch sequentially
  against the deployed function using the operator's OWN admin JWT
  (`SEED_APPLY_JWT`; no service-role key exists in the repo or the runner),
  persisting state (`seeds/awri_dogbook_2026_27.apply-state.json`) after
  every item — stop with Ctrl-C and rerun to resume. Logs one line per
  identity: created / already_exists / unresolved / conflict / failed.
- Tests 67–74 (`seed_apply_test.ts`) pin every gate above.

Runbook (when execution is approved): 1) deploy the updated function
(`supabase functions deploy chemical-info-lookup`, §16); 2) plan:
`deno run --allow-read seeds/run_awri_apply.ts`; 3) execute:
`SEED_APPLY_JWT=<admin JWT> deno run --allow-read --allow-write --allow-net
--allow-env seeds/run_awri_apply.ts --execute` (optionally `--limit 5` for a
pilot slice); 4) rerun the same command until `pending 0`; reruns create
nothing new. saved_chemicals and spray records are never touched; approval
remains a human step in the admin review UI.

## 18. Future jurisdictions (New Zealand, not implemented)

To add NZ later: implement `SourceAdapter` for the MPI ACVM register (and the
EPA HSNO approval reference the label quotes), decide the identity scheme
precedence between `acvm` and `nz_epa` for the identity key, apply the same
deterministic name discipline, fill the `NZ` registry slot, and add an
NZ regression fixture mirroring Custodia. No master_chemicals schema change
is required — identity is already country-scoped and the candidate columns
are jurisdiction-neutral.

## 19. General resolver upgrade (Sprayseal-class fixes)

The shared identity resolver was generalised after a live miss: “Spray
Seal” (AU) fell through to a fabricated AI answer because the CKAN
full-text search returns zero rows for a spaced query against the compact
register name “Sprayseal Pruning Wound Treatment”, and the matcher had no
typography tiers. Changes (no schema change, additive wire keys only):

- `ingestion/matching.ts` — ONE deterministic matcher for every
  register-facing path: strict tier, pure-typography tiers
  (case/punctuation/spacing/pack codes: “250SC” ↔ “250 SC”, “Spray Seal” ↔
  “Sprayseal”), formulation/use-descriptor suffix tiers in both directions,
  the AWRI Stage 5E variant guard (`VARIANT_TOKENS` — FORTE/ULTRA/DUO/…
  never droppable on either side), substring matching structurally
  impossible, every tie fails closed. Retrieval fires bounded typography
  query variants (raw → compact → loose) so the register rows can be found
  at all; MATCHING stays anchored to the original requested name.
- Master lookup (`ingestion/master_lookup.ts`) retries the exact-equality
  name/alias query with the same typography variants — still whole-string,
  still unique-or-nothing, never fuzzy.
- AI demotion: where the register was consulted and did NOT verify
  (unresolved/ambiguous), AI registration-identity claims are DISCARDED
  (`discovery.ai_registration_hint_discarded`), and candidates are enqueued
  ONLY from register-verified identities. On register-resolved products,
  `registered_uses`/WHP/re-entry/restrictions come ONLY from official label
  evidence; without it the field stays unresolved and AI readings move to
  the non-authoritative `ai_suggested_uses` envelope. Section 20 extends
  this to EVERY AI-derived product fact (strict fail-closed identity gate).
- Jurisdiction: `ingestion/jurisdiction.ts` resolves the vineyard-country
  contract server-side (display names, aliases, ISO-2; no fallback) and
  every search/structured response carries the `jurisdiction` envelope
  (vineyard-country contract §7).
- Per-field provenance: `field_provenance` (additive) states which evidence
  tier populated each field — official_register, manufacturer_label,
  authoritative_classification, ai_interpretation, master_catalogue, or
  unresolved.
- Contract invariant (enforced at response assembly on EVERY serving path —
  register merge, AI-only, master serve): `verification.unresolved_fields`
  never lists a whole field whose served value carries authoritative
  provenance. AI-populated fields stay listed (present-but-unverified is
  still unresolved), genuinely empty fields stay listed, and per-context gap
  entries (`rates:<crop>`, `withholding_period:<crop>`,
  `concentration:<active>`, …) are never pruned. Master rows stored before
  the invariant serve clean without any data rewrite
  (`pruneAuthoritativelyResolvedFields` in `ingestion/ingest.ts`).

Regression fixture: `ingestion/resolver_test.ts` (R01–R18) — Sprayseal
(APVMA 80160, Omnia, Tebuconazole 430 g/L, FRAC 3) resolves from the query
“Spray Seal” with register-backed facts and the fabricated AI result reduced
to recorded conflicts; variant safety (“Custodia” ↔ “CUSTODIA FORTE”),
ambiguity fail-closed, label-evidence-only enrichment, and the country
contract are pinned alongside; R12 pins the unresolved_fields ↔
field_provenance coherence invariant on the merge, AI-only and master-serve
paths; R13–R18 pin the strict fail-closed identity gate (section 20),
including the Custodia 320SC and Ridomil Gold production regressions.

## 20. Strict fail-closed identity gate (checked-but-unverified consults)

General resolver invariant — never product-specific, no schema change
(additive wire keys only):

When a SUPPORTED authoritative register was SUCCESSFULLY consulted and the
identity outcome is `unresolved` or `ambiguous` (which is also how a checked
name↔number conflict surfaces — a hint whose register row does not
correspond falls through to the name path), the AI must not establish or
populate ANY product-specific fact in the canonical structured response:

- `match_source` is `"unresolved"` — never `"ai_candidate"`;
- `registration` (number/scheme/registered name/label refs) stays unresolved;
- `registrant` stays unresolved;
- `active_ingredients` / concentrations stay unresolved;
- `activity_groups` stay unresolved — even when the authoritative table
  classified the AI-claimed actives, because the classification inherits the
  unverified identity of the chemistry it classified;
- `registered_uses`, label rates, WHP, re-entry and restrictions stay
  unresolved;
- `verification` is rebuilt: status `unverified`, conflicts moved out of the
  canonical envelope, `unresolved_fields` reduced to WHOLE-FIELD gaps only
  (a per-context entry like `concentration:<active>` would itself leak
  unverified AI chemistry);
- `field_provenance` reads `unresolved` for every field;
- NO Master candidate is created (the emptied registration block makes
  `buildCandidatePayload` structurally return null).

The AI reading is preserved — clearly separated — in the additive
`ai_suggestion` advisory (name, registrant, category/form, actives, uses,
plus a disclaimer note), and `guidance` carries the operator-facing meaning:
“We could not uniquely verify this product in the official register for
‹country›. Please refine the product name or registration number.” The AI’s
registration hint stays useful internally for discovery (it is retried as a
pointer before the gate) and remains visible as
`discovery.ai_registration_hint_discarded`.

The gate deliberately does NOT apply when the register itself was
UNAVAILABLE (`source_unavailable`) or never consulted (`not_supported`,
`no_country`): “could not check” is not “checked and could not verify”, so
the existing degraded mode — clearly-AI-attributed extraction served as
`ai_candidate` — remains explicit and unchanged. A register-RESOLVED result
never reaches the gate: authoritative facts win and AI disagreements are
recorded as structured conflicts by the merge, exactly as before.

Enforced in `quarantineUnverifiedAiFacts` (`ingestion/ingest.ts`), called on
the serving path immediately after `discardUnverifiedAiIdentity`. Regressions
R13–R18: unresolved + plausible AI chemistry, ambiguous + plausible AI
chemistry, resolved + AI disagreement (authority wins, conflict recorded),
register unavailable (degraded mode intact), Custodia 320SC, Ridomil Gold.

## 21. Stage LD-1 — official label DOCUMENT discovery + provenance

Implemented 2026-08-20 (NOT yet deployed). Design + audit:
`docs/chemical-label-document-extraction-design.md`. NO rate/WHP/REI
parsing (that is LD-2), NO AI involvement, NO database change, NO Saved
Chemicals or spray-snapshot changes.

For a register-RESOLVED identity only (`ingestion/apvma.ts` →
`resolveDetails`, which unresolved/ambiguous/unavailable outcomes never
reach), `ingestion/label_document.ts` locates the official APVMA label
document:

1. **Confirm** — fetch the PubCRIS portal's own view-label action for the
   exact pcode; the response is a stub whose only payload is a
   `window.location.replace('https://elabels.apvma.gov.au/<pcode>ELBL.pdf')`
   redirect. The redirect is STRICTLY validated: https, the official
   eLabels host, a `.pdf` path naming THIS pcode. Anything else is
   rejected.
2. **Fetch** — download the PDF (one retry on transient failure; 404/410 is
   definitive and never retried), verify the `%PDF` magic bytes, record
   SHA-256 + byte size + retrieval timestamp.
3. **Fallback** — if the portal stub is unavailable, the deterministic
   eLabels URL pattern counts ONLY when the PDF bytes are actually fetched
   and verified (confirmation `document_fetch` instead of
   `pubcris_view_label`). A constructed URL that nothing confirmed is never
   served.

Serving effects (all additive, wire `schema_version` unchanged):

- `registration.label_reference` = the confirmed document URL;
  `field_provenance.label_reference` = `manufacturer_label` — ONLY for the
  exact discovered URL. An AI-supplied URL still reads `ai_interpretation`
  and still goes through the serve-time reachability probe; the
  authoritative URL is NOT re-probed, so an eLabels hiccup can never strip
  authoritative provenance at serve time.
- The `label_reference` unresolved entry clears ONLY on discovery success.
- A `manufacturer_label` source entry records URL + retrieval time + sha256
  ("PDF not retrieved this pass" when only the URL was confirmed).
- Candidates carry `label_reference` (existing sql/199 column, no
  migration); a candidate refresh patch rides a freshly-confirmed URL along
  with an applied material change — additive only, discovery failure never
  blanks a stored reference.

Failure discipline: fail-soft, never fail-closed of identity. Portal
outage, eLabels timeout, non-PDF response or 404 leave the register result
exactly as it stands. One deliberate special case: after the portal HAS
confirmed the URL, a merely-transient document-host failure still serves
the confirmed URL with `document: null` provenance (the hash completes on a
later pass) — the eLabels host measurably drops connections. Transport
cache only (same `SourceCache` discipline, no storage infrastructure):
success 6 h, transient failure 5 min, definitive absence 1 h.

Budget: 6 s per attempt, ≈15 s discovery ceiling, 25 MB document cap; at
most 1 portal + 2 eLabels requests per uncached discovery.

Tests — `ingestion/label_document_test.ts` (LD-A…LD-I + URL-validation
units): Sprayseal 80160 full discovery (sha256 provenance, Stage 4
claims/WHP untouched, candidate carries the reference); Custodia Forte
91636 transient PDF-host failure (URL still resolves, lookup intact,
exactly one retry); definitive 404 (no reference, nothing damaged);
portal-down fallback (verified bytes only); total outage (register result
intact); foreign-host redirect rejected and never fetched;
unresolved/ambiguous outcomes never attempt discovery; cache-fronted;
non-PDF 200 → URL-only provenance. R01–R18 and the full ingestion suite
unchanged: 144 passed / 0 failed.
