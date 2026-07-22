import SwiftUI
import Charts

struct VarietyGDDDetailView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(DegreeDayService.self) private var degreeDayService

    let varietyId: UUID

    @State private var selectedDate: Date?

    private var fmt: RegionFormatter { store.settings.regionFormatter }
    private var variety: GrapeVariety? { store.grapeVariety(for: varietyId) }

    private var allocatedBlocks: [Paddock] {
        store.orderedPaddocks.filter { p in
            p.varietyAllocations.contains(where: { $0.varietyId == varietyId })
        }
    }

    private var defaultSeasonStartDate: Date {
        let cal = Calendar.current
        let now = Date()
        let month = store.settings.seasonStartMonth
        let day = store.settings.seasonStartDay
        let currentMonth = cal.component(.month, from: now)
        let currentDay = cal.component(.day, from: now)
        let year = cal.component(.year, from: now)
        let startYear: Int
        if currentMonth > month || (currentMonth == month && currentDay >= day) {
            startYear = year
        } else {
            startYear = year - 1
        }
        return cal.date(from: DateComponents(year: startYear, month: month, day: day)) ?? now
    }

    private var effectiveLatitude: Double? {
        store.settings.vineyardLatitude ?? store.paddockCentroidLatitude
    }

    private struct SeriesPoint: Identifiable {
        let id = UUID()
        let date: Date
        let daily: Double
        let cumulative: Double
        let interpolated: Bool
    }

    private struct BlockSeries: Identifiable {
        let id: UUID
        let block: Paddock
        let points: [SeriesPoint]
        let resetDate: Date
        let total: Double
    }

    private var weatherSource: GDDSource? {
        RipenessMath.weatherState(store: store, degreeDayService: degreeDayService).source
    }

    private var blockSeries: [BlockSeries] {
        guard let source = weatherSource else { return [] }
        let stationId = source.sourceKey
        let cal = Calendar.current
        let now = Date()
        let oneYearAgo = cal.date(byAdding: .year, value: -1, to: now) ?? now
        let seasonStart = defaultSeasonStartDate
        let resetDefault = store.settings.resetMode
        let modeDefault = store.settings.calculationMode
        var result: [BlockSeries] = []
        for block in allocatedBlocks {
            let resetMode = block.effectiveResetMode(defaultMode: resetDefault)
            guard let resetDate = block.resetDate(for: resetMode, seasonStart: seasonStart),
                  resetDate <= now, resetDate >= oneYearAgo else { continue }
            let calcMode = block.effectiveCalculationMode(defaultMode: modeDefault)
            let series = degreeDayService.dailyGDDSeries(
                stationId: stationId,
                from: cal.startOfDay(for: resetDate),
                to: cal.startOfDay(for: now),
                latitude: effectiveLatitude,
                useBEDD: calcMode.useBEDD
            )
            let points = series.map { SeriesPoint(date: $0.date, daily: $0.daily, cumulative: $0.cumulative, interpolated: $0.interpolated) }
            result.append(BlockSeries(
                id: block.id,
                block: block,
                points: points,
                resetDate: resetDate,
                total: points.last?.cumulative ?? 0
            ))
        }
        return result
    }

    private var averageTotal: Double {
        let series = blockSeries
        guard !series.isEmpty else { return 0 }
        return series.map(\.total).reduce(0, +) / Double(series.count)
    }

    private var progress: Double {
        guard let target = variety?.optimalGDD, target > 0 else { return 0 }
        return min(1.0, max(0, averageTotal / target))
    }

    private var progressColor: Color {
        switch progress {
        case 0.98...: return VineyardTheme.leafGreen
        case 0.9..<0.98: return .orange
        default: return .red
        }
    }

    private var daysToTarget: Int? {
        guard let target = variety?.optimalGDD, target > averageTotal else { return 0 }
        let series = blockSeries.first?.points ?? []
        guard series.count >= 14 else { return nil }
        let recent = Array(series.suffix(14))
        let gained = (recent.last?.cumulative ?? 0) - (recent.first?.cumulative ?? 0)
        let perDay = gained / Double(max(recent.count - 1, 1))
        guard perDay > 0 else { return nil }
        let remaining = target - averageTotal
        return Int((remaining / perDay).rounded(.up))
    }

    private enum IntersectionKind {
        case reached
        case projected
    }

    private var targetIntersection: (date: Date, kind: IntersectionKind)? {
        guard let target = variety?.optimalGDD, target > 0 else { return nil }
        let points = unionPoints
        guard points.count >= 2 else { return nil }
        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            if prev.cumulative < target && curr.cumulative >= target {
                let span = curr.cumulative - prev.cumulative
                let frac = span > 0 ? (target - prev.cumulative) / span : 0
                let interval = curr.date.timeIntervalSince(prev.date)
                let date = prev.date.addingTimeInterval(interval * frac)
                return (date, .reached)
            }
        }
        if let last = points.last, last.cumulative >= target {
            return (last.date, .reached)
        }
        if let days = daysToTarget, days > 0,
           let last = points.last,
           let projected = Calendar.current.date(byAdding: .day, value: days, to: last.date) {
            return (projected, .projected)
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                if blockSeries.isEmpty {
                    emptyState
                } else {
                    cumulativeChartCard
                    dailyChartCard
                    blocksBreakdownCard
                    stageTimelineCard
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(variety?.name ?? "Variety")
        .navigationBarTitleDisplayMode(.large)
        .task(id: weatherSource?.sourceKey ?? "none") {
            await loadGDDIfNeeded()
        }
    }

    private func loadGDDIfNeeded() async {
        let cands = RipenessMath.candidates(store: store)
        guard !cands.isEmpty else { return }
        if let last = degreeDayService.lastSource,
           cands.contains(where: { $0.source == last }),
           !degreeDayService.needsDailyRefresh(for: last.sourceKey) {
            return
        }
        let start = RipenessMath.fetchRangeStart(settings: store.settings)
        let useBEDD = store.settings.calculationMode.useBEDD
        for c in cands {
            switch c.source {
            case .davisWeatherLink(let sid):
                await degreeDayService.fetchSeasonDavis(
                    stationId: sid,
                    vineyardId: store.selectedVineyardId,
                    useProxy: c.usesProxy,
                    latitude: effectiveLatitude,
                    seasonStart: start,
                    useBEDD: useBEDD
                )
            case .weatherUnderground, .openMeteoArchive:
                await degreeDayService.fetchSeason(source: c.source, seasonStart: start, useBEDD: useBEDD)
            }
            if degreeDayService.lastSource == c.source,
               degreeDayService.hasUsableData(for: c.source) {
                return
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "thermometer.sun")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No degree-day data yet")
                .font(.subheadline.weight(.semibold))
            Text("Set block budburst dates and a weather station to see the season graph.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let source = weatherSource {
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.sun.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("GDD source: \(source.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if degreeDayService.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Season to date")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(averageTotal))")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                            .foregroundStyle(progressColor)
                        Text("°C·days")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let target = variety?.optimalGDD {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Target")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(target))")
                            .font(.title3.monospacedDigit().weight(.semibold))
                    }
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(progressColor.gradient)
                        .frame(width: max(4, geo.size.width * progress))
                }
            }
            .frame(height: 10)

            HStack {
                Text("\(Int(progress * 100))% of optimal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(progressColor)
                Spacer()
                if let days = daysToTarget {
                    if days == 0 {
                        Label("Ready", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(VineyardTheme.leafGreen)
                    } else {
                        Text("≈ \(days) day\(days == 1 ? "" : "s") to target")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let hit = targetIntersection {
                let tint: Color = hit.kind == .reached ? VineyardTheme.leafGreen : .orange
                HStack(spacing: 10) {
                    Image(systemName: hit.kind == .reached ? "flag.checkered" : "calendar.badge.clock")
                        .font(.title3)
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.kind == .reached ? "Target reached on" : "Projected crossover")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(fmt.formatDate(hit.date))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(tint)
                    }
                    Spacer()
                    if let target = variety?.optimalGDD {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("at target")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(Int(target)) GDD")
                                .font(.caption.monospacedDigit().weight(.semibold))
                        }
                    }
                }
                .padding(10)
                .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(tint.opacity(0.3), lineWidth: 1)
                )
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var unionPoints: [SeriesPoint] {
        guard !blockSeries.isEmpty else { return [] }
        let longest = blockSeries.max(by: { $0.points.count < $1.points.count })?.points ?? []
        var merged: [Date: (sum: Double, count: Int)] = [:]
        for series in blockSeries {
            for p in series.points {
                let existing = merged[p.date] ?? (0, 0)
                merged[p.date] = (existing.sum + p.cumulative, existing.count + 1)
            }
        }
        var results: [SeriesPoint] = []
        for p in longest {
            if let v = merged[p.date] {
                results.append(SeriesPoint(date: p.date, daily: p.daily, cumulative: v.sum / Double(v.count), interpolated: p.interpolated))
            }
        }
        return results
    }

    private var cumulativeChartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cumulative GDD")
                .font(.headline)
            Chart {
                ForEach(unionPoints) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("GDD", point.cumulative)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(progressColor.gradient)

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("GDD", point.cumulative)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(progressColor.opacity(0.15).gradient)
                }
                if let target = variety?.optimalGDD {
                    RuleMark(y: .value("Target", target))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Target \(Int(target))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    if let hit = targetIntersection {
                        let tint: Color = hit.kind == .reached ? VineyardTheme.leafGreen : .orange
                        RuleMark(x: .value("Intersect", hit.date))
                            .foregroundStyle(tint.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: hit.kind == .projected ? [3, 3] : []))
                        PointMark(
                            x: .value("Intersect", hit.date),
                            y: .value("GDD", target)
                        )
                        .symbolSize(80)
                        .foregroundStyle(tint)
                        .annotation(position: .topLeading, spacing: 4) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.kind == .reached ? "Reached" : "Projected")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(hit.date.formatted(.dateTime.day().month(.abbreviated)))
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(tint)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: .rect(cornerRadius: 6))
                        }
                    }
                }
                if let selectedDate,
                   let point = unionPoints.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) {
                    RuleMark(x: .value("Date", point.date))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("GDD", point.cumulative)
                    )
                    .foregroundStyle(progressColor)
                    .annotation(position: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(Int(point.cumulative)) GDD")
                                .font(.caption.monospacedDigit().weight(.semibold))
                        }
                        .padding(6)
                        .background(.regularMaterial, in: .rect(cornerRadius: 6))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartXSelection(value: $selectedDate)
            .frame(height: 220)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var dailyChartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily contribution")
                    .font(.headline)
                Spacer()
                Text("°C·days / day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(unionPoints) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("GDD", point.daily)
                    )
                    .foregroundStyle(point.interpolated ? Color.secondary.opacity(0.5) : progressColor.opacity(0.8))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 140)

            HStack(spacing: 14) {
                legendDot(color: progressColor.opacity(0.8), label: "Reported")
                legendDot(color: Color.secondary.opacity(0.5), label: "Estimated")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private var blocksBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocks")
                .font(.headline)
            VStack(spacing: 8) {
                ForEach(blockSeries) { series in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(series.block.name)
                                .font(.subheadline.weight(.semibold))
                            Text("Since \(fmt.formatDate(series.resetDate))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(series.total)) GDD")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(progressColorFor(total: series.total))
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func progressColorFor(total: Double) -> Color {
        guard let target = variety?.optimalGDD, target > 0 else { return .primary }
        let p = total / target
        switch p {
        case 0.98...: return VineyardTheme.leafGreen
        case 0.9..<0.98: return .orange
        default: return .primary
        }
    }

    private var stageTimelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Phenology milestones")
                .font(.headline)
            let blocks = allocatedBlocks
            if blocks.isEmpty {
                Text("No blocks assigned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(blocks) { block in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.name)
                                .font(.caption.weight(.semibold))
                            HStack(spacing: 12) {
                                milestone(label: "Budburst", date: block.budburstDate)
                                milestone(label: "Flowering", date: block.floweringDate)
                                milestone(label: "Veraison", date: block.veraisonDate)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func milestone(label: String, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(date?.formatted(.dateTime.day().month(.abbreviated)) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(date == nil ? .tertiary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
