import Foundation
import XCTest
@testable import VineTrack

/// P0 Phase A (Issue #40) iOS parity with Android `TripActivityCancellationTest`.
/// Real coordinator, intent store, evidence writer and receipt verification; only the network
/// and the app's local stores are replaced at their protocol boundary.
final class TripActivityCancellationTests: XCTestCase {
    typealias C = TripActivityCancellation

    @MainActor private final class FakeRemote: TripCancellationRemote {
        // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
        deinit {}
        var cancelCalls: [C.Intent] = []
        var cancelResult: (C.Intent) throws -> C.JSON = { _ in throw URLError(.timedOut) }
        var stored: C.JSON?
        var readFails = false
        var onCancel: (() -> Void)?
        func cancel(_ intent: C.Intent) async throws -> C.JSON {
            cancelCalls.append(intent)
            onCancel?()
            return try cancelResult(intent)
        }
        func readReceipt(tripId: String, vineyardId: String) async throws -> C.JSON? {
            if readFails { throw URLError(.notConnectedToInternet) }
            return stored
        }
    }

    @MainActor private final class FakeLocal: TripCancellationLocal {
        // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
        deinit {}
        var writeInFlight = false
        var entries: [C.QueueEntry] = []
        var actuals: [SprayTankActual] = []
        var journal: Data? = Data("{\"journal\":\"original\"}".utf8)
        var claim: Data? = Data("{\"claim\":\"original\"}".utf8)
        var failRemoval = false
        var unreadable = false
        func queueEntries(tripId: String, sprayRecordIds: [String]) throws -> [C.QueueEntry] {
            if unreadable { throw CocoaError(.fileReadCorruptFile) }
            return entries
        }
        func removeQueueEntry(_ entry: C.QueueEntry, tripId: String) -> Bool {
            if failRemoval { return false }
            entries.removeAll { $0 == entry }; return true
        }
        func localActuals(tripId: String) throws -> [SprayTankActual] { actuals.filter { $0.tripId.uuidString.lowercased() == tripId } }
        func removeActual(id: String) -> Bool { actuals.removeAll { $0.id.uuidString == id }; return true }
        func rawJournal(ownerId: String, vineyardId: String, tripId: String) throws -> Data? { journal }
        func removeJournal(ownerId: String, vineyardId: String, tripId: String) -> Bool { journal = nil; return true }
        func rawClaim(tripId: String) throws -> Data? { claim }
        func clearClaim(tripId: String) -> Bool { claim = nil; return true }
    }

