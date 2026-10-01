# Weedmaster revision-2 coordinated release handoff

## 2026-10-01: international Master identity correction (not deployed)

This correction supersedes the registration-required candidate request below. **`master_chemical_id` is the primary VineTrack identity. Country is jurisdiction context. Registration scheme/number are optional evidence, never a prerequisite and never invented from an adapter.**

Exact candidate hydration (authenticated current System Admin session Bearer token required):

```json
{
  "action": "structured_master_preview",
  "master_chemical_id": "03dfb9e8-6592-4746-a3bc-295890d32cd1",
  "country": "AU"
}
```

Exact approved hydration through the existing structured action (no productName required for this path):

```json
{
  "action": "structured",
  "master_chemical_id": "03dfb9e8-6592-4746-a3bc-295890d32cd1",
  "country": "AU"
}
```

The approved request above will not serve the actual Weedmaster candidate. Only an approved exact row is customer-serviceable. When populated, optionally include `registrationScheme` and/or `registrationNumber` (camelCase request keys); each supplied nonempty hint must independently match its corresponding persisted field, including schemes without a wired adapter. Omitted, null or blank registration hints do not block hydration. Supplied non-text metadata is a 400.

Both exact paths read by ID and required status, verify returned ID/status, validate populated row country using the existing canonical country resolver, and validate every supplied registration hint. A complete persisted `registration_identity_key` is additionally checked against its own populated country/scheme/number; it is preserved in `master.registration_identity_key` and never fabricated. Missing registration metadata is not an identity failure. Response metadata remains under `registration.country_code`, `registration.scheme`, `registration.registration_number`; jurisdiction context is the existing `jurisdiction` envelope. Master ID/revision/status remain under `master`. The candidate response retains the explicit read-only/not-approved `admin_preview` marker.

Neither exact path falls through to another product, online discovery, register lookup, manufacturer/PDF/AI work, enrichment or writes on failure. Both work without an OpenAI key and have an eight-second shared network deadline. Missing exact row is 404; mismatched ID/country/status/supplied registration is 409; invalid ID or missing/unresolvable country is 400; unavailable read or incomplete canonical rates is 503 (`catalogue_preview_unavailable` for candidate, `catalogue_hydration_unavailable` for approved). Candidate authentication and current-admin failures remain 401/403.

The shared readiness gate no longer requires a registration number. Existing retained-label evidence and persisted operational-rate identities still protect rates. Exact hydration can also serve a reviewed input with no calculable vineyard rates and no label, provided it has no unresolved vineyard-rate gap; it returns empty options, not invented rates. Product category is retained unchanged, with no pesticide-only gate. No rate/direction IDs are minted. Existing name-only discovery and register-adapter behaviour are not redesigned in this correction.

**Lovable handoff (Portal source absent here):**

- Remove registration-number/country prerequisites from selected Master hydration. Send the selected exact Master ID and the canonical product/vineyard country. Candidate + System Admin uses `structured_master_preview`; approved uses `structured` with that ID.
- Include each registration hint only when populated. Never infer APVMA, ACVM or another scheme.
- Always validate `master.master_chemical_id` against the selected ID and country/jurisdiction consistency when populated. Compare number/scheme when present on both sides; absence alone is not failure. Preserve existing metadata and canonical default-rate options.
- Use VineTrack's supplied canonical country values and backend `jurisdiction` envelope, not an AU/NZ-only Portal map. Unknown country never becomes Australia. Existing backend country resolution already supports AU, NZ, US, GB, FR, IT, ES, ZA, CL, AR, CA and other vineyard countries/ISO-2 contexts regardless of adapter availability.
- Keep the existing grouped options, persistence fields and Retry/manual/Back failure UX specified below. No Portal UI execution or save/reopen acceptance is claimed by these backend tests.

Focused coverage adds synthetic, disposable international row variants for AU/APVMA, NZ/ACVM, FR without registration, US/EPA metadata, ZA without an adapter, and unregistered fertiliser/biostimulant products, each through candidate and approved exact handler paths. It covers omitted hints, supplied mismatches, exact-ID/status/country mismatch, no-rate/no-label inputs and failure without fallback, while the unchanged actual Weedmaster fixture protects 70 directions and 9 + 8 grouped options. These synthetic variants are not production catalogue claims or new extraction evidence.

