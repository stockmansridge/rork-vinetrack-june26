import Foundation

/// Wraps a Davis fetch error plus a flag for whether it was a rate-limit
/// response, so the shared Davis path can show a friendly 429 message.
nonisolated struct DavisFetchFailure: Error, Sendable {
    let error: any Error
    let rateLimited: Bool
}

/// Provenance for a single daily rainfall value.
nonisolated enum RainfallSource: String, Sendable, Hashable, Codable {
    case davis
    case wunderground
    case archive
    case manual
    case missing
}

/// A single daily rainfall observation with provenance.
nonisolated struct RainfallObservation: Sendable, Hashable, Identifiable {
    let date: Date
    let rainfallMm: Double
    let isMeasured: Bool
    let provider: WeatherProvider
    let stationName: String?
    let source: RainfallSource

    var id: Date { date }
}

/// Result of a rainfall history fetch — daily totals plus source labels and
/// any fallback warning text the UI should surface.
nonisolated struct RainfallHistoryResult: Sendable, Hashable {
    let dailyMm: [Date: Double]
    /// Per-day provenance (start-of-day → source). Days that returned no
    /// data are marked `.missing` and excluded from `dailyMm`.
    let sources: [Date: RainfallSource]
    /// The provider the user *configured*. May differ from where data came
    /// from when fallback occurred.
    let configuredProvider: WeatherProvider
    /// The provider that actually supplied the data.
    let effectiveProvider: WeatherProvider
    let providerLabel: String
    let stationName: String?
    /// `true` when at least some of the values are measured station observations.
    let isMeasured: Bool
    let fallbackUsed: Bool
    let fallbackReason: String?
    let coveredFrom: Date
    let coveredTo: Date
    let recordCount: Int
    let davisDaysCovered: Int
    let wuDaysCovered: Int
    let archiveDaysCovered: Int
    /// Short coverage breakdown for the UI, e.g. "Davis: 87 days · Archive: 245 days".
    let coverageSummary: String?
    /// `true` when WeatherLink returned HTTP 429 during this fetch. The UI
    /// should surface a friendly message and back off.
    let rateLimited: Bool

    static let empty = RainfallHistoryResult(
        dailyMm: [:],
        sources: [:],
        configuredProvider: .automatic,
        effectiveProvider: .automatic,
        providerLabel: "Source: Automatic Forecast / Historical Weather",
        stationName: nil,
        isMeasured: false,
        fallbackUsed: false,
        fallbackReason: nil,
        coveredFrom: Date(),
        coveredTo: Date(),
        recordCount: 0,
        davisDaysCovered: 0,
        wuDaysCovered: 0,
        archiveDaysCovered: 0,
        coverageSummary: nil,
        rateLimited: false
    )
}

/// Resolves the active weather provider and fetches daily rainfall, preferring
/// the local station (Davis WeatherLink) over forecast/archive sources.
///
/// Provider priority (for actual / historical rainfall):
/// A. Davis WeatherLink — selected, credentials saved, connection tested,
///    station selected.
/// B. Weather Underground (selected) — uses WU per-day history endpoint.
/// C. Automatic — Open-Meteo Archive.
@MainActor
enum RainfallHistoryService {
    /// We cap direct Davis archive fetches to this many trailing days so the
    /// total number of WeatherLink v2 calls (24h chunks) stays reasonable.
    /// Older portions of a year-long range are filled in from Open-Meteo
    /// Archive and clearly labelled as fallback data.
    static let davisMaxDaysWindow: Int = 120

    /// WU's per-day daily-history endpoint requires one HTTP call per day.
    /// We cap the live WU window so a year-long calendar fetch doesn't
    /// fire 365 calls. Older portions are filled from the Open-Meteo
    /// archive and labelled as fallback data.
    static let wuMaxDaysWindow: Int = 60

