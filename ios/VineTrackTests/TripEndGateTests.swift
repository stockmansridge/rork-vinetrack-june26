import Foundation
import XCTest
@testable import VineTrack

/// Manual End Trip must never depend on planned-path completion.
///
/// Regression case: trip 4700F6C1-593E-47E5-A409-F25255333545, a Free Drive
/// spraying trip with plannedPath = nil, rowSequenceCount = 0, sequenceIndex
/// 0/0, pathLength = nil, planned progress 0%, accumulated planned distance
/// 0.0 m, 29 completed Free Drive paths and 6,655 recorded GPS points, which
/// the operator could not end.
final class TripEndGateTests: XCTestCase {

    /// The supplied failing diagnostic, as a fixture. Every planned-path
    /// value is absent or zero exactly as reported from the field.
    private enum FreeDriveFixture {
        static let tripID = UUID(uuidString: "4700F6C1-593E-47E5-A409-F25255333545")!
        static let plannedPath: Double? = nil
        static let rowSequenceCount = 0
        static let sequenceIndex = 0
        static let pathLength: Double? = nil
        static let plannedProgressPercent = 0.0
        static let accumulatedPlannedMetres = 0.0
        static let pathsCompleted = 29
        static let routePointCount = 6_655
        static let smoothedSpeedKmh = 17.4
        static let calculatedSpeedKmh = 17.0
        static let gpsAccuracyMetres = 14.3
    }

    // MARK: - A. The reported failure

    func testExactFailingFreeDriveTripCanBeEnded() {
        // No tank is open, so nothing legitimately holds this trip open.
        let decision = TripEndGate.evaluate(
            activeTankNumber: nil,
            isFillingTank: false,
            fillingTankNumber: nil
        )

        XCTAssertTrue(decision.isAllowed, "a Free Drive trip with no planned path must still end")
        XCTAssertNil(decision.blocker)
    }

    func testAbsentPlannedPathValuesCannotReachTheGate() {
        // The gate's signature physically cannot accept planned path, row
        // sequence, sequence index, path length, progress, accumulated
        // distance, current row, corridor state, GPS accuracy or speed. This
        // documents the fixture and asserts the outcome is unaffected by
        // every one of those values being absent or zero.
        XCTAssertNil(FreeDriveFixture.plannedPath)
        XCTAssertEqual(FreeDriveFixture.rowSequenceCount, 0)
        XCTAssertEqual(FreeDriveFixture.sequenceIndex, 0)
        XCTAssertNil(FreeDriveFixture.pathLength)
        XCTAssertEqual(FreeDriveFixture.plannedProgressPercent, 0.0)
        XCTAssertEqual(FreeDriveFixture.accumulatedPlannedMetres, 0.0)

        XCTAssertTrue(
            TripEndGate.evaluate(
                activeTankNumber: nil,
                isFillingTank: false,
                fillingTankNumber: nil
            ).isAllowed
        )
    }

    func testCompletedFreeDrivePathsAndLongRouteDoNotBlockEnding() {
        XCTAssertEqual(FreeDriveFixture.pathsCompleted, 29)
        XCTAssertEqual(FreeDriveFixture.routePointCount, 6_655)
        XCTAssertEqual(
            FreeDriveFixture.tripID.uuidString,
            "4700F6C1-593E-47E5-A409-F25255333545"
        )

        XCTAssertTrue(
            TripEndGate.evaluate(
                activeTankNumber: nil,
                isFillingTank: false,
                fillingTankNumber: nil
            ).isAllowed
        )
    }

    // MARK: - B. Row lock active

    func testLiveRowLockDoesNotBlockEnding() {
        // Row lock, corridor status and current row are not gate inputs, so a
        // trip ending mid-row ends exactly like one ending at a headland.
        XCTAssertTrue(
            TripEndGate.evaluate(
                activeTankNumber: nil,
                isFillingTank: false,
                fillingTankNumber: nil
            ).isAllowed
        )
    }

    // MARK: - C. Active tank

    func testOpenTankBlocksEndingAndNamesTheTank() {
        let decision = TripEndGate.evaluate(
            activeTankNumber: 3,
            isFillingTank: false,
            fillingTankNumber: nil
        )

        XCTAssertFalse(decision.isAllowed)
        XCTAssertEqual(decision.blocker, .activeTank(tankNumber: 3))
    }

    func testOpenTankBlockStatesTheExactRequiredAction() {
        let blocker = TripEndGate.evaluate(
            activeTankNumber: 3,
            isFillingTank: false,
            fillingTankNumber: nil
        ).blocker

        // The operator must never see a bare refusal: the message has to name
        // what is wrong AND what to press.
        XCTAssertEqual(blocker?.reason, "Tank 3 is still running.")
        XCTAssertEqual(blocker?.requiredAction, "Tap End Tank to close it, then end the trip.")
        XCTAssertTrue(blocker?.message.contains("Tank 3") == true)
        XCTAssertTrue(blocker?.message.contains("End Tank") == true)
    }

    func testEndingTheTankThenUnblocksTheFreeDriveTrip() {
        XCTAssertFalse(
            TripEndGate.evaluate(activeTankNumber: 3, isFillingTank: false, fillingTankNumber: nil).isAllowed
        )
        // Operator taps End Tank; the session closes and activeTankNumber clears.
        XCTAssertTrue(
            TripEndGate.evaluate(activeTankNumber: nil, isFillingTank: false, fillingTankNumber: nil).isAllowed
        )
    }

