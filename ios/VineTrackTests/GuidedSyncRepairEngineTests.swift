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
