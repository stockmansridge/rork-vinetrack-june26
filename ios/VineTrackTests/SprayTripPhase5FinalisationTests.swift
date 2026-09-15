import Foundation
import XCTest
@testable import VineTrack

/// Records what the sync layer actually sent, so the dependency order
/// `Trip parent -> Spray Record -> Tank Actuals -> final Trip state` is asserted
/// against real pushed payloads rather than helper return values.
actor FakeTripSyncRepository: TripSyncRepositoryProtocol {
    private(set) var batches: [[BackendTripUpsert]] = []
    /// Persistent, because SyncQueuePush retries each item individually after a
    /// failed batch — a one-shot failure would silently succeed on retry.
    private var failUpserts: Bool = false

    /// Every payload pushed, flattened, in order.
    var pushed: [BackendTripUpsert] { batches.flatMap { $0 } }

    func setFailUpserts(_ value: Bool) { failUpserts = value }

    func upsertTrips(_ trips: [BackendTripUpsert]) async throws {
        if failUpserts { throw URLError(.timedOut) }
        batches.append(trips)
    }

    func upsertTrip(_ trip: BackendTripUpsert) async throws { try await upsertTrips([trip]) }
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] { [] }
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] { [] }
    func fetchAllAccessibleTrips() async throws -> [BackendTrip] { [] }
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {}
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {}
    func softDeleteTrip(id: UUID) async throws {}
}

/// Behavioural coverage for the Phase 5 trip-finalisation / tank-actual
/// deadlock. XCTest so `-only-testing` can select and execute it.
@MainActor
final class SprayTripPhase5FinalisationTests: XCTestCase {

    private let vineyardId = UUID(uuidString: "00BB9A18-28DA-4BA7-9136-B2C5A1B56FB5")!
    private let userId = UUID(uuidString: "94238371-53C6-472D-975B-48BF98A268A9")!
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase5-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func endedTrip(id: UUID, endTime: Date) -> Trip {
        Trip(
            id: id,
            vineyardId: vineyardId,
            startTime: endTime.addingTimeInterval(-10_000),
            endTime: endTime,
            isActive: false
        )
    }

    private struct Harness {
        let service: TripSyncService
        let metadata: TripSyncMetadata
        let repository: FakeTripSyncRepository
        let store: MigratedDataStore
        let actuals: SprayTankActualStore
    }

    private func makeHarness(trips: [Trip]) -> Harness {
        let directory = makeDirectory()
        let persistence = PersistenceStore(directory: directory)
        let metadata = TripSyncMetadata(persistence: persistence)
        let repository = FakeTripSyncRepository()
        let service = TripSyncService(repository: repository, metadata: metadata)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        store.trips = trips
        let auth = NewBackendAuthService()
        auth.isSignedIn = true
        auth.userId = userId
        service.configure(store: store, auth: auth)
        let actuals = SprayTankActualStore(persistence: persistence)
        service.configurePhase5EndGate { [weak actuals] tripId in
            actuals?.hasPending(tripId: tripId) ?? false
        }
        return Harness(service: service, metadata: metadata, repository: repository, store: store, actuals: actuals)
    }

    private func makeActual(
        id: UUID = UUID(),
        tripId: UUID,
        sprayRecordId: UUID,
        tankNumber: Int,
        sessionId: String
    ) throws -> SprayTankActual {
        try SprayTankActual(
            id: id,
            vineyardId: vineyardId,
            sprayRecordId: sprayRecordId,
            tripId: tripId,
            tankSessionId: sessionId,
            tankNumber: tankNumber,
            waterVolumeL: 800,
            chemicals: [],
            confirmedAt: Date(timeIntervalSince1970: 1_780_000_000),
            confirmedBy: userId
        )
    }

    // MARK: - 1. Parent not yet uploaded

