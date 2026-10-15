# New spray planning operational integration — approval proposal and evidence

Date: 2026-10-15. Baseline: `c54ec2743dce379313bca8e8507d59d714144fc7`, clean working tree before this pass.

## Decision and boundaries

**NO-GO for enabling new-planning Save/Start.** Calculator previews remain available. This is not a conclusion that the approved calculations are wrong: persistence/server/workflow acceptance remains incomplete. No operational gate, quantity formula, CF formula, registered rate, product dose, row-equivalent definition, actual coverage or frozen Live Trip source was changed. No SQL executed, migration registered, backend deployed, release or store action performed.

The previously frozen Android Live Trip candidate remains commit `c2e65a51d48622b0423ae2818252344c559cb0f9` / APK SHA-256 `8836a3025c30a779c04a0e1207490687f3d73a55ebf05eab1babb3eae4a538bb`. This planning pass is separate source; do not identify a newly built APK as those exact frozen bytes.

## Source-backed trace

| Boundary | Android | iOS | Finding |
|---|---|---|---|
| Calculator/Review | `data/spray/SprayGuidedFlow.kt`, `ui/screens/SprayCalculatorScreen.kt` | `App/SprayEngine/SprayGuidedFlow.swift`, `App/SprayCalculatorView.swift` | Completeness and operational admission are separate. Every non-null new intent remains operationally gated. |
| Models/wire/reopen | `data/spray/SprayPlanningWireFields.kt`, `data/model/Models.kt` | `App/SprayEngine/SprayPlanningWireFields.swift`, backend record mappers | Seven inputs plus seven frozen outputs represented; input-only templates; absent historical configuration stays unknown. Wire projection is not proof of server round-trip. |
| Save/update | `SprayRecordRepository.kt`, AppViewModel save/start checks | `MigratedDataStore.swift`, `SupabaseSprayRecordSyncRepository.swift`, `SpraySaveForLaterCoordinator.swift` | Admission before save/transport. iOS record then inactive Trip durable save is ordered, not a single atomic transaction; the same-screen retry pair is not a fully process-restorable creation journal. |
| Queues/replay | `SprayRecordCreateSync.kt`, `SprayRecordUpdateSync.kt` | `Backend/Sync/SprayRecordSyncService.swift` | New planning refuses before enqueue/replay. Android arbitrary 409 retains operation, never proves duplicate success. iOS first blocked dirty record aborts push/pull pass; unrelated-work isolation still needs integration. |
| Start Spray | recipe-backed AppViewModel paths; generic spray starts refuse | `SprayTripStartAdmission.swift`, `TripTrackingService.swift` | Scoped frozen recipe required. No preview-only record may start. New planning must share a durable record/Trip admission version, not bypass via a generic Trip. |
| Start Tank | `StartTankCommitCoordinator.kt`, current/captured record equality | `StartTankCommitCoordinator.swift`, `TripTrackingService.swift` | Rechecks exact recipe before establishing operation. Already-established factual recovery must not be erased or repeated by later admission failure. |
| Supabase | `sql/review/spray_configuration_full_tank_planning_draft.sql` | shared | Review-only DDL, not a registered/applied migration. No verified deployed column/admission/receipt support was established in this pass. |

## Concrete blockers

1. **Storage approval and full-schema evidence:** draft v2 exists, but no approved installation/full-clone validation evidence for these columns, column grants, existing freeze triggers and RPC projections. Presence of client fields cannot establish deployed storage.
2. **Admission versus advisory policy:** historical `docs/spray-server-compliance-proposal.md` and `sql/review/spray_label_server_admission_acceptance.sql` expect unknown CF approval to reject. That is incompatible with the accepted WARNING ONLY policy. The proposal now carries an explicit supersession notice; its SQL fixtures were not applied or silently made passing.
3. **Durable creation identity:** Save for Later/Start Now needs a recoverable parent-record/Trip attempt with stable IDs and exact original payload across process termination, not only same-view retry. Android calculator creation currently retains its online prerequisite. Do not claim fresh offline calculator creation supported merely because a saved plan activates offline.
4. **Typed acceptance:** ordinary REST success/409 handling does not supply a reviewed operation+actor+vineyard+recipe+revision receipt across record/job/Trip/tank side effects. Unknown/lost responses must retain the same frozen operation; duplicate ID alone must not clear it.
5. **Output validation:** Full Tank had consistency checks, but there was no common positive/finite/controller-width validation of frozen outputs for both methods. This pass adds that client check behind the still-closed gate. It does not validate all server geometry/product identities or authorise execution.
6. **Only Full Tanks route scope:** existing meaning is one intended fill (not necessarily equipment capacity), with area resolved from target/calibration, constrained to selected gross hectares. It is NOT an integer-tank optimisation. If planned area is less than the selected blocks, no row subset can be inferred from hectares. Full Tank snapshots deliberately omit fabricated treated-row allocations. Explicit route selection/binding is required before planned occurrence work; otherwise hold Start, never credit all selected rows or invent partial coverage. Preserve approved fill calculations; any change to the meaning of Only Full Tanks needs separate approval.
7. **Over-Row route scope:** configuration multiplies controller travel output/working width, not physical row spacing, dose or occurrence completion count. Explicit physical path/pass binding must be proved at Start and Tank; two row equivalents do not authorise two occurrence Done actions.
8. **Legacy/history:** NULL must remain unknown; no defaults/backfill/automatic conversion. Input-only saved templates require fresh output validation on execution, not recalculation of completed Spray Records. Future/malformed fields must hold rather than lose their provenance.
9. **Native acceptance:** no safe authenticated calculator session was available to this pass; screen and physical workflow matrix remains unverified. Existing fixtures are not authenticated workflow evidence.

