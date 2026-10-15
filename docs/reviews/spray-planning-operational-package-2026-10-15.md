# Spray Planning operational integration package — 15 October 2026

> **Owner directive supersession — 15 October 2026:** Rork has no database access and must not seek credentials, inspect the live catalog, execute SQL or deploy. ChatGPT/backend owns schema reconciliation, migrations, server authority and installation under separate approval. L1, R1, R3, R4 and R5 are approved: dedicated ledger; whole passes only; `saved_unbound` without executable Trip; Over-Row as one physical travel occurrence with separate treatment context; initial online admission. R2 remains undecided. References below to access repair or requesting those five approvals are historical, not current Rork tasks. The client implementation/evidence and exact wire handoff are in `spray-planning-mobile-client-implementation-2026-10-15.md`. No server capability is asserted installed or enabled.

## 0. Review status and execution boundary

**Source-reviewed contract package; final executable migration BLOCKED by current catalog access.** This is further development under the accepted October 15 proposal, not permission to install, deploy, activate or distribute. No mobile source, frozen Live Trip implementation, SQL migration, Edge Function or production data was changed by this package.

Workspace baseline: `5796f137ff3de5b5abb6e0600fcbdf954e89e46b`; clean at inspection. The user-established current V2 facts are accepted: spray_records 56 columns, spray_jobs 46, RLS on both, none of the 21 proposed columns installed, existing completed-job protection concerns resistance provenance, and the three named operation tables exist. These facts do not establish their complete current definitions.

The managed credentials were located without printing them into this document. The read-only Supabase Management API catalog request returned **HTTP 401**. No catalog body was returned and no database statement was executed successfully. Therefore complete deployed trigger/function/grant/policy/RPC inspection has NOT occurred. The requirement to inspect those definitions BEFORE producing final executable migration SQL is respected: no new purportedly final migration is supplied. The existing v2 review draft remains unchanged and is NOT installation-ready.

Reproducible read-only capture: `python3 scripts/inspect-spray-planning-contract.py`. It checks the expected V2 project, requests `read_only=true`, captures public function bodies plus auth identity helpers, public relation columns/defaults/ACLs, constraints/indexes, trigger definitions, policies, views, role memberships/default ACLs and effective exposed-role table/function privileges. It selects no application/auth-user rows, exports no role passwords, and saves successful results privately under /tmp rather than committing arbitrary deployed function bodies. This is a catalog capture, NOT a restorable full schema dump or authenticated acceptance test. Review definitions for embedded secrets before sharing an export.

**Unblocking requirement:** valid read-only management access, or an authorised sanitized catalog export containing the complete definitions and privilege inventory above. Do not request a service-role mutation workaround or infer missing definitions from migration filenames.

## 1. Storage migration specification and finalisation checklist

Starting point: `sql/review/spray_configuration_full_tank_planning_draft.sql` (unapplied v2). Keep it in review/, not automatic migration discovery. Final SQL must be generated only after catalog reconciliation and separate ledger/design decisions below.

### Exact additive inventory

Both tables receive these seven nullable inputs, without defaults:

| Column | Type |
|---|---|
| sprayer_configuration | text |
| spray_planning_method | text |
| full_tank_specification | text |
| planning_input_provenance | jsonb |
| planning_intended_tank_litres | numeric |
| planning_target_area_ha | numeric |
| planning_calibrated_litres_per_hectare | numeric |

spray_records additionally receives these seven nullable frozen outputs, without defaults:

| Column | Type |
|---|---|
| planned_application_area_ha | numeric |
| resolved_planning_carrier_litres | numeric |
| resolved_planning_litres_per_hectare | numeric |
| resolved_planning_physical_row_litres_per_100m | numeric |
| resolved_planning_concentration_factor | numeric |
| controller_litres_per_100m_travel | numeric |
| effective_working_width_metres | numeric |

Post-install expected counts are 70 and 53 ONLY if the preflight still proves the exact 56/46 baseline. Preflight compares types, defaults, owners, RLS flags, all relevant function/trigger/policy definitions, ACLs and dependency signatures against the reviewed manifest, not column counts alone. Abort on drift. Do not let ADD COLUMN IF NOT EXISTS silently accept an incompatible pre-existing column or partially applied draft.

### Required changes beyond v2 storage CHECKs

