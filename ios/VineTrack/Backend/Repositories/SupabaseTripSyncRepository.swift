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

    /// Exact scoped lookup: a capped vineyard list cannot establish absence.
    func fetchTripForOccurrenceStart(tripId: UUID, vineyardId: UUID) async throws -> BackendTrip? {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard let owner = provider.client.auth.currentUser?.id else { throw CancellationError() }
        let rows: [BackendTrip] = try await provider.client.from("trips").select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .eq("id", value: tripId.uuidString).limit(2).execute().value
        guard provider.client.auth.currentUser?.id == owner, rows.count <= 1 else {
            throw TripOccurrenceCoverage.Failure.scopeConflict
        }
        return rows.first
    }

    private func requireTripWrite(_ id: UUID) async throws -> UUID {
        guard let owner = provider.client.auth.currentUser?.id else { throw CancellationError() }
        struct Row: Decodable { let vineyard_id: UUID }
        let rows: [Row] = try await provider.client.from("trips").select("vineyard_id")
            .eq("id", value: id.uuidString).limit(2).execute().value
        guard provider.client.auth.currentUser?.id == owner, rows.count == 1 else {
            throw VineyardWriteAuthority.Restricted(reason: "WRITE_SCOPE_UNRESOLVED")
        }
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: rows[0].vineyard_id.uuidString)
        return rows[0].vineyard_id
    }

    func upsertTrip(_ trip: BackendTripUpsert) async throws {
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString)
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
        for trip in legacyTrips { try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString) }
        try await provider.client
            .from("trips")
            .upsert(legacyTrips, onConflict: "id")
            .execute()
    }

    /// Called at the local creation commitment, before sync can observe a new occurrence trip.
    /// The ordinary native payload is retained verbatim; only the envelope is a separate RPC argument.
    func prepareOccurrenceCreation(_ trip: BackendTripUpsert, ownerId: UUID) throws {
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString)
        guard let coverage = trip.occurrenceCoverage else { throw TripOccurrenceCoverage.Failure.updateRequired }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var metadata = try JSONDecoder().decode([String: TripOccurrenceCoverage.JSON].self, from: encoder.encode(trip))
        metadata.removeValue(forKey: "occurrence_coverage")
        let journal = try TripOccurrenceJournal(scope: .init(ownerId: ownerId.uuidString.lowercased(),
            vineyardId: trip.vineyardId.uuidString.lowercased(), tripId: trip.id.uuidString.lowercased()))
        if let existing = try journal.load() {
            guard let creation = existing.history.first(where: { $0.rpc == "create_trip_with_occurrences_v1" }),
                  creation.params[occurrence: "p_trip"] == .object(metadata), creation.params[occurrence: "p_coverage"] == coverage else {
                throw TripOccurrenceCoverage.Failure.reconciliation
            }
            return
        }
        try journal.prepareCreation(trip: .object(metadata), coverage: coverage)
    }

    /// Serial durable action replay. Never converts an occurrence trip into a numeric full-snapshot write.
    private func replayOccurrenceTrip(_ trip: BackendTripUpsert) async throws {
        guard let raw = trip.occurrenceCoverage else { throw TripOccurrenceCoverage.Failure.updateRequired }
        _ = try TripOccurrenceCoverage.requireDocument(raw)
        let session = try await provider.client.auth.session
        let account = session.user.id
        let journal = try TripOccurrenceJournal(scope: .init(ownerId: account.uuidString.lowercased(),
            vineyardId: trip.vineyardId.uuidString.lowercased(), tripId: trip.id.uuidString.lowercased()))
        guard let initial = try journal.load() else { throw TripOccurrenceCoverage.Failure.missing }
        if initial.creationConfirmed != false || !initial.pending.contains(where: { $0.rpc == "create_trip_with_occurrences_v1" }) {
            let recovery = try await occurrenceRequest(rpc: "get_trip_occurrence_recovery_v1", params: .object([
                "p_trip_id": .string(trip.id.uuidString.lowercased()),
                "p_operation_ids": .array(initial.pending.prefix(256).map { .string($0.id) })]), accessToken: session.accessToken)
            let currentSession = try await provider.client.auth.session
            guard currentSession.user.id == account, currentSession.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
            try journal.recover(recovery)
        }
        guard try journal.load()?.heldReason == nil else { throw TripOccurrenceCoverage.Failure.reconciliation }
        // Existing trip data/session establishment must precede occurrence links and finalisation.
        var sessionsEstablished = false
        for _ in 0..<128 {
            guard let state = try journal.load(), state.heldReason == nil else { throw TripOccurrenceCoverage.Failure.reconciliation }
            guard let op = state.pending.first else { break }
            do {
                let beforeRequest = try await provider.client.auth.session
                guard beforeRequest.user.id == account, beforeRequest.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                if !sessionsEstablished && !["create_trip_with_occurrences_v1", "activate_trip_occurrences_v1"].contains(op.rpc) {
                    try await updateOccurrenceNonAuthorityFields(trip, accessToken: session.accessToken)
                    let establishedSession = try await provider.client.auth.session
                    guard establishedSession.user.id == account, establishedSession.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                    sessionsEstablished = true
                }
                try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString)
                let result = try await occurrenceRequest(rpc: op.rpc, params: op.params, accessToken: session.accessToken, writeVineyard: trip.vineyardId)
                let currentSession = try await provider.client.auth.session
            guard currentSession.user.id == account, currentSession.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                try journal.acknowledge(result)
            } catch {
                let message = String(describing: error)
                if let rejection = error as? OccurrenceRPCFailure, rejection.code != "OCCURRENCE_SYNC_UNAVAILABLE" {
                    let current = try await provider.client.auth.session
                    guard current.user.id == account, current.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                    try journal.hold(message.contains("UPDATE_REQUIRED") || message.contains("UNSUPPORTED") ? "OCCURRENCE_UPDATE_REQUIRED" : "OCCURRENCE_CONFLICT")
                }
                throw error
            }
        }
        guard let state = try journal.load(), state.pending.isEmpty, state.heldReason == nil else { throw TripOccurrenceCoverage.Failure.reconciliation }
        try await updateOccurrenceNonAuthorityFields(trip, accessToken: session.accessToken)
    }

    private func updateOccurrenceNonAuthorityFields(_ trip: BackendTripUpsert, accessToken: String) async throws {
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var fields = try JSONDecoder().decode([String: TripOccurrenceCoverage.JSON].self, from: encoder.encode(trip))
        // Authority, route identity and lifecycle can only go through their dedicated RPCs.
        for key in ["id", "vineyard_id", "created_by", "occurrence_coverage", "row_sequence", "completed_paths", "skipped_paths",
                    "sequence_index", "current_row_number", "next_row_number", "paddock_id", "paddock_ids", "tracking_pattern",
                    "start_time", "end_time", "is_active", "operator_user_id"] { fields.removeValue(forKey: key) }
        var components = URLComponents(url: provider.supabaseURL.appendingPathComponent("rest/v1/trips"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(trip.id.uuidString.lowercased())"), URLQueryItem(name: "select", value: "id")]
        guard let url = components?.url else { throw TripOccurrenceCoverage.Failure.invalidAction }
        var request = URLRequest(url: url); request.httpMethod = "PATCH"; request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(PostgrestError.self, from: data))?.code
            if VineyardWriteAuthority.shared.handleServerCode(code, vineyardId: trip.vineyardId.uuidString) {
                throw VineyardWriteAuthority.Restricted(reason: "VT_READ_ONLY")
            }
            throw TripOccurrenceCoverage.Failure.reconciliation
        }
        let rows = try JSONDecoder().decode([TripOccurrenceCoverage.JSON].self, from: data)
        guard rows.count == 1, rows.first?[occurrence: "id"]?.occurrenceString?.lowercased() == trip.id.uuidString.lowercased() else {
            throw TripOccurrenceCoverage.Failure.reconciliation
        }
    }

    func fetchOccurrenceRecovery(tripId: UUID, operationIds: [String] = []) async throws -> TripOccurrenceCoverage.JSON {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let params: TripOccurrenceCoverage.JSON = .object(["p_trip_id": .string(tripId.uuidString.lowercased()),
            "p_operation_ids": .array(operationIds.prefix(256).map { .string($0) })])
        let session = try await provider.client.auth.session
        let result = try await occurrenceRequest(rpc: "get_trip_occurrence_recovery_v1", params: params, accessToken: session.accessToken)
        let current = try await provider.client.auth.session
        guard current.user.id == session.user.id, current.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
        return result
    }

    /// Captured credentials prevent a switched account being substituted mid-replay by an SDK refresh.
    private func occurrenceRequest(rpc: String, params: TripOccurrenceCoverage.JSON, accessToken: String, writeVineyard: UUID? = nil) async throws -> TripOccurrenceCoverage.JSON {
        if let writeVineyard { try VineyardWriteAuthority.shared.requireWrite(vineyardId: writeVineyard.uuidString) }
        guard ["create_trip_with_occurrences_v1", "activate_trip_occurrences_v1", "apply_trip_occurrence_action_v1",
               "finalize_trip_occurrences_v1", "get_trip_occurrence_recovery_v1"].contains(rpc) else { throw TripOccurrenceCoverage.Failure.invalidAction }
        var request = URLRequest(url: provider.supabaseURL.appendingPathComponent("rest/v1/rpc/\(rpc)"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(params)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let writeVineyard, VineyardWriteAuthority.shared.handleServerCode((try? JSONDecoder().decode(PostgrestError.self, from: data))?.code, vineyardId: writeVineyard.uuidString) {
                throw VineyardWriteAuthority.Restricted(reason: "VT_READ_ONLY")
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            let range = text.range(of: "OCCURRENCE_[A-Z_]+", options: .regularExpression)
            throw OccurrenceRPCFailure(code: range.map { String(text[$0]) } ?? "OCCURRENCE_SYNC_UNAVAILABLE")
        }
        return try JSONDecoder().decode(TripOccurrenceCoverage.JSON.self, from: data)
    }

    private struct OccurrenceRPCFailure: Error, LocalizedError {
        let code: String
        var errorDescription: String? { "Occurrence sync needs review (\(code)). Saved work was retained." }
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
        _ = try await requireTripWrite(id)
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: vineyardId.uuidString)
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
        _ = try await requireTripWrite(id)
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
        _ = try await requireTripWrite(id)
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
