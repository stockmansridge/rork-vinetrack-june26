# PR33 recovery-store inventory — partial verification, not release approval

All 38 names below come from AccountTransitionEvidence.businessPreferences. Writer paths are relative to Android `data/`. This inventory identifies the boundary; it does NOT claim every format was reproduced or historically deployed. Source-review-only observations are not executed regressions. No blanket empty-only restriction was removed to pass recovery.

| Inspected store | Actual writer/reader | Classification and format | Current admission / remaining evidence |
|---|---|---|---|
| vinetrack_legacy_spray_saves_v1 | LegacySpraySaveStore | Uncertain authored save attempts; attempts JSON list | Empty-only; interrupted/legacy attempts held |
| vinetrack_pending_writes | PendingWriteStore, RetainedEvidenceContract | Authored operation outbox; pending_writes_json | Original-account/scoped supported operation contract; never an acknowledgement |
| vinetrack_pending_photos | PendingPhotoStore | Pending and completed-photo cache JSON lists | Only empty known arrays; populated evidence held |
| vinetrack_active_trip | ActiveTripSnapshotStorage, ActiveTripStore | Device-authored active snapshot | Exact original owner and matching Trip/vineyard; shared domain-cache Trip is not device authority |
| vinetrack_spray_tank_actuals | SprayTankActualStore | Mixed pending confirmations, edits, server-corrected/shared history, raw input drafts | Pending authorship separated from exact isolated server history proof; pending corrections explicitly held for review; read-only, unchanged preferences/epoch fenced |
| vinetrack_start_tank_journal | StartTankCommitCoordinator | Interrupted multi-store commit JSON journal | Empty-only; unresolved stages held, not recreated |
| vinetrack_chemical_label_photos | ChemicalLabelPhotoStore | Attachment evidence JSON | Only empty attachments array |
| vinetrack_manual_spray_operations_v1 | ManualSprayEntryRepository | Authored operations JSON list | Empty-only, including writer-persisted empty list; compatibility not repaired |
| vinetrack_manual_spray_drafts_v1 | ManualSprayDraftStore | Authored form JSON; reader also accepts old bare ManualSprayPayload | Empty-only; old/new populated drafts held |
| vinetrack_work_task_materials | material/WorkTaskMaterialStore | Mixed server catalogue/material caches and local task material lines | Empty-only; settled versus pending state needs separate proof/fixtures |
| vinetrack_paired_growth_capture | insights/SharedPreferencesPairedGrowthCaptureJournalStore | Capture-journal JSON list | Empty-only; wiring/historical stages not fully verified |
| vinetrack_pin_capture_evidence | PinCaptureEvidenceStore | Capture evidence JSON | Only empty known array; populated evidence held |
| vinetrack_recovery_snapshots_v2 | RecoverySnapshotStore | Preservation snapshot; source status and original retained operations | Dedicated original-scope/integrity contract; format3 clean-exit separately requires empty evidence |
| vinetrack_local_planning | WorkTaskPlanningDraftStore | Authored draft strings and uncertain intent/history | RetainedPlanningContract; original attribution, unchanged identity; not replay permission |
| vinetrack_domain_cache | DomainCacheStore, DomainCacheRepository | Mixed shared read datasets, owner metadata, timestamps and target outbox | Typed dataset/scope contract; old bare spray-record templates supported; pending outbox held; task/pin/equipment datasets are inside this store, not separate preference stores |
| vinetrack_irrigation | IrrigationPrefsStore AND IrrigationRepository | Shared namespace: settings plus repository persistence | Validator accepts only five finite-float settings; repository slices still require audit/reproduction |
| vineyard_insights_preview | insights/VineyardInsightsStore | JSON dataset slices | Empty-only; dataset/lifecycle audit incomplete |
| vinetrack_pruning | PruningStore | Setup/entry/activity/labour caches, possible authored intent | Populated recovery requires independent pruning projection/canonical read, not copied local audit fields |
| vinetrack_fertiliser | FertiliserStore | records_v2_<vineyard> JSON list | Empty-only; settled versus authored lifecycle not fully verified |
| vinetrack_saved_chemicals_local | SavedChemicalLocalStore | Scoped chemical snapshots including nested preserved label evidence | Bounded production codec plus every-supplied-field preservation; unknown/lossy top-level fields held; current-writer and deliberately omitted later optional fields executed, not a handset export |
| resistance_plans | resistance/ResistancePlanStore | Plans, pending StringSet, adopted Boolean, conflicts; retained Planner-v1 keys | Empty-only; settled/pending/conflict separation not implemented |
| vinetrack_map_alignment | mapalignment/MapAlignmentLocalStore | Unfinished calibration draft AND completed local-only calibration | Empty-only; completed versus interrupted attribution needs fixtures |
| vinetrack_operational_tools | OperationalToolLayoutStore | Per-vineyard layout JSON with visible/hidden/pending | Exact known shape and pending=false; pending layout held |
| vinetrack_button_templates | ButtonTemplateStore | templates_v1 JSON configuration list | Empty-only; populated saved configuration currently held |
| vinetrack_yield_determination | YieldDeterminationPrefsStore | Input strings, result Float, saved timestamp Long | Empty-only; result versus unfinished inputs not separated |
| vinetrack_pruning_yield_settings | PruningYieldSettingsStore | Scoped settings JSON lists | Independent exact server projection for populated recovery |
| vinetrack_region_settings | RegionSettingsStore | Scoped string settings | Known AU_NZ/au_nz terminology aliases compared read-only; unknown/type mismatches held |
| vinetrack_map | MapPrefsStore | Enumerated style, Boolean settings | Explicit preference contract; full historical writer equivalence not reproduced |
| vinetrack_operations | OperationPrefsStore | Boolean/Float/Int settings, delimited stages, scoped season values | Explicit key/type contract; unresolved global season migration held |
| vinetrack_canopy_rates | CanopyWaterRatesStore | Named finite Float settings | Explicit key/type contract; full history not reproduced |
| vinetrack_gdd_settings | GddSettingsStore | Calculation/reset enum settings | Explicit known enums; full history not reproduced |
| vinetrack_bunch_weights | BunchWeightDefaultsStore | Positive bw_* Float defaults | Explicit key/type contract; full history not reproduced |
| vinetrack_app_prefs | AppPreferencesStore | Display enum, Boolean/Float/timezone preferences | Explicit key/type contract; full history not reproduced |
| vinetrack_home | HomePrefsStore | Boolean plus dismissed-ID StringSet | Explicit key/type contract; full history not reproduced |
| vinetrack_onboarding | OnboardingStore | Completion Boolean | Explicit key/type contract |
| vinetrack_setup_wizard | SetupWizardStore | Enable Boolean | Explicit key/type contract |
| vinetrack_write_holds | auth/SessionStore | holds JSON scope/reason map | Fixed reasons, canonical account UUID, original-account scope; not a write grant |
| vinetrack_photo_acquisitions | auth/PhotoCaptureReceipt | Acquisition-ID-keyed receipt strings | Empty-only; detailed historical lifecycle not fully verified |

