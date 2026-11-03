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

    func testUnresolvedCorrectionCannotMintCompetingOperationAfterReopen() throws {
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

    func testFrozenReviewedInputsSurviveReopenWithSameOperation() throws {
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

    func testAuditLedgerIsDurableAndRetriesExactOriginalOperationId() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let account = UUID(), vineyard = UUID(), record = UUID()
        let original = GuidedRepairAuditLedger(persistence: persistence)
        let operation = try original.begin(
            account: account, vineyard: vineyard, record: record,
            correction: "reviewLegacyDeleted", inputHash: "fingerprint",
            reason: "Confirmed original record from spray log")
        try original.stage(
            id: operation, account: account, vineyard: vineyard,
            code: "RETAINS_ISSUE_READ_FAILED",
            explanation: "Server receipt read could not be completed")
        let reloaded = GuidedRepairAuditLedger(persistence: persistence)
        let retried = try reloaded.begin(
            account: account, vineyard: vineyard, record: record,
            correction: "reviewLegacyDeleted", inputHash: "fingerprint",
            reason: "Confirmed original record from spray log")
        XCTAssertEqual(operation, retried,
            "A lost response must reuse the same idempotent server operation")
        try reloaded.stage(
            id: retried, account: account, vineyard: vineyard,
            code: "VERIFIED", explanation: "Independent original receipt")
        let next = try reloaded.begin(
            account: account, vineyard: vineyard, record: record,
            correction: "reviewLegacyDeleted", inputHash: "fingerprint",
            reason: "Confirmed original record from spray log")
        XCTAssertNotEqual(operation, next)
    }
}