## Exact storage proposal — approval required before applying

Reuse the checked-in draft `sql/review/spray_configuration_full_tank_planning_draft.sql` as the DDL proposal, not a new conflicting migration. Its exact columns are:

- `spray_records` and `spray_jobs`: nullable TEXT `sprayer_configuration`, `spray_planning_method`, `full_tank_specification`; nullable JSONB `planning_input_provenance`; nullable NUMERIC `planning_intended_tank_litres`, `planning_target_area_ha`, `planning_calibrated_litres_per_hectare`.
- `spray_records` only: nullable NUMERIC `planned_application_area_ha`, `resolved_planning_carrier_litres`, `resolved_planning_litres_per_hectare`, `resolved_planning_physical_row_litres_per_100m`, `resolved_planning_concentration_factor`, `controller_litres_per_100m_travel`, `effective_working_width_metres`.
- Enums: `standard_pass`/`over_row_two_rows`; `by_area`/`full_tank`; Full Tank discriminator `target_area`/`calibrated_rate`. Positive finite numeric checks; frozen CF additionally must be >=1 at execution. Provenance is schema_version=1 with exact raw text/unit/country keys, not a permission flag.
- No defaults, history updates, backfill, new role privileges or RLS weakening. Missing fields remain NULL. Omitted PATCH means unchanged, explicit NULL means clear. Declared replacement is one atomic tuple; templates carry inputs only, records retain frozen outputs.
- On a restored full schema, extend EXISTING completed-history/job provenance freeze protections to all new planning fields and preserve already-established tank facts. Draft column checks alone are insufficient. This pass does not have a verified current object-by-object server catalog; final trigger/RPC installation SQL must be checked against that catalog before approval to apply it.

### Proposed operational server contract — not implemented or applied

Approval is requested for this scope, not for deployment:

1. Add a versioned planning admission validator shared by record save/update, executable job activation, spray Trip activation/linking and tank establishment. Check actor/membership/current recipe revision, complete planning inputs/frozen outputs, finite positive quantities, explicit rate basis/product units, actual equipment capacity and route scope. Reject inconsistent data without recalculating or silently modifying supplied amounts. By Area measured-row carrier totals must remain measured-row based; do not impose gross area × L/ha where existing approved equations use canonical row length.
2. **Do not require verified concentrate-label permission, unknown-label acknowledgement or a trusted-label approval record.** Label uncertainty produces advisory data only. A valid CF above 1 is not a refusal reason. Preserve genuine quantity/calculation checks and existing independently established restrictions; do not invent new label limits from a registered-rate maximum or unreviewed text.
3. Establish a scoped operation receipt bound to original operation UUID, actor, vineyard, record, recipe revision, exact accepted request digest, linked Trip/tank/session identities and stored result. Exact retries return the original result; same operation/different digest rejects. Uncertain replay cannot regenerate identity or rebase silently. Implement using the existing pending-operation infrastructure only where its receipt scope is proven; a new ledger/table must be explicitly approved if existing infrastructure cannot bind these facts.
4. Lock recipe/Trip/tank in a stable order through validation and operational effects. Compare the captured recipe revision immediately before Start Tank. A rejected new start has zero recording/session/inventory/labour effects. Preserve existing prepared/established recovery: it is factual reconciliation, not a fresh operational start.
5. Proposed typed errors: `SPRAY_PLANNING_INCOMPLETE`, `SPRAY_PLANNING_INCONSISTENT`, `SPRAY_PLANNING_UNSUPPORTED`, `SPRAY_RECIPE_REVISION_CONFLICT`, plus existing auth/scope failures. Safe details identify record/tank/line IDs and remedy. Do NOT use `SPRAY_LABEL_AUTHORITY_UNVERIFIED` for CF uncertainty. Missing RPC/schema capability keeps native admission disabled, not numeric/legacy fallback.
6. Capability activation must identify the validated contract version, not a client-only Boolean. Keep native gate closed until both platforms pass durable save/reopen, original-payload replay, duplicate/lost acknowledgement, partial-commit recovery and all four operational combinations against the approved non-production authority. Activation/deployment requires separate approval and is not performed by this proposal.