1. Preserve enums `standard_pass` / `over_row_two_rows`, `by_area` / `full_tank`, and Full Tank `target_area` / `calibrated_rate`. NULL means not recorded, never inferred Single Row. Keep strict provenance v1 keys and captured explicit gallon/area/travel units from v2; raw text is evidence, not parsed by SQL or reinterpreted under current settings.
2. Every nonnull numeric value must be positive and explicitly reject PostgreSQL numeric NaN, Infinity and -Infinity. CF additionally >= 1.00, not merely >0 as in the old draft. A valid 2.00 with unverified permission MUST pass calculation admission when the remaining data is valid.
3. Separate incomplete saved drafts from executable snapshots. Admission requires configuration/method, full frozen output set and discriminated inputs. Optional physical/controller/width outputs must be all absent or all present, positive, finite and mutually consistent. Travel = physical row rate × row equivalents; travel = resolved L/ha × effective width / 100, within the existing client tolerance max(0.000001, max(abs(a),abs(b))*0.00000001). Freeze the algorithm/version; never repair supplied quantities silently.
4. Full Tank requires intended fill, exactly the selected target-area/calibrated-rate canonical input, planned hectares within verified selected physical scope, intended fill = resolved carrier = planned area × resolved L/ha, plus matching discriminator input. Inactive canonical input is NULL; inactive original raw text may remain in provenance. Equipment maximum capacity is validated separately from intended fill. By Area preserves the approved measured-row carrier arithmetic; **do not add a universal carrier = gross ha × L/ha constraint**. Its admission validates the frozen geometry/basis snapshot through the same approved algorithm.
5. Validate each chemical line's explicit rate basis, units, stable product/line identity, positive finite amount, tank identity and approved quantity relationship. Per-area products do not acquire CF; per-100 L follows the existing formula. Missing required dimensions/ambiguous rate basis genuinely reject. Captured label-permission uncertainty, concentrate permission and unknown limits are advisory only: no approval Boolean, acknowledgement or CF>1 limit prerequisite.
6. Inputs, geometry/basis evidence, chemical recipe and frozen outputs are replaced in one admitted database transaction as a complete tuple. RPC accepts an exact-key replacement (including explicit NULLs), not a partial merge of new inputs into old outputs. Reject partial output tuples and unknown keys. Generic unrelated PATCH omission remains unchanged; generic planning PATCH is denied. Reopen returns the original stored snapshot, never a recalculation using today's catalogue/template/geometry.
7. Protect planning evidence on completed spray records, including clears, NULL downgrades, scope/identity relinks, template/source reclassification, completion removal and replacement through old SECURITY DEFINER RPCs. The final completion predicate must be reconciled with actual completion triggers and linked Trip semantics; end_time alone may be insufficient. Do not install a speculative predicate. Completed legacy rows cannot be populated with invented planning evidence.
8. Extend completed-job protection to all seven new inputs and the legacy fields participating in the admitted recipe/scope. Retain the existing resistance-plan veto. Source SQL 201 freezes provenance on ANY live referencing record, not merely status=completed; do not weaken this by narrowing to end_time/status. Include status=completed self-protection and prevent clearing the record/job link to evade the freeze. Edits after execution require a genuinely new job/revision, never a history overwrite. Serialize record-link creation and job editing using the same lock discipline; a query-only BEFORE trigger is not sufficient concurrency proof.
9. Old/new presence of planning fields and durable admitted identity must make protection sticky. An old upsert cannot clear all 14 fields, reclassify the record, replace the recipe through tanks, or move it to another vineyard to regain legacy admission. Do not revoke unrelated legacy REST use globally. Add narrowly conditional guard triggers to every authority write surface (record/job, Trip activation/link/tank-session establishment, tank actuals and any job-paddock child writer), based on catalog audit, not just the 21 new columns.
10. Use a dedicated inaccessible NOLOGIN, NOSUPERUSER, NOBYPASSRLS writer principal with no client SET ROLE/membership path and narrowly scoped RLS/grants, if approved after catalog inspection. An invoker guard checks the actual controlled writer identity. Do NOT use request headers, client capability claims or a client-settable GUC as the security bypass. Existing definer triggers may change current_user internally; audit their call/write graph and final-row constraints. No broad execute grant, implicit PUBLIC/default-ACL inheritance, generic dynamic-table RPC or arbitrary user JSON assignment.
11. Preserve all existing ownership/RLS/vineyard-role semantics, block/job compatibility triggers, manual workflow, Trip Actuals, recorded row coverage and facts. No trigger disable, historical UPDATE/backfill/default, blanket grant/revoke or old migration replay. Preserve pre-existing nullable historical evidence. Confirm SELECT *, composite-return RPCs, view row shapes, native decoders and Portal consumers after adding columns.
12. Migration is one transaction, with bounded lock/statement timeouts, dependency/definition preflight and postcondition checks. Data-equality evidence excludes only legitimately changed metadata on new synthetic operations, not historical rows. Failed installation rolls back wholly. After deployment, disable capability on failure and retain admitted rows/receipts; do not drop evidence columns or rewind effects. No production run is authorised here.

