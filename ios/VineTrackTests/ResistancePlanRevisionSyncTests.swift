import Foundation
import Testing

@testable import VineTrack

/// Sync Integrity Stage 2: the mobile half of the sql/198 revision contract.
///
/// Every test here targets a failure that ACTUALLY HAPPENED under the old
/// `client_updated_at` contract, or a regression that would silently reintroduce it. The
/// fake server arbitrates purely on `server_revision` and never on a clock — so a test that
/// passes because the timestamps happened to line up cannot exist in this file.
///
/// Mirrors `ResistancePlanRevisionSyncTest.kt` on Android case for case.
@MainActor
struct ResistancePlanRevisionSyncTests {

    // MARK: - Fake server — revision-authoritative, clock-blind

    /// In-memory stand-in for `public.resistance_plans` under sql/198.
    ///
    /// Contract enforced:
    ///   - `base_revision` must equal the stored `server_revision`, else conflict;
    ///   - the server issues the next revision on every accepted write;
    ///   - `client_updated_at` is recorded but NEVER arbitrates;
    ///   - a client-supplied `server_revision` is ignored (unforgeable token).
    final class RevisionServer: ResistancePlanRemote, @unchecked Sendable {
        var rows: [String: ResistancePlan] = [:]
        var upsertCalls = 0
        var baseRevisionsSent: [Int64?] = []
        var serveStaleReadNext = false
        var failNextFetch = false
        private var lagSnapshot: [ResistancePlan] = []

        struct Offline: Error, LocalizedError {
            var errorDescription: String? { "offline" }
        }

        func fetchAll(vineyardId: String) async throws -> [ResistancePlan] {
            if failNextFetch { failNextFetch = false; throw Offline() }
            if serveStaleReadNext {
                serveStaleReadNext = false
                return lagSnapshot.filter { $0.vineyardId == vineyardId }
            }
            return rows.values.filter { $0.vineyardId == vineyardId }
        }

        func upsert(_ plans: [ResistancePlan]) async throws -> [VersionedWriteOutcome<ResistancePlan>] {
            lagSnapshot = Array(rows.values)
            upsertCalls += 1
            var outcomes: [VersionedWriteOutcome<ResistancePlan>] = []
            for plan in plans {
                baseRevisionsSent.append(plan.serverRevision)
                let existing = rows[plan.id]
                if let existing, plan.serverRevision != existing.serverRevision {
                    outcomes.append(
                        .conflict(
                            rowId: plan.id,
                            baseRevision: plan.serverRevision,
                            serverRevision: existing.serverRevision
                        )
                    )
                    continue
                }
                var stored = plan
                stored.createdBy = existing?.createdBy ?? plan.createdBy
                stored.deletedAtEpochMs = existing?.deletedAtEpochMs
                stored.serverRevision = (existing?.serverRevision ?? 0) + 1
                rows[plan.id] = stored
                outcomes.append(.applied(stored))
            }
            return outcomes
        }

        func softDelete(planId: String) async throws {
            guard let existing = rows[planId] else { return }
            var tombstoned = existing
            tombstoned.deletedAtEpochMs = existing.updatedAtEpochMs + 1
            tombstoned.serverRevision = (existing.serverRevision ?? 0) + 1
            rows[planId] = tombstoned
        }

        /// Another device or the portal saves over the row, advancing the revision.
        func writeAsOtherDevice(planId: String, notes: String, atEpochMs: Int64) {
            guard let existing = rows[planId] else { return }
            var updated = existing
            updated.notes = notes
            updated.updatedAtEpochMs = atEpochMs
            updated.serverRevision = (existing.serverRevision ?? 0) + 1
            rows[planId] = updated
        }

        /// Seeds a row exactly as a pre-sql/198 client left it: no revision at all.
        func seedLegacyRow(_ plan: ResistancePlan) {
            var legacy = plan
            legacy.serverRevision = nil
            rows[plan.id] = legacy
        }
    }

    // MARK: - Fixtures

    let vineyard = "vy-1"

    final class Clock: @unchecked Sendable {
        var now: Int64 = 10_000
    }

    func position(_ id: String, _ code: String) -> ResistancePlannedPosition {
        ResistancePlannedPosition(
            id: id,
            products: [
                ResistancePlannedProduct(
                    id: "prod-\(id)",
                    groups: ResistanceGroupSignature.of([code]),
                    source: .group
                )
            ]
        )
    }