Validation: **23 tests passed, 27 handler substeps passed, zero failures** across `master_candidate_preview_test.ts`, `weedmaster_catalogue_release_test.ts`, and `master_default_identity_test.ts`. Targeted `deno check` passed for the handler, shared Master module and modified contract tests; `git diff --check` passed. No broad build ran.

Changed code: `supabase/functions/chemical-info-lookup/index.ts`, `ingestion/master_lookup.ts`, and `master_candidate_preview_test.ts`. Only the existing handoff is updated. No production data changes, approval, deployment, SQL, broad/mobile build or Portal source changes occurred. Prior preview implementation is now recorded in Rork commit `e3288b7abbed4d538afbda7506cc104d9d0677ac`; the current international correction's commit is pending automatic sync at the time of this edit.

## 2026-10-01: exact candidate hydration repair (not deployed)

Root cause of the reported live minute-long hydration: ordinary `structured` serving queries approved rows only; the selected candidate misses that read and enters the existing discovery/enrichment path. The Portal's flattened-rate fallback then presents 137 rate entries instead of canonical options. No Master correction, extraction or apply is needed.

New read-only action on `chemical-info-lookup`, with the caller's authenticated session Bearer token:

```json
{
  "action": "structured_master_preview",
  "master_chemical_id": "03dfb9e8-6592-4746-a3bc-295890d32cd1",
  "country": "Australia",
  "registrationScheme": "apvma",
  "registrationNumber": "53576"
}
```

The server verifies the session through Auth and checks the existing authoritative `is_system_admin()` RPC using the CALLER's JWT, never the service role. Only then does it read `master_chemicals` by exact ID with candidate status. Returned ID and candidate status must match; populated country and supplied optional registration hints are validated under the international correction above. It uses `buildMasterStructuredResponse` and `applyDefaultRateOptions`, without minting a second contract or changing the candidate. The response has the existing `master` linkage and an explicit `admin_preview: { read_only: true, catalogue_status: "candidate", approved_for_customer_use: false }`. Master serving remains approved-only for `structured`; its additive exact-ID hydration path is specified above.

The preview has one shared eight-second network deadline across session verification, current-admin check and DB read. It never enters manufacturer discovery, AI, PDF fetch/parsing, cache writes or Master writes, and works without an OpenAI API key. Missing candidate returns 404; identity mismatch 409; failed/incomplete canonical hydration 503 with `catalogue_preview_unavailable`, never an enrichment fallback.

Focused local validation: **9 tests plus 11 preview substeps passed**, TypeScript check and whitespace validation passed. The final mocked success measured **15.98 ms** for the handler response, with exactly Auth GET → admin RPC POST (read-only check) → exact Master GET. This is not live latency; the supplied live one-minute issue remains unverified/unrepaired in deployment until the new function and Portal call are delivered.

Actual unchanged full-row fixture: **70 Vineyard directions**, **66 /ha + 71 /100 L flattened rate entries**, **9 /ha + 8 /100 L canonical options**. These are the existing producer's options, not newly grouped Portal rows. Example target summaries (first three supplied names, exact remaining counts):

- 2–3 L/ha — Boom: Amaranth, Barley grass, Barnyard grass **+32 more**.
- 6 L/ha — Boom: Johnson grass, Kangaroo grass, Kikuyu grass **+9 more**.
- 3–6 L/ha — Boom: Phalaris.
- 500–700 mL/100 L — Handgun: Amaranth, Barley grass, Barnyard grass **+32 more**.
- 500–1000 mL/100 L — Handgun: Phalaris, canonical key `default_option_v1_5f58b1d9f422213e1ecf8632036c1356`, unchanged rate/direction IDs below.

**Lovable implementation and tests remain outstanding here (Portal source absent):**

