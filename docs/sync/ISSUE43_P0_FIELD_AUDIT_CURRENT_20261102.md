# Issue #43 — current-source P0 field audit and review sequence

**2 November 2026 — INCOMPLETE / PUBLIC RELEASE BLOCKED.** This is the requested first report before runtime corrections. It is not the completed 26-domain certification. No application code, queues, database, permissions, workflow, package/version or publication changed in this pass. Issues #40, #41 and #42 remain separate obligations.

## 1. Evidence boundaries

- Current managed source inspected: `0130a8ff05fcb4759ccd4fe2046d376ac2631be6`. No installed-binary equivalence established.
- Governing reference: open, unmerged PR #38, exact head `637d646181a4b7cab1ab0ed8da3db1e84c7a327e`, `docs/sync/CANONICAL_SYNC_CONTRACT_V1.md`. Read complete contract, complete first audit, domain register, draft validator and workflow. No blind import of that older tree.
- PR audit mobile baseline was `510348760de2b61a060e47ce19e7420d363b8e6e`; its findings are not automatically current-device results.
- Schema comparison below uses PR #38's **2026-11-02 metadata snapshot**, 26 tables / 718 columns, project `tbafuqwruefgkbyxrxyb`. This pass fetched the exact pinned snapshot but did not independently query live schema/RLS/RPCs. Previously reported live function MD5 `afcbc340565f6917ec48245998808ca6` is attributed to that audit, not a fresh deployment attestation.
- Portal revision `9f7b647d3472dc910c631fdf6a6163daad313521` and project `9b5a08c7-4e98-403e-aabb-9adeb50cdc93` are **upstream report provenance only**. No Portal source is connected in the current workspace; all Portal columns in this comparison remain Unverified. Required endpoints include `get_spray_report_v1`, actual correction, Trip management and Spray creation/edit, not just visual Trip sheets.
- Genuine signed 3.1.8 writer captures, 3.1.8 source attestations and installed 3.1.9 writer captures remain unavailable. Current model declarations are not historical fixtures.
- Machine-readable scope/status: `issue43-domain-audit-current.json`. Status `Mismatch` records an identified incompatible representation or authority policy, not proof that every action in that domain fails. `Unverified` is not a pass. No domain is Verified.

Pinned PR artifacts are available at `https://github.com/stockmansridge/rork-vinetrack-june26/tree/637d646181a4b7cab1ab0ed8da3db1e84c7a327e`. SHA-256: canonical contract `2c91131b6a89b00d8882e0e4f559fa4f274891459d08f521fa134bc19e2b29a9`; complete upstream audit `e193c3df4b392bf7b1cdd736592dee187a1512bd3abc3300def4407691cb443a`; domain register `3342c2f9843f1c043ebd102e0c028a9423d6441d9cc52289295e0036b315aeab`; schema snapshot `fe7e5d811df957674e96687040a3f33e443e355a533bab315f7bb26b86740c0e`.

## 2. Tank Actual — exact field comparison

Source abbreviations below are precise paths at the managed revision above:

- **I-model:** `ios/VineTrack/LegacyImported/Models/SprayTankActual.swift:4–85`.
- **I-wire/read:** `ios/VineTrack/Backend/Sync/SprayTankActualStore.swift:13–79`.
- **A-model:** `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/SprayTankActual.kt:8–46`.
- **A-wire/read:** `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/SprayTankActualRepository.kt:20–64`.
- **A-JSON:** `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/SupabaseClient.kt:46–55,110` (shared Ktor JSON configuration).
- **SQL-base:** `sql/223_spray_tank_actuals.sql:39–88`.
- **SQL-update:** `sql/227_spray_actual_corrections_v1.sql:177–194`. Source SQL is not fresh proof of deployment.

### RPC arguments and read-only server fields

