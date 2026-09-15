import Foundation
import XCTest
@testable import VineTrack

/// Read-only observability coverage for the Sync Diagnostics spray section.
/// XCTest so `-only-testing` can select and execute it.
final class SprayFinalisationDiagnosticsTests: XCTestCase {

    private func tripInput(
        pendingParent: Bool = false,
        sprayRecordPending: Bool = false,
        pendingActuals: Int = 0,
        tripPending: Bool = true
    ) -> SprayFinalisationDiagnostics.TripInput {
        SprayFinalisationDiagnostics.TripInput(
            tripId: UUID(),
            sprayRecordId: UUID(),
            isActive: false,
            hasEndTime: true,
            tripPendingUpsert: tripPending,
            parentEstablished: !pendingParent,
            isPhase5Held: pendingActuals > 0,
            pendingActualCount: pendingActuals,
            sprayRecordPending: sprayRecordPending
        )
    }

    func testFinalisationStatusResolvesInDependencyOrder() {
        XCTAssertEqual(
            tripInput(pendingParent: true, sprayRecordPending: true, pendingActuals: 2).status,
            .waitingForTripParent
        )
        XCTAssertEqual(tripInput(sprayRecordPending: true, pendingActuals: 2).status, .waitingForSprayRecord)
        XCTAssertEqual(tripInput(pendingActuals: 2).status, .waitingForTankActuals)
        XCTAssertEqual(tripInput().status, .readyForFinalTripSync)
        XCTAssertEqual(tripInput(tripPending: false).status, .fullySynced)
    }

    func testPendingParentCreationIsSeparateFromGenericPending() {
        XCTAssertTrue(tripInput(pendingParent: true).isPendingParentCreation)
        // Queued only for finalisation is NOT pending parent creation.
        XCTAssertFalse(tripInput().isPendingParentCreation)
    }

    func testPendingButNotFailedTripIsStillReported() {
        // The production incident had failed_items = 0 while records sat pending.
        let held = tripInput(pendingActuals: 1)
        XCTAssertTrue(held.isRelevant)
        let synced = tripInput(tripPending: false)
        XCTAssertFalse(synced.isRelevant)
        XCTAssertEqual(SprayFinalisationDiagnostics.relevantTrips([held, synced]).count, 1)
    }

    private func actual(
        parentBlocked: Bool,
        recordPending: Bool,
        kind: SyncFailureKind? = nil
    ) -> SprayFinalisationDiagnostics.TankActualInput {
        SprayFinalisationDiagnostics.TankActualInput(
            actualId: UUID(),
            tripId: UUID(),
            sprayRecordId: UUID(),
            tankNumber: 1,
            tankSessionId: "tank-1",
            isPending: true,
            parentTripBlocked: parentBlocked,
            sprayRecordPending: recordPending,
            failureKind: kind
        )
    }

    func testTankActualSkipReasonsDistinguishWaitingFromFailure() {
        XCTAssertEqual(actual(parentBlocked: true, recordPending: false).skipReason, "trip_parent_not_established")
        XCTAssertEqual(actual(parentBlocked: false, recordPending: true).skipReason, "spray_record_still_pending")
        XCTAssertEqual(actual(parentBlocked: false, recordPending: false).skipReason, "ready_to_upload")
        XCTAssertEqual(
            actual(parentBlocked: false, recordPending: false, kind: .retryable).skipReason,
            "retryable_upload_failure"
        )
        XCTAssertEqual(
            actual(parentBlocked: false, recordPending: false, kind: .permanent).skipReason,
            "permanent_failure"
        )
    }