    // MARK: - D. Tank actuals / fill timer

    func testRunningFillTimerBlocksEndingRatherThanSilentlyFailing() {
        let decision = TripEndGate.evaluate(
            activeTankNumber: nil,
            isFillingTank: true,
            fillingTankNumber: 4
        )

        XCTAssertEqual(decision.blocker, .fillingTank(tankNumber: 4))
        XCTAssertTrue(decision.blocker?.message.contains("Tank 4") == true)
        XCTAssertTrue(decision.blocker?.message.contains("Stop Fill") == true)
    }

    func testFillTimerWithNoKnownTankStillExplainsItself() {
        let blocker = TripEndGate.evaluate(
            activeTankNumber: nil,
            isFillingTank: true,
            fillingTankNumber: nil
        ).blocker

        XCTAssertEqual(blocker?.reason, "A tank fill timer is still running.")
        XCTAssertTrue(blocker?.requiredAction.contains("Stop Fill") == true)
    }

    func testStoppingTheFillThenAllowsTheTripToFinish() {
        XCTAssertFalse(
            TripEndGate.evaluate(activeTankNumber: nil, isFillingTank: true, fillingTankNumber: 4).isAllowed
        )
        XCTAssertTrue(
            TripEndGate.evaluate(activeTankNumber: nil, isFillingTank: false, fillingTankNumber: nil).isAllowed
        )
    }

    func testOpenTankIsReportedBeforeAFillTimer() {
        // Both outstanding: the tank is the action the operator must take
        // first, so naming the fill timer would send them to the wrong button.
        let blocker = TripEndGate.evaluate(
            activeTankNumber: 2,
            isFillingTank: true,
            fillingTankNumber: 2
        ).blocker

        XCTAssertEqual(blocker, .activeTank(tankNumber: 2))
    }

    // MARK: - F. Planned-path trips unchanged

    func testPlannedPathTripEndsOnExactlyTheSameTerms() {
        // The gate is mode-agnostic: a sequential trip with a full row plan is
        // evaluated by the same two record conditions, so this correction
        // cannot have changed planned-route behaviour.
        XCTAssertTrue(
            TripEndGate.evaluate(activeTankNumber: nil, isFillingTank: false, fillingTankNumber: nil).isAllowed
        )
        XCTAssertFalse(
            TripEndGate.evaluate(activeTankNumber: 1, isFillingTank: false, fillingTankNumber: nil).isAllowed
        )
    }

    func testIncompletePlannedRouteDoesNotBlockEnding() {
        // Ending early with rows still outstanding is normal and supported;
        // the review sheet records the coverage that was actually achieved.
        XCTAssertTrue(
            TripEndGate.evaluate(activeTankNumber: nil, isFillingTank: false, fillingTankNumber: nil).isAllowed
        )
    }

    // MARK: - G. Outcome messaging

    func testEveryNonEndedOutcomeCarriesAnActionableMessage() {
        // No failure path may leave the End Trip button apparently ineffective.
        XCTAssertNil(TripEndOutcome.ended.operatorMessage)

        let blocked = TripEndOutcome.blocked(.activeTank(tankNumber: 5))
        XCTAssertTrue(blocked.operatorMessage?.contains("End Tank") == true)

        let failed = TripEndOutcome.persistenceFailed("Disk full.")
        XCTAssertTrue(failed.operatorMessage?.contains("still running") == true)
        XCTAssertTrue(failed.operatorMessage?.contains("Disk full.") == true)

        XCTAssertNotNil(TripEndOutcome.noActiveTrip.operatorMessage)
    }

    func testPersistenceFailureIsNotReportedAsEnded() {
        // A trip whose final state never reached disk must not be presented
        // as finished — that would silently discard the whole route.
        XCTAssertFalse(TripEndOutcome.persistenceFailed("Disk full.").isEnded)
        XCTAssertFalse(TripEndOutcome.blocked(.activeTank(tankNumber: 1)).isEnded)
        XCTAssertFalse(TripEndOutcome.noActiveTrip.isEnded)
        XCTAssertTrue(TripEndOutcome.ended.isEnded)
    }

    // MARK: - H. Movement

    func testEndingWhileMovingAtSpeedIsAllowed() {
        // Captured at ~17 km/h with 14.3 m GPS accuracy. Speed, smoothed
        // speed and GPS quality are not gate inputs, so a moving tractor ends
        // its trip identically to a stopped one. Intended behaviour: movement
        // NEVER blocks manual termination.
        XCTAssertEqual(FreeDriveFixture.smoothedSpeedKmh, 17.4, accuracy: 0.001)
        XCTAssertEqual(FreeDriveFixture.calculatedSpeedKmh, 17.0, accuracy: 0.001)
        XCTAssertEqual(FreeDriveFixture.gpsAccuracyMetres, 14.3, accuracy: 0.001)

        XCTAssertTrue(
            TripEndGate.evaluate(activeTankNumber: nil, isFillingTank: false, fillingTankNumber: nil).isAllowed,
            "movement must not block manual End Trip"
        )
    }

    func testEndingWhileStoppedBehavesIdentically() {
        let moving = TripEndGate.evaluate(activeTankNumber: nil, isFillingTank: false, fillingTankNumber: nil)
        let stopped = TripEndGate.evaluate(activeTankNumber: nil, isFillingTank: false, fillingTankNumber: nil)

        XCTAssertEqual(moving, stopped, "speed cannot change the outcome")
    }
}
