import XCTest
@testable import VineTrack

/// Focused coverage for the invalid `carrier_volume_basis` defect.
///
/// XCTest (not Swift Testing) so `-only-testing:VineTrackTests/<class>` can
/// actually select and execute these.
@MainActor
final class SprayCarrierBasisSyncContractTests: XCTestCase {

    // MARK: - Canonicalisation

    func testLitresPerHectareUploadsUnchanged() {
        XCTAssertEqual(SprayCarrierBasisSyncContract.serverValue(for: .litresPerHectare), "l_per_ha")
        XCTAssertFalse(SprayCarrierBasisSyncContract.outcome(for: .litresPerHectare).didConvert)
    }

    func testLitresPer100MetresUploadsUnchanged() {
        XCTAssertEqual(SprayCarrierBasisSyncContract.serverValue(for: .litresPer100Metres), "l_per_100m")
        XCTAssertFalse(SprayCarrierBasisSyncContract.outcome(for: .litresPer100Metres).didConvert)
    }

    func testManualTotalVolumeUploadsAsManualActualTotal() {
        // The local enum persists "manual"; the DB CHECK accepts only
        // "manual_actual_total". This mapping is the root-cause fix.
        XCTAssertEqual(SprayCarrierBasis.manualTotalVolume.rawValue, "manual")
        XCTAssertEqual(SprayCarrierBasisSyncContract.serverValue(for: .manualTotalVolume), "manual_actual_total")
        XCTAssertTrue(SprayCarrierBasisSyncContract.outcome(for: .manualTotalVolume).didConvert)
    }

    func testHistoricalManualStringUploadsAsManualActualTotal() {
        XCTAssertEqual(SprayCarrierBasisSyncContract.canonicalise("manual").serverValue, "manual_actual_total")
        XCTAssertEqual(SprayCarrierBasisSyncContract.canonicalise(" MANUAL ").serverValue, "manual_actual_total")
        XCTAssertTrue(SprayCarrierBasisSyncContract.canonicalise("manual").didConvert)
    }

    func testNilBasisUploadsAsNull() {
        XCTAssertNil(SprayCarrierBasisSyncContract.serverValue(for: nil))
        XCTAssertEqual(SprayCarrierBasisSyncContract.outcome(for: nil), .absent)
        XCTAssertEqual(SprayCarrierBasisSyncContract.canonicalise(""), .absent)
        XCTAssertEqual(SprayCarrierBasisSyncContract.canonicalise(nil), .absent)
    }

    func testEveryEmittedValueSatisfiesTheDatabaseContract() {
        for basis in SprayCarrierBasis.allCases {
            let value = SprayCarrierBasisSyncContract.serverValue(for: basis)
            XCTAssertNotNil(value, "\(basis.rawValue) must map to a server value")
            XCTAssertTrue(
                SprayCarrierBasisSyncContract.serverValues.contains(value ?? ""),
                "\(basis.rawValue) produced \(value ?? "nil"), which the CHECK rejects"
            )
        }
    }

    func testUnknownValueIsNeverGuessedIntoAnotherBasis() {
        // Treated-area methods, application modes and chemical rate bases are
        // different columns and must never leak into carrier basis.
        for foreign in ["whole_block", "banded", "spreader", "per_100l", "per_hectare", "band_area", "treated_area"] {
            let outcome = SprayCarrierBasisSyncContract.canonicalise(foreign)
            XCTAssertTrue(outcome.isUnknown, "\(foreign) must not canonicalise")
            XCTAssertNil(outcome.serverValue, "\(foreign) must not become a carrier basis")
            XCTAssertNotEqual(outcome.serverValue, "l_per_ha")
            XCTAssertNotEqual(outcome.serverValue, "l_per_100m")
        }
    }

    func testUnsupportedValueCannotRecreateTheCheckConstraintViolation() {
        for raw in ["manual", "MANUAL", "whole_block", "banded", "per_100l", "", "  ", "garbage"] {
            let sent = SprayCarrierBasisSyncContract.canonicalise(raw).serverValue
            if let sent {
                XCTAssertTrue(
                    SprayCarrierBasisSyncContract.serverValues.contains(sent),
                    "\(raw) would send \(sent) and violate spray_records_carrier_volume_basis_check"
                )
            }
        }
    }

    // MARK: - Read-back

    func testServerValuesDecodeBackIntoLocalEnum() {
        XCTAssertEqual(SprayCarrierBasisSyncContract.basis(fromServerValue: "l_per_ha"), .litresPerHectare)
        XCTAssertEqual(SprayCarrierBasisSyncContract.basis(fromServerValue: "l_per_100m"), .litresPer100Metres)
        XCTAssertEqual(SprayCarrierBasisSyncContract.basis(fromServerValue: "manual_actual_total"), .manualTotalVolume)
    }