    static func fetchDailyRainfall(
        vineyardId: UUID?,
        latitude: Double,
        longitude: Double,
        from: Date,
        to: Date,
        weatherStationId: String?,
        davisRecentOnlyDays: Int? = nil
    ) async -> RainfallHistoryResult {
        let cal = Calendar.current
        let safeFrom = cal.startOfDay(for: from)
        let endOfToday = (cal.date(bySettingHour: 23, minute: 59, second: 59, of: cal.startOfDay(for: Date())) ?? Date())
        let safeTo = min(to, endOfToday)
        guard safeFrom <= safeTo else {
            return RainfallHistoryResult(
                dailyMm: [:],
                sources: [:],
                configuredProvider: .automatic,
                effectiveProvider: .automatic,
                providerLabel: "Source: Automatic Forecast / Historical Weather",
                stationName: nil,
                isMeasured: false,
                fallbackUsed: false,
                fallbackReason: nil,
                coveredFrom: safeFrom,
                coveredTo: safeTo,
                recordCount: 0,
                davisDaysCovered: 0,
                wuDaysCovered: 0,
                archiveDaysCovered: 0,
                coverageSummary: nil,
                rateLimited: false
            )
        }

        // Make sure the vineyard's Davis integration metadata (if any)
        // has been pulled into the local config before resolving the
        // active provider. This is what allows operator users — who
        // never opened Weather Data settings — to see and use the
        // shared Davis source automatically.
        if let vid = vineyardId {
            await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: vid)
        }

        let status: WeatherSourceStatus? = vineyardId.map {
            WeatherProviderResolver.resolve(for: $0, weatherStationId: weatherStationId)
        }
        let configuredProvider: WeatherProvider = status?.provider ?? .automatic

        // Whether the requested window ends in the current calendar year.
        let currentYear = cal.component(.year, from: Date())
        let endYear = cal.component(.year, from: safeTo)
        let isPastYearOnly = endYear < currentYear

        // MARK: Davis path
        if let vid = vineyardId,
           let s = status,
           s.provider == .davis,
           s.quality != .forecastOnly,
           !isPastYearOnly {
            let cfg = WeatherProviderStore.shared.config(for: vid)
            let stationLabel = (cfg.davisStationName?.isEmpty == false ? cfg.davisStationName! : (cfg.davisStationId ?? ""))
            if let stationId = cfg.davisStationId, !stationId.isEmpty {

                // Limit Davis fetch window to last `davisMaxDaysWindow` days,
                // or to the explicit `davisRecentOnlyDays` window when the
                // caller is doing a "refresh recent" pass.
                let windowDays = max(1, min(davisRecentOnlyDays ?? davisMaxDaysWindow, davisMaxDaysWindow))
                let earliestDavis = cal.date(byAdding: .day, value: -windowDays, to: safeTo) ?? safeFrom
                let davisStart = max(safeFrom, earliestDavis)

                // Prefer the vineyard-shared proxy whenever the
                // integration is configured for the vineyard. Operators
                // never hold local Keychain credentials, but they can
                // still load Davis rainfall via the proxy.
                let useProxy = cfg.davisIsVineyardShared
                    && cfg.davisVineyardHasServerCredentials

                if useProxy {
                    return await runDavisProxyPath(
                        vineyardId: vid,
                        stationId: stationId,
                        stationLabel: stationLabel,
                        stationName: cfg.davisStationName,
                        safeFrom: safeFrom,
                        safeTo: safeTo,
                        davisStart: davisStart,
                        latitude: latitude,
                        longitude: longitude
                    )
                }

                if let apiKey = WeatherKeychain.get(.apiKey),
                   let apiSecret = WeatherKeychain.get(.apiSecret) {
                    return await runDavisPath(
                        vineyardId: vid,
                        apiKey: apiKey,
                        apiSecret: apiSecret,
                        stationId: stationId,
                        stationLabel: stationLabel,
                        stationName: cfg.davisStationName,
                        safeFrom: safeFrom,
                        safeTo: safeTo,
                        davisStart: davisStart,
                        latitude: latitude,
                        longitude: longitude
                    )
                }
            }
        }

