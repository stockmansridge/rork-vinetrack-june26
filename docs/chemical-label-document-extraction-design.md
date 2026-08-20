# Chemical Intelligence — official label document extraction (audit & design)

Status: AUDIT/DESIGN ONLY — nothing implemented. Next stage implements against
this document after review.

Goal: when the register's machine-published data does not provide label rates
(it never does — PubCRIS publishes no rate table), extract authoritative
rates, WHP, re-entry and restrictions from the OFFICIAL APVMA-approved label
document for the already-resolved registration identity, with verbatim
provenance for every value, failing closed on any uncertain association.

## 1. What exists today (audited)

- `ingestion/apvma.ts` resolves identity from the PubCRIS register extract
  (data.gov.au CKAN) and already fetches the register-published label data:
  use claims (`produse` × `host` × `pest`) and label statements (`prodcom`).
- `ingestion/label.ts` (Stage 4) turns that into `LabelEvidence`: claims with
  crop/target verbatim, WHP/re-entry parsed by strict patterns from verbatim
  statements, restrictions verbatim. RATES are structurally absent: every
  claimed crop gets a `rates:<crop>` unresolved gap.
- `mergeLabelEvidenceIntoUses` serves the label's claim set; AI rates ride on
  a matching claim attributed `ai_interpretation`, never promoted.
- `labelreg` provides `label_version` ("APVMA label approval NNNNN (date)").
  `label_reference` is ALWAYS unresolved on the register path today.
- The legacy `info` action validates AI-suggested label URLs for
  reachability/shape only — non-authoritative, unchanged by this design.
- Fail-closed identity gate (§20 of docs/master-chemical-ingestion.md):
  document extraction can only ever run downstream of a register-RESOLVED
  identity, so "use the resolved authoritative identity first" is structural.

## 2. Label-document source options (verified in this audit)

1. **APVMA eLabels PDF — RECOMMENDED PRIMARY.**
   `https://elabels.apvma.gov.au/{pcode}ELBL.pdf` — the approved label
   particulars document, keyed by the SAME pcode the register resolved. No
   auth. Discovery is deterministic: the PubCRIS portal action
   `…&_pubcrisportlet_WAR_pubcrisportlet_id={pcode}&…action=viewLabel`
   returns a stub whose only payload is
   `window.location.replace('https://elabels.apvma.gov.au/{pcode}ELBL.pdf')`.
   Verified live:
   - Sprayseal 80160: PDF downloaded (105,253 bytes, 3 pages). DFU table
     contains verbatim: "Grapevines | Eutypa dieback / Botryosphaeria
     dieback | Mix 30 mL of SpraySeal per 100 litres of water | …" — the
     exact missing 30 mL/100 L rate. WHP: "WITHHOLDING PERIOD - NOT REQUIRED
     WHEN USED AS DIRECTED" (parses to 0 days with the existing pattern).
   - Custodia Forte 91636: portal stub confirms
     `https://elabels.apvma.gov.au/91636ELBL.pdf`.
   Caveats (measured): the origin is SLOW/FLAKY — repeated connection drops
   before a successful 200; some older products may have no eLabel (404).
   Both are fail-soft cases, never fail-closed of identity.
2. **PubCRIS register extract (existing Stage 4)** — stays the authority for
   WHICH uses exist (claim set) and for statement-parsed WHP/re-entry. The
   document layer may only ATTACH detail to claims, never mint new claims.
3. **PubCRIS product print-preview PDF** (`generateProductPrintPreviewPdf`)
   — register summary render; its "Directions for Use" is a file-attachment
   reference, not the table. Not useful; rejected.
4. **Manufacturer sites / third-party mirrors** (Infopest, agrobase, brand
   sites) — NOT official, non-deterministic. Remain what they are today:
   AI-suggested references validated for reachability only, or
   admin-attached at review. Never authoritative.

## 3. Recommended extraction architecture

New module `ingestion/label_document.ts`, pure functions, injected fetch
(same testing discipline as the rest of the resolver). Two sub-stages that
can ship independently:

**Stage LD-1 — document discovery + provenance (no parsing):**
- `discoverLabelDocument(deps, pcode)` → probe the eLabels URL (GET, ranged
  or full), fall back to parsing the portal `viewLabel` stub if the direct
  pattern ever 404s while the stub points elsewhere (future-proofing).
