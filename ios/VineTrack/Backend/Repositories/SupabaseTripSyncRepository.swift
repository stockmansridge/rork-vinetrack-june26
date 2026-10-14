import Foundation
import Supabase

final class SupabaseTripSyncRepository: TripSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let query = provider.client
            .from("trips")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await query
                .gte("updated_at", value: ISO8601DateFormatter().string(from: since))
                .order("updated_at", ascending: true)
                .execute()
                .value
        } else {
            return try await query
                .order("updated_at", ascending: true)
                .execute()
                .value
        }
    }

    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] {
        try await fetchTrips(vineyardId: vineyardId, since: nil)
    }

    func upsertTrip(_ trip: BackendTripUpsert) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        if TripOccurrenceCoverage.basis(trip.occurrenceCoverage) != .legacy {
            try await replayOccurrenceTrip(trip)
            return
        }
        try await provider.client
            .from("trips")
            .upsert(trip, onConflict: "id")
            .execute()
    }

    func upsertTrips(_ trips: [BackendTripUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !trips.isEmpty else { return }
        let occurrenceTrips = trips.filter { TripOccurrenceCoverage.basis($0.occurrenceCoverage) != .legacy }
        for trip in occurrenceTrips { try await replayOccurrenceTrip(trip) }
        let legacyTrips = trips.filter { TripOccurrenceCoverage.basis($0.occurrenceCoverage) == .legacy }
        guard !legacyTrips.isEmpty else { return }
        try await provider.client
            .from("trips")
            .upsert(legacyTrips, onConflict: "id")
            .execute()
    }

    /// Serial durable action replay. Never converts an occurrence trip into a numeric full-snapshot write.
    private func replayOccurrenceTrip(_ trip: BackendTripUpsert) async throws {
        guard let raw = trip.occurrenceCoverage else { throw TripOccurrenceCoverage.Failure.updateRequired }
        _ = try TripOccurrenceCoverage.requireDocument(raw)
        guard trip.isActive, trip.endTime == nil else { throw TripOccurrenceCoverage.Failure.reconciliation }
        let session = try await provider.client.auth.session
        let account = session.user.id
        let journal = try TripOccurrenceJournal(scope: .init(ownerId: account.uuidString.lowercased(),
            vineyardId: trip.vineyardId.uuidString.lowercased(), tripId: trip.id.uuidString.lowercased()))
        guard try journal.load() != nil else { throw TripOccurrenceCoverage.Failure.missing }
        for _ in 0..<128 {
            guard let state = try journal.load(), state.heldReason == nil else { throw TripOccurrenceCoverage.Failure.reconciliation }
            guard let op = state.pending.first else { break }
            do {
                let result: TripOccurrenceCoverage.JSON = try await provider.client
                    .rpc("apply_trip_occurrence_action_v1", params: op.params).execute().value
                guard try await provider.client.auth.session.user.id == account else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                try journal.acknowledge(result)
            } catch {
                let message = String(describing: error)
                if message.contains("OCCURRENCE_") {
                    try journal.hold(message.contains("UPDATE_REQUIRED") || message.contains("UNSUPPORTED") ? "OCCURRENCE_UPDATE_REQUIRED" : "OCCURRENCE_CONFLICT")
                }
                throw error
            }
        }
        guard let state = try journal.load(), state.pending.isEmpty, state.heldReason == nil else { throw TripOccurrenceCoverage.Failure.reconciliation }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var fields = try JSONDecoder().decode([String: TripOccurrenceCoverage.JSON].self, from: encoder.encode(trip))
        // Authority, route identity and lifecycle can only go through their dedicated RPCs.
        for key in ["id", "vineyard_id", "created_by", "occurrence_coverage", "row_sequence", "completed_paths", "skipped_paths",
                    "sequence_index", "current_row_number", "next_row_number", "paddock_id", "paddock_ids", "tracking_pattern",
                    "start_time", "end_time", "is_active", "operator_user_id"] { fields.removeValue(forKey: key) }
        try await provider.client.from("trips").update(fields).eq("id", value: trip.id.uuidString).execute()
    }

    func fetchAllAccessibleTrips() async throws -> [BackendTrip] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("trips")
            .select()
            .is("deleted_at", value: nil)
            .order("updated_at", ascending: false)
            .limit(10_000)
            .execute()
            .value
    }

    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("trips")
            .update(TripVineyardAssignmentUpdate(
                vineyardId: vineyardId,
                paddockId: paddockId,
                clientUpdatedAt: Date()
            ))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("trips")
            .update(TripWorkTaskLinkUpdate(
                workTaskId: workTaskId,
                clientUpdatedAt: Date()
            ))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func softDeleteTrip(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_trip", params: SoftDeleteTripRequest(tripId: id))
            .execute()
    }
}

nonisolated private struct TripVineyardAssignmentUpdate: Encodable, Sendable {
    let vineyardId: UUID
    let paddockId: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case clientUpdatedAt = "client_updated_at"
    }
}

/// Explicit `work_task_id` patch. Unlike the synthesized bulk upsert, this
/// forces `encode` (not `encodeIfPresent`) so a nil `workTaskId` is written as
/// an explicit SQL null — required to actually unlink a trip on the server.
nonisolated private struct TripWorkTaskLinkUpdate: Encodable, Sendable {
    let workTaskId: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case workTaskId = "work_task_id"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workTaskId, forKey: .workTaskId)
        try container.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

nonisolated private struct SoftDeleteTripRequest: Encodable, Sendable {
    let tripId: UUID

    enum CodingKeys: String, CodingKey {
        case tripId = "p_trip_id"
    }
}