    private let owner = UUID().uuidString.lowercased()
    private let vineyard = UUID().uuidString.lowercased()
    private let trip = UUID().uuidString.lowercased()
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("trip-cancel-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var intents: TripCancellationIntentStore { TripCancellationIntentStore(directory: root.appendingPathComponent("intents")) }
    private var evidenceDir: URL { root.appendingPathComponent("evidence") }

    @MainActor private func coordinator(_ remote: FakeRemote, _ local: FakeLocal) -> TripActivityCancellationCoordinator {
        TripActivityCancellationCoordinator(intents: intents, evidence: TripCancellationEvidenceWriter(directory: evidenceDir),
                                            remote: remote, local: local)
    }

    private func actual(water: Double? = 412.5, amount: Double = 1.75) throws -> SprayTankActual {
        try SprayTankActual(vineyardId: UUID(uuidString: vineyard)!, sprayRecordId: UUID(), tripId: UUID(uuidString: trip)!,
                            tankSessionId: UUID().uuidString.lowercased(), tankNumber: 1, waterVolumeL: water,
                            chemicals: [SprayTankActualChemical(plannedChemicalId: UUID(), savedChemicalId: nil,
                                                                name: "Copper", actualAmountBase: amount, unit: .kilograms)],
                            confirmedAt: Date(timeIntervalSince1970: 1_790_000_000), confirmedBy: UUID(uuidString: owner)!)
    }

    private func receipt(for intent: C.Intent, operation: String? = nil, archive: String? = nil) -> C.JSON {
        var row: [String: C.JSON] = [
            "status": .string("CANCELLED_ACKED"), "trip_id": .string(intent.tripId), "vineyard_id": .string(intent.vineyardId),
            "operation_id": .string(operation ?? intent.operationId), "application_classification": .string(intent.classification),
            "server_revision": .string("42"),
        ]
        if let archive { row["compliance_archive_id"] = .string(archive) }
        return .object(row)
    }

    private func request(_ classification: C.Classification, confirm: Bool = false) -> C.Request {
        C.Request(ownerId: owner, vineyardId: vineyard, tripId: trip, classification: classification,
                  confirmedRecordedActualsWereNotApplied: confirm)
    }

    private func evidenceFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: evidenceDir, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: Eligibility (same codes and order as Android)

    func testEligibilityCodesAndOrder() {
        let claim = C.LocalEndClaim(tripId: trip, ownerId: owner, vineyardId: vineyard, endedAt: Date(), source: "device_claim_at_end")
        func code(_ role: String?, _ user: String?, _ claim: C.LocalEndClaim?, pending: Bool = true) -> String? {
            C.eligibility(role: role, signedInUserId: user, claim: claim, tripId: trip, vineyardId: vineyard, localEndPending: pending).code
        }
        XCTAssertEqual(code("owner", nil, claim), "TRIP_CANCEL_AUTH_REQUIRED")
        XCTAssertEqual(code("operator", owner, claim), "TRIP_CANCEL_FORBIDDEN")
        XCTAssertEqual(code("supervisor", owner, claim, pending: false), "TRIP_CANCEL_NOT_LOCAL_END_PENDING")
        XCTAssertEqual(code("manager", owner, nil), "TRIP_CANCEL_NOT_DEVICE_CLAIM")
        XCTAssertEqual(code("manager", UUID().uuidString, claim), "TRIP_CANCEL_CLAIM_OWNER_MISMATCH")
        let foreign = C.LocalEndClaim(tripId: trip, ownerId: owner, vineyardId: UUID().uuidString, endedAt: Date(), source: "x")
        XCTAssertEqual(code("owner", owner, foreign), "TRIP_CANCEL_CLAIM_VINEYARD_MISMATCH")
        XCTAssertNil(code("Owner", owner.uppercased(), claim))
        for role in ["owner", "manager", "supervisor"] { XCTAssertNil(code(role, owner, claim)) }
    }

    // MARK: Classification holds

    @MainActor func testNotSureChangesNothingAndSendsNothing() async {
        let remote = FakeRemote(), local = FakeLocal()
        local.entries = [.init(kind: C.QueueEntry.tripUpsert, id: trip)]
        let outcome = await coordinator(remote, local).cancel(request(.unknown), sprayRecordIds: [])
        XCTAssertEqual(outcome, .refused("TRIP_CANCEL_CLASSIFICATION_UNKNOWN_HELD"))
        XCTAssertTrue(remote.cancelCalls.isEmpty)
        XCTAssertEqual(local.entries.count, 1)
        XCTAssertTrue(evidenceFiles().isEmpty)
        XCTAssertNil(try intents.find(tripId: trip))
    }

    @MainActor func testNotAppliedWithRecordedActualsRequiresExplicitConfirmation() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        local.actuals = [try actual()]
        let outcome = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        XCTAssertEqual(outcome, .refused("TRIP_CANCEL_LOCAL_ACTUALS_REQUIRE_CONFIRMATION"))
        XCTAssertTrue(remote.cancelCalls.isEmpty)
        XCTAssertEqual(local.actuals.count, 1)
    }

