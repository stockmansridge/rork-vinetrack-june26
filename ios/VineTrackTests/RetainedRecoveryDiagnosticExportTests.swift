import Foundation
import CryptoKit
import XCTest
@testable import VineTrack

final class RetainedRecoveryDiagnosticExportTests: XCTestCase {
    func testExportRetainsMalformedOriginalsQueuesAndReceiptsByteForByteWithoutSourceWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        let support = root.appendingPathComponent("Support")
        let dataRoot = docs.appendingPathComponent("VineTrackData")
        let occurrence = support.appendingPathComponent("TripOccurrenceJournals/owner/vineyard")
        let planning = support.appendingPathComponent("SprayPlanningAttempts-v1/actor/vineyard/incarnation")
        for directory in [dataRoot, occurrence, planning] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let originals: [URL: Data] = [
            dataRoot.appendingPathComponent("vinetrack_trips.json"): Data("{malformed retained trip".utf8),
            dataRoot.appendingPathComponent("vinetrack_spray_records.json"): Data(#"[{"id":"f8fc6b6c-b60f-465c-9a80-0dad4b857049","tanks":[{"water":600,"originalMl":646},{"water":600}],"ratePerHa":300,"ratePer100L":0}]"#.utf8),
            dataRoot.appendingPathComponent("vinetrack_legacy_spray_save_attempts_v1.json"): Data(#"[{"tripBytes":"AAEC/w==","recordBytes":"//4=","verified":{"status":"accepted","hash":"retained-original"}}]"#.utf8),
            dataRoot.appendingPathComponent("vinetrack_trip_sync_metadata.json"): Data(#"{"pendingUpserts":["original-id",1234.567],"establishedParents":[]}"#.utf8),
            dataRoot.appendingPathComponent("vinetrack_growth_stage_record_sync_metadata.json"): Data(#"{"pendingCount":230,"doNotAcknowledge":true}"#.utf8),
            dataRoot.appendingPathComponent("vinetrack_start_tank_commit_v1.json"): Data([0, 1, 255, 42]),
            occurrence.appendingPathComponent("original-trip.json"): Data(#"{"pending":[{"id":"original-operation"}],"history":[],"creationConfirmed":false}"#.utf8),
            planning.appendingPathComponent("attempts.json"): Data(#"{"receipt":{"status":"accepted","original":true}}"#.utf8)
        ]
        for (url, bytes) in originals { try bytes.write(to: url) }
        var modified: [URL: Date] = [:]
        for url in originals.keys { modified[url] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let beforePaths = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let bytes = try RetainedRecoveryDiagnosticExport.capture(documents: docs, applicationSupport: support,
            ownerId: "owner", vineyardId: "vineyard", version: "3.1.9", build: "fixture", diagnostics: "retained error")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(RetainedRecoveryDiagnosticExport.Bundle.self, from: bytes)
        XCTAssertEqual(bundle.formatVersion, 1)
        XCTAssertEqual(bundle.selectedOwnerId, "owner")
        for (url, original) in originals {
            let path = url.path.replacingOccurrences(of: docs.path, with: "Documents").replacingOccurrences(of: support.path, with: "Application Support")
            let file = try XCTUnwrap(bundle.files.first { $0.path == path }, "Missing \(path); exported paths: \(bundle.files.map(\.path))")
            XCTAssertEqual(file.status, "copied", path)
            XCTAssertEqual(file.bytes, original, path)
            XCTAssertEqual(file.sha256, SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified[url])
        }
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), beforePaths)
    }

    func testExportDoesNotCreateMissingSourceDirectoriesOrTreatMissingAsEmptyData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = try RetainedRecoveryDiagnosticExport.capture(documents: root.appendingPathComponent("Documents"),
            applicationSupport: root.appendingPathComponent("Support"), ownerId: "a", vineyardId: "b", version: "v", build: "b", diagnostics: "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(RetainedRecoveryDiagnosticExport.Bundle.self, from: bytes)
        XCTAssertEqual(bundle.files.count, RetainedRecoveryDiagnosticExport.keys.count + RetainedRecoveryDiagnosticExport.journalDirectories.count)
        XCTAssertTrue(bundle.files.allSatisfy { $0.status == "missing" && $0.bytes == nil && $0.sha256 == nil })
    }

    func testAuthPreferencesAndSymlinkedFilesAreNotExported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        let dataRoot = docs.appendingPathComponent("VineTrackData")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let secret = dataRoot.appendingPathComponent("supabase-session.json")
        try Data("private bearer token".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: dataRoot.appendingPathComponent("vinetrack_trips.json"), withDestinationURL: secret)
        let bytes = try RetainedRecoveryDiagnosticExport.capture(documents: docs, applicationSupport: root.appendingPathComponent("Support"),
            ownerId: "a", vineyardId: "b", version: "v", build: "b", diagnostics: "")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(RetainedRecoveryDiagnosticExport.Bundle.self, from: bytes)
        XCTAssertFalse(bundle.files.contains { $0.path.contains("supabase-session") })
        let trip = try XCTUnwrap(bundle.files.first { $0.path.hasSuffix("vinetrack_trips.json") })
        XCTAssertEqual(trip.status, "not_regular_file")
        XCTAssertNil(trip.bytes)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private bearer token"))
    }

    func testSymlinkedSourceRootIsRejectedRatherThanFollowingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("VineTrackData"), withDestinationURL: outside)
        XCTAssertThrowsError(try RetainedRecoveryDiagnosticExport.capture(documents: docs, applicationSupport: root.appendingPathComponent("Support"), ownerId: "a", vineyardId: "b", version: "v", build: "b", diagnostics: ""))
    }

    func testDecodingEvidencePreservesExactSourceOperationIndexAndMissingKeyWithoutPayload() throws {
        struct Item: Decodable { let id: UUID }
        do {
            _ = try JSONDecoder().decode([Item].self, from: Data("[{}]".utf8))
            XCTFail("Strict decode must fail; no skipped/defaulted row")
        } catch {
            let evidence = try XCTUnwrap(RecoveryDecodeEvidence.entry(error, source: "supabase_response", operation: "trips.fetchTrips"))
            XCTAssertEqual(evidence.source, "supabase_response")
            XCTAssertEqual(evidence.operation, "trips.fetchTrips")
            XCTAssertEqual(evidence.failure, "keyNotFound")
            XCTAssertEqual(evidence.codingPath, ["[0]"])
            XCTAssertEqual(evidence.missingKey, "id")
        }
        let context = DecodingError.Context(codingPath: [], debugDescription: "SECRET CUSTOMER BODY AND TOKEN")
        let evidence = try XCTUnwrap(RecoveryDecodeEvidence.entry(DecodingError.dataCorrupted(context), source: "local_legacy_wal", operation: "Attempt.tripBytes"))
        let encoded = try JSONEncoder().encode(evidence)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("SECRET"))
        XCTAssertNil(RecoveryDecodeEvidence.entry(CocoaError(.fileReadUnknown), source: "local_archive", operation: "read"))
    }
}
