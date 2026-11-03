import Foundation
import XCTest
@testable import VineTrack

@MainActor
final class GuidedSyncRepairEngineTests: XCTestCase {
    private func actual() throws -> SprayTankActual {
        let product = try SprayTankActualChemical(
            plannedChemicalId: UUID(),
            savedChemicalId: UUID(),
            name: "Test ingredient",
            actualAmountBase: ChemicalUnit.litres.toBase(2.5),
            unit: .litres)
        let additive = try SprayTankActualChemical(
            plannedChemicalId: nil, savedChemicalId: UUID(),
            usageKind: "additional", name: "Test additive",
            actualAmountBase: ChemicalUnit.kilograms.toBase(1.25),
            unit: .kilograms)
        return try SprayTankActual(
            vineyardId: UUID(), sprayRecordId: UUID(), tripId: UUID(),
            tankSessionId: UUID().uuidString, tankNumber: 1,
            waterVolumeL: 450, chemicals: [product, additive],
            confirmedAt: Date(timeIntervalSince1970: 1_793_660_000),
            confirmedBy: UUID(), correctionVersion: 1)
    }

    func testOriginalConfirmedActualIdentityIsImmutable() throws {
        let a = try actual()
        XCTAssertTrue(GuidedRepairFieldValidation.immutableIdentityMatches(a, a))
        let foreign = try SprayTankActual(
            id: a.id, vineyardId: a.vineyardId, sprayRecordId: UUID(),
            tripId: a.tripId, tankSessionId: a.tankSessionId,
            tankNumber: a.tankNumber, waterVolumeL: a.waterVolumeL,
            chemicals: a.chemicals, confirmedAt: a.confirmedAt,
            confirmedBy: a.confirmedBy)
        XCTAssertFalse(GuidedRepairFieldValidation.immutableIdentityMatches(a, foreign))
    }

    func testCorrectedChemicalAmountsPreserveAllOriginalIdentitiesAndUnits() throws {
        let a = try actual()
        let amounts = Dictionary(uniqueKeysWithValues:
            a.chemicals.map { ($0.id, "0") })
        let corrected = try GuidedActualUseCorrection.reviewedChemicals(
            original: a.chemicals, amounts: amounts)
        XCTAssertEqual(corrected.count, a.chemicals.count)
        for (before, after) in zip(a.chemicals, corrected) {
            XCTAssertEqual(before.id, after.id)
            XCTAssertEqual(before.plannedChemicalId, after.plannedChemicalId)
            XCTAssertEqual(before.savedChemicalId, after.savedChemicalId)
            XCTAssertEqual(before.unit, after.unit)
            XCTAssertEqual(before.usageKind, after.usageKind)
            XCTAssertEqual(after.actualAmountBase, 0)
        }
    }

    func testAmountReviewRejectsBlankNegativeInvalidAndMissingChemicalRows() throws {
        let a = try actual()
        let first = try XCTUnwrap(a.chemicals.first)
        for entered in ["", "-2", "Infinity", "not-a-number"] {
            let amounts = [first.id: entered]
            XCTAssertThrowsError(try GuidedActualUseCorrection.reviewedChemicals(
                original: a.chemicals, amounts: amounts))
        }
        let amount = a.chemicals.map { ($0.id, "1") }
        var extra = Dictionary(uniqueKeysWithValues: amount)
        extra[UUID()] = "7"
        XCTAssertThrowsError(try GuidedActualUseCorrection.reviewedChemicals(
            original: a.chemicals, amounts: extra))
    }