        // MARK: Weather Underground path
        if let s = status,
           s.provider == .wunderground,
           let stationId = weatherStationId,
           !stationId.isEmpty,
           !isPastYearOnly {
            let apiKey = AppConfig.wundergroundAPIKey
            if !apiKey.isEmpty {
                let earliestWU = cal.date(byAdding: .day, value: -wuMaxDaysWindow, to: safeTo) ?? safeFrom
                let wuStart = max(safeFrom, earliestWU)
                do {
                    let wu = try await WeatherUndergroundRainfallService.fetchDailyRainfall(
                        apiKey: apiKey,
                        stationId: stationId,
                        from: wuStart,
                        to: safeTo
                    )

                    var merged = wu.dailyMm
                    var sources: [Date: RainfallSource] = [:]
                    for (k, _) in wu.dailyMm { sources[k] = .wunderground }
                    var fallbackUsed = false
                    var fallbackReason: String?
                    var archiveCount = 0

                    if wuStart > safeFrom {
                        let priorEnd = cal.date(byAdding: .day, value: -1, to: wuStart) ?? safeFrom
                        if let archive = try? await OpenMeteoRainfallArchive.fetchDaily(
                            latitude: latitude,
                            longitude: longitude,
                            from: safeFrom,
                            to: priorEnd
                        ) {
                            for (k, v) in archive where merged[k] == nil {
                                merged[k] = v
                                sources[k] = .archive
                                archiveCount += 1
                            }
                        }
                        fallbackUsed = true
                        fallbackReason = "Recent rainfall from Weather Underground. Older dates filled from automatic archive."
                    }

                    let wuCount = wu.dailyMm.count
                    let label: String
                    if wuCount == 0 {
                        label = "Source: Open-Meteo Archive (WU returned no data)"
                    } else if archiveCount > 0 {
                        label = "Source: Mixed — Weather Underground (\(stationId)) + Open-Meteo Archive"
                    } else {
                        label = "Source: Weather Underground — \(stationId)"
                    }

                    return RainfallHistoryResult(
                        dailyMm: merged,
                        sources: sources,
                        configuredProvider: .wunderground,
                        effectiveProvider: wuCount > 0 ? .wunderground : .automatic,
                        providerLabel: label,
                        stationName: stationId,
                        isMeasured: wuCount > 0,
                        fallbackUsed: fallbackUsed,
                        fallbackReason: fallbackReason,
                        coveredFrom: safeFrom,
                        coveredTo: safeTo,
                        recordCount: wu.recordCount + archiveCount,
                        davisDaysCovered: 0,
                        wuDaysCovered: wuCount,
                        archiveDaysCovered: archiveCount,
                        coverageSummary: coverageSummary(davis: 0, wu: wuCount, archive: archiveCount),
                        rateLimited: false
                    )
                } catch {
                    let archive = (try? await OpenMeteoRainfallArchive.fetchDaily(
                        latitude: latitude,
                        longitude: longitude,
                        from: safeFrom,
                        to: safeTo
                    )) ?? [:]
                    var sources: [Date: RainfallSource] = [:]
                    for (k, _) in archive { sources[k] = .archive }
                    return RainfallHistoryResult(
                        dailyMm: archive,
                        sources: sources,
                        configuredProvider: .wunderground,
                        effectiveProvider: .automatic,
                        providerLabel: "Source: Open-Meteo Archive (WU unavailable)",
                        stationName: stationId,
                        isMeasured: false,
                        fallbackUsed: true,
                        fallbackReason: "Weather Underground data unavailable — using fallback. (\(error.localizedDescription))",
                        coveredFrom: safeFrom,
                        coveredTo: safeTo,
                        recordCount: archive.count,
                        davisDaysCovered: 0,
                        wuDaysCovered: 0,
                        archiveDaysCovered: archive.count,
                        coverageSummary: coverageSummary(davis: 0, wu: 0, archive: archive.count),
                        rateLimited: false
                    )
                }
            }
        }

        // MARK: Fallback path (Automatic / unconfigured / past years)
        let archive = (try? await OpenMeteoRainfallArchive.fetchDaily(
            latitude: latitude,
            longitude: longitude,
            from: safeFrom,
            to: safeTo
        )) ?? [:]
        var sources: [Date: RainfallSource] = [:]
        for (k, _) in archive { sources[k] = .archive }

