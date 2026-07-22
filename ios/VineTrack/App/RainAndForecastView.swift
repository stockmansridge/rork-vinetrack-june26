import SwiftUI

/// Clean operational rain page combining forecast at the top and rainfall
/// history below. Opened from the Home → Today's Rain card.
///
/// Intentionally excludes troubleshooting, weather station selection, Davis
/// credentials/status, debug messages and other setup detail. Those live in
/// Weather Settings.
struct RainAndForecastView: View {
    @Environment(MigratedDataStore.self) private var store

    @State private var todayMm: Double?
    @State private var forecastDays: [ForecastDay] = []
    @State private var forecastSource: String?
    @State private var isLoadingForecast: Bool = false
    @State private var hasLoadedForecast: Bool = false

    @State private var recentRain: [PersistedRainfallDay] = []
    @State private var isLoadingHistory: Bool = false
    @State private var hasLoadedHistory: Bool = false

    /// User-configured high-wind threshold from Alert Preferences. Falls back
    /// to a sensible default when no prefs are available.
    @State private var windWarningThresholdKmh: Double = 20
    /// Spray caution threshold. Fixed lower bound where drift becomes a concern.
    private let windCautionThresholdKmh: Double = 15

    private var latitude: Double? {
        store.settings.vineyardLatitude ?? store.paddockCentroidLatitude
    }
    private var longitude: Double? {
        store.settings.vineyardLongitude ?? store.paddockCentroidLongitude
    }

    private var hasLocation: Bool { latitude != nil && longitude != nil }