    func makePlan(
        id: String = "plan-1",
        notes: String? = nil,
        updatedAt: Int64 = 1_000,
        positions: [ResistancePlannedPosition]? = nil
    ) -> ResistancePlan {
        ResistancePlan(
            id: id,
            vineyardId: vineyard,
            seasonId: "2026/27",
            seasonStartYear: 2026,
            disease: .powderyMildew,
            jurisdiction: .australia,
            crop: .grape,
            blockIds: ["block-a"],
            positions: positions ?? [position("pos-1", "3")],
            notes: notes,
            rulesetId: "AU_GRAPE_POWDERY_2026_07_22",
            rulesetVersion: "2026.07.22",
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: updatedAt
        )
    }

    func makeRepo(
        server: (any ResistancePlanRemote)?,
        store: InMemoryResistancePlanLocalStore = InMemoryResistancePlanLocalStore(),
        clock: Clock
    ) -> ResistancePlanRepository {
        ResistancePlanRepository(
            local: store,
            remote: server,
            clock: { clock.now },
            currentUserId: { "user-1" }
        )
    }

    // MARK: - 1. Successful create

    @Test func aBrandNewPlanIsCreatedWithNoBaseRevisionAndAdoptsTheServerRevision() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())

        // Before the push this device has never been given a revision. It must send NOTHING
        // rather than invent one: a fabricated base_revision would either be refused forever
        // or match by luck and overwrite an unseen edit.
        #expect(repository.plans[0].serverRevision == nil)
        #expect(repository.plans[0].isUnsynced)

        let result = await repository.sync(vineyardId: vineyard)

        #expect(result.isSuccess)
        #expect(result.pushed == 1)
        #expect(result.conflicted == 0)
        #expect(server.baseRevisionsSent == [nil], "create must not assert a base revision")
        #expect(repository.plans[0].serverRevision == 1)
        #expect(repository.pendingCount() == 0)
        #expect(repository.syncState == .synced)
    }

    // MARK: - 2. Successful edit advances the revision

    @Test func anEditSendsTheObservedRevisionAndAdoptsTheAdvancedOne() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())
        await repository.sync(vineyardId: vineyard)
        #expect(repository.plans[0].serverRevision == 1)

        clock.now = 20_000
        repository.save(repository.plans[0].settingNotes("edited", atEpochMs: clock.now))
        let result = await repository.sync(vineyardId: vineyard)

        #expect(result.isSuccess)
        #expect(server.baseRevisionsSent.last == 1, "must send the revision it READ")
        // The server's value, not local+1 arithmetic.
        #expect(repository.plans[0].serverRevision == 2)
        #expect(server.rows["plan-1"]?.serverRevision == 2)
        #expect(repository.plans[0].notes == "edited")
        #expect(repository.pendingCount() == 0)
    }

    @Test func theRevisionComesFromTheServerAndIsNeverComputedLocally() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())
        await repository.sync(vineyardId: vineyard)

        // A server that jumps revisions (legal — any write by any actor advances it) must be
        // believed. If the client assumed base+1 it would now be wrong by 8.
        server.rows["plan-1"]?.serverRevision = 9
        clock.now = 30_000
        repository.save(repository.plans[0].settingNotes("second", atEpochMs: clock.now))
        let conflictPass = await repository.sync(vineyardId: vineyard)
        #expect(conflictPass.conflicted == 1, "the jump must be seen, not guessed around")

        repository.resolveKeepingLocal(id: "plan-1")
        #expect(repository.plans[0].serverRevision == 9)
        let result = await repository.sync(vineyardId: vineyard)

        #expect(result.isSuccess)
        #expect(result.conflicted == 0)
        #expect(repository.plans[0].serverRevision == 10)
    }

    // MARK: - 3 & 4. Clock skew

    @Test func anEditFromADeviceHoursBehindTheServerStillSucceeds() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        clock.now = 10_000_000
        repository.save(makePlan(updatedAt: clock.now))
        await repository.sync(vineyardId: vineyard)
        #expect(repository.plans[0].serverRevision == 1)

        // The device clock jumps BACKWARDS six hours — the exact case that silently lost a
        // grower's edit under sql/185 while the app reported success.
        clock.now = 10_000_000 - 6 * 60 * 60 * 1_000
        repository.save(repository.plans[0].settingNotes("slow clock edit", atEpochMs: clock.now))
        let result = await repository.sync(vineyardId: vineyard)

        #expect(result.isSuccess)
        #expect(result.conflicted == 0, "a slow clock must not manufacture a conflict")
        #expect(result.pushed == 1)
        #expect(server.rows["plan-1"]?.notes == "slow clock edit")
        #expect(repository.plans[0].serverRevision == 2)
        #expect(repository.pendingCount() == 0)
        #expect(repository.syncState == .synced)
    }

    @Test func aDeviceHoursAheadDoesNotLockLaterWritersOut() async {
        let server = RevisionServer()
        let fastClock = Clock()
        let fastDevice = makeRepo(server: server, clock: fastClock)
        fastDevice.load(vineyardId: vineyard)

        // Fast device parks a far-future client_updated_at on the row. Under sql/185 this
        // poisoned the row for everyone until the server clock caught up.
        fastClock.now = 10_000_000 + 8 * 60 * 60 * 1_000
        fastDevice.save(makePlan(updatedAt: fastClock.now))
        await fastDevice.sync(vineyardId: vineyard)
        #expect(server.rows["plan-1"]?.serverRevision == 1)

        let normalClock = Clock()
        normalClock.now = 10_000_000
        let normalDevice = makeRepo(
            server: server,
            store: InMemoryResistancePlanLocalStore(),
            clock: normalClock
        )
        normalDevice.load(vineyardId: vineyard)
        await normalDevice.sync(vineyardId: vineyard)
        #expect(normalDevice.plans[0].serverRevision == 1)

        normalDevice.save(
            normalDevice.plans[0].settingNotes("honest later edit", atEpochMs: normalClock.now)
        )
        let result = await normalDevice.sync(vineyardId: vineyard)

        #expect(result.isSuccess)
        #expect(result.conflicted == 0, "the fast clock must not block this write")
        #expect(server.rows["plan-1"]?.notes == "honest later edit")
        #expect(server.rows["plan-1"]?.serverRevision == 2)
    }

    // MARK: - 5, 6, 7. Genuine conflict and what survives it

    @Test func aGenuineStaleEditIsReportedAsAConflictAndNeverAsSuccess() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(notes: "original"))
        await repository.sync(vineyardId: vineyard)

        server.writeAsOtherDevice(planId: "plan-1", notes: "other device wins", atEpochMs: 50_000)
        clock.now = 60_000
        repository.save(repository.plans[0].settingNotes("my offline edit", atEpochMs: clock.now))
        let result = await repository.sync(vineyardId: vineyard)

        // The pass itself completed — this is NOT a failure.
        #expect(result.isSuccess)
        #expect(result.failure == nil)
        #expect(result.conflicted == 1)
        #expect(result.hasConflicts)
        #expect(result.pushed == 0)
        // ...and it is NOT reported as a successful sync.
        #expect(repository.syncState == .conflict)
    }

    @Test func aConflictIsClassifiedSeparatelyFromANetworkFailure() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())
        await repository.sync(vineyardId: vineyard)

        // Network failure: failed, no conflict, retryable.
        server.failNextFetch = true
        clock.now = 20_000
        repository.save(repository.plans[0].settingNotes("edit", atEpochMs: clock.now))
        let failure = await repository.sync(vineyardId: vineyard)
        #expect(!failure.isSuccess)
        #expect(failure.failure != nil)
        #expect(failure.conflicted == 0)
        #expect(repository.syncState == .failed)
        #expect(repository.conflictCount() == 0)

        // Revision conflict: success with a conflict, NOT retryable.
        server.writeAsOtherDevice(planId: "plan-1", notes: "other", atEpochMs: 30_000)
        clock.now = 40_000
        repository.save(repository.plans[0].settingNotes("mine", atEpochMs: clock.now))
        let conflict = await repository.sync(vineyardId: vineyard)
        #expect(conflict.isSuccess)
        #expect(conflict.failure == nil)
        #expect(conflict.conflicted == 1)
        #expect(repository.syncState == .conflict)
        #expect(repository.conflictCount() == 1)
    }

    @Test func aConflictLeavesTheLocalMutationQueuedAndBothDocumentsIntact() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(
            makePlan(positions: [position("p1", "3"), position("p2", "7"), position("p3", "11")])
        )
        await repository.sync(vineyardId: vineyard)

        server.writeAsOtherDevice(planId: "plan-1", notes: "server copy", atEpochMs: 50_000)
        clock.now = 60_000
        repository.save(repository.plans[0].settingNotes("my authored plan", atEpochMs: clock.now))
        await repository.sync(vineyardId: vineyard)

        // OUTBOX RETAINED — the edit exists on this device and nowhere else.
        #expect(repository.pendingCount() == 1)
        // LOCAL PENDING COPY PRESERVED.
        #expect(repository.plans[0].notes == "my authored plan")
        let conflict = repository.conflict(id: "plan-1")
        #expect(conflict != nil)
        #expect(conflict?.entity == resistancePlansEntity)
        #expect(conflict?.localPending.notes == "my authored plan")
        #expect(conflict?.localPending.positions.count == 3)
        // LATEST SERVER COPY PRESERVED.
        #expect(conflict?.serverCurrent?.notes == "server copy")
        #expect(conflict?.baseRevision == 1)
        #expect(conflict?.serverRevision == 2)
    }

    @Test func aConflictIsNotBlindlyRetried() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())
        await repository.sync(vineyardId: vineyard)
        server.writeAsOtherDevice(planId: "plan-1", notes: "server", atEpochMs: 50_000)
        clock.now = 60_000
        repository.save(repository.plans[0].settingNotes("mine", atEpochMs: clock.now))
        await repository.sync(vineyardId: vineyard)
        #expect(repository.syncState == .conflict)

        // A further pass must not re-offer the same stale base_revision: retrying it is
        // guaranteed to be refused, so a retry loop would never converge.
        let sentBefore = server.baseRevisionsSent.count
        let second = await repository.sync(vineyardId: vineyard)
        #expect(server.baseRevisionsSent.count == sentBefore)
        #expect(repository.syncState == .conflict)
        #expect(repository.pendingCount() == 1)
        #expect(repository.plans[0].notes == "mine")
        #expect(second.isSuccess)

        // The ONLY way out is an explicit resolution.
        repository.resolveKeepingLocal(id: "plan-1")
        #expect(repository.conflictCount() == 0)
        let resolved = await repository.sync(vineyardId: vineyard)
        #expect(resolved.isSuccess)
        #expect(resolved.conflicted == 0)
        #expect(server.rows["plan-1"]?.notes == "mine")
    }

    @Test func resolvingInFavourOfTheServerDiscardsTheLocalEditOnlyWhenAsked() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(notes: "original"))
        await repository.sync(vineyardId: vineyard)
        server.writeAsOtherDevice(planId: "plan-1", notes: "server version", atEpochMs: 50_000)
        clock.now = 60_000
        repository.save(repository.plans[0].settingNotes("mine", atEpochMs: clock.now))
        await repository.sync(vineyardId: vineyard)

        repository.resolveKeepingServer(id: "plan-1")

        #expect(repository.plans[0].notes == "server version")
        #expect(repository.pendingCount() == 0)
        #expect(repository.conflictCount() == 0)
        #expect(repository.syncState == .synced)
    }

    // MARK: - 8. Whole-document semantics

    @Test func conflictingPositionArraysAreNeverElementMerged() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(positions: [position("p1", "3")]))
        await repository.sync(vineyardId: vineyard)

        // Server: 3 -> 11. Local: 3 -> 7 -> 11. A row-wise merge could produce a spray
        // sequence NEITHER operator authored and present it as resistance-compliant.
        server.rows["plan-1"]?.positions = [position("p1", "3"), position("p9", "11")]
        server.rows["plan-1"]?.serverRevision = 2
        clock.now = 60_000
        var mine = repository.plans[0]
        mine.positions = [position("p1", "3"), position("p2", "7"), position("p3", "11")]
        mine.updatedAtEpochMs = clock.now
        repository.save(mine)
        await repository.sync(vineyardId: vineyard)

        let conflict = repository.conflict(id: "plan-1")
        #expect(conflict != nil)
        #expect(conflict?.localPending.positions.map(\.id) == ["p1", "p2", "p3"])
        #expect(conflict?.serverCurrent?.positions.map(\.id) == ["p1", "p9"])
        #expect(repository.plans[0].positions.count == 3, "nothing may invent a union")
    }

    // MARK: - 10. Restart durability

    @Test func anUnresolvedConflictAndBothDocumentsSurviveARepositoryReload() async {
        let server = RevisionServer()
        let store = InMemoryResistancePlanLocalStore()
        let clock = Clock()
        let first = makeRepo(server: server, store: store, clock: clock)
        first.load(vineyardId: vineyard)
        first.save(makePlan(notes: "original"))
        await first.sync(vineyardId: vineyard)
        server.writeAsOtherDevice(planId: "plan-1", notes: "server version", atEpochMs: 50_000)
        clock.now = 60_000
        first.save(first.plans[0].settingNotes("my authored version", atEpochMs: clock.now))
        await first.sync(vineyardId: vineyard)
        #expect(first.conflictCount() == 1)

        // App killed. A brand-new repository over the SAME store — the durability boundary.
        let reloaded = makeRepo(server: server, store: store, clock: clock)
        reloaded.load(vineyardId: vineyard)

        #expect(reloaded.conflictCount() == 1)
        #expect(reloaded.syncState == .conflict)
        let conflict = reloaded.conflict(id: "plan-1")
        // Not just a flag: the authored payload is what matters.
        #expect(conflict?.localPending.notes == "my authored version")
        #expect(conflict?.serverCurrent?.notes == "server version")
        #expect(conflict?.baseRevision == 1)
        #expect(conflict?.serverRevision == 2)
        #expect(reloaded.pendingCount() == 1)
        #expect(reloaded.plans[0].notes == "my authored version")
    }

    // MARK: - Legacy rows and old clients

    @Test func aRowLastWrittenByAnOldClientDecodesAndBecomesVersionedSafely() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        // A pre-sql/198 row: no revision. Legitimate migrated state, not corruption.
        server.seedLegacyRow(makePlan(notes: "written by an old client"))

        repository.load(vineyardId: vineyard)
        let pull = await repository.sync(vineyardId: vineyard)

        #expect(pull.isSuccess)
        #expect(repository.plans[0].notes == "written by an old client")
        #expect(repository.plans[0].serverRevision == nil, "a missing revision must decode")
        #expect(pull.conflicted == 0, "a legacy row is not a conflict")

        clock.now = 70_000
        repository.save(repository.plans[0].settingNotes("edited by a new client", atEpochMs: clock.now))
        let result = await repository.sync(vineyardId: vineyard)

        #expect(result.isSuccess)
        #expect(result.conflicted == 0)
        #expect(server.rows["plan-1"]?.notes == "edited by a new client")
        #expect(repository.plans[0].serverRevision == 1)
    }

    // MARK: - Revision is server state, not editable content

    @Test func aCallerCannotSmuggleAForgedRevisionInThroughSave() async {
        let server = RevisionServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())
        await repository.sync(vineyardId: vineyard)
        #expect(repository.plans[0].serverRevision == 1)

        // A stale view, a copied value or a hand-built plan tries to assert a revision. The
        // repository must re-stamp from its own cache: a save is content, and the revision is
        // server state no screen is allowed to author.
        clock.now = 20_000
        var forged = repository.plans[0]
        forged.serverRevision = 99
        forged.notes = "edit"
        repository.save(forged)
        #expect(repository.plans[0].serverRevision == 1, "the forged revision must be discarded")

        let result = await repository.sync(vineyardId: vineyard)
        #expect(result.isSuccess)
        #expect(server.baseRevisionsSent.last == 1)
        #expect(result.conflicted == 0)
        #expect(repository.plans[0].serverRevision == 2)
    }

    // MARK: - Conflict classification

    @Test func aPostgRESTRevisionConflictIsRecognisedAndMinedForRevisions() {
        struct PostgRESTError: Error, LocalizedError {
            let body: String
            var errorDescription: String? { body }
        }
        let error = PostgRESTError(
            body: #"{"code":"PT409","details":"{\"code\": \"REVISION_CONFLICT\", \"server_revision\": 12, \"base_revision\": 7}","message":"REVISION_CONFLICT"}"#
        )

        #expect(SyncRevisionContract.isRevisionConflict(error))
        #expect(SyncRevisionContract.serverRevision(from: error) == 12)
        #expect(SyncRevisionContract.baseRevision(from: error) == 7)

        // A typed conflict is always a conflict.
        let typed = SyncRevisionConflictError(
            rowId: "p", entity: resistancePlansEntity, baseRevision: 1, serverRevision: 2
        )
        #expect(SyncRevisionContract.isRevisionConflict(typed))

        // And an ordinary server error must NOT be mistaken for one.
        struct Plain: Error, LocalizedError {
            var errorDescription: String? { "internal error" }
        }
        #expect(!SyncRevisionContract.isRevisionConflict(Plain()))
    }
}
