import SwiftUI
import Charts

/// Disease Risk Advisor — standalone tool that surfaces Downy, Powdery and
/// Botrytis risk based on weather conditions and (estimated/measured) wetness.
struct DiseaseRiskAdvisorView: View {
    @Environment(MigratedDataStore.self) private var store

    @State private var hourlyService = WeatherHourlyService()
    @State private var assessments: [DiseaseRiskAssessment] = []
    @State private var dailyScores: [DailyDiseaseScore] = []
    @State private var lastCalculated: Date?
    @State private var hasLoadedOnce: Bool = false
    @State private var hours: [WeatherHour] = []
    @State private var showInfo: Bool = false

    private var latitude: Double? {
        store.settings.vineyardLatitude ?? store.paddockCentroidLatitude
    }

    private var longitude: Double? {
        store.settings.vineyardLongitude ?? store.paddockCentroidLongitude
    }

    private var weatherStatus: WeatherSourceStatus? {
        guard let vid = store.selectedVineyardId else { return nil }
        return WeatherProviderResolver.resolve(
            for: vid,
            weatherStationId: store.settings.weatherStationId
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard

                if hourlyService.isLoading && assessments.isEmpty {
                    loadingState
                } else if let error = hourlyService.errorMessage, assessments.isEmpty {
                    errorState(message: error)
                } else if assessments.isEmpty && hasLoadedOnce {
                    emptyState
                } else if !assessments.isEmpty {
                    dataQualityCard
                    summaryCardsSection
                    chartSection
                    detailSection
                    disclaimerCard
                    preferencesLink
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Disease Risk Advisor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(hourlyService.isLoading)
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            NavigationStack { aboutDiseaseRiskView }
        }
        .refreshable {
            await refresh()
        }
        .task {
            if !hasLoadedOnce {
                await refresh()
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "leaf.arrow.triangle.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
                Text("Disease Risk Advisor")
                    .font(.headline)
                Spacer()
            }
            Text("Forecast risk for Downy, Powdery and Botrytis based on weather conditions and wetness estimates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                diseaseSourceRow(label: "Forecast", value: forecastSourceValue, icon: forecastSourceIcon, tint: Color.accentColor)
                if let reason = hourlyService.fallbackReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 22)
                }
                diseaseSourceRow(label: "Wetness", value: wetnessSourceValue, icon: weatherStatus?.quality == .localStationWithMeasuredWetness ? "sensor.tag.radiowaves.forward.fill" : "drop.fill", tint: weatherStatus?.quality == .localStationWithMeasuredWetness ? VineyardTheme.leafGreen : .secondary)
                diseaseSourceRow(label: "Fallback wetness", value: "Estimated from rain / RH / dew point", icon: "tray.full.fill", tint: .secondary)
                if let last = lastCalculated {
                    Text("Updated \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var forecastSourceValue: String {
        switch hourlyService.resolvedProvider {
        case .willyWeather:
            return "WillyWeather (hourly via Open-Meteo)"
        case .openMeteo:
            return "Open-Meteo Forecast"
        case .auto:
            return "Automatic — Open-Meteo"
        }
    }

    private var forecastSourceIcon: String {
        hourlyService.resolvedProvider.symbol
    }

    private var wetnessSourceValue: String {
        guard let s = weatherStatus else { return "Estimated wetness" }
        switch s.quality {
        case .localStationWithMeasuredWetness:
            return "Davis WeatherLink — \(s.detailLabel) (measured wetness)"
        case .localStation:
            switch s.provider {
            case .davis: return "Davis WeatherLink — \(s.detailLabel) (no leaf wetness sensor)"
            case .wunderground: return "Weather Underground — \(s.detailLabel) (estimated wetness)"
            case .automatic: return "Estimated wetness"
            }
        case .forecastOnly:
            return "Estimated wetness"
        }
    }

    private func diseaseSourceRow(label: String, value: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Summary cards

    private var summaryCardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Current Risk")
            VStack(spacing: 10) {
                ForEach(assessments, id: \.self) { a in
                    summaryCard(for: a)
                }
            }
        }
    }

    private func summaryCard(for assessment: DiseaseRiskAssessment) -> some View {
        let level = riskLevel(for: assessment.severity)
        let score = scoreFor(assessment)
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(level.color.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: iconFor(assessment.model))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(level.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(assessment.model.displayName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(level.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(level.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(level.color.opacity(0.15)))
                }
                Text(assessment.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Text("Score \(score)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    sourceBadge(for: assessment)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func wetnessBadge(measured: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "drop.degreesign")
                .font(.caption2)
            Text(measured ? "Measured wetness" : "Estimated wetness")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    @ViewBuilder
    private func sourceBadge(for assessment: DiseaseRiskAssessment) -> some View {
        switch assessment.model {
        case .powderyMildew:
            HStack(spacing: 3) {
                Image(systemName: "thermometer.sun")
                    .font(.caption2)
                Text("Temp + RH model")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        case .downyMildew, .botrytis:
            wetnessBadge(measured: assessment.usedMeasuredWetness)
        }
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("7-Day Risk")
            Group {
                if dailyScores.isEmpty {
                    Text("Not enough hourly data for a 7-day projection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    riskChart
                        .frame(height: 200)
                        .padding(12)
                    chartLegend
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
    }

    private var riskChart: some View {
        Chart {
            ForEach(dailyScores) { row in
                BarMark(
                    x: .value("Day", row.date, unit: .day),
                    y: .value("Score", row.downy)
                )
                .foregroundStyle(by: .value("Disease", "Downy"))
                .position(by: .value("Disease", "Downy"))

                BarMark(
                    x: .value("Day", row.date, unit: .day),
                    y: .value("Score", row.powdery)
                )
                .foregroundStyle(by: .value("Disease", "Powdery"))
                .position(by: .value("Disease", "Powdery"))

                BarMark(
                    x: .value("Day", row.date, unit: .day),
                    y: .value("Score", row.botrytis)
                )
                .foregroundStyle(by: .value("Disease", "Botrytis"))
                .position(by: .value("Disease", "Botrytis"))
            }
            RuleMark(y: .value("Medium", 40))
                .foregroundStyle(.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            RuleMark(y: .value("High", 70))
                .foregroundStyle(.red.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartForegroundStyleScale([
            "Downy": Color.blue,
            "Powdery": Color.orange,
            "Botrytis": Color.purple
        ])
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
    }

    private var chartLegend: some View {
        HStack(spacing: 14) {
            legendDot(color: .blue, label: "Downy")
            legendDot(color: .orange, label: "Powdery")
            legendDot(color: .purple, label: "Botrytis")
            Spacer()
            Text("Low / Med / High")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Detail section

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Details")
            VStack(spacing: 10) {
                ForEach(assessments, id: \.self) { a in
                    detailCard(for: a)
                }
            }
        }
    }

    private func detailCard(for assessment: DiseaseRiskAssessment) -> some View {
        let level = riskLevel(for: assessment.severity)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(assessment.model.displayName, systemImage: iconFor(assessment.model))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(level.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(level.color)
            }
            Text(driverText(for: assessment))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(reasonText(for: assessment))
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            breakdownView(for: assessment.model, level: level)
            nextStepView(for: level)
            if assessment.model != .powderyMildew, !assessment.usedMeasuredWetness {
                Text("Based on estimated wetness (no measured leaf wetness sensor).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if let last = lastCalculated {
                    Label(last.formatted(date: .omitted, time: .shortened),
                          systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let status = weatherStatus {
                    Text("·").foregroundStyle(.tertiary).font(.caption2)
                    Text(status.primaryLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                sourceBadge(for: assessment)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Disclaimer / preferences

    private var disclaimerCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Forecast risk only. This is not a diagnosis or spray recommendation. Inspect the vineyard and follow local agronomic advice and product labels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private var preferencesLink: some View {
        VStack(spacing: 8) {
            NavigationLink {
                AlertSettingsView()
            } label: {
                HStack {
                    Label("Manage disease alert settings", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(.blue)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            NavigationLink {
                WeatherDataSettingsView()
            } label: {
                HStack {
                    Label("Weather Data & Forecasting", systemImage: "cloud.sun.fill")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(.blue)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading hourly forecast…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Unable to load weather data")
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Pull to refresh, or check your weather data source in Settings → Weather Data & Forecasting.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button {
                Task { await refresh() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "leaf")
                .font(.title2)
                .foregroundStyle(.green)
            Text("No assessable risk yet")
                .font(.subheadline.weight(.semibold))
            Text("Set your vineyard location in Vineyard Setup so we can fetch hourly weather and assess risk.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconFor(_ model: DiseaseModel) -> String {
        switch model {
        case .downyMildew: return "leaf.fill"
        case .powderyMildew: return "aqi.medium"
        case .botrytis: return "allergens"
        }
    }

    private struct RiskLevel {
        let label: String
        let color: Color
    }

    private func riskLevel(for severity: AlertSeverity?) -> RiskLevel {
        switch severity {
        case .none: return RiskLevel(label: "Low", color: .green)
        case .info: return RiskLevel(label: "Low", color: .green)
        case .warning: return RiskLevel(label: "Medium", color: .orange)
        case .critical: return RiskLevel(label: "High", color: .red)
        }
    }

    private func scoreFor(_ a: DiseaseRiskAssessment) -> Int {
        switch a.severity {
        case .none: return 10
        case .info: return 25
        case .warning: return 60
        case .critical: return 90
        }
    }

    private func driverText(for a: DiseaseRiskAssessment) -> String {
        switch a.model {
        case .downyMildew:
            return "Drivers: rainfall over the past 48h, minimum temperature, and wet hours."
        case .powderyMildew:
            return "Drivers: extended periods of 21–30°C with humidity ≥ 60% over the past 3 days."
        case .botrytis:
            return "Drivers: wet hours in the 15–25°C window over the past 36h."
        }
    }

    private func reasonText(for a: DiseaseRiskAssessment) -> String {
        let level = riskLevel(for: a.severity).label
        return "Current assessment: \(level). \(a.summary)"
    }

    // MARK: - Daily score model

    private struct DailyDiseaseScore: Identifiable, Hashable {
        let date: Date
        let downy: Int
        let powdery: Int
        let botrytis: Int
        var id: Date { date }
    }

    private func computeDailyScores(hours: [WeatherHour]) -> [DailyDiseaseScore] {
        guard !hours.isEmpty else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var rows: [DailyDiseaseScore] = []
        // Build scores for past 2 days + next 4 days = 7 day window centred on today.
        for offset in -2...4 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let endOfDay = cal.date(byAdding: .day, value: 1, to: day) ?? day
            let downy = DiseaseRiskCalculator.downyMildew(hours: hours, now: endOfDay)
            let powdery = DiseaseRiskCalculator.powderyMildew(hours: hours, now: endOfDay)
            let botrytis = DiseaseRiskCalculator.botrytis(hours: hours, now: endOfDay)
            rows.append(DailyDiseaseScore(
                date: day,
                downy: scoreFor(downy),
                powdery: scoreFor(powdery),
                botrytis: scoreFor(botrytis)
            ))
        }
        return rows
    }

    // MARK: - Refresh

    private func refresh() async {
        hasLoadedOnce = true
        guard let lat = latitude, let lon = longitude else {
            assessments = []
            dailyScores = []
            return
        }
        await hourlyService.fetchWithDavisOverride(
            latitude: lat,
            longitude: lon,
            pastDays: 3,
            forecastDays: 5,
            vineyardId: store.selectedVineyardId
        )
        guard let forecast = hourlyService.forecast else {
            assessments = []
            dailyScores = []
            return
        }
        hours = forecast.hours
        assessments = DiseaseRiskCalculator.assess(hours: forecast.hours)
        dailyScores = computeDailyScores(hours: forecast.hours)
        lastCalculated = Date()
    }

    // MARK: - Data quality / source

    private var dataQualityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: weatherStatus?.quality == .localStationWithMeasuredWetness
                      ? "sensor.tag.radiowaves.forward.fill"
                      : "cloud.sun.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(weatherStatus?.primaryLabel ?? "Automatic Forecast")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let q = weatherStatus?.quality {
                    Text(q.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(q == .localStationWithMeasuredWetness ? .green : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                (q == .localStationWithMeasuredWetness ? Color.green : Color.secondary)
                                    .opacity(0.15)
                            )
                        )
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.caption2)
                Text("Last updated: \(lastCalculated?.formatted(.relative(presentation: .named)) ?? "—")")
                    .font(.caption2)
                Spacer()
                Image(systemName: "leaf").font(.caption2)
                Text("Growth stage adjustment: Not applied")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Why this risk / breakdown

    private struct BreakdownItem: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

    private func breakdown(for model: DiseaseModel) -> [BreakdownItem] {
        guard !hours.isEmpty else { return [] }
        let now = Date()
        switch model {
        case .downyMildew:
            let window = hours.filter { $0.date <= now && $0.date >= now.addingTimeInterval(-48 * 3600) }
            let rain = window.map(\.precipitationMm).reduce(0, +)
            let minTemp = window.map(\.temperatureC).min() ?? 0
            let wet = window.filter { $0.isWetHour }.count
            let measured = window.contains { $0.isWetnessMeasured }
            return [
                BreakdownItem(label: "Rain past 48h", value: String(format: "%.1f mm", rain)),
                BreakdownItem(label: "Min temperature", value: String(format: "%.1f°C", minTemp)),
                BreakdownItem(label: "Wet hours", value: "\(wet) h"),
                BreakdownItem(label: "Wetness source", value: measured ? "Measured" : "Estimated")
            ]
        case .powderyMildew:
            let window = hours.filter { $0.date <= now && $0.date >= now.addingTimeInterval(-72 * 3600) }
            let cal = Calendar.current
            let byDay = Dictionary(grouping: window) { cal.startOfDay(for: $0.date) }
            var favourableDays = 0
            for (_, dayHours) in byDay {
                let sorted = dayHours.sorted { $0.date < $1.date }
                var run = 0, maxRun = 0
                for h in sorted {
                    let humidOK = (h.humidityPercent ?? 0) >= 60
                    let tempOK = h.temperatureC >= 21 && h.temperatureC <= 30
                    if humidOK && tempOK { run += 1; maxRun = max(maxRun, run) } else { run = 0 }
                }
                if maxRun >= 6 { favourableDays += 1 }
            }
            return [
                BreakdownItem(label: "Days with 6+ favourable hours", value: "\(favourableDays) of last 3"),
                BreakdownItem(label: "Favourable temperature", value: "21–30°C"),
                BreakdownItem(label: "RH threshold", value: "≥ 60%")
            ]
        case .botrytis:
            let window = hours.filter { $0.date <= now && $0.date >= now.addingTimeInterval(-36 * 3600) }
            let qualifying = window.filter { $0.isWetHour && $0.temperatureC >= 15 && $0.temperatureC <= 25 }
            let measured = window.contains { $0.isWetnessMeasured }
            return [
                BreakdownItem(label: "Wet hours past 36h", value: "\(qualifying.count) h (15–25°C)"),
                BreakdownItem(label: "Favourable temperature", value: "15–25°C"),
                BreakdownItem(label: "Wetness source", value: measured ? "Measured" : "Estimated")
            ]
        }
    }

    private func breakdownView(for model: DiseaseModel, level: RiskLevel) -> some View {
        let items = breakdown(for: model)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Why this risk?")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                HStack {
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.value)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
            HStack {
                Text("Resulting level")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(level.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(level.color)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8))
    }

    // MARK: - Next steps

    private func nextStepText(for level: RiskLevel) -> String {
        switch level.label {
        case "High":
            return "Prioritise vineyard inspection and check whether protection is current. Conditions may favour disease development."
        case "Medium":
            return "Inspect susceptible blocks and review protection status."
        default:
            return "Continue monitoring."
        }
    }

    private func nextStepIcon(for level: RiskLevel) -> String {
        switch level.label {
        case "High": return "exclamationmark.triangle.fill"
        case "Medium": return "eye.fill"
        default: return "checkmark.circle.fill"
        }
    }

    private func nextStepView(for level: RiskLevel) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: nextStepIcon(for: level))
                .font(.caption)
                .foregroundStyle(level.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("What to do next")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(nextStepText(for: level))
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(level.color.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    // MARK: - Info screen

    private var aboutDiseaseRiskView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("This is a forecast risk tool, not a diagnosis. Always inspect the vineyard and follow local agronomic advice and product labels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                infoBlock(title: "Downy mildew",
                          body: "Risk uses rainfall, temperature and wetness over the past 48 hours.")
                infoBlock(title: "Powdery mildew",
                          body: "Risk uses favourable temperature (21–30°C) and humidity (≥ 60%) periods over the past 3 days. Leaf wetness is not used.")
                infoBlock(title: "Botrytis",
                          body: "Risk uses wet hours within the 15–25°C window over the past 36 hours.")
                infoBlock(title: "Wetness source",
                          body: "Wetness may be measured from a Davis WeatherLink leaf wetness sensor when available, or estimated from rainfall, humidity and dew-point spread.")
                infoBlock(title: "Important",
                          body: "This tool does not recommend chemicals or claim that infection has occurred. Always inspect the vineyard and follow local agronomic advice and product labels.")
            }
            .padding()
        }
        .navigationTitle("About disease risk")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { showInfo = false }
            }
        }
    }

    private func infoBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }
}
