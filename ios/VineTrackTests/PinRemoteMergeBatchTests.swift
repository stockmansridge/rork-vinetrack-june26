import Observation
import Synchronization
import XCTest
@testable import VineTrack

private final class ObservationCounter: Sendable {
    private let value = Mutex(0)

    func increment() {
        value.withLock { count in
            count += 1
        }
    }

    var count: Int {
        value.withLock { $0 }
    }
}

@MainActor
final class PinRemoteMergeBatchTests: XCTestCase {
    func testMixed215RecordBatchRetainsOtherVineyardAndPublishesOnce() throws {
        let fixture = try makeFixture()
        let other = pin(vineyardId: fixture.otherVineyardId, name: "Other")
        let existing = pin(vineyardId: fixture.vineyardId, name: "Existing")
        fixture.persistence.save([other, existing], key: PinRepository.storageKey)
        fixture.store.pins = [existing]

        let incoming = (0..<215).map { pin(vineyardId: fixture.vineyardId, name: "Remote \($0)") }
        let deletedIds = Set(incoming.prefix(15).map(\.id))
        let publicationCount = ObservationCounter()
        withObservationTracking {
            _ = fixture.store.pins
        } onChange: {
            publicationCount.increment()
        }

        try fixture.store.applyRemotePinBatch(
            vineyardId: fixture.vineyardId,
            cacheSnapshot: fixture.store.pinRepo.loadAllForDurableUpdate(),
            upserts: Array(incoming.dropFirst(15)),
            deleting: deletedIds
        )

        let persisted = try fixture.store.pinRepo.loadAllForDurableUpdate()
        XCTAssertEqual(persisted.filter { $0.vineyardId == fixture.vineyardId }.count, 201)
        XCTAssertTrue(persisted.contains { $0.id == other.id })
        XCTAssertEqual(publicationCount.count, 1)
    }

    func testFailedWriteDoesNotPublishAndRetryCommits() throws {
        let fixture = try makeFixture()
        let local = pin(vineyardId: fixture.vineyardId, name: "Local")
        fixture.persistence.save([local], key: PinRepository.storageKey)
        fixture.store.pins = [local]
        let remote = pin(vineyardId: fixture.vineyardId, name: "Remote")
        var shouldFail = true
        fixture.persistence.durableSaveFailureForTesting = { key in
            guard shouldFail, key == PinRepository.storageKey else { return nil }
            return CocoaError(.fileWriteUnknown)
        }

        XCTAssertThrowsError(try fixture.store.applyRemotePinBatch(
            vineyardId: fixture.vineyardId,
            cacheSnapshot: fixture.store.pinRepo.loadAllForDurableUpdate(),
            upserts: [remote],
            deleting: []
        ))
        XCTAssertEqual(fixture.store.pins.map(\.id), [local.id])

        shouldFail = false
        try fixture.store.applyRemotePinBatch(
            vineyardId: fixture.vineyardId,
            cacheSnapshot: fixture.store.pinRepo.loadAllForDurableUpdate(),
            upserts: [remote],
            deleting: []
        )
        XCTAssertEqual(Set(fixture.store.pins.map(\.id)), Set([local.id, remote.id]))
    }

    func testVineyardSwitchPersistsTargetWithoutReplacingVisiblePins() throws {
        let fixture = try makeFixture()
        let targetLocal = pin(vineyardId: fixture.vineyardId, name: "Target local")
        let visible = pin(vineyardId: fixture.otherVineyardId, name: "Visible")
        fixture.persistence.save([targetLocal, visible], key: PinRepository.storageKey)
        fixture.store.selectedVineyardId = fixture.otherVineyardId
        fixture.store.pins = [visible]
        let remote = pin(vineyardId: fixture.vineyardId, name: "Target remote")

        try fixture.store.applyRemotePinBatch(
            vineyardId: fixture.vineyardId,
            cacheSnapshot: fixture.store.pinRepo.loadAllForDurableUpdate(),
            upserts: [remote],
            deleting: []
        )

        XCTAssertEqual(fixture.store.pins.map(\.id), [visible.id])
        let persisted = try fixture.store.pinRepo.loadAllForDurableUpdate()
        XCTAssertTrue(persisted.contains { $0.id == targetLocal.id })
        XCTAssertTrue(persisted.contains { $0.id == remote.id })
        XCTAssertTrue(persisted.contains { $0.id == visible.id })
    }

    private func makeFixture() throws -> (store: MigratedDataStore, persistence: PersistenceStore, vineyardId: UUID, otherVineyardId: UUID) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyardId = UUID()
        store.selectedVineyardId = vineyardId
        return (store, persistence, vineyardId, UUID())
    }

    private func pin(vineyardId: UUID, name: String) -> VinePin {
        VinePin(
            id: UUID(), vineyardId: vineyardId, latitude: -33.0, longitude: 149.0,
            heading: nil, buttonName: name, buttonColor: "red", side: nil, mode: .repairs
        )
    }
}
