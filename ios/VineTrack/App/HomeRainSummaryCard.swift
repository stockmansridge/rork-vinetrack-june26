import SwiftUI

/// Compact, read-only rain summary shown at the top of the Home → Today
/// section. Displays today's rain (midnight → now) and a simple summary of
/// meaningful forecast rain in the next 7 days.
///
/// Operationally important for spraying / irrigation / seeding decisions but
/// intentionally does NOT feed into vineyard health or alert severity.
///
/// Refresh strategy:
/// - On vineyard change / first appear: kick off a provider-appropriate live
///   refresh so today's mm reflects the latest available reading without
///   making the user dive into the Rain page and tap refresh:
///     * Davis: live `fetchCurrentConditions` (writes today's cache + daily row).
///     * Weather Underground: server-side `backfill_rainfall` for recent days
///       (refreshes yesterday — WU's daily summary excludes the in-progress
///       day) and uses Open-Meteo forecast for today's running total.
///     * Open-Meteo / Automatic: server-side `backfill_rainfall_gaps` to keep
///       recent persisted rows current; today's value falls back to the
///       Open-Meteo forecast first-day rain.
/// - On return from background (`.scenePhase == .active`): same refresh.
/// - Manual refresh in the Rain page still works and shares the same
///   `rainfall_daily` / `vineyard_weather_observations` cache as this card.
struct HomeRainSummaryCard: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var todayMm: Double?
    @State private var sourceLabel: String?
    @State private var lastObservedAt: Date?
    @State private var isStaleSnapshot: Bool = false
    @State private var refreshDidFail: Bool = false

    /// `true` when today's value came from a live station current reading
    /// (Davis WeatherLink / Weather Underground) rather than a persisted
    /// daily row or the forecast fallback. Drives the "Live station:" prefix
    /// so it's clear this is the current station reading, not history.
    @State private var todayIsLiveStation: Bool = false

    @State private var forecastDays: [ForecastDay] = []
    @State private var hasLoadedForecast: Bool = false
    @State private var isLoading: Bool = false

    /// Guards re-entrant refreshes when scenePhase fires while a load is
    /// still in flight (e.g. cold launch → quickly background → foreground).
    @State private var isRefreshInFlight: Bool = false

    private var latitude: Double? {
        store.settings.vineyardLatitude ?? store.paddockCentroidLatitude
    }

    private var longitude: Double? {
        store.settings.vineyardLongitude ?? store.paddockCentroidLongitude
    }

    var body: some View {
        NavigationLink {
            RainAndForecastView()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: "cloud.rain.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(todayLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let sub = subtitleLine {
                        Text(sub)
                            .font(.caption2)
                            .foregroundStyle(isStaleSnapshot || refreshDidFail ? .orange : .secondary)
                            .lineLimit(1)
                    }
                    Text(forecastLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.blue.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .task(id: store.selectedVineyardId) { await refresh() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await refresh() }
        }
    }

    // MARK: - Display

    private var todayLine: String {
        guard let mm = todayMm else { return "Rain data unavailable" }
        if mm <= 0 {
            return "Today's rain: 0 mm"
        }
        return String(format: "Today's rain: %.1f mm", mm)
    }

    private var subtitleLine: String? {
        if refreshDidFail, let source = sourceLabel {
            return "\(source) · could not refresh"
        }
        guard let source = sourceLabel else { return nil }
        var parts: [String] = [todayIsLiveStation ? "Live station: \(source)" : source]
        if let observed = lastObservedAt {
            parts.append("updated \(Self.formatTime(observed))")
        }
        if isStaleSnapshot { parts.append("stale") }
        return parts.joined(separator: " · ")
    }

    private var forecastLine: String {
        guard hasLoadedForecast else { return "Loading 7-day rain forecast…" }
        return Self.summarize(days: forecastDays)
    }

    // MARK: - Refresh

    /// Single entry point used by `.task`, vineyard switching, and
    /// scenePhase transitions. Pulls the live Davis observation (when a
    /// shared station is configured) so the cached snapshot reflects the
    /// current station reading, then reads `get_vineyard_current_weather`
    /// the same way the rest of the app does. Forecast is always reloaded.
    private func refresh() async {
        guard !isRefreshInFlight else { return }
        guard let vid = store.selectedVineyardId else {
            todayMm = nil
            sourceLabel = nil
            lastObservedAt = nil
            isStaleSnapshot = false
            todayIsLiveStation = false
            refreshDidFail = false
            forecastDays = []
            hasLoadedForecast = false
            return
        }
        isRefreshInFlight = true
        isLoading = true
        defer {
            isRefreshInFlight = false
            isLoading = false
        }
        refreshDidFail = false

        // 1) Provider-appropriate live refresh. We pick at most one
        //    foreground refresh per call so this stays cheap; lower-priority
        //    backfills (e.g. Open-Meteo gap fill) are scheduled detached.
        await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: vid)
        let cfg = WeatherProviderStore.shared.config(for: vid)
        let canUseDavis = (cfg.davisStationId?.isEmpty == false) &&
            ((cfg.davisIsVineyardShared && cfg.davisVineyardHasServerCredentials)
             || (cfg.davisHasCredentials && cfg.davisConnectionTested))
        var didLivePull = false

        if canUseDavis, let sid = cfg.davisStationId {
            do {
                _ = try await VineyardDavisProxyService.fetchCurrentConditions(
                    vineyardId: vid, stationId: sid
                )
                didLivePull = true
                NotificationCenter.default.post(
                    name: .rainfallCalendarShouldReload, object: nil
                )
            } catch {
                // Network/auth/rate-limit issues shouldn't blank the card;
                // we still read whatever's in the cache below.
                refreshDidFail = true
                print("[HomeRain] live Davis refresh failed — \(error.localizedDescription)")
            }
        }

        // If Davis isn't the active source, try the next-best server-side
        // refresh so the Home card reflects today's available data without
        // requiring the user to open the Rain page and tap refresh.
        if !didLivePull {
            await refreshNonDavis(vineyardId: vid)
        }

        // 2) Read the cached current snapshot (matches Rain page + Irrigation).
        var resolvedToday: Double?
        var resolvedSource: String?
        var resolvedObserved: Date?
        var resolvedStale = false
        var resolvedIsLiveStation = false
        if let snap = try? await WeatherCurrentService().fetchCachedCurrent(vineyardId: vid) {
            if let r = snap.rainTodayMm { resolvedToday = r }
            resolvedObserved = snap.observedAt
            resolvedStale = snap.isStale
            resolvedSource = Self.displaySource(
                rawSource: snap.source,
                stationName: snap.stationName
            )
            // A live station reading is one sourced from Davis/WU current
            // conditions (not the archive/manual). This is what powers the
            // "Today's rain" value and we label it as the live station.
            if snap.rainTodayMm != nil {
                resolvedIsLiveStation = (snap.source == "davis_weatherlink"
                    || snap.source == "wunderground_pws")
            }
        }

        // 3) Fallback: persisted daily rainfall row for today.
        if resolvedToday == nil {
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            if let rows = try? await PersistedRainfallService.fetchDailyRainfall(
                vineyardId: vid, from: start, to: start
            ), let r = rows.first?.rainfallMm {
                resolvedToday = r
                if resolvedSource == nil {
                    resolvedSource = Self.displaySource(
                        rawSource: rows.first?.source,
                        stationName: rows.first?.stationName
                    )
                }
            }
        }

        todayMm = resolvedToday
        sourceLabel = resolvedSource
        lastObservedAt = resolvedObserved
        isStaleSnapshot = resolvedStale
        todayIsLiveStation = resolvedIsLiveStation

        // 4) 7-day forecast rain.
        if let lat = latitude, let lon = longitude {
            let svc = IrrigationForecastService()
            await svc.fetchForecast(latitude: lat, longitude: lon, days: 7, vineyardId: vid)
            forecastDays = svc.forecast?.days ?? []
            hasLoadedForecast = true
        } else {
            forecastDays = []
            hasLoadedForecast = true
        }

        // 5) Last-resort fallback for today: when neither the cache nor the
        //    persisted daily row has a value (typical for WU/Open-Meteo on
        //    the in-progress day, which both proxies intentionally skip),
        //    use the forecast first-day rain that matches today's date.
        if todayMm == nil, let todayForecast = forecastDayMatchingToday() {
            todayMm = todayForecast.forecastRainMm
            if sourceLabel == nil {
                sourceLabel = forecastSourceLabel()
            }
        }
    }

    /// Schedules a server-side refresh appropriate to the active non-Davis
    /// provider. Both proxies intentionally skip the in-progress day, but
    /// they keep recent persisted rows current and the daily row for today
    /// fills in from the forecast fallback below.
    private func refreshNonDavis(vineyardId vid: UUID) async {
        // Weather Underground — backfill_rainfall(days: 2) refreshes the
        // most-recent completed day. Returns 404 (notConfigured) if no
        // WU integration exists, which we treat as "skip".
        do {
            _ = try await VineyardWundergroundProxyService.backfillRainfall(
                vineyardId: vid, days: 2
            )
            NotificationCenter.default.post(
                name: .rainfallCalendarShouldReload, object: nil
            )
        } catch VineyardWundergroundProxyError.notConfigured {
            // No WU station for this vineyard — fall through to Open-Meteo.
        } catch VineyardWundergroundProxyError.forbidden {
            // Operator role — skip, the proxy refused. Cache/forecast still cover Home.
        } catch {
            print("[HomeRain] WU refresh failed — \(error.localizedDescription)")
        }

        // Open-Meteo gap fill — top-priority days are already covered by
        // Manual / Davis / WU rows (the RPC honours that priority), so this
        // only writes Open-Meteo rows where nothing better exists. Cheap
        // and safe to run on every foreground.
        do {
            _ = try await VineyardOpenMeteoProxyService.backfillRainfallGaps(
                vineyardId: vid, days: 7, timezone: TimeZone.current.identifier
            )
            NotificationCenter.default.post(
                name: .rainfallCalendarShouldReload, object: nil
            )
        } catch VineyardOpenMeteoProxyError.forbidden {
            // Operator role — skip silently.
        } catch {
            print("[HomeRain] Open-Meteo gap fill failed — \(error.localizedDescription)")
        }
    }

    /// Returns the forecast day whose start-of-day matches today's, if any.
    /// Used as a last-resort fallback for the Home card's today value when
    /// WU/Open-Meteo proxies have intentionally skipped the in-progress day.
    private func forecastDayMatchingToday() -> ForecastDay? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return forecastDays.first(where: { cal.isDate($0.date, inSameDayAs: today) })
            ?? forecastDays.first.flatMap { d in
                cal.isDate(d.date, inSameDayAs: today) ? d : nil
            }
    }

    /// Display label for the forecast-derived fallback so the subtitle
    /// makes the source transparent.
    private func forecastSourceLabel() -> String? {
        guard let vid = store.selectedVineyardId else { return "Open-Meteo forecast" }
        let cfg = WeatherProviderStore.shared.config(for: vid)
        switch cfg.forecastProvider {
        case .willyWeather:
            return "WillyWeather forecast (today)"
        case .auto:
            return (cfg.willyWeatherLocationId?.isEmpty == false)
                ? "WillyWeather forecast (today)"
                : "Open-Meteo forecast (today)"
        case .openMeteo:
            return "Open-Meteo forecast (today)"
        }
    }

    // MARK: - Forecast summary

    /// Build a short, scannable summary of meaningful rain in the next 7 days.
    /// Ignores tiny amounts (<1 mm) unless nothing else is forecast.
    static func summarize(days: [ForecastDay]) -> String {
        guard !days.isEmpty else { return "Rain forecast unavailable" }
        let threshold = 1.0
        let meaningful = days.filter { $0.forecastRainMm >= threshold }
        guard !meaningful.isEmpty else {
            return "No significant rain in next 7 days"
        }
        // Pick the first meaningful event (most operationally relevant).
        // If a much larger event is later in the window, mention it too.
        let first = meaningful.first!
        let largest = meaningful.max(by: { $0.forecastRainMm < $1.forecastRainMm }) ?? first
        if largest.date != first.date, largest.forecastRainMm >= first.forecastRainMm + 2 {
            return String(
                format: "Forecast: %.1f mm %@ · %.1f mm %@",
                first.forecastRainMm, relativeDay(first.date),
                largest.forecastRainMm, relativeDay(largest.date)
            )
        }
        return String(
            format: "Forecast: %.1f mm %@",
            first.forecastRainMm, relativeDay(first.date)
        )
    }

    private static func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    private static func displaySource(rawSource: String?, stationName: String?) -> String? {
        guard let raw = rawSource, !raw.isEmpty else { return nil }
        let label: String
        switch raw {
        case "davis_weatherlink": label = "Davis WeatherLink"
        case "wunderground_pws": label = "Weather Underground"
        case "manual": label = "Manual"
        case "open_meteo": label = "Open-Meteo"
        default: label = raw
        }
        if let name = stationName, !name.isEmpty {
            return "\(label) · \(name)"
        }
        return label
    }
}
