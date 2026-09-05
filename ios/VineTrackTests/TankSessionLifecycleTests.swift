import Foundation
import XCTest
@testable import VineTrack

final class TankSessionLifecycleTests: XCTestCase {
    private let vineyardID = UUID(uuidString: "81000000-0000-4000-8000-000000000001")!
    private let sessionID = UUID(uuidString: "81000000-0000-4000-8000-000000000002")!
    private let fillStart = Date(timeIntervalSince1970: 1_780_000_000)
    private let fillEnd = Date(timeIntervalSince1970: 1_780_000_060)
    private let sprayStart = Date(timeIntervalSince1970: 1_780_000_120)
    private let sprayEnd = Date(timeIntervalSince1970: 1_780_000_600)

    private func trip(
        sessions: [TankSession] = [],
        activeTankNumber: Int? = nil,
        isFilling: Bool = false,
        fillingTankNumber: Int? = nil
    ) -> Trip {
        Trip(
            id: UUID(uuidString: "81000000-0000-4000-8000-000000000010")!,
            vineyardId: vineyardID,
            paddockName: "Lifecycle block",
            startTime: Date(timeIntervalSince1970: 1_779_999_000),
            currentRowNumber: 4.5,
            isActive: true,
            tankSessions: sessions,
            activeTankNumber: activeTankNumber,
            totalTanks: 2,
            isFillingTank: isFilling,
            fillingTankNumber: fillingTankNumber
        )
    }

    private func fillOnly(completed: Bool) -> TankSession {
        TankSession(
            id: sessionID,
            tankNumber: 1,
            startTime: fillStart,
            fillStartTime: fillStart,
            fillEndTime: completed ? fillEnd : nil
        )
    }

    func testStartWithoutFillCreatesTankOneExactlyOnce() {
        let started = TankSessionLifecycle.start(
            trip: trip(), at: sprayStart, currentRow: 4.5, makeID: { self.sessionID }
        )
        XCTAssertEqual(started.tankSessions.count, 1)
        XCTAssertEqual(started.tankSessions.single?.id, sessionID)
        XCTAssertEqual(started.tankSessions.single?.tankNumber, 1)
        XCTAssertEqual(started.tankSessions.single?.startTime, sprayStart)
        XCTAssertEqual(started.tankSessions.single?.startRow, 4.5)
        XCTAssertEqual(started.activeTankNumber, 1)
        XCTAssertFalse(started.isFillingTank)
        XCTAssertNil(started.fillingTankNumber)

        let repeated = TankSessionLifecycle.start(
            trip: started, at: sprayEnd, currentRow: 5.5, makeID: { UUID() }
        )
        XCTAssertEqual(repeated, started)
    }