    @MainActor func testAppliedWithoutRecordedActualsIsRefusedLocally() async {
        let remote = FakeRemote(), local = FakeLocal()
        let outcome = await coordinator(remote, local).cancel(request(.applied), sprayRecordIds: [])
        XCTAssertEqual(outcome, .refused("TRIP_CANCEL_COMPLIANCE_FACTS_REQUIRED"))
        XCTAssertTrue(remote.cancelCalls.isEmpty)
    }

    @MainActor func testWriteInFlightHoldsWithoutRequest() async {
        let remote = FakeRemote(), local = FakeLocal()
        local.entries = [.init(kind: C.QueueEntry.tripUpsert, id: trip)]
        local.writeInFlight = true
        let outcome = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        XCTAssertEqual(outcome, .refused("TRIP_CANCEL_WRITE_IN_FLIGHT"))
        XCTAssertTrue(remote.cancelCalls.isEmpty)
    }

    @MainActor func testUnreadableLocalQueueHoldsAsEvidenceUnreadable() async {
        let remote = FakeRemote(), local = FakeLocal()
        local.unreadable = true
        let outcome = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        XCTAssertEqual(outcome, .refused("TRIP_CANCEL_EVIDENCE_UNREADABLE"))
        XCTAssertTrue(remote.cancelCalls.isEmpty)
    }

    // MARK: Happy path

