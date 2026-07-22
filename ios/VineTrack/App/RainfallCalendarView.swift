import SwiftUI

/// Compact calendar/table view of daily rainfall (mm) for a year.
struct RainfallCalendarView: View {
    @Environment(MigratedDataStore.self) private var store

    @State private var service = RainfallCalendarService()
    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var didInitialLoad = false

    /// Live station provider configured for this vineyard. This is what
    /// powers the Home card's "Today's rain" value, so we surface it here
    /// as the "Today / current" source to keep the two screens consistent.
    @State private var liveStationProvider: LocalObservationProvider = .none
    @State private var liveStationName: String?

    private let dayColumnWidth: CGFloat = 28
    private let monthColumnWidth: CGFloat = 44
    private let cellHeight: CGFloat = 18

    private var latitude: Double? {
        store.settings.vineyardLatitude ?? store.paddockCentroidLatitude
    }
    private var longitude: Double? {
        store.settings.vineyardLongitude ?? store.paddockCentroidLongitude
    }

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    /// Region-aware formatter for display dates. Rainfall amounts stay in mm;
    /// only date formatting follows the configured region.
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                yearControls
                sourceCard
                if latitude == nil || longitude == nil {
                    locationMissing
                } else {
                    calendarTable
                    summarySection
                }
                if let err = service.errorMessage {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                legend
                Text("mm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Rainfall Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    if service.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(service.isLoading)
            }
        }
        .refreshable { await reload() }
        .task {
            if !didInitialLoad {
                didInitialLoad = true
                await reload()
            }
        }
        .onChange(of: year) { _, _ in
            Task { await reload() }
        }
        // Reload after admin actions that mutate persisted rainfall
        // (e.g. the Owner/Manager "Backfill Davis rainfall" button in
        // Weather Data settings).
        .onReceive(NotificationCenter.default.publisher(
            for: .rainfallCalendarShouldReload
        )) { _ in
            Task { await reload() }
        }
    }

    // MARK: - Year controls

    private var yearControls: some View {
        HStack(spacing: 12) {
            Button {
                year -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)

            VStack(spacing: 2) {
                Text(String(year))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Year")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button {
                if year < currentYear { year += 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .disabled(year >= currentYear)
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 1) Today / current — the live station that powers the Home
            //    card's "Today's rain". Shown so the two screens don't look
            //    like they disagree about the source.
            if liveStationProvider != .none {
                calendarSourceRow(
                    label: "Today / current",
                    value: liveStationProvider.displayName
                        + (liveStationName.map { " — \($0)" } ?? ""),
                    icon: liveStationProvider.symbol,
                    tint: VineyardTheme.leafGreen
                )
            }

            // 2) Saved daily rainfall — the persisted vineyard history that
            //    fills the calendar grid.
            if service.usedPersistedHistory {
                calendarSourceRow(
                    label: "Saved daily rainfall",
                    value: "Vineyard rainfall history",
                    icon: "externaldrive.fill.badge.icloud",
                    tint: VineyardTheme.leafGreen
                )
            }

            // 3) Measured-day breakdown (manual / Davis / WU). These are
            //    real recorded rainfall, distinct from the archive fallback.
            if service.manualDaysCovered > 0 {
                calendarSourceRow(
                    label: "Manual entries",
                    value: "\(service.manualDaysCovered) day\(service.manualDaysCovered == 1 ? "" : "s")",
                    icon: "hand.raised.fill",
                    tint: .indigo
                )
            }
            if service.davisDaysCovered > 0 {
                calendarSourceRow(
                    label: "Station record",
                    value: "Davis WeatherLink — \(service.stationName ?? "station") · \(service.davisDaysCovered) day\(service.davisDaysCovered == 1 ? "" : "s")",
                    icon: "sensor.tag.radiowaves.forward.fill",
                    tint: VineyardTheme.leafGreen
                )
            }
            if service.wuDaysCovered > 0 {
                calendarSourceRow(
                    label: "Station record",
                    value: "Weather Underground\(service.davisDaysCovered == 0 ? " — \(service.stationName ?? "station")" : "") · \(service.wuDaysCovered) day\(service.wuDaysCovered == 1 ? "" : "s")",
                    icon: "antenna.radiowaves.left.and.right",
                    tint: .orange
                )
            }

            // 4) Fallback source — Open-Meteo archive, used only for days
            //    with no station/manual record. Never labelled as actual
            //    station rainfall.
            if service.archiveDaysCovered > 0 {
                calendarSourceRow(
                    label: "Fallback source",
                    value: "Open-Meteo archive · used for \(service.archiveDaysCovered) missing day\(service.archiveDaysCovered == 1 ? "" : "s")",
                    icon: "tray.full.fill",
                    tint: .secondary
                )
            }

            // Honest warning when the whole calendar period has no station /
            // manual rainfall and is entirely Open-Meteo archive estimates.
            if service.usedPersistedHistory,
               service.davisDaysCovered == 0,
               service.wuDaysCovered == 0,
               service.manualDaysCovered == 0,
               service.archiveDaysCovered > 0 {
                Label("No station rainfall recorded for this period — daily values are Open-Meteo archive estimates, not station readings.",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if service.todayFromLiveDavis {
                calendarSourceRow(
                    label: "Today",
                    value: "Live Davis cache (no saved row yet)",
                    icon: "clock.arrow.circlepath",
                    tint: .orange
                )
            }
            if let coverage = service.coverageSummary {
                Text(coverage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if service.rateLimited {
                Label(service.fallbackNote, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if service.fallbackUsed {
                Text(service.fallbackNote)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                if let updated = service.lastUpdated {
                    Text("Last refreshed \(updated.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if service.isLoading {
                    Text("Loading rainfall…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await service.refreshRecent(days: 30) }
                } label: {
                    HStack(spacing: 4) {
                        if service.isRefreshingRecent {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise.circle")
                        }
                        Text("Refresh recent")
                    }
                    .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(service.isLoading || service.isRefreshingRecent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    }

    private func calendarSourceRow(label: String, value: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(VineyardTheme.leafGreen.opacity(0.8))
                    .frame(width: 10, height: 10)
                Text("Station (measured)")
            }
            HStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 10, height: 10)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 10, height: 1)
                        .offset(y: 4)
                }
                Text("Open-Meteo fallback")
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var locationMissing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No vineyard location set", systemImage: "location.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Set your vineyard location in Weather Data & Forecasting setup to load rainfall history.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    }

    // MARK: - Calendar table

    private var calendarTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    Divider()
                    ForEach(1...31, id: \.self) { day in
                        dayRow(day: day)
                            .background(day.isMultiple(of: 2) ? Color.clear : Color.black.opacity(0.025))
                    }
                }
                .padding(8)
                .background(Color(.systemBackground), in: .rect(cornerRadius: 10))
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: dayColumnWidth, height: cellHeight, alignment: .center)
            ForEach(1...12, id: \.self) { m in
                Text(monthAbbrev(m))
                    .font(.caption2.weight(.semibold))
                    .frame(width: monthColumnWidth, height: cellHeight, alignment: .center)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dayRow(day: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(day)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: dayColumnWidth, height: cellHeight, alignment: .center)
            ForEach(1...12, id: \.self) { m in
                cell(month: m, day: day)
                    .frame(width: monthColumnWidth, height: cellHeight)
            }
        }
    }

    @ViewBuilder
    private func cell(month: Int, day: Int) -> some View {
        let info = cellInfo(month: month, day: day)
        ZStack {
            // Subtle marker for fallback (archive) cells: a dotted lower edge.
            if info.source == .archive {
                Color.gray.opacity(0.06)
            }
            if let mm = info.mm {
                if mm > 0 {
                    Color.blue.opacity(min(0.55, mm / 30.0))
                }
                Text(formatMm(mm))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(mm >= 10 ? Color.primary : Color.primary.opacity(0.85))
            } else {
                Text("----")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            if info.source == .archive {
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(height: 1)
                }
            }
        }
    }

    private func cellInfo(month: Int, day: Int) -> (valid: Bool, mm: Double?, source: RainfallSource?) {
        // Validate the (y, m, d) triple using the device calendar (catches
        // Feb 30 etc.). Day validity does not depend on timezone.
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        guard let probe = cal.date(from: comps) else { return (false, nil, nil) }
        let real = cal.dateComponents([.year, .month, .day], from: probe)
        if real.year != year || real.month != month || real.day != day {
            return (false, nil, nil)
        }

        // Look up rainfall using the canonical UTC-anchored key so persisted
        // rows align with the cell regardless of device tz.
        guard let key = RainfallDateKey.key(year: year, month: month, day: day) else {
            return (false, nil, nil)
        }
        let mm = service.dailyRainMm[key]
        let src = service.sources[key]

        // Hide future *empty* cells, but never hide a cell that has data —
        // a vineyard-tz "today" can look like the future to a device tz that
        // is one day behind, and we still want to show that data.
        if mm == nil {
            let todayKey = RainfallDateKey.todayKey()
            if key > todayKey { return (true, nil, nil) }
        }
        return (true, mm, src)
    }

    private func formatMm(_ mm: Double) -> String {
        // Mirrors the reference style: 05.9, 00.0
        let clamped = max(0, min(mm, 99.9))
        return String(format: "%04.1f", clamped)
    }

    private func monthAbbrev(_ month: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        return f.shortMonthSymbols[month - 1]
    }

    // MARK: - Summary

    private var summarySection: some View {
        let months = RainfallCalendarMath.monthSummaries(year: year, daily: service.dailyRainMm)
        let annual = RainfallCalendarMath.annual(year: year, daily: service.dailyRainMm, months: months)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    summaryHeaderRow(months: months)
                    summaryRow(label: "TOTALS",     months: months) { mmString($0.totalMm) }
                    summaryRow(label: "Rain days",  months: months) { "\($0.rainDays)" }
                    summaryRow(label: "Wettest day", months: months) {
                        guard let d = $0.wettestDay, let mm = $0.wettestDayMm else { return "—" }
                        return "\(d) (\(mmShort(mm)))"
                    }
                    summaryRow(label: "Average",    months: months) { mmString($0.averageMm) }
                }
                .padding(8)
                .background(Color(.systemBackground), in: .rect(cornerRadius: 10))
            }

            annualCard(annual)
        }
    }

    private func summaryHeaderRow(months: [RainfallMonthSummary]) -> some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: dayColumnWidth + 60, alignment: .leading)
            ForEach(months, id: \.month) { entry in
                Text(monthAbbrev(entry.month))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: monthColumnWidth, alignment: .center)
            }
        }
    }

    private func summaryRow(label: String,
                            months: [RainfallMonthSummary],
                            value: (RainfallMonthSummary) -> String) -> some View {
        let values: [(month: Int, text: String)] = months.map { ($0.month, value($0)) }
        return HStack(spacing: 0) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: dayColumnWidth + 60, alignment: .leading)
            ForEach(values, id: \.month) { entry in
                Text(entry.text)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: monthColumnWidth, alignment: .center)
            }
        }
    }

    private func annualCard(_ annual: RainfallAnnualSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statRow("Year total to date", value: mmString(annual.totalMm) + " mm")
            statRow("Rain days (year)", value: "\(annual.rainDays)")
            if let m = annual.wettestMonth, let mm = annual.wettestMonthMm {
                statRow("Wettest month", value: "\(monthAbbrev(m)) (\(mmShort(mm)) mm)")
            }
            if let m = annual.driestMonth, let mm = annual.driestMonthMm {
                statRow("Driest month", value: "\(monthAbbrev(m)) (\(mmShort(mm)) mm)")
            }
            if let date = annual.wettestDay, let mm = annual.wettestDayMm {
                statRow("Wettest day", value: "\(formattedDate(date)) (\(mmShort(mm)) mm)")
            }
            statRow("Av. Year total", value: "—")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func mmString(_ mm: Double) -> String {
        String(format: "%.1f", mm)
    }
    private func mmShort(_ mm: Double) -> String {
        String(format: "%.1f", mm)
    }
    private func formattedDate(_ date: Date) -> String {
        fmt.formatDate(date)
    }

    // MARK: - Reload

    private func reload() async {
        guard let lat = latitude, let lon = longitude else { return }
        // Resolve the live station provider so the "Today / current" row
        // matches what the Home card uses. Best-effort; never blocks load.
        if let vid = store.selectedVineyardId {
            await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: vid)
            let cfg = WeatherProviderStore.shared.config(for: vid)
            liveStationProvider = cfg.localObservationProvider
            liveStationName = cfg.davisStationName
        } else {
            liveStationProvider = .none
            liveStationName = nil
        }
        await service.load(
            year: year,
            vineyardId: store.selectedVineyardId,
            latitude: lat,
            longitude: lon,
            weatherStationId: store.settings.weatherStationId
        )
    }
}