- Returns `{ url, retrieved_at, byte_size, sha256 }` or null (fail-soft).
- Serving effect: `registration.label_reference` = document URL (clears the
  `label_reference` unresolved gap), plus a `manufacturer_label` source
  entry "APVMA-approved label document (eLabels) — product {pcode}" with
  reference = URL and the sha256 recorded for reproducibility.

**Stage LD-2 — text extraction + deterministic DFU parsing:**
- PDF → text in the Supabase Edge (Deno) runtime with a pure-JS extractor
  (`unpdf`, the serverless pdf.js build; npm: import — no native deps).
  Measured reality: the text layer fragments table cells across lines
  ("Mix 30 mL of / SpraySeal per / 100 litres of / water"), so parsing is a
  reassembly grammar, not line matching.
- `parseDirectionsForUse(text)` — deterministic, bounded grammar:
  - locate the DIRECTIONS FOR USE section and its column header (CROP |
    DISEASE/PEST | RATE | CRITICAL COMMENTS variants);
  - segment rows; a row keeps `{ crop_text, target_texts[], rate_texts[],
    comments_text }` all VERBATIM;
  - rate grammar over bounded label forms only: "N mL/L/g/kg per 100 L(itres)",
    "N–M …/100 L", "N L/ha", "N g/ha", ranges, "per 100 litres of water"
    wordings → `{ basis, value|min/max, unit, raw_text }`. Anything the
    grammar cannot parse is carried as `basis:"other"` with `raw_text` only
    (a verbatim quote is deterministic; a numeric guess is not).
- `bindDfuRowsToClaims(rows, claims)` — THE fail-closed join. A row's rates
  attach to a register claim only when `cropsCorrespond` AND at least one
  target corresponds (`targetsCorrespond` — both already exist in label.ts
  and are regression-pinned). Ambiguity of any kind — crop matching multiple
  claims inconsistently, unmatched crop text, a rate cell spanning
  non-corresponding crops — serves NOTHING for that row: the `rates:<crop>`
  gap remains and the verbatim row is preserved in an `unbound_rows` audit
  list. AI never breaks these ties.
- WHP / re-entry / restrictions from the document are parsed SEPARATELY with
  the SAME strict statement patterns already in label.ts. Where the register
  statements already state a value, the document is corroboration — any
  disagreement is a recorded conflict (both sides manufacturer_label, so it
  goes to review, never silent). Where register statements are silent, a
  document-parsed value may fill, attributed `manufacturer_label` with the
  document reference. Restrictions/critical comments append verbatim to
  claim statements, never paraphrased.
- Merge order in `mergeLabelEvidenceIntoUses`: document rates (with
  provenance `manufacturer_label`) now outrank AI rates on the same claim;
  an AI rate that disagrees becomes a structured conflict; AI rates survive
  only on claims the document gave no rates (still `ai_interpretation`).
- AI's ONLY optional role: reading the same extracted text to produce
  non-authoritative binding SUGGESTIONS for admin review (advisory
  envelope). A suggestion can never create, alter, or promote a value.
  Stage LD-2 works with zero AI involvement.

**Operational discipline:**
- Runs only after `outcome: resolved`; never on unresolved/ambiguous (§20
  gate) — no document fetch can even be attempted for an unverified identity.
- Fail-soft budget separate from the register's 8s per-call timeout: one
  attempt + one retry, ~15s ceiling, cached in `SourceCache` under the
  resolved identity with `RESOLVED_TTL_MS` so the flaky origin is hit rarely.
- Refresh: `labelClaimsSignature` extends to include bound rates; a changed
  document (sha256 or parsed-rate signature) surfaces as `material_change`
  with old/new diffs; apply patches CANDIDATES only (existing discipline).
- Saved Chemicals and historical spray snapshots: untouched. This layer
  lives entirely in the lookup/candidate/refresh path; approved master rows
  change only through the existing human-reviewed refresh/approve flow.

## 4. Contract changes required (all additive; NO breaking change)

- `LabelUseClaim.rates?: WireRate[]` — same rate shape as
  `registered_uses[].rates`; every entry carries verbatim `raw_text`.