| Exact RPC key / stored field | Current iOS | Current Android | Backend snapshot / contract and disposition |
|---|---|---|---|
| `p_id` / `id` | UUID | String | Required UUID; stable original actual ID. Native wire canonicality/old fixtures Unverified. |
| `p_vineyard_id` / `vineyard_id` | UUID | String | Required UUID; membership and original-scope evidence required. |
| `p_spray_record_id` / `spray_record_id` | UUID | String | Required UUID; exact Spray parent, not name/time matching. |
| `p_trip_id` / `trip_id` | UUID | String | Required UUID; exact original Trip. |
| `p_tank_session_id` / `tank_session_id` | String | String | Required text; SQL trims it. iOS ACK normalizes UUID-like IDs; Android ACK compares text literally. Case/whitespace fixtures missing. |
| `p_tank_number` / `tank_number` | Int, >=1 | Int, >=1 | Required int4, >=1; not an alternative session identity. |
| `p_water_volume_l` / `water_volume_l` | Explicit null or Double | Request Double; `requireNotNull(actual.waterVolumeL)` before send | Nullable float8; argument mandatory, null distinct from zero. Android represents nullable reads but cannot submit null on this route. Contract capability difference, not proof the current confirmation UI needs a null write. |
| `p_chemicals` / `chemicals` | Typed array | Typed array | Non-null jsonb; whole array replacement on eligible conflict. Nested comparison below. |
| `p_confirmed_at` / `confirmed_at` | Date | String | Required timestamptz. UTC precision/round-trip and original capture missing. |
| `p_client_updated_at` / `client_updated_at` | Date | String, defaults to confirmation time | Required timestamptz; currently update authority, not a safe server revision. P0-F03. |
| `confirmed_by` | UUID decoded; not an RPC arg | String decoded; not an RPC arg | Required UUID; SQL derives `auth.uid()`. Attribution must not be copied to a new actor. |
| `correction_version` | Optional Int; comparisons default nil to 0 | Long, default 0 | Non-null int8. iOS optional acceptance is not proof of legacy server behavior. |
| `last_corrected_at` | Optional Date | Optional String | Nullable timestamptz; correction provenance. |
| `created_by`, `updated_by` | Not in actual read DTO | Not in actual read projection | Nullable UUIDs, server-owned; no equality evidence. |
| `created_at`, `updated_at` | Not in actual read DTO | Not in actual read projection | Required timestamptz; server-owned. |
| `deleted_at` | Not in actual read DTO | Fetch filters `is.null` | Nullable timestamptz; list absence is not deletion ACK. |
| `sync_version` | Not in actual read DTO | Not in actual read projection | Required int4; neither actual writer supplies CAS. Do not treat as universal revision. |

This accounts for all **19** columns in the pinned actual-table snapshot. It does not establish RLS, trigger coverage, correction RPC parity or Portal projection equality.

### Nested `p_chemicals[]` fields

| Exact key | iOS representation | Android representation | Result / missing evidence |
|---|---|---|---|
| `id` | UUID | nonblank String | SQL validates UUID; ACK chemical lookup typed UUID vs literal String. Malformed/case fixtures missing. |
| `plannedChemicalId` | UUID?, synthesized nil omission | String? default null; shared JSON has `explicitNulls=false` | **P0-F01 Mismatch:** validator demands key presence even when value null. Android is also exposed by current configured source, not only iOS. Native production-writer captures still required. |
| `savedChemicalId` | UUID?, synthesized nil omission | String? default null; same JSON policy | **P0-F01 Mismatch:** same required-key/null distinction. Manual/additional/substitution cases all need captures. |
| `replacesPlannedChemicalId` | UUID?, omitted nil | String?, omitted null | Optional relationship; base validator does not establish complete substitution semantics. Current ACK does not compare it. |
| `usageKind` | String? | String? | Local completion treats nil as `planned`; known values `planned`, `additional`, `substitution`. Unknown-kind/old-client behavior Unverified; ACK ignores it. |
| `name` | String | String | SQL rejects blank; ACK compares literal equality. Constructors alone do not prove all inbound validation. |
| `actualAmountBase` | finite nonnegative Double | finite nonnegative Double | Base quantity; SQL finite/nonnegative; ACK tolerance 1e-9. Never convert planned quantity into actual. |
| `unit` | `ChemicalUnit` | String constrained to `Litres`, `mL`, `Kg`, `g` | SQL accepts these four strings. Amount is base quantity, not necessarily display unit; conversion fixtures required. |
| `productCategory` | **Absent** | String? | **P0-F02 source risk:** typed iOS decode/re-encode cannot retain it. |
| `physicalForm` | **Absent** | String? | Same unknown-field loss risk. |
| `snapshotAt` | **Absent** | String? | Same unknown-field loss risk; timestamp semantics Unverified. |
| Any future unknown key | No extension-data storage in model | Shared JSON ignores unknown keys, no extension-data storage | Both typed round trips lack general lossless future-field retention. An ignored key is not a preserved key. |

