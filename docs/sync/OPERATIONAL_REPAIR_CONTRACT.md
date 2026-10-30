# Operational repair contract: 3.1.8 / 3.1.9

This is a release contract, not a declaration that the entire release has passed. The incident repair belongs to PR #22. Keep the recently improved iOS guided Spray Program order, compact rate cards and navigation. Android must match its decisions and results. Do not reintroduce the previously excluded three-row or true over-row configurations.

## Non-negotiable sync rules

1. A timeout, 401/403, cancelled fetch, decoder failure, incomplete page, different permission scope, or not-yet-loaded cache is NOT an empty authoritative dataset. Retain verified local data; show the actual failure. An explicit denied account cannot read retained field data until same-account recovery succeeds.
2. Only explicit authorised tombstones or a separately verified reconciliation contract may remove local server-backed records. Never infer deletion from a truncated list or wipe a store on refresh failure. Pending edits, photos, drafts, receipts and active trips are not disposable cache.
3. Account incarnation, vineyard identity and selection generation accompany reads, writes, caches and publications. Check them again after every suspension. Never bind an old request to a new account's token or publish another vineyard's rows.
4. Persist user intent before transport. Use stable operation/entity IDs. A timeout after commit is an unknown acknowledgement, not permission to create a replacement. Retry the same operation and recover its receipt.
5. Acknowledging an older payload must not clear a newer local edit. A conflict is not a retryable network error. Preserve the user's value and mark it for review.
6. Parent-before-child ordering applies per Trip/task/application, not as a global all-or-nothing lock. Trip creation, planned route, tank records, actual quantities and completion must retain their dependency gates. A failed photo/history fetch must not hold all operational reference data hostage.
7. The 3.1.8 contract stays usable. Add optional fields/versioned endpoints; do not rename or remove fields or require new request arguments on old endpoints. Never let an old client replace a new JSON object and erase unknown fields. Unsupported occurrence edits must not downgrade the record or corrupt row coverage.
8. Re-authentication and read-only entitlement holds retain original work and IDs. A confirmed revoked session is not an endless refresh loop. A temporary network failure is not a logout. Do not advise reinstall, storage clearing, or blind sign-out during recovery.
9. Overall success means required reads succeeded and eligible uploads were acknowledged. Report per-entity last success, retained data, pending/held/conflicted counts and actionable error. Do not mark the whole system green after a pull-only success.
10. Every new sync surface must enter the register and receive old/new fixtures, failure/restart tests and a bounded-work review. `scripts/audit_sync_inventory.py --release-gate` intentionally refuses unverified release baselines.

## All-entity coverage boundary

The register covers the iOS coordinator calls and all Android persistent pending-write discriminators. Review the following families AND independently scheduled queues: account/membership/entitlements; vineyards/blocks/rows/planting allocations; pins/custom types/segments/capture evidence/photos; Trips/start/metadata/GPS/route/occurrences/tanks/labour/end/delete; spray Programs/templates/steps/jobs/records/targets/legacy paired saves/manual entries/tank actuals/weather snapshots; chemicals/catalogue/approved revisions/rate preferences/presets/labels/inventory/prices; tractors/modern machines/spray units/equipment/fuel purchases/fuel logs; work-task headers/blocks/labour/machines/materials/piece-rate rows; maintenance/photos; growth observations/images; yield sessions/samples/weights/historical estimates/picking; pruning seasons/entries/activities/allocations/resources; fertiliser/fertigation/irrigation; resistance plans/manual issues; region/units/vintage/preferences/buttons; weather/provider history/forecast caches/alerts/notices/documents.

Inventory coverage alone does not certify each serializer, merge policy, delete path, or endpoint. Record semantic findings separately and do not change the two release-verification booleans merely because the inventory gate passes.

## Scaling acceptance

Already implemented in this bundle: priority publication of operational equipment, coalescing identical Android vineyard refreshes, complete keyset pagination on repaired equipment/reference reads, finite request/page budgets, and invalid tank-count allocation guards. These prevent specific stalls and partial reads; they are NOT a complete delta-sync conversion.