- `LabelEvidence.document?: { url, sha256, byte_size, retrieved_at,
  extraction: "pdf_text_layer", parser_version }`.
- `LabelEvidence.unbound_rows?: Array<{ crop_text, target_texts, rate_texts,
  comments_text }>` — verbatim audit of fail-closed rows (serving path may
  omit it from the wire response; it is candidate/review material).
- `registration.label_reference` populated on the register path (field has
  existed since sql/194; today always null there).
- Per-use `provenance.rates` gains the value `manufacturer_label`;
  `field_provenance.label_rates` reads `manufacturer_label` when any served
  rate is document-backed.
- New `manufacturer_label` source entries (document URL + sha256).
- `schema_version` stays 1 — additive keys only; both apps' decoders ignore
  unknown keys (established Stage 3/4 behaviour).

## 5. Proposed tests (deno, hermetic — parser fixtures are EXTRACTED TEXT)

Regressions R01–R18 must stay green untouched. New LD series in
`ingestion/label_document_test.ts` (+ resolver wiring cases):

- LD01 Sprayseal 80160 (captured text fixture): DFU parses to one row —
  Grapevines × {Eutypa dieback, Botryosphaeria dieback}, rate "Mix 30 mL of
  SpraySeal per 100 litres of water" → binds to BOTH register claims as
  `{ basis: per_100_litres, value: 30, unit: mL, raw_text: verbatim }`;
  `rates:GRAPEVINE` gap cleared; `label_reference` = eLabels URL;
  `provenance.rates = manufacturer_label`; WHP stays 0 from the register
  statement; unresolved↔provenance coherence invariant holds.
- LD02 Custodia Forte 91636 (fixture once captured): multi-crop DFU with
  dilute + concentrate grape rates → both bases served on the grape claims
  only; no cross-crop leakage; variant guard untouched.
- LD03 document rate vs AI rate disagreement → document served, structured
  conflict recorded (ai_interpretation vs manufacturer_label).
- LD04 DFU row for a crop with NO corresponding register claim → nothing
  served, row lands verbatim in `unbound_rows`, claim gaps unchanged.
- LD05 ambiguous binding (one row corresponding to multiple claims with
  conflicting rate cells) → nothing served, gaps remain.
- LD06 unparseable rate wording → `basis:"other"` + verbatim `raw_text`
  only; numeric fields null; never a guessed number.
- LD07 document unavailable (404 / timeout / non-PDF bytes) → response
  byte-equivalent to today's Stage 4 output; `label_reference` stays
  unresolved; no invented values (fail-soft pinned).
- LD08 no-AI-promotion pinned: without document rates, AI rates keep
  `ai_interpretation` and never satisfy `rates:<crop>` gaps.
- LD09 refresh: changed parsed-rate signature / sha256 → `material_change`
  with old/new summaries; identical → `no_material_change`; apply patches
  candidates only.
- LD10 injection resistance: instruction-like text inside the DFU is inert —
  the authoritative path contains no AI.
- Live verification script: extend
  `scripts/verify-chemical-lookup-production.ts` to print `label_reference`,
  document sha256 and served rate provenance for the 5-product regression
  set (Sprayseal must show the 30 mL/100 L rate as manufacturer_label).

## 6. Database migration — NOT needed for this stage

`master_chemicals` (sql/199) already carries everything this layer produces:
`label_reference` (document URL), `label_version` (approval record),
`registered_uses` jsonb (rates + per-use provenance + verbatim raw_text ride
inside), `verification_sources` jsonb (document source entry with sha256 in
its reference), `verification_unresolved_fields`, and the approval gate
already accepts `manufacturer_label` provenance. The catalogue history
trigger snapshots these columns, so document-driven changes are versioned
for free.

The only thing that WOULD need storage is whole-document raw-text archival.
Out of scope by design: URL + sha256 + verbatim per-value `raw_text`/
statements give reproducibility. If full-text archival is wanted later, it
should be a Storage bucket (not a table) and a separate decision.

Deployment: adds the `unpdf` npm import to the function bundle; same
`supabase functions deploy chemical-info-lookup` flow; no SQL to run.
