import Foundation
import XCTest
@testable import VineTrack

final class PreparedVineyardSelectionTests: XCTestCase {
    @MainActor func testSupersededPreparationCannotSelectOrPublishOldVineyard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let a = Vineyard(name: "Synthetic A")
        let b = Vineyard(name: "Synthetic B")
        store.vineyards = [a, b]
        let first = Task { await store.prepareAndSelectVineyard(a) }
        await Task.yield()
        let second = Task { await store.prepareAndSelectVineyard(b) }
        await first.value
        await second.value
        XCTAssertEqual(store.selectedVineyardId, b.id)
        XCTAssertNil(store.preparingVineyard)
        XCTAssertTrue(store.pins.allSatisfy { $0.vineyardId == b.id })
    }

    @MainActor func testDefaultSelectionRoundTripInvalidatesOlderPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let a = Vineyard(name: "Synthetic A")
        let b = Vineyard(name: "Synthetic B")
        let target = Vineyard(name: "Superseded target")
        store.vineyards = [a, b, target]
        store.applyDefaultVineyardSelection(defaultId: a.id)
        var committed = false
        store.preparedSelectionMeasurement = { stage, _ in
            if stage == "selection-state-acknowledgement" {
                // Execute at the request boundary, before the worker can finish.
                store.applyDefaultVineyardSelection(defaultId: b.id)
                store.applyDefaultVineyardSelection(defaultId: a.id)
            }
            if stage == "atomic-selection-commit" { committed = true }
        }
        defer { store.preparedSelectionMeasurement = nil }
        await store.prepareAndSelectVineyard(target)
        XCTAssertEqual(store.selectedVineyardId, a.id)
        XCTAssertNil(store.preparingVineyard)
        XCTAssertFalse(committed)
    }

    @MainActor func testClearingStoreInvalidatesSuspendedSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let vineyard = Vineyard(name: "Synthetic")
        let selection = Task { await store.prepareAndSelectVineyard(vineyard) }
        await Task.yield()
        store.clearInMemoryState()
        await selection.value
        XCTAssertNil(store.selectedVineyardId)
        XCTAssertNil(store.preparingVineyard)
        XCTAssertTrue(store.pins.isEmpty)
    }
}