Before release, measure cold bootstrap, warm no-change sync, ten changed records, offline restart, repeated refresh taps, a backlog with photos, and an active Trip across representative 1x/10x/100x histories. Record calls, bytes, rows decoded, peak memory, main-thread stalls, time to usable equipment and total convergence separately.

Warm incremental work must scale with changed rows rather than total history. Use durable per-entity cursors including stable tie-break IDs, server-assigned watermarks, overlap/deduplication and tombstones. Commit a cursor only with the successfully persisted page. Never use the phone's completion time as proof that all server changes before that instant were read. Bootstrap/history loading must be paginated and resumable; history and media cannot be prerequisites to opening Start Trip. Bounded independent concurrency and backoff must preserve write ordering and account fences. Do not claim these acceptance conditions passed without measured results.

## Spray review and start contract

The final Start Trip confirmation on both platforms lists actual product rates with units and basis and requires explicit confirmation. Per-100 L values show the concentration actually mixed, including concentration factor; whole-block and treated-area hectares remain distinct. Confirmed evidence is invalidated when the recipe or scope changes and is not restored as consent after process death. Store the exact reviewed recipe, not a recomputed version after an asynchronous weather fetch. Later tank actuals remain distinct from pre-start confirmation.

Advisory concentration-factor/label uncertainty, unconfigured weather, unavailable prices, and EL Not Set must not block an otherwise valid operational start. Keep real errors: non-finite/negative/zero required quantities, ambiguous treated-area basis, missing required route geometry, foreign-vineyard references, denied write authority, duplicate active-trip conflicts and failed durable storage. Keep errors visible; moving instructional prose into an info button is not permission to hide a blocker or a safety warning.

Test each supported entry route: new standalone calculation; Program Step reuse; Save for Later then Start; queued create/receipt recovery then Start; saved paused/resumable Trip. Each must reach the active Trip screen with the same Trip ID, selected equipment, blocks, recipe and route. A synthetic database activation alone is not a device-navigation pass.

Test supported geometry and mathematics independently: whole and partial verified blocks; multiple blocks with differing row spacing; both travel directions; sequential/alternate/repeated/manual path selection; half/open-ended paths; 2-row airblast aisle coverage versus one-row/undervine coverage; whole-block/treated-area/per-100 L/per-100 m product bases; manual total-water mode; full/partial/exact-multiple tanks; mixed liquid/solid units; concentration factors below/equal/above one. Free Drive must not invent coverage. A proposed Full Tanks preview without verified physical work is not made operational simply by removing its guard.

Independent reference example: 10 gross ha, 31,250 row m, 3.2 m row spacing and 0.8 m total band width gives 2.5 treated ha. At 20 L/100 row m, total water is 6,250 L: three 2,000 L tanks plus 250 L. Products at 2 L/gross ha, 2 L/treated ha and 100 mL/100 L require 20 L, 5 L and 6,250 mL respectively. Assert conservation and unit conversions, not just iOS/Android agreement.

## User-interface rule

Preserve the existing fast guided flow. Long explanatory help belongs in an accessible `i` button beside its heading, with an appropriate sheet/dialog. Do not truncate it to one line or add new mandatory tutorial pages. Essential values, concise validation messages and advisory warnings remain visible. Verify compact and accessibility text sizes on both platforms.

## Release evidence and limitations

Live backend permission repair `occurrence_actor_identity_compatibility_v1` has passed rollback-only authentication/request checks, occurrence create/replay/recover/activate checks, legacy Trip insert/update checks and authenticated equipment visibility. Customer field records were not altered by those probes.

Source bundle commit: `ed652159796d58608f76a19502ac38de8dccacaf`. Actual-rate confirmation, reviewed-recipe preservation, reference read hardening, pending-ack protection and focused tests are committed. Exact shipped 3.1.8 source/binary matching, all-entity semantic certification, growing-history measurements and physical-device acceptance remain unverified. Keep one coordinated candidate; no main merge, public release, destructive migration, broad auth-policy rewrite or version-floor increase until the missing evidence is supplied.
