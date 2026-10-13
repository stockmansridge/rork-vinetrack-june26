# Spray label admission — separate review proposal

Status: DESIGN ONLY, 2026-10-13. No deployment, authority data seeding, workflow activation or production DDL authorised. This is separate from `sql/review/spray_configuration_full_tank_planning_draft.sql`. Application and chemical quantity engines stay frozen.

## Inspected evidence and reuse

The previously captured live catalog and a fresh authorised read-only inspection were used; no customer chemical rows were exported. `scripts/inspect-spray-label-authority.py` reproduces the targeted read-only inspection. Its private result is `/tmp/vinetrack-authority-private.2g52cwr0/inspection.json` (not a restore artifact).

| Existing relation | Reuse | Not sufficient to grant permission |
| --- | --- | --- |
| `chemical_v3_product_revisions` | Product/revision identity, country, registration scheme/number, label SHA/version, vineyard uses, review provenance and unresolved conflicts | `review_status=approved`, `core_fields_complete`, discovery confidence or generic label-link verification |
| `chemical_v3_documents` | Revision-bound manufacturer/regulator evidence, immutable content hash, storage reference, page/version and currentness | Front artwork, `is_current` alone, identity verification or a mutable external URL |
| `chemical_v3_rate_options` | Applicable rate basis/unit/value/range, targets, method/condition/raw text, document/page linkage | `max_value` is an upper REGISTERED RATE, not a maximum concentration factor; `needs_review=false` is not concentrate permission |
| `saved_chemicals` | Vineyard-scoped product lookup and V3/master identifiers | Manager-editable preferred rates, mirrored verification flags, copied label references or snapshots; foreign keys do not ensure a revision belongs to the stated product |
| `master_chemicals` | Approved registration identity, official/manufacturer references and use evidence; deterministic registration bridge where reviewed | `verification_status=verified`, `review_status=approved`, source kind, generic registered uses or active-ingredient strength without explicit applicable label directions |
| `chemical_v3_products` | Require `status=approved`, approved revision pointer, matching country and revision/product relationship | A current discovery revision must not replace the approved revision implicitly |

Observed targeted live data: 26 approved revisions (17 with label hashes); 19 current manufacturer-label documents, all hashed; 6 rate options (4 per hectare, 2 per 100 litres), all with NULL application method and no `source_document_id`. Fourteen approved revisions contain dilute/concentrate terms in `vineyard_uses`; that is a discovery clue, NOT permission. No structured reviewed concentration contract was established. No full label was certified by this inspection. An additional read-only key-only inspection of `master_chemicals.registered_uses` found direction/rate IDs, provenance, source_refs, raw_text, conditions, restrictions and rate min/max; Saved Chemical uses also contain method and user-confirmation flags. These can locate applicable evidence but contain no established typed reviewed concentrate-limit contract. No customer values were selected or exported.

Inspected writer definitions reinforce the distinction: `chemical_v3_admin_save_rate_option` permits manually entered rates without a document link. `chemical_v3_replace_ingested_rate_options` does not populate source_document_id and can replace ingested rates without an approved-revision status guard. `chemical_v3_sync_rate_options_json` mirrors rates, not authority. Generic review actions can confirm an external label link or acknowledge warnings; neither is a concentrate approval procedure. `approve_chemical_v3_revision` checks core fields and resolved generic review issues, promotes saved copies and records catalogue approval; it contains no explicit concentrate-permission or limit validation. The gate must invalidate admission if any cited content changes even on an approved revision.

## Smallest additive authority proposal

Do NOT create another product, document or chemical-authorisation catalogue. Add one nullable, versioned `application_admission_evidence jsonb` to existing `chemical_v3_rate_options`, written only through a reviewed system-admin procedure. NULL means unknown. This field is NOT populated automatically from existing status/ranges or AI text. Approved rows are immutable: revisions of policy or evidence require a new reviewed revision; legacy ingestion paths must be prevented from mutating approved evidence. No new ordinary-client write grant.

