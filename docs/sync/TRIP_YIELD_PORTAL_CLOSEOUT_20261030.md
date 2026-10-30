# Trip recovery, shared bunch weights and Portal access - 30 October 2026

## Source and release status

This follow-up is based on Rork main commit
`58dc23dffc7340a56ebebc36868a6eeda40c4081`. It preserves Rork's active
journal-based Trip absence verification, verification-only recovery of the
original held intent, distinct retained-spray/deletion projection, interrupted
sweep cleanup and separate Android Work Task repairs. Do not replace this
source with the older PR #22 snapshot.

The initial parallel Trip implementation was superseded by the concurrent Rork
commit, rather than overwriting Rork's integration. Only the additional defects
below remain in this follow-up. No native release/build counters, signed
candidate, store publication, customer Trip, historical yield or queue reset
was performed by this follow-up.

## Trip correction retained and extended

The shipping resolver now calls the already-deployed
`confirm_trip_absence_v1(p_trip_id uuid)` for an empty exact-ID read. Rork's code
validates schema, exact Trip/actor, absence and account incarnation and retains
the actual receipt. Historical ambiguous holds use a read-only verification
route; an existing live Trip is not deleted by that route. Cancellation
records and original evidence remain durable after acknowledgement. The
existing per-account/vineyard retained-state projection distinguishes a real
saved spray from a pending deletion.

Two failing-before tests reproduced an additional issue in Rork's new
full-intent equality check: ISO8601 disk storage drops fractions of a second,
so a fresh intent with a subsecond queue date did not match its just-saved copy.
Matching now uses the exact durable revision UUID plus Trip, account/vineyard
scope, original evidence, creation outcome, review reason and acknowledgement.
Only the lossy date comparison is excluded. Newer reasons and revisions remain
protected. Receipt/delete awaits also recheck cancellation and write authority
before reporting acknowledgement. Interrupted full sweeps cannot advance the
success timestamp for a changed account/vineyard.

## Shared bunch-weight discrepancy

A confirmed source defect on BOTH mobile platforms was that the ordinary
full-sync/load path did not refresh the current shared-weight cache. Opening a
Yield surface could refresh it independently, so tapping Sync was not a
reliable way to pick up Portal changes. Full sync now refreshes the complete
shared table and publishes updated cache state to Yield consumers. A failed
read retains last-confirmed values with an explicit stale warning; it does not
replace them with zero, an invented default or 'Not configured'.

Current effective weight is resolved by exact canonical `variety_key`
(lowercase + trim, not fuzzy variety names):

1. Active exact vineyard + block + variety override.
2. Active vineyard + variety master (`paddock_id IS NULL`).
3. Not configured, but only after a successful authoritative complete read.

Storage is grams; calculations explicitly convert grams to kilograms. Removing
an override falls back to the master. The historical weight captured on an
existing Trip remains historical evidence and is NOT rewritten by a changed
master, sync or this repair.

Reads are vineyard/account scoped and paginated with exact counts and stable
ordering; invalid, duplicate-ID, wrong-tenant and incomplete reads fail rather
than masquerading as a complete configuration. Visible-vineyard checks prevent
an inaccessible empty response from becoming 'Not configured'. Newer confirmed
management results must not be overwritten by an earlier iOS refresh response.
Android cache notifications update UI without starting another network loop.

The live database had ZERO duplicate active weight keys when inspected; unique
partial indexes already enforce master and override identity. Duplicates are
NOT established as the customer's cause. The customer's vineyard, block,
variety, two displayed values, screen and app build were not provided. Therefore
neither displayed number is individually certified here. Compare both with the
current shared block/master row and distinguish current estimate from captured
Trip history before answering which specific value is correct.

## Portal frontend and backend

Lovable project `9b5a08c7-4e98-403e-aabb-9adeb50cdc93` final saved frontend
commit: `4fbe72bc1c896754a9e860874ba5686b49c08b9d`.

Portal changes include customer read/add gates, complete guarded weight reads,
current/unavailable/stale distinctions, preserved historical Trip weight, and
withholding the Dashboard total after a failed weight refetch rather than
presenting an unverified total as current. The owner-without-membership case is
supported by the deployed `is_vineyard_member` function, verified directly.
No frontend publication or signed-in acceptance was performed in this session.