### Four upstream priorities, checked against current source

1. **P0-F01 — Mismatch, source representation vs pinned validator.** `SQL-base:55–56` explicitly requires both linkage keys. I-model has synthesized Codable; I-wire delegates nested encoding. A-model defaults null; A-JSON omits explicit nulls and A-wire sends that model through shared JSON. Upstream's omitted=false / explicit-null=true SQL result is attributed, not rerun here. Do not fix by zeroing IDs, quantities or changing the shared JSON setting globally.
2. **P0-F02 — Unverified end-to-end, confirmed lossy model path.** Three Android evidence keys cannot survive iOS typed decode/re-encode. SQL-update replaces the whole chemicals array. Android also cannot retain arbitrary future keys. Reproduction needs a correction/edit that actually reaches this writer; a read-only view by itself does not erase server data.
3. **P0-F03 — Mismatch with canonical concurrency policy.** SQL-update:190–192 gates by `correction_version=0` and `excluded.client_updated_at >= stored.client_updated_at`, otherwise returns the stored row. No server base revision is supplied. Current client readback reduces some false ACKs but cannot stop a clock-skewed destructive server overwrite. Identical amounts with different linkage/provenance can also pass current ACK. Requires compatible backend policy design, not blind mobile retries.
4. **P0-F04 — Conditional schema mismatch, not a blanket By Area failure.** Exact 14-field map and route/admission distinctions follow.

### Additional current-source finding: P0-F07 — incomplete actual ACK comparison

`ios/VineTrack/Backend/Sync/TankDependencyVerification.swift:35–54` and `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TankDependencyVerification.kt:44–59` compare actual/parent/session identity, tank number, correction floor, water, chemical count and each line's ID/name/unit/amount. They **do not compare** `plannedChemicalId`, `savedChemicalId`, `replacesPlannedChemicalId`, `usageKind`, `confirmed_at`, `confirmed_by`, `client_updated_at`, or Android's category/form/snapshot evidence. Unknown keys are already absent from typed input.

**Mismatch with the requirement for exact original-evidence ACK; source-only counterexample:** two rows with the same checked fields/amounts but different planned linkage satisfy these comparators. No new executable test or original-device outcome is claimed. A higher correction version is accepted by the comparison floor; the correct authoritative-amendment policy must be reviewed rather than replaced by naive byte equality.

Production path has more safeguards than HTTP success alone: iOS store:385–401 checks server session and independent actual readback, then store:182–188 clears only if the complete current local object still equals submitted. Android `ScopedTankActualSync.kt:35–58` invokes optional injected session/readback gates and `markSyncedIfCurrent`; verifying every production injection and local-clear implementation remains part of the unfinished lifecycle audit. These safeguards do not fill the comparator's omitted fields.

## 3. Spray Planning — exact 14-field mismatch and routes

Sources: `ios/VineTrack/App/SprayEngine/SprayPlanningWireFields.swift:20–34,85–103`; `ios/VineTrack/Backend/Models/BackendSprayRecordUpsert+Encoding.swift:38,75–92`; `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/spray/SprayPlanningWireFields.kt:13–26,49–84`; Android `data/SprayRecordRepository.kt:258–288,409–414`.

**Every field below is absent from the pinned `spray_records` SQL-column snapshot.** Type below is the mobile wire type, NOT an existing SQL type/default. All are optional in the mobile tuple; a declared flat replacement fills nulls. Absence/clear are separate actions.

