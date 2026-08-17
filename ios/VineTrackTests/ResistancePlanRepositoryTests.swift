import Foundation
import Testing

@testable import VineTrack

/// Persistence, offline and multi-device tests for `ResistancePlanRepository`.
///
/// The fake server below is not a rubber stamp: it enforces the same rules sql/196 and
/// sql/198 enforce (vineyard isolation, whole-document upsert, tombstone-on-RPC, write-once
/// attribution and the REVISION guard). A fake that accepted everything would let a conflict
/// bug pass here and only surface as a lost season plan in a vineyard.
///
/// It arbitrates on `server_revision` and never on a device clock — see sql/198. A fake that
/// still compared timestamps would keep passing the clock-skew tests for the wrong reason.
///
/// Mirrors `ResistancePlanRepositoryTest.kt` on Android case for case.
@MainActor
struct ResistancePlanRepositoryTests {

    // MARK: - Fake server

    /// In-memory stand-in for `public.resistance_plans`.
    final class FakeServer: ResistancePlanRemote, @unchecked Sendable {
        var rows: [String: ResistancePlan] = [:]
        var upsertCalls = 0
        var softDeleteCalls = 0
        var failNextUpsert = false
        var failNextFetch = false
        /// Serve the NEXT read from the state captured before the last write.
        ///
        /// Models read-after-write replica lag: the push genuinely succeeded, but the
        /// follow-up read lands on a replica that has not caught up and returns the PREVIOUS
        /// row. That stale row must never overwrite the newer edit the grower is looking at.
        var serveStaleReadNext = false
        private var lagSnapshot: [ResistancePlan] = []
        var baseRevisionsSent: [Int64?] = []

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
            if failNextUpsert { failNextUpsert = false; throw Offline() }
            lagSnapshot = Array(rows.values)
            upsertCalls += 1
            var outcomes: [VersionedWriteOutcome<ResistancePlan>] = []
            for plan in plans {
                baseRevisionsSent.append(plan.serverRevision)
                let existing = rows[plan.id]
                if let existing, plan.serverRevision != existing.serverRevision {
                    // sql/198: base_revision does not match the row's current version.
                    // Returned as an OUTCOME, never thrown — a thrown conflict gets counted
                    // as a transport failure and blindly retried.
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
                // sql/196 attribution guard: created_by is write-once.
                stored.createdBy = existing?.createdBy ?? plan.createdBy
                // The server owns the tombstone; an upsert never sets it.
                stored.deletedAtEpochMs = existing?.deletedAtEpochMs
                // The server issues the next revision. Whatever the client sent is
                // irrelevant — that is what makes the token unforgeable.
                stored.serverRevision = (existing?.serverRevision ?? 0) + 1
                rows[plan.id] = stored
                outcomes.append(.applied(stored))
            }
            return outcomes
        }

