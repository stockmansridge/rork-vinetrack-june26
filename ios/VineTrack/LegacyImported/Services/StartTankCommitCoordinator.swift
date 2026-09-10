import Foundation

/// Durable transaction journal joining the Trip session and confirmed actual stores.
@MainActor
final class StartTankCommitCoordinator {
    nonisolated struct Journal: Codable, Sendable {
        let actualRecordId: UUID
        let tankSessionId: String
        let tankNumber: Int
        let confirmationTimestamp: Date
        let updatedTrip: Trip
        let actual: SprayTankActual
        let sourceTrip: Trip?
        var state: String
    }

    enum FailurePoint: Sendable { case beforeActual, afterActual, afterTrip, beforeClear }
    enum InjectedFailure: Error { case requested }

    static let persistenceKey = "vinetrack_start_tank_commit_v1"
    private let persistence: PersistenceStore
    private let actualStore: SprayTankActualStore
    private let failurePoint: FailurePoint?

    init(
        persistence: PersistenceStore = .shared,
        actualStore: SprayTankActualStore = .shared,
        failurePoint: FailurePoint? = nil
    ) {
        self.persistence = persistence
        self.actualStore = actualStore
        self.failurePoint = failurePoint
    }

    func commit(sourceTrip: Trip, updatedTrip: Trip, actual: SprayTankActual, store: MigratedDataStore) throws {
        guard persistence.load(key: Self.persistenceKey) as Journal? == nil else {
            throw SprayTankActualValidationError.localSaveFailed
        }
        let journal = Journal(
            actualRecordId: actual.id,
            tankSessionId: actual.tankSessionId,
            tankNumber: actual.tankNumber,
            confirmationTimestamp: actual.confirmedAt,
            updatedTrip: updatedTrip,
            actual: actual,
            sourceTrip: sourceTrip,
            state: "prepared"
        )
        try persistence.saveOrThrow(journal, key: Self.persistenceKey)
        try finish(journal, store: store)
    }

    /// Completes the exact stable-ID operation saved before process termination.
    @discardableResult
    func recover(store: MigratedDataStore) -> Bool {
        guard let journal: Journal = persistence.load(key: Self.persistenceKey) else { return false }
        do {
            try finish(journal, store: store)
            return true
        } catch {
            return false
        }
    }

    private func finish(_ initial: Journal, store: MigratedDataStore) throws {
        var journal = initial
        guard store.selectedVineyardId == journal.updatedTrip.vineyardId,
              let current = store.trips.first(where: { $0.id == journal.updatedTrip.id }),
              let mergedTrip = Self.applyOperation(
                current: current,
                source: journal.sourceTrip,
                intended: journal.updatedTrip,
                tankSessionId: journal.tankSessionId,
                tankNumber: journal.tankNumber
              )
        else { throw SprayTankActualValidationError.localSaveFailed }

        try failIfRequested(.beforeActual)
        if !actualStore.records.contains(where: { $0.id == journal.actualRecordId && $0.tripId == journal.actual.tripId && $0.tankSessionId == journal.tankSessionId }) {
            try actualStore.saveLocally(journal.actual)
        }
        try failIfRequested(.afterActual)
        journal.state = "actual_durable"
        try persistence.saveOrThrow(journal, key: Self.persistenceKey)

        if store.trips.first(where: { $0.id == journal.updatedTrip.id }) != mergedTrip {
            try store.updateTripOrThrow(mergedTrip)
        } else {
            // Reassert the Trip dirty marker after a relaunch even when its file write landed.
            store.onTripChanged?(journal.updatedTrip.id)
        }
        try failIfRequested(.afterTrip)
        journal.state = "trip_durable"
        try persistence.saveOrThrow(journal, key: Self.persistenceKey)

        guard actualStore.records.contains(where: { $0.id == journal.actualRecordId && $0.tankSessionId == journal.tankSessionId }),
              let durableTrip = store.trips.first(where: { $0.id == journal.updatedTrip.id }),
              Self.operationIsEstablished(in: durableTrip, intended: journal.updatedTrip, tankSessionId: journal.tankSessionId, tankNumber: journal.tankNumber)
        else { throw SprayTankActualValidationError.localSaveFailed }
        try failIfRequested(.beforeClear)
        try persistence.removeOrThrow(key: Self.persistenceKey)
    }

    private static func applyOperation(
        current: Trip,
        source: Trip?,
        intended: Trip,
        tankSessionId: String,
        tankNumber: Int
    ) -> Trip? {
        guard current.id == intended.id,
              current.vineyardId == intended.vineyardId,
              current.isActive,
              current.endTime == nil,
              let intendedSession = intended.tankSessions.first(where: {
                $0.id.uuidString == tankSessionId && $0.tankNumber == tankNumber
              })
        else { return nil }
        if operationIsEstablished(in: current, intended: intended, tankSessionId: tankSessionId, tankNumber: tankNumber) {
            return current
        }
        guard let source,
              current.id == source.id,
              current.vineyardId == source.vineyardId,
              current.tankSessions == source.tankSessions,
              current.activeTankNumber == source.activeTankNumber,
              current.isFillingTank == source.isFillingTank,
              current.fillingTankNumber == source.fillingTankNumber
        else { return nil }
        var merged = current
        merged.tankSessions = intended.tankSessions
        merged.activeTankNumber = intended.activeTankNumber
        merged.isFillingTank = intended.isFillingTank
        merged.fillingTankNumber = intended.fillingTankNumber
        return merged
    }

    private static func operationIsEstablished(in trip: Trip, intended: Trip, tankSessionId: String, tankNumber: Int) -> Bool {
        guard let expected = intended.tankSessions.first(where: { $0.id.uuidString == tankSessionId && $0.tankNumber == tankNumber }),
              let actual = trip.tankSessions.first(where: { $0.id.uuidString == tankSessionId && $0.tankNumber == tankNumber }),
              actual.startTime == expected.startTime,
              actual.startRow == expected.startRow,
              actual.fillStartTime == expected.fillStartTime,
              actual.fillEndTime == expected.fillEndTime
        else { return false }
        if actual.endTime != nil { return true }
        return actual.endTime == expected.endTime && actual.endRow == expected.endRow &&
            trip.activeTankNumber == intended.activeTankNumber &&
            trip.isFillingTank == intended.isFillingTank &&
            trip.fillingTankNumber == intended.fillingTankNumber
    }

    private func failIfRequested(_ point: FailurePoint) throws {
        if failurePoint == point { throw InjectedFailure.requested }
    }
}