- Candidate System Admin selection calls this action, validates returned Master/registration/revision linkage and uses `default_rate_options` as the primary radio UI. Ordinary users continue using approved structured serving.
- One radio per backend option, separate /ha and /100 L sections; do not regroup/mint keys or select individual flattened weed rows. Keep candidate/not-approved labelling visible.
- Show the first three `targets` and `+ N more`; Show all expands the complete supplied list. Retain all supplied condition wording and target-specific restrictions in supporting direction evidence; some existing Handgun options aggregate multiple qualified condition strings, so do not imply every condition applies to every listed target.
- Canonical options already use `isGrapevineCrop`; keep other-crop and excluded/reference-only methods out of selectable defaults. Do not add another Portal crop parser.
- Failed hydration shows: "Catalogue rate details could not be loaded. Try again or enter a rate manually." with Retry, Enter rate manually and Back. Never turn `viticulture_rates` or flattened registered uses into a selectable fallback.
- Copy backend option identity/amount/rate IDs into the existing saved-selection contract; retain direction/conditions for display, not a new persistence format. Prove candidate hydration, grouped/count/collapse/expand display, Phalaris selection, exclusions and failure recovery through focused Portal tests.

Changed implementation: `supabase/functions/chemical-info-lookup/index.ts`; new focused tests: `master_candidate_preview_test.ts` in the same folder. No production lookup/write/approval, deployment, SQL, re-extraction/apply, source-order change or mobile/broad build occurred. The current pre-change Rork HEAD observed here is `a6d48479561ddbe014525572e95dffb6691ccccb`; this repair's synced commit is not yet available within this turn. Lovable's last supplied commit remains `830f68da6d6fcdadf2a1aa4a495f5ccbf46fd53b`, not independently verified or claimed to contain these UI changes.

The sections below retain earlier approved-clone release evidence; they do not supersede the candidate preview authorization boundary above.

## Scope, ownership and evidence

Master `03dfb9e8-6592-4746-a3bc-295890d32cd1`, `AU:apvma:53576`, revision **2**, **candidate**, **partially_verified**.

This acceptance supersedes the earlier synthetic release fixture. The supplied actual applied snapshot SHA-256 is `6daee0d6d2502a897cac988123ead3f6a1db07ec3f75ad5032be6ed40ac4c3a6`. Tests ran against those original bytes privately, with no rate, chemistry, source-order or metadata substitutions. Only a local clone's `review_status` is changed for the hypothetical approved request. The original remains candidate and deeply unchanged. The package's existing eight-field comparison is supplied evidence, not a fresh database query by Rork.

For reusable repository tests, `revision-2-shared/master-revision-2.sanitized-fixture.json` retains the entire row, all amounts, timestamps, hashes, versions and source ordering; ONLY `verification_sources[6].reviewed_visual_declaration.reviewed_by` is replaced by an explicitly test-only redaction. `sanitize_release_fixture.ts` verifies the original byte hash and proves that reversing that one substitution reproduces the entire original object. The actual private snapshot is not retained in repository tests or submitted as new review evidence.

**Lovable owns** Portal raw-table/RPC readers, review drawer, release eligibility and customer selection/save/reopen. **Rork owns** approved-Master serving and its retained-evidence rules. This handoff specifies the shared contract; an Edge Function deployment does **not** repair direct table/RPC readers. No Portal source transport from Jonathan is required. Portal code was not available/executed here, so its actual displayed-option → selection → save → adapter result is **pending Lovable acceptance**, not asserted by backend tests.

No extraction, preparation, Master apply, production read/write/approval/lookup, SQL, SQL 257, deployment, media staging, mobile changes/builds or broad suites occurred.

## Rork actual-input result

Eight focused release tests pass against both the original private snapshot and the reviewer-redacted full derivative:

