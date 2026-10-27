import Foundation
import XCTest
@testable import VineTrack

final class PreparedVineyardSelectionTests: XCTestCase {
    @MainActor func testDeferredRepairsIgnoredAfterNewSelectionRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let a = Vineyard(name: "A"), b = Vineyard(name: "B")
        store.vineyards = [a, b]
        var repairStages: [String] = []
        store.preparedSelectionMeasurement = { stage, _ in
            if stage.hasPrefix("deferred-") { repairStages.append(stage) }
        }
        await store.prepareAndSelectVineyard(a)
        let firstRepairs = store.deferredSelectionRepairs
        // No suspension: invalidate the queued A repairs before their yield resumes.
        store.selectVineyard(b, deferSelectionRepairs: true)
        await firstRepairs?.value
        XCTAssertEqual(store.selectedVineyardId, b.id)
        XCTAssertTrue(repairStages.isEmpty)
    }

    @MainActor func testDeferredRepairsFenceAccountIncarnation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let suite = "PreparedRepairs.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let authority = VineyardWriteAuthority(defaults: defaults)
        let owner = UUID()
        authority.bind(userId: owner)
        store.operationalWriteAuthority = authority
        store.currentUserIdProvider = { owner }
        var ran = false
        store.preparedSelectionMeasurement = { stage, _ in if stage.hasPrefix("deferred-") { ran = true } }
        await store.prepareAndSelectVineyard(Vineyard(name: "A"))
        let repairs = store.deferredSelectionRepairs
        authority.bind(userId: nil)
        authority.bind(userId: owner)
        await repairs?.value
        XCTAssertFalse(ran)
    }

    @MainActor func testCurrentDeferredRepairsExecuteBothStagesWithinFrameBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        var stages: [String: Double] = [:]
        store.preparedSelectionMeasurement = { stage, duration in stages[stage] = duration }
        await store.prepareAndSelectVineyard(Vineyard(name: "A"))
        await store.deferredSelectionRepairs?.value
        for name in ["deferred-legacy-spray-recovery", "deferred-variety-canonicalization"] {
            let value = try XCTUnwrap(stages[name])
            XCTAssertLessThan(value, 16)
        }
    }

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
