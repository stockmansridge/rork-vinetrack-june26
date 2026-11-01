# VineTrack iOS delete crash and pending actual-use triage — 2026-11-02

Status: source correction committed on incident branch, NOT merged or released. Original-device confirmation remains open.

## iOS crash evidence

Uploaded TestFlight .ips: VineTrack 3.1.9 build 197, iOS 27.2, 2026-11-02 00:19:38 +1100. Exception SIGABRT during UICollectionView swipe item batch update: `_Bug_Detected_In_Client_Of_UICollectionView_Invalid_Number_Of_Items_In_Section`, with `UIContextualAction executeHandlerWithView` in the same exception stack. Not symbolicated to a specific VineTrack function; the crash occurs during a UIKit swipe action and the report does not certify server deletion or data damage.

The history List used SwiftUI `.onDelete` to present an asynchronous confirmation alert without deleting its item. UIKit can expect the item-count mutation while performing the swipe action, triggering the reported invalid item count. The repair replaces `.onDelete` with a non-full-swipe explicit `.swipeActions` button; the row is removed only after explicit confirmation and the existing store delete path. Active Trips remain ineligible, and the active-state/write-access check is repeated immediately before deletion. TripDetail's Delete alert similarly rechecks current state and retained occurrence-plan recovery protection.

Original Trip deletion backend, journal, account and vineyard protections are unchanged.

## iOS sync evidence

Supplied diagnostics: 2 queued Trips, one `TRIP_SNAPSHOT_NOT_IN_SELECTED_SLICE`, one `TRIP_WAITING_FOR_ACTUAL_USE`; 0 pending actual rows and 2 retained initial-mix handoffs. 0 network failures in the sync registry is not acknowledgement. The source correction here expands read-only local handoff classification (account verification, selected-slice Trip/Spray presence, recipe identity, real tank session and recorded actuals) without creating or clearing any actual, handoff, Trip or upload row.

A retained handoff MUST NOT be consumed without an exact existing operator-entered actual for the original real tank session. Distinguish proof of a completed handoff needing durable local acknowledgement from genuinely absent actual-use records. A queued Trip snapshot outside the selected vineyard must not be auto-adopted or deleted; diagnose against its original authenticated scope.

This diagnostic improvement does NOT claim the two existing pending Trip operations are resolved. Rork must capture the newly classified reasons and address the precise phase, with an on-device retained-data acceptance test.

## Catalogue evidence

The JH Testing saved THIOVIT Jet record links to chemical_v3_revision_id e310e341-7fc5-4f59-a2da-30efdd0f330e (revision 1, superseded, 0 vineyard uses/rates). The same catalogue product_id d0c15ce7-aead-4ccb-870f-2fa3def36b43 has current AND approved revision 3588437b-1a4a-4c8a-8038-deba45b5f731 (revision 2, found grapevine rates). Its two options are a 200–600 g/100 L powdery mildew RANGE, and 600 g/100 L bud mite EXACT option. The older JH Testing vineyard copy contains an empty per-100L rate list; other vineyards linked to revision 2 contain two options. Android resolves its saved chemical's *exact* revision and correctly sees no rates for revision 1. Portal displays latest approved revision rates.

No customer chemical was silently modified. The missing backend contract is an authenticated owner/manager action to explicitly refresh an existing saved chemical from a newer APPROVED revision with optimistic concurrency, unchanged saved chemical ID, preserved notes/preferred vineyard rate/inventory, unchanged historical spray snapshots and proper audit. No range dose auto-selected; display source and review conditions. The Portal implementation was requested in Lovable, gated and unpublished.

## Targeted Rork verification

1. Native iOS build and one UI test on simulator for filtered Trip list: swipe a completed Trip -> confirmation -> cancel, then swipe -> delete -> list count changes once; no UIKit exception. Tap historical *active* Trip: cannot swipe-delete. Change trip active state between presenting alert and confirmation: deletion refused. Close/reopen, no stale duplicate.
2. Copy diagnostics again after installed update and obtain the added HANDOFF_* counts. Verify exact recorded amounts/session before any handoff acknowledgement; preserve original two drafts and pending trips until evidence confirmed.
3. For catalogue, test old saved revision -> newer approved revision with two rates; preserve old snapshots and manually entered preferred rate, refuse unapproved/pending revision or mismatched product/vineyard. Do not implement via raw permissive update.
4. Android Chemical Store list summaries and long `Used for`/attention text are now capped at two lines. Mobile detail view fetches the latest APPROVED revision by the same product ID for read-only reference if its vineyard copy is pinned to an older revision. This DOES NOT change or approve the saved vineyard chemical, automatically select a label rate, update a preferred rate, or resolve the missing catalogue-link refresh contract. Rork must ensure the revision reference is visibly labelled and fails safely offline.
5. Do not release publicly until iOS deletion crash and actual-use sync acceptance are demonstrated. Exact source/build linkage and signed TestFlight receipt required.

## Source validation and remaining gates

At commit 25fb417d20aad3e47230d8c1b28ee9373b065f57 the focused Swift parser and source guard completed successfully in GitHub Actions run 41312569073. Android compile was still in progress at the last inspected status; do not claim a pass until its final job result is read. A subsequent narrow Android change ensures that an optional current-revision query failure cannot hide the original pinned revision/label. The final build must use this branch's current HEAD, not the earlier tested one. No iOS simulator deletion test, actual-use reconciliation, signed mobile build, Portal catalogue-link RPC, or in-place device acceptance has been established by this document.