# Weedmaster catalogue release and customer-selection handoff

## Status and scope

Master `03dfb9e8-6592-4746-a3bc-295890d32cd1`, identity `AU:apvma:53576`.
The supplied live-state description is revision **2**, review status **candidate**, verification status **partially_verified**. The already-applied Master content was not prepared, extracted, enriched, applied again, or changed.

This is a local engineering handoff, **not approval or a real reviewer attestation**. The regression fixture reuses the complete retained synthetic report's serialized directions and sources, with the supplied revision/status/identity metadata. It is a revision-2-shaped reconstruction, not a fresh database export. The test's register-version string is deliberately fictional, so it cannot be confused with the manufacturer PDF's version. The synthetic reviewer remains explicitly test-only.

## Changed files

- `supabase/functions/chemical-info-lookup/ingestion/master_lookup.ts`: one read-only retained-label resolver is shared by readiness and serving. It uses the existing `classifyUrl`, `manufacturerHostEligible`, and `selectLabelReferences` rules. Manufacturer sources must be label documents/PDFs on eligible HTTPS manufacturer hosts, never SDS/product pages, reseller hosts, or regulator URLs mislabelled as manufacturer evidence. When visual evidence exists, its URL, SHA-256 shape, method and reviewer/date metadata must remain bound to that source. No document is fetched or re-attested.
- `supabase/functions/chemical-info-lookup/weedmaster_catalogue_release_test.ts`: six focused local regressions, including the actual structured request handler captured with a mocked `Deno.serve`, mocked configuration and mocked HTTP reads. Runtime network, environment-secret reads and production writes are not granted.
- `docs/weedmaster-acceptance/catalogue-release-handoff.md`: this coordinated handoff.

Serving now includes the retained manufacturer link in both `registration` and `label_urls`; the full source, cover declaration and hash remain in verification evidence. Existing `viticulture_rates` is passed through verbatim, not rebuilt. Customer default options still come only from authoritative `registered_uses`, not from double-counting that projection.

### Distinct label versions

`label_evidence.stored_register_metadata` and `registration.stored_register_label_version` preserve stored register metadata. `registration.manufacturer_label_version` is read only from the matching retained reviewed document declaration. `label_evidence.reviewed_manufacturer_document` retains that source and its hash-bound cover evidence. `same_label_version_established` is false: this code does not establish document-version equivalence.

When the legacy `registration.label_reference` is populated from retained manufacturer evidence instead of the stored register link, `registration.label_version` is not populated from unrelated register metadata. This prevents legacy clients from labelling that PDF with the register's version. Nothing changes in storage. Lovable should display the two evidence identities separately, including when the register's version has no openable URL.

## Focused results

- Six Weedmaster release tests passed.
- Existing `master_default_identity_test.ts` selection `C: valid D1 identities` passed (one test, thirteen filtered out).
- Existing `ingestion/resolver_test.ts` selection `R12:` passed (one test, eighteen filtered out).
- `deno check supabase/functions/chemical-info-lookup/index.ts` passed.
- `git diff --check` passed.

The full local fixture proves:

1. Both `per_hectare` and `per_100_litres` reach customer `default_rate_options`.
2. Phalaris Handgun remains a range of **500–1000 mL/100 L**, with null fixed value, original method/target associations, direction `direction_v1_1363f3205ca7b639cd5f970a03d91785`, and rate `rate_v1_4efec198ead373a3286939ced245fadf`. Selection validation retains those rate IDs.
3. Unsupported Wiper, Knapsack /15 L, controlled-droplet, cut-stump and low-volume methods do not become calculator options. Withheld Paspalum and unestablished aquatic/wetland situations remain excluded.
4. All registered directions, restrictions, source references, verification sources/conflicts and eleven retained exception entries survive serialization. The fixture is unchanged after serving.
5. A hypothetical approved copy of this local row takes the real structured-handler Master path with **exactly one mocked GET** of `master_chemicals`: no register discovery, document fetch, preparation, extraction, AI request, enrichment or write.
6. Candidate rows are not returned by customer approved-Master search/lookup queries. Local hypothetical approval does not change production state.
7. Missing operational rate IDs and unresolved `RATES:GRAPEVINE...` still fail readiness; no stored rate/direction IDs are minted or repaired at serving time.

This does not prove the deployed endpoint, the exact current DB row, or a customer device/UI interaction. No mobile/web builds or broad suites were run.

## Exact release gates and retained exceptions

### Genuine current release blocker

`fetchApprovedMaster` and `searchMaster` in `ingestion/master_lookup.ts` query **`review_status=eq.approved`**. The supplied current row is **candidate**, so it is not an approved customer catalogue entry. The existing catalogue read policy in SQL 199 likewise permits non-admin reads only for approved rows. Applying reviewed content is not the same as catalogue approval.

**Required decision:** an authorised system admin must decide whether to approve the already-applied row, with its supported directions and retained limitations, through the existing catalogue approval workflow. Do not auto-approve, re-apply a backfill, or change canonical rates/evidence to make the drawer look complete.