    @MainActor func testVerifiedReceiptCleansOnlyAfterDurableAckAndKeepsEvidence() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        let spray = UUID().uuidString.lowercased()
        local.entries = [.init(kind: C.QueueEntry.tripUpsert, id: trip), .init(kind: C.QueueEntry.sprayRecordUpsert, id: spray),
                         .init(kind: C.QueueEntry.occurrencePending, id: UUID().uuidString.lowercased())]
        local.actuals = [try actual()]
        var evidenceExistedAtSend = false
        var intentAtSend: C.Intent?
        remote.onCancel = { [unowned self] in
            evidenceExistedAtSend = !self.evidenceFiles().isEmpty
            intentAtSend = try? self.intents.find(tripId: self.trip)
            XCTAssertEqual(local.entries.count, 3, "nothing removed before the receipt")
        }
        remote.cancelResult = { [unowned self] in self.receipt(for: $0) }
        let outcome = await coordinator(remote, local).cancel(request(.notApplied, confirm: true), sprayRecordIds: [spray])
        XCTAssertEqual(outcome, .acked(cleaned: true))
        XCTAssertTrue(evidenceExistedAtSend)
        XCTAssertEqual(intentAtSend?.state, .REQUESTED)
        XCTAssertEqual(remote.cancelCalls.count, 1)
        XCTAssertNil(remote.cancelCalls[0].complianceFacts)
        XCTAssertTrue(local.entries.isEmpty)
        XCTAssertTrue(local.actuals.isEmpty)
        XCTAssertNil(local.journal)
        XCTAssertNil(local.claim)
        let saved = try XCTUnwrap(try intents.find(tripId: trip))
        XCTAssertEqual(saved.state, .CLEANED)
        XCTAssertTrue(saved.blocksReplay, "a cancelled Trip must never be re-uploaded")
        // Original evidence retained verbatim, including recorded actual amounts.
        let file = try XCTUnwrap(evidenceFiles().first)
        let evidence = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(evidence.contains("1.75"))
        XCTAssertTrue(evidence.contains("412.5"))
        XCTAssertTrue(evidence.contains("journal"))
        XCTAssertTrue(evidence.contains(spray))
    }

    @MainActor func testAppliedSendsVerbatimComplianceFactsAndRequiresArchiveId() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        local.actuals = [try actual(water: 380.25, amount: 2.125)]
        remote.cancelResult = { [unowned self] in self.receipt(for: $0) }
        let refused = await coordinator(remote, local).cancel(request(.applied), sprayRecordIds: [])
        XCTAssertEqual(refused, .refused("TRIP_CANCEL_RECEIPT_MISMATCH"))
        XCTAssertEqual(try intents.find(tripId: trip)?.lastCode, "TRIP_CANCEL_RECEIPT_MISMATCH_COMPLIANCE_ARCHIVE_ID")
        XCTAssertEqual(local.actuals.count, 1, "mismatch removes nothing")
        let facts = try XCTUnwrap(remote.cancelCalls.first?.complianceFacts)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(facts), encoding: .utf8))
        XCTAssertTrue(encoded.contains("2.125"))
        XCTAssertTrue(encoded.contains("380.25"))
        XCTAssertTrue(encoded.contains("\"Kg\""))
    }

    // MARK: Interruption and recovery

    @MainActor func testLostResponseRecoversByReadbackWithSameOperation() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        local.entries = [.init(kind: C.QueueEntry.tripUpsert, id: trip)]
        let first = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        XCTAssertEqual(first, .pending("TRIP_CANCEL_RESPONSE_UNKNOWN"))
        XCTAssertEqual(local.entries.count, 1)
        let held = try XCTUnwrap(try intents.find(tripId: trip))
        XCTAssertEqual(held.state, .REQUESTED)
        XCTAssertTrue(held.blocksReplay)
        // Server did commit; the receipt is found by readback after restart.
        remote.stored = receipt(for: held)
        let results = await coordinator(remote, local).reconcileAll()
        XCTAssertEqual(results.map(\.1), [.acked(cleaned: true)])
        XCTAssertEqual(remote.cancelCalls.count, 1, "readback first; no resend")
        XCTAssertTrue(local.entries.isEmpty)
    }

    @MainActor func testReadbackAbsentResendsOriginalOperationId() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        _ = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        let opId = try XCTUnwrap(try intents.find(tripId: trip)).operationId
        remote.cancelResult = { [unowned self] in self.receipt(for: $0) }
        _ = await coordinator(remote, local).reconcileAll()
        XCTAssertEqual(remote.cancelCalls.map(\.operationId), [opId, opId])
        XCTAssertEqual(try intents.find(tripId: trip)?.state, .CLEANED)
    }

    @MainActor func testReadbackUnavailableKeepsHolding() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        local.entries = [.init(kind: C.QueueEntry.tripUpsert, id: trip)]
        _ = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        remote.readFails = true
        let results = await coordinator(remote, local).reconcileAll()
        XCTAssertEqual(results.map(\.1), [.pending("TRIP_CANCEL_READBACK_UNAVAILABLE")])
        XCTAssertEqual(remote.cancelCalls.count, 1)
        XCTAssertEqual(local.entries.count, 1)
    }

    @MainActor func testDefinitiveRefusalReleasesHoldAndRemovesNothing() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        local.entries = [.init(kind: C.QueueEntry.tripUpsert, id: trip)]
        remote.cancelResult = { _ in throw TripCancellationServerRefusal(status: 409, code: "TRIP_CANCEL_TRIP_COMPLETED") }
        let outcome = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        XCTAssertEqual(outcome, .refused("TRIP_CANCEL_TRIP_COMPLETED"))
        let saved = try XCTUnwrap(try intents.find(tripId: trip))
        XCTAssertEqual(saved.state, .REFUSED)
        XCTAssertFalse(saved.blocksReplay)
        XCTAssertEqual(local.entries.count, 1)
        XCTAssertNotNil(local.journal)
        XCTAssertEqual(evidenceFiles().count, 1)
    }

    @MainActor func testAlreadyCancelledByOtherOperationAcceptsReadbackForSameTrip() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        remote.cancelResult = { _ in throw TripCancellationServerRefusal(status: 409, code: "TRIP_CANCEL_ALREADY_CANCELLED_OTHER_OPERATION") }
        remote.stored = .object(["status": .string("CANCELLED_ACKED"), "trip_id": .string(trip), "vineyard_id": .string(vineyard),
                                 "operation_id": .string(UUID().uuidString.lowercased()),
                                 "application_classification": .string("not_applied"), "server_revision": .number(7)])
        let outcome = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        XCTAssertEqual(outcome, .acked(cleaned: true))
    }

    @MainActor func testForeignTripReceiptIsMismatchAndHeld() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        local.entries = [.init(kind: C.QueueEntry.tripUpsert, id: trip)]
        remote.cancelResult = { intent in
            .object(["status": .string("CANCELLED_ACKED"), "trip_id": .string(UUID().uuidString), "vineyard_id": .string(intent.vineyardId),
                     "operation_id": .string(intent.operationId), "application_classification": .string(intent.classification),
                     "server_revision": .number(3)])
        }
        let outcome = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        XCTAssertEqual(outcome, .refused("TRIP_CANCEL_RECEIPT_MISMATCH"))
        XCTAssertEqual(try intents.find(tripId: trip)?.state, .RECEIPT_MISMATCH)
        XCTAssertTrue(try XCTUnwrap(try intents.find(tripId: trip)).blocksReplay)
        XCTAssertEqual(local.entries.count, 1)
    }

    @MainActor func testInterruptedCleanupStaysAckedAndFinishesOnReconcile() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        local.entries = [.init(kind: C.QueueEntry.tripUpsert, id: trip)]
        local.failRemoval = true
        remote.cancelResult = { [unowned self] in self.receipt(for: $0) }
        let outcome = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        XCTAssertEqual(outcome, .acked(cleaned: false))
        XCTAssertEqual(try intents.find(tripId: trip)?.state, .ACKED)
        local.failRemoval = false
        let results = await coordinator(remote, local).reconcileAll()
        XCTAssertEqual(results.map(\.1), [.acked(cleaned: true)])
        XCTAssertEqual(remote.cancelCalls.count, 1)
        XCTAssertTrue(local.entries.isEmpty)
    }

    @MainActor func testOpenIntentIsReusedNotReplacedByNewOperation() async throws {
        let remote = FakeRemote(), local = FakeLocal()
        _ = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        _ = await coordinator(remote, local).cancel(request(.notApplied), sprayRecordIds: [])
        XCTAssertEqual(Set(remote.cancelCalls.map(\.operationId)).count, 1)
        XCTAssertEqual(evidenceFiles().count, 1)
    }

    // MARK: Durable store

    func testUnreadableIntentHoldsReplay() throws {
        let dir = root.appendingPathComponent("intents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let store = TripCancellationIntentStore(directory: dir)
        XCTAssertThrowsError(try store.all())
        XCTAssertTrue(store.blocksReplay(tripId: UUID()))
    }

    func testLocalEndClaimIsWrittenOnceAndRemovable() throws {
        let store = TripLocalEndClaimStore(directory: root.appendingPathComponent("claims"))
        let claim = C.LocalEndClaim(tripId: trip, ownerId: owner, vineyardId: vineyard, endedAt: Date(timeIntervalSince1970: 1), source: "device_claim_at_end")
        XCTAssertTrue(store.record(claim))
        XCTAssertTrue(store.record(.init(tripId: trip, ownerId: UUID().uuidString, vineyardId: vineyard, endedAt: Date(), source: "later")))
        XCTAssertEqual(try store.find(tripId: trip), claim, "the first claim is never overwritten")
        XCTAssertTrue(store.remove(tripId: trip))
        XCTAssertNil(try store.find(tripId: trip))
    }

    func testServerCodeExtractsFixedCodeOnly() {
        XCTAssertEqual(C.serverCode("{\"message\":\"TRIP_CANCEL_TRIP_COMPLETED: secret detail\"}"), "TRIP_CANCEL_TRIP_COMPLETED")
        XCTAssertEqual(C.serverCode("{\"message\":\"TRIP_CANCELLED_TOMBSTONE\"}"), "TRIP_CANCELLED_TOMBSTONE")
        XCTAssertNil(C.serverCode("{\"message\":\"boom\"}"))
    }
}