**Outstanding SQL deliverable:** exact catalog-bound ALTER/constraints/guard functions, completed-job extension, admitted writer grants/policies and RPC bodies. These are deliberately not disguised as executable final SQL while the required catalog and new-ledger approval are absent.

## 2. Existing objects: source-backed reconciliation

These are findings from checked-in definitions, NOT assertions that those exact bodies are deployed.

| Existing authority | Proposed treatment / reason |
|---|---|
| spray_records and spray_jobs | Add exactly 14/7 nullable fields. Keep current owners and ordinary legacy permissions. New fields alone do not establish admission. |
| spray_jobs_freeze_completed_provenance + its trigger (201) | Extend planning freeze without removing four resistance provenance checks or ANY-live-linked-record predicate. Audit concurrent linkage and delete/relink escape routes. |
| spray_records_validate_job_link (033) | Preserve same-vineyard job linkage. New admission additionally locks and binds recipe/job revision. |
| spray_records_derive_block_ids (195), spray_records_validate_block_vineyard (197) | Preserve derived block projection and elevated cross-vineyard veto. Source permits missing historical block IDs deliberately; do not retrofit existence constraints onto history. New execution requires live scoped physical selection. |
| manual_spray_compatibility_before_write_v1 / manual_spray_compatible_tanks_v1 (233) | Preserve released-client manual tank projection. Final admission validates the stored post-trigger representation, not just pre-trigger request JSON. Do not rerun 233's historical backfill/trigger disabling. |
| manual_spray_guard_v1 + manual sync actual-number trigger (232/233) | Keep manual factual entry isolated; never use entry_source=manual as new-planning bypass. No new planning evidence is manufactured for manual history. |
| complete_spray_record (259) | Preserve factual completion and its idempotent existing-result path. It locks Spray then Trip and must be considered in lock-order/deadlock review. Do not treat completion as start admission or regenerate quantities. |
| spray_tank_actuals_before_write; upsert_spray_tank_actual; correction/amendment RPCs (223/227/233) | Retain existing identity, scope, actuals and correction authorities. Add fresh planned-start admission only at the correct establishment seam; already-durable facts remain recoverable. Guard old direct writes from creating a new planning start. |
| trip_occurrence_operations + 276/278 RPCs | Reuse prospective occurrence identity/actions/recovery ONLY if deployment/capability is verified. Checked-in authority is described as undeployed. Does not hold the parent recipe/revision/tank lifecycle receipt; do not claim it does. |
| manual_spray_operations (232) | **Do not repurpose.** save/delete manual_entry_id contract, manual actor/result/fingerprint; not a planned recipe/Trip/tank lifecycle or immutable recipe revision. |
| spray_row_recovery_operations (228/244/245) | **Do not repurpose.** Service-authorised factual assignment recovery; actor/fingerprint/count, current evidence returned on retry, logical duplicate handling/rate guard. Not exact original planned-operation results. |
| spray_trip_correction_operations (228/242) | **Do not repurpose.** Trip metadata correction fingerprint/result_version; no immutable whole-request/recipe/tank receipt; retry reads current correction rather than guaranteed original response. |
| Existing labour/inventory/tank effect authorities | Audit complete deployed write graph before reuse. Prove stable effect key, atomic commit and read-back per effect; no new labour/inventory system or claimed exactly-once external side effect. |

The existing v2 validation harness applies the storage-only draft twice and performs direct planning updates; it does NOT exercise future operational guards. Do not relabel it as acceptance of the secured migration. Historical `spray_label_server_admission_acceptance.sql` is incompatible with WARNING ONLY and must not be applied unchanged.

## 3. Durable receipt and recovery design — proposed, approval required

### Ledger decision

No inspected source table proves the complete required receipt contract. **Approval request L1:** one dedicated `spray_planning_operations` ledger storing both immutable accepted requests/results and reconstructable recipe-revision snapshots. It is not created by this package. If the owner declines a new ledger, keep the feature disabled until an alternative audited durable authority is approved. Do not overload manual/recovery/correction tables, notes, provenance text or a client queue to pretend a server ledger exists.