    // Swift 6.2.4 synchronous XCTest teardown can corrupt MainActor deinit task-local state.
    // Async XCTest supplies the correct task context; assertions and disk writes stay synchronous.
    // https://github.com/swiftlang/swift/issues/87316
    func testUnresolvedCorrectionCannotMintCompetingOperationAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let owner = UUID(), vineyard = UUID(), record = UUID()
        let ledger = GuidedRepairAuditLedger(persistence: persistence)
        let operation = try ledger.begin(account: owner, vineyard: vineyard, record: record,
            correction: "reviewLegacyDeleted", inputHash: "original", reason: "Original reviewed evidence")
        let reopened = GuidedRepairAuditLedger(persistence: persistence)
        XCTAssertThrowsError(try reopened.begin(account: owner, vineyard: vineyard, record: record,
            correction: "reviewLegacyDeleted", inputHash: "changed", reason: "Changed reviewed evidence"))
        let history = try reopened.history(account: owner, vineyard: vineyard, record: record)
        XCTAssertEqual(history.map(\.id), [operation])
        XCTAssertTrue(try reopened.history(account: UUID(), vineyard: vineyard, record: record).isEmpty)
    }

    func testFrozenReviewedInputsSurviveReopenWithSameOperation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UUID(), vineyard = UUID(), record = UUID(), chemical = UUID()
        let input = GuidedRepairReviewInput(reason: "Verified original paper record", water: "350",
            chemicals: [chemical: "702"], tankTime: nil, sessionId: nil,
            applied: nil, recordedNotApplied: nil)
        let fingerprint = try input.fingerprint(issueId: "actual:" + record.uuidString, correction: "amendActualUse")
        let persistence = PersistenceStore(directory: directory)
        let ledger = GuidedRepairAuditLedger(persistence: persistence)
        let operation = try ledger.begin(account: owner, vineyard: vineyard, record: record,
            correction: "amendActualUse", inputHash: fingerprint, reason: input.reason, reviewInput: input)
        try ledger.stage(id: operation, account: owner, vineyard: vineyard,
            code: "RETAINS_FAILED_RESPONSE", explanation: "Original response lost; do not replace operation")
        let reopened = GuidedRepairAuditLedger(persistence: PersistenceStore(directory: directory))
        let entry = try XCTUnwrap(reopened.history(account: owner, vineyard: vineyard, record: record).first)
        XCTAssertEqual(entry.reviewInput, input)
        XCTAssertEqual(try reopened.begin(account: owner, vineyard: vineyard, record: record,
            correction: "amendActualUse", inputHash: fingerprint, reason: input.reason,
            reviewInput: entry.reviewInput), operation)
    }

    func testLegacyAuditWithoutFrozenInputsCannotBeResumedOrReplaced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let owner = UUID(), vineyard = UUID(), record = UUID()
        let ledger = GuidedRepairAuditLedger(persistence: persistence)
        let operation = try ledger.begin(account: owner, vineyard: vineyard, record: record,
            correction: "amendActualUse", inputHash: "legacy", reason: "Retained original legacy request")
        let reopened = GuidedRepairAuditLedger(persistence: PersistenceStore(directory: directory))
        XCTAssertThrowsError(try reopened.begin(account: owner, vineyard: vineyard, record: record,
            correction: "amendActualUse", inputHash: "legacy", reason: "Retained original legacy request"))
        XCTAssertEqual(try reopened.history(account: owner, vineyard: vineyard, record: record).map(\.id), [operation])
    }

    func testReviewedFingerprintIsIndependentOfChemicalDictionaryOrder() throws {
        let first = UUID(), second = UUID()
        let lhs = GuidedRepairReviewInput(reason: "Verified original operator record", water: "350",
            chemicals: Dictionary(uniqueKeysWithValues: [(first, "702"), (second, "5")]),
            tankTime: nil, sessionId: nil, applied: nil, recordedNotApplied: nil)
        let rhs = GuidedRepairReviewInput(reason: lhs.reason, water: lhs.water,
            chemicals: Dictionary(uniqueKeysWithValues: [(second, "5"), (first, "702")]),
            tankTime: nil, sessionId: nil, applied: nil, recordedNotApplied: nil)
        XCTAssertEqual(try lhs.fingerprint(issueId: "original", correction: "amendActualUse"),
                       try rhs.fingerprint(issueId: "original", correction: "amendActualUse"))
        let changed = GuidedRepairReviewInput(reason: lhs.reason, water: "351", chemicals: lhs.chemicals,
            tankTime: nil, sessionId: nil, applied: nil, recordedNotApplied: nil)
        XCTAssertNotEqual(try lhs.fingerprint(issueId: "original", correction: "amendActualUse"),
                          try changed.fingerprint(issueId: "original", correction: "amendActualUse"))
    }

    func testEveryChemicalRowRejectsInvalidNumbersWithOtherwiseCompleteInput() throws {
        let a = try actual()
        let first = try XCTUnwrap(a.chemicals.first)
        for entered in ["", "-2", "Infinity", "nan", "not-a-number"] {
            var amounts = Dictionary(uniqueKeysWithValues: a.chemicals.map { ($0.id, "1") })
            amounts[first.id] = entered
            XCTAssertThrowsError(try GuidedActualUseCorrection.reviewedChemicals(original: a.chemicals, amounts: amounts))
        }
    }

    func testAcceptedAmendmentLostResponseReopensAndReconcilesWithoutResend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let before = try actual(), operation = UUID(), actor = UUID()
        let accepted = try SprayTankActual(id: before.id, vineyardId: before.vineyardId,
            sprayRecordId: before.sprayRecordId, tripId: before.tripId,
            tankSessionId: before.tankSessionId, tankNumber: before.tankNumber,
            waterVolumeL: 350, chemicals: before.chemicals, confirmedAt: before.confirmedAt,
            confirmedBy: before.confirmedBy, correctionVersion: 2)
        let receipt = GuidedActualUseCorrection.AmendmentRow(operation_id: operation,
            vineyard_id: before.vineyardId, trip_id: before.tripId, spray_record_id: before.sprayRecordId,
            spray_tank_actual_id: before.id, tank_number: 1, chemical_actual_id: nil,
            field_name: "actualWaterLitres", previous_value: .number(450), new_value: .number(350),
            revision: 2, edited_by: actor)
        var remote = before, rows: [GuidedActualUseCorrection.AmendmentRow] = [], sent = 0
        do {
            _ = try await GuidedActualUseCorrection.reconcileAmendment(original: before, owner: actor,
                vineyard: before.vineyardId, reason: "Verified original operator paper record", water: 350,
                chemicals: before.chemicals, operationId: operation, persistence: persistence,
                requireContext: {}, readActual: { remote }, readAmendments: { rows }, send: { request in
                    sent += 1
                    XCTAssertEqual(request.p_operation_id, operation)
                    XCTAssertEqual(request.p_expected_version, 1)
                    remote = accepted; rows = [receipt]
                    throw URLError(.networkConnectionLost) // Server committed; response lost.
                })
            XCTFail("The lost response must not be reported as verified")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let reopened = PersistenceStore(directory: directory)
        let frozen = try XCTUnwrap(GuidedActualUseCorrection.savedAmendment(operation, persistence: reopened))
        XCTAssertEqual(frozen.original, before)
        XCTAssertEqual(frozen.request.p_expected_version, 1)
        // A normal pull may already have updated the local Actual before retry.
        let verified = try await GuidedActualUseCorrection.reconcileAmendment(original: accepted, owner: actor,
            vineyard: before.vineyardId, reason: frozen.reason, water: 350, chemicals: before.chemicals,
            operationId: operation, persistence: reopened, requireContext: {}, readActual: { remote },
            readAmendments: { rows }, send: { _ in sent += 1; XCTFail("Do not resend an accepted operation") })
        XCTAssertEqual(verified, accepted)
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(try GuidedActualUseCorrection.savedAmendment(operation, persistence: reopened), frozen)
    }

    func testFailedAmendmentRetriesExactFrozenPayloadAndVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try actual(), operation = UUID(), actor = UUID()
        let persistence = PersistenceStore(directory: directory)
        var payloads: [GuidedActualUseCorrection.Requested] = []
        for _ in 0..<2 {
            do {
                _ = try await GuidedActualUseCorrection.reconcileAmendment(original: before, owner: actor,
                    vineyard: before.vineyardId, reason: "Verified original operator paper record", water: nil,
                    chemicals: before.chemicals, operationId: operation, persistence: persistence,
                    requireContext: {}, readActual: { before }, readAmendments: { [] }, send: { request in
                        payloads.append(request); throw URLError(.notConnectedToInternet)
                    })
                XCTFail("Offline dispatch cannot verify success")
            } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        }
        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads.first, payloads.last)
        XCTAssertEqual(payloads.first?.p_operation_id, operation)
        XCTAssertEqual(payloads.first?.p_expected_version, 1)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(payloads.first))) as? [String: Any]
        XCTAssertTrue(json?["p_water_volume_l"] is NSNull, "Not recorded is explicit RPC NULL, never omitted/zero")
        // Changed operator input cannot overwrite the original archive or dispatch.
        do {
            _ = try await GuidedActualUseCorrection.reconcileAmendment(original: before, owner: actor,
                vineyard: before.vineyardId, reason: "Verified original operator paper record", water: 351,
                chemicals: before.chemicals, operationId: operation, persistence: persistence,
                requireContext: {}, readActual: { before }, readAmendments: { [] }, send: { _ in XCTFail("Changed input dispatched") })
            XCTFail("Frozen inputs must conflict")
        } catch { XCTAssertTrue(error is GuidedActualUseCorrection.Rejected) }
        XCTAssertNil(try XCTUnwrap(GuidedActualUseCorrection.savedAmendment(operation, persistence: persistence)).request.p_water_volume_l)
    }

    func testAmendmentCannotDispatchAfterScopeChangesDuringReadOrDurableSaveFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try actual(), operation = UUID(), actor = UUID()
        let persistence = PersistenceStore(directory: directory)
        var contextIsCurrent = true, sent = 0
        do {
            _ = try await GuidedActualUseCorrection.reconcileAmendment(original: before, owner: actor,
                vineyard: before.vineyardId, reason: "Verified original operator paper record", water: 350,
                chemicals: before.chemicals, operationId: operation, persistence: persistence,
                requireContext: { if !contextIsCurrent { throw CancellationError() } },
                readActual: { before }, readAmendments: { contextIsCurrent = false; return [] },
                send: { _ in sent += 1 })
            XCTFail("Scope change must hold")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try GuidedActualUseCorrection.savedAmendment(operation, persistence: persistence))
        persistence.durableSaveFailureForTesting = { _ in URLError(.cannotWriteToFile) }
        do {
            _ = try await GuidedActualUseCorrection.reconcileAmendment(original: before, owner: actor,
                vineyard: before.vineyardId, reason: "Verified original operator paper record", water: 350,
                chemicals: before.chemicals, operationId: operation, persistence: persistence,
                requireContext: {}, readActual: { before }, readAmendments: { [] }, send: { _ in sent += 1 })
            XCTFail("Failed durable request cannot dispatch")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cannotWriteToFile) }
        XCTAssertEqual(sent, 0)
    }

    func testReentrantAmendmentCannotReplaceOrDispatchOriginalInFlightRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try actual(), operation = UUID(), actor = UUID()
        let persistence = PersistenceStore(directory: directory)
        var nestedDispatches = 0
        do {
            _ = try await GuidedActualUseCorrection.reconcileAmendment(original: before, owner: actor,
                vineyard: before.vineyardId, reason: "Verified original operator paper record", water: 350,
                chemicals: before.chemicals, operationId: operation, persistence: persistence,
                requireContext: {}, readActual: { before }, readAmendments: {
                    do {
                        _ = try await GuidedActualUseCorrection.reconcileAmendment(original: before, owner: actor,
                            vineyard: before.vineyardId, reason: "Verified original operator paper record", water: 351,
                            chemicals: before.chemicals, operationId: operation, persistence: persistence,
                            requireContext: {}, readActual: { before }, readAmendments: { [] }, send: { _ in
                                nestedDispatches += 1
                                throw URLError(.networkConnectionLost)
                            })
                        XCTFail("A concurrent request must be refused")
                    } catch { XCTAssertTrue(error is GuidedActualUseCorrection.Rejected) }
                    return []
                }, send: { _ in throw URLError(.notConnectedToInternet) })
            XCTFail("Offline request cannot verify success")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(nestedDispatches, 0)
        let frozen = try XCTUnwrap(GuidedActualUseCorrection.savedAmendment(operation, persistence: persistence))
        XCTAssertEqual(frozen.request.p_water_volume_l, 350, "The first reviewed input must survive")
    }

    func testCompleteChemicalAndNullWaterReceiptRequired() async throws {
        let before = try actual(), operation = UUID(), actor = UUID()
        let amounts = Dictionary(uniqueKeysWithValues: before.chemicals.map { ($0.id, "0") })
        let chemicals = try GuidedActualUseCorrection.reviewedChemicals(original: before.chemicals, amounts: amounts)
        let request = GuidedActualUseCorrection.Requested(p_operation_id: operation, p_actual_id: before.id,
            p_trip_id: before.tripId, p_spray_record_id: before.sprayRecordId,
            p_tank_session_id: before.tankSessionId, p_tank_number: 1, p_expected_version: 1,
            p_water_volume_l: nil, p_chemicals: chemicals)
        let saved = GuidedActualUseCorrection.AmendmentAttempt(owner: actor, vineyard: before.vineyardId,
            reason: "Verified original operator paper record", original: before, request: request)
        let remote = try SprayTankActual(id: before.id, vineyardId: before.vineyardId,
            sprayRecordId: before.sprayRecordId, tripId: before.tripId,
            tankSessionId: before.tankSessionId, tankNumber: 1, waterVolumeL: nil,
            chemicals: chemicals, confirmedAt: before.confirmedAt, confirmedBy: before.confirmedBy, correctionVersion: 2)
        var rows = [GuidedActualUseCorrection.AmendmentRow(operation_id: operation,
            vineyard_id: before.vineyardId, trip_id: before.tripId, spray_record_id: before.sprayRecordId,
            spray_tank_actual_id: before.id, tank_number: 1, chemical_actual_id: nil,
            field_name: "actualWaterLitres", previous_value: .number(450), new_value: .null,
            revision: 2, edited_by: actor)]
        for (previous, next) in zip(before.chemicals, chemicals) {
            rows.append(GuidedActualUseCorrection.AmendmentRow(operation_id: operation,
                vineyard_id: before.vineyardId, trip_id: before.tripId, spray_record_id: before.sprayRecordId,
                spray_tank_actual_id: before.id, tank_number: 1, chemical_actual_id: previous.id,
                field_name: "actualChemical",
                previous_value: try JSONDecoder().decode(TripActivityCancellation.JSON.self, from: JSONEncoder().encode(previous)),
                new_value: try JSONDecoder().decode(TripActivityCancellation.JSON.self, from: JSONEncoder().encode(next)),
                revision: 2, edited_by: actor))
        }
        XCTAssertNoThrow(try GuidedActualUseCorrection.verifyAmendment(saved, remote: remote, rows: rows))
        XCTAssertThrowsError(try GuidedActualUseCorrection.verifyAmendment(saved, remote: remote, rows: Array(rows.dropLast())))
        XCTAssertThrowsError(try GuidedActualUseCorrection.verifyAmendment(saved, remote: remote, rows: rows + [rows[1]]))
        XCTAssertThrowsError(try GuidedActualUseCorrection.verifyAmendment(saved, remote: remote, rows: [rows[0], rows[1], rows[1]]))
    }

    func testScopeChangeAfterDispatchRetainsOriginalWithoutAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try actual(), operation = UUID(), actor = UUID()
        let persistence = PersistenceStore(directory: directory)
        var contextIsCurrent = true, sent = 0, reads = 0
        do {
            _ = try await GuidedActualUseCorrection.reconcileAmendment(original: before, owner: actor,
                vineyard: before.vineyardId, reason: "Verified original operator paper record", water: 350,
                chemicals: before.chemicals, operationId: operation, persistence: persistence,
                requireContext: { if !contextIsCurrent { throw CancellationError() } },
                readActual: { reads += 1; return before }, readAmendments: { [] }, send: { _ in
                    sent += 1; contextIsCurrent = false
                })
            XCTFail("Changed scope cannot acknowledge a sent request")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(reads, 1, "Do not continue receipt reads in the changed scope")
        let frozen = try XCTUnwrap(GuidedActualUseCorrection.savedAmendment(operation, persistence: persistence))
        XCTAssertEqual(frozen.request.p_operation_id, operation)
        XCTAssertEqual(frozen.request.p_expected_version, 1)
        XCTAssertEqual(frozen.original, before)
    }

    func testAmendmentReceiptRejectsWrongActorVersionBeforeAfterAndDuplicates() async throws {
        let before = try actual(), operation = UUID(), actor = UUID()
        let request = GuidedActualUseCorrection.Requested(p_operation_id: operation, p_actual_id: before.id,
            p_trip_id: before.tripId, p_spray_record_id: before.sprayRecordId,
            p_tank_session_id: before.tankSessionId, p_tank_number: 1, p_expected_version: 1,
            p_water_volume_l: 350, p_chemicals: before.chemicals)
        let saved = GuidedActualUseCorrection.AmendmentAttempt(owner: actor, vineyard: before.vineyardId,
            reason: "Verified original operator paper record", original: before, request: request)
        let remote = try SprayTankActual(id: before.id, vineyardId: before.vineyardId,
            sprayRecordId: before.sprayRecordId, tripId: before.tripId,
            tankSessionId: before.tankSessionId, tankNumber: 1, waterVolumeL: 350,
            chemicals: before.chemicals, confirmedAt: before.confirmedAt, confirmedBy: before.confirmedBy, correctionVersion: 2)
        var valid: GuidedActualUseCorrection.AmendmentRow?
        for variation in 0..<6 {
            let row = GuidedActualUseCorrection.AmendmentRow(operation_id: variation == 1 ? UUID() : operation,
                vineyard_id: before.vineyardId, trip_id: before.tripId, spray_record_id: before.sprayRecordId,
                spray_tank_actual_id: before.id, tank_number: 1, chemical_actual_id: nil,
                field_name: "actualWaterLitres", previous_value: .number(variation == 4 ? 451 : 450),
                new_value: .number(variation == 5 ? 351 : 350), revision: variation == 3 ? 3 : 2,
                edited_by: variation == 2 ? UUID() : actor)
            if variation == 0 {
                valid = row
                XCTAssertNoThrow(try GuidedActualUseCorrection.verifyAmendment(saved, remote: remote, rows: [row]))
            } else { XCTAssertThrowsError(try GuidedActualUseCorrection.verifyAmendment(saved, remote: remote, rows: [row])) }
        }
        let row = try XCTUnwrap(valid)
        XCTAssertThrowsError(try GuidedActualUseCorrection.verifyAmendment(saved, remote: remote, rows: [row, row]))
        XCTAssertThrowsError(try GuidedActualUseCorrection.verifyAmendment(saved, remote: remote, rows: []))
        XCTAssertThrowsError(try GuidedActualUseCorrection.verifyAmendment(saved, remote: before, rows: [row]))
    }

    func testManualTankTimeRequiresEvidenceAndOriginalTripBounds() {
        let begin = Date(timeIntervalSince1970: 1_793_660_000)
        let end = begin.addingTimeInterval(7200)
        let confirmed = begin.addingTimeInterval(400)
        let note = "Checked the original paper spray book."
        XCTAssertNil(GuidedRepairFieldValidation.manualTankTime(
            begin.addingTimeInterval(200),
            tripStart: begin, tripEnd: end,
            originalConfirmedAt: confirmed, reason: note))
        XCTAssertNotNil(GuidedRepairFieldValidation.manualTankTime(
            begin.addingTimeInterval(-1),
            tripStart: begin, tripEnd: end,
            originalConfirmedAt: confirmed, reason: note))
        XCTAssertNotNil(GuidedRepairFieldValidation.manualTankTime(
            confirmed.addingTimeInterval(1),
            tripStart: begin, tripEnd: end,
            originalConfirmedAt: confirmed, reason: note))
        XCTAssertNotNil(GuidedRepairFieldValidation.manualTankTime(
            begin.addingTimeInterval(200),
            tripStart: begin, tripEnd: end,
            originalConfirmedAt: confirmed, reason: ""))
    }

    func testAuditLedgerIsDurableAndRetriesExactOriginalOperationId() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let account = UUID(), vineyard = UUID(), record = UUID()
        let original = GuidedRepairAuditLedger(persistence: persistence)
        let review = GuidedRepairReviewInput(reason: "Confirmed original record from spray log", water: nil,
            chemicals: nil, tankTime: nil, sessionId: nil, applied: true, recordedNotApplied: false)
        let operation = try original.begin(
            account: account, vineyard: vineyard, record: record,
            correction: "reviewLegacyDeleted", inputHash: "fingerprint",
            reason: "Confirmed original record from spray log", reviewInput: review)
        try original.stage(
            id: operation, account: account, vineyard: vineyard,
            code: "RETAINS_ISSUE_READ_FAILED",
            explanation: "Server receipt read could not be completed")
        let reloaded = GuidedRepairAuditLedger(persistence: persistence)
        let retried = try reloaded.begin(
            account: account, vineyard: vineyard, record: record,
            correction: "reviewLegacyDeleted", inputHash: "fingerprint",
            reason: "Confirmed original record from spray log", reviewInput: review)
        XCTAssertEqual(operation, retried,
            "A lost response must reuse the same idempotent server operation")
        try reloaded.stage(
            id: retried, account: account, vineyard: vineyard,
            code: "VERIFIED", explanation: "Independent original receipt")
        let next = try reloaded.begin(
            account: account, vineyard: vineyard, record: record,
            correction: "reviewLegacyDeleted", inputHash: "fingerprint",
            reason: "Confirmed original record from spray log", reviewInput: review)
        XCTAssertNotEqual(operation, next)
    }
}