    func testCarrierBasisDiagnosticShowsConversionAndUnsupported() {
        let converted = SprayFinalisationDiagnostics.CarrierBasisInput(sprayRecordId: UUID(), localBasisRaw: "manual")
        XCTAssertTrue(converted.didConvert)
        XCTAssertFalse(converted.isUnsupported)
        XCTAssertTrue(converted.lines.contains("  carrier_basis_local: manual"))
        XCTAssertTrue(converted.lines.contains("  carrier_basis_server: manual_actual_total"))
        XCTAssertTrue(converted.lines.contains("  carrier_basis_conversion: yes"))

        let unsupported = SprayFinalisationDiagnostics.CarrierBasisInput(
            sprayRecordId: UUID(),
            localBasisRaw: "whole_block"
        )
        XCTAssertTrue(unsupported.isUnsupported)
        XCTAssertTrue(unsupported.lines.contains("  carrier_basis_server: NULL"))
        XCTAssertTrue(unsupported.lines.contains("  carrier_basis_status: unsupported"))

        let clean = SprayFinalisationDiagnostics.CarrierBasisInput(sprayRecordId: UUID(), localBasisRaw: "l_per_ha")
        XCTAssertFalse(clean.didConvert)
        XCTAssertFalse(clean.isUnsupported)
        XCTAssertTrue(clean.lines.contains("  carrier_basis_server: l_per_ha"))
    }

    func testReportSummarisesCountsWithoutSensitiveContent() {
        let tripId = UUID()
        let sprayRecordId = UUID()
        let trip = SprayFinalisationDiagnostics.TripInput(
            tripId: tripId,
            sprayRecordId: sprayRecordId,
            isActive: false,
            hasEndTime: true,
            tripPendingUpsert: true,
            parentEstablished: true,
            isPhase5Held: true,
            pendingActualCount: 1,
            sprayRecordPending: false
        )
        let pendingActual = SprayFinalisationDiagnostics.TankActualInput(
            actualId: UUID(),
            tripId: tripId,
            sprayRecordId: sprayRecordId,
            tankNumber: 2,
            tankSessionId: "tank-2",
            isPending: true,
            parentTripBlocked: false,
            sprayRecordPending: false
        )
        let carrier = SprayFinalisationDiagnostics.CarrierBasisInput(
            sprayRecordId: sprayRecordId,
            localBasisRaw: "manual"
        )
        let summary = SprayFinalisationDiagnostics.summary(
            trips: [trip],
            actuals: [pendingActual],
            carriers: [carrier],
            sprayRecordsPending: 1,
            retryableFailures: 0,
            permanentFailures: 0
        )
        XCTAssertEqual(summary.tripsPending, 1)
        XCTAssertEqual(summary.tripsPhase5Held, 1)
        XCTAssertEqual(summary.tripsWaitingForParent, 0)
        XCTAssertEqual(summary.tankActualsPending, 1)
        XCTAssertEqual(summary.sprayRecordsPending, 1)
        XCTAssertEqual(summary.carrierBasisConversions, 1)
        XCTAssertEqual(summary.carrierBasisUnsupported, 0)
        XCTAssertEqual(summary.failedItems, 0)

        let report = SprayFinalisationDiagnostics.report(
            trips: [trip],
            actuals: [pendingActual],
            carriers: [carrier],
            summary: summary
        ).joined(separator: "\n")

        XCTAssertTrue(report.contains("Spray Finalisation"))
        XCTAssertTrue(report.contains("waiting_for_tank_actuals"))
        XCTAssertTrue(report.contains("tank_number: 2"))
        XCTAssertTrue(report.contains("tank_session_id: tank-2"))
        XCTAssertTrue(report.contains("carrier_basis_server: manual_actual_total"))
        XCTAssertTrue(report.contains(tripId.uuidString))
        // Content-free: no litres, chemical names, notes or credentials.
        let lowered = report.lowercased()
        XCTAssertFalse(lowered.contains("litre"))
        XCTAssertFalse(lowered.contains("chemical"))
        XCTAssertFalse(lowered.contains("notes"))
        XCTAssertFalse(lowered.contains("token"))
    }

    func testFailureCountsSeparateRetryableFromPermanent() {
        let summary = SprayFinalisationDiagnostics.summary(
            trips: [],
            actuals: [],
            carriers: [],
            sprayRecordsPending: 0,
            retryableFailures: 2,
            permanentFailures: 3
        )
        XCTAssertEqual(summary.retryableFailures, 2)
        XCTAssertEqual(summary.permanentFailures, 3)
        XCTAssertEqual(summary.failedItems, 5)
        XCTAssertTrue(summary.lines.contains("  retryable_failures: 2"))
        XCTAssertTrue(summary.lines.contains("  permanent_failures: 3"))
    }
}
