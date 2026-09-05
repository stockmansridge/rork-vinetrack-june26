import Foundation
import Observation
import Supabase

nonisolated private struct SprayTankActualCache: Codable, Sendable {
    var records: [SprayTankActual] = []
    var pendingIds: Set<UUID> = []
}

nonisolated private struct SprayTankActualUpsertRequest: Encodable, Sendable {
    let actual: SprayTankActual

    enum CodingKeys: String, CodingKey {
        case id = "p_id", vineyardId = "p_vineyard_id", sprayRecordId = "p_spray_record_id"
        case tripId = "p_trip_id", tankSessionId = "p_tank_session_id", tankNumber = "p_tank_number"
        case waterVolumeL = "p_water_volume_l", chemicals = "p_chemicals"
        case confirmedAt = "p_confirmed_at", clientUpdatedAt = "p_client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actual.id, forKey: .id)
        try container.encode(actual.vineyardId, forKey: .vineyardId)
        try container.encode(actual.sprayRecordId, forKey: .sprayRecordId)
        try container.encode(actual.tripId, forKey: .tripId)
        try container.encode(actual.tankSessionId, forKey: .tankSessionId)
        try container.encode(actual.tankNumber, forKey: .tankNumber)
        try container.encode(actual.waterVolumeL, forKey: .waterVolumeL)
        try container.encode(actual.chemicals, forKey: .chemicals)
        try container.encode(actual.confirmedAt, forKey: .confirmedAt)
        try container.encode(actual.clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

/// Durable local authority and retry queue for confirmed actual tank contents.
@Observable
@MainActor
final class SprayTankActualStore {
    static let shared = SprayTankActualStore()
    private static let persistenceKey = "vinetrack_spray_tank_actuals_v1"

    private(set) var records: [SprayTankActual]
    private(set) var pendingIds: Set<UUID>
    private let persistence: PersistenceStore

    convenience init() {
        self.init(persistence: .shared)
    }

    init(persistence: PersistenceStore) {
        self.persistence = persistence
        let cache: SprayTankActualCache? = persistence.load(key: Self.persistenceKey)
        records = cache?.records ?? []
        pendingIds = cache?.pendingIds ?? []
    }

    func actual(tripId: UUID, tankNumber: Int) -> SprayTankActual? {
        records.filter { $0.tripId == tripId && $0.tankNumber == tankNumber }
            .max { $0.clientUpdatedAt < $1.clientUpdatedAt }
    }

    /// Upserts by stable trip/session identity and durably queues before network activity.
    func saveLocally(_ actual: SprayTankActual) throws {
        var next = records
        if let index = next.firstIndex(where: { $0.tripId == actual.tripId && $0.tankSessionId == actual.tankSessionId }) {
            if next[index].clientUpdatedAt <= actual.clientUpdatedAt { next[index] = actual }
        } else {
            next.append(actual)
        }
        var pending = pendingIds
        pending.insert(actual.id)
        try persistence.saveOrThrow(SprayTankActualCache(records: next, pendingIds: pending), key: Self.persistenceKey)
        records = next
        pendingIds = pending
    }

    func removeLocal(id: UUID) throws {
        let next = records.filter { $0.id != id }
        var pending = pendingIds
        pending.remove(id)
        try persistence.saveOrThrow(SprayTankActualCache(records: next, pendingIds: pending), key: Self.persistenceKey)
        records = next
        pendingIds = pending
    }

    /// Replays only after parent trip and spray-record sync have had an opportunity to run.
    func syncPending(tripSync: TripSyncService?, spraySync: SprayRecordSyncService?, vineyardId: UUID) async {
        if tripSync?.isSyncing == true || spraySync?.isSyncing == true { return }
        guard SupabaseClientProvider.shared.isConfigured else { return }
        let ids = pendingIds
        for id in ids {
            guard let actual = records.first(where: { $0.id == id && $0.vineyardId == vineyardId }) else { continue }
            do {
                try await SupabaseClientProvider.shared.client
                    .rpc("upsert_spray_tank_actual", params: SprayTankActualUpsertRequest(actual: actual))
                    .execute()
                var pending = pendingIds
                pending.remove(id)
                try persistence.saveOrThrow(SprayTankActualCache(records: records, pendingIds: pending), key: Self.persistenceKey)
                pendingIds = pending
            } catch {
                // Durable queue remains pending. A later app/sync cycle retries idempotently.
            }
        }
    }
}