        func softDelete(planId: String) async throws {
            softDeleteCalls += 1
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
    let otherVineyard = "vy-2"

    final class Clock: @unchecked Sendable {
        var now: Int64 = 10_000
    }

    func product(_ codes: [String], chemicalId: String? = nil) -> ResistancePlannedProduct {
        ResistancePlannedProduct(
            id: "prod-\(codes.joined(separator: "-"))-\(chemicalId ?? "g")",
            groups: ResistanceGroupSignature.of(codes),
            source: chemicalId == nil ? .group : .savedChemical,
            savedChemicalId: chemicalId,
            productName: chemicalId.map { "Product \($0)" }
        )
    }

    func position(_ id: String, _ codes: [String]) -> ResistancePlannedPosition {
        ResistancePlannedPosition(id: id, products: [product(codes)])
    }

    func makePlan(
        id: String = "plan-1",
        vineyardId: String? = nil,
        seasonId: String = "2026/27",
        disease: ResistanceDisease = .powderyMildew,
        positions: [ResistancePlannedPosition]? = nil,
        blockIds: [String] = ["block-a"],
        rulesetVersion: String? = "2026.07.22",
        updatedAt: Int64 = 1_000
    ) -> ResistancePlan {
        ResistancePlan(
            id: id,
            vineyardId: vineyardId ?? vineyard,
            seasonId: seasonId,
            seasonStartYear: 2026,
            disease: disease,
            jurisdiction: .australia,
            crop: .grape,
            blockIds: blockIds,
            positions: positions ?? [
                position("pos-1", ["3"]), position("pos-2", ["7"]), position("pos-3", ["11"]),
            ],
            rulesetId: "AU_GRAPE_POWDERY_2026_07_22",
            rulesetVersion: rulesetVersion,
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: updatedAt
        )
    }

    func makeRepo(
        server: (any ResistancePlanRemote)?,
        store: InMemoryResistancePlanLocalStore = InMemoryResistancePlanLocalStore(),
        clock: Clock = Clock(),
        userId: String? = "user-1"
    ) -> ResistancePlanRepository {
        ResistancePlanRepository(
            local: store,
            remote: server,
            clock: { clock.now },
            currentUserId: { userId }
        )
    }

    // MARK: - Create / save / reload

    @Test func savedPlanReloadsWithPositionsInOrder() {
        let store = InMemoryResistancePlanLocalStore()
        let repository = makeRepo(server: nil, store: store)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())

        let reloaded = makeRepo(server: nil, store: store)
        reloaded.load(vineyardId: vineyard)

        let loaded = try! #require(reloaded.plans.first)
        #expect(loaded.id == "plan-1")
        #expect(loaded.positions.map(\.id) == ["pos-1", "pos-2", "pos-3"])
        #expect(loaded.positions.map { $0.products[0].groupCodes[0] } == ["3", "7", "11"])
    }

    @Test func editSurvivesReload() {
        let store = InMemoryResistancePlanLocalStore()
        let repository = makeRepo(server: nil, store: store)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())
        repository.save(repository.plans[0].settingNotes("mildew pressure high", atEpochMs: 2_000))

        let reloaded = makeRepo(server: nil, store: store)
        reloaded.load(vineyardId: vineyard)
        #expect(reloaded.plans[0].notes == "mildew pressure high")
    }

    @Test func reorderPersistsAndPositionIdsAreUnchanged() {
        let store = InMemoryResistancePlanLocalStore()
        let repository = makeRepo(server: nil, store: store)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())
        repository.save(repository.plans[0].movingPositionUp(id: "pos-3", atEpochMs: 2_000))

        let reloaded = makeRepo(server: nil, store: store)
        reloaded.load(vineyardId: vineyard)
        let loaded = reloaded.plans[0]