This is the exact proposed scope and stored fields, not executable final server installation SQL. Current deployed trigger/RPC definitions and receipt infrastructure must be supplied/verified to produce an exact installation patch without inventing server objects. Nothing in this document authorises applying the existing draft or the old CF-permission proposal.

## Client work implemented this pass

- Shared-semantics Swift/Kotlin frozen-output validation: positive finite carrier/area/rate; calculated CF finite and >=1; optional physical/controller/width outputs either absent together or complete, positive and mutually consistent with the declared row equivalents.
- Wired into native frozen-record admission and iOS backend payload admission before the unchanged operational migration gate. By Area row-length carrier totals explicitly preserved rather than rewritten as gross-area volume.
- Added two tests on each platform: all four combinations with CF2, frozen serialization round-trip, independent advisory CF acceptance and closed gate; measured-row By Area carrier preservation. Matrix loops are four cases in one test, not four separately reported test counts.
- Historical server proposal explicitly marked superseded for CF-uncertainty admission. No executable server changes.
- This does NOT implement server admission, receipt verification, process-restorable creation, route subset selection or gate activation. Those remain incomplete rather than being hidden behind a passing preview test.

## Acceptance matrix — supporting evidence versus operational evidence

| Configuration | Method | Local resolve/frozen round-trip/CF advisory | Save + reopen + server reconciliation | Start Spray + Start Tank | Real offline kill/relaunch |
|---|---|---|---|---|---|
| Single Row | By Area | New focused matrix coverage | Blocked by disabled gate; not passed | Blocked; not passed | Not verified |
| Single Row | Only Full Tanks | New focused matrix coverage | Blocked by disabled gate; not passed | Blocked; route scope unresolved | Not verified |
| Over-Row | By Area | New focused matrix coverage | Blocked by disabled gate; not passed | Blocked; physical binding acceptance pending | Not verified |
| Over-Row | Only Full Tanks | New focused matrix coverage | Blocked by disabled gate; not passed | Blocked; route scope unresolved | Not verified |

Both platforms: legacy CF2 recipe admission remains allowed by existing focused tests; all new modes return only the independent migration hold for the valid matrix. There is no test-only permission switch, and no claim that the future enabled server workflow was proved.

## Validation and native screenshots

- iOS `SprayPlanningIntentTests` + `SprayStartPresentationTests`: **33 passed, 112s**. Managed runner does not expose a skipped count. These are local model/writer-admission tests, not authenticated server operations.
- iOS `runChecks`: **passed simulator build**; no signed handset/release validation or delivery.
- Android calculator regression selection: **168 passed / 0 failed / 0 errors / 0 skipped**, 14 suites, Gradle BUILD SUCCESSFUL in 3m37s, runner exit 0. Includes 26 planning cases, existing replay/409 rejection, tank coordinator, snapshots, registered-rate and calculation regressions; not a new all-platform operational acceptance claim. Existing runner `scripts/run-calculator-completion.py --launch` and `.rork-tmp/calculator-completion.init.gradle` were reused. Child-JVM restart is not Android OS-process death.
- Android final `runChecks`: **passed release APK build**. This is a new planning integration artifact, not the frozen Live Trip APK identity. No store upload.
- No fresh Android instrumentation, iOS UI-test suite, PostgreSQL or Edge execution this pass. Backend definitions unchanged. Source-scoped whitespace checks passed. Explicit diff against baseline showed no change in Live Trip traversal/location/tank lifecycle/AppViewModel/TripsScreen, SQL or Supabase functions. Existing tracked regression-runner log was regenerated; no production code was changed by it.
- One existing-preview-only iOS visual attempt: unavailable because no matching open simulator preview was accessible. No separate simulator rented, no credentials requested/entered, no data/fixture/account created, no automatic retry.
- Android authenticated visual flow not repeated on the known signed-out separate simulator. No fresh authenticated session established.
- Requested seven screen captures (Single Row, Over-Row, Full Tanks, complete label rates, compact WARNING, expanded details, complete Review), small screen, dark mode and keyboard acceptance: **not captured/verified in an authenticated calculator this pass**. No synthetic screenshots presented as actual-device evidence. Need the user to open an authenticated native preview with approved data, or supply handset screenshots/recordings. Physical handset capture is user-owned; the available simulator tool is not a physical device.

**GO:** existing calculator preview/visual inspection and previously frozen field candidate within its recorded limits. **NO-GO:** enable or field-operate any of the four NEW planning Save/Start combinations until approved schema/workflow integration and replay acceptance pass. Do not deploy merely to obtain that evidence.
