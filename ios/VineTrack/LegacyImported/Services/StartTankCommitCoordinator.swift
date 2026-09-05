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

    func commit(updatedTrip: Trip, actual: SprayTankActual, store: MigratedDataStore) throws {
        let journal = Journal(
            actualRecordId: actual.id,
            tankSessionId: actual.tankSessionId,
            tankNumber: actual.tankNumber,
            confirmationTimestamp: actual.confirmedAt,
            updatedTrip: updatedTrip,
            actual: actual,
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
        try failIfRequested(.beforeActual)
        if !actualStore.records.contains(where: { $0.id == journal.actualRecordId && $0.tripId == journal.actual.tripId && $0.tankSessionId == journal.tankSessionId }) {
            try actualStore.saveLocally(journal.actual)
        }
        try failIfRequested(.afterActual)
        journal.state = "actual_durable"
        try persistence.saveOrThrow(journal, key: Self.persistenceKey)

        if store.trips.first(where: { $0.id == journal.updatedTrip.id }) != journal.updatedTrip {
            try store.updateTripOrThrow(journal.updatedTrip)
        } else {
            // Reassert the Trip dirty marker after a relaunch even when its file write landed.
            store.onTripChanged?(journal.updatedTrip.id)
        }
        try failIfRequested(.afterTrip)
        journal.state = "trip_durable"
        try persistence.saveOrThrow(journal, key: Self.persistenceKey)

        guard actualStore.records.contains(where: { $0.id == journal.actualRecordId && $0.tankSessionId == journal.tankSessionId }),
              store.trips.contains(journal.updatedTrip)
        else { throw SprayTankActualValidationError.localSaveFailed }
        try failIfRequested(.beforeClear)
        try persistence.removeOrThrow(key: Self.persistenceKey)
    }

    private func failIfRequested(_ point: FailurePoint) throws {
        if failurePoint == point { throw InjectedFailure.requested }
    }
}