        let label: String
        var fallbackUsed = false
        var fallbackReason: String?
        switch configuredProvider {
        case .davis:
            let cfg = vineyardId.map { WeatherProviderStore.shared.config(for: $0) }
            label = "Source: Open-Meteo Archive"
            fallbackUsed = true
            if isPastYearOnly {
                fallbackReason = "Historical archive rainfall. Davis station history is used for recent periods only."
            } else if let cfg {
                if cfg.davisHasCredentials,
                   cfg.davisConnectionTested,
                   (cfg.davisStationId ?? "").isEmpty {
                    fallbackReason = "Davis connected, but no station is selected. Select a Davis station to use local rainfall."
                } else if cfg.davisHasCredentials, !cfg.davisConnectionTested {
                    fallbackReason = "Davis credentials saved — run Test Connection to use local rainfall."
                } else {
                    fallbackReason = "Using automatic archive rainfall. Connect Davis WeatherLink or Weather Underground for local station history."
                }
            } else {
                fallbackReason = "Using automatic archive rainfall. Connect Davis WeatherLink or Weather Underground for local station history."
            }
        case .wunderground:
            label = "Source: Open-Meteo Archive"
            fallbackUsed = true
            if isPastYearOnly {
                fallbackReason = "Historical archive rainfall. Weather Underground is used for recent periods only."
            } else {
                fallbackReason = "Weather Underground selected but no station is set. Choose a WU station to use local rainfall."
            }
        case .automatic:
            label = "Source: Open-Meteo Archive"
            fallbackUsed = true
            fallbackReason = "Using automatic archive rainfall. Connect Davis WeatherLink or Weather Underground for local station history."
        }