    func testTankActualWaitsWhileTripParentHasNeverBeenUploaded() async throws {
        let tripId = UUID()
        let harness = makeHarness(trips: [endedTrip(id: tripId, endTime: Date(timeIntervalSince1970: 1_780_000_000))])
        harness.metadata.markDirty(tripId, at: Date())

        XCTAssertFalse(harness.service.isParentEstablished(tripId))
        XCTAssertTrue(harness.service.isPendingParentCreation(tripId))

        let decision = SprayTankActualUploadGate.decide(
            parentTripBlocked: harness.service.isPendingParentCreation(tripId),
            sprayRecordPending: false
        )
        XCTAssertEqual(decision, .skipParentTripNotEstablished)
        XCTAssertNotNil(decision.skipReason)
        // No child-before-parent upload occurred.
        let pushed = await harness.repository.pushed
        XCTAssertTrue(pushed.isEmpty)
    }

    // MARK: - 2. Parent exists, finalisation still queued

    func testGenericPendingTripDoesNotBlockItsOwnActual() throws {
        let tripId = UUID()
        let harness = makeHarness(trips: [endedTrip(id: tripId, endTime: Date(timeIntervalSince1970: 1_780_000_000))])
        harness.metadata.markParentsEstablished([tripId])
        harness.metadata.markDirty(tripId, at: Date())

        // Queued, but only for finalisation.
        XCTAssertTrue(harness.metadata.pendingUpserts[tripId] != nil)
        XCTAssertFalse(harness.service.isPendingParentCreation(tripId))
        XCTAssertTrue(harness.service.isPendingFinalisationOnly(tripId))

        XCTAssertEqual(
            SprayTankActualUploadGate.decide(
                parentTripBlocked: harness.service.isPendingParentCreation(tripId),
                sprayRecordPending: false
            ),
            .upload
        )
    }

    func testPendingSprayRecordStillDefersItsActual() {
        XCTAssertEqual(
            SprayTankActualUploadGate.decide(parentTripBlocked: false, sprayRecordPending: true),
            .skipSprayRecordNotEstablished
        )
    }

    // MARK: - 3. Phase 5 hold never falsifies the payload

    func testPhase5HoldUploadsTrueEndedStateAndKeepsTripQueued() async throws {
        let tripId = UUID()
        let sprayRecordId = UUID()
        let endTime = Date(timeIntervalSince1970: 1_780_000_000)
        let harness = makeHarness(trips: [endedTrip(id: tripId, endTime: endTime)])
        try harness.actuals.saveLocally(
            try makeActual(tripId: tripId, sprayRecordId: sprayRecordId, tankNumber: 1, sessionId: "tank-1")
        )
        harness.metadata.markDirty(tripId, at: Date())

        try await harness.service.pushLocalTrips(vineyardId: vineyardId)

        let pushed = await harness.repository.pushed
        let payload = try XCTUnwrap(pushed.first { $0.id == tripId })
        // The old hold sent is_active = true and omitted the nil end_time,
        // leaving the server active AND ended. That must be unreachable.
        XCTAssertFalse(payload.isActive)
        XCTAssertEqual(payload.endTime, endTime)
        XCTAssertFalse(payload.isActive && payload.endTime != nil)
        // Local state is untouched by the hold.
        let local = try XCTUnwrap(harness.store.trips.first { $0.id == tripId })
        XCTAssertFalse(local.isActive)
        XCTAssertEqual(local.endTime, endTime)
        // Parent now demonstrably exists; finalisation stays queued.
        XCTAssertTrue(harness.service.isParentEstablished(tripId))
        XCTAssertFalse(harness.service.isPendingParentCreation(tripId))
        XCTAssertTrue(harness.service.isPendingFinalisationOnly(tripId))
    }

    // MARK: - 4. Actual upload succeeds -> gate releases

