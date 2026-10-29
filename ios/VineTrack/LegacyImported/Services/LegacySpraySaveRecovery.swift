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
        var rpc: LegacySprayPairReceipt.Request?
        var rpcClaimed: Bool = false
        var candidate: LegacySprayPairReceipt.Receipt?
        var verified: LegacySprayPairReceipt.Receipt?
        var receiptBlocker: String?
        var isHeld: Bool { verified?.status != "accepted" }
        init(scope: Scope, record: SprayRecord, trip: Trip) {
            self.scope = scope; self.record = record; self.trip = trip
        }
        private enum CodingKeys: String, CodingKey { case scope, recordBytes, tripBytes, localComplete, rpc, rpcClaimed, candidate, verified, receiptBlocker }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scope = try c.decode(Scope.self, forKey: .scope)
            record = try RecoveryDecodeEvidence.decode(SprayRecord.self, from: c.decode(Data.self, forKey: .recordBytes),
                source: "local_legacy_wal", operation: "LegacySpraySaveRecovery.Attempt.recordBytes")
            trip = try RecoveryDecodeEvidence.decode(Trip.self, from: c.decode(Data.self, forKey: .tripBytes),
                source: "local_legacy_wal", operation: "LegacySpraySaveRecovery.Attempt.tripBytes")
            localComplete = try c.decode(Bool.self, forKey: .localComplete)
            rpc = try c.decodeIfPresent(LegacySprayPairReceipt.Request.self, forKey: .rpc)
            rpcClaimed = try c.decodeIfPresent(Bool.self, forKey: .rpcClaimed) ?? false
            candidate = try c.decodeIfPresent(LegacySprayPairReceipt.Receipt.self, forKey: .candidate)
            verified = try c.decodeIfPresent(LegacySprayPairReceipt.Receipt.self, forKey: .verified)
            receiptBlocker = try c.decodeIfPresent(String.self, forKey: .receiptBlocker)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(scope, forKey: .scope)
            // The legacy cache codec truncates ISO dates to seconds. The original attempt must not.
            try c.encode(JSONEncoder().encode(record), forKey: .recordBytes)
            try c.encode(JSONEncoder().encode(trip), forKey: .tripBytes)
            try c.encode(localComplete, forKey: .localComplete)
            try c.encodeIfPresent(rpc, forKey: .rpc)
            try c.encode(rpcClaimed, forKey: .rpcClaimed)
            try c.encodeIfPresent(candidate, forKey: .candidate)
            try c.encodeIfPresent(verified, forKey: .verified)
            try c.encodeIfPresent(receiptBlocker, forKey: .receiptBlocker)
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
            for item in items {
                if let request = item.rpc {
                    let t = try JSONSerialization.jsonObject(with: request.trip) as? [String: Any]
                    let r = try JSONSerialization.jsonObject(with: request.record) as? [String: Any]
                    guard t?["id"] as? String == item.trip.id.uuidString.lowercased(),
                          r?["id"] as? String == item.record.id.uuidString.lowercased(),
                          t?["vineyard_id"] as? String == item.scope.vineyard.uuidString.lowercased(),
                          r?["vineyard_id"] as? String == item.scope.vineyard.uuidString.lowercased(),
                          r?["trip_id"] as? String == item.trip.id.uuidString.lowercased(),
                          t?["created_by"] as? String == item.scope.actor.uuidString.lowercased(),
                          r?["created_by"] as? String == item.scope.actor.uuidString.lowercased() else { throw failure }
                    try item.candidate?.validate(item); try item.verified?.validate(item)
                } else if item.verified != nil || item.candidate != nil || item.rpcClaimed { throw failure }
            }
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
        guard try !items.contains(where: { item in
            guard item.scope.actor == scope.actor, item.scope.vineyard == scope.vineyard else { return false }
            return try requiresLegacyReceipt(item)
        }) else { throw failure }
        var attempt = Attempt(scope: scope, record: record, trip: trip)
        do { attempt.rpc = try LegacySprayPairReceipt.prepare(scope: scope, record: record, trip: trip) }
        catch { attempt.receiptBlocker = "Legacy receipt v1 does not admit this payload. Original local evidence is retained, not stripped or sent." }
        items.append(attempt)
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
    /// An occurrence save uses this WAL only for the local recipe/trip pair. Release
    /// its *legacy* transport gate only when the exact original create intent is
    /// already durable in its scoped occurrence journal. That journal still owns
    /// all conflicts, activation, receipts and duplicate prevention. Never migrate,
    /// clear, re-create or transmit the retained WAL through the legacy RPC.
    func requiresLegacyReceipt(_ item: Attempt) throws -> Bool {
        guard item.isHeld else { return false }
        guard item.localComplete, item.trip.coverageBasis == .occurrence,
              item.rpc == nil, !item.rpcClaimed, item.candidate == nil, item.verified == nil else { return true }
        let scope = TripOccurrenceJournal.Scope(ownerId: item.scope.actor.uuidString.lowercased(),
            vineyardId: item.scope.vineyard.uuidString.lowercased(), tripId: item.trip.id.uuidString.lowercased())
        let journal = try TripOccurrenceJournal(scope: scope)
        guard let state = try journal.load(),
              let create = state.history.first(where: { $0.rpc == "create_trip_with_occurrences_v1" }),
              create.params[occurrence: "p_coverage"] == item.trip.occurrenceCoverage else { return true }
        let payload = BackendTrip.upsert(from: item.trip, createdBy: item.scope.actor, clientUpdatedAt: item.trip.startTime)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var metadata = try JSONDecoder().decode([String: TripOccurrenceCoverage.JSON].self, from: encoder.encode(payload))
        metadata.removeValue(forKey: "occurrence_coverage")
        return create.params[occurrence: "p_trip"] != .object(metadata)
    }
    func contains(record: UUID? = nil, trip: UUID? = nil) throws -> Bool {
        try attempts().contains { item in
            guard item.record.id == record || item.trip.id == trip else { return false }
            return try requiresLegacyReceipt(item)
        }
    }
    /// One caller serializes replay at the owning store; every send follows a durable claim.
    private var isReplaying: Bool = false
    func replay(scope: Scope, isCurrent: () -> Bool,
                transport: (String, Data) async throws -> Data) async throws {
        guard !isReplaying else { return }
        isReplaying = true
        defer { isReplaying = false }
        for original in try attempts() where original.scope == scope && original.localComplete && original.isHeld && original.verified == nil {
            guard let rpc = original.rpc, isCurrent() else { continue }
            let body = try rpc.body()
            var item = original
            if !item.rpcClaimed {
                item.rpcClaimed = true
                try replace(item)
                guard isCurrent() else { throw failure }
                let data = try await transport("save_legacy_spray_pair_v1", body)
                guard isCurrent() else { throw failure }
                let receipt = try RecoveryDecodeEvidence.decode(LegacySprayPairReceipt.Receipt.self, from: data,
                    source: "supabase_response", operation: "rpc.save_legacy_spray_pair_v1")
                try receipt.validate(item)
                item.candidate = receipt
                try replace(item)
            }
            guard isCurrent() else { throw failure }
            let data = try await transport("recover_legacy_spray_pair_v1", body)
            guard isCurrent() else { throw failure }
            let receipt = try RecoveryDecodeEvidence.decode(LegacySprayPairReceipt.Receipt.self, from: data,
                source: "supabase_response", operation: "rpc.recover_legacy_spray_pair_v1")
            try receipt.validate(item)
            if let candidate = item.candidate { guard candidate == receipt else { throw failure } }
            // The recovery RPC compares actor, exact JSONB bodies, identities and server hash.
            item.verified = receipt
            item.receiptBlocker = receipt.status == "rejected" ? "Original spray save rejected: \(receipt.code ?? "unknown"). Evidence retained; Start remains blocked." : nil
            try replace(item)
        }
    }
    private func replace(_ item: Attempt) throws {
        var items = try attempts()
        guard let index = items.firstIndex(where: { $0.record.id == item.record.id }),
              items[index].scope == item.scope, items[index].rpc == item.rpc,
              items[index].record == item.record, items[index].trip == item.trip else { throw failure }
        items[index] = item
        try persistence.saveOrThrow(items, key: Self.key)
    }
    private func valid(scope: Scope, record: SprayRecord, trip: Trip) -> Bool {
        record.vineyardId == scope.vineyard && trip.vineyardId == scope.vineyard && record.tripId == trip.id &&
            !trip.isActive && trip.endTime == nil && record.endTime == nil && trip.tankSessions.isEmpty &&
            trip.activeTankNumber == nil && trip.completedPaths.isEmpty && trip.skippedPaths.isEmpty &&
            trip.pathPoints.isEmpty && record.operationalPlanningBlocker == nil
    }
    private var failure: Error { SprayTankActualValidationError.localSaveFailed }
}