The reviewed object binds:
- Exact revision/product registration identity, vineyard crop/use/target, jurisdiction (including applicable regional rules), physical application method, condition and validity period.
- A source document in the SAME revision, content SHA-256, label version, page/section and literal permission/limit excerpts. Require approved regulator/manufacturer directions applicable to that registration. Hash authentic downloaded label content; label identity/currentness are separate checks.
- Explicit permission state `allowed`, `prohibited` or `unknown`. Allowed requires evidence-specific reviewer identity/time and a digest of all bound rate/use/document content. Generic product approval is not sufficient.
- Label-defined dilute reference rule, concentration rule and typed applicable limits: max factor ONLY if expressly stated; minimum carrier, maximum product concentration, per-area/tank amount or other ceilings only with units and scope. An absent numeric maximum never means unlimited; unsupported/unbounded rules remain non-executable until an enforceable rule is reviewed. Reuse a registered-rate maximum only as the bound on that rate and only for its applicable use.
- Supported reference interpretation/version. No free-text expression evaluation in SQL. Unsupported rules or unverifiable predicates fail closed.

Use `source_document_id` and `source_page` already present for evidence linkage; the object additionally pins their hashes and excerpts. Database shape validation must be strict and versioned. A single server-admin procedure validates joins, evidence binding and limits atomically. Existing system-admin identity is necessary but not, by itself, proof of label applicability. Saved Chemical/master edits cannot manufacture this permission. A master-only product requires a reviewed identity bridge to the V3 evidence chain before dilute execution; do not fuzzy-match names or silently upgrade historical snapshots.

## Trusted application evidence and independent validation

One internal `assert_spray_label_admission` routine, used by all boundaries, validates every product in its actual tank. It never accepts client CF, cached approval or an acknowledgement as authority.

1. Resolve vineyard ownership/jurisdiction and Saved Chemical identity from server rows; require matching approved product/revision/registration/document/rate/use. Reject mismatches, stale policy, conflicts, retired evidence, future basis tokens and ambiguous legacy dual-basis recipes.
2. For area-based recipes, validate the selected area basis and applicable registered amount limits. Preserve the exact existing quantity equation, with NO CF multiplication. Area evidence cannot be fabricated from Full Tank partial area into physical rows/blocks.
3. For dilute-derived recipes, independently establish positive finite tank carrier V, intended treatment area A and label-defined dilute reference D. Reference D must come from a reviewed rule evaluated against server-bound application evidence, not `recommended_rate`, client CF, client dilute snapshot or arbitrary JSON. Validate consistency between V, A, selected configuration, calibration and frozen inputs. Controller travel width is not physical row spacing.
4. Where the reviewed reference rule is the existing physical L/ha comparison, compute `required_CF=max(1,D/(V/A))`. For D=713 and V/A=500, required CF=1.426 even if the client declares 1.00. Independently check the frozen product quantity and mixture concentration against the reviewed applicable rule/limits; reject inconsistency, never recalculate or silently overwrite it. A deliberately underdosed dilute-derived recipe cannot escape classification merely by setting CF1; nor can it be relabelled area-based without an applicable area-rate option.
5. The current database does NOT establish a trusted server dilute-reference/calibration contract. Before this routine may approve execution, reuse reviewed server geometry/calibration where actually available, otherwise add a server-owned, versioned application-evidence envelope bound to record/version/tank and recipe digest. Operator factual canopy/calibration inputs may be captured through an authorised validation procedure but are not independently measured truth; missing or contradictory facts block. No client-editable settings become label authority. Prove reference parity with frozen engines in staging rather than inventing a new canopy formula.
6. CF>1 requires explicit allowed concentrate directions AND enforceable applicable limits. Prohibited or unknown => reject. CF<=1 still requires an unambiguous applicable dilute reference/use; no unknown-basis fallback. An allowed flag with missing bounds/rule is not enough.

The proposed evidence envelope, if needed, is a nullable server-owned column on the existing spray record, not another chemical table; it must be separately reviewed after the full operational definitions are restored. This is an approval dependency, not an already-existing trusted source. Old clients that supply sufficient existing facts can be validated; otherwise return an actionable refusal, not a default reference. Historical factual reads are unaffected.

## Enforcement boundaries and atomicity

Install ordinary BEFORE triggers on the existing tables, including direct PostgREST writes. RLS remains unchanged and is enforced in addition to admission. System/service business writers are also subject to these triggers; no client-set session variable or `is_template`/status toggle is an exemption.