One proposed ledger avoids an unapproved second recipe-revision table: each admitted create/replace operation has an immutable revision UUID and complete recipe snapshot; later lifecycle receipts reference that defining operation/revision. Additional indexes/unique constraints on revision identities/effect keys would be part of separately reviewed DDL. Mutable tables remain read projections checked against that snapshot, not the sole historical revision authority.

### Exact logical receipt schema

- operation_id UUID primary identity, generated once before any effect.
- contract `vinetrack.spray-planning`, schema_version 1; operation kind `save_plan`, `replace_plan`, `bind_route`, `start_spray`, `start_tank` (job/template writes need their own admitted kind if included).
- actor_user_id = auth.uid(), vineyard_id from locked scope, request JSONB containing the ORIGINAL full domain request. Actor in request must match auth; no identity substitution.
- recipe_revision_id UUID, recipe_defining_operation_id UUID, prior_recipe_revision_id UUID/null; record_id UUID, job_id UUID/null, trip_id UUID/null, tank_session_id text/null, actual_use_id UUID/null. Use actual native/session identifier encoding, not an invented UUID cast where the established session contract is text.
- recipe_snapshot JSONB: exact seven inputs + seven outputs + chemical lines/rate bases/quantities/tanks, equipment/geometry/basis snapshots and route binding. Inputs-only jobs/templates have no resolved output authority.
- canonical_request_sha256 and recipe_sha256: server computed SHA-256 of UTF-8 PostgreSQL JSONB text under a named digest algorithm `pg-jsonb-text-sha256-v1`; compare full JSONB equality as well, not digest alone. JSON object key order/whitespace is immaterial; array order, NULL vs omitted and canonical numeric values matter. Preserve raw operator strings exactly. Clients retain original domain JSON and use server-returned digest for receipts; do NOT compare platform-native JSON serialization hashes to PostgreSQL serialization. If wire-byte evidence is needed it is a separate diagnostic digest, not admission identity. Pin PostgreSQL/digest version and test upgrade stability before changing it.
- dependencies: exact predecessor operation IDs and accepted receipt digests, occurrence plan ID/revision/digest, equipment identity, tank number and actual commit identity as appropriate.
- immutable result JSONB containing the original typed receipt, accepted_at, server revision tokens, exact committed IDs and scoped effect references. No result built from today's mutable tables on an exact retry.
- Retain receipts and defining recipe snapshots for record lifetime/audit policy. No cascade receipt deletion on ordinary Trip/record/user soft deletion. Hard-deletion/retention policy requires explicit design review; no historical erasure to resolve a retry.
- No direct authenticated/anon/service REST writes or broad member SELECT of raw operation requests. Narrow actor-scoped recovery RPC authorises current scope before disclosing receipts; cross-device plan read can return scoped recipe snapshots without another actor's private request. Writer-only insert, no mutable successful receipt. Error logs contain safe IDs/codes, not credentials or raw operator payloads.

### Proposed RPC boundary (signatures are contract proposals, NOT installed functions)

| RPC | Proposed arguments / result |
|---|---|
| get_spray_planning_capability_v1 | Scoped vineyard; returns server contract/version, migration and validation-suite IDs, compatible occurrence/tank contract versions, and enabled=false until approved activation. No writable client flag. |
| save_spray_plan_v1 | operation UUID + complete envelope; atomically writes recipe and bound inactive Trip when supplied, job projection if intended, defining revision and receipt. A save cannot start GPS, a tank, inventory or labour. |
| replace_spray_plan_v1 | operation UUID + exact original expected revision/digest + full replacement; only eligible unstarted/uncompleted plans. Replaces inputs/outputs/chemical snapshot atomically, keeps prior receipt, allocates new immutable recipe revision. |
| bind_spray_plan_route_v1 | operation UUID + expected recipe revision/digest + explicit physical scope; validates frozen occurrence IDs/scope and stores new bound revision. No coverage or actual effect. |
| start_spray_plan_v1 | operation UUID + expected recipe revision/digest + route receipt + original activation/setup; validates record/Trip/equipment/actor scope and occurrence authority before reserved active lifecycle. Actual GPS remains behind existing Tank 1 confirmation. No invented completed rows. |
| start_spray_plan_tank_v1 | operation UUID + captured recipe revision/digest + Trip/route revision + exact session/actual identities and reviewed Actuals. Coordinates the existing tank establishment contract and receipt; not a second actual-use authority. |
| get_spray_planning_recovery_v1 | vineyard + operation UUID list + stable record/Trip IDs; returns exact actor receipts plus separately labelled current revision/lifecycle/effects. Missing receipt is NOT proof of failure while the original request may be in flight. |

