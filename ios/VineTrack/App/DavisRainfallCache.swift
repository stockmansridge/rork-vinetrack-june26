import Foundation

/// On-device cache for Davis WeatherLink daily rainfall (mm) per station/year.
///
/// Davis WeatherLink v2 historic endpoint allows a 24-hour window per call,
/// so a full year-long fetch can be 365 calls per station. To stay well below
/// the WeatherLink rate limit we persist the daily totals we've already
/// computed and only fetch the days we don't have, plus today/yesterday
/// (which can still accumulate rainfall in real time).
nonisolated enum DavisRainfallCache {
    private static let prefix = "DavisRainfallCache.v1"
    private static let lastFetchedSuffix = ".lastFetched"

    /// Cache key — when a `vineyardId` is supplied, the entry is scoped
    /// to the vineyard so a personal/local Davis setup and a vineyard-
    /// shared Davis setup never collide. Legacy entries (no vineyard)
    /// remain readable for backwards compatibility.
    private static func key(
        vineyardId: UUID?,
        provider: String,
        stationId: String,
        year: Int
    ) -> String {
        if let vid = vineyardId {
            return "\(prefix).\(provider).\(vid.uuidString).\(stationId).\(year)"
        }
        return "\(prefix).\(stationId).\(year)"
    }

    private static func key(stationId: String, year: Int) -> String {
        key(vineyardId: nil, provider: "davis", stationId: stationId, year: year)
    }

    private static func dateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Calendar.current.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Returns cached daily rainfall (start-of-day → mm) for the given
    /// station/year. Empty when nothing is cached.
    static func load(stationId: String, year: Int) -> [Date: Double] {
        load(vineyardId: nil, stationId: stationId, year: year)
    }

    /// Vineyard-aware load. Returns the merged daily totals from the
    /// vineyard-scoped entry, falling back to the legacy device-scoped
    /// entry if no vineyard entry exists yet.
    static func load(vineyardId: UUID?, stationId: String, year: Int) -> [Date: Double] {
        let k = key(vineyardId: vineyardId, provider: "davis", stationId: stationId, year: year)
        var raw = UserDefaults.standard.dictionary(forKey: k) ?? [:]
        if raw.isEmpty, vineyardId != nil {
            // Read-through to the legacy non-vineyard entry so cached
            // data isn't lost after the upgrade.
            let legacy = key(stationId: stationId, year: year)
            raw = UserDefaults.standard.dictionary(forKey: legacy) ?? [:]
        }
        let cal = Calendar.current
        let fmt = dateFormatter()
        var out: [Date: Double] = [:]
        for (s, v) in raw {
            guard let d = fmt.date(from: s) else { continue }
            let mm: Double?
            if let dbl = v as? Double { mm = dbl }
            else if let i = v as? Int { mm = Double(i) }
            else if let n = v as? NSNumber { mm = n.doubleValue }
            else { mm = nil }
            if let mm { out[cal.startOfDay(for: d)] = mm }
        }
        return out
    }

    /// Replaces the cache entry entirely.
    static func save(stationId: String, year: Int, daily: [Date: Double]) {
        save(vineyardId: nil, stationId: stationId, year: year, daily: daily)
    }

    /// Vineyard-aware save.
    static func save(
        vineyardId: UUID?,
        stationId: String,
        year: Int,
        daily: [Date: Double]
    ) {
        let fmt = dateFormatter()
        var dict: [String: Double] = [:]
        for (date, v) in daily {
            dict[fmt.string(from: date)] = v
        }
        let k = key(vineyardId: vineyardId, provider: "davis", stationId: stationId, year: year)
        UserDefaults.standard.set(dict, forKey: k)
        UserDefaults.standard.set(Date(), forKey: k + lastFetchedSuffix)
    }

    /// Merges new values into the cached entry, returning the merged map.
    /// New values overwrite existing ones for the same date.
    @discardableResult
    static func merge(stationId: String, year: Int, additions: [Date: Double]) -> [Date: Double] {
        var existing = load(stationId: stationId, year: year)
        for (k, v) in additions { existing[k] = v }
        save(stationId: stationId, year: year, daily: existing)
        return existing
    }

    static func lastFetched(stationId: String, year: Int) -> Date? {
        UserDefaults.standard.object(forKey: key(stationId: stationId, year: year) + lastFetchedSuffix) as? Date
    }

    static func clear(stationId: String, year: Int) {
        let k = key(stationId: stationId, year: year)
        UserDefaults.standard.removeObject(forKey: k)
        UserDefaults.standard.removeObject(forKey: k + lastFetchedSuffix)
    }

    /// Removes all cached Davis rainfall entries for the given station
    /// across every year, in both vineyard-scoped and legacy entries.
    static func clearAll(stationId: String) {
        let defaults = UserDefaults.standard
        let suffix = ".\(stationId)."
        for k in defaults.dictionaryRepresentation().keys
        where k.hasPrefix(prefix) && k.contains(suffix) {
            defaults.removeObject(forKey: k)
        }
    }

    /// Removes vineyard-scoped Davis rainfall entries for a specific
    /// vineyard / station combination.
    static func clearAll(vineyardId: UUID, stationId: String) {
        let defaults = UserDefaults.standard
        let scope = "\(prefix).davis.\(vineyardId.uuidString).\(stationId)."
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(scope) {
            defaults.removeObject(forKey: k)
        }
    }

    /// Removes every cached Davis rainfall entry on this device.
    static func clearAll() {
        let defaults = UserDefaults.standard
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) {
            defaults.removeObject(forKey: k)
        }
    }
}