- All **582 registered-use records** survive: **512 other-crop** and **70 Vineyard directions**.
- Both canonical flattened collections survive verbatim: **66 per-hectare**, **71 per-100-litre** entries. The canonical option producer yields **9 per-hectare** and **8 per-100-litre grouped options**, not 137 independent choices.
- All **seven verification sources**, in their original order, and **all 32 unresolved entries** survive the served JSON, as do restrictions, source references, chemistry and empty conflicts. Partial verification remains partial.
- Manufacturer resolution skips the two `data.gov.au` API references at zero-based indexes **3 and 4**, even though they are tagged `manufacturer_label`, and selects the reviewed Nufarm PDF at index **6**. The API references remain evidence; they are not manufacturer-document links.
- The actual `index.ts` structured handler serves a hypothetical approved clone using exactly **one mocked GET** to `master_chemicals`, with the approved and registration-identity filters. All other HTTP requests and all writes fail the mock. No discovery, enrichment, document fetch or extraction is entered; diagnostics identify `master_catalogue`.
- Candidate queries do not return an approved customer hit. Admin inspection of a candidate is a different boundary and must remain available under existing permissions.
- Missing eligible rate identity and an injected `RATES:GRAPEVINE...` gap still fail readiness. Untrusted/SDS/product-page/non-HTTPS and mismatched visual sources still fail the retained-source gate. Those negative cases mutate disposable clones only.
- The canonical Phalaris option survives a local persistence-shaped JSON round trip through the existing `validateDefaultRates` reader, with zero violations. Empty `rate_ids` and source `manual` are rejected by that shared contract. This is **not** execution of a Portal save builder, database save, RPC adapter or UI.

No production runtime claim follows from mocked acceptance. In particular, the fast-path diagnostic event's `unresolved_count` is not a completeness checklist; acceptance asserts the actual response's full 32-entry warning array.

## Precise trusted-label read contract for Lovable

### Raw row / RPC reader

Do not use `verification_sources.find(kind === 'manufacturer_label')` alone. Retain every source unchanged, but qualify a **manufacturer document** with the same Rork rules:

1. `kind === 'manufacturer_label'`, string reference, HTTPS.
2. `manufacturerHostEligible(reference, registration_country, registrant)` succeeds. Existing `research/classify.ts` requires an eligible registrant host or domain matching the locked registrant; it rejects government/foreign regulator and untrusted reseller hosts. Do not replace this with a substring match on the brand or URL.
3. `classifyUrl(reference, country)` is not `safety_data_sheet`; it is a `label_document` or its URL pathname ends in `.pdf`. A product page, data API or SDS does not qualify.
4. If a `reviewed_visual_declaration` exists, it must bind to exactly this URL, carry a lowercase 64-hex SHA-256, method `human_visual_transcription`, a nonempty reviewer and parseable review timestamp. This reads existing provenance; it does not fetch, attest again or require a candidate to be approved before an admin can inspect it.
5. Choose the first **qualified** retained document, not the first source-kind claim. Preserve source ordering in evidence, rather than sorting the Nufarm PDF to the front to make a test pass.

On this row, the resolved URL is:

`https://cdn.nufarm.com/wp-content/uploads/sites/22/2018/05/13085258/0533-Nufarm-Weedmaster-DUO-Herbicide.pdf`

Reviewed PDF hash: `69213c077e191e99682e515884d7667156367ea7ab927ecdac2882f4d0ec39b8`.

`masterLabelTargets` and `resolveChemicalLabelLinks` must agree on that document. Reading raw table/RPC data requires this compatible read-only resolution in Portal; no serving-envelope change implicitly updates it. Do not mutate the stored null label projections or introduce discovery.

### Served envelope and version separation

`resolveMasterLabelEvidence` in `ingestion/master_lookup.ts` already implements the retained-source fallback. For this exact row, serving returns:

- `label_urls.manufacturer_label_url` and `registration.manufacturer_label_url`: Nufarm PDF above.
- `registration.label_reference`: that PDF; `label_urls.regulator_label_url`: null.
- `registration.label_version`: null, avoiding assignment of unrelated register metadata to the newly resolved PDF.
- `registration.stored_register_label_version` and `label_evidence.stored_register_metadata.label_version`: **APVMA label approval 141445 (13/12/2023 12:00:00 AM)**; its stored document reference is null.
- `registration.manufacturer_label_version`: **08-09-2022**.
- `label_evidence.reviewed_manufacturer_document`: the complete matching source at index 6.
- `label_evidence.same_label_version_established`: false.
- Original `verification.sources`: all seven sources; original `viticulture_rates`: passed through, not rebuilt.

The approval metadata is not a regulator PDF URL, nor evidence that both document versions are equivalent. Show it separately, even without an openable register document. Existing top-level/legacy label compatibility remains unchanged; the trusted retained-source fallback is not permission to trust arbitrary URLs.