Server transport maps typed revision/idempotency conflicts to HTTP409 consistently. Raw PostgREST 409 (including unique-key errors) is never duplicate success. Missing/unrecognised capability is unavailable; never fall back to direct legacy REST, a generic spray Trip, numeric coverage or a client-only Boolean. Server must enforce admission independently on every new write even if a client lies about capability.

### Admission/transaction order

1. Require authenticated actor and current vineyard role before state/receipt disclosure. Confirm same operation belongs to actor, vineyard and identical full request.
2. Serialize operation UUID; for an exact accepted retry return its ORIGINAL receipt before applying new CAS/business checks. Current authentication/authorisation still applies. Revoked actor is not entitled to a stale receipt. Same UUID/different payload/actor/scope returns operation conflict with no effects.
3. Serialize the record/job/Trip lifecycle in a common order shared by every participating RPC. Proposed order is operation lock, optional Job, Spray Record, Trip, tank/session/actual, effect rows in stable ID order. This is NOT final: catalog audit must prove compatibility with complete_spray_record's Spray→Trip order, job-link/freeze triggers and all Trip/tank writers. Where existing RPCs lock Trip before Record, refactor narrowly or adopt one common coordinator; do not nest conflicting lock orders blindly.
4. Validate immutable recipe revision/digest and expected stored projection, route, equipment and explicit chemical basis with genuine positive/finite checks. Validate resulting state after compatibility triggers; mismatch rolls back rather than accepting altered evidence. No label-permission blocking. Lock/serialize relevant job+record linkage against concurrent provenance edits.
5. Apply domain effects and ledger result in the SAME DB transaction. Successful creation stores recipe + bound inactive Trip + receipt together, never record-only/server orphan on partial failure. No network calls inside transaction. If any existing side effect is an external system or separate transaction, it needs proven durable idempotent dispatch/reconciliation; do not claim transaction-level exactly-once for it. An additional outbox/table needs separate approval.
6. Commit then respond. A server receipt lists only committed/established effects, not attempted ones. Start Tank must preserve previously established factual effects and return recovery status without manufacturing a second session or rewriting confirmed Actuals.

### Native write-ahead and restart state machine

Both platforms need one atomically replaced account/session-incarnation/vineyard-scoped attempt envelope **before** record/Trip/effect publication or HTTP. Contains attempt UUID, all stable record/job/Trip/plan/occurrence/revision/session/actual/operation IDs, complete original payloads and predecessor requests, recipe/route snapshots, local stage and acknowledged receipts. Creation time/start metadata and UUIDs are not regenerated on recomposition, reopen, retry or crash recovery.

States: `draft` → `intent_durable` → `request_in_flight_or_unknown` → `receipt_durable` → `projection_repaired` → `published`; business conflicts become `held`, transient transport failure retains the unknown original request. A disk failure before intent durability prevents transmission/success. Unknown-outcome intent cannot be edited/coalesced. New deliberate revision requires a new operation after original resolution.

On restart: fence account/incarnation, load original attempt, query actor-scoped receipt, verify every identity/full request/digest/revision, persist receipt, then repair local recipe/Trip/tank projections from exact admitted snapshot. Crash between these steps is replayable. Only matching acknowledgement clears the matching queue head; newer overlays survive delayed responses. Never infer success from a row's existence, matching ID, server timestamp, HTTP409 or an inactive Trip snapshot. If original receipt absent, retry the SAME operation; never assume safe to mint a replacement while the request may still commit.

Receipt result is original accepted state; separately fetched current state may be newer. Do not overwrite newer plan/coverage with an old receipt. Stale revision, changed scope, ended/deleted Trip, missing dependency or payload mismatch holds work for explicit resolution. No automatic rebase of uncertain payloads. Logout/account changes retain quarantined pending bytes, prevent publication into another account and never auto-reassign actor.

Existing local legacy recipe-only partial saves require an explicit repair path using a retained original complete attempt. If no such attempt survives, preserve the recipe and show repair-required; do not reconstruct the original Trip from current geometry. No automatic cleanup/delete/recreate. Fresh new-contract server creation is atomic and avoids creating this partial state. Offline creation policy is a separate approval decision; current Android calculator online prerequisite is not removed here.

### Preserve factual recovery

