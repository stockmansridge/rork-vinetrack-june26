import Foundation

extension Notification.Name {
    /// Posted when persisted vineyard rainfall has been changed by an
    /// admin action (e.g. the Owner/Manager-only "Backfill Davis
    /// rainfall" button) and the Rain Calendar should re-pull from
    /// `get_daily_rainfall`.
    static let rainfallCalendarShouldReload = Notification.Name("rainfallCalendarShouldReload")
}

/// Canonical UTC-anchored calendar-date key helpers used by the Rain Calendar.
///
/// Postgres `date` columns are timezone-free calendar dates (e.g. "2026-05-07").
/// Mapping them onto a `Date` using the device's local timezone caused
/// alignment bugs when the device tz differed from the vineyard tz: a row
/// for May 7 could resolve to a different absolute instant than the cell
/// the UI computed for May 7. Using UTC midnight as the canonical key for
/// every (year, month, day) makes the mapping deterministic and bug-free.
nonisolated enum RainfallDateKey {
    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")!
        return c
    }()

    /// UTC-midnight `Date` for the given calendar (year, month, day) triple.
    static func key(year: Int, month: Int, day: Int) -> Date? {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        return utcCalendar.date(from: comps)
    }

    /// Today's UTC-midnight key, derived from the device's *local* calendar
    /// (year, month, day). This keeps "today" stable relative to what the
    /// user sees on the device clock, even when the device tz differs from
    /// the vineyard tz.
    static func todayKey() -> Date {
        let local = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return key(
            year: local.year ?? 1970,
            month: local.month ?? 1,
            day: local.day ?? 1
        ) ?? Date()
    }

    /// UTC-midnight start-of-day for an arbitrary `Date`.
    static func startOfDay(_ date: Date) -> Date {
        utcCalendar.startOfDay(for: date)
    }
}

/// Fetches a year's worth of daily rainfall (mm) for the vineyard location,
/// preferring the configured local weather station (Davis WeatherLink) and
/// falling back gracefully to Open-Meteo Archive.
@MainActor
@Observable
final class RainfallCalendarService {
    var isLoading: Bool = false
    var isRefreshingRecent: Bool = false
    var errorMessage: String?
    var year: Int = Calendar.current.component(.year, from: Date())
    /// Daily rainfall keyed by start-of-day date.
    var dailyRainMm: [Date: Double] = [:]
    /// Per-day source (start-of-day → provenance).
    var sources: [Date: RainfallSource] = [:]
    var providerLabel: String = "Source: Vineyard rainfall history"
    var fallbackNote: String = "Persisted vineyard rainfall (manual → Davis → Weather Underground → Open-Meteo)"
    var coverageSummary: String?
    var lastUpdated: Date?
    var fallbackUsed: Bool = false
    var rateLimited: Bool = false
    var stationName: String?
    var isMeasured: Bool = false
    var manualDaysCovered: Int = 0
    var davisDaysCovered: Int = 0
    var wuDaysCovered: Int = 0
    var archiveDaysCovered: Int = 0
    /// `true` when the calendar values were loaded from the persisted
    /// `rainfall_daily` table via the `get_daily_rainfall` RPC. `false`
    /// when the service had to fall back to the live providers.
    var usedPersistedHistory: Bool = false
    /// `true` when today's value came from the live Davis cache because
    /// no persisted row existed yet.
    var todayFromLiveDavis: Bool = false

    private var lastVineyardId: UUID?
    private var lastLatitude: Double?
    private var lastLongitude: Double?
    private var lastWeatherStationId: String?

