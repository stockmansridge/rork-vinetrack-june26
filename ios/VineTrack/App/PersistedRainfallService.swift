import Foundation
import Supabase

/// One row returned by `public.get_daily_rainfall(p_vineyard_id, p_from, p_to)`.
/// One row exists for every day in the requested range; `rainfallMm` is nil
/// when no source has data for that day.
nonisolated struct PersistedRainfallDay: Sendable, Hashable {
    public let date: Date
    public let rainfallMm: Double?
    /// Raw source string from the RPC: `"manual"`, `"davis_weatherlink"`,
    /// `"open_meteo"`, or `nil` when no row exists.
    public let source: String?
    public let stationId: String?
    public let stationName: String?
    public let notes: String?
}

/// Reads vineyard-level persisted rainfall history (`public.rainfall_daily`)
/// via the `get_daily_rainfall` RPC. The RPC enforces vineyard membership
/// and returns the highest-priority source per day:
/// `manual > davis_weatherlink > open_meteo`.
///
/// This is the primary source for the iOS Rain Calendar — it lets us show
/// the full year (and beyond) without hammering Davis from every device.
@MainActor
enum PersistedRainfallService {
    /// Fetch persisted daily rainfall in `[from, to]` (inclusive). Dates
    /// are interpreted in the device's current calendar timezone.
    static func fetchDailyRainfall(
        vineyardId: UUID,
        from: Date,
        to: Date
    ) async throws -> [PersistedRainfallDay] {
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured else { return [] }

        // Outgoing date strings: format using the device's local timezone so
        // the SQL date matches what the user sees on screen (e.g. "today"
        // in the local calendar).
        let outFmt = DateFormatter()
        outFmt.calendar = Calendar.current
        outFmt.locale = Locale(identifier: "en_US_POSIX")
        outFmt.timeZone = Calendar.current.timeZone
        outFmt.dateFormat = "yyyy-MM-dd"

        // Incoming date strings ("YYYY-MM-DD" from PostgREST): parse as UTC
        // midnight so the resulting `Date` is a deterministic, timezone-free
        // calendar-day key. The Rain Calendar UI uses the same UTC-anchored
        // keys so May 7 always renders on May 7 regardless of device tz.
        let utc = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")!
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = utc
        let inFmt = DateFormatter()
        inFmt.calendar = utcCal
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.timeZone = utc
        inFmt.dateFormat = "yyyy-MM-dd"

        let fromStr = outFmt.string(from: from)
        let toStr = outFmt.string(from: to)

        let params = Params(
            pVineyardId: vineyardId,
            pFromDate: fromStr,
            pToDate: toStr
        )

        let rows: [Row] = try await provider.client
            .rpc("get_daily_rainfall", params: params)
            .execute()
            .value

        return rows.compactMap { row in
            guard let parsed = inFmt.date(from: row.date) else { return nil }
            return PersistedRainfallDay(
                date: utcCal.startOfDay(for: parsed),
                rainfallMm: row.rainfallMm,
                source: row.source,
                stationId: row.stationId,
                stationName: row.stationName,
                notes: row.notes
            )
        }
    }

    nonisolated private struct Params: Encodable, Sendable {
        let pVineyardId: UUID
        let pFromDate: String
        let pToDate: String
        enum CodingKeys: String, CodingKey {
            case pVineyardId = "p_vineyard_id"
            case pFromDate = "p_from_date"
            case pToDate = "p_to_date"
        }
    }

    nonisolated private struct Row: Decodable, Sendable {
        let date: String
        let rainfallMm: Double?
        let source: String?
        let stationId: String?
        let stationName: String?
        let notes: String?
        enum CodingKeys: String, CodingKey {
            case date
            case rainfallMm = "rainfall_mm"
            case source
            case stationId = "station_id"
            case stationName = "station_name"
            case notes
        }
    }
}