    /// Region-aware formatter for display dates. With AU defaults this
    /// produces dd/MM/yyyy and is unit-agnostic for rainfall (kept in mm).
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusBanner
                if let warning = windWarning {
                    windWarningBanner(warning)
                }
                forecastSummaryGrid
                dailyForecastSection
                rainfallHistorySection
                calendarLink
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Rain & Forecast")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task(id: store.selectedVineyardId) { await reload() }
    }

    // MARK: - Status banner

    private var statusBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(statusTint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.subheadline.weight(.semibold))
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(statusTint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(statusTint.opacity(0.25), lineWidth: 1)
        )
    }

    private var statusTitle: String {
        if let mm = todayMm, mm > 0 {
            return String(format: "Rain recorded today: %.1f mm", mm)
        }
        if rain24h >= 1 {
            return "Rain expected in next 24h"
        }
        if rain48h >= 1 {
            return "Rain possible in next 48h"
        }
        if rain7d >= 1 {
            return "Rain possible this week"
        }
        return "No rain forecast"
    }

    private var statusSubtitle: String {
        if !hasLocation { return "Set vineyard location to enable forecast." }
        if !hasLoadedForecast { return "Loading forecast…" }
        return String(format: "Today %.1f mm · 24h %.1f mm · 7d %.1f mm",
                      todayMm ?? 0, rain24h, rain7d)
    }

    private var statusIcon: String {
        if (todayMm ?? 0) > 0 { return "cloud.rain.fill" }
        if rain24h >= 1 { return "cloud.heavyrain.fill" }
        if rain7d >= 1 { return "cloud.drizzle.fill" }
        return "sun.max.fill"
    }

    private var statusTint: Color {
        if (todayMm ?? 0) > 0 || rain24h >= 5 { return .blue }
        if rain24h >= 1 || rain48h >= 1 { return .teal }
        if rain7d >= 1 { return .mint }
        return .orange
    }

    // MARK: - Forecast summary grid

    private var forecastSummaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            summaryTile(title: "Today so far",
                        value: formatMm(todayMm),
                        icon: "cloud.rain",
                        tint: .blue)
            summaryTile(title: "Next 24h",
                        value: hasLoadedForecast ? String(format: "%.1f mm", rain24h) : "—",
                        icon: "clock",
                        tint: .teal)
            summaryTile(title: "Next 48h",
                        value: hasLoadedForecast ? String(format: "%.1f mm", rain48h) : "—",
                        icon: "calendar.badge.clock",
                        tint: .indigo)
            summaryTile(title: "Next 7 days",
                        value: hasLoadedForecast ? String(format: "%.1f mm", rain7d) : "—",
                        icon: "calendar",
                        tint: .purple)
        }
    }

    private func summaryTile(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Daily forecast section

    private var dailyForecastSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily forecast")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let label = forecastSourceLabel {
                    Text("Forecast source: \(label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)

            if !hasLocation {
                unavailableCard(message: "Rain forecast is currently unavailable.")
            } else if isLoadingForecast && forecastDays.isEmpty {
                HStack { ProgressView(); Text("Loading forecast…").font(.footnote).foregroundStyle(.secondary) }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
            } else if forecastDays.isEmpty && hasLoadedForecast {
                unavailableCard(message: "Rain forecast is currently unavailable.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(forecastDays.enumerated()), id: \.element.id) { idx, day in
                        forecastRow(day: day)
                        if idx < forecastDays.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
        }
    }

    private func forecastRow(day: ForecastDay) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayLabel(day.date))
                    .font(.subheadline.weight(.semibold))
                Text(dateLabel(day.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)

            Image(systemName: rainIcon(mm: day.forecastRainMm))
                .font(.subheadline)
                .foregroundStyle(rainTint(mm: day.forecastRainMm))
                .frame(width: 22)

            Spacer(minLength: 0)

            if let wind = day.forecastWindKmhMax {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "wind")
                            .font(.caption2)
                            .foregroundStyle(windTint(kmh: wind))
                        Text(fmt.formatSpeed(kmh: wind, fractionDigits: 0))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(windTint(kmh: wind))
                    }
                    Text("Forecast wind")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 70, alignment: .trailing)
            }

            Text(String(format: "%.1f mm", day.forecastRainMm))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(day.forecastRainMm >= 1 ? .primary : .secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Rainfall history section

    private var rainfallHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent rainfall")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Last 30 days")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if isLoadingHistory && recentRain.isEmpty {
                HStack { ProgressView(); Text("Loading rainfall…").font(.footnote).foregroundStyle(.secondary) }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
            } else {
                let rainDays = recentRain.filter { ($0.rainfallMm ?? 0) > 0 }.sorted { $0.date > $1.date }
                if rainDays.isEmpty {
                    Text(hasLoadedHistory ? "No rain recorded in the last 30 days." : "—")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                } else {
                    VStack(spacing: 0) {
                        rainDaysHeader
                        Divider()
                        ForEach(Array(rainDays.enumerated()), id: \.offset) { idx, day in
                            rainDayRow(day)
                            if idx < rainDays.count - 1 {
                                Divider().padding(.leading, 12)
                            }
                        }
                        Divider()
                        rainTotalRow(rainDays: rainDays)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                }
            }
        }
    }

    private var rainDaysHeader: some View {
        HStack {
            Text("Date").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("Source").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("Rain").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func rainDayRow(_ day: PersistedRainfallDay) -> some View {
        HStack {
            Text(fmt.formatDate(day.date))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(prettySource(day.source))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)
            Text(String(format: "%.1f mm", day.rainfallMm ?? 0))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func rainTotalRow(rainDays: [PersistedRainfallDay]) -> some View {
        let total = rainDays.compactMap { $0.rainfallMm }.reduce(0, +)
        return HStack {
            Text("\(rainDays.count) rain day\(rainDays.count == 1 ? "" : "s")")
                .font(.footnote.weight(.semibold))
            Spacer()
            Text(String(format: "%.1f mm total", total))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Calendar link

    private var calendarLink: some View {
        NavigationLink {
            RainfallCalendarView()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rainfall Calendar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Full daily rainfall by month and year")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Unavailable card

    private func unavailableCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "cloud.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink {
                WeatherSettingsDestination()
            } label: {
                HStack {
                    Text("Open Weather Settings")
                        .font(.footnote.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.blue)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Wind warning

    private struct WindWarning {
        enum Level { case caution, high }
        let level: Level
        let maxKmh: Double
        let timeframe: String
    }

    /// Highest forecast wind across the relevant window (today + next 24-48h).
    /// Returns nil when no forecast data is available or wind is below caution.
    private var windWarning: WindWarning? {
        guard hasLoadedForecast else { return nil }
        let today = forecastDays.first?.forecastWindKmhMax
        let next48 = forecastDays.prefix(2).compactMap { $0.forecastWindKmhMax }.max()

        // Prefer today's wind if it already triggers, otherwise look ahead.
        if let t = today, t >= windCautionThresholdKmh {
            let level: WindWarning.Level = t >= windWarningThresholdKmh ? .high : .caution
            return WindWarning(level: level, maxKmh: t, timeframe: "Today")
        }
        if let n = next48, n >= windCautionThresholdKmh {
            let level: WindWarning.Level = n >= windWarningThresholdKmh ? .high : .caution
            return WindWarning(level: level, maxKmh: n, timeframe: "Next 48h")
        }
        return nil
    }

    private func windWarningBanner(_ warning: WindWarning) -> some View {
        let tint: Color = warning.level == .high ? .red : .orange
        let icon = warning.level == .high ? "wind" : "wind"
        let title = warning.level == .high ? "High wind warning" : "Spray caution: high wind forecast"
        let subtitle: String = {
            let speed = String(format: "%.0f km/h", warning.maxKmh)
            switch warning.level {
            case .high:
                return "Wind forecast up to \(speed) \(warning.timeframe.lowercased()). Wind is above the recommended spray limit — consider delaying spray operations."
            case .caution:
                return "Wind forecast up to \(speed) \(warning.timeframe.lowercased()). Conditions may be unsuitable for spraying — check on-site before applying."
            }
        }()

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: "Limit: %.0f km/h · Caution: %.0f km/h",
                            windWarningThresholdKmh, windCautionThresholdKmh))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Computed sums

    private var rain24h: Double {
        guard let first = forecastDays.first else { return 0 }
        return first.forecastRainMm
    }
    private var rain48h: Double {
        forecastDays.prefix(2).map(\.forecastRainMm).reduce(0, +)
    }
    private var rain7d: Double {
        forecastDays.prefix(7).map(\.forecastRainMm).reduce(0, +)
    }

    // MARK: - Formatting

    private func formatMm(_ mm: Double?) -> String {
        guard let mm = mm else { return "—" }
        if mm <= 0 { return "0 mm" }
        return String(format: "%.1f mm", mm)
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    private func rainIcon(mm: Double) -> String {
        if mm >= 10 { return "cloud.heavyrain.fill" }
        if mm >= 1 { return "cloud.rain.fill" }
        if mm > 0 { return "cloud.drizzle" }
        return "sun.max"
    }

    private func windTint(kmh: Double) -> Color {
        if kmh >= windWarningThresholdKmh { return .red }
        if kmh >= windCautionThresholdKmh { return .orange }
        return .secondary
    }

    private func rainTint(mm: Double) -> Color {
        if mm >= 10 { return .blue }
        if mm >= 1 { return .teal }
        if mm > 0 { return .mint }
        return .orange
    }

    /// Display label for the active forecast source, shown on the Daily
    /// forecast header. Returns `nil` while the source is still loading so
    /// the header stays clean.
    private var forecastSourceLabel: String? {
        guard let raw = forecastSource?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let key = raw.lowercased()
        switch key {
        case "willyweather", "willy_weather", "willy-weather":
            return "WillyWeather"
        case "open_meteo", "open-meteo", "openmeteo":
            return "Open-Meteo"
        case "davis_weatherlink", "davis", "weatherlink":
            return "Davis"
        case "weather_underground", "wunderground":
            return "Wunderground"
        default:
            return raw
        }
    }

    private func prettySource(_ source: String?) -> String {
        switch source {
        case "manual": return "Manual"
        case "davis_weatherlink": return "Davis"
        case "open_meteo": return "Open-Meteo"
        case "weather_underground": return "Wunderground"
        case .some(let s) where !s.isEmpty: return s.capitalized
        default: return "—"
        }
    }

    // MARK: - Loading

    private func reload() async {
        await loadWindThreshold()
        await loadToday()
        await loadForecast()
        await loadHistory()
    }

    private func loadWindThreshold() async {
        guard let vid = store.selectedVineyardId else { return }
        if let prefs = try? await SupabaseAlertRepository().fetchPreferences(vineyardId: vid) {
            windWarningThresholdKmh = prefs.windAlertThresholdKmh
        }
    }

    private func loadToday() async {
        guard let vid = store.selectedVineyardId else { todayMm = nil; return }
        var resolved: Double?
        if let snap = try? await WeatherCurrentService().fetchCachedCurrent(vineyardId: vid),
           let r = snap.rainTodayMm {
            resolved = r
        }
        if resolved == nil {
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            if let rows = try? await PersistedRainfallService.fetchDailyRainfall(
                vineyardId: vid, from: start, to: start
            ), let r = rows.first?.rainfallMm {
                resolved = r
            }
        }
        todayMm = resolved
    }

    private func loadForecast() async {
        guard let lat = latitude, let lon = longitude else {
            forecastDays = []
            hasLoadedForecast = true
            return
        }
        isLoadingForecast = true
        let svc = IrrigationForecastService()
        await svc.fetchForecast(latitude: lat, longitude: lon, days: 7, vineyardId: store.selectedVineyardId)
        forecastDays = svc.forecast?.days ?? []
        forecastSource = svc.forecast?.source
        hasLoadedForecast = true
        isLoadingForecast = false
    }

    private func loadHistory() async {
        guard let vid = store.selectedVineyardId else {
            recentRain = []
            hasLoadedHistory = true
            return
        }
        isLoadingHistory = true
        let cal = Calendar.current
        let end = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -29, to: end) ?? end
        if let rows = try? await PersistedRainfallService.fetchDailyRainfall(
            vineyardId: vid, from: start, to: end
        ) {
            recentRain = rows
        } else {
            recentRain = []
        }
        hasLoadedHistory = true
        isLoadingHistory = false
    }
}

/// Lightweight wrapper that pushes to the existing Weather settings screen
/// without leaking setup detail onto the Rain & Forecast page.
private struct WeatherSettingsDestination: View {
    var body: some View {
        WeatherDataSettingsView()
    }
}