    func load(year: Int,
              vineyardId: UUID?,
              latitude: Double,
              longitude: Double,
              weatherStationId: String?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        self.year = year
        self.lastVineyardId = vineyardId
        self.lastLatitude = latitude
        self.lastLongitude = longitude
        self.lastWeatherStationId = weatherStationId

        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = year; comps.month = 1; comps.day = 1
        guard let jan1 = cal.date(from: comps) else {
            errorMessage = "Invalid year"
            return
        }
        comps.month = 12; comps.day = 31
        guard let dec31 = cal.date(from: comps) else {
            errorMessage = "Invalid year"
            return
        }
        let today = cal.startOfDay(for: Date())
        let end = min(dec31, today)

        if end < jan1 {
            self.dailyRainMm = [:]
            self.sources = [:]
            self.lastUpdated = Date()
            return
        }

        // Primary path: persisted vineyard rainfall via Supabase RPC.
        // This is the long-history source (years), so we do NOT cap at
        // 14 days like the legacy live Davis fetch did.
        if let vid = vineyardId {
            do {
                let rows = try await PersistedRainfallService.fetchDailyRainfall(
                    vineyardId: vid, from: jan1, to: end
                )
                await applyPersisted(
                    rows: rows,
                    vineyardId: vid,
                    today: today
                )
                return
            } catch {
                print("[RainfallCalendar] persisted fetch failed: \(error.localizedDescription) — falling back to live providers")
            }
        }

        // Fallback path (no vineyard, or RPC unavailable): legacy live
        // providers + Open-Meteo archive.
        let result = await RainfallHistoryService.fetchDailyRainfall(
            vineyardId: vineyardId,
            latitude: latitude,
            longitude: longitude,
            from: jan1,
            to: end,
            weatherStationId: weatherStationId
        )
        apply(result)
    }

    /// Refresh only the most recent `days` days. When persisted history
    /// is the active source, this re-fetches the recent window from
    /// `get_daily_rainfall` and merges into the year. When persisted
    /// history is unavailable, falls back to the legacy live provider
    /// path so users without Supabase still see a refresh.
    func refreshRecent(days: Int = 30) async {
        isRefreshingRecent = true
        defer { isRefreshingRecent = false }

        let cal = Calendar.current
        let to = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -max(1, days), to: to) ?? to

        if usedPersistedHistory, let vid = lastVineyardId {
            do {
                let rows = try await PersistedRainfallService.fetchDailyRainfall(
                    vineyardId: vid, from: from, to: to
                )
                await mergePersisted(
                    rows: rows,
                    vineyardId: vid,
                    today: to
                )
                return
            } catch {
                print("[RainfallCalendar] persisted refresh failed: \(error.localizedDescription)")
            }
        }

        guard let lat = lastLatitude, let lon = lastLongitude else { return }
        let recent = await RainfallHistoryService.fetchDailyRainfall(
            vineyardId: lastVineyardId,
            latitude: lat,
            longitude: lon,
            from: from,
            to: Date(),
            weatherStationId: lastWeatherStationId,
            davisRecentOnlyDays: days
        )

