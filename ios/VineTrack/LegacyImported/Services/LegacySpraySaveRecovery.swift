import Foundation

/// Legacy local two-file creation WAL. Not the versioned spray-planning protocol or a remote receipt.
@MainActor
final class LegacySpraySaveRecovery {
    struct Scope: Codable, Equatable {
        let actor: UUID
        let session: UUID
        let vineyard: UUID
    }
    struct Attempt: Codable, Equatable {
        let scope: Scope
        let record: SprayRecord
        let trip: Trip
        var localComplete: Bool = false
        init(scope: Scope, record: SprayRecord, trip: Trip) {
            self.scope = scope; self.record = record; self.trip = trip
        }
        private enum CodingKeys: String, CodingKey { case scope, recordBytes, tripBytes, localComplete }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scope = try c.decode(Scope.self, forKey: .scope)
            record = try JSONDecoder().decode(SprayRecord.self, from: c.decode(Data.self, forKey: .recordBytes))
            trip = try JSONDecoder().decode(Trip.self, from: c.decode(Data.self, forKey: .tripBytes))
            localComplete = try c.decode(Bool.self, forKey: .localComplete)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(scope, forKey: .scope)
            // The legacy cache codec truncates ISO dates to seconds. The original attempt must not.
            try c.encode(JSONEncoder().encode(record), forKey: .recordBytes)
            try c.encode(JSONEncoder().encode(trip), forKey: .tripBytes)
            try c.encode(localComplete, forKey: .localComplete)
        }
    }
    static func sameProjection<T: Encodable>(_ first: T, _ second: T) throws -> Bool {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        return try encoder.encode(first) == encoder.encode(second)
    }
    static let key = "vinetrack_legacy_spray_save_attempts_v1"
    private let persistence: PersistenceStore
    init(persistence: PersistenceStore) { self.persistence = persistence }

    func attempts() throws -> [Attempt] {
        switch persistence.loadOutcome(key: Self.key) as PersistenceStore.LoadOutcome<[Attempt]> {
        case .missing: return []
        case .decoded(let items):
            guard Set(items.map { $0.record.id }).count == items.count,
                  Set(items.map { $0.trip.id }).count == items.count,
                  items.allSatisfy({ valid(scope: $0.scope, record: $0.record, trip: $0.trip) }) else { throw failure }
            return items
        case .failed: throw failure
        }
    }
    func prepare(scope: Scope, record: SprayRecord, trip: Trip) throws {
        guard valid(scope: scope, record: record, trip: trip) else { throw failure }
        var items = try attempts()
        if let old = items.first(where: { $0.record.id == record.id || $0.trip.id == trip.id }) {
            guard old.scope == scope, old.record == record, old.trip == trip else { throw failure }
            return
        }
        // Local completion is not remote acceptance. A new session cannot bypass retained creation evidence.
        guard !items.contains(where: { $0.scope.actor == scope.actor && $0.scope.vineyard == scope.vineyard }) else { throw failure }
        items.append(Attempt(scope: scope, record: record, trip: trip))
        try persistence.saveOrThrow(items, key: Self.key)
    }
    /// Missing files are repaired only from the original WAL; existing different values are never overwritten.
    func reconcile(scope: Scope, record: (SprayRecord) throws -> Void, trip: (Trip) throws -> Void) throws -> [Attempt] {
        var items = try attempts()
        let pending = items.indices.filter { items[$0].scope == scope && !items[$0].localComplete }
        for index in pending {
            try record(items[index].record)
            try trip(items[index].trip)
            items[index].localComplete = true
            try persistence.saveOrThrow(items, key: Self.key)
        }
        return pending.map { items[$0] }
    }
    func contains(record: UUID? = nil, trip: UUID? = nil) throws -> Bool {
        try attempts().contains { $0.record.id == record || $0.trip.id == trip }
    }
    private func valid(scope: Scope, record: SprayRecord, trip: Trip) -> Bool {
        record.vineyardId == scope.vineyard && trip.vineyardId == scope.vineyard && record.tripId == trip.id &&
            !trip.isActive && trip.endTime == nil && record.endTime == nil && trip.tankSessions.isEmpty &&
            trip.activeTankNumber == nil && trip.completedPaths.isEmpty && trip.skippedPaths.isEmpty &&
            trip.pathPoints.isEmpty && record.operationalPlanningBlocker == nil
    }
    private var failure: Error { SprayTankActualValidationError.localSaveFailed }
}
