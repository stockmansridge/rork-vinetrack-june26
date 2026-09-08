import Foundation
import UIKit
import PostgREST
import Supabase

/// Authenticated Spray Report v1 and hourly-weather server paths.
@MainActor
final class SprayReportRepository {
    static let shared: SprayReportRepository = SprayReportRepository()
    private var submittedSlots: Set<String> = []

    private init() {}

    func fetch(tripId: UUID) async throws -> SprayReportPayloadV1 {
        struct Request: Encodable { let p_trip_id: UUID }
        return try await SupabaseClientProvider.shared.client
            .rpc("get_spray_report_v1", params: Request(p_trip_id: tripId))
            .execute()
            .value
    }

    func routeImage(for payload: SprayReportPayloadV1, fallbackTrip: Trip) async -> UIImage? {
        if let route = payload.route,
           route.styleVersion == SprayReportPayloadV1.routeStyleVersion,
           let data = try? await SupabaseClientProvider.shared.client.storage
            .from(route.bucket)
            .download(path: route.objectPath),
           let image = UIImage(data: data) {
            return image
        }
        return await SprayRecordPDFService.captureMapSnapshot(trip: fallbackTrip)
    }

    /// Creates the scheduled slot even when no genuine provider sample is available.
    /// The server's `(trip_id, sample_slot)` constraint makes retries idempotent.
    func captureUnavailableIfDue(for trip: Trip, at now: Date = Date(), isFinal: Bool = false) async {
        guard trip.tripFunction == TripFunction.spraying.rawValue,
              SupabaseClientProvider.shared.isConfigured else { return }
        let elapsed = max(0, now.timeIntervalSince(trip.startTime))
        let scheduled = isFinal ? now : trip.startTime.addingTimeInterval(floor(elapsed / 3600) * 3600)
        let key = "\(trip.id.uuidString):\(Int(scheduled.timeIntervalSince1970))"
        guard submittedSlots.insert(key).inserted else { return }

        struct Request: Encodable {
            let p_trip_id: UUID
            let p_sample_slot: Date
            let p_observed_at: Date?
            let p_source: String
            let p_source_kind: String
            let p_station_id: String?
            let p_temperature_c: Double?
            let p_humidity_pct: Double?
            let p_wind_speed_kmh: Double?
            let p_wind_gust_kmh: Double?
            let p_wind_direction_deg: Double?
            let p_rain_mm: Double?
            let p_is_stale: Bool
        }
        do {
            try await SupabaseClientProvider.shared.client.rpc(
                "capture_trip_weather_observation_v1",
                params: Request(
                    p_trip_id: trip.id,
                    p_sample_slot: scheduled,
                    p_observed_at: nil,
                    p_source: "Mobile capture unavailable",
                    p_source_kind: "unavailable",
                    p_station_id: nil,
                    p_temperature_c: nil,
                    p_humidity_pct: nil,
                    p_wind_speed_kmh: nil,
                    p_wind_gust_kmh: nil,
                    p_wind_direction_deg: nil,
                    p_rain_mm: nil,
                    p_is_stale: false
                )
            ).execute()
        } catch {
            submittedSlots.remove(key)
        }
    }
}
