import Foundation
import UIKit
import PostgREST
import Supabase
import CryptoKit

/// Authenticated Spray Report v1 and hourly-weather server paths.
@MainActor
final class SprayReportRepository {
    static let shared: SprayReportRepository = SprayReportRepository()
    private init() {}

    func fetch(tripId: UUID) async throws -> SprayReportPayloadV1 {
        await recoverRows(tripId: tripId)
        struct Request: Encodable { let p_trip_id: UUID }
        return try await SupabaseClientProvider.shared.client
            .rpc("get_spray_report_v1", params: Request(p_trip_id: tripId))
            .execute()
            .value
    }

    /// Resolves each distinct trip independently so multi-record exports never inherit
    /// another trip's weather or row evidence. Failed trips remain available for offline fallback.
    func fetchAll(tripIds: [UUID]) async -> [UUID: SprayReportPayloadV1] {
        var reports: [UUID: SprayReportPayloadV1] = [:]
        var seen: Set<UUID> = []
        for tripId in tripIds where seen.insert(tripId).inserted {
            if let report = try? await fetch(tripId: tripId) { reports[tripId] = report }
        }
        return reports
    }

    func correctMetadata(
        tripId: UUID,
        expectedVersion: Int,
        machineId: UUID?,
        tractorId: UUID?,
        sprayEquipmentId: UUID?,
        operatorUserId: UUID?,
        fuelConsumptionLPerHour: Double?,
        startEngineHours: Double?,
        endEngineHours: Double?
    ) async throws -> SprayReportPayloadV1 {
        struct Request: Encodable {
            let p_operation_id: UUID
            let p_trip_id: UUID
            let p_expected_version: Int
            let p_machine_id: UUID?
            let p_tractor_id: UUID?
            let p_spray_equipment_id: UUID?
            let p_operator_user_id: UUID?
            let p_fuel_consumption_l_per_hour: Double?
            let p_start_engine_hours: Double?
            let p_end_engine_hours: Double?
        }
        struct Response: Decodable { let report: SprayReportPayloadV1 }
        let request = Request(
            p_operation_id: UUID(), p_trip_id: tripId, p_expected_version: expectedVersion,
            p_machine_id: machineId, p_tractor_id: tractorId, p_spray_equipment_id: sprayEquipmentId,
            p_operator_user_id: operatorUserId, p_fuel_consumption_l_per_hour: fuelConsumptionLPerHour,
            p_start_engine_hours: startEngineHours, p_end_engine_hours: endEngineHours
        )
        let response: Response = try await SupabaseClientProvider.shared.client
            .rpc("correct_spray_trip_metadata_v1", params: request)
            .execute()
            .value
        return response.report
    }

    /// Runs the shared server derivation; ambiguous paths are intentionally left unresolved.
    private func recoverRows(tripId: UUID) async {
        guard SupabaseClientProvider.shared.isConfigured,
              let session = try? await SupabaseClientProvider.shared.client.auth.session,
              let url = URL(string: "\(AppConfig.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/functions/v1/spray-row-recovery") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["tripId": tripId.uuidString.lowercased()])
        _ = try? await URLSession.shared.data(for: request)
    }

    func routeImage(for payload: SprayReportPayloadV1, fallbackTrip: Trip) async -> UIImage? {
        if let route = payload.route,
           route.styleVersion == SprayReportPayloadV1.routeStyleVersion,
           let data = try? await SupabaseClientProvider.shared.client.storage
            .from(route.bucket)
            .download(path: route.objectPath),
           SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == route.sha256,
           let image = UIImage(data: data) {
            return image
        }
        guard let generated = await SprayRecordPDFService.captureMapSnapshot(trip: fallbackTrip) else { return nil }
        return await uploadAndResolveRoute(generated, trip: fallbackTrip) ?? generated
    }

    private func uploadAndResolveRoute(_ image: UIImage, trip: Trip) async -> UIImage? {
        guard let png = image.pngData(), let session = try? await SupabaseClientProvider.shared.client.auth.session else { return nil }
        let routeInput = ([SprayReportPayloadV1.routeStyleVersion, "1030x700"] + trip.pathPoints.map {
            String(format: "%.6f,%.6f", $0.latitude, $0.longitude)
        }).joined(separator: "|")
        let routeHash = SHA256.hash(data: Data(routeInput.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "\(AppConfig.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/functions/v1/spray-report-route-upload") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["tripId": trip.id.uuidString.lowercased(), "routeHash": routeHash, "pngBase64": png.base64EncodedString(), "coordinates": trip.pathPoints.map { ["latitude": $0.latitude, "longitude": $0.longitude] }, "width": 1030, "height": 700])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(RouteUploadResponse.self, from: data) else { return nil }
        if envelope.route.sha256 == SHA256.hash(data: png).map({ String(format: "%02x", $0) }).joined() { return image }
        guard let winner = try? await SupabaseClientProvider.shared.client.storage.from(envelope.route.bucket).download(path: envelope.route.objectPath),
              SHA256.hash(data: winner).map({ String(format: "%02x", $0) }).joined() == envelope.route.sha256 else { return nil }
        return UIImage(data: winner)
    }

    private nonisolated struct RouteUploadResponse: Decodable, Sendable { let route: SprayReportPayloadV1.Route }

    /// Creates the scheduled slot even when no genuine provider sample is available.
    /// The server's `(trip_id, sample_slot)` constraint makes retries idempotent.
    func captureUnavailableIfDue(for trip: Trip, at now: Date = Date(), isFinal: Bool = false) async {
        guard trip.tripFunction == TripFunction.spraying.rawValue,
              SupabaseClientProvider.shared.isConfigured else { return }
        let elapsed = max(0, now.timeIntervalSince(trip.startTime))
        let scheduled = isFinal ? now : trip.startTime.addingTimeInterval(floor(elapsed / 3600) * 3600)
        guard let session = try? await SupabaseClientProvider.shared.client.auth.session,
              let url = URL(string: "\(AppConfig.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/functions/v1/spray-weather-recovery") else { return }
        var edgeRequest = URLRequest(url: url)
        edgeRequest.httpMethod = "POST"
        edgeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        edgeRequest.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        edgeRequest.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        edgeRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["tripId": trip.id.uuidString.lowercased(), "through": ISO8601DateFormatter().string(from: scheduled)])
        _ = try? await URLSession.shared.data(for: edgeRequest)
        // Failed/transient slots remain absent server-side. Start, resume, restart and
        // final capture all ask the server for the complete missing-slot set again.
    }
}