Reuse existing StartTankCommitCoordinator commit/resume/recover/merge and actual/session IDs. Fresh unestablished starts recheck the captured recipe. Already-established actual/session facts remain factual even when a later recipe validation fails: reconcile them, retain recovery journal, do not erase/repeat effects or deny their existence. There is no user-controlled recovery bypass for a new start. Scope and identity checks still apply. Source review found iOS tank journal account fencing needs explicit integration; vineyard/Trip checks alone are not full account-incarnation acceptance.

## 4. Physical route selection — owner decisions, not defaults

### Proposed operator flow

1. Calculator carrier card retains Single Row | Over-Row and By Area | Only Full Tanks; no dosing redesign.
2. Review shows **Planned mix: X L for Y ha** separately from **Physical work selected: N passes in named blocks**. Neither is recorded actual coverage.
3. Choose **Select work area**: block-qualified map/list of physical paths, real row context, unchanged path label and independent pass ordinal/direction where known. Explicit checkboxes/list selection; bulk ranges require block and endpoints, then a review list. No auto-selection of the first Y hectares, lowest labels, nearest route or whole blocks from intended fill.
4. Show selected geometry provenance and availability. Persist exact occurrence UUIDs, immutable physical references, frozen endpoints/row IDs and route revision once accepted. Repeated same-label passes and same labels in different blocks stay independently selectable. Missing geometry is labelled, not fabricated.
5. Review planned capacity versus physical selection. A shortfall/excess is an explicit mismatch, not silent dose scaling, extra water/area or automatic row completion. Operator deliberately revises the mix/input or physical selection and recalculates with the unchanged approved engine. Route/mix binding receives a new immutable revision and invalidates any unsubmitted start/tank confirmation; uncertain operations must resolve first.
6. Starting/selection changes no occurrence to Done. Existing frozen Live Trip does only its established per-occurrence action/traversal. Over-Row multiplies controller/width outputs, NEVER two completion actions. No historical coverage reinterpretation.

### Decisions requiring explicit owner approval

- **R1 — whole passes vs within-pass segments:** recommend initial executable scope of whole physical passes only. A smaller area requiring a partial pass remains unavailable, with guidance to revise selected work/mix. Supporting segments needs a versioned segment identity/start/end boundary and traversal/report/recovery contract; it cannot be slipped into the frozen Live Trip candidate. No segment implementation or assumed default here.
- **R2 — area reconciliation:** approve the source/algorithm for selected physical hectares, edge/boundary treatment, overlap and a physically meaningful mismatch tolerance. Controller row equivalents are not a substitute for actual physical scope. Current numeric consistency tolerance is NOT an agronomic route-area tolerance. Unknown measured area cannot become executable through operator acknowledgement alone.
- **R3 — unbound save:** recommend allowing explicitly labelled `saved_unbound` server plans with frozen mix but NO executable Trip/activation receipt until scope is bound. Alternatively require binding before Save Plan. If unbound save is chosen, the new ledger snapshot carries that phase and nullable trip_id; native Save for Later must not claim Ready to Start. No new database status value is assumed installed. Either decision preserves the original full recipe and does not fabricate coverage.
- **R4 — Over-Row physical treatment:** verify how a selected machine travel pass maps to the intended vine faces without double-counting shared boundaries. Propose one live travel/pass occurrence with separately frozen treatment context, not auto-generated Done on two row occurrences. If the current occurrence physical-reference model cannot express this faithfully, keep that route blocked until an additive contract is approved. Do not alter frozen tracking semantics to hide the mismatch.
- **R5 — offline first creation:** recommend retaining existing online initial calculator commitment for v1, then durable offline reopen/activation/actions only under admitted retained evidence. New offline initial save/start would need separately accepted policy and exact server capability cache expiry/revocation behaviour. No offline bypass on held or unsupported work.

Until decisions and server binding pass acceptance, Only Full Tanks partial-area and uncertain Over-Row binding remain non-executable, not automatically assigned coverage.

## 5. Security and legacy compatibility assessment