The database approval constraint `master_chemicals_approved_provenance_check` requires `source_kind` to be `official_register` or `manufacturer_label` for an approved row. It does not require `verification_status='verified'` or empty warning arrays. The local fixture uses official-register provenance. Any additional Lovable UI approval rule is unverified because its source is absent from this workspace.

### Readiness blockers, if present on the actual record

`masterHasCompleteVineyardData` requires a registration number, a resolved label reference, no unresolved entry beginning `RATES:GRAPEVINE` (case-insensitive), and valid persisted identities for eligible vineyard operational rates. The revised resolver fixes the empty top-level label projection without changing these gates or the approval/permission rules.

### Retained warnings/exclusions, not automatic whole-product blockers under those rules

- Paspalum critical-comment relationship: rates withheld; do not offer that direction.
- Unknown re-entry interval: remains unknown, not zero hours.
- Wiper mixture and Knapsack /15 L: label information only, unsupported calculator bases.
- Controlled droplet applicators: device/mixture ambiguity, not a bound per-ha or per-100 L dose.
- Bamboo cut-stump and Pampas low-volume: vineyard method permission not established, excluded.
- Cumbungi, Ludwigia and Phragmites/common reed aquatic/wetland situations: vineyard situation not established, excluded.

These entries remain visible alongside supported directions. Partial verification remains partial. Their persistence does not automatically imply an unresolved `RATES:GRAPEVINE` gate; the reviewer still decides whether release with these limitations is appropriate.

## Lovable reader work: not delivered in this workspace

`src/lib/masterCuration.ts` and `parseMasterViticultureRates` do not exist here; repository-wide TypeScript searches found no such symbol. No replacement file was invented. Neither the Lovable drawer nor its customer search/review reader has been patched or exercised.

Required Lovable change:

1. Accept the canonical object collections `per_hectare` and `per_100_litres`, while retaining existing array and `object.rates` compatibility. Read canonical collections first when present; do not treat an empty legacy `rates` property as overriding populated canonical collections.
2. Feed entries through existing validation/display without collapsing ranges or converting bases/units. Retain `value`, `min_value`, `max_value`, `basis`, `unit`, `label`, `raw_text`, `source_refs`, `rate_id`, and any persisted direction identity.
3. Retain method/target associations. Where a flattened catalogue rate carries only source references and `rate_id`, associate it with its stored registered direction by the persisted identity, not a newly invented ID or positional index.
4. Use the same compatible reader wherever customer search/review consumes `viticulture_rates`; test that path independently of the admin drawer. Where customer selection consumes structured responses, use the server's `default_rate_options` buckets and carry their existing supporting identities intact.
5. Show retained warnings and distinct register/manufacturer version evidence. Never save a replacement rate structure just because the UI reader changed.
6. Exercise canonical fixed/range shapes and both legacy shapes locally. Confirm Phalaris, restrictions/links, exclusions and warnings before catalogue approval.

Rork's inspected customer readers already decode both server-option buckets in `ChemicalServerDefaultRateOptions.swift` and `ChemicalServerDefaultRateOptions.kt`. The V2 catalogue models also decode both `viticulture_rates` buckets. No equivalent canonical-shape mismatch was found in those native decoders, and they were not modified or rebuilt.

## Remaining coordinated steps

1. Obtain the Lovable admin parser, its rate types, the customer search/review reader and their focused tests; apply and independently validate the read-only compatibility fix above. A read-only export of the current revision-2 row would allow validation against the exact applied content rather than the local reconstruction.
2. Review and, when separately authorised, deploy the changed `chemical-info-lookup` module graph. No backend deployment has occurred in this task.
3. Have the authorised reviewer make the explicit catalogue approval decision on the existing Master row and its retained exceptions. If the UI imposes an additional blocker, record its exact rule instead of weakening it or clearing warnings. Re-read the current revision/status before the decision; do not presume an unchanged revision after an unrelated edit.
4. Once approved and deployed, test as an ordinary customer: search/select the same Master identity, see both supported bases, choose the Phalaris range, verify supporting IDs and Master source metadata on save/reload, open the retained manufacturer PDF, and see restrictions plus warnings. Confirm diagnostics use `master_catalogue` without an unnecessary discovery/enrichment attempt. Confirm excluded methods never appear as calculator choices.

## Delivery references

- Existing rate correction: `8d1fd4ab256c8699126c0e4f9ca3252a68ada1a9`.
- Existing complete Phalaris acceptance delivery: `81a612aac86e6c7fea218bfbf96ba029d5455b40`.
- This readiness/serving change is present as workspace source and test changes. No new commit hash was available while preparing this handoff; no manual commit/push or fabricated delivery hash was produced.

No production write, preparation/extraction/Master apply, bulk enrichment, SQL execution, SQL 257 step, media staging, Trip/tank change, permission weakening, warning clearance, or full-verification assertion is part of this handoff.