        // Merge recent results into the existing yearly dataset so older
        // dates remain unchanged.
        var merged = dailyRainMm
        var mergedSources = sources
        for (k, v) in recent.dailyMm {
            merged[k] = v
        }
        for (k, v) in recent.sources {
            mergedSources[k] = v
        }
        dailyRainMm = merged
        sources = mergedSources
        providerLabel = recent.providerLabel
        stationName = recent.stationName
        isMeasured = recent.isMeasured || isMeasured
        fallbackUsed = recent.fallbackUsed || fallbackUsed
        rateLimited = recent.rateLimited
        fallbackNote = recent.fallbackReason ?? fallbackNote
        manualDaysCovered = mergedSources.values.filter { $0 == .manual }.count
        davisDaysCovered = mergedSources.values.filter { $0 == .davis }.count
        wuDaysCovered = mergedSources.values.filter { $0 == .wunderground }.count
        archiveDaysCovered = mergedSources.values.filter { $0 == .archive }.count
        coverageSummary = coverageSummaryString(
            manual: manualDaysCovered,
            davis: davisDaysCovered,
            wu: wuDaysCovered,
            archive: archiveDaysCovered
        )
        lastUpdated = Date()
    }

    private func apply(_ result: RainfallHistoryResult) {
        self.dailyRainMm = result.dailyMm
        self.sources = result.sources
        self.providerLabel = result.providerLabel
        self.stationName = result.stationName
        self.isMeasured = result.isMeasured
        self.fallbackUsed = result.fallbackUsed
        self.rateLimited = result.rateLimited
        self.manualDaysCovered = 0
        self.davisDaysCovered = result.davisDaysCovered
        self.wuDaysCovered = result.wuDaysCovered
        self.archiveDaysCovered = result.archiveDaysCovered
        self.coverageSummary = result.coverageSummary
        self.usedPersistedHistory = false
        self.todayFromLiveDavis = false
        self.fallbackNote = result.fallbackReason
            ?? (result.isMeasured
                ? "Daily totals from station archive"
                : "Daily history via Open-Meteo Archive")
        self.lastUpdated = Date()
    }

    /// Apply a fresh persisted-RPC result to the calendar state. If today
    /// has no persisted row, fall back to the live Davis cached current
    /// reading so the most recent day is never blank when Davis is
    /// configured.
    private func applyPersisted(
        rows: [PersistedRainfallDay],
        vineyardId: UUID,
        today: Date
    ) async {
        var daily: [Date: Double] = [:]
        var sources: [Date: RainfallSource] = [:]
        var manualCount = 0
        var davisCount = 0
        var wuCount = 0
        var openMeteoCount = 0
        var resolvedStationName: String?
        var resolvedWuStationName: String?
        var todayHadValue = false
        var hasFreshPersisted = false

        let todayKey = RainfallDateKey.todayKey()
        // Persisted rows are considered "fresh enough to be today" if they
        // are within ±1 day of the device's local today. This handles the
        // case where the device tz and vineyard tz disagree about which
        // calendar date "now" falls on (e.g. device UTC = May 6, vineyard
        // AEST = May 7). Without this, the live-Davis fallback would fire
        // and write today's rainfall to the wrong calendar day.
        let oneDay: TimeInterval = 86_400

        for row in rows {
            let key = RainfallDateKey.startOfDay(row.date)
            guard let mm = row.rainfallMm else { continue }
            daily[key] = mm
            switch row.source {
            case "manual":
                sources[key] = .manual
                manualCount += 1
            case "davis_weatherlink":
                sources[key] = .davis
                davisCount += 1
                if resolvedStationName == nil,
                   let name = row.stationName, !name.isEmpty {
                    resolvedStationName = name
                }
            case "wunderground_pws":
                sources[key] = .wunderground
                wuCount += 1
                if resolvedWuStationName == nil {
                    if let name = row.stationName, !name.isEmpty {
                        resolvedWuStationName = name
                    } else if let sid = row.stationId, !sid.isEmpty {
                        resolvedWuStationName = sid
                    }
                }
            case "open_meteo":
                sources[key] = .archive
                openMeteoCount += 1
            default:
                sources[key] = .archive
            }
            if key == todayKey { todayHadValue = true }
            if abs(key.timeIntervalSince(todayKey)) <= oneDay {
                hasFreshPersisted = true
            }
        }

        // Today fallback: only fire when persisted history has no row
        // anywhere within ±1 day of "today". This avoids double-writing
        // when the device tz and vineyard tz disagree about today's date.
        var todayFromLive = false
        if !todayHadValue && !hasFreshPersisted {
            if let snap = try? await WeatherCurrentService().fetchCachedCurrent(vineyardId: vineyardId),
               let mm = snap.rainTodayMm {
                daily[todayKey] = mm
                sources[todayKey] = .davis
                davisCount += 1
                todayFromLive = true
                if resolvedStationName == nil,
                   let name = snap.stationName, !name.isEmpty {
                    resolvedStationName = name
                }
            }
        }
        _ = today

        let totalCovered = manualCount + davisCount + wuCount + openMeteoCount
        let dominantLabel: String
        if davisCount > 0, davisCount >= manualCount, davisCount >= wuCount, davisCount >= openMeteoCount {
            dominantLabel = "Davis WeatherLink" + (resolvedStationName.map { " — \($0)" } ?? "")
        } else if manualCount > 0, manualCount >= wuCount, manualCount >= openMeteoCount {
            dominantLabel = "Manual entries"
        } else if wuCount > 0, wuCount >= openMeteoCount {
            dominantLabel = "Weather Underground" + (resolvedWuStationName.map { " — \($0)" } ?? "")
        } else if openMeteoCount > 0 {
            dominantLabel = "Open-Meteo Archive"
        } else {
            dominantLabel = "No vineyard rainfall recorded yet"
        }

        self.dailyRainMm = daily
        self.sources = sources
        self.providerLabel = "Source: Vineyard rainfall history (\(dominantLabel))"
        // Prefer Davis station name when present; otherwise expose the WU
        // station label so the source card can render it.
        self.stationName = resolvedStationName ?? resolvedWuStationName
        self.isMeasured = davisCount > 0 || manualCount > 0 || wuCount > 0
        self.fallbackUsed = false
        self.rateLimited = false
        self.manualDaysCovered = manualCount
        self.davisDaysCovered = davisCount
        self.wuDaysCovered = wuCount
        self.archiveDaysCovered = openMeteoCount
        self.coverageSummary = coverageSummaryString(
            manual: manualCount, davis: davisCount, wu: wuCount, archive: openMeteoCount
        )
        self.usedPersistedHistory = true
        self.todayFromLiveDavis = todayFromLive
        self.fallbackNote = totalCovered == 0
            ? "No persisted rainfall yet — tap Refresh Davis now in Weather Data settings to populate today."
            : (todayFromLive
                ? "Persisted vineyard history. Today shown from live Davis cache."
                : "Persisted vineyard rainfall (manual → Davis → Weather Underground → Open-Meteo).")
        self.lastUpdated = Date()
    }

    /// Merge a recent-window persisted refresh into the existing year so
    /// older dates stay intact.
    private func mergePersisted(
        rows: [PersistedRainfallDay],
        vineyardId: UUID,
        today: Date
    ) async {
        var merged = dailyRainMm
        var mergedSources = sources
        var resolvedStationName = stationName
        var todayHadValue = false
        var hasFreshPersisted = false

        let todayKey = RainfallDateKey.todayKey()
        let oneDay: TimeInterval = 86_400

        for row in rows {
            let key = RainfallDateKey.startOfDay(row.date)
            guard let mm = row.rainfallMm else {
                // Persisted RPC explicitly says no data for this day.
                merged.removeValue(forKey: key)
                mergedSources.removeValue(forKey: key)
                continue
            }
            merged[key] = mm
            switch row.source {
            case "manual":
                mergedSources[key] = .manual
            case "davis_weatherlink":
                mergedSources[key] = .davis
                if resolvedStationName == nil,
                   let name = row.stationName, !name.isEmpty {
                    resolvedStationName = name
                }
            case "wunderground_pws":
                mergedSources[key] = .wunderground
                if resolvedStationName == nil {
                    if let name = row.stationName, !name.isEmpty {
                        resolvedStationName = name
                    } else if let sid = row.stationId, !sid.isEmpty {
                        resolvedStationName = sid
                    }
                }
            case "open_meteo":
                mergedSources[key] = .archive
            default:
                mergedSources[key] = .archive
            }
            if key == todayKey { todayHadValue = true }
            if abs(key.timeIntervalSince(todayKey)) <= oneDay {
                hasFreshPersisted = true
            }
        }

        var todayFromLive = false
        if !todayHadValue && !hasFreshPersisted {
            if let snap = try? await WeatherCurrentService().fetchCachedCurrent(vineyardId: vineyardId),
               let mm = snap.rainTodayMm {
                merged[todayKey] = mm
                mergedSources[todayKey] = .davis
                todayFromLive = true
                if resolvedStationName == nil,
                   let name = snap.stationName, !name.isEmpty {
                    resolvedStationName = name
                }
            }
        }
        _ = today

        self.dailyRainMm = merged
        self.sources = mergedSources
        self.stationName = resolvedStationName
        self.manualDaysCovered = mergedSources.values.filter { $0 == .manual }.count
        self.davisDaysCovered = mergedSources.values.filter { $0 == .davis }.count
        self.wuDaysCovered = mergedSources.values.filter { $0 == .wunderground }.count
        self.archiveDaysCovered = mergedSources.values.filter { $0 == .archive }.count
        self.isMeasured = manualDaysCovered > 0 || davisDaysCovered > 0 || wuDaysCovered > 0
        self.fallbackUsed = false
        self.rateLimited = false
        self.coverageSummary = coverageSummaryString(
            manual: manualDaysCovered,
            davis: davisDaysCovered,
            wu: wuDaysCovered,
            archive: archiveDaysCovered
        )
        self.todayFromLiveDavis = todayFromLive
        self.fallbackNote = todayFromLive
            ? "Persisted vineyard history. Today shown from live Davis cache."
            : "Persisted vineyard rainfall (manual → Davis → Weather Underground → Open-Meteo)."
        self.lastUpdated = Date()
    }

    private func coverageSummaryString(manual: Int = 0, davis: Int, wu: Int, archive: Int) -> String? {
        var parts: [String] = []
        if manual > 0 { parts.append("Manual: \(manual) day\(manual == 1 ? "" : "s")") }
        if davis > 0 { parts.append("Davis: \(davis) day\(davis == 1 ? "" : "s")") }
        if wu > 0 { parts.append("WU: \(wu) day\(wu == 1 ? "" : "s")") }
        if archive > 0 { parts.append("Open-Meteo: \(archive) day\(archive == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Per-month summary derived from a `[Date: Double]` rainfall map.
nonisolated struct RainfallMonthSummary: Sendable, Hashable, Identifiable {
    let month: Int          // 1...12
    let totalMm: Double
    let rainDays: Int
    let wettestDay: Int?    // day of month, or nil
    let wettestDayMm: Double?
    let averageMm: Double   // average across days that have a value
    let daysWithData: Int

    var id: Int { month }
}

/// Annual roll-up.
nonisolated struct RainfallAnnualSummary: Sendable, Hashable {
    let year: Int
    let totalMm: Double
    let rainDays: Int
    let wettestDay: Date?
    let wettestDayMm: Double?
    let wettestMonth: Int?
    let wettestMonthMm: Double?
    let driestMonth: Int?
    let driestMonthMm: Double?
    let daysWithData: Int
}

enum RainfallCalendarMath {
    static let rainDayThresholdMm: Double = 0.2

    static func monthSummaries(year: Int, daily: [Date: Double]) -> [RainfallMonthSummary] {
        // Keys are UTC-anchored calendar dates (see RainfallDateKey), so we
        // must read components in UTC too — using device tz here would
        // shift days back/forward depending on the local offset.
        let cal = RainfallDateKey.utcCalendar
        var byMonth: [Int: [(day: Int, mm: Double)]] = [:]
        for (date, mm) in daily {
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            guard comps.year == year, let m = comps.month, let d = comps.day else { continue }
            byMonth[m, default: []].append((d, mm))
        }
        return (1...12).map { m in
            let entries = byMonth[m] ?? []
            let total = entries.reduce(0) { $0 + $1.mm }
            let rainDays = entries.filter { $0.mm >= rainDayThresholdMm }.count
            let wettest = entries.max(by: { $0.mm < $1.mm })
            let avg = entries.isEmpty ? 0 : total / Double(entries.count)
            return RainfallMonthSummary(
                month: m,
                totalMm: total,
                rainDays: rainDays,
                wettestDay: wettest.map { $0.day },
                wettestDayMm: wettest.map { $0.mm },
                averageMm: avg,
                daysWithData: entries.count
            )
        }
    }

    static func annual(year: Int, daily: [Date: Double], months: [RainfallMonthSummary]) -> RainfallAnnualSummary {
        let cal = RainfallDateKey.utcCalendar
        let total = months.reduce(0) { $0 + $1.totalMm }
        let rainDays = months.reduce(0) { $0 + $1.rainDays }
        let daysWithData = months.reduce(0) { $0 + $1.daysWithData }

        var wettestDate: Date?
        var wettestMm: Double = -1
        for (date, mm) in daily {
            let comps = cal.dateComponents([.year], from: date)
            guard comps.year == year else { continue }
            if mm > wettestMm {
                wettestMm = mm
                wettestDate = date
            }
        }

        let nonZeroMonths = months.filter { $0.daysWithData > 0 }
        let wettestMonth = nonZeroMonths.max(by: { $0.totalMm < $1.totalMm })
        let driestMonth = nonZeroMonths.min(by: { $0.totalMm < $1.totalMm })

        return RainfallAnnualSummary(
            year: year,
            totalMm: total,
            rainDays: rainDays,
            wettestDay: wettestDate,
            wettestDayMm: wettestMm > 0 ? wettestMm : nil,
            wettestMonth: wettestMonth?.month,
            wettestMonthMm: wettestMonth?.totalMm,
            driestMonth: driestMonth?.month,
            driestMonthMm: driestMonth?.totalMm,
            daysWithData: daysWithData
        )
    }
}
