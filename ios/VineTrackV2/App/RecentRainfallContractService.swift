import Foundation
import Supabase

/// Shared "recent rainfall" contract for the Irrigation Advisor.
///
/// Both iOS and Lovable resolve recent rain via the SQL RPC
/// `public.get_vineyard_recent_rainfall(p_vineyard_id, p_lookback_hours)`
/// so the value AND user-facing label agree across clients.
///
/// Resolution hierarchy (server side, see sql/075):
///   1. manual            (manager-corrected days)
///   2. davis_weatherlink (primary auto)
///   3. open_meteo        (historical/archive)
///   4. zero_fallback     (soft 0 mm — NEVER blocks the recommendation)
nonisolated struct RecentRainfallResolution: Sendable, Hashable {
    /// Total rainfall in window. Never nil — soft `0` when no data.
    let recentRainMm: Double
    let lookbackHours: Int
    let coveredFrom: Date
    let coveredTo: Date
    /// One of: `manual`, `davis_weatherlink`, `open_meteo`, `mixed`, `zero_fallback`.
    let source: String
    /// Short user-facing label, e.g. "Rainfall: Davis WeatherLink".
    let sourceLabel: String
    /// Verbose resolution path tag, e.g. `rainfall_daily.davis_weatherlink`
    /// or `rainfall_daily+current_weather_cache` or `zero_fallback`.
    let resolutionPath: String
    /// `true` when the resolver fell back to soft 0 mm. Clients MUST still
    /// display the recommendation in that case.
    let fallbackUsed: Bool
    let daysWithData: Int
    let daysMissing: Int
    let davisDays: Int
    let manualDays: Int
    let openMeteoDays: Int
    let todayFromCache: Bool

    var isSoftZeroFallback: Bool { source == "zero_fallback" || fallbackUsed }
}

@MainActor
enum RecentRainfallContractService {
    /// Get the shared vineyard-level recent-rain lookback (in hours).
    /// Allowed values: 24, 48, 168, 336. Defaults to 168 (7 days).
    static func getLookbackHours(vineyardId: UUID) async throws -> Int {
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured else { return 168 }
        let params = VineyardOnlyParams(pVineyardId: vineyardId)
        let value: Int = try await provider.client
            .rpc("get_vineyard_recent_rain_lookback_hours", params: params)
            .execute()
            .value
        return value
    }

    /// Set the shared vineyard-level recent-rain lookback (in hours).
    /// Requires owner/manager role. Throws on non-allowed values.
    @discardableResult
    static func setLookbackHours(vineyardId: UUID, hours: Int) async throws -> Int {
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured else { return hours }
        let params = SetLookbackParams(pVineyardId: vineyardId, pHours: hours)
        let value: Int = try await provider.client
            .rpc("set_vineyard_recent_rain_lookback_hours", params: params)
            .execute()
            .value
        return value
    }

    /// Resolve recent rainfall via the shared RPC. Pass `lookbackHours = nil`
    /// to use the vineyard's saved setting.
    static func resolveRecentRainfall(
        vineyardId: UUID,
        lookbackHours: Int?
    ) async throws -> RecentRainfallResolution {
        let provider = SupabaseClientProvider.shared
        if !provider.isConfigured {
            return softZero(hours: lookbackHours ?? 168)
        }

        let params = ResolveParams(
            pVineyardId: vineyardId,
            pLookbackHours: lookbackHours
        )

        let rows: [Row] = try await provider.client
            .rpc("get_vineyard_recent_rainfall", params: params)
            .execute()
            .value

        guard let row = rows.first else {
            return softZero(hours: lookbackHours ?? 168)
        }

        let utc = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = utc
        fmt.dateFormat = "yyyy-MM-dd"

        let from = fmt.date(from: row.coveredFrom).map { cal.startOfDay(for: $0) } ?? Date()
        let to = fmt.date(from: row.coveredTo).map { cal.startOfDay(for: $0) } ?? Date()

        return RecentRainfallResolution(
            recentRainMm: row.recentRainMm ?? 0,
            lookbackHours: row.lookbackHours,
            coveredFrom: from,
            coveredTo: to,
            source: row.source,
            sourceLabel: row.sourceLabel,
            resolutionPath: row.resolutionPath,
            fallbackUsed: row.fallbackUsed,
            daysWithData: row.daysWithData,
            daysMissing: row.daysMissing,
            davisDays: row.davisDays,
            manualDays: row.manualDays,
            openMeteoDays: row.openMeteoDays,
            todayFromCache: row.todayFromCache
        )
    }

    private static func softZero(hours: Int) -> RecentRainfallResolution {
        let to = Date()
        let from = Calendar.current.date(
            byAdding: .hour, value: -hours, to: to
        ) ?? to
        return RecentRainfallResolution(
            recentRainMm: 0,
            lookbackHours: hours,
            coveredFrom: from,
            coveredTo: to,
            source: "zero_fallback",
            sourceLabel: "No recent rainfall data — assuming 0 mm",
            resolutionPath: "zero_fallback",
            fallbackUsed: true,
            daysWithData: 0,
            daysMissing: max(1, Int(ceil(Double(hours) / 24.0))),
            davisDays: 0,
            manualDays: 0,
            openMeteoDays: 0,
            todayFromCache: false
        )
    }

    nonisolated private struct VineyardOnlyParams: Encodable, Sendable {
        let pVineyardId: UUID
        enum CodingKeys: String, CodingKey {
            case pVineyardId = "p_vineyard_id"
        }
    }

    nonisolated private struct SetLookbackParams: Encodable, Sendable {
        let pVineyardId: UUID
        let pHours: Int
        enum CodingKeys: String, CodingKey {
            case pVineyardId = "p_vineyard_id"
            case pHours = "p_hours"
        }
    }

    nonisolated private struct ResolveParams: Encodable, Sendable {
        let pVineyardId: UUID
        let pLookbackHours: Int?
        enum CodingKeys: String, CodingKey {
            case pVineyardId = "p_vineyard_id"
            case pLookbackHours = "p_lookback_hours"
        }
    }

    nonisolated private struct Row: Decodable, Sendable {
        let recentRainMm: Double?
        let lookbackHours: Int
        let coveredFrom: String
        let coveredTo: String
        let source: String
        let sourceLabel: String
        let resolutionPath: String
        let fallbackUsed: Bool
        let daysWithData: Int
        let daysMissing: Int
        let davisDays: Int
        let manualDays: Int
        let openMeteoDays: Int
        let todayFromCache: Bool

        enum CodingKeys: String, CodingKey {
            case recentRainMm = "recent_rain_mm"
            case lookbackHours = "lookback_hours"
            case coveredFrom = "covered_from"
            case coveredTo = "covered_to"
            case source
            case sourceLabel = "source_label"
            case resolutionPath = "resolution_path"
            case fallbackUsed = "fallback_used"
            case daysWithData = "days_with_data"
            case daysMissing = "days_missing"
            case davisDays = "davis_days"
            case manualDays = "manual_days"
            case openMeteoDays = "open_meteo_days"
            case todayFromCache = "today_from_cache"
        }
    }
}
