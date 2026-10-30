# Trip delete acknowledgement: 30 October 2026

## Confirmed defect

The iPhone reports one pending upload and one pending delete. Edge logs for build 188 at the screenshot time identify the delete lookup as the same retained Trip previously investigated. An administrative database read confirms that exact Trip is physically absent; its occurrence receipt list is also absent. This establishes current absence, not a claim about whether it ever existed.

`SupabaseTripSyncRepository.requireTripWrite` previously required one server row before invoking `soft_delete_trip`. An absent Trip therefore raised `WRITE_SCOPE_UNRESOLVED` forever, before the service could treat an already-missing delete as satisfied. An empty user SELECT cannot itself prove absence because RLS also hides inaccessible rows.

## Narrow correction

- Add read-only `confirm_trip_absence_v1(uuid)`. Its public entry point is SECURITY INVOKER; its internal helper has an empty search path and checks the authenticated actor before inspecting existence.
- A physically absent UUID returns schema version, exact Trip ID, authenticated actor ID, and `absent=true`.
- An existing accessible row returns `absent=false`; an existing inaccessible row raises an authorization error. Soft-deleted rows remain present for this test.
- Anonymous execution is revoked. No customer rows are created, changed or deleted, and existing table policies and old RPC signatures remain unchanged.
- Only the delete path may use the absence confirmation. Ordinary updates still need the original write-scope checks.
- iOS accepts the receipt only for the exact record and actor, with the account generation unchanged before/after the awaited request. A sign-out/sign-in to the same user is not the original account incarnation.
- Any failure to obtain or decode proof remains pending. It is wrapped so the pre-existing broad missing-row text matcher cannot mistake a missing RPC or transport error for successful deletion.
- Existing normal delete behavior and all old routes are retained. No queue reset or synthetic Trip is introduced.

## Deployment and evidence

Migration `20261030041859_trip_delete_authoritative_absence_v1` was applied and its permissions/search paths verified. Rork must not blindly apply it again.

Rollback-only SQL tests executed as `authenticated` passed: exact absent Trip receipt; existing Trip not absent; null ID rejection; missing actor rejection; hidden Trip rejection; anonymous execute denied. No customer data writes.

The production receipt helper and ten focused Swift tests compiled and passed with Swift on Linux. These cover success, existing/wrong record, wrong actor, future version, changed account, new incarnation of the same account, signed-out state, malformed JSON, and protection from the legacy missing-row shortcut. Full native iOS repository compilation and original-device acceptance have NOT run here.

Eleven source-inventory tests passed. The register adds exactly one literal RPC callsite and no dynamic dispatch changes. Static Swift syntax parsing passed. These checks do not replace Xcode builds.

## Rork acceptance

Use this change on the existing PR #22 branch, preserving newer work. Run `TripDeleteAbsenceReceiptTests`, focused Trip deletion/replay/account-isolation regressions and one iOS simulator build. Validate an originally queued absent-Trip delete clears only after its server receipt, while inaccessible Trips and network failures remain queued. Retain all unrelated local edits and original recovery evidence. Do not publish or declare device recovery from helper tests alone.

The separate pending upload remains unidentified from the screenshot. This change must not mark it successful or clear it. Fresh Sync diagnostics are needed to identify that remaining record before declaring all synchronization resolved.
