import Foundation

/// Deterministic production transitions for operator-driven tank spraying.
nonisolated enum TankSessionLifecycle {
    static func start(
        trip: Trip,
        at timestamp: Date,
        currentRow: Double,
        makeID: () -> UUID = UUID.init
    ) -> Trip {
        guard trip.activeTankNumber == nil else { return trip }

        var updated = trip
        if let fillIndex = reusableFillOnlySessionIndex(in: updated) {
            let tankNumber = updated.tankSessions[fillIndex].tankNumber
            updated.tankSessions[fillIndex].startTime = timestamp
            updated.tankSessions[fillIndex].startRow = currentRow
            updated.tankSessions[fillIndex].endTime = nil
            updated.tankSessions[fillIndex].endRow = nil
            if updated.tankSessions[fillIndex].fillEndTime == nil {
                updated.tankSessions[fillIndex].fillEndTime = timestamp
            }
            updated.activeTankNumber = tankNumber
        } else {
            let nextNumber = (updated.tankSessions.map(\.tankNumber).max() ?? 0) + 1
            updated.tankSessions.append(TankSession(
                id: makeID(),
                tankNumber: nextNumber,
                startTime: timestamp,
                startRow: currentRow
            ))
            updated.activeTankNumber = nextNumber
        }
        updated.isFillingTank = false
        updated.fillingTankNumber = nil
        return updated
    }

    static func end(trip: Trip, at timestamp: Date, currentRow: Double) -> Trip {
        guard let activeTankNumber = trip.activeTankNumber else { return trip }
        guard let sessionIndex = trip.tankSessions.lastIndex(where: {
            $0.tankNumber == activeTankNumber && $0.endTime == nil && $0.startRow != nil
        }) else { return trip }

        var updated = trip
        updated.tankSessions[sessionIndex].endTime = timestamp
        updated.tankSessions[sessionIndex].endRow = currentRow
        updated.activeTankNumber = nil
        return updated
    }

    private static func reusableFillOnlySessionIndex(in trip: Trip) -> Int? {
        let isFillOnly: (TankSession) -> Bool = {
            $0.fillStartTime != nil && $0.endTime == nil && $0.startRow == nil
        }
        if let fillingTankNumber = trip.fillingTankNumber,
           let index = trip.tankSessions.lastIndex(where: {
               $0.tankNumber == fillingTankNumber && isFillOnly($0)
           }) {
            return index
        }
        return trip.tankSessions.lastIndex(where: isFillOnly)
    }
}