The LIVE Supabase migration is already applied:
`20261030101035_portal_scout_read_and_vintage_note_add_access`.
DO NOT apply it again or blindly execute earlier proposal SQL.

Three new STABLE SECURITY INVOKER helpers use an empty search path, revoke
PUBLIC/anon execution and grant authenticated execution:
`can_view_vineyard_insights`, `can_add_vintage_notes`,
`has_any_vineyard_membership`.

Eight additive policies allow vineyard members to read the four Scout tables,
Scout photos, Vintage Notes and permitted note types. Portal Scout Reports
remain read-only. Owners/managers/supervisors with writable vineyard access may
add notes. Insert checks require the actual observer, non-spoofed authorship
fields and an active global or same-vineyard note type. Operators may read;
expired-trial members may read but may not insert. Cross-vineyard reads and
anonymous access remain blocked. RLS remains enabled.

The original `can_use_vineyard_insights`, existing policies, mobile editing,
AI/Vintage Report gates and other preview features remain unchanged. This does
not broadly enable Insights or write access to Scout data.

Migration tests used synthetic users, profiles, vineyards, notes and photo
metadata inside a rolled-back subtransaction. Assertions covered owner without
membership, manager, supervisor, operator, expired trial, foreign vineyard,
malformed photo path, spoofed observer, foreign note type, nonmember and anon.
All passed; post-deployment verification found eight policies, all three
helpers with expected permissions, RLS on and ZERO remaining synthetic users.
No existing customer data was edited. Security advisors reported unrelated
pre-existing issues; this is not a certification of the whole database.

## Verification actually executed

- Trip persistence identity tests: before correction 2 passed / 2 failed;
  after correction 4 passed. Native test source uses the real PersistenceStore;
  Linux execution substitutes only its deterministic disk boundary.
- Shared-weight cache and current resolution tests: 12 passed across two
  suites. Production cache/resolver/estimate logic with SDK/input-model boundary
  stubs; the Linux-only runner removes the Observation macro/import because of
  an unavailable runtime symbol. No cache logic is rewritten by the runner.
- Source integration guards: 5 passed. These check production wiring and
  preservation, not runtime/native functionality.
- Modified Swift syntax parsing and `git diff --check`: passed.
- Portal final affected selection reported by Lovable: 45 passed across four
  files; preview build OK. Earlier role/navigation tests were reported passing.
  No signed-in browser/role acceptance was performed.
- Rork's retained report at the BASE commit records 184 selected iOS tests and
  a simulator build passing for its repair. Those results predate this delta
  and are not claimed as tests of the final combined source.

Android instrumentation tests were updated for the complete shared-table
transport, override removal, cached failure and later success. They were NOT
executed here. The new iOS production-repository write-authority regression also
requires native execution. Xcode/native simulator compilation and original
phone recovery remain required; host tests are not a substitute.

## Rork handoff / acceptance

Fetch this follow-up branch/PR and preserve all newer main work. No new backend
migration is required. Run only the affected native suites: Trip journal
absence integration/recovery/persistence identity, shared-weight repository and
cache/full-sync tests, and the two changed Android shared-weight instrumentation
classes. Perform the normal native builds once after integration; no unrelated
broad test/build churn. Preserve existing known baseline failures in reporting.

On the original iPhone, recover the original pending deletion IN PLACE through
its retained receipt, confirm counts and spinner settle, and ensure a genuine
saved spray remains independently held until its own proof. On each mobile
platform change a test-vineyard master/override in Portal, use normal Sync,
verify the current weight/source/tonnes update, then remove the override and
verify master fallback. Verify offline failure retains data with a warning,
reconnection clears it, and historical Trip snapshots are unchanged.

Before publishing Portal, verify signed-in operator, supervisor and expired
trial journeys, foreign-vineyard denial, Scout photo visibility and current/
stale bunch-weight displays. Preview code and live backend permissions are not
proof the public frontend has been published. Do not claim the original
customer mismatch or device recovery resolved until these observations exist.
