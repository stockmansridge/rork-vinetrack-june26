# Legacy branch and pull-request preservation ledger — 2026-11-03

**Purpose:** The owner has requested a single active development branch (`main`) and removal of stale review queues. This records the original exact SHAs *before* closing legacy PRs. Closing a PR is **NOT** evidence its unmerged changes were applied to `main`, and no customer data or app-binary delivery is affected by this ledger.

**Pre-cleanup main:** `eb6878f29dd312f5f202706a935fa85ad0a555f7`.
**Inventory:** 36 open PRs, 50 branch refs including main. GitHub compare inspections of all 36 open PRs against main reported ahead commits on their heads (even when equivalent fixes may have been cherry-picked). Do NOT bulk-merge these old branches.

## Priority unmerged work to recheck against current main before treating it as complete

| PR | Area | Risk / action |
|---|---|---|
| [#51](https://github.com/stockmansridge/rork-vinetrack-june26/pull/51) / [#50](https://github.com/stockmansridge/rork-vinetrack-june26/pull/50) | iOS Trip and tank recovery | Source differs from main in multiple iOS files; never auto-merge old queue semantics. User says current crash resolved; only port an independently reproduced gap. |
| [#45](https://github.com/stockmansridge/rork-vinetrack-june26/pull/45) | Scoped Sync Support Snapshot | Extra diagnostic code not assumed to be on main; customer-data scope and privacy-sensitive. |
| [#44](https://github.com/stockmansridge/rork-vinetrack-june26/pull/44) | Tank Actual native contract tests | Tests/docs only; unmerged; do not imply regression coverage is live. |
| [#38](https://github.com/stockmansridge/rork-vinetrack-june26/pull/38) | Canonical sync contracts/governance | CI and docs not automatically applied to main. |
| [#36](https://github.com/stockmansridge/rork-vinetrack-june26/pull/36) | Chemical catalogue effective-rate mobile reads | Has non-main source changes; recheck 3.1.8/3.1.9 old/new catalogue parity before closing requirement. |
| [#26](https://github.com/stockmansridge/rork-vinetrack-june26/pull/26) | Quadrant Count (System Admin gated) | Has separate iOS and Android source changes; verify feature-gated presence on main before declaring complete. |
| [#23](https://github.com/stockmansridge/rork-vinetrack-june26/pull/23) | Shared bunch-weight sync / yield recovery | Contains unmerged changes that require separate data-contract audit. |
| [#6](https://github.com/stockmansridge/rork-vinetrack-june26/pull/6) | Pin travel direction | May affect historic pin placement and needs data-evidence testing before porting. |
| [#2](https://github.com/stockmansridge/rork-vinetrack-june26/pull/2) | Chemical inventory / upcoming work tasks | Older mobile feature changes not assumed to be on main. |
| [#3](https://github.com/stockmansridge/rork-vinetrack-june26/pull/3) | Contour rows mobile notice | Low-priority independent UI work. |

## Original open PR snapshots (none to be automatically merged)

| # | PR title | Branch | Original SHA |
|---:|---|---|---|
| [#51](https://github.com/stockmansridge/rork-vinetrack-june26/pull/51) | P0 iOS build 209 follow-up: Trip tank → Actual Use → finalise → Spray recovery | `fix/ios-p0-build209-complete-sync-chain` | `1747fbf1f47839c8731c405b897fd24c62682adb` |
| [#50](https://github.com/stockmansridge/rork-vinetrack-june26/pull/50) | P0 iOS build 208: preserve locally ended Trips, match archived tank precision, reduce sync scroll lag | `fix/ios-p0-trip-sync-build208-reconciliation` | `39bdc353fe7f7079e9b2df9a43c321d21b00430d` |
| [#45](https://github.com/stockmansridge/rork-vinetrack-june26/pull/45) | [DRAFT / NOT RELEASE-READY] Scoped Sync Support Snapshot — iOS + Android | `feature/system-admin-full-sync-diagnostics-20261102` | `c1694747fb58aba031c17275c9c88a80ae18aac1` |
| [#44](https://github.com/stockmansridge/rork-vinetrack-june26/pull/44) | [DRAFT / RED FIRST] Issue 43 Tank Actual encoder and ACK contract tests (branch-only) | `issue43-tank-actual-p0` | `4ccb71560d8828763a9815c4acf7aff89e0806b8` |
| [#39](https://github.com/stockmansridge/rork-vinetrack-june26/pull/39) | Fix occurrence UUID deploy preflight to verify delegated auth guards | `fix/occurrence-uuid-deployment-preflight-20261102` | `cc0808e8e053ca31b18d142e2c3ee4e4c92ab579` |
| [#38](https://github.com/stockmansridge/rork-vinetrack-june26/pull/38) | Governance: canonical iOS/Android/Portal/Supabase sync contracts and CI guard | `governance/canonical-sync-contract-v1-20261102` | `637d646181a4b7cab1ab0ed8da3db1e84c7a327e` |
| [#37](https://github.com/stockmansridge/rork-vinetrack-june26/pull/37) | Android P0: let new row-planned Spray Trips start despite unrelated legacy Save-for-Later journal | `fix/android-qualified-spray-start-legacy-journal-isolation-20261102` | `7b52089b946bc5af22cc6afb6a3cb37d83db308e` |
| [#36](https://github.com/stockmansridge/rork-vinetrack-june26/pull/36) | v3.1.9: include missing live catalogue sync reads on iOS and Android | `fix/catalogue-effective-mobile-read-parity-20261102` | `8d36a996f8d39ad3d8c27422bd63ae8aec65f779` |
| [#35](https://github.com/stockmansridge/rork-vinetrack-june26/pull/35) | Hotfix: prevent iOS Trip swipe-delete crash; inspect retained actuals; show newer approved catalogue rates | `fix/ios-trip-swipe-and-actual-handoff-inspection-20261102` | `db8f0d3dc9e1997089bd29cab6d95fc3a4d9c8a3` |
| [#34](https://github.com/stockmansridge/rork-vinetrack-june26/pull/34) | Restore Android spray-review parity and catalogue/pass label readability | `fix/mobile-spray-review-parity-trip-controls-20261101` | `7ff419e392ebae3dba2294dcbee876f08398de21` |
| [#33](https://github.com/stockmansridge/rork-vinetrack-june26/pull/33) | Fix recovery writer compatibility, clarify spray review and retain actual-use sync evidence | `fix/spray-review-recovery-contracts-20261101` | `33fc6a20427f14250ced5ec1c4162e3dcac56cdc` |
| [#32](https://github.com/stockmansridge/rork-vinetrack-june26/pull/32) | Fix older saved-chemical recovery and report all local store blockers | `fix/android-chemical-recovery-preflight-20261101` | `dd021b953c284b61f5d334051a5fa18254048c71` |
| [#31](https://github.com/stockmansridge/rork-vinetrack-june26/pull/31) | Repair spray-start identity checks and expose held Trip sync stages; recovery remains gated | `fix/spray-start-yield-recovery-20261101` | `7c344904de0c8b6c636b17935a5c77c04e84497a` |
| [#30](https://github.com/stockmansridge/rork-vinetrack-june26/pull/30) | Correct Android domain-cache recovery policy and expose precise failure rules | `fix/android-domain-cache-recovery-20261101` | `b43fcdd17e9ba439edd8aa9947d58be1e2975bde` |
| [#29](https://github.com/stockmansridge/rork-vinetrack-june26/pull/29) | Restore explicit spray actuals and reopen in-progress trips | `fix/spray-review-actuals-resume-20261101` | `dc603d8c4ad445da502ce9610f19dd30ecfbb681` |
| [#28](https://github.com/stockmansridge/rork-vinetrack-june26/pull/28) | Fix 3.1.9 Spray Calculator selection, canopy confirmation and Full Tank visibility | `fix/spray-flow-release-blockers-20261030` | `ec839e830879a9461811f413c5ec289cc609d82a` |
| [#27](https://github.com/stockmansridge/rork-vinetrack-june26/pull/27) | fix(Android): recognise rejected sessions and report missing block downloads honestly | `fix/android-block-download-status-20261030` | `aef91ca05ededd6fe3690ef5e5ccc79d2dc8af69` |
| [#26](https://github.com/stockmansridge/rork-vinetrack-june26/pull/26) | Add System Admin-only Quadrant Count for iOS and Android | `feature/quadrant-count-admin` | `e681f2796b22bd9d94bdd936a8fd9ea388584191` |
| [#24](https://github.com/stockmansridge/rork-vinetrack-june26/pull/24) | fix(iOS): stop build 189 calculator recursion when a chemical is selected | `fix/ios-189-chemical-flow-recursion` | `9f9f5ada0c7620c9ed4b85292e753190ca583e3c` |
| [#23](https://github.com/stockmansridge/rork-vinetrack-june26/pull/23) | Repair shared bunch-weight full sync and finish reconciled Trip recovery | `fix/trip-recovery-yield-parity-20261030` | `eea8b318d2275da4b32389fba63ba955d317ec76` |
| [#22](https://github.com/stockmansridge/rork-vinetrack-june26/pull/22) | Draft: single 3.1.8/3.1.9 sync and Spray Start operational repair bundle | `fix/sync-compatibility-318-319-20261030` | `d4c991d64e2c444805c039ca7392fce22228958a` |
| [#21](https://github.com/stockmansridge/rork-vinetrack-june26/pull/21) | fix(iOS): stabilize Spray Calculator chemical selection and preserve rate identity | `fix/ios-spray-chemical-selection-20261030` | `422274410ab90e38728259ee2c7603f3b227ffa8` |
| [#20](https://github.com/stockmansridge/rork-vinetrack-june26/pull/20) | fix(iOS): restore v186 Trip decoding and reconcile existing Growth Stage mirrors | `fix/ios-trip-legacy-utc-growth-mirror-20261030` | `8a81ade2396daca314bcf24ad962ad60c9523e33` |
| [#19](https://github.com/stockmansridge/rork-vinetrack-june26/pull/19) | fix(iOS): reconcile 23505 Growth Stage pin duplicates without losing queued edits | `hotfix/ios-growth-pin-conflict-20261029` | `2cf9544780578da7ac64394d8ff44cd495393046` |
| [#18](https://github.com/stockmansridge/rork-vinetrack-june26/pull/18) | DRAFT iOS hotfix: recover original orphaned spray tanks and preserve trip links | `hotfix/ios-verified-orphan-spray-recovery-20261029` | `d6dc03b4082f4cd55453ec862702801323bb8e35` |
| [#17](https://github.com/stockmansridge/rork-vinetrack-june26/pull/17) | fix(iOS): refresh current RevenueCat entitlement before initial paywall decision | `fix/ios-paywall-verify-before-routing-20261029` | `c794e4c2ab43d8dee9b1f65a1f02ca38e16b5810` |
| [#16](https://github.com/stockmansridge/rork-vinetrack-june26/pull/16) | hotfix(iOS): recover queued original occurrence Spray Trip from Trip Details | `hotfix/ios-queued-spray-recovery-20261029` | `4cfda28e908c4a87ccf96ef5f22c2657a02b51ee` |
| [#15](https://github.com/stockmansridge/rork-vinetrack-june26/pull/15) | hotfix: recover queued iOS spray after occurrence backend deployment and recheck paywall | `hotfix/ios-occurrence-retry-and-access-20261029` | `94db356c9379a26264b0239bf7c90544f90064d9` |
| [#14](https://github.com/stockmansridge/rork-vinetrack-june26/pull/14) | iOS spray UX: concise rate details, named links, inherited banded area | `fix/ios-spray-rate-cards-area-20261029` | `457ea42f679e827fb3947ebf68865dab38b3caee` |
| [#13](https://github.com/stockmansridge/rork-vinetrack-june26/pull/13) | HOTFIX iOS: recover queued spray from Trip Details without duplicate start | `hotfix/ios-original-spray-trip-recovery-20261029` | `8ecd541496e248b7cb5f5e184931c46a7fb3db7c` |
| [#12](https://github.com/stockmansridge/rork-vinetrack-june26/pull/12) | hotfix(iOS 3.1.8): unblock original saved occurrence spray recovery | `hotfix/ios-saved-occurrence-spray-recovery-v318` | `7060f992a90e1225eaa2eb42700ad626923f3fe7` |
| [#11](https://github.com/stockmansridge/rork-vinetrack-june26/pull/11) | DRAFT: v3.1.9 customer-focused Spray Calculator and chemical entry | `fix/spray-calculator-customer-ux-v319` | `017ae7b23eb7fe82bb76a69765214f37deb38167` |
| [#10](https://github.com/stockmansridge/rork-vinetrack-june26/pull/10) | Reduce repeated iOS display work in Task Log, Growth and Pruning | `perf/ios-presentation-20261021` | `84b9e5f5566d86a3d57bf6af7a744a7157e2f7bc` |
| [#6](https://github.com/stockmansridge/rork-vinetrack-june26/pull/6) | Fix iOS/Android automatic pin direction evidence without altering manual placement | `fix/pin-capture-travel-direction-ios-android` | `3f8bcdc45fcc14ff2bba66424b5494f0ff051a94` |
| [#3](https://github.com/stockmansridge/rork-vinetrack-june26/pull/3) | Show Portal guidance for contour rows in mobile block setup | `chore/contour-portal-only-mobile-notices-20261018` | `1a7a7ba6638c2426762246b352a231d7be4dba07` |
| [#2](https://github.com/stockmansridge/rork-vinetrack-june26/pull/2) | Mobile: exclude archived chemicals from inventory and show upcoming work tasks | `fix/inventory-active-and-upcoming-work-20261014` | `0889a6614bc77fa9ece468d5020f83fc288884ff` |

## Original branch ref snapshots

| Branch | Original SHA |
|---|---|
| `chemical-v3-prototype` | `5f6301f71b79681de50d20e66bcb3e1c96d32794` |
| `chore/contour-portal-only-mobile-notices-20261018` | `1a7a7ba6638c2426762246b352a231d7be4dba07` |
| `docs/legacy-spray-receipt-handoff-20261015` | `67b6abf620a4f0bd12e8d0e52d017dd0afd520cb` |
| `feature/fertigation-system-admin` | `06fa4b9ca93058ea359cbab9e726de7e897c9b71` |
| `feature/quadrant-count-admin` | `e681f2796b22bd9d94bdd936a8fd9ea388584191` |
| `feature/system-admin-full-sync-diagnostics-20261102` | `c1694747fb58aba031c17275c9c88a80ae18aac1` |
| `fix/android-block-download-status-20261030` | `aef91ca05ededd6fe3690ef5e5ccc79d2dc8af69` |
| `fix/android-chemical-recovery-preflight-20261101` | `dd021b953c284b61f5d334051a5fa18254048c71` |
| `fix/android-domain-cache-recovery-20261101` | `b43fcdd17e9ba439edd8aa9947d58be1e2975bde` |
| `fix/android-qualified-spray-start-legacy-journal-isolation-20261102` | `7b52089b946bc5af22cc6afb6a3cb37d83db308e` |
| `fix/android-recovery-maps-and-pruning-audit-20261101` | `d3b7f7ace498de5d4b24b83891815833765024e0` |
| `fix/android-stale-catalogue-rate-visibility-20261102` | `a2663ce3ddc966c0cad0e229772f6fe07d2686e1` |
| `fix/catalogue-effective-mobile-read-parity-20261102` | `8d36a996f8d39ad3d8c27422bd63ae8aec65f779` |
| `fix/inventory-active-and-upcoming-work-20261014` | `0889a6614bc77fa9ece468d5020f83fc288884ff` |
| `fix/ios-189-chemical-flow-recursion` | `9f9f5ada0c7620c9ed4b85292e753190ca583e3c` |
| `fix/ios-chemical-sync-batching-20261021` | `bbd2b791bb9d4b8c9c036e56fe66839035eb029e` |
| `fix/ios-p0-build209-complete-sync-chain` | `1747fbf1f47839c8731c405b897fd24c62682adb` |
| `fix/ios-p0-trip-sync-build208-reconciliation` | `39bdc353fe7f7079e9b2df9a43c321d21b00430d` |
| `fix/ios-paywall-verify-before-routing-20261029` | `c794e4c2ab43d8dee9b1f65a1f02ca38e16b5810` |
| `fix/ios-spray-chemical-selection-20261030` | `422274410ab90e38728259ee2c7603f3b227ffa8` |
| `fix/ios-spray-rate-cards-area-20261029` | `457ea42f679e827fb3947ebf68865dab38b3caee` |
| `fix/ios-spray-rate-compact-area-20261029` | `72ed894bb8d72d14da2716d943995d963446d267` |
| `fix/ios-sync-scroll-followup-20261021` | `3bb6b1fb4f3c68cb4f1239ad31aad6ad666446f6` |
| `fix/ios-trip-legacy-utc-growth-mirror-20261030` | `8a81ade2396daca314bcf24ad962ad60c9523e33` |
| `fix/ios-trip-swipe-and-actual-handoff-inspection-20261102` | `db8f0d3dc9e1997089bd29cab6d95fc3a4d9c8a3` |
| `fix/issue46-mtbera-scout-pilot-20261102` | `fffdd8f8f8a724ab00a07a76d682eb4c4c1df64a` |
| `fix/issue47-customer-spray-workflow-20261102` | `a031f5c831affe3699800fa8aa81f3a1138eb543` |
| `fix/mobile-spray-review-parity-trip-controls-20261101` | `7ff419e392ebae3dba2294dcbee876f08398de21` |
| `fix/occurrence-uuid-deployment-preflight-20261102` | `cc0808e8e053ca31b18d142e2c3ee4e4c92ab579` |
| `fix/pin-capture-travel-direction-ios-android` | `3f8bcdc45fcc14ff2bba66424b5494f0ff051a94` |
| `fix/shared-access-recovery-20261021` | `81ffb4a17287de059b882b37338fa651b4bf0e7d` |
| `fix/spray-calculator-customer-ux-v319` | `017ae7b23eb7fe82bb76a69765214f37deb38167` |
| `fix/spray-flow-human-testing-20261030` | `2764402a101e6a9bfb0c42285a82576a8ad01335` |
| `fix/spray-flow-release-blockers-20261030` | `ec839e830879a9461811f413c5ec289cc609d82a` |
| `fix/spray-review-actuals-resume-20261101` | `dc603d8c4ad445da502ce9610f19dd30ecfbb681` |
| `fix/spray-review-recovery-contracts-20261101` | `33fc6a20427f14250ced5ec1c4162e3dcac56cdc` |
| `fix/spray-start-yield-recovery-20261101` | `7c344904de0c8b6c636b17935a5c77c04e84497a` |
| `fix/sync-compatibility-318-319-20261030` | `d4c991d64e2c444805c039ca7392fce22228958a` |
| `fix/trip-recovery-yield-parity-20261030` | `eea8b318d2275da4b32389fba63ba955d317ec76` |
| `governance/canonical-sync-contract-v1-20261102` | `637d646181a4b7cab1ab0ed8da3db1e84c7a327e` |
| `hotfix/ios-growth-pin-conflict-20261029` | `2cf9544780578da7ac64394d8ff44cd495393046` |
| `hotfix/ios-occurrence-retry-and-access-20261029` | `94db356c9379a26264b0239bf7c90544f90064d9` |
| `hotfix/ios-original-spray-trip-recovery-20261029` | `8ecd541496e248b7cb5f5e184931c46a7fb3db7c` |
| `hotfix/ios-queued-spray-recovery-20261029` | `4cfda28e908c4a87ccf96ef5f22c2657a02b51ee` |
| `hotfix/ios-saved-occurrence-spray-recovery-v318` | `7060f992a90e1225eaa2eb42700ad626923f3fe7` |
| `hotfix/ios-verified-orphan-spray-recovery-20261029` | `d6dc03b4082f4cd55453ec862702801323bb8e35` |
| `issue43-tank-actual-p0` | `4ccb71560d8828763a9815c4acf7aff89e0806b8` |
| `main` | `eb6878f29dd312f5f202706a935fa85ad0a555f7` |
| `perf/ios-presentation-20261021` | `84b9e5f5566d86a3d57bf6af7a744a7157e2f7bc` |
| `review/spray-backend-admission-20261013` | `6c1ec19bc20825d67dde438e5bbf6c4fe79d2996` |

## Cleanup policy

1. `main` is the only active development/integration branch for future user-approved changes. Do not activate another legacy branch or build from it.
2. Archive old PR conversations as superseded/inactive **without merging**; their source remains on the original branch refs until source parity or explicit retirement is verified.
3. Do not delete or force-update a branch carrying unique changes. Removing its ref before a durable replacement exists can lose the only retrievable code.
4. If an archived change is still required, compare the original SHA above against latest `main`, implement only the missing behavior *directly on main*, test and release with exact commit receipt.
5. Close issues only when their requirements are independently accepted; a closed PR/archived branch does not mean customer functionality is complete.
6. The GitHub connector in this chat does not expose branch-ref deletion. Deleting branch refs needs a separate repository action after parity checks. Until then the branches remain as read-only recovery references.

**Not a release:** no signed TestFlight/Google Play build is produced by this ledger.