        // Sequence changed...
        #expect(loaded.positions.map(\.id) == ["pos-1", "pos-3", "pos-2"])
        // ...identity did not. This is the seam a future actual-spray association hangs
        // off: if reordering minted new ids, every past association would silently break.
        #expect(Set(loaded.positions.map(\.id)) == ["pos-1", "pos-2", "pos-3"])
    }

    @Test func planIdIsStableAcrossEveryEdit() {
        let repository = makeRepo(server: nil)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())
        let original = repository.plans[0].id

        repository.save(repository.plans[0].settingNotes("a", atEpochMs: 2_000))
        repository.save(repository.plans[0].movingPositionDown(id: "pos-1", atEpochMs: 3_000))
        repository.save(repository.plans[0].settingBlockIds(["block-b"], atEpochMs: 4_000))

        #expect(repository.plans[0].id == original)
    }

    // MARK: - Multiple plans, isolation

    @Test func vineyardMayHoldTwoPlansForSameSeasonAndDisease() {
        // A grower legitimately keeps "conservative" and "aggressive" plans side by side.
        // Keying plans by season+disease+blocks would have silently overwritten one.
        let repository = makeRepo(server: nil)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "plan-a"))
        repository.save(makePlan(id: "plan-b"))

        let same = repository.plans(seasonId: "2026/27", disease: .powderyMildew)
        #expect(same.count == 2)
        #expect(Set(same.map(\.id)) == ["plan-a", "plan-b"])
    }

    @Test func differentVineyardsAreIsolatedInTheCache() {
        let store = InMemoryResistancePlanLocalStore()
        let repository = makeRepo(server: nil, store: store)

        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "plan-a", vineyardId: vineyard))

        repository.load(vineyardId: otherVineyard)
        repository.save(makePlan(id: "plan-b", vineyardId: otherVineyard))
        #expect(repository.plans.map(\.id) == ["plan-b"])

        repository.load(vineyardId: vineyard)
        #expect(repository.plans.map(\.id) == ["plan-a"])
    }

    @Test func serverSliceIsScopedToTheVineyard() async {
        let server = FakeServer()
        let a = makeRepo(server: server)
        a.load(vineyardId: vineyard)
        a.save(makePlan(id: "plan-a", vineyardId: vineyard))
        await a.sync(vineyardId: vineyard)

        let b = makeRepo(server: server)
        b.load(vineyardId: otherVineyard)
        await b.sync(vineyardId: otherVineyard)
        #expect(b.plans.isEmpty, "another vineyard's plan leaked")
    }

    // MARK: - Offline

    @Test func planCreatedOfflineGetsIdImmediatelyAndIsEditable() {
        // No server at all: the id must come from the device, not from Supabase.
        let repository = makeRepo(server: nil)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "offline-plan"))
        #expect(repository.plans[0].id == "offline-plan")

        repository.save(repository.plans[0].addingPosition(position("pos-4", ["40"]), atEpochMs: 2_000))
        #expect(repository.plans[0].positions.count == 4)
    }

    @Test func offlineCreateIsQueuedAndReplaysOnNextSync() async {
        let server = FakeServer()
        server.failNextUpsert = true
        let repository = makeRepo(server: server)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "queued"))

        let failed = await repository.sync(vineyardId: vineyard)
        #expect(!failed.isSuccess)
        #expect(server.rows.isEmpty, "server should hold nothing yet")
        // The plan is still there and still queued — nothing was dropped.
        #expect(repository.plans[0].id == "queued")
        #expect(repository.syncState == .failed)
        #expect(repository.pendingCount() == 1)

        let ok = await repository.sync(vineyardId: vineyard)
        #expect(ok.isSuccess)
        #expect(server.rows.count == 1)
        #expect(repository.pendingCount() == 0)
        #expect(repository.syncState == .synced)
    }

    @Test func offlineEditToPreviouslySyncedPlanReplays() async {
        let server = FakeServer()
        let repository = makeRepo(server: server)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "p"))
        await repository.sync(vineyardId: vineyard)

        server.failNextUpsert = true
        repository.save(repository.plans[0].settingNotes("added offline", atEpochMs: 20_000))
        _ = await repository.sync(vineyardId: vineyard)
        #expect(server.rows["p"]?.notes == nil, "edit must not reach the server yet")

        let ok = await repository.sync(vineyardId: vineyard)
        #expect(ok.isSuccess)
        #expect(server.rows["p"]?.notes == "added offline")
    }

    // MARK: - Multi-device

    @Test func deviceBSeesPlanFromDeviceAAndAConvergesOnBsEdit() async {
        let server = FakeServer()
        let deviceA = makeRepo(server: server)
        let deviceB = makeRepo(server: server)

        deviceA.load(vineyardId: vineyard)
        deviceA.save(makePlan(id: "shared", updatedAt: 1_000))
        #expect(await deviceA.sync(vineyardId: vineyard).isSuccess)

        deviceB.load(vineyardId: vineyard)
        #expect(await deviceB.sync(vineyardId: vineyard).isSuccess)
        let onB = try! #require(deviceB.plans.first)
        #expect(onB.id == "shared")
        #expect(onB.positions.map(\.id) == ["pos-1", "pos-2", "pos-3"])

        deviceB.save(onB.movingPositionUp(id: "pos-3", atEpochMs: 30_000))
        #expect(await deviceB.sync(vineyardId: vineyard).isSuccess)

        #expect(await deviceA.sync(vineyardId: vineyard).isSuccess)
        let onA = try! #require(deviceA.plans.first)
        #expect(onA.id == "shared")
        #expect(onA.positions.map(\.id) == ["pos-1", "pos-3", "pos-2"])
    }

    @Test func staleOfflineReplayDoesNotOverwriteNewerEditFromAnotherDevice() async {
        let server = FakeServer()
        let deviceA = makeRepo(server: server)
        let deviceB = makeRepo(server: server)

        deviceA.load(vineyardId: vineyard)
        deviceA.save(makePlan(id: "shared", updatedAt: 1_000))
        await deviceA.sync(vineyardId: vineyard)
        deviceB.load(vineyardId: vineyard)
        await deviceB.sync(vineyardId: vineyard)

        // A edits OFFLINE at T1.
        server.failNextUpsert = true
        deviceA.save(deviceA.plans[0].settingNotes("A offline at T1", atEpochMs: 2_000))
        await deviceA.sync(vineyardId: vineyard)

        // B edits ONLINE at T2 > T1.
        deviceB.save(deviceB.plans[0].settingNotes("B online at T2", atEpochMs: 3_000))
        #expect(await deviceB.sync(vineyardId: vineyard).isSuccess)
        #expect(server.rows["shared"]?.notes == "B online at T2")

        // A reconnects and replays its older edit: the sql/198 revision guard refuses it.
        let replay = await deviceA.sync(vineyardId: vineyard)
        #expect(
            server.rows["shared"]?.notes == "B online at T2",
            "a late offline replay overwrote a newer edit"
        )
        // The refusal is a CONFLICT, not a silent skip. A's authored edit exists nowhere
        // else, so it stays queued and on screen while both versions are preserved for an
        // explicit choice — converging automatically would be the auto-resolution the
        // contract forbids (deciding by "T2 > T1" is exactly the clock arbitration sql/198
        // removed).
        #expect(replay.conflicted == 1)
        #expect(deviceA.syncState == .conflict)
        #expect(deviceA.pendingCount() == 1)
        #expect(deviceA.plans[0].notes == "A offline at T1")
        let conflict = deviceA.conflict(id: "shared")
        #expect(conflict?.localPending.notes == "A offline at T1")
        #expect(conflict?.serverCurrent?.notes == "B online at T2")

        // Convergence happens the only legitimate way: the grower chooses.
        deviceA.resolveKeepingServer(id: "shared")
        #expect(deviceA.plans[0].notes == "B online at T2")
        #expect(deviceA.pendingCount() == 0)
    }

    @Test func aLaggingReplicaReadCannotOverwriteARevisionNewerConfirmedWrite() async {
        let server = FakeServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "p", updatedAt: 1_000))
        await repository.sync(vineyardId: vineyard)

        // The push succeeds, but the pull in the same pass lands on a LAGGING REPLICA and
        // returns the pre-push row. Detected by REVISION now, not by comparing device
        // clocks — which is what makes it work even on a device whose clock runs backwards.
        clock.now = 1_000
        server.serveStaleReadNext = true
        repository.save(repository.plans[0].settingNotes("newer local", atEpochMs: 1_000))
        let result = await repository.sync(vineyardId: vineyard)

        #expect(repository.plans[0].notes == "newer local")
        #expect(result.staleRemoteIgnored == 1)
        #expect(result.conflicted == 0)
        #expect(repository.plans[0].serverRevision == 2)
        #expect(repository.pendingCount() == 0)
    }

    @Test func positionArraysFromTwoDevicesAreNeverMergedElementWise() async {
        let server = FakeServer()
        let deviceA = makeRepo(server: server)
        let deviceB = makeRepo(server: server)

        deviceA.load(vineyardId: vineyard)
        deviceA.save(makePlan(id: "shared", updatedAt: 1_000))
        await deviceA.sync(vineyardId: vineyard)
        deviceB.load(vineyardId: vineyard)
        await deviceB.sync(vineyardId: vineyard)

        deviceA.save(deviceA.plans[0].removingPosition(id: "pos-2", atEpochMs: 2_000))
        await deviceA.sync(vineyardId: vineyard)
        deviceB.save(deviceB.plans[0].movingPositionUp(id: "pos-3", atEpochMs: 3_000))
        let bResult = await deviceB.sync(vineyardId: vineyard)

        // B's reorder was based on the original three-position document, which A's
        // removal superseded — the server refuses the write outright rather than splicing.
        #expect(bResult.conflicted == 1)

        await deviceA.sync(vineyardId: vineyard)
        // Every copy anywhere is one of the two AUTHORED sequences. The server and A hold
        // A's document; B still shows its own, with both versions preserved in the
        // conflict record. A spliced third sequence that nobody chose exists nowhere.
        let authoredByA = ["pos-1", "pos-3"]
        let authoredByB = ["pos-1", "pos-3", "pos-2"]
        #expect(server.rows["shared"]?.positions.map(\.id) == authoredByA)
        #expect(deviceA.plans[0].positions.map(\.id) == authoredByA)
        #expect(deviceB.plans[0].positions.map(\.id) == authoredByB)
        let conflict = deviceB.conflict(id: "shared")
        #expect(conflict?.localPending.positions.map(\.id) == authoredByB)
        #expect(conflict?.serverCurrent?.positions.map(\.id) == authoredByA)
    }

    // MARK: - Delete / archive

    @Test func deleteArchivesLocallyAndTombstonesOnTheServer() async {
        let server = FakeServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "doomed"))
        await repository.sync(vineyardId: vineyard)

        clock.now = 40_000
        repository.delete(id: "doomed")
        #expect(repository.plans.isEmpty, "archived plan must leave the live list")

        #expect(await repository.sync(vineyardId: vineyard).isSuccess)
        #expect(server.softDeleteCalls == 1)
        #expect(server.rows["doomed"] != nil, "server row must be tombstoned, not removed")
        #expect(server.rows["doomed"]?.deletedAtEpochMs != nil)
    }

    @Test func deletePropagatesToOtherDeviceInsteadOfBeingResurrected() async {
        let server = FakeServer()
        let clock = Clock()
        let deviceA = makeRepo(server: server, clock: clock)
        let deviceB = makeRepo(server: server)

        deviceA.load(vineyardId: vineyard)
        deviceA.save(makePlan(id: "shared"))
        await deviceA.sync(vineyardId: vineyard)
        deviceB.load(vineyardId: vineyard)
        await deviceB.sync(vineyardId: vineyard)
        #expect(deviceB.plans.count == 1)

        clock.now = 50_000
        deviceA.delete(id: "shared")
        await deviceA.sync(vineyardId: vineyard)

        // B pulls the tombstone and stops showing the plan. It must NOT push it back.
        await deviceB.sync(vineyardId: vineyard)
        #expect(deviceB.plans.isEmpty, "the deleted plan came back on device B")
        #expect(server.rows["shared"]?.deletedAtEpochMs != nil)
    }

    @Test func planCreatedAndDeletedWhileOfflineStillDeletesOnReconnect() async {
        let server = FakeServer()
        let clock = Clock()
        let repository = makeRepo(server: server, clock: clock)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "ghost"))
        clock.now = 60_000
        repository.delete(id: "ghost")

        #expect(await repository.sync(vineyardId: vineyard).isSuccess)
        // The row had to be created before it could be tombstoned, otherwise the delete
        // would silently target nothing and the plan would reappear from the outbox.
        #expect(server.rows["ghost"] != nil)
        #expect(server.rows["ghost"]?.deletedAtEpochMs != nil)
        #expect(repository.plans.isEmpty)
    }

    @Test func restoreBringsArchivedPlanBack() {
        let repository = makeRepo(server: nil)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "p"))
        repository.delete(id: "p")
        #expect(repository.plans.isEmpty)

        repository.restore(id: "p")
        #expect(repository.plans[0].id == "p")
    }

    // MARK: - Local-only adoption (Planner v1 -> synced)

    @Test func existingLocalOnlyPlansAreUploadedOnceAndKeepTheirIds() async {
        let store = InMemoryResistancePlanLocalStore()

        // Planner v1: two plans saved with no server at all.
        let legacy = makeRepo(server: nil, store: store)
        legacy.load(vineyardId: vineyard)
        legacy.save(makePlan(id: "legacy-1"))
        legacy.save(makePlan(id: "legacy-2", seasonId: "2025/26"))

        let server = FakeServer()
        let synced = makeRepo(server: server, store: store)
        synced.load(vineyardId: vineyard)
        let result = await synced.sync(vineyardId: vineyard)

        #expect(result.isSuccess)
        #expect(result.adopted == 2)
        #expect(Set(server.rows.keys) == ["legacy-1", "legacy-2"])
        // Ids preserved — this is what makes the upload idempotent rather than a second
        // copy of the same season.
        #expect(server.rows.count == 2)
    }

    @Test func secondMigrationRunDoesNotDuplicateAdoptedPlans() async {
        let store = InMemoryResistancePlanLocalStore()
        let legacy = makeRepo(server: nil, store: store)
        legacy.load(vineyardId: vineyard)
        legacy.save(makePlan(id: "legacy-1"))

        let server = FakeServer()
        let synced = makeRepo(server: server, store: store)
        synced.load(vineyardId: vineyard)
        await synced.sync(vineyardId: vineyard)
        let callsAfterFirst = server.upsertCalls

        let relaunched = makeRepo(server: server, store: store)
        relaunched.load(vineyardId: vineyard)
        let second = await relaunched.sync(vineyardId: vineyard)
        await relaunched.sync(vineyardId: vineyard)

        #expect(second.adopted == 0)
        #expect(server.rows.count == 1)
        #expect(server.upsertCalls <= callsAfterFirst, "adoption re-ran and re-pushed")
    }

    @Test func localPlanStaysUsableWhenNetworkFailsDuringMigration() async {
        let store = InMemoryResistancePlanLocalStore()
        let legacy = makeRepo(server: nil, store: store)
        legacy.load(vineyardId: vineyard)
        legacy.save(makePlan(id: "legacy-1"))

        let server = FakeServer()
        server.failNextUpsert = true
        let synced = makeRepo(server: server, store: store)
        synced.load(vineyardId: vineyard)
        let failed = await synced.sync(vineyardId: vineyard)

        #expect(!failed.isSuccess)
        // Still readable, still editable, still queued.
        #expect(synced.plans[0].id == "legacy-1")
        synced.save(synced.plans[0].settingNotes("still editable", atEpochMs: 11_000))
        #expect(synced.plans[0].notes == "still editable")
        #expect(
            !store.isAdopted(vineyardId: vineyard),
            "migration must not be marked done after a failure"
        )

        #expect(await synced.sync(vineyardId: vineyard).isSuccess)
        #expect(server.rows.count == 1)
        #expect(store.isAdopted(vineyardId: vineyard))
    }

    @Test func freshInstallWithNoLocalPlansMarksAdoptionCompleteWithoutUploading() async {
        let server = FakeServer()
        let store = InMemoryResistancePlanLocalStore()
        let repository = makeRepo(server: server, store: store)
        repository.load(vineyardId: vineyard)
        let result = await repository.sync(vineyardId: vineyard)

        #expect(result.adopted == 0)
        #expect(server.upsertCalls == 0)
        #expect(store.isAdopted(vineyardId: vineyard))
    }

    // MARK: - Ruleset metadata

    @Test func rulesetIdAndVersionSurviveSaveAndReload() {
        let store = InMemoryResistancePlanLocalStore()
        let repository = makeRepo(server: nil, store: store)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())

        let reloaded = makeRepo(server: nil, store: store)
        reloaded.load(vineyardId: vineyard)
        #expect(reloaded.plans[0].rulesetId == "AU_GRAPE_POWDERY_2026_07_22")
        #expect(reloaded.plans[0].rulesetVersion == "2026.07.22")
    }

    @Test func planStampedWithCurrentVersionReportsNoUpdateAvailable() throws {
        let registry = ResistanceRulesets.registry
        let current = try #require(
            registry.current(jurisdiction: .australia, crop: .grape, disease: .powderyMildew)
        )
        let saved = makePlan(rulesetVersion: current.rulesetVersion)
        #expect(!saved.isStrategyOutdated(against: registry))
    }

    @Test func planStampedWithOlderVersionReportsUpdateAvailable() {
        let registry = ResistanceRulesets.registry
        let saved = makePlan(rulesetVersion: "2019.01.01")
        #expect(saved.isStrategyOutdated(against: registry))
        // And the stored stamp is NOT rewritten by asking the question.
        #expect(saved.rulesetVersion == "2019.01.01")
    }

    @Test func syncingNeverRewritesStampedRulesetVersion() async {
        let server = FakeServer()
        let repository = makeRepo(server: server)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "old", rulesetVersion: "2019.01.01"))
        await repository.sync(vineyardId: vineyard)

        #expect(server.rows["old"]?.rulesetVersion == "2019.01.01")
        #expect(repository.plans[0].rulesetVersion == "2019.01.01")
    }

    // MARK: - Tolerance for deleted references

    @Test func positionKeepsPlannedGroupWhenSavedChemicalIsGone() {
        // The Chemical Store product was deleted after planning. The plan must still know
        // WHAT CHEMISTRY it intended, which is why group codes are stored alongside the
        // product id rather than being re-derived from today's product record.
        let store = InMemoryResistancePlanLocalStore()
        let repository = makeRepo(server: nil, store: store)
        repository.load(vineyardId: vineyard)
        repository.save(
            makePlan(positions: [
                ResistancePlannedPosition(
                    id: "pos-1",
                    products: [product(["7"], chemicalId: "chem-deleted")]
                )
            ])
        )

        let reloaded = makeRepo(server: nil, store: store)
        reloaded.load(vineyardId: vineyard)
        let loaded = reloaded.plans[0].positions[0].products[0]

        #expect(loaded.groupCodes == ["7"])
        #expect(loaded.savedChemicalId == "chem-deleted")
        #expect(loaded.source == .savedChemical)
        // The intent is intact even though nothing can resolve the product any more.
        #expect(loaded.groups == ResistanceGroupSignature.of(["7"]))
    }

    @Test func planKeepsBlockIdThatNoLongerResolves() {
        let store = InMemoryResistancePlanLocalStore()
        let repository = makeRepo(server: nil, store: store)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(blockIds: ["block-a", "block-archived"]))

        let reloaded = makeRepo(server: nil, store: store)
        reloaded.load(vineyardId: vineyard)
        #expect(reloaded.plans[0].blockIds == ["block-a", "block-archived"])
    }

    // MARK: - Sync state reporting

    @Test func syncStateReportsLocalOnlyWithNoServer() {
        let repository = makeRepo(server: nil)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())
        #expect(repository.syncState == .localOnly)
    }

    @Test func syncStateReportsPendingUploadAfterOfflineEdit() {
        let repository = makeRepo(server: FakeServer())
        repository.load(vineyardId: vineyard)
        repository.save(makePlan())
        #expect(repository.syncState == .pendingUpload)
    }

    @Test func failedFetchLeavesCacheIntact() async {
        let server = FakeServer()
        let repository = makeRepo(server: server)
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "p"))
        await repository.sync(vineyardId: vineyard)

        server.failNextFetch = true
        let result = await repository.sync(vineyardId: vineyard)
        #expect(!result.isSuccess)
        #expect(repository.plans[0].id == "p")
    }

    // MARK: - Cross-platform JSON parity

    @Test func positionsDocumentUsesSharedSnakeCaseWireContract() throws {
        // These exact keys are asserted on Android too. A silent rename on one platform is
        // how "the plan I made on my phone is empty on the iPad" happens.
        let encoder = JSONEncoder()
        let data = try encoder.encode(
            ResistancePlannedPosition(
                id: "pos-1",
                products: [product(["11", "3"], chemicalId: "chem-1")],
                targetDateEpochMs: 1_790_000_000_000,
                growthStage: "flowering",
                note: "n"
            )
        )
        let encoded = try #require(String(data: data, encoding: .utf8))

        for key in [
            "\"id\"", "\"products\"", "\"group_codes\"", "\"source\"",
            "\"saved_chemical_id\"", "\"product_name\"",
            "\"target_date_epoch_ms\"", "\"growth_stage\"", "\"note\"",
        ] {
            #expect(encoded.contains(key), "missing wire key \(key)")
        }
        // camelCase must never appear.
        #expect(!encoded.contains("groupCodes"))
        #expect(!encoded.contains("savedChemicalId"))
        #expect(!encoded.contains("targetDateEpochMs"))
        #expect(ResistancePlannedChemistrySource.savedChemical.rawValue == "saved_chemical")
    }

    @Test func planDocumentDecodesFromSharedWireForm() throws {
        // Byte-for-byte what Android emits, decoded here.
        let wire = """
        {
          "id": "plan-x",
          "vineyard_id": "vy-1",
          "season_id": "2026/27",
          "season_start_year": 2026,
          "disease": "powdery_mildew",
          "jurisdiction": "AU",
          "crop": "grape",
          "block_ids": ["block-a", "block-b"],
          "positions": [
            {"id":"pos-1","products":[{"id":"pr-1","group_codes":["3"],"source":"group"}]},
            {"id":"pos-2","products":[{"id":"pr-2","group_codes":["11","3"],"source":"saved_chemical","saved_chemical_id":"c1","product_name":"Mix","chemical_availability":"available_verified"}],"target_date_epoch_ms":1790000000000,"growth_stage":"flowering"}
          ],
          "notes": "n",
          "ruleset_id": "AU_GRAPE_POWDERY_2026_07_22",
          "ruleset_version": "2026.07.22",
          "created_by": "user-1",
          "created_at_epoch_ms": 1000,
          "updated_at_epoch_ms": 2000
        }
        """
        let decoded = try JSONDecoder().decode(
            ResistancePlan.self,
            from: try #require(wire.data(using: .utf8))
        )

        #expect(decoded.id == "plan-x")
        #expect(decoded.seasonStartYear == 2026)
        #expect(decoded.disease == .powderyMildew)
        #expect(decoded.jurisdiction == .australia)
        #expect(decoded.blockIds == ["block-a", "block-b"])
        #expect(decoded.positions.map(\.id) == ["pos-1", "pos-2"])
        #expect(decoded.positions[1].products[0].groupCodes == ["11", "3"])
        #expect(decoded.positions[1].products[0].savedChemicalId == "c1")
        #expect(decoded.positions[1].targetDateEpochMs == 1_790_000_000_000)
        #expect(decoded.rulesetVersion == "2026.07.22")
        #expect(decoded.createdBy == "user-1")
        #expect(decoded.deletedAtEpochMs == nil)
    }

    @Test func createdByIsStampedOnceAndNotRewrittenByLaterEditor() async {
        let server = FakeServer()
        let store = InMemoryResistancePlanLocalStore()
        let author = ResistancePlanRepository(
            local: store, remote: server, clock: { 10_000 }, currentUserId: { "author" }
        )
        author.load(vineyardId: vineyard)
        author.save(makePlan(id: "p"))
        await author.sync(vineyardId: vineyard)
        #expect(server.rows["p"]?.createdBy == "author")

        let colleagueStore = InMemoryResistancePlanLocalStore()
        let colleague = ResistancePlanRepository(
            local: colleagueStore, remote: server, clock: { 70_000 }, currentUserId: { "colleague" }
        )
        colleague.load(vineyardId: vineyard)
        await colleague.sync(vineyardId: vineyard)
        colleague.save(colleague.plans[0].settingNotes("colleague edit", atEpochMs: 70_000))
        await colleague.sync(vineyardId: vineyard)

        #expect(server.rows["p"]?.notes == "colleague edit")
        #expect(server.rows["p"]?.createdBy == "author", "attribution was overwritten")
    }

    // MARK: - No derived evaluation is ever persisted

    @Test func onlyPlanDefinitionIsPersisted() throws {
        // Structural guarantee: the encoded plan has no key that could carry a verdict. If
        // someone later adds a `lastStatus` to ResistancePlan, this is what should stop them.
        let data = try JSONEncoder().encode(makePlan())
        let encoded = try #require(String(data: data, encoding: .utf8)).lowercased()
        for word in ["status", "verdict", "warning", "finding", "evaluation", "goodfit"] {
            #expect(
                !encoded.contains(word),
                "ResistancePlan must not persist derived evaluation output (\(word))"
            )
        }
    }
}