    func testHistoricalManualRemainsReadable() {
        XCTAssertEqual(SprayCarrierBasisSyncContract.basis(fromServerValue: "manual"), .manualTotalVolume)
        XCTAssertNil(SprayCarrierBasisSyncContract.basis(fromServerValue: "whole_block"))
        XCTAssertNil(SprayCarrierBasisSyncContract.basis(fromServerValue: nil))
    }

    // MARK: - Real BackendSprayRecord payload

    private func record(basis: SprayCarrierBasis?, mode: SprayApplicationMode?) -> SprayRecord {
        SprayRecord(
            id: UUID(uuidString: "5A000000-0000-4000-8000-000000000001")!,
            tripId: UUID(uuidString: "5A000000-0000-4000-8000-000000000002")!,
            vineyardId: UUID(uuidString: "00BB9A18-28DA-4BA7-9136-B2C5A1B56FB5")!,
            sprayReference: "Estellar",
            notes: "operator notes",
            applicationGeometry: SprayApplicationSnapshot(
                grossAreaHa: 4,
                treatedAreaHa: 3,
                applicationMode: mode,
                treatedAreaMethod: .wholeBlock,
                carrierVolumeBasis: basis,
                totalCarrierLitres: 900
            ),
            sprayJobId: UUID(uuidString: "5A000000-0000-4000-8000-000000000003")!
        )
    }

    func testManualUpsertPayloadEmitsCanonicalValue() {
        let payload = BackendSprayRecord.upsert(
            from: record(basis: .manualTotalVolume, mode: .banded),
            createdBy: nil,
            clientUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        XCTAssertEqual(payload.carrierVolumeBasis, "manual_actual_total")
        XCTAssertNotEqual(payload.carrierVolumeBasis, "manual")
    }

    func testUpsertPayloadKeepsCarrierBasisIndependentOfOtherColumns() {
        let payload = BackendSprayRecord.upsert(
            from: record(basis: .litresPerHectare, mode: .banded),
            createdBy: nil,
            clientUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        // Application method, treated-area basis and band/rate geometry each
        // stay in their own column.
        XCTAssertEqual(payload.carrierVolumeBasis, "l_per_ha")
        XCTAssertEqual(payload.treatedAreaMethod, "whole_block")
        XCTAssertEqual(payload.applicationMode, SprayApplicationMode.banded.rawValue)
        XCTAssertNotEqual(payload.applicationMode, payload.carrierVolumeBasis)
        XCTAssertNotEqual(payload.treatedAreaMethod, payload.carrierVolumeBasis)
        XCTAssertEqual(payload.treatedAreaHa, 3)
        XCTAssertEqual(payload.grossAreaHa, 4)
    }

    func testNilBasisUpsertPayloadSendsNoCarrierBasis() {
        let payload = BackendSprayRecord.upsert(
            from: record(basis: nil, mode: .wholeBlock),
            createdBy: nil,
            clientUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        XCTAssertNil(payload.carrierVolumeBasis)
    }

    func testUpsertPreservesIdentitiesWhileCorrectingBasis() {
        let original = record(basis: .manualTotalVolume, mode: .wholeBlock)
        let payload = BackendSprayRecord.upsert(
            from: original,
            createdBy: UUID(uuidString: "94238371-53C6-472D-975B-48BF98A268A9")!,
            clientUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        XCTAssertEqual(payload.id, original.id)
        XCTAssertEqual(payload.tripId, original.tripId)
        XCTAssertEqual(payload.vineyardId, original.vineyardId)
        XCTAssertEqual(payload.sprayJobId, original.sprayJobId)
        XCTAssertEqual(payload.notes, original.notes)
        XCTAssertEqual(payload.totalCarrierLitres, 900)
    }

    func testBandedPerHundredMetresUnaffected() {
        let payload = BackendSprayRecord.upsert(
            from: record(basis: .litresPer100Metres, mode: .banded),
            createdBy: nil,
            clientUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        XCTAssertEqual(payload.carrierVolumeBasis, "l_per_100m")
    }

    // MARK: - Diagnostics

    func testCarrierDiagnosticReportsConversionWithoutLeakingContent() {
        let id = UUID(uuidString: "5A000000-0000-4000-8000-000000000001")!
        let converted = SprayCarrierSyncDiagnostic(sprayRecordId: id, basis: .manualTotalVolume, applicationMode: "banded")
        XCTAssertTrue(converted.didConvert)
        XCTAssertFalse(converted.wasRejected)
        XCTAssertEqual(converted.attemptedBasis, "manual")
        XCTAssertEqual(converted.canonicalBasis, "manual_actual_total")
        XCTAssertTrue(converted.isNoteworthy)
        XCTAssertFalse(converted.summary.contains("operator notes"))

        let clean = SprayCarrierSyncDiagnostic(sprayRecordId: id, basis: .litresPerHectare, applicationMode: "whole_block")
        XCTAssertFalse(clean.isNoteworthy)
        XCTAssertEqual(clean.canonicalBasis, "l_per_ha")
    }
}