    func testGateReleasesAndSecondSyncClearsTheTripQueue() async throws {
        let tripId = UUID()
        let sprayRecordId = UUID()
        let endTime = Date(timeIntervalSince1970: 1_780_000_000)
        let harness = makeHarness(trips: [endedTrip(id: tripId, endTime: endTime)])
        let actual = try makeActual(tripId: tripId, sprayRecordId: sprayRecordId, tankNumber: 1, sessionId: "tank-1")
        try harness.actuals.saveLocally(actual)
        harness.metadata.markDirty(tripId, at: Date())

        try await harness.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertTrue(harness.metadata.pendingUpserts[tripId] != nil, "held while actuals pending")

        // The actual uploads and leaves the pending queue.
        try harness.actuals.removeLocal(id: actual.id)
        XCTAssertEqual(harness.actuals.pendingCount(tripId: tripId), 0)
        XCTAssertFalse(harness.actuals.hasPending(tripId: tripId))

        try await harness.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertNil(harness.metadata.pendingUpserts[tripId], "queue clears once actuals are gone")
        let pushed = await harness.repository.pushed
        let final = try XCTUnwrap(pushed.last { $0.id == tripId })
        XCTAssertFalse(final.isActive)
        XCTAssertEqual(final.endTime, endTime)
    }

    // MARK: - 5. Retryable failure

    func testRetryableFailureKeepsQueueAndIdentitiesStableWithoutDuplicates() async throws {
        let tripId = UUID()
        let sprayRecordId = UUID()
        let endTime = Date(timeIntervalSince1970: 1_780_000_000)
        let harness = makeHarness(trips: [endedTrip(id: tripId, endTime: endTime)])
        let actual = try makeActual(tripId: tripId, sprayRecordId: sprayRecordId, tankNumber: 1, sessionId: "tank-1")
        try harness.actuals.saveLocally(actual)
        harness.metadata.markDirty(tripId, at: Date())

        await harness.repository.setFailUpserts(true)
        _ = try? await harness.service.pushLocalTrips(vineyardId: vineyardId)

        // Trip stays queued and the parent was never falsely claimed.
        XCTAssertTrue(harness.metadata.pendingUpserts[tripId] != nil)
        XCTAssertFalse(harness.service.isParentEstablished(tripId))
        // The actual stays pending.
        XCTAssertEqual(harness.actuals.pendingCount(tripId: tripId), 1)

        // Retrying the same actual must not duplicate it.
        try harness.actuals.saveLocally(actual)
        XCTAssertEqual(harness.actuals.records.filter { $0.tripId == tripId }.count, 1)
        let retained = try XCTUnwrap(harness.actuals.records.first { $0.tripId == tripId })
        XCTAssertEqual(retained.id, actual.id)
        XCTAssertEqual(retained.tripId, tripId)
        XCTAssertEqual(retained.sprayRecordId, sprayRecordId)
        XCTAssertEqual(retained.tankSessionId, "tank-1")
        XCTAssertEqual(harness.store.trips.first { $0.id == tripId }?.endTime, endTime)
    }

    // MARK: - 6. Legacy Estellar-style recovery