## Release eligibility versus completeness

### Actual record / inspected policy results

| Check | Actual revision-2 result | Release meaning |
|---|---|---|
| Registration identity | AU / apvma / 53576, consistent product Master | No identified identity blocker; do not reinterpret noncanonical printed 136340 as the product identity |
| Chemistry | 360 g/L glyphosate register constituent and retained cover declaration; group G, classified | Present; keep existing chemistry/classification validation |
| Authoritative provenance | `source_kind=official_register`; register sources retained | Satisfies SQL 199 approved-provenance constraint |
| Trusted retained document | Correct index-6 Nufarm PDF, hash-bound existing review | Present; empty top-level label projections are not a reason to enrich |
| Verification conflicts | `[]` | No conflict item in this snapshot to adjudicate; keep conflict/identity guards for other records |
| Operational identities | Eligible rates pass the existing producer's readiness inspection | No missing eligible-ID blocker here |
| `RATES:GRAPEVINE...` gap | None among the actual 32 entries | No current vineyard missing-rate fast-path blocker |
| Catalogue status | candidate | **Genuine customer-release gate:** human catalogue approval has not occurred |
| Portal `masterIssues` all-or-nothing gate | Reported by Jonathan: `approveWithCorrections` blocks any entry | **Portal implementation blocker:** completeness warnings must be classified, not all treated as release blockers |

SQL 199's `master_chemicals_approved_provenance_check` requires official-register or manufacturer-label source provenance. It does not require `verified` status or empty warning arrays. Rork `masterHasCompleteVineyardData` requires a registration number, resolved label reference, no `RATES:GRAPEVINE` prefix and eligible rate identities. These are inspected rules, not a complete replacement for Portal identity, chemistry, evidence or conflict checks. No broad bypass should be added.

Lovable must connect its existing legitimate manual release action to a separate policy decision, with exact blocking item/rule if any of its remaining checks fails. Keep save-before-approve, successful read-back, current-row/revision check and drawer-lock protections. Do not auto-approve, clear issues, declare full verification, replay the completed apply, or change rates to satisfy a checklist.

### Exact retained warning accounting

The exact strings are retained in `revision-2-shared/focused-release-evidence.json::retained_unresolved_fields` and the full fixture. All **32** remain warnings/exclusions under the inspected vineyard-serving policy:

- **10 other-crop rate gaps** and **10 other-crop withholding gaps**, for the same ten situations: BLUEBERRY OVER 3 YEARS OLD; CHICKPEA - SEE LABEL; CITRUS FRUIT - OVER 3 YEARS OLD; POME FRUIT, OVER 3 YEARS OLD; RASPBERRY OVER 3 YEARS OLD; RICE - DIRECT DRILLING; SORGHUM - POST-HARVEST; SORGHUM - PRE-HARVEST; SUGAR CANE; SUGAR CANE - RATOON CROP. These are not Vineyard directions and must not be offered as Vineyard defaults.
- **2 re-entry entries:** global `re_entry_period_hours` and the qualified GRAPEVINE unknown-hours warning. Unknown is not zero.
- **2 Paspalum entries:** shared-comment relationship unconfirmed, and the detailed rates-withheld warning. Do not offer Paspalum rates.
- **3 unsupported-calculator entries:** Wiper mixture, Knapsack /15 L, controlled-droplet delivery/device table. Retain label information; no /ha or /100 L default conversion.
- **2 unestablished Vineyard-method entries:** Bamboo cut-stump and Pampas low-volume. Excluded methods, not newly allowed uses.
- **3 unestablished aquatic/wetland-situation entries:** Cumbungi, Ludwigia peruviana, Phragmites/Common reed. Excluded situations, not Vineyard calculator options.

No exact retained warning is a `RATES:GRAPEVINE` missing-rate entry, and none of these automatically blocks the whole product under the inspected Rork/SQL rules. Whether release with those visible limitations is acceptable remains Jonathan's human decision. The exact set of additional Portal-generated `masterIssues` and its resulting policy decision cannot be claimed without Lovable's execution result.

## Canonical option → selection → save/read-back contract