## Executed versus unresolved

- Chemical/region and known domain/pruning/planning/actual-entry contracts: final explicit JVM selection **102 passed, 0 failed/errors/skips**; real XML and named manifest retained separately.
- Tank shared/corrected history refusal: real writer failed before repair; eight current ChemicalRecoveryPreflight native cases are included in the later broad run. They cover successful history admission without pending promotion, missing/conflicting/403/503/offline history, pending correction refusal, original account/access and unchanged retained stores. Native raw log contains their named completion records.
- Read-only server proof is NOT a fallback that copies remote records over local bytes. Original pending actual and raw entered quantities remain unchanged.
- Writer-produced material caches, completed map calibration, resistance settled metadata, button configuration, yield results and empty manual-operation arrays can be held by empty-only rules. These remain **source-level mismatch candidates**, not corrected or reproduced fixes. Do not call this inventory a completed 38-store compatibility certification.
- No authentic private 3.1.8 installation snapshot or complete historical handset payload was supplied. Current-writer serializers with known historical omissions and the captured chemical REST fixture are not substitutes for populated in-place upgrade acceptance.
- Allowlisted chemical model-field/expected/actual-type diagnostics remain incomplete. Existing fixed chemical schema rules contain no private paths/values, but do not yet satisfy that finer diagnostic requirement.
- Full recovery through vineyard switch and an actual process restart, interrupted durable session persistence/cancellation for the newly combined layout, populated installed-lineage upgrade and original-phone acceptance remain open. Activity close/reopen and model-store recreation must not be labeled process death.