    func testEstellarRecoveryUploadsActualAndWritesTrueEndedStateWithoutRecreating() async throws {
        let tripId = UUID(uuidString: "890D268F-EA69-4A98-B0FA-844362F55B76")!
        let sprayRecordId = UUID(uuidString: "5A000000-0000-4000-8000-000000000001")!
        let endTime = Date(timeIntervalSince1970: 1_780_000_000)
        let harness = makeHarness(trips: [endedTrip(id: tripId, endTime: endTime)])

        // Server already holds the trip and spray record (the trip in the
        // historical bad state end_time != NULL && is_active = true), while the
        // device still has both the trip and its actual queued.
        harness.metadata.markParentsEstablished([tripId])
        harness.metadata.markDirty(tripId, at: Date())
        let actual = try makeActual(tripId: tripId, sprayRecordId: sprayRecordId, tankNumber: 1, sessionId: "tank-1")
        try harness.actuals.saveLocally(actual)

        let tripCountBefore = harness.store.trips.count

        // Parent is recognised, so the existing actual may upload on its own identity.
        XCTAssertFalse(harness.service.isPendingParentCreation(tripId))
        XCTAssertEqual(
            SprayTankActualUploadGate.decide(
                parentTripBlocked: harness.service.isPendingParentCreation(tripId),
                sprayRecordPending: false
            ),
            .upload
        )
        XCTAssertEqual(harness.actuals.records.filter { $0.tripId == tripId }.count, 1)
        XCTAssertEqual(harness.actuals.records.first?.id, actual.id)

        try harness.actuals.removeLocal(id: actual.id)
        try await harness.service.pushLocalTrips(vineyardId: vineyardId)

        // True ended state written; nothing recreated; queue cleared.
        let pushed = await harness.repository.pushed
        let payload = try XCTUnwrap(pushed.last { $0.id == tripId })
        XCTAssertFalse(payload.isActive)
        XCTAssertEqual(payload.endTime, endTime)
        XCTAssertEqual(payload.id, tripId)
        XCTAssertEqual(harness.store.trips.count, tripCountBefore)
        XCTAssertNil(harness.metadata.pendingUpserts[tripId])
        XCTAssertEqual(pushed.filter { $0.id == tripId }.count, 1)
    }

    // MARK: - 7. Multiple tanks

    func testFinalisationReleasesOnlyWhenEveryTankActualHasCleared() async throws {
        let tripId = UUID()
        let sprayRecordId = UUID()
        let endTime = Date(timeIntervalSince1970: 1_780_000_000)
        let harness = makeHarness(trips: [endedTrip(id: tripId, endTime: endTime)])
        let tank1 = try makeActual(tripId: tripId, sprayRecordId: sprayRecordId, tankNumber: 1, sessionId: "tank-1")
        let tank2 = try makeActual(tripId: tripId, sprayRecordId: sprayRecordId, tankNumber: 2, sessionId: "tank-2")
        try harness.actuals.saveLocally(tank1)
        try harness.actuals.saveLocally(tank2)
        harness.metadata.markDirty(tripId, at: Date())

        XCTAssertEqual(harness.actuals.pendingCount(tripId: tripId), 2)
        XCTAssertEqual(harness.actuals.actual(tripId: tripId, tankNumber: 1)?.id, tank1.id)
        XCTAssertEqual(harness.actuals.actual(tripId: tripId, tankNumber: 2)?.id, tank2.id)

        try await harness.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertTrue(harness.metadata.pendingUpserts[tripId] != nil)

        // Tank 1 completing must not complete tank 2.
        try harness.actuals.removeLocal(id: tank1.id)
        XCTAssertEqual(harness.actuals.pendingCount(tripId: tripId), 1)
        XCTAssertTrue(harness.actuals.hasPending(tripId: tripId))
        XCTAssertEqual(harness.actuals.actual(tripId: tripId, tankNumber: 2)?.id, tank2.id)

        try await harness.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertTrue(harness.metadata.pendingUpserts[tripId] != nil, "still held by tank 2")

        try harness.actuals.removeLocal(id: tank2.id)
        try await harness.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertNil(harness.metadata.pendingUpserts[tripId])
    }

    // MARK: - 8. Dependency order across the sweep

