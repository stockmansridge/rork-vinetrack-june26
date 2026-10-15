import Foundation
import XCTest
@testable import VineTrack

final class SyncCompatibilityTests: XCTestCase {
    private let vineyard = UUID(uuidString: "71000000-0000-4000-8000-000000000001")!

    private func row(_ buttons: String, type: String = "growth_buttons") throws -> BackendButtonConfig {
        let data = Data("""
        {"id":"71000000-0000-4000-8000-000000000002","vineyard_id":"\(vineyard)","config_type":"\(type)","config_data":\(buttons),"sync_version":3}
        """.utf8)
        return try JSONDecoder().decode(BackendButtonConfig.self, from: data)
    }

    func testLegacyGrowthWithoutIDsPreservesValuesAndStableIdentityAcrossDecodes() throws {
        let payload = """
        [{"name":"Custom stage","color":"darkgreen","index":0,"mode":"Growth","isGrowthStageButton":true}]
        """
        let first = try row(payload)
        let second = try row(payload)
        XCTAssertEqual(first.configData, second.configData)
        XCTAssertEqual(first.configData.first?.vineyardId, vineyard)
        XCTAssertEqual(first.configData.first?.name, "Custom stage")
        XCTAssertEqual(first.configData.first?.color, "darkgreen")
        XCTAssertEqual(first.configData.first?.isGrowthStageButton, true)
        let reloaded = try JSONDecoder().decode(BackendButtonConfig.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(first.configData, reloaded.configData)
    }

    func testCompleteButtonIDsNeverChangeAndMalformedValuesNeverBecomeDefaults() throws {
        let payload = """
        [{"id":"71000000-0000-4000-8000-000000000003","vineyardId":"\(vineyard)","name":"Repairs custom","color":"orange","index":3,"mode":"Repairs","isGrowthStageButton":false}]
        """
        XCTAssertEqual(try row(payload, type: "repair_buttons").configData.first?.id,
                       UUID(uuidString: "71000000-0000-4000-8000-000000000003"))
        XCTAssertThrowsError(try row(payload.replacingOccurrences(of: "\"name\":\"Repairs custom\",", with: "")))
        XCTAssertThrowsError(try row(payload.replacingOccurrences(of: "71000000-0000-4000-8000-000000000003", with: "invalid")))
    }

    func testExactServerTimestampTokenRetainsMicroseconds() throws {
        let data = Data("""
        {"id":"71000000-0000-4000-8000-000000000002","vineyard_id":"\(vineyard)","config_type":"repair_buttons","config_data":[],"updated_at":"2026-10-15T10:00:00.123456+00:00","sync_version":1}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return try XCTUnwrap(formatter.date(from: c.decode(String.self)))
        }
        let result = try decoder.decode(BackendButtonConfig.self, from: data)
        XCTAssertEqual(result.updatedAtToken, "2026-10-15T10:00:00.123456+00:00")
    }

    func testTwoSnakeCaseSessionsWithFractionalAndOffsetDatesAndCacheRoundTrip() throws {
        // Synthetic shape reproduction. The two recorded production objects were not supplied.
        let data = Data("""
        [{"id":"71000000-0000-4000-8000-000000000011","tank_number":1,"start_time":"2026-10-14T08:00:00.123Z","end_time":"2026-10-14T09:00:00Z","paths_covered":[0.5,1.5],"start_row":0.5,"end_row":1.5,"fill_start_time":null},
         {"id":"71000000-0000-4000-8000-000000000012","tank_number":2,"start_time":"2026-10-14T20:00:00+11:00","end_time":"2026-10-14T10:00:00.456Z","paths_covered":[2.5,3.5],"fill_start_time":"2026-10-14T08:55:00Z","fill_end_time":"2026-10-14T08:59:00Z"}]
        """.utf8)
        let sessions = try JSONDecoder().decode([TankSession].self, from: data)
        XCTAssertEqual(sessions.map(\.tankNumber), [1, 2])
        XCTAssertEqual(sessions.map(\.pathsCovered), [[0.5, 1.5], [2.5, 3.5]])
        XCTAssertEqual(sessions[0].endTime, sessions[1].startTime)
        XCTAssertEqual(sessions[1].fillDuration, 240)
        let tripPayload: [String: Any] = [
            "id": "71000000-0000-4000-8000-000000000099", "vineyard_id": vineyard.uuidString,
            "is_active": false, "end_time": 100,
            "tank_sessions": try JSONSerialization.jsonObject(with: data),
            "completed_paths": (0..<109).map { Double($0) + 0.5 },
            "path_points": (0..<4584).map { ["latitude": -33.0 + Double($0) * 0.000001, "longitude": 149.0] }
        ]
        let backend = try JSONDecoder().decode(BackendTrip.self, from: JSONSerialization.data(withJSONObject: tripPayload))
        let mapped = backend.toTrip()
        XCTAssertFalse(mapped.isActive)
        XCTAssertEqual(mapped.pathPoints.count, 4584)
        XCTAssertEqual(mapped.completedPaths.count, 109)
        XCTAssertEqual(mapped.tankSessions, sessions)
        XCTAssertEqual(try JSONDecoder().decode([TankSession].self, from: JSONEncoder().encode(sessions)), sessions)
        let iso = JSONEncoder(); iso.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try JSONDecoder().decode([TankSession].self, from: iso.encode(sessions)).map(\.pathsCovered), sessions.map(\.pathsCovered))
    }

    func testInvalidTankDatesAndConflictingAliasesFailWithoutDefaulting() {
        for extra in ["\"start_time\":\"bad\"", "\"start_time\":\"2026-10-14T08:00:00Z\",\"tankNumber\":9"] {
            let data = Data("{\"id\":\"71000000-0000-4000-8000-000000000011\",\"tank_number\":1,\(extra)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(TankSession.self, from: data))
        }
    }

    @MainActor func testDirtyMetadataRestartAndOldAcknowledgementPreserveNewEdit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ButtonConfigSyncMetadata(persistence: PersistenceStore(directory: directory))
        let old = Date(timeIntervalSince1970: 100), new = Date(timeIntervalSince1970: 200)
        first.markDirty(vineyardId: vineyard, type: .repairButtons, at: old)
        let restarted = ButtonConfigSyncMetadata(persistence: PersistenceStore(directory: directory))
        XCTAssertEqual(restarted.pendingTimestamp(vineyardId: vineyard, type: .repairButtons), old)
        restarted.markDirty(vineyardId: vineyard, type: .repairButtons, at: new)
        restarted.clearDirty(vineyardId: vineyard, type: .repairButtons, matching: old)
        XCTAssertEqual(restarted.pendingTimestamp(vineyardId: vineyard, type: .repairButtons), new)
    }

    @MainActor func testNewerRemoteConfigurationHoldsDirtyEditAndFailedDiskAckCannotClearIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let p = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: p); store.selectedVineyardId = vineyard
        let metadata = ButtonConfigSyncMetadata(persistence: p)
        let data = Data("""
        {"id":"71000000-0000-4000-8000-000000000002","vineyard_id":"\(vineyard)","config_type":"repair_buttons","config_data":[],"client_updated_at":1000}
        """.utf8)
        let repo = ButtonProbe(remote: try JSONDecoder().decode(BackendButtonConfig.self, from: data))
        let service = ButtonConfigSyncService(repository: repo, metadata: metadata, isBackendConfigured: { true })
        let auth = NewBackendAuthService(); service.configure(store: store, auth: auth)
        store.repairButtons = [ButtonConfig(vineyardId: vineyard, name: "Custom", color: "red", index: 0, mode: .repairs)]
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        metadata.markDirty(vineyardId: vineyard, type: .repairButtons, at: timestamp)
        do { try await service.pushLocalButtonConfig(vineyardId: vineyard); XCTFail("Remote conflict overwritten") } catch {}
        XCTAssertEqual(metadata.pendingTimestamp(vineyardId: vineyard, type: .repairButtons), timestamp)
        p.durableSaveFailureForTesting = { _ in NSError(domain: "SyntheticDisk", code: 1) }
        metadata.clearDirty(vineyardId: vineyard, type: .repairButtons, matching: timestamp)
        XCTAssertEqual(metadata.pendingTimestamp(vineyardId: vineyard, type: .repairButtons), timestamp)
        XCTAssertNotNil(metadata.persistenceError)
    }

    @MainActor func testNewEditDuringAcknowledgementRemainsDirty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let p = PersistenceStore(directory: directory), store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyard
        let metadata = ButtonConfigSyncMetadata(persistence: p), auth = NewBackendAuthService()
        let repo = ButtonProbe(remote: try row("[]", type: "repair_buttons"))
        let service = ButtonConfigSyncService(repository: repo, metadata: metadata, isBackendConfigured: { true })
        service.configure(store: store, auth: auth)
        let old = Date(timeIntervalSince1970: 100), new = Date(timeIntervalSince1970: 200)
        store.repairButtons = [ButtonConfig(vineyardId: vineyard, name: "Custom", color: "orange", index: 0, mode: .repairs)]
        metadata.markDirty(vineyardId: vineyard, type: .repairButtons, at: old)
        repo.onSave = {
            store.repairButtons[0].color = "red"
            metadata.markDirty(vineyardId: self.vineyard, type: .repairButtons, at: new)
        }
        try await service.pushLocalButtonConfig(vineyardId: vineyard)
        XCTAssertEqual(store.repairButtons[0].color, "red")
        XCTAssertEqual(metadata.pendingTimestamp(vineyardId: vineyard, type: .repairButtons), new)
    }

    @MainActor func testDirtyRepairsSurvivePullAndOnlyExactAckClearsThenOtherDeviceReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let p = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: p)
        store.selectedVineyardId = vineyard
        let metadata = ButtonConfigSyncMetadata(persistence: p)
        let remote = try row("[]", type: "repair_buttons")
        let repo = ButtonProbe(remote: remote)
        let auth = NewBackendAuthService()
        let service = ButtonConfigSyncService(repository: repo, metadata: metadata, isBackendConfigured: { true })
        service.configure(store: store, auth: auth)
        let local = ButtonConfig(vineyardId: vineyard, name: "Irrigation", color: "orange", index: 0, mode: .repairs)
        store.repairButtons = [local]
        metadata.markDirty(vineyardId: vineyard, type: .repairButtons, at: Date())
        try await service.pullRemoteButtonConfig(vineyardId: vineyard)
        XCTAssertEqual(store.repairButtons, [local])
        repo.setMismatch(true)
        await service.sync(vineyardId: vineyard)
        guard case .failure = service.syncStatus else { return XCTFail("Mismatched acknowledgement reported full sync") }
        XCTAssertNil(service.lastSyncDate)
        XCTAssertNotNil(metadata.pendingTimestamp(vineyardId: vineyard, type: .repairButtons))
        repo.setMismatch(false)
        await service.sync(vineyardId: vineyard)
        XCTAssertEqual(service.syncStatus, .success)
        XCTAssertNotNil(service.lastSyncDate)
        XCTAssertNil(service.errorMessage)
        XCTAssertNil(metadata.pendingTimestamp(vineyardId: vineyard, type: .repairButtons))
        let other = MigratedDataStore(persistence: PersistenceStore(directory: directory.appendingPathComponent("other")))
        other.selectedVineyardId = vineyard
        let reader = ButtonConfigSyncService(repository: repo, metadata: ButtonConfigSyncMetadata(persistence: PersistenceStore(directory: directory.appendingPathComponent("other"))))
        let otherAuth = NewBackendAuthService()
        reader.configure(store: other, auth: otherAuth)
        try await reader.pullRemoteButtonConfig(vineyardId: vineyard)
        XCTAssertEqual(other.repairButtons, [local])
    }
}

@MainActor private final class ButtonProbe: ButtonConfigSyncRepositoryProtocol {
    var remote: BackendButtonConfig
    var mismatch: Bool = false
    var onSave: (() -> Void)?
    init(remote: BackendButtonConfig) { self.remote = remote }
    func setMismatch(_ value: Bool) { mismatch = value }
    func fetchButtonConfigs(vineyardId: UUID) async throws -> [BackendButtonConfig] { [remote] }
    func upsertButtonConfig(_ config: BackendButtonConfigUpsert) async throws { XCTFail("Unconditional upsert used") }
    func upsertButtonConfigs(_ configs: [BackendButtonConfigUpsert]) async throws { XCTFail("Unconditional upsert used") }
    func saveButtonConfig(_ config: BackendButtonConfigUpsert, replacing expected: BackendButtonConfig?) async throws -> BackendButtonConfig {
        if mismatch { return remote }
        onSave?()
        let data = try JSONEncoder().encode(config)
        remote = try JSONDecoder().decode(BackendButtonConfig.self, from: data)
        return remote
    }
}
