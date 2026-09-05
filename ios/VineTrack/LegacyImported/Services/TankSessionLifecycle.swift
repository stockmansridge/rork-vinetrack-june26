import Foundation

/// Deterministic production transitions for operator-driven tank spraying.
nonisolated enum TankSessionLifecycle {
    static func start(
        trip: Trip,
        at timestamp: Date,
        currentRow: Double?,
        plannedTankNumbers: [Int]? = nil,
        makeID: () -> UUID = UUID.init
    ) -> Trip {
        guard trip.activeTankNumber == nil else { return trip }
        guard let target = startTarget(in: trip, plannedTankNumbers: plannedTankNumbers) else { return trip }

        var updated = trip
        if let fillIndex = target.fillSessionIndex {
            updated.tankSessions[fillIndex].startTime = timestamp
            updated.tankSessions[fillIndex].startRow = currentRow
            updated.tankSessions[fillIndex].endTime = nil
            updated.tankSessions[fillIndex].endRow = nil
            if updated.tankSessions[fillIndex].fillEndTime == nil {
                updated.tankSessions[fillIndex].fillEndTime = timestamp
            }
        } else {
            updated.tankSessions.append(TankSession(
                id: makeID(),
                tankNumber: target.tankNumber,
                startTime: timestamp,
                startRow: currentRow
            ))
        }
        updated.activeTankNumber = target.tankNumber
        updated.isFillingTank = false
        updated.fillingTankNumber = nil
        return updated
    }

    static func end(trip: Trip, at timestamp: Date, currentRow: Double?) -> Trip {
        guard let activeTankNumber = trip.activeTankNumber else { return trip }
        guard let sessionIndex = trip.tankSessions.lastIndex(where: {
            $0.tankNumber == activeTankNumber && $0.endTime == nil
        }) else { return trip }

        var updated = trip
        updated.tankSessions[sessionIndex].endTime = timestamp
        updated.tankSessions[sessionIndex].endRow = currentRow
        updated.activeTankNumber = nil
        return updated
    }

    private static func startTarget(in trip: Trip, plannedTankNumbers: [Int]?) -> StartTarget? {
        guard let plannedTankNumbers else {
            let fillIndex = reusableFillOnlySessionIndex(in: trip)
            let tankNumber = fillIndex.map { trip.tankSessions[$0].tankNumber }
                ?? (trip.tankSessions.map(\.tankNumber).max() ?? 0) + 1
            return StartTarget(tankNumber: tankNumber, fillSessionIndex: fillIndex)
        }

        let planned = Array(Set(plannedTankNumbers.filter { $0 >= 1 })).sorted()
        let completed = Set(trip.tankSessions.filter { $0.endTime != nil }.map(\.tankNumber))
        let incomplete = planned.filter { !completed.contains($0) }
        guard !incomplete.isEmpty else { return nil }

        if let fillingTankNumber = trip.fillingTankNumber,
           incomplete.contains(fillingTankNumber),
           let fillIndex = trip.tankSessions.lastIndex(where: {
               $0.tankNumber == fillingTankNumber && isFillOnly($0)
           }) {
            return StartTarget(tankNumber: fillingTankNumber, fillSessionIndex: fillIndex)
        }
        for tankNumber in incomplete {
            if let fillIndex = trip.tankSessions.lastIndex(where: {
                $0.tankNumber == tankNumber && isFillOnly($0)
            }) {
                return StartTarget(tankNumber: tankNumber, fillSessionIndex: fillIndex)
            }
        }
        return StartTarget(tankNumber: incomplete[0], fillSessionIndex: nil)
    }

    private static func reusableFillOnlySessionIndex(in trip: Trip) -> Int? {
        if let fillingTankNumber = trip.fillingTankNumber,
           let index = trip.tankSessions.lastIndex(where: {
               $0.tankNumber == fillingTankNumber && isFillOnly($0)
           }) {
            return index
        }
        return trip.tankSessions.lastIndex(where: isFillOnly)
    }

    private static func isFillOnly(_ session: TankSession) -> Bool {
        session.fillStartTime != nil && session.endTime == nil && session.startRow == nil
    }

    private struct StartTarget {
        let tankNumber: Int
        let fillSessionIndex: Int?
    }
}
