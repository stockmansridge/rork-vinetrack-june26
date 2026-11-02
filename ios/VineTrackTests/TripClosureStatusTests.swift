import Foundation
import XCTest
@testable import VineTrack

/// P0 Phase C: mirrors Android `TripClosureStatusPhaseCTest` case for case.
final class TripClosureStatusTests: XCTestCase {
    private let session = "30259F0A-E2E2-41A2-8FBF-4569028A6F45"

    private func input(
        evidence: TripClosureStatus.ServerEvidence = .freshRead,
        active: Bool = false,
        end: Date? = Date(timeIntervalSince1970: 1_793_600_000),
        serverSessions: Set<String>? = nil,
        useDefaultServerSessions: Bool = true,
        locallyEnded: Bool = false,
        markers: [TripClosureStatus.Marker] = [],
        occurrence: Int? = 0,
        occurrenceHeld: String? = nil,
        actualSessions: Set<String>? = nil,
        pendingActuals: [String] = [],
        holds: [String] = []
    ) -> TripClosureStatus.Input {
        TripClosureStatus.Input(
            tripId: "3bfb7f81-2ae2-4f33-8fd8-6666b2b45393", evidence: evidence,
            serverIsActive: active, serverEndTime: end,
            serverSessionIds: useDefaultServerSessions ? [session.lowercased()] : serverSessions,
            locallyEnded: locallyEnded, unresolvedMarkers: markers,
            occurrencePending: occurrence, occurrenceHeldReason: occurrenceHeld,
            actualSessionIds: actualSessions ?? [session], pendingActualIds: pendingActuals, holdCodes: holds)
    }

    func testAllAcknowledgedAndTerminalIsClosedSynced() {
        let r = TripClosureStatus.evaluate(input())
        XCTAssertEqual(r.state, .closedSynced)
        XCTAssertTrue(r.reasons.isEmpty)
    }

    func testLocalEndPendingIsNeverSynced() {
        XCTAssertEqual(TripClosureStatus.evaluate(input(locallyEnded: true)).state, .localEndPending)
    }

    func testServerActiveIsNotClosed() {
        XCTAssertEqual(TripClosureStatus.evaluate(input(active: true, end: nil)).state, .active)
    }

    func testPendingActualBlocksClosure() {
        XCTAssertEqual(TripClosureStatus.evaluate(input(pendingActuals: ["2b07a0ce"])).state, .dependentsPending)
    }

    func testPendingTripMarkerBlocksClosure() {
        XCTAssertEqual(TripClosureStatus.evaluate(input(markers: [.init(entityType: "trip", status: "pending")])).state, .dependentsPending)
    }

    func testFailedMarkerIsHeld() {
        XCTAssertEqual(TripClosureStatus.evaluate(input(markers: [.init(entityType: "spray_record", status: "failed")])).state, .dependentsHeld)
    }

    func testMissingRequiredSessionOnServerIsHeld() {
        let r = TripClosureStatus.evaluate(input(serverSessions: [], useDefaultServerSessions: false))
        XCTAssertEqual(r.state, .dependentsHeld)
        XCTAssertTrue(r.reasons.contains(TankDependencyVerification.requiredSessionMissing))
    }

    func testOccurrenceOperationsBlockClosure() {
        XCTAssertEqual(TripClosureStatus.evaluate(input(occurrence: 1)).state, .dependentsPending)
        XCTAssertEqual(TripClosureStatus.evaluate(input(occurrence: nil)).state, .dependentsHeld)
        XCTAssertEqual(TripClosureStatus.evaluate(input(occurrenceHeld: "X")).state, .dependentsHeld)
    }

    func testFailedOrAbsentServerReadIsUnconfirmed() {
        XCTAssertEqual(TripClosureStatus.evaluate(input(evidence: .readFailed)).state, .serverStateUnconfirmed)
        XCTAssertEqual(TripClosureStatus.evaluate(input(evidence: .absent)).state, .serverStateUnconfirmed)
    }

    func testDependencyHoldIsHeld() {
        XCTAssertEqual(TripClosureStatus.evaluate(input(holds: [TankDependencyVerification.patchReadbackMismatch])).state, .dependentsHeld)
    }

    func testNoActualsTripClosesWithoutSessions() {
        let r = TripClosureStatus.evaluate(input(serverSessions: [], useDefaultServerSessions: false, actualSessions: []))
        XCTAssertEqual(r.state, .closedSynced)
    }
}
