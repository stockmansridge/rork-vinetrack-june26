import Foundation

/// Pure helpers for Growing Degree Days (GDD) and Biologically
/// Effective Degree Days (BEDD).
///
/// Extracts the maths from `DegreeDayService` so the website can run
/// the same computation against any temperature source. Network
/// fetching, Supabase caching, UserDefaults caching, and Wunderground
/// API handling all remain in `DegreeDayService` and are unchanged.
nonisolated enum DegreeDayMath {
    /// Vitis vinifera lower base temperature, °C.
    static let baseTemp: Double = 10.0
    /// BEDD upper cap on daily mean, °C.
    static let beddCap: Double = 19.0

    /// Plain GDD for a single day: `max(0, ((high + low) / 2) - baseTemp)`.
    static func plainGDDDay(high: Double, low: Double, baseTemp: Double = baseTemp) -> Double {
        max(0, ((high + low) / 2.0) - baseTemp)
    }

    /// Gladstones BEDD for a single day, with optional latitude-based
    /// day-length correction. Mirrors `DegreeDayService.beddDay`.
    ///
    /// - high/low capped at `beddCap` before averaging.
    /// - Heat = `max(0, mean - baseTemp)` plus a diurnal range bonus
    ///   of `(range - 13) × 0.25` when daily range exceeds 13 °C.
    /// - Multiplied by `dayLengthFactor(latitude:date:)`.
    static func beddDay(
        high: Double,
        low: Double,
        latitude: Double?,
        date: Date,
        baseTemp: Double = baseTemp,
        cap: Double = beddCap
    ) -> Double {
        let cappedHigh = min(high, cap)
        let cappedLow = min(low, cap)
        let mean = (cappedHigh + cappedLow) / 2.0
        var heat = max(0, mean - baseTemp)

        let range = high - low
        if range > 13 {
            heat += (range - 13) * 0.25
        }

        let k = dayLengthFactor(latitude: latitude, date: date)
        return heat * k
    }

    /// Day-length correction factor, clamped to `[0.5, 1.5]`.
    /// Returns `1.0` for unknown or polar (|lat| > 66) latitudes.
    static func dayLengthFactor(latitude: Double?, date: Date) -> Double {
        guard let lat = latitude, abs(lat) <= 66 else { return 1.0 }
        let cal = Calendar(identifier: .gregorian)
        let n = cal.ordinality(of: .day, in: .year, for: date) ?? 1
        let decl = 23.45 * sin((360.0 * Double(284 + n) / 365.0) * .pi / 180.0)
        let latRad = lat * .pi / 180.0
        let declRad = decl * .pi / 180.0
        let cosOmega = -tan(latRad) * tan(declRad)
        let clamped = max(-1.0, min(1.0, cosOmega))
        let omega = acos(clamped) * 180.0 / .pi
        let dayLength = 2.0 * omega / 15.0
        return max(0.5, min(1.5, dayLength / 12.0))
    }

    // MARK: - Series helpers

    nonisolated struct DailyTempSample: Sendable {
        public let date: Date
        public let high: Double
        public let low: Double
        public init(date: Date, high: Double, low: Double) {
            self.date = date
            self.high = high
            self.low = low
        }
    }

    nonisolated struct DailyAccumulation: Sendable {
        public let date: Date
        public let daily: Double
        public let cumulative: Double
    }

    /// Cumulative GDD/BEDD series from an ordered list of daily
    /// temperature samples. Caller is responsible for filling/
    /// interpolating gaps; this helper does not synthesise data.
    static func dailySeries(
        from samples: [DailyTempSample],
        latitude: Double?,
        useBEDD: Bool,
        baseTemp: Double = baseTemp
    ) -> [DailyAccumulation] {
        var cumulative: Double = 0
        var out: [DailyAccumulation] = []
        out.reserveCapacity(samples.count)
        for s in samples {
            let value = useBEDD
                ? beddDay(high: s.high, low: s.low, latitude: latitude, date: s.date, baseTemp: baseTemp)
                : plainGDDDay(high: s.high, low: s.low, baseTemp: baseTemp)
            cumulative += value
            out.append(DailyAccumulation(date: s.date, daily: value, cumulative: cumulative))
        }
        return out
    }

    /// Total accumulated GDD/BEDD across the supplied samples.
    static func totalAccumulation(
        from samples: [DailyTempSample],
        latitude: Double?,
        useBEDD: Bool,
        baseTemp: Double = baseTemp
    ) -> Double {
        dailySeries(from: samples, latitude: latitude, useBEDD: useBEDD, baseTemp: baseTemp)
            .last?.cumulative ?? 0
    }
}