- Current RLS enabled does not prove admission: source 007 permits operational-role direct inserts/updates, and inherited table-level grants can cover newly added columns. Revoke-only-column strategies do not override a table UPDATE grant. Need conditional guards plus controlled RPC authority, tested against direct POST/PATCH/UPSERT, service APIs, legacy definers, child mutations and compatibility triggers.
- Guard all original/new contract-bound rows through immutable receipt linkage even if a stale writer clears fields. Deny scope change, aliasing a template/manual/legacy record, relinking or deleting dependencies to bypass admission. New execution verifies all referenced live objects in the SAME vineyard. Never rely on an RLS-filtered lookup making a foreign ID look absent.
- RLS membership roles remain the existing owner/manager/supervisor/operator roles for operational writes; read-only members/anon rejected. Do not broaden template, ended-history, inventory or recovery permissions. Existing extra actor/equipment restrictions must remain after catalog reconciliation.
- Preserve all legacy NULL-field records and old completed history unchanged, including quantities, actuals, dates, blocks and coverage. Never assign new planning evidence to legacy rows to make them pass new constraints. The new API is prospective; historical records remain under their real legacy/manual rules. Malformed/future NONNULL planning evidence is held, not downgraded to legacy.
- New guard may reject stale old-client upserts on prospective records. Surface update-required/held pending state, not success; old binaries cannot be made to understand new contract by SQL alone. Portal and every writer/reader need compatibility acceptance before activation.
- Freeze evidence by admitted immutable revision and underlying projections, not just the new fields. Existing historical correction APIs remain factual/audited and do not rewrite frozen planned evidence. Any necessary exclusion must be specific, scope checked and proven—not an arbitrary bypass flag.
- A live capability must be server-authorised and versioned after acceptance. Schema presence or a successful SELECT is not enabled capability. Unknown versions and a server rollback disable new starts but preserve established factual recovery/pending receipts.

## 6. Non-production validation and evidence levels

### Can be done now without a database or paid infrastructure

- Source audit and contract/decision documentation (this package).
- Read-only capture script syntax and safety/static inspection. Actual request failed 401; no definitions were obtained.
- Existing local model/parser/journal tests can be rerun, and isolated contract tests can be authored after receipt/route decisions. They would be LOCAL evidence only. No native test counts from previous passes are claimed as new execution.
- Do not run the old CF-permission SQL or storage draft against production. A minimal synthetic schema cannot prove complete-schema security/compatibility.

### Requires authorised metadata access, not a feature deployment

- Complete current catalog/function bodies, trigger order/call graphs and effective grants; resolve discrepancies from source and sign a drift manifest. A function hash without its body is insufficient.
- A full restorable schema including relevant auth/storage/extension dependencies, password-free custom roles/memberships/default ACLs, policies and functions. Existing catalog JSON is NOT this dump. Use synthetic users/vineyards/business fixtures; no production customer-data copy.

### Requires approved free/local or existing non-production integration environment

Prefer an already-authorised disposable local full Supabase/PostgREST/auth stack if resources are adequate; otherwise an existing owner-approved test project. **No paid project, branch, instance, backup or infrastructure creation** without approval. Never register test webhooks, cron/integrations or production external endpoints in the clone. Restore schema faithfully while quarantining outbound effects. Verify clone manifest parity rather than reconstructing from checked-in historical migrations.

The old 276 bootstrap and canonical reader-compatible fixture are not sufficient. Install the final reviewed candidate ONLY in the approved clone; validate both the unchanged baseline and migration postconditions. Use real authenticated JWTs/PostgREST roles and actual current trigger/policy/function bodies. Local SQL tests with simulated auth are a different evidence tier from actual JWT/HTTP acceptance.

### Mandatory four-combination matrix (all unexecuted in this package)

Run Single Row/By Area, Single Row/Only Full Tanks, Over-Row/By Area, Over-Row/Only Full Tanks; Full Tank exercises target_area AND calibrated_rate. For each:

| Scenario | Required assertions |
|---|---|
| Save → reopen | Exact 14 fields, original raw units/text, chemical/tank values, geometry and immutable revision survive DB/REST/native encode/decode. Jobs have seven INPUT fields only. No catalogue/settings reinterpretation. |
| Start Spray | Exact recipe/revision/route linkage and one permitted lifecycle effect; no coverage or unintended GPS/tank/labour/inventory effect. Tank 1 gate retained. |
| Start Tank | Captured recipe revision still matches immediately before establishment; exact actual/session IDs, approved Actuals and established effects persist once. |
| CF 2.00 | Unknown label approval, concentrate permission and limit yield advisory data; Save/Start/Tank/replay pass if otherwise valid. No acknowledgement field needed. |
| Genuine invalidity | NaN/±Infinity/zero/negative, CF<1, malformed/future provenance, missing dimensions, partial tuple, explicit-basis omission, invalid chemical unit/quantity and output mismatch reject atomically, zero new effects. |
| Roles/scope | Nonmember, read-only role, wrong actor, foreign vineyard/block/job/equipment/record/Trip/session, forged digest/revision/capability/GUC and role escalation all reject before information/effects. |
| Exact duplicate | Simultaneous same UUID/full request returns original immutable result once; changed request or actor/scope rejects. New UUID cannot duplicate same session/effect key. |
| Lost acknowledgement | Drop response after COMMIT; native retains intent, recovers exact receipt, repairs local projections; no second Trip/session/labour/inventory and no false success before receipt. |
| HTTP409 | Unique violation/conflict is held; not inferred success. Query original receipt/current state; no identity remint or silent CAS rebase. |
| Partial persistence | Fail before/after local intent, HTTP commit, receipt write and each local projection repair. Original IDs/payload retained and process-restorable. Unrecoverable legacy recipe-only save remains explicit repair-required. |
| OS termination/offline | Actual kill/relaunch, offline retained queue, reconnect and delayed/duplicate/out-of-order acknowledgements on BOTH platforms. Store recreation is supplementary, not equivalent. |
| Route | Explicit subset, repeated labels, distinct same-label blocks, mismatch/no geometry and approved Over-Row binding; starting/selection credits no coverage; one traversal/action cannot complete a second occurrence. |
| History/legacy | Byte/JSON equality of pre-existing records/Trip Actuals/coverage; completed planning mutation/clear/relink/reopen/cross-scope writes fail. Legacy NULL/manual flows and released-client compatible tank projection unchanged. |
| Concurrency | Job edit vs record link, recipe replace vs Start/Tank, two devices, completion vs start and deadlock/serialization retry all preserve original intent and immutable evidence. |
| Factual recovery | Durable actual-only/session-only/already-completed-session cases recover exact facts, even after later planning denial; missing/unestablished facts do not get invented. |
| Consumers | Native and Portal reopen/review/report/export, old REST writers and full composite/SELECT * readers; no numeric downgrade, duplicate-label collapse or recipe-derived actual coverage. |

Evidence report must separately list SQL/model tests, full-schema role tests, authenticated HTTP/JWT integration, native production entry-point journeys, actual OS-process restart/offline, Portal and physical handset acceptance. No test is passed until executed. No screenshot proves hidden exactly-once/atomicity.

## 7. Approval register and safe continuation

| ID | Approval / prerequisite | Current state |
|---|---|---|
| A0 | Valid read-only access or complete sanitized schema-definition export | BLOCKED: configured Management token returned HTTP401. Access repair is not SQL execution approval. |
| L1 | New dedicated immutable planning operation/revision ledger and inaccessible writer role | Requested; no table/role created. Existing three operation tables will not be repurposed. |
| R1–R5 | Whole passes/segments, physical area reconciliation, unbound saves, Over-Row physical treatment and offline initial creation policy | Owner decision required; recommendations above are not assumed defaults. |
| E1 | Named disposable full-schema non-production environment and permissible restore/synthetic fixture scope | Not designated/created. Any cost requires separate approval. |
| I1 | Final catalog-bound SQL/RPC implementation and review, after A0/L1 and relevant route decisions | Not final; do not apply current v2 draft or old CF-authority acceptance SQL. |
| T1 | Installation of reviewed candidate in approved test environment and authenticated integration/fault-injection/native test runs | Separate approval before environment mutation; no test installation executed. |
| P1 | Production migration and any server/Edge deployment | Explicitly NOT authorised. Requires accepted test evidence, fresh drift check, reviewed execution/rollback and separate owner approval. |
| G1 | Capability enablement and any mobile release/distribution | Explicitly NOT authorised. Server version/capability, durable recovery, route/Portal and all required lifecycle acceptance must be green first. |

## 8. Checks actually executed for this package

- Python capture script compilation: **passed**, `python3 -m py_compile scripts/inspect-spray-planning-contract.py`.
- `git diff --check`: **passed**. New script/document were read back for review; whitespace checking of tracked diffs is not a SQL/runtime test of those new artifacts.
- `git diff --exit-code -- ios android-vinetrack sql supabase`: **passed**, no differences. Only this report and the read-only capture script were added.
- Current catalog request: **failed HTTP401**, no complete definitions obtained; not a passed read-only inspection.
- No new SQL/RPC/role installation, schema restore, authenticated server tests, native builds/tests or physical-device runs. Native source/artifacts were intentionally left unchanged. Python syntax validation is the validation surface for the only new executable code, not a native build claim.

Next safe development step: repair read-only metadata access, review full definitions, settle L1/R1–R5 and identify E1, then produce exact final SQL and server code bound to that catalog. Nothing in this package changes production, enables a gate or modifies the frozen Live Trip candidate.