    func testCompletedFillOnlyTankOneIsReusedWithoutCreatingTankTwo() {
        let original = fillOnly(completed: true)
        let started = TankSessionLifecycle.start(trip: trip(sessions: [original]), at: sprayStart, currentRow: 6.5)

        XCTAssertEqual(started.tankSessions.count, 1)
        let session = started.tankSessions[0]
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.tankNumber, 1)
        XCTAssertEqual(session.startTime, sprayStart)
        XCTAssertEqual(session.startRow, 6.5)
        XCTAssertEqual(session.fillStartTime, fillStart)
        XCTAssertEqual(session.fillEndTime, fillEnd)
        XCTAssertEqual(started.activeTankNumber, 1)
        XCTAssertFalse(started.isFillingTank)
        XCTAssertNil(started.fillingTankNumber)
        XCTAssertFalse(started.tankSessions.contains { $0.tankNumber == 2 })
    }

    func testRunningFillOnlyTankOneStopsAtOperationTimeAndIsReused() {
        let started = TankSessionLifecycle.start(
            trip: trip(sessions: [fillOnly(completed: false)], isFilling: true, fillingTankNumber: 1),
            at: sprayStart,
            currentRow: 7.5
        )

        XCTAssertEqual(started.tankSessions.count, 1)
        let session = started.tankSessions[0]
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.tankNumber, 1)
        XCTAssertEqual(session.fillStartTime, fillStart)
        XCTAssertEqual(session.fillEndTime, sprayStart)
        XCTAssertEqual(session.fillDuration, sprayStart.timeIntervalSince(fillStart))
        XCTAssertEqual(session.startTime, sprayStart)
        XCTAssertFalse(started.isFillingTank)
        XCTAssertNil(started.fillingTankNumber)
        XCTAssertFalse(started.tankSessions.contains { $0.tankNumber == 2 })
    }

    func testEndTargetsActiveTankAndCancellationAndDoubleConfirmationAreSafe() {
        let unrelatedFill = TankSession(
            id: UUID(uuidString: "81000000-0000-4000-8000-000000000003")!,
            tankNumber: 2,
            startTime: fillStart,
            fillStartTime: fillStart,
            fillEndTime: fillEnd
        )
        var current = TankSessionLifecycle.start(
            trip: trip(sessions: [fillOnly(completed: true)]),
            at: sprayStart,
            currentRow: 8.5
        )
        current.tankSessions.append(unrelatedFill)
        let beforeCancellation = current
        var controls = TankControlInteractionState()
        controls.tapEnd()
        controls.cancelEnd()
        XCTAssertEqual(current, beforeCancellation)

        controls.tapEnd()
        controls.confirmEnd {
            current = TankSessionLifecycle.end(trip: current, at: sprayEnd, currentRow: 12.5)
        }
        XCTAssertEqual(current.tankSessions[0].endTime, sprayEnd)
        XCTAssertEqual(current.tankSessions[0].endRow, 12.5)
        XCTAssertNil(current.activeTankNumber)
        XCTAssertNil(current.tankSessions[1].endTime)

        let afterFirstConfirmation = current
        controls.confirmEnd {
            current = TankSessionLifecycle.end(trip: current, at: sprayEnd.addingTimeInterval(1), currentRow: 13.5)
        }
        XCTAssertEqual(current, afterFirstConfirmation)
    }

    @MainActor
    func testRelaunchOfflinePayloadAndCanonicalContractPreserveReusedClosedSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tank-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = TankSessionLifecycle.start(
            trip: trip(sessions: [fillOnly(completed: true)]), at: sprayStart, currentRow: 9.5
        )
        let closed = TankSessionLifecycle.end(trip: started, at: sprayEnd, currentRow: 14.5)
        let persistence = PersistenceStore(directory: directory)
        TripRepository(persistence: persistence).saveSlice([closed], for: vineyardID)
        let relaunched = try XCTUnwrap(TripRepository(persistence: persistence).load(for: vineyardID).single)
        XCTAssertEqual(relaunched, closed)

        let replayBytes = try JSONEncoder().encode(relaunched)
        let replayed = try JSONDecoder().decode(Trip.self, from: replayBytes)
        let session = try XCTUnwrap(replayed.tankSessions.single)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.tankNumber, 1)
        XCTAssertEqual(session.fillStartTime, fillStart)
        XCTAssertEqual(session.fillEndTime, fillEnd)
        XCTAssertEqual(session.startTime, sprayStart)
        XCTAssertEqual(session.endTime, sprayEnd)
        XCTAssertEqual(session.endRow, 14.5)
        XCTAssertNil(replayed.activeTankNumber)
        XCTAssertFalse(replayed.isFillingTank)
        XCTAssertNil(replayed.fillingTankNumber)

        let payload = BackendTrip.upsert(from: replayed, createdBy: nil, clientUpdatedAt: sprayEnd)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let sessions = try XCTUnwrap(json["tank_sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["tankNumber"] as? Int, 1)
        XCTAssertEqual(json["active_tank_number"] as? Int, nil)
        XCTAssertEqual(json["is_filling_tank"] as? Bool, false)
    }
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}
