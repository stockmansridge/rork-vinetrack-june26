import Foundation
import Supabase

/// Version-one legacy pair protocol. Fingerprints are verified by exact-request server recovery, not a client JSONB approximation.
@MainActor
enum LegacySprayPairReceipt {
    struct Request: Codable, Equatable {
        let operation: UUID
        let trip: Data
        let record: Data
        func body() throws -> Data {
            let t = try JSONSerialization.jsonObject(with: trip)
            let r = try JSONSerialization.jsonObject(with: record)
            return try JSONSerialization.data(withJSONObject: ["p_operation_id": operation.uuidString.lowercased(), "p_trip": t, "p_record": r], options: [.sortedKeys])
        }
    }
    struct Receipt: Codable, Equatable {
        let version: Int
        let status: String
        let operation_id: UUID?
        let vineyard_id: UUID?
        let trip_id: UUID?
        let spray_record_id: UUID?
        let request_sha256: String?
        let committed_at: String?
        let code: String?
        func validate(_ attempt: LegacySpraySaveRecovery.Attempt) throws {
            guard version == 1, ["accepted", "rejected"].contains(status),
                  operation_id == attempt.rpc?.operation, vineyard_id == attempt.scope.vineyard,
                  trip_id == attempt.trip.id, spray_record_id == attempt.record.id,
                  let hash = request_sha256, hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let committed_at, ISO8601DateFormatter().date(from: committed_at) != nil || Self.fractionalDate(committed_at),
                  status == "accepted" ? code == nil : ["identity_conflict", "validation_or_reference_conflict"].contains(code ?? "") else { throw failure }
        }
        private static func fractionalDate(_ value: String) -> Bool {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: value) != nil
        }
    }
    static let tripKeys = Set("id vineyard_id paddock_id paddock_ids paddock_name tracking_pattern start_time is_active is_paused person_name trip_function trip_title machine_id tractor_id work_task_id operator_user_id worker_type_id total_distance path_points start_engine_hours seeding_details row_sequence sequence_index current_row_number next_row_number total_tanks created_by client_updated_at".split(separator: " ").map(String.init))
    static let recordKeys = Set("id vineyard_id date start_time temperature wind_speed wind_direction humidity spray_reference notes number_of_fans_jets average_speed equipment_type tractor tractor_gear machine_id tractor_id spray_equipment_id operation_type trip_id spray_job_id is_template tanks gross_area_ha treated_area_ha application_mode treated_area_method band_width_total_metres band_width_left_metres band_width_right_metres canonical_row_length_metres row_spacing_metres geometry_source geometry_quality carrier_volume_basis total_carrier_litres carrier_litres_per_hectare dilute_litres_per_100m applied_litres_per_100m concentration_factor targets spray_head_target ground_application_target carrier_area_basis application_blocks entry_source created_by client_updated_at".split(separator: " ").map(String.init))

    static func prepare(scope: LegacySpraySaveRecovery.Scope, record: SprayRecord, trip: Trip) throws -> Request {
        guard trip.occurrenceCoverage == nil, trip.rowSequence.isEmpty, !trip.isPaused, trip.workTaskId == nil,
              trip.totalDistance == 0, trip.currentPathDistance == 0, trip.pinIds.isEmpty,
              trip.pauseTimestamps.isEmpty, trip.resumeTimestamps.isEmpty, !trip.isFillingTank,
              trip.fillingTankNumber == nil, trip.endEngineHours == nil,
              trip.manualCorrectionEvents.isEmpty, trip.completionNotes == nil else { throw failure }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let now = Date()
        var t = try JSONSerialization.jsonObject(with: encoder.encode(BackendTrip.upsert(from: trip, createdBy: scope.actor, clientUpdatedAt: now))) as? [String: Any] ?? [:]
        // Only known empty runtime fields are excluded from the typed insert projection.
        for key in ["current_path_distance", "completed_paths", "skipped_paths", "pin_ids", "tank_sessions", "active_tank_number", "pause_timestamps", "resume_timestamps", "is_filling_tank", "filling_tank_number"] { t.removeValue(forKey: key) }
        var r = try JSONSerialization.jsonObject(with: encoder.encode(BackendSprayRecord.upsert(from: record, createdBy: scope.actor, clientUpdatedAt: now))) as? [String: Any] ?? [:]
        guard Set(t.keys).isSubset(of: tripKeys), Set(r.keys).isSubset(of: recordKeys) else {
            throw SprayPlanningAdmissionError(message: "This saved mix contains fields not admitted by legacy receipt v1. No fields were discarded or sent; backend contract review is required.")
        }
        // UUID text comparisons in the deployed RPC use PostgreSQL's lowercase uuid::text.
        for key in ["id", "vineyard_id", "paddock_id", "machine_id", "tractor_id", "operator_user_id", "worker_type_id", "created_by"] {
            if let value = t[key] as? String, let uuid = UUID(uuidString: value) { t[key] = uuid.uuidString.lowercased() }
        }
        if let values = t["paddock_ids"] as? [String] { t["paddock_ids"] = values.map { $0.lowercased() } }
        for key in ["id", "vineyard_id", "trip_id", "spray_job_id", "machine_id", "tractor_id", "spray_equipment_id", "created_by"] {
            if let value = r[key] as? String, let uuid = UUID(uuidString: value) { r[key] = uuid.uuidString.lowercased() }
        }
        return Request(operation: UUID(), trip: try JSONSerialization.data(withJSONObject: t, options: [.sortedKeys]), record: try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]))
    }

    static func request(rpc: String, body: Data, scope: LegacySpraySaveRecovery.Scope, isCurrent: () -> Bool) async throws -> Data {
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured, isCurrent() else { throw failure }
        let session = try await provider.client.auth.session
        guard session.user.id == scope.actor, isCurrent() else { throw failure }
        var request = URLRequest(url: provider.supabaseURL.appendingPathComponent("rest/v1/rpc/\(rpc)"))
        request.httpMethod = "POST"; request.timeoutInterval = 30; request.httpBody = body
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let current = try await provider.client.auth.session
        guard isCurrent(), current.user.id == session.user.id, current.refreshToken == session.refreshToken,
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw failure }
        return data
    }
    static var failure: Error { SprayPlanningAdmissionError(message: "Legacy spray receipt is unverified. Original evidence remains held; no dependent Start or sync was released.") }
}