The authoritative producer is `default_rate_options.ts::buildDefaultRateOptions(registered_uses)` / `applyDefaultRateOptions`. It reads eligible registered directions, not both directions and flattened rates. Range bases fold onto their corresponding operational slot without changing their numbers or units. Existing producer-owned `option_key` and supporting `rate_ids` must be copied, never invented by Portal. Conditions/targets/directions must stay available for display and deliberate selection.

A direct table/search RPC returns stored fields, not automatically the Edge Function's `default_rate_options`. Lovable must explicitly consume the existing canonical options or share the existing producer contract at its read boundary. Do not create a new discovery flow or another client-owned grouping/key scheme. For a flattened rate, join its persisted `rate_id` (or preserved `source_id` representing that same ID) to `registered_uses[].rates[].rate_id`, then its owning `direction_id`, conditions, restrictions and target. The actual flattened Phalaris row contains **no** `target_raw`, `direction_id` or method field; `label=Handgun` and `source_refs` are present. No positional joins or new identities.

### Actual option, produced from this snapshot

```json
{
  "option_key": "default_option_v1_5f58b1d9f422213e1ecf8632036c1356",
  "rate_ids": ["rate_v1_4efec198ead373a3286939ced245fadf"],
  "basis": "per_100_litres",
  "unit": "mL",
  "value": null,
  "min_value": 500,
  "max_value": 1000,
  "direction_ids": ["direction_v1_1363f3205ca7b639cd5f970a03d91785"],
  "targets": ["Phalaris"],
  "conditions": ["Handgun"],
  "crops": ["Vineyards"],
  "condition_ambiguous": false
}
```

The full owning direction retains its Winter–Spring / lower knockdown versus higher long-term-control wording and all Vineyard shielding, vine-age, drift, disturbance, growing-condition and rainfall restrictions. Option `conditions` is the rate label; it is not a replacement for full direction conditions/restrictions. Rehydrate them through the identities on reopen.

### Local canonical persistence fragment that passed shared read-back

```json
{
  "master_chemical_id": "03dfb9e8-6592-4746-a3bc-295890d32cd1",
  "master_source_revision": 2,
  "default_rates": {
    "version": 1,
    "per_hectare": null,
    "per_100_litres": {
      "option_key": "default_option_v1_5f58b1d9f422213e1ecf8632036c1356",
      "rate_ids": ["rate_v1_4efec198ead373a3286939ced245fadf"],
      "basis": "per_100_litres",
      "unit": "mL",
      "value": null,
      "min_value": 500,
      "max_value": 1000,
      "source": "operator",
      "selected_at": null,
      "label_version": "08-09-2022"
    }
  }
}
```

This is a **backend shared-contract fragment**, not an observed full Portal request. The test chooses that option explicitly, copies its semantic fields, performs JSON serialization and reads `default_rates` with the existing validator. Result: zero violations, same key/IDs/basis/unit/range. The document-version provenance here is explicitly the reviewed manufacturer PDF, not the APVMA approval metadata. The test leaves `selected_at` null instead of inventing a historical selection timestamp; the real user action may supply its current selection time.

D3 persistence stores `rate_ids`, not display-only `direction_ids`, targets or conditions. Keep those relationships accessible via the stored authoritative directions; do not extend the saved structure just to keep presentation metadata. Do not rewrite authoritative chemistry or automatically choose among ambiguous options. Preserve the other basis if the customer already has a selection.

`source='operator'` describes a deliberate operator selection of a canonical option. It is not a claim that the label was manually invented. Allowed D3 sources are `operator` / `recommended`, not `manual`. Product-level catalogue provenance must separately remain Master-linked through existing Portal save fields/adapters. Jonathan reports Portal `selectionFromMasterRate` still emits empty IDs and marks selections manual: **that actual Portal result remains defective/unverified here**, regardless of successful normalization or backend validation.

**Lovable's remaining required focused acceptance:** actual raw Master/RPC shape → displayed identity-bound option → explicit selection → existing save builder/payload → mocked successful save response → existing read-back/reopen adapter. Verify the exact key/IDs and source fields above, range, direction restrictions, both basis slots, retained warnings, and no unsupported choices. Do not stop at `normaliseMasterSearchHit`. Report the actual full Portal payload/read-back result and delivered Portal commit.