        return RainfallHistoryResult(
            dailyMm: archive,
            sources: sources,
            configuredProvider: configuredProvider,
            effectiveProvider: .automatic,
            providerLabel: label,
            stationName: nil,
            isMeasured: false,
            fallbackUsed: fallbackUsed,
            fallbackReason: fallbackReason,
            coveredFrom: safeFrom,
            coveredTo: safeTo,
            recordCount: archive.count,
            davisDaysCovered: 0,
            wuDaysCovered: 0,
            archiveDaysCovered: archive.count,
            coverageSummary: coverageSummary(davis: 0, wu: 0, archive: archive.count),
            rateLimited: false
        )
    }

    // MARK: - Davis path with cache + delta fetch

    /// Vineyard-shared proxy variant: fetches Davis rainfall via the
    /// `davis-proxy` Edge Function (no local Keychain credentials
    /// required), so every member of the vineyard sees the same data.
    private static func runDavisProxyPath(
        vineyardId: UUID,
        stationId: String,
        stationLabel: String,
        stationName: String?,
        safeFrom: Date,
        safeTo: Date,
        davisStart: Date,
        latitude: Double,
        longitude: Double
    ) async -> RainfallHistoryResult {
        await runDavisCommon(
            vineyardId: vineyardId,
            stationId: stationId,
            stationLabel: stationLabel,
            stationName: stationName,
            safeFrom: safeFrom,
            safeTo: safeTo,
            davisStart: davisStart,
            latitude: latitude,
            longitude: longitude,
            fetchChunk: { from, to in
                do {
                    let r = try await VineyardDavisProxyService.fetchHistoricRainfall(
                        vineyardId: vineyardId,
                        stationId: stationId,
                        from: from,
                        to: to
                    )
                    return .success(r)
                } catch let e as VineyardDavisProxyError {
                    if case .rateLimited = e {
                        return .failure(DavisFetchFailure(error: e, rateLimited: true))
                    }
                    return .failure(DavisFetchFailure(error: e, rateLimited: false))
                } catch {
                    return .failure(DavisFetchFailure(error: error, rateLimited: false))
                }
            }
        )
    }

    private static func runDavisPath(
        vineyardId: UUID,
        apiKey: String,
        apiSecret: String,
        stationId: String,
        stationLabel: String,
        stationName: String?,
        safeFrom: Date,
        safeTo: Date,
        davisStart: Date,
        latitude: Double,
        longitude: Double
    ) async -> RainfallHistoryResult {
        await runDavisCommon(
            vineyardId: vineyardId,
            stationId: stationId,
            stationLabel: stationLabel,
            stationName: stationName,
            safeFrom: safeFrom,
            safeTo: safeTo,
            davisStart: davisStart,
            latitude: latitude,
            longitude: longitude,
            fetchChunk: { from, to in
                do {
                    let r = try await DavisWeatherLinkService.fetchDailyRainfall(
                        apiKey: apiKey,
                        apiSecret: apiSecret,
                        stationId: stationId,
                        from: from,
                        to: to
                    )
                    return .success(r)
                } catch let e as DavisWeatherLinkError {
                    if case .http(let code) = e, code == 429 {
                        return .failure(DavisFetchFailure(error: e, rateLimited: true))
                    }
                    return .failure(DavisFetchFailure(error: e, rateLimited: false))
                } catch {
                    return .failure(DavisFetchFailure(error: error, rateLimited: false))
                }
            }
        )
    }

    /// Shared Davis path used by both the direct (Keychain) client and
    /// the vineyard-shared proxy client. The only thing that varies is
    /// how a 24h+ chunk is fetched.
    private static func runDavisCommon(
        vineyardId: UUID,
        stationId: String,
        stationLabel: String,
        stationName: String?,
        safeFrom: Date,
        safeTo: Date,
        davisStart: Date,
        latitude: Double,
        longitude: Double,
        fetchChunk: (_ from: Date, _ to: Date) async -> Result<DavisDailyRainfall, DavisFetchFailure>
    ) async -> RainfallHistoryResult {
        let cal = Calendar.current

        // Pull cached values for any years that intersect the Davis window.
        let years = yearsSpanning(from: davisStart, to: safeTo)
        var davisData: [Date: Double] = [:]
        for y in years {
            for (k, v) in DavisRainfallCache.load(
                vineyardId: vineyardId, stationId: stationId, year: y
            ) {
                let comps = cal.dateComponents([.year], from: k)
                if comps.year == y, k >= davisStart, k <= cal.startOfDay(for: safeTo) {
                    davisData[k] = v
                }
            }
        }

        // Determine which days inside the Davis window still need fetching.
        let allDays = enumerateDays(from: davisStart, to: safeTo)
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let mustRefresh: Set<Date> = [today, yesterday]

        let toFetch = allDays.filter { d in
            mustRefresh.contains(d) || davisData[d] == nil
        }

        var rateLimited = false
        var davisError: Error?

        if !toFetch.isEmpty {
            let ranges = contiguousRanges(of: toFetch)
            for range in ranges {
                let chunkFrom = range.start
                let chunkTo = cal.date(byAdding: .day, value: 1, to: range.end) ?? range.end.addingTimeInterval(86400)
                let outcome = await fetchChunk(chunkFrom, chunkTo)
                switch outcome {
                case .success(let result):
                    // For days inside the requested chunk that returned no
                    // record, treat them as 0 mm so we don't keep hammering
                    // the API on every reload (Davis simply omits empty days).
                    let chunkDays = enumerateDays(from: range.start, to: range.end)
                    for d in chunkDays {
                        davisData[d] = result.dailyMm[d] ?? 0
                    }
                case .failure(let info):
                    if info.rateLimited { rateLimited = true }
                    davisError = info.error
                }
                if davisError != nil { break }
            }

            // Persist whatever we have per year (even partial progress).
            for y in years {
                let yearOnly = davisData.filter { cal.component(.year, from: $0.key) == y }
                if !yearOnly.isEmpty {
                    DavisRainfallCache.save(
                        vineyardId: vineyardId,
                        stationId: stationId,
                        year: y,
                        daily: yearOnly
                    )
                }
            }
        }

        // Merge into the result map (Davis values).
        var merged: [Date: Double] = [:]
        var sources: [Date: RainfallSource] = [:]
        var davisCount = 0
        for (k, v) in davisData {
            merged[k] = v
            sources[k] = .davis
            davisCount += 1
        }

        // Fill anything outside the Davis window or any missing days from
        // Open-Meteo Archive.
        var archiveCount = 0
        if davisStart > safeFrom || davisError != nil || mustRefresh.contains(where: { merged[$0] == nil }) {
            let archive = (try? await OpenMeteoRainfallArchive.fetchDaily(
                latitude: latitude,
                longitude: longitude,
                from: safeFrom,
                to: safeTo
            )) ?? [:]
            for (k, v) in archive where merged[k] == nil {
                merged[k] = v
                sources[k] = .archive
                archiveCount += 1
            }
        }

        // Build labels and fallback messages.
        let usedFallback = archiveCount > 0 || davisError != nil
        let label: String
        if davisCount == 0 {
            label = "Source: Open-Meteo Archive (Davis unavailable)"
        } else if archiveCount > 0 {
            label = "Source: Mixed — Davis WeatherLink (\(stationLabel)) + Open-Meteo Archive"
        } else {
            label = "Source: Davis WeatherLink — \(stationLabel)"
        }

        var fallbackReason: String?
        if rateLimited {
            fallbackReason = "WeatherLink rate limit reached. Showing archive rainfall for now — try again in a few minutes."
        } else if let davisError, davisCount == 0 {
            fallbackReason = "Davis data unavailable for this period — using fallback. (\(davisError.localizedDescription))"
        } else if davisError != nil {
            fallbackReason = "Some Davis data unavailable — older dates filled from automatic archive."
        } else if archiveCount > 0 && davisCount > 0 {
            fallbackReason = "Recent rainfall from Davis. Older dates filled from automatic archive."
        } else if archiveCount > 0 {
            fallbackReason = "Using automatic archive rainfall."
        }

        return RainfallHistoryResult(
            dailyMm: merged,
            sources: sources,
            configuredProvider: .davis,
            effectiveProvider: davisCount > 0 ? .davis : .automatic,
            providerLabel: label,
            stationName: stationName,
            isMeasured: davisCount > 0,
            fallbackUsed: usedFallback,
            fallbackReason: fallbackReason,
            coveredFrom: safeFrom,
            coveredTo: safeTo,
            recordCount: davisCount + archiveCount,
            davisDaysCovered: davisCount,
            wuDaysCovered: 0,
            archiveDaysCovered: archiveCount,
            coverageSummary: coverageSummary(davis: davisCount, wu: 0, archive: archiveCount),
            rateLimited: rateLimited
        )
    }

    /// Convenience for "rainfall in the last N days" — used by Irrigation
    /// Advisor to offset the deficit calculation with measured rain.
    static func fetchRecentRainfall(
        vineyardId: UUID?,
        latitude: Double,
        longitude: Double,
        days: Int,
        weatherStationId: String?
    ) async -> RainfallHistoryResult {
        let cal = Calendar.current
        let to = Date()
        let from = cal.date(byAdding: .day, value: -max(1, days), to: cal.startOfDay(for: to))
            ?? to.addingTimeInterval(-Double(max(1, days)) * 86400)
        return await fetchDailyRainfall(
            vineyardId: vineyardId,
            latitude: latitude,
            longitude: longitude,
            from: from,
            to: to,
            weatherStationId: weatherStationId
        )
    }

    /// Recent-window rainfall preferring persisted vineyard history
    /// (`get_daily_rainfall` RPC). The RPC already prioritises
    /// `manual > davis_weatherlink > open_meteo` per day, so this is the
    /// preferred source for irrigation deficit calculations.
    ///
    /// Today is only ever filled from the live Davis cached snapshot
    /// (`get_vineyard_current_weather`) when persisted history has no
    /// row for today yet. Older days are never re-fetched live — that
    /// avoids hammering Davis on every irrigation refresh.
    ///
    /// Falls back to `fetchRecentRainfall` (legacy live path) when no
    /// vineyard is selected, the RPC fails, or the RPC returned no
    /// usable values and no live Davis snapshot exists.
    static func fetchRecentRainfallPreferringPersisted(
        vineyardId: UUID?,
        latitude: Double,
        longitude: Double,
        days: Int,
        weatherStationId: String?
    ) async -> RainfallHistoryResult {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -max(0, days - 1), to: today) ?? today

        if let vid = vineyardId {
            do {
                let rows = try await PersistedRainfallService.fetchDailyRainfall(
                    vineyardId: vid, from: from, to: today
                )
                if let result = await buildRecentResultFromPersisted(
                    rows: rows,
                    vineyardId: vid,
                    from: from,
                    to: today
                ) {
                    return result
                }
            } catch {
                print("[Irrigation] persisted recent rainfall fetch failed: \(error.localizedDescription) — falling back to live")
            }
        }

        return await fetchRecentRainfall(
            vineyardId: vineyardId,
            latitude: latitude,
            longitude: longitude,
            days: days,
            weatherStationId: weatherStationId
        )
    }

    /// Build a `RainfallHistoryResult` from a persisted-RPC response,
    /// merging in today's value from the live Davis cache when needed.
    /// Returns `nil` when there is genuinely nothing to show, so the
    /// caller can fall back to the legacy live path.
    private static func buildRecentResultFromPersisted(
        rows: [PersistedRainfallDay],
        vineyardId: UUID,
        from: Date,
        to: Date
    ) async -> RainfallHistoryResult? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var daily: [Date: Double] = [:]
        var sourceMap: [Date: RainfallSource] = [:]
        var manualCount = 0
        var davisCount = 0
        var openMeteoCount = 0
        var resolvedStationName: String?
        var todayHadValue = false

        for row in rows {
            let key = cal.startOfDay(for: row.date)
            guard let mm = row.rainfallMm else { continue }
            daily[key] = mm
            switch row.source {
            case "manual":
                sourceMap[key] = .manual
                manualCount += 1
            case "davis_weatherlink":
                sourceMap[key] = .davis
                davisCount += 1
                if resolvedStationName == nil,
                   let n = row.stationName, !n.isEmpty {
                    resolvedStationName = n
                }
            case "open_meteo":
                sourceMap[key] = .archive
                openMeteoCount += 1
            default:
                sourceMap[key] = .archive
                openMeteoCount += 1
            }
            if cal.isDate(key, inSameDayAs: today) { todayHadValue = true }
        }

        // Only fall back to live Davis cache for today, and only when
        // the requested window actually includes today.
        var todayFromLive = false
        if !todayHadValue, cal.startOfDay(for: to) >= today {
            if let snap = try? await WeatherCurrentService().fetchCachedCurrent(vineyardId: vineyardId),
               let mm = snap.rainTodayMm {
                daily[today] = mm
                sourceMap[today] = .davis
                davisCount += 1
                todayFromLive = true
                if resolvedStationName == nil,
                   let n = snap.stationName, !n.isEmpty {
                    resolvedStationName = n
                }
            }
        }

        let total = manualCount + davisCount + openMeteoCount
        guard total > 0 else { return nil }

        let sourcesPresent = [manualCount > 0, davisCount > 0, openMeteoCount > 0].filter { $0 }.count
        let stationSuffix = resolvedStationName.map { " — \($0)" } ?? ""

        let label: String
        let effective: WeatherProvider
        if sourcesPresent > 1 {
            var parts: [String] = []
            if manualCount > 0 { parts.append("Manual") }
            if davisCount > 0 { parts.append("Davis WeatherLink\(stationSuffix)") }
            if openMeteoCount > 0 { parts.append("Open-Meteo") }
            label = "Source: Mixed — \(parts.joined(separator: " + "))"
            effective = davisCount > 0 ? .davis : .automatic
        } else if davisCount > 0 {
            label = "Source: Davis WeatherLink\(stationSuffix)"
            effective = .davis
        } else if manualCount > 0 {
            label = "Source: Manual entries"
            effective = .automatic
        } else {
            label = "Source: Open-Meteo Archive"
            effective = .automatic
        }

        let fallbackReason: String? = todayFromLive
            ? "Today shown from live Davis cache; older days from persisted vineyard history."
            : nil

        let coverage = persistedCoverageSummary(
            manual: manualCount,
            davis: davisCount,
            archive: openMeteoCount
        )

        return RainfallHistoryResult(
            dailyMm: daily,
            sources: sourceMap,
            configuredProvider: effective,
            effectiveProvider: effective,
            providerLabel: label,
            stationName: resolvedStationName,
            isMeasured: davisCount > 0 || manualCount > 0,
            fallbackUsed: false,
            fallbackReason: fallbackReason,
            coveredFrom: from,
            coveredTo: to,
            recordCount: total,
            davisDaysCovered: davisCount,
            wuDaysCovered: 0,
            archiveDaysCovered: openMeteoCount,
            coverageSummary: coverage,
            rateLimited: false
        )
    }

    private static func persistedCoverageSummary(manual: Int, davis: Int, archive: Int) -> String? {
        var parts: [String] = []
        if manual > 0 { parts.append("Manual: \(manual) day\(manual == 1 ? "" : "s")") }
        if davis > 0 { parts.append("Davis: \(davis) day\(davis == 1 ? "" : "s")") }
        if archive > 0 { parts.append("Open-Meteo: \(archive) day\(archive == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private static func coverageSummary(davis: Int, wu: Int, archive: Int) -> String? {
        var parts: [String] = []
        if davis > 0 { parts.append("Davis: \(davis) day\(davis == 1 ? "" : "s")") }
        if wu > 0 { parts.append("WU: \(wu) day\(wu == 1 ? "" : "s")") }
        if archive > 0 { parts.append("Archive: \(archive) day\(archive == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func yearsSpanning(from: Date, to: Date) -> [Int] {
        let cal = Calendar.current
        let start = cal.component(.year, from: from)
        let end = cal.component(.year, from: to)
        guard start <= end else { return [start] }
        return Array(start...end)
    }

    private static func enumerateDays(from: Date, to: Date) -> [Date] {
        let cal = Calendar.current
        var out: [Date] = []
        var cur = cal.startOfDay(for: from)
        let last = cal.startOfDay(for: to)
        while cur <= last {
            out.append(cur)
            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
        return out
    }

    private static func contiguousRanges(of days: [Date]) -> [(start: Date, end: Date)] {
        let cal = Calendar.current
        let sorted = days.sorted()
        guard !sorted.isEmpty else { return [] }
        var ranges: [(Date, Date)] = []
        var rangeStart = sorted[0]
        var prev = sorted[0]
        for d in sorted.dropFirst() {
            if let next = cal.date(byAdding: .day, value: 1, to: prev),
               cal.isDate(d, inSameDayAs: next) {
                prev = d
            } else {
                ranges.append((rangeStart, prev))
                rangeStart = d
                prev = d
            }
        }
        ranges.append((rangeStart, prev))
        return ranges
    }
}

// MARK: - Open-Meteo Archive (fallback)

nonisolated enum OpenMeteoRainfallArchive {
    /// Returns daily precipitation_sum keyed by start-of-day in
    /// `Calendar.current`.
    static func fetchDaily(
        latitude: Double,
        longitude: Double,
        from: Date,
        to: Date
    ) async throws -> [Date: Double] {
        let cal = Calendar.current
        let safeFrom = cal.startOfDay(for: from)
        let safeTo = min(to, cal.startOfDay(for: Date()).addingTimeInterval(24 * 3600 - 1))
        guard safeFrom <= safeTo else { return [:] }

        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = cal.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        let startStr = fmt.string(from: safeFrom)
        let endStr = fmt.string(from: safeTo)

        let urlString = "https://archive-api.open-meteo.com/v1/archive?latitude=\(latitude)&longitude=\(longitude)&start_date=\(startStr)&end_date=\(endStr)&daily=precipitation_sum&timezone=auto"
        guard let url = URL(string: urlString) else { return [:] }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return [:]
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let times = daily["time"] as? [String],
              let rains = daily["precipitation_sum"] as? [Any] else {
            return [:]
        }

        var map: [Date: Double] = [:]
        let count = min(times.count, rains.count)
        for i in 0..<count {
            guard let d = fmt.date(from: times[i]) else { continue }
            if let value = parseDouble(rains[i]) {
                map[cal.startOfDay(for: d)] = value
            }
        }
        return map
    }

    private static func parseDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        if value is NSNull { return nil }
        return nil
    }
}