| Boundary | Required behavior |
| --- | --- |
| `spray_records` INSERT / material recipe UPDATE | Validate effective NEW tuple, including OLD values for omitted PATCH keys. Ordinary insert must not bypass by marking itself completed/manual. Preserve completed history; reject executable reuse or material recipe changes requiring new admission. Unrelated notes/history read/write follows existing protection contracts. |
| `spray_jobs` executable transition / live recipe edit | Validate immutable execution recipe, not input-only template outputs. Templates/drafts may keep unknown evidence but are explicitly non-executable. Claim/activation MUST revalidate. |
| Spray-linked `trips` INSERT / activation / relink | Require admitted linked record/job in same vineyard and current recipe version. Old/direct spray Trips without verifiable linked recipe are refused. Non-spray Trips unchanged. |
| Tank session INSERT / start / material recipe change | Validate actual selected tank; never aggregate one tank's area-only CF into another tank's dilute decision. Direct table/session routes require same check as RPC routes. |
| Start/claim/worksheet/tank RPCs and inventory/events | Call routine before any side effects, then hold locks on recipe and authority through commit. Rejection rolls back Trip, job claim, tank, marker, inventory, labour and event writes atomically. |
| Offline replay / older clients | Server reads current approved authority at every attempt, independently of client version or omitted new fields. Repeated rejection changes no operational state. Successful retries use original idempotency key/version and cannot duplicate effects. |

The known live functions `save_spray_trip_worksheet_v1`, `upsert_spray_tank_actual`, `validate_spray_tank_actual_chemicals_v1`, `spray_tank_actuals_before_write` and completion flows must be examined with all callers after restore; a trigger only on `spray_records` is NOT complete protection. Final object-by-object installation SQL awaits the full clone, including alternate direct routes.

Use stable lock order (authority -> recipe/job -> Trip -> tank), check recipe/policy digests under locks, and freeze accepted evidence with the record. Lock approval/revocation paths compatibly so authority cannot change between check and commit. No external network call inside a transaction. Preserve SECURITY DEFINER actor/vineyard checks; schema-qualify all names, fixed safe search_path, revoke PUBLIC execution on internal routines. Privileged database administrators can disable triggers; they are outside the client threat model.

Preserve Manual factual-entry RPCs for already-applied history, using their existing protected completion/actuals contracts; never convert that factual entry into executable permission. Reads and frozen quantities are never backfilled/recomputed. Keep completed provenance immutable, including the new planning tuple. Do not add a generic client-controlled `manual` bypass.

## Error contract

SQLSTATE `23514`; MESSAGE prefix `SPRAY_LABEL_AUTHORITY_UNVERIFIED` (unknown), `SPRAY_LABEL_CONCENTRATE_PROHIBITED`, `SPRAY_LABEL_LIMIT_EXCEEDED` or `SPRAY_LABEL_RECIPE_INCONSISTENT`. Safe structured DETAIL identifies line/tank/product IDs, approved product display name, reason, applicable rule and remedy; HINT says, for example: “Wettable product: concentrate spraying permission is not verified for this label/use. Select a verified applicable label/use or a supported dilute application and submit a new plan.” Do not imply any arbitrary carrier increase automatically makes the application compliant. No token/customer personal information in errors. Clients preserve original rejected payload/id/retry metadata and publish no success; expose product-specific actionable error without automatically altering quantities.

## Required isolated acceptance before installation approval

Synthetic label documents/revisions/options for allowed/bounded, expressly prohibited, unknown, stale hash, wrong jurisdiction/method/target, generic-verified-only, max-rate-only, ambiguous old client, spoofed CF1 and unsupported rules. Positive area-only/manual/historical controls. Verify required_CF1.426 from713/500 and CF1 from713/750; enforce label limits at boundary values.

Prove actor can legitimately edit fixture BEFORE chemical denial. Test record INSERT/UPDATE, jobs, direct Trip/tank, all RPC variants, concurrent recipe/policy replacement, offline original payload replay and exact zero-side-effect counts after rejection. Existing `spray_label_server_admission_acceptance.sql` is only a first direct UPDATE assertion, not the full matrix or the enforcement itself.

No server gate should be deployed until reviewed evidence semantics, trusted application-reference contract, full route coverage, native-auth/RLS/role restoration and these assertions pass in an approved isolated environment. SQL v2 persistence can be tested independently; it never grants chemical permission.