    func testFullSequenceEstablishesParentBeforeActualsAndFinalisesLast() async throws {
        let tripId = UUID()
        let sprayRecordId = UUID()
        let endTime = Date(timeIntervalSince1970: 1_780_000_000)
        let harness = makeHarness(trips: [endedTrip(id: tripId, endTime: endTime)])
        let actual = try makeActual(tripId: tripId, sprayRecordId: sprayRecordId, tankNumber: 1, sessionId: "tank-1")
        try harness.actuals.saveLocally(actual)
        harness.metadata.markDirty(tripId, at: Date())

        // Stage 0 — nothing on the server: the actual must wait.
        XCTAssertEqual(
            SprayTankActualUploadGate.decide(
                parentTripBlocked: harness.service.isPendingParentCreation(tripId),
                sprayRecordPending: true
            ),
            .skipParentTripNotEstablished
        )

        // Stage 1 — trip sync establishes the parent.
        try await harness.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertTrue(harness.service.isParentEstablished(tripId))

        // Stage 2 — spray record still pending blocks the actual.
        XCTAssertEqual(
            SprayTankActualUploadGate.decide(
                parentTripBlocked: harness.service.isPendingParentCreation(tripId),
                sprayRecordPending: true
            ),
            .skipSprayRecordNotEstablished
        )

        // Stage 3 — spray record landed: the actual uploads.
        XCTAssertEqual(
            SprayTankActualUploadGate.decide(
                parentTripBlocked: harness.service.isPendingParentCreation(tripId),
                sprayRecordPending: false
            ),
            .upload
        )
        try harness.actuals.removeLocal(id: actual.id)

        // Stage 4 — trip sync again finalises.
        try await harness.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertNil(harness.metadata.pendingUpserts[tripId])
        let payloads = await harness.repository.pushed.filter { $0.id == tripId }
        XCTAssertEqual(payloads.count, 2, "parent establish, then finalisation")
        XCTAssertTrue(payloads.allSatisfy { !$0.isActive && $0.endTime == endTime })
    }

    // MARK: - Persistence of parent establishment

    func testEstablishedParentsSurviveRelaunch() {
        let directory = makeDirectory()
        let tripId = UUID(uuidString: "C9CB8E43-201E-43F6-B50B-B92E9D2A66BC")!

        let first = TripSyncMetadata(persistence: PersistenceStore(directory: directory))
        first.markDirty(tripId, at: Date(timeIntervalSince1970: 1_780_000_000))
        first.markParentsEstablished([tripId])

        let relaunched = TripSyncMetadata(persistence: PersistenceStore(directory: directory))
        XCTAssertTrue(relaunched.isParentEstablished(tripId))
        XCTAssertNotNil(relaunched.pendingUpserts[tripId], "queued finalisation survives the upgrade")
    }

    func testDeletedTripDropsItsEstablishedParentClaim() {
        let metadata = TripSyncMetadata(persistence: PersistenceStore(directory: makeDirectory()))
        let tripId = UUID(uuidString: "C4DB2285-F69E-49DC-BD9F-521CF92CE207")!
        metadata.markParentsEstablished([tripId])
        metadata.markDeleted(tripId, at: Date())
        XCTAssertFalse(metadata.isParentEstablished(tripId))
    }

    // MARK: - Finalisation diagnostics

    func testFinalisationDiagnosticReportsHeldStateWithoutContent() async throws {
        let tripId = UUID()
        let sprayRecordId = UUID()
        let endTime = Date(timeIntervalSince1970: 1_780_000_000)
        let harness = makeHarness(trips: [endedTrip(id: tripId, endTime: endTime)])
        try harness.actuals.saveLocally(
            try makeActual(tripId: tripId, sprayRecordId: sprayRecordId, tankNumber: 1, sessionId: "tank-1")
        )
        harness.metadata.markDirty(tripId, at: Date())
        try await harness.service.pushLocalTrips(vineyardId: vineyardId)

        let diagnostic = harness.service.finalisationDiagnostic(
            for: tripId,
            pendingActualCount: harness.actuals.pendingCount(tripId: tripId)
        )
        XCTAssertEqual(diagnostic.tripId, tripId)
        XCTAssertEqual(diagnostic.pendingActualCount, 1)
        XCTAssertTrue(diagnostic.isPhase5Held)
        XCTAssertTrue(diagnostic.parentEstablished)
        XCTAssertTrue(diagnostic.isPendingUpsert)
        XCTAssertFalse(diagnostic.isActive)
        XCTAssertTrue(diagnostic.hasEndTime)
        XCTAssertTrue(diagnostic.summary.contains("pendingActuals=1"))
    }
}