| Exact wire key | Type / unit / authority |
|---|---|
| `sprayer_configuration` | String code; operator selection (`standard_pass`, `over_row_two_rows`) |
| `spray_planning_method` | String code; `by_area` or `full_tank` |
| `full_tank_specification` | String code; `target_area` or `calibrated_rate` |
| `planning_input_provenance` | Object: `schema_version`, `tank_text`, `area_text`, `rate_text`, `volume_unit`, `area_unit`, `rate_area_unit`, `country_code` |
| `planning_intended_tank_litres` | Double, L; frozen input |
| `planning_target_area_ha` | Double, ha; frozen input |
| `planning_calibrated_litres_per_hectare` | Double, L/ha; frozen input |
| `planned_application_area_ha` | Double, ha; frozen calculated output, never actual coverage |
| `resolved_planning_carrier_litres` | Double, L; frozen calculated output, never actual water |
| `resolved_planning_litres_per_hectare` | Double, L/ha; frozen calculated output |
| `resolved_planning_physical_row_litres_per_100m` | Double, L/100 m physical row; frozen output |
| `resolved_planning_concentration_factor` | Double, dimensionless; read defaults absent value to 1 |
| `controller_litres_per_100m_travel` | Double, L/100 m travelled; distinct from physical-row rate |
| `effective_working_width_metres` | Double, m; frozen calculated output |

Nested provenance source: Swift wire:107–145; Kotlin wire:89–107. `schema_version=1`; raw text is not a normalized quantity. Legacy `gallons` converts to `us_gallons` for US/CA and `imperial_gallons` otherwise. Unknown country/unit/enum/version round trips still need native fixtures, not inferred compatibility.

### Actual writer-route distinctions

- **Old record / no planning / no explicit clear:** helper emits no new planning keys. This does not prove all other legacy fields are preserved.
- **Valid non-template By Area:** `LegacySpraySetup.canCarry` requires By Area intent and valid frozen resolution. iOS encoder:38,90 and Android merging:50–52 carry the tuple in existing `notes`, not flat SQL fields. Markers are `\n[VineTrack sprayer setup v1]\n` and `\n[/VineTrack sprayer setup]`. Append preserves original user notes and prior annotations. This route is not demonstrated broken by the missing columns.
- **Full Tank / incomplete planning / explicit clear:** helpers can emit the flat names, but production admission may refuse before transport. Android repository:258 and iOS `SupabaseSprayRecordSyncRepository` must be traced through each supported action; helper reachability alone is not a rejected real request.
- **Record templates:** iOS encoder always calls `inputsOnly:false` even for template; initializer strips outputs, so those outputs can become explicit nulls. Android repository passes `isTemplate` to `.from(...)` but omits `template` in `.merging(...)`; the default is false, selecting 14 record keys rather than the helper's seven-key template branch when intent remains. This is a confirmed callsite distinction, not a captured rejection. Canonical `spray_jobs` templates are a different endpoint/contract.
- **Reads:** iOS `BackendSprayRecord.swift:453–509`; Android `Models.kt:1904–1916` prefer the whole flat tuple if any intent or complete resolution exists, otherwise notes fallback. No field-by-field backfill. Partial flat intent can suppress a complete annotation. All-null flat values plus a retained valid notes annotation can restore old setup on read after a hypothetical clear. These are source risks; no backend clear or device reproduction performed.
- **Future annotation:** Android notes parser uses `ignoreUnknownKeys=false`; unsupported future fields return no setup rather than retain typed planning. Original notes may remain intact, but preservation through later edits/Portal writers is Unverified.

Required route fixtures: old/no planning; valid By Area with/without prior annotation; blocked Full Tank (assert no dispatch); record template; canonical job template; explicit clear with old annotation; edit old record; partial flat plus complete notes; future annotation/unknown fields; both systems of gallons. Capture actual POST/PATCH and authoritative readback. Do not add 14 columns as an unreviewed workaround.

## 4. Full Trip/Spray/Tank lifecycle — remaining audit boundary

The upstream audit identifies each path below; this pass deep-reviewed actual and planning field boundaries, **not every field in the Trip/Spray DTOs or every state transition**. Trips have 50 columns, Spray records 56, plus nested documents; they remain Unverified as complete lifecycles.

