import Foundation
import XCTest
@testable import VineTrack

final class TripPullResponsivenessTests: XCTestCase {
    @MainActor func testPreparedTripMemoStillRejectsChangedAndCorruptBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceStore(directory: root)
        let otherWriter = PersistenceStore(directory: root)
        let vineyard = UUID()
        let trip = Trip(vineyardId: vineyard, startTime: Date(timeIntervalSince1970: 1_700_000_000))
        var measurements: [PersistenceMeasurement] = []
        persistence.onPersistenceMeasurementForTesting = { measurements.append($0) }
        try persistence.saveOrThrow([trip], key: TripRepository.storageKey)
        await persistence.prepareDecode([Trip].self, key: TripRepository.storageKey)
        let exact: [Trip]? = persistence.load(key: TripRepository.storageKey)
        XCTAssertEqual(exact, [trip])
        XCTAssertTrue(measurements.last?.reusedDecode == true)
        var changed = trip
        changed.endTime = Date(timeIntervalSince1970: 1_700_000_000)
        try otherWriter.saveOrThrow([changed], key: TripRepository.storageKey)
        let reloaded: [Trip]? = persistence.load(key: TripRepository.storageKey)
        XCTAssertEqual(reloaded, [changed])
        XCTAssertFalse(measurements.last?.reusedDecode ?? true)
        try Data("not JSON".utf8).write(to: root.appendingPathComponent(TripRepository.storageKey + ".json"), options: .atomic)
        let corrupt: [Trip]? = persistence.load(key: TripRepository.storageKey)
        XCTAssertNil(corrupt)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(TripRepository.storageKey + ".json")), Data("not JSON".utf8))
    }

    @MainActor func testResponsiveRowsRejectSelectionRoundTripBetweenRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let a = Vineyard(name: "A"), b = Vineyard(name: "B")
        store.vineyards = [a, b]
        store.selectedVineyardId = a.id
        let check = store.remoteApplicationCurrentCheck()
        var applied: [Int] = []
        do {
            try await ResponsiveRemoteApplication.forEach([1, 2, 3], isCurrent: check) { row in
                applied.append(row)
                store.applyDefaultVineyardSelection(defaultId: b.id)
                store.applyDefaultVineyardSelection(defaultId: a.id)
            }
            XCTFail("Superseded application must stop")
        } catch is CancellationError {}
        XCTAssertEqual(applied, [1])
        XCTAssertEqual(store.selectedVineyardId, a.id)
    }

    @MainActor func testResponsiveRowsRejectOriginalAccountIncarnation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let suite = "TripPullResponsivenessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let authority = VineyardWriteAuthority(defaults: defaults)
        let owner = UUID()
        authority.bind(userId: owner)
        store.operationalWriteAuthority = authority
        store.currentUserIdProvider = { owner }
        let check = store.remoteApplicationCurrentCheck()
        var applied = 0
        do {
            try await ResponsiveRemoteApplication.forEach([1, 2], isCurrent: check) { _ in
                applied += 1
                authority.bind(userId: nil)
                authority.bind(userId: owner)
            }
            XCTFail("Account round-trip must revoke the application")
        } catch is CancellationError {}
        XCTAssertEqual(applied, 1)
    }
}
