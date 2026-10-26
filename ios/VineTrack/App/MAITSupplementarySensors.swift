import Foundation
import Supabase

/// Extra read-only sensors. Never used as primary weather, rainfall or irrigation input.
nonisolated struct MAITSupplementarySensors: Decodable, Sendable {
    let success: Bool?
    let partial: Bool?
    let modules: [Module]
    var partialHTTP = false

    enum CodingKeys: String, CodingKey { case success, partial, modules }
    static let warning = "Some MAIT sensor data may be incomplete. Primary weather is unaffected."
    var warning: String? {
        partialHTTP || partial == true || success == false || modules.contains { $0.partial == true || $0.status == "error" } ? Self.warning : nil
    }

    nonisolated struct Module: Decodable, Sendable {
        let friendlyName: String
        let observedAt: String?
        let status: String
        let partial: Bool?
        let readings: [Reading]

        enum CodingKeys: String, CodingKey {
            case friendlyName = "friendly_name", displayName = "display_name", name, observedAt = "observed_at", status, partial, readings
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            friendlyName = try c.decodeIfPresent(String.self, forKey: .friendlyName)
                ?? c.decodeIfPresent(String.self, forKey: .displayName)
                ?? c.decodeIfPresent(String.self, forKey: .name) ?? "MAIT sensor"
            observedAt = try c.decodeIfPresent(String.self, forKey: .observedAt)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "no_data"
            partial = try c.decodeIfPresent(Bool.self, forKey: .partial)
            readings = try c.decodeIfPresent([Reading].self, forKey: .readings) ?? []
        }
        var statusLabel: String {
            switch status {
            case "ok": return "Observed"
            case "no_data": return "No recent data"
            default: return "Sensor data unavailable"
            }
        }
        var visibleReadings: [Reading] { status == "ok" ? readings.filter { $0.displayValue != nil } : [] }
    }

    nonisolated struct Reading: Decodable, Sendable {
        let canonicalMetric: String
        let channelKey: String?
        let channelNumber: Int?
        let sourceLabel: String?
        let sourceUnit: String?
        let value: Double?
        enum CodingKeys: String, CodingKey {
            case canonicalMetric = "canonical_metric", channelKey = "channel_key", channelNumber = "channel_number"
            case sourceLabel = "source_label", sourceUnit = "source_unit", value
        }
        var title: String {
            if let sourceLabel, !sourceLabel.isEmpty { return sourceLabel }
            switch canonicalMetric {
            case "soil_moisture": return "Soil moisture"
            case "soil_temperature": return "Soil temperature"
            case "leaf_wetness": return "Leaf wetness"
            default: return canonicalMetric.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
        var displayValue: String? {
            guard let value, value.isFinite else { return nil }
            let unit = canonicalMetric == "soil_temperature" ? "°C" : (sourceUnit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            // Use normalized value only. No raw-value conversion or unit inference.
            return value.formatted(.number.precision(.fractionLength(0...2))) + (unit.isEmpty ? "" : " \(unit)")
        }
    }
}

extension WeatherCurrentService {
    func fetchSupplementaryCurrent(vineyardId: UUID) async throws -> MAITSupplementarySensors {
        let origin = await MainActor.run { (VineyardWriteAuthority.shared.accountBinding, VineyardWriteAuthority.shared.accountGeneration) }
        let session = try await SupabaseClientProvider.shared.client.auth.session
        return try await Self.loadSupplementary(vineyardId: vineyardId, token: session.accessToken, isCurrent: {
            let current = await MainActor.run { (VineyardWriteAuthority.shared.accountBinding, VineyardWriteAuthority.shared.accountGeneration) }
            return origin == current && !Task.isCancelled
        }, send: { try await URLSession.shared.data(for: $0) })
    }

    static func loadSupplementary(
        vineyardId: UUID, token: String,
        isCurrent: () async -> Bool,
        send: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> MAITSupplementarySensors {
        guard await isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let request = try maitRequest(vineyardId: vineyardId, token: token, action: .supplementary)
        let (data, response) = try await send(request)
        guard await isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WeatherFetchError.network(MAITSupplementarySensors.warning)
        }
        var result = try JSONDecoder().decode(MAITSupplementarySensors.self, from: data)
        result.partialHTTP = http.statusCode == 206
        return result
    }
}