## Checks executed and changed files

- `weedmaster_catalogue_release_test.ts`: **8 passed** with original private snapshot; **8 passed** with the full reviewer-redacted derivative. No runtime env/network/write permission granted; handler env/fetch/serve mocked.
- Local importer hash/deep-equality check: passed; only reviewer identity redacted for repository fixture.
- `deno check supabase/functions/chemical-info-lookup/index.ts docs/weedmaster-acceptance/sanitize_release_fixture.ts`: **passed** affected backend/tool validation.
- `git diff --check`: **passed** final whitespace validation.

Reproduce the repository-fixture check with:

```sh
deno test --cached-only --allow-read="docs/weedmaster-acceptance/revision-2-shared/master-revision-2.sanitized-fixture.json" "supabase/functions/chemical-info-lookup/weedmaster_catalogue_release_test.ts"
```

For byte-identical private input, grant read permission only to its local path and append `-- /path/to/master-revision-2.applied-snapshot.json`. The test verifies the original SHA-256 before running. Backend Deno checks are the active validation surface; no app `runChecks`/build or publishing tool is needed for this backend-only acceptance.

This turn changes the focused release test, this handoff, the full sanitized fixture/importer and supplied non-personal evidence notes. The serving resolver itself needed **no further correction** for the actual snapshot; it correctly rejected the earlier API sources. No Portal files or native app sources changed.

## Delivery and Jonathan's next actions

Confirmed existing Rork delivery: **`58f093399f548128282fccac0c1c08f84d6edf0d`**, retained-label readiness/serving and initial release tests. Earlier Phalaris acceptance: **`81a612aac86e6c7fea218bfbf96ba029d5455b40`**. The attachment records Portal reference **`5ee63d2411651dc638d462c6126788726ee3a9de`**, but that is supplied context, **not a verified delivery of the remaining Portal fixes**. The actual-snapshot tests, full sanitized fixture/importer and handoff are now confirmed delivered in **`1b084a8a083ce9899fe536abc0c77066e2c6a717`**. No manual commit/push was performed. On this follow-up, the original attachment was restored privately after the temporary copy was unavailable; its byte-hash assertion and all eight tests passed again, as did the eight derivative-fixture tests, affected backend/tool type checks and whitespace check. No additional serving change was required.

After Lovable completes and reports all three boundary fixes and its focused acceptance:

1. **Deploy exactly:** Lovable's Portal bundle containing trusted raw-row label resolution, release-policy separation and identity-preserving selection/save/read-back; and Rork's **`chemical-info-lookup` Edge Function with its full imported module graph**, including the delivered `ingestion/master_lookup.ts` change. Do not paste only `index.ts`, deploy test/private fixture files, run migrations, rebuild mobile apps or replay the Master apply. No deployment has occurred in this task.
2. **Approval action:** Jonathan, as authorised system admin, opens the existing Master review drawer for **AU:apvma:53576** and uses its existing catalogue approval action handled by **`approveWithCorrections`**, after Lovable has connected its legitimate manual release policy. Preserve save-before-approve/read-back/drawer lock and check the current identity/revision/status. For unchanged applied data, do not fabricate corrections or a new reviewer attestation. This is catalogue approval of the existing candidate, **not** `master_review_apply`, extraction approval, full verification, media approval or SQL. If that action still blocks, stop and obtain the exact blocking item/rule from Lovable; do not work around it with a direct production write. Jonathan's release decision remains separate.
3. **One ordinary-customer check:** search/select Weedmaster identity 53576; see both supported bases; deliberately select **Phalaris / Handgun / 500–1000 mL per 100 L**; save, close and reopen through the ordinary customer path. Confirm the same option key, supporting rate identity, range, Master link/revision, direction restrictions and warnings remain; the PDF opens as Nufarm version 08-09-2022 while APVMA approval metadata is separate; excluded methods/situations are not offered. The structured fetch should be `master_catalogue`, without discovery/enrichment. Do not auto-select an ambiguous direction.

The coordinated release is **not fully accepted** until Lovable supplies its exact policy-blocker result and end-to-end Portal save/reopen evidence. Rork's actual-snapshot serving acceptance is complete.