| Action group | Evidence required to close |
|---|---|
| Select/prepare/review | Original user fields, immutable recipe, separately entered actuals, local transaction and account/epoch scope; both production UI entry points |
| Create parent / create+activate occurrence | Exact native request per verb, full nested `occurrence_coverage`, original IDs, RPC whitelist, privilege/owner, durable receipt; known UUID owner correction separate |
| Link Spray / edit plan / complete Spray | Every Spray insert/patch field and notes representation; job provenance, old-client later edits, fresh ACK against original revision |
| Start Tank 1 / subsequent Tank / pause/resume/end Tank | Every nested session member, original session identity, retained atomic handoff and complete session comparison; kill/restart at each step |
| Confirm/upload/correct actual | Fields in sections 2–3, correction-role semantics, matching full-evidence ACK and approved amendment retention |
| GPS / row / route / fuel / metadata | Separate patch inventories, units/time precision, partial/duplicate/reordered delivery, conflict preservation |
| Labour / End / finalise / reopen | Labour receipt/readback under authorised access, exact finalisation operation, terminal server row, all children ACKed, claim release and reopen durability |
| Delete / cancel / historical recovery | Applied/Not applied/Not sure, archive, anti-resurrection, old-client refusal, exact scoped retirement only after durable receipt; no absent-parent fabrication |
| Pull on other mobile / Portal | Fresh same-vineyard authorised fetch, complete pages, null/unknown handling, report projections and no takeover of remote tracking claim |

Never cancel/recreate modern Trip `b1dd59ab-ff1b-4ff4-9af6-a9688425db22`. Prior server recovery does not close original-device #41. #42 journal bytes and #40 historical reconciliation remain held independently. Full-sweep zero modern uploads does not mean no original obligations.

## 5. Missing fixture register — required before certification

**No genuine versioned writer fixture was established in this pass.** Existing model/unit test sources are candidates, not signed historical captures and not fresh test results.

1. **Origins:** signed iOS 3.1.8 and Android 3.1.8 source/build attestations, durable pre-upgrade snapshots and actual original writer payloads; signed installed 3.1.9 mappings and current production-encoder outputs; Portal serializer revision and backend function/trigger/RLS hashes. Capture privately with stable sanitized identities and exact shape, never customer quantities/credentials in chat.
2. **F01 matrix:** each native/version writer, planned/additional/substitution, both optional IDs populated/explicit null/omitted, empty array, zero actual versus absent, all four units, finite boundary, invalid UUID and unknown usage code. Required outcome: known safe legacy omission accepted only by reviewed adapter; malformed inputs remain rejected; no amount substitution.
3. **F02 matrix:** Android evidence → server → iOS read/edit/correction → server → Android; reverse direction; 3.1.8 edit after 3.1.9 unknown fields; future nested keys. Assert exact preserved provenance as well as unchanged quantities.
4. **F03/F07 matrix:** negative/positive clock skew, equal timestamps, stale response after newer local edit, different linkage with same quantity, different confirmer/time, same session with competing IDs, correction_version>0, lost response/duplicate. Assert rejection/receipt and retained original local revision; a 2xx or equal quantity alone cannot pass.
5. **Planning matrix:** routes listed in section 3 at native repository boundary, expected full request and server row, notes preservation after old-client/Portal resave, unknown future schema, units and precision.
6. **Operational fixtures:** every action in section 4, account/vineyard switch at awaits, expired access and 401/403/RLS-empty, process death before/after durable stages, partial pages, late ACK, out-of-order delivery, tombstones and deletion lineage.
7. **Convergence:** signed iOS/Android old→new and new→old readers **and writers**, in-place upgrade preserving original IDs/bytes, A→server→B and reverse, authenticated Portal comparison. No fixture reconstructed from current serializers may be labelled 3.1.8.

Fixture receipts must include source SHA, exact encoder entry point, signing/build identity when claiming released origin, capture method, sanitized payload SHA-256, backend revision/hash, expected result and actual native/server/Portal receipt. A fixture inventory without payloads is explicitly Missing, never Passed.

## 6. Separately reviewed, independently testable sequence

These are proposals, not authorisation to deploy or change runtime behavior.

