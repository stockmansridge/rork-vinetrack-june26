import Foundation
import CryptoKit
import XCTest
import zlib
@testable import VineTrack

/// Private inputs are downloaded into test-process memory. No production samples
/// are bundled in the app or retained in this repository. Supply a temporary
/// PrivateRecordedFixtureLocation.txt resource containing the private ZIP URL.
@MainActor final class RecordedSyncFixtureTests: XCTestCase {
    private func fixtures() async throws -> [String: Data] {
        guard let locator = Bundle(for: Self.self).url(forResource: "PrivateRecordedFixtureLocation", withExtension: "txt") else {
            throw XCTSkip("Private recorded fixture locator not supplied")
        }
        let source = try String(contentsOf: locator, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try XCTUnwrap(URL(string: source))
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (archive, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(Self.sha(archive) == "ffb05870f11efd94336ccb78608001291afa15c694df60d327f6b8d0ca8dd833", "Original ZIP checksum changed")
        let entries = try Self.inflateZIP(archive)
        let tanks = try XCTUnwrap(entries.first { $0.key.hasSuffix("tank_sessions_recorded.json") }?.value)
        let growth = try XCTUnwrap(entries.first { $0.key.hasSuffix("growth_buttons_legacy_recorded.json") }?.value)
        XCTAssertTrue(Self.sha(tanks) == "2af3729284692229c992f10e529232c2f78cfa7376b304a951894921ff436cfe", "Original tank bytes changed")
        XCTAssertTrue(Self.sha(growth) == "36339f0b264b8059576ef32ddb57184a1d94f2ba716f131a9a3a8f1fcbf4c960", "Original Growth bytes changed")
        let provenance = try XCTUnwrap(entries.first { $0.key.hasSuffix("fixture-provenance.txt") }?.value)
        return ["tanks": tanks, "growth": growth, "provenance": provenance]
    }

    func testRecordedTankSessionsPreserveEveryFieldThroughProductionDecoders() async throws {
        let input = try await fixtures()
        let raw = try XCTUnwrap(input["tanks"])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
        let sessions = try JSONDecoder().decode([TankSession].self, from: raw)
        XCTAssertEqual(sessions.count, 2)
        for (session, object) in zip(sessions, original) {
            XCTAssertTrue(session.id == UUID(uuidString: try XCTUnwrap(object["id"] as? String)), "Session identity changed")
            XCTAssertTrue(session.tankNumber == object["tank_number"] as? Int, "Tank number changed")
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let start = try XCTUnwrap(iso.date(from: try XCTUnwrap(object["start_time"] as? String)))
            let end = try XCTUnwrap(iso.date(from: try XCTUnwrap(object["end_time"] as? String)))
            XCTAssertTrue(abs(session.startTime.timeIntervalSince(start)) < 0.000001, "Start date changed")
            XCTAssertTrue(abs(try XCTUnwrap(session.endTime).timeIntervalSince(end)) < 0.000001, "End date changed")
            XCTAssertTrue(session.startRow == object["start_row"] as? Double, "Start row changed")
            XCTAssertTrue(session.endRow == object["end_row"] as? Double, "End row changed")
            XCTAssertTrue(session.pathsCovered == object["paths_covered"] as? [Double], "Recorded coverage changed")
        }
        // Only the enclosing transport shell is synthetic; raw session bytes are concatenated untouched.
        let prefix = Data("{\"id\":\"71000000-0000-4000-8000-000000000099\",\"vineyard_id\":\"71000000-0000-4000-8000-000000000001\",\"is_active\":false,\"tank_sessions\":".utf8)
        let backend = try JSONDecoder().decode(BackendTrip.self, from: prefix + raw + Data("}".utf8))
        XCTAssertTrue(backend.toTrip().tankSessions == sessions, "Backend Trip mapping changed sessions")
        XCTAssertTrue(try JSONDecoder().decode([TankSession].self, from: JSONEncoder().encode(sessions)) == sessions, "Cache round-trip changed sessions")
        XCTAssertTrue(Self.sha(raw) == "2af3729284692229c992f10e529232c2f78cfa7376b304a951894921ff436cfe")
    }

    func testEightRecordedGrowthButtonsPreserveValuesAndDeterministicIdentities() async throws {
        let input = try await fixtures()
        let raw = try XCTUnwrap(input["growth"])
        let originals = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
        let scope = try Self.vineyard(input)
        let first = try Self.growthRow(raw, vineyard: scope)
        let second = try Self.growthRow(raw, vineyard: scope)
        XCTAssertEqual(first.configData.count, 8)
        XCTAssertTrue(first.configData == second.configData, "Repeated decoding changed identities or values")
        XCTAssertEqual(Set(first.configData.map(\.id)).count, 8)
        for (button, object) in zip(first.configData, originals) {
            XCTAssertNil(object["id"])
            XCTAssertNil(object["vineyardId"])
            XCTAssertTrue(button.name == object["name"] as? String, "Recorded name changed")
            XCTAssertTrue(button.color == object["color"] as? String, "Recorded colour changed")
            XCTAssertTrue(button.index == object["index"] as? Int, "Recorded position changed")
            XCTAssertTrue(button.mode.rawValue == object["mode"] as? String, "Recorded mode changed")
            XCTAssertTrue(button.isGrowthStageButton == object["isGrowthStageButton"] as? Bool, "Growth flag changed")
            XCTAssertTrue(button.vineyardId == first.vineyardId, "Enclosing scope lost")
        }
        let cached = try JSONDecoder().decode(BackendButtonConfig.self, from: JSONEncoder().encode(first))
        XCTAssertTrue(cached.configData == first.configData, "Cache changed identities or values")
        XCTAssertTrue(Self.sha(raw) == "36339f0b264b8059576ef32ddb57184a1d94f2ba716f131a9a3a8f1fcbf4c960")
    }

    func testRecordedLegacyGrowthDoesNotBlockDirtyRepairsVerifiedAcknowledgement() async throws {
        let input = try await fixtures()
        let raw = try XCTUnwrap(input["growth"])
        let growth = try Self.growthRow(raw, vineyard: Self.vineyard(input))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = growth.vineyardId
        let metadata = ButtonConfigSyncMetadata(persistence: persistence)
        let auth = NewBackendAuthService()
        let repo = RecordedButtonTransport(growthBytes: raw, vineyard: growth.vineyardId)
        let service = ButtonConfigSyncService(repository: repo, metadata: metadata, isBackendConfigured: { true })
        service.configure(store: store, auth: auth)
        let repair = ButtonConfig(vineyardId: growth.vineyardId, name: "Synthetic Repairs edit", color: "orange", index: 0, mode: .repairs)
        store.repairButtons = [repair]
        metadata.markDirty(vineyardId: growth.vineyardId, type: .repairButtons, at: Date())
        await service.sync(vineyardId: growth.vineyardId)
        guard case .failure = service.syncStatus else { return XCTFail("Unverified acknowledgement reported success") }
        XCTAssertNotNil(metadata.pendingTimestamp(vineyardId: growth.vineyardId, type: .repairButtons))
        XCTAssertNil(service.lastSyncDate)
        repo.returnMismatch = false
        await service.sync(vineyardId: growth.vineyardId)
        XCTAssertEqual(service.syncStatus, .success)
        XCTAssertNotNil(service.lastSyncDate)
        XCTAssertNil(metadata.pendingTimestamp(vineyardId: growth.vineyardId, type: .repairButtons))
        XCTAssertTrue(store.repairButtons == [repair], "Dirty Repairs value was overwritten")
        XCTAssertTrue(store.growthButtons == growth.configData, "Original Growth values changed")
        XCTAssertEqual(repo.savedTypes, ["repair_buttons", "repair_buttons"])
        XCTAssertTrue(repo.acknowledgedRepairs?.configData == [repair], "Verified response lost Repairs edit")
        XCTAssertTrue(Self.sha(raw) == "36339f0b264b8059576ef32ddb57184a1d94f2ba716f131a9a3a8f1fcbf4c960")
    }

    private static func vineyard(_ input: [String: Data]) throws -> UUID {
        let provenance = String(decoding: try XCTUnwrap(input["provenance"]), as: UTF8.self)
        let line = try XCTUnwrap(provenance.components(separatedBy: .newlines).first { $0.hasPrefix("Vineyard ID:") })
        let text = line.dropFirst("Vineyard ID:".count).trimmingCharacters(in: .whitespaces)
        return try XCTUnwrap(UUID(uuidString: String(text.prefix(36))))
    }

    fileprivate static func growthRow(_ raw: Data, vineyard: UUID) throws -> BackendButtonConfig {
        let prefix = Data("{\"id\":\"71000000-0000-4000-8000-000000000002\",\"vineyard_id\":\"\(vineyard.uuidString)\",\"config_type\":\"growth_buttons\",\"config_data\":".utf8)
        return try JSONDecoder().decode(BackendButtonConfig.self, from: prefix + raw + Data("}".utf8))
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Bounded ZIP reader for this small private archive, never extracting files.
    /// Validates entry method/size and SHA-256 of the untouched inflated bytes.
    private static func inflateZIP(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func uint(_ p: Int, _ length: Int) throws -> Int {
            guard p >= 0, p + length <= bytes.count else { throw NSError(domain: "FixtureZIP", code: 1) }
            return (0..<length).reduce(0) { $0 | Int(bytes[p + $1]) << (8 * $1) }
        }
        var offset: Int = 0
        var entries: [String: Data] = [:]
        while try uint(offset, 4) == 0x04034b50 {
            let flags = try uint(offset + 6, 2), method = try uint(offset + 8, 2)
            let compressed = try uint(offset + 18, 4), expanded = try uint(offset + 22, 4)
            let nameLength = try uint(offset + 26, 2), extraLength = try uint(offset + 28, 2)
            let start = offset + 30 + nameLength + extraLength
            guard flags & 9 == 0, method == 8, expanded > 0, expanded <= 16384,
                  start <= bytes.count, compressed <= bytes.count - start else { throw NSError(domain: "FixtureZIP", code: 2) }
            let name = String(decoding: bytes[(offset + 30)..<(offset + 30 + nameLength)], as: UTF8.self)
            var input = Array(bytes[start..<(start + compressed)])
            var output = [UInt8](repeating: 0, count: expanded)
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw NSError(domain: "FixtureZIP", code: 3) }
            defer { inflateEnd(&stream) }
            let result = input.withUnsafeMutableBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    stream.next_in = source.baseAddress
                    stream.avail_in = uInt(compressed)
                    stream.next_out = destination.baseAddress
                    stream.avail_out = uInt(expanded)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard result == Z_STREAM_END, stream.total_out == expanded else { throw NSError(domain: "FixtureZIP", code: 4) }
            entries[name] = Data(output)
            offset = start + compressed
        }
        return entries
    }
}

@MainActor private final class RecordedButtonTransport: ButtonConfigSyncRepositoryProtocol {
    let growthBytes: Data
    let vineyard: UUID
    var acknowledgedRepairs: BackendButtonConfig?
    var returnMismatch: Bool = true
    var savedTypes: [String] = []
    init(growthBytes: Data, vineyard: UUID) { self.growthBytes = growthBytes; self.vineyard = vineyard }
    func fetchButtonConfigs(vineyardId: UUID) async throws -> [BackendButtonConfig] {
        // Execute the production row decoder on the original array every fetch.
        let growth = try RecordedSyncFixtureTests.growthRow(growthBytes, vineyard: vineyard)
        return [growth] + (acknowledgedRepairs.map { [$0] } ?? [])
    }
    func saveButtonConfig(_ config: BackendButtonConfigUpsert, replacing expected: BackendButtonConfig?) async throws -> BackendButtonConfig {
        savedTypes.append(config.configType)
        if returnMismatch { return try RecordedSyncFixtureTests.growthRow(growthBytes, vineyard: vineyard) }
        let response = try JSONDecoder().decode(BackendButtonConfig.self, from: JSONEncoder().encode(config))
        acknowledgedRepairs = response
        return response
    }
    func upsertButtonConfig(_ config: BackendButtonConfigUpsert) async throws { XCTFail("Unconditional upsert used") }
    func upsertButtonConfigs(_ configs: [BackendButtonConfigUpsert]) async throws { XCTFail("Unconditional upsert used") }
}
