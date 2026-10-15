import XCTest
import CryptoKit
@testable import VineTrack

final class LegacySprayPairReceiptTests: XCTestCase {
    @MainActor private func fixture() throws -> (PersistenceStore, LegacySpraySaveRecovery, LegacySpraySaveRecovery.Attempt, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let p = PersistenceStore(directory: root)
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: UUID())
        let trip = Trip(vineyardId: scope.vineyard, startTime: Date(timeIntervalSince1970: 100), isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: scope.vineyard, date: trip.startTime, startTime: trip.startTime, notes: "Frozen")
        let journal = LegacySpraySaveRecovery(persistence: p)
        try journal.prepare(scope: scope, record: record, trip: trip)
        _ = try journal.reconcile(scope: scope, record: { _ in }, trip: { _ in })
        return (p, journal, try XCTUnwrap(journal.attempts().first), root)
    }
    @MainActor private func response(_ a: LegacySpraySaveRecovery.Attempt, status: String = "accepted", code: String? = nil, hash: String = String(repeating: "a", count: 64)) throws -> Data {
        var fields: [String: Any] = ["version": 1, "status": status, "operation_id": try XCTUnwrap(a.rpc?.operation).uuidString.lowercased(),
            "vineyard_id": a.scope.vineyard.uuidString.lowercased(), "trip_id": a.trip.id.uuidString.lowercased(),
            "spray_record_id": a.record.id.uuidString.lowercased(), "request_sha256": hash, "committed_at": "2026-10-15T03:00:01+00:00"]
        if let code { fields["code"] = code }
        return try JSONSerialization.data(withJSONObject: fields)
    }
    @MainActor func testFreshLegacyRecipeAdmitsRecordedIntentWithoutPlanningFields() throws {
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: UUID())
        let trip = Trip(vineyardId: scope.vineyard, isActive: false, tripFunction: "spraying")
        let tank = SprayTank(tankNumber: 1, waterVolume: 420,
            chemicals: [SprayChemical(name: "Fixture", volumePerTank: 1500, ratePerHa: 750, unit: .grams)])
        let record = SprayRecord(tripId: trip.id, vineyardId: scope.vineyard, tanks: [tank],
            applicationGeometry: SprayApplicationSnapshot(applicationMode: .wholeBlock,
                targets: [.powderyMildew, .downyMildew], sprayHeadTarget: .fullCanopy))
        XCTAssertNil(SprayStartRecipeValidation.blocker(record.tanks))
        let request = try LegacySprayPairReceipt.prepare(scope: scope, record: record, trip: trip)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: request.record) as? [String: Any])
        XCTAssertEqual(fields["targets"] as? [String], ["powdery_mildew", "downy_mildew"])
        XCTAssertEqual(fields["spray_head_target"] as? String, "full_canopy")
        XCTAssertNil(fields["sprayer_configuration"])
        XCTAssertNil(fields["spray_planning_method"])
        XCTAssertTrue(Set(fields.keys).isSubset(of: LegacySprayPairReceipt.recordKeys))
    }

    @MainActor func testFirstAtomicSaveRequiresExactFollowupRecoveryBeforeRelease() async throws {
        let (_, journal, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var calls: [String] = []; let receipt = try response(a)
        try await journal.replay(scope: a.scope, isCurrent: { true }) { rpc, body in
            calls.append(rpc); XCTAssertEqual(body, try a.rpc?.body())
            XCTAssertTrue(try journal.contains(trip: a.trip.id)); return receipt
        }
        XCTAssertEqual(calls, ["save_legacy_spray_pair_v1", "recover_legacy_spray_pair_v1"])
        XCTAssertFalse(try journal.contains(trip: a.trip.id))
        XCTAssertEqual(try journal.attempts().first?.record, a.record)
        calls = []
        try await journal.replay(scope: a.scope, isCurrent: { true }) { rpc, _ in calls.append(rpc); return receipt }
        XCTAssertTrue(calls.isEmpty)
    }
    @MainActor func testLostSuccessfulResponseUsesOnlyRecoveryAfterFileRecreation() async throws {
        let (p, journal, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { try await journal.replay(scope: a.scope, isCurrent: { true }) { _, _ in throw URLError(.timedOut) }; XCTFail() } catch {}
        XCTAssertTrue(try journal.attempts()[0].rpcClaimed)
        let restarted = LegacySpraySaveRecovery(persistence: p); let receipt = try response(a)
        try await restarted.replay(scope: a.scope, isCurrent: { true }) { rpc, body in
            XCTAssertEqual(rpc, "recover_legacy_spray_pair_v1"); XCTAssertEqual(body, try a.rpc?.body()); return receipt
        }
        XCTAssertFalse(try restarted.contains(record: a.record.id))
    }
    @MainActor func testTerminalRejectionPreservesOriginalAndNeverSendsAgain() async throws {
        for code in ["identity_conflict", "validation_or_reference_conflict"] {
            let (_, j, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let receipt = try response(a, status: "rejected", code: code)
            try await j.replay(scope: a.scope, isCurrent: { true }) { _, _ in receipt }
            XCTAssertTrue(try j.contains(trip: a.trip.id)); XCTAssertEqual(try j.attempts()[0].record, a.record)
            XCTAssertTrue(try XCTUnwrap(j.attempts()[0].receiptBlocker).contains(code))
            try await j.replay(scope: a.scope, isCurrent: { true }) { _, _ in XCTFail("Terminal request retried"); return receipt }
        }
    }
    @MainActor func testUnknownConflictMalformedAndHTTPErrorRemainHeldWithoutCreateReplay() async throws {
        for raw in ["{\"version\":1,\"status\":\"unknown\"}", "{\"version\":1,\"status\":\"conflict\",\"code\":\"operation_payload_mismatch\"}", "[]", "{}", "{\"code\":\"409\"}"] {
            let (_, j, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            do { try await j.replay(scope: a.scope, isCurrent: { true }) { _, _ in Data(raw.utf8) }; XCTFail(raw) } catch {}
            do { try await j.replay(scope: a.scope, isCurrent: { true }) { rpc, _ in XCTAssertEqual(rpc, "recover_legacy_spray_pair_v1"); return Data(raw.utf8) }; XCTFail() } catch {}
            XCTAssertTrue(try j.contains(trip: a.trip.id))
        }
    }
    @MainActor func testEveryReceiptIdentityVersionAndHashMismatchStaysHeld() async throws {
        for key in ["operation_id", "trip_id", "spray_record_id", "vineyard_id", "version", "request_sha256", "committed_at"] {
            let (_, j, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: response(a)) as? [String: Any])
            fields[key] = key == "version" ? 2 : (key == "request_sha256" ? "BAD" : UUID().uuidString)
            let bad = try JSONSerialization.data(withJSONObject: fields)
            do { try await j.replay(scope: a.scope, isCurrent: { true }) { _, _ in bad }; XCTFail(key) } catch {}
            XCTAssertTrue(try j.contains(record: a.record.id))
        }
    }
    @MainActor func testDifferentRecoveryFingerprintCannotReleaseCandidate() async throws {
        let (_, j, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { try await j.replay(scope: a.scope, isCurrent: { true }) { rpc, _ in
            try self.response(a, hash: String(repeating: rpc.hasPrefix("save") ? "a" : "b", count: 64))
        }; XCTFail() } catch {}
        XCTAssertTrue(try j.contains(trip: a.trip.id))
    }
    @MainActor func testRevocationAndForeignScopeCannotSendOrAcknowledge() async throws {
        let (_, j, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        try await j.replay(scope: .init(actor: UUID(), session: a.scope.session, vineyard: a.scope.vineyard), isCurrent: { true }) { _, _ in calls += 1; return Data() }
        try await j.replay(scope: a.scope, isCurrent: { false }) { _, _ in calls += 1; return Data() }
        XCTAssertEqual(calls, 0)
        var current = true; let receipt = try response(a)
        do { try await j.replay(scope: a.scope, isCurrent: { current }) { _, _ in current = false; return receipt }; XCTFail() } catch {}
        XCTAssertTrue(try j.contains(trip: a.trip.id))
    }
    @MainActor func testDurableClaimFailurePreventsNetwork() async throws {
        let (p, j, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        p.durableSaveFailureForTesting = { _ in URLError(.cannotWriteToFile) }
        do { try await j.replay(scope: a.scope, isCurrent: { true }) { _, _ in XCTFail("Sent before commit"); return Data() }; XCTFail() } catch {}
        p.durableSaveFailureForTesting = nil
        XCTAssertFalse(try j.attempts()[0].rpcClaimed)
    }
    @MainActor func testOldFormatEvidenceNeverAdoptedOrTransmitted() async throws {
        let (p, _, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var old = a; old.rpc = nil
        try p.saveOrThrow([old], key: LegacySpraySaveRecovery.key)
        let j = LegacySpraySaveRecovery(persistence: p)
        try await j.replay(scope: a.scope, isCurrent: { true }) { _, _ in XCTFail("Old evidence adopted"); return Data() }
        XCTAssertTrue(try j.contains(trip: a.trip.id))
    }
    @MainActor func testChangedIntentCannotReplaceOriginalOperationOrPayload() throws {
        let (_, j, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var changed = a.record; changed.notes = "Changed"
        XCTAssertThrowsError(try j.prepare(scope: a.scope, record: changed, trip: a.trip))
        XCTAssertEqual(try j.attempts()[0].rpc, a.rpc)
        let request = try XCTUnwrap(a.rpc)
        let trip = try XCTUnwrap(JSONSerialization.jsonObject(with: request.trip) as? [String: Any])
        XCTAssertEqual(trip["vineyard_id"] as? String, a.scope.vineyard.uuidString.lowercased())
        XCTAssertTrue(Set(trip.keys).isSubset(of: LegacySprayPairReceipt.tripKeys))
    }
    @MainActor func testConcurrentReplayHasOneCreateAndKeepsOriginalIdentity() async throws {
        let (_, j, a, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var calls: [String] = []; let receipt = try response(a)
        try await j.replay(scope: a.scope, isCurrent: { true }) { rpc, body in
            calls.append(rpc)
            // Reentrant reconnect while the create response is in flight cannot send again.
            try await j.replay(scope: a.scope, isCurrent: { true }) { _, _ in XCTFail("Concurrent duplicate send"); return receipt }
            XCTAssertEqual(body, try a.rpc?.body()); return receipt
        }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(try j.attempts()[0].rpc, a.rpc)
    }
    @MainActor func testGoldenPostgresBytesAreNotSwiftSortedJSONHash() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "legacy-spray-pair-v1-golden", withExtension: "json"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let text = try XCTUnwrap(fields["postgres_jsonb_canonical_text"] as? String)
        XCTAssertEqual(text.utf8.count, 944)
        XCTAssertEqual(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), fields["postgres_sha256_hex"] as? String)
    }
}