1. **Evidence + harness review only:** freeze missing sources/captures; define semantic fixture manifest and native serializer adapters; retain current failing baseline. Require an explicit missing-fixture/Unverified result rather than synthetic historical success. No production request.
2. **F01 backend compatibility proposal:** decide omitted-to-null treatment for only semantically optional linkage keys, preserving provenance; controlled rollback-only validation including malformed/foreign values, permissions and old clients. Review constraint and RPC together. No grant relaxation or production migration here.
3. **F01 isolated mobile codec:** explicit nullable chemical linkage encoding scoped to actuals on both platforms; test real repository writers, local-store compatibility and all usage kinds. Do not globally toggle shared Android JSON.
4. **F02 lossless nested JSON proposal:** unknown-key retention or reviewed server-owned patch/amendment contract; prove older edits preserve newer evidence before enabling cross-device edits. Must compose with concurrency change, not a blind whole-array merge.
5. **F03 additive concurrency proposal:** server revision or immutable base plus audited amendment with explicit result/receipt; preserve old endpoint compatibility without allowing legacy writes to overwrite newer protected state. Old-writer behavior is a blocking design choice. Deploy only after separate authorised review and controlled matrix.
6. **F07 complete semantic ACK:** compare all contract-owned identity/linkage/actual/provenance fields against the submitted revision; define timestamp normalization and authoritative correction semantics. Retain newer local edits. Fixture red case must prove equal quantity/different linkage cannot clear intent.
7. **F04 route-specific planning proposal:** choose supported notes versus additive columns only after Portal/old-client round trips. Handle templates and explicit clears separately; test no-dispatch admission, notes read precedence and upgrade preservation. No blind column creation.
8. **Whole operational dependency regression:** validate create→activate→Spray→session→actual→GPS/labour→End and cancel/delete before proceeding through other domains. Original-device incidents still need their own acceptance.
9. **Reviewed CI activation:** integrate reviewed governance and native semantic gates into actual default workflow, exercise a deliberately incompatible synthetic change with red receipt and corrected green receipt, then separately verify required branch protection. Structural green is not semantic certification. No workflow was activated here.

Dependencies: lossless preservation and concurrency design must be agreed together; F07 consumes that reviewed contract. Backend-first steps require named deployment authority. No release, floor increase, migration, queue clearing or customer mutation follows automatically from accepting this report.

## 7. Validation actually performed

- Current `scripts/audit_sync_inventory.py --verify-inventory` **FAILS**: unregistered iOS coordinator call `YieldMasterWeightCache.shared.synchronize`; literal and dynamic route signatures differ from the register. Android pending discriminator names show no drift. Register source is `8c15003d793e200c12f43c1a35349c77e829fdbf`, not current source. Do not mechanically replace signatures before reviewing affected callsites.
- Literal expected `bb04cb27da47dd09590be02fd520bda9abb465364fdabe58063165640c8cc537`, observed `547103bf794c368f0e95b25a9f2913420a5d951634ec845158316a32408a3013`; dynamic expected `2da03dbe79bead9407a16a006adc54a1b2015891fa25dd47ae969e034b9b2813`, observed `fd1025f7c28786d06bdb4c7ff99fce999d10506bf1b7382cea14737eaf63b2ce`.
- Reviewed PR #38 validator is **structural only** and not runnable as the current gate without its unmerged required artifacts. It permits >=25 domains rather than exact 26, requires only a subset of domain IDs and rejects placeholders for Verified rows using string checks rather than artifact/native/backend validation. Its allowed statuses do not include Mismatch. These are harness-review items, not a reason to silently change the canonical draft.
- Draft workflow has no native golden tests, Portal run or controlled backend job. It is not tracked on current main here. Required branch protection was not established; workflow presence alone cannot establish it.
- No fresh native tests, app builds, controlled backend execution, signed-device upgrade or Portal/device interactions in this documentation-only pass. Prior passing tests remain bounded historical evidence, not this audit's acceptance.

**Outcome:** first P0 field report and patch review sequence delivered; all 26 domain certifications remain incomplete. Two domains have identified mismatches; 24 have no complete current semantic verdict. Full field/action inventory, genuine fixtures, fresh backend/Portal source and cross-version/device convergence remain outstanding.
