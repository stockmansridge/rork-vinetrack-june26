import Foundation

/// Prospective completion-time evidence only; never reconstructs history from planned ranges or GPS totals.
nonisolated enum TankPathAttribution {
    static func activeSession(in trip: Trip) -> TankSession? {
        guard trip.isActive, trip.endTime == nil, !trip.isPaused, !trip.isFillingTank,
              let number = trip.activeTankNumber else { return nil }
        let open = trip.tankSessions.filter { TankSessionLifecycle.isOpenSpray($0) }
        guard open.count == 1, let session = open.first, session.tankNumber == number,
              trip.tankSessions.filter({ $0.id == session.id || $0.tankNumber == number }).count == 1
        else { return nil }
        return session
    }

    /// Preserve recorded same-session evidence during an active-trip replay, never derive new links.
    static func mergingRecordedPaths(local: Trip, remote: Trip) -> Trip? {
        guard Set(local.tankSessions.map(\.id)).count == local.tankSessions.count,
              Set(remote.tankSessions.map(\.id)).count == remote.tankSessions.count else { return nil }
        var result = local
        for session in remote.tankSessions {
            guard let index = result.tankSessions.firstIndex(where: { $0.id == session.id }) else {
                result.tankSessions.append(session)
                continue
            }
            let localSession = result.tankSessions[index]
            let isFillUpgrade = session.fillStartTime != nil && session.endTime == nil &&
                !TankSessionLifecycle.isOpenSpray(session) &&
                (localSession.startRow != nil || (localSession.fillEndTime.map { localSession.startTime >= $0 } ?? false)) &&
                localSession.fillStartTime == session.fillStartTime
            guard localSession.tankNumber == session.tankNumber,
                  localSession.startTime == session.startTime || isFillUpgrade else { return nil }
            result.tankSessions[index].endTime = localSession.endTime ?? session.endTime
            result.tankSessions[index].endRow = localSession.endRow ?? session.endRow
            result.tankSessions[index].fillStartTime = localSession.fillStartTime ?? session.fillStartTime
            result.tankSessions[index].fillEndTime = localSession.fillEndTime ?? session.fillEndTime
            for path in session.pathsCovered where !result.tankSessions[index].pathsCovered.contains(path) {
                result.tankSessions[index].pathsCovered.append(path)
            }
        }
        guard Set(result.tankSessions.map(\.tankNumber)).count == result.tankSessions.count else { return nil }
        if let number = result.activeTankNumber,
           !result.tankSessions.contains(where: { $0.tankNumber == number && TankSessionLifecycle.isOpenSpray($0) }) {
            result.activeTankNumber = nil
        }
        return result
    }

    /// Legacy numeric evidence is admitted only when it identifies one planned path in one block.
    /// Repeated/cross-block coverage uses the occurrence journal's exact session IDs instead.
    static func recordCompletion(_ path: Double, in trip: inout Trip, at timestamp: Date = Date()) {
        guard trip.coverageBasis == .legacy, path.isFinite,
              trip.paddockIds.count <= 1,
              trip.rowSequence.filter({ $0 == path }).count == 1,
              let session = activeSession(in: trip), timestamp >= session.startTime,
              let index = trip.tankSessions.firstIndex(where: { $0.id == session.id }),
              !trip.tankSessions[index].pathsCovered.contains(path) else { return }
        trip.tankSessions[index].pathsCovered.append(path)
    }
}
