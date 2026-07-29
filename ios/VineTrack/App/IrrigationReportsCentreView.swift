import SwiftUI

// MARK: - Phase 2B Irrigation Reports Centre
//
// Every figure comes from the SQL 147 report RPCs — the client performs no
// calculations of its own. Lists double as the accessible numeric equivalent
// of any visual bars.

struct IrrigationReportsCentreView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"
        case blocks = "Blocks"
        case valves = "Valves"
        case varieties = "Varieties"
        case water = "Water Sources"
        case rainfall = "Rainfall"
        case sources = "Record Sources"
        case trends = "Vintage Trends"
        var id: String { rawValue }
    }

    @Environment(MigratedDataStore.self) private var store

    @State private var section: Section = .overview
    @State private var vintageYear: Int?
    @State private var sourceGroup: String?
    @State private var rainfallGroupBy = "month"

    @State private var overview: IrrigationVintageOverview?
    @State private var periodRows: [IrrigationPeriodReportRow] = []
    @State private var blockRows: [IrrigationBlockReportRow] = []
    @State private var valveRows: [IrrigationValveReportRow] = []
    @State private var varietyRows: [IrrigationVarietyReportRow] = []
    @State private var waterRows: [IrrigationWaterSourceReportRow] = []
    @State private var rainfallRows: [IrrigationRainfallReportRow] = []
    @State private var recordSourceRows: [IrrigationRecordSourceReportRow] = []
    @State private var calcSourceRows: [IrrigationCalcSourceReportRow] = []
    @State private var trendRows: [IrrigationVintageTrendRow] = []
    @State private var warnings: [IrrigationReportWarning] = []
    @State private var resolvedVintage: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var drillDown: DrillDownContext?

    private let repository = SupabaseIrrigationRepository.shared
    private var vineyardId: UUID? { store.selectedVineyardId }
    private var formatter: RegionFormatter { RegionFormatter(settings: store.settings.regionSettings) }

    private var filter: IrrigationReportFilter {
        var f = IrrigationReportFilter()
        f.vintageYear = vintageYear
        f.sourceGroup = sourceGroup
        return f
    }

    private var vintageOptions: [Int] {
        let year = Calendar.current.component(.year, from: Date())
        return ((year - 5)...(year + 1)).reversed()
    }

    var body: some View {
        List {
            filtersSection

            if let errorMessage {
                SwiftUI.Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if isLoading {
                SwiftUI.Section { ProgressView().frame(maxWidth: .infinity) }
            } else {
                content
            }

            if !warnings.isEmpty {
                SwiftUI.Section("Data quality") {
                    ForEach(warnings) { warning in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: warning.severity == "info" ? "info.circle" : "exclamationmark.triangle")
                                .foregroundStyle(warning.severity == "info" ? Color.blue : Color.orange)
                                .font(.caption)
                            Text(warning.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Irrigation Reports")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: taskKey) { await reload() }
        .sheet(item: $drillDown) { context in
            IrrigationReportDrillDownSheet(context: context)
        }
    }

    private var taskKey: String {
        "\(section.rawValue)|\(vintageYear.map(String.init) ?? "current")|\(sourceGroup ?? "all")|\(rainfallGroupBy)"
    }

    // MARK: Filters

    private var filtersSection: some View {
        SwiftUI.Section {
            Picker("Report", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Vintage", selection: $vintageYear) {
                Text("Current").tag(Int?.none)
                ForEach(vintageOptions, id: \.self) { year in
                    Text("Vintage \(String(year))").tag(Int?.some(year))
                }
            }
            Picker("Source", selection: $sourceGroup) {
                Text("All records").tag(String?.none)
                Text("Manual only").tag(String?.some("manual"))
                Text("Imported only").tag(String?.some("controller_import"))
            }
            if section == .rainfall {
                Picker("Group by", selection: $rainfallGroupBy) {
                    Text("Day").tag("day")
                    Text("Week").tag("week")
                    Text("Month").tag("month")
                    Text("Vintage").tag("vintage")
                }
            }
            if let resolvedVintage {
                LabeledContent("Showing", value: "Vintage \(String(resolvedVintage))")
                    .font(.footnote)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview: overviewSection
        case .daily, .weekly, .monthly: periodSection
        case .blocks: blocksSection
        case .valves: valvesSection
        case .varieties: varietiesSection
        case .water: waterSection
        case .rainfall: rainfallSection
        case .sources: sourcesSection
        case .trends: trendsSection
        }
    }

    private var overviewSection: some View {
        Group {
            if let o = overview {
                SwiftUI.Section("Water") {
                    metric("Total irrigation", IrrigationFormat.volume(o.totalIrrigationLitres, formatter: formatter))
                    metric("Effective irrigation", o.effectiveIrrigationLitres.map { IrrigationFormat.volume($0, formatter: formatter) } ?? "—")
                    metric("Manual", IrrigationFormat.volume(o.manualLitres ?? 0, formatter: formatter))
                    metric("Imported (Galcon)", IrrigationFormat.volume(o.importedLitres ?? 0, formatter: formatter))
                    metric("Directly reported", IrrigationFormat.volume(o.directlyReportedLitres ?? 0, formatter: formatter))
                    metric("Directly measured", IrrigationFormat.volume(o.directlyMeasuredLitres ?? 0, formatter: formatter))
                    metric("Calculated", IrrigationFormat.volume(o.calculatedLitres ?? 0, formatter: formatter))
                    metric("Estimated", IrrigationFormat.volume(o.estimatedLitres ?? 0, formatter: formatter))
                }
                SwiftUI.Section("Sessions") {
                    metric("Sessions", "\(o.sessionCount)")
                    metric("Total runtime", IrrigationFormat.duration(minutes: o.totalRuntimeMinutes))
                    metric("Average session", o.averageSessionMinutes.map { IrrigationFormat.duration(minutes: Int($0.rounded())) } ?? "—")
                    metric("Longest / shortest", "\(o.longestSessionMinutes.map { IrrigationFormat.duration(minutes: $0) } ?? "—") / \(o.shortestSessionMinutes.map { IrrigationFormat.duration(minutes: $0) } ?? "—")")
                }
                SwiftUI.Section("Coverage") {
                    metric("Systems / water sources", "\(o.systemsUsed ?? 0) / \(o.waterSourcesUsed ?? 0)")
                    metric("Valves / blocks / varieties", "\(o.valvesUsed ?? 0) / \(o.blocksIrrigated ?? 0) / \(o.varietiesIrrigated ?? 0)")
                    metric("Serviced area", o.servicedAreaHectares.map { String(format: "%.2f ha", $0) } ?? "—")
                    metric("Serviced vines", o.servicedVines.map(String.init) ?? "—")
                }
                SwiftUI.Section("Normalised") {
                    metric("Water per hectare", o.litresPerHectare.map { IrrigationFormat.volume($0, formatter: formatter) + "/ha" } ?? "—")
                    metric("Water per vine", o.litresPerVine.map { IrrigationFormat.volume($0, formatter: formatter) + "/vine" } ?? "—")
                    metric("Irrigation depth", o.irrigationDepthMm.map { IrrigationFormat.depth($0, formatter: formatter) } ?? "—")
                    metric("Effective depth", o.effectiveIrrigationDepthMm.map { IrrigationFormat.depth($0, formatter: formatter) } ?? "—")
                    metric("Rainfall (vintage)", o.rainfallMm.map { IrrigationFormat.depth($0, formatter: formatter) } ?? "—")
                }
                SwiftUI.Section("Timing") {
                    metric("First / last irrigation", "\(o.firstIrrigationDate.map(IrrigationFormat.displayDate) ?? "—") / \(o.lastIrrigationDate.map(IrrigationFormat.displayDate) ?? "—")")
                    metric("Days since last", o.daysSinceLastIrrigation.map(String.init) ?? "—")
                    metric("Highest-use day", o.highestUseDate.map { "\(IrrigationFormat.displayDate($0)) · \(IrrigationFormat.volume(o.highestUseDateLitres ?? 0, formatter: formatter))" } ?? "—")
                    metric("Highest-use month", o.highestUseMonth.map { "\($0) · \(IrrigationFormat.volume(o.highestUseMonthLitres ?? 0, formatter: formatter))" } ?? "—")
                }
                SwiftUI.Section("Previous vintage \(o.previousVintageYear.map(String.init) ?? "")") {
                    metric("Previous total", o.previousTotalLitres.map { IrrigationFormat.volume($0, formatter: formatter) } ?? "—")
                    metric("Volume change", changeText(o.volumeDifferenceLitres, percent: o.volumeDifferencePercent))
                    metric("Previous depth", o.previousDepthMm.map { IrrigationFormat.depth($0, formatter: formatter) } ?? "—")
                    metric("Sessions change", o.sessionCountDifference.map { ($0 >= 0 ? "+" : "") + String($0) } ?? "—")
                }
                if let quality = o.dataQuality {
                    SwiftUI.Section {
                        metric("Report quality", quality.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                }
            } else {
                emptySection
            }
        }
    }

    private var periodSection: some View {
        SwiftUI.Section(section.rawValue) {
            if periodRows.isEmpty { emptyRow }
            ForEach(periodRows) { row in
                Button {
                    drillDown = drillContext(title: periodTitle(row),
                                             dateFrom: row.periodStart, dateTo: row.periodEnd)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(periodTitle(row)).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(IrrigationFormat.volume(row.totalLitres, formatter: formatter))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.cyan)
                        }
                        HStack(spacing: 8) {
                            Text("\(row.sessionCount) session\(row.sessionCount == 1 ? "" : "s")")
                            Text(IrrigationFormat.duration(minutes: row.runtimeMinutes))
                            if let depth = row.irrigationDepthMm {
                                Text(IrrigationFormat.depth(depth, formatter: formatter))
                            }
                            if let rain = row.rainfallMm {
                                Label(IrrigationFormat.depth(rain, formatter: formatter), systemImage: "cloud.rain")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if (row.importedLitres ?? 0) > 0 || (row.estimatedLitres ?? 0) > 0 {
                            HStack(spacing: 8) {
                                if let imported = row.importedLitres, imported > 0 {
                                    Text("Imported \(IrrigationFormat.volume(imported, formatter: formatter))")
                                }
                                if let estimated = row.estimatedLitres, estimated > 0 {
                                    Text("Estimated \(IrrigationFormat.volume(estimated, formatter: formatter))")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        if section == .monthly, let prev = row.previousVintageTotalLitres, prev > 0 {
                            Text("Prev vintage \(IrrigationFormat.volume(prev, formatter: formatter)) · \(changeText(row.differenceLitres, percent: row.differencePercent))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var blocksSection: some View {
        SwiftUI.Section("By block") {
            if blockRows.isEmpty { emptyRow }
            ForEach(blockRows) { row in
                Button {
                    var f = filter
                    f.blockId = row.blockId
                    drillDown = DrillDownContext(title: row.blockName ?? "Block", filter: f)
                } label: {
                    reportRow(
                        title: row.blockName ?? "Block",
                        subtitle: row.varietyName,
                        volume: row.totalLitres,
                        details: [
                            "\(row.sessionCount) sessions",
                            row.irrigationDepthMm.map { IrrigationFormat.depth($0, formatter: formatter) },
                            row.litresPerVine.map { IrrigationFormat.volume($0, formatter: formatter) + "/vine" },
                            row.combinedWaterInputMm.map { "Combined \(IrrigationFormat.depth($0, formatter: formatter))" },
                            row.previousVintageLitres.flatMap { $0 > 0 ? "Prev \(IrrigationFormat.volume($0, formatter: formatter))" : nil },
                        ])
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var valvesSection: some View {
        SwiftUI.Section("By valve") {
            if valveRows.isEmpty { emptyRow }
            ForEach(valveRows) { row in
                Button {
                    var f = filter
                    f.valveId = row.valveId
                    drillDown = DrillDownContext(title: row.valveName, filter: f)
                } label: {
                    reportRow(
                        title: row.valveName,
                        subtitle: row.systemName,
                        volume: row.totalLitres,
                        details: [
                            "\(row.sessionCount) sessions",
                            IrrigationFormat.duration(minutes: row.runtimeMinutes),
                            row.averageFlowLitresPerHour.map { IrrigationFormat.volume($0, formatter: formatter) + "/h avg" },
                            row.percentOfVineyardTotal.map { String(format: "%.1f%%", $0) },
                            row.lastUse.map { "Last \(IrrigationFormat.displayDate($0))" },
                        ])
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var varietiesSection: some View {
        SwiftUI.Section("By variety") {
            if varietyRows.isEmpty { emptyRow }
            ForEach(varietyRows) { row in
                reportRow(
                    title: row.varietyName,
                    subtitle: row.blockCount.map { "\($0) block\($0 == 1 ? "" : "s")" },
                    volume: row.totalLitres,
                    details: [
                        "\(row.sessionCount) sessions",
                        row.litresPerVine.map { IrrigationFormat.volume($0, formatter: formatter) + "/vine" },
                        row.irrigationDepthMm.map { IrrigationFormat.depth($0, formatter: formatter) },
                        row.previousVintageLitres.flatMap { $0 > 0 ? "Prev \(IrrigationFormat.volume($0, formatter: formatter))" : nil },
                    ])
            }
        }
    }

    private var waterSection: some View {
        SwiftUI.Section("By water source") {
            if waterRows.isEmpty { emptyRow }
            ForEach(waterRows) { row in
                reportRow(
                    title: row.waterSource.capitalized,
                    subtitle: "\(row.systemCount ?? 0) system\(row.systemCount == 1 ? "" : "s") · \(row.valveCount ?? 0) valves",
                    volume: row.totalLitres,
                    details: [
                        "\(row.sessionCount) sessions",
                        row.percentOfVineyardTotal.map { String(format: "%.1f%%", $0) },
                        (row.importedLitres ?? 0) > 0 ? "Imported \(IrrigationFormat.volume(row.importedLitres ?? 0, formatter: formatter))" : nil,
                    ])
            }
        }
    }

    private var rainfallSection: some View {
        SwiftUI.Section("Rainfall vs irrigation") {
            if rainfallRows.isEmpty { emptyRow }
            ForEach(rainfallRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.periodKey).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(row.combinedWaterInputMm.map { IrrigationFormat.depth($0, formatter: formatter) } ?? "—")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                    HStack(spacing: 10) {
                        Label(row.rainfallMm.map { IrrigationFormat.depth($0, formatter: formatter) } ?? "—",
                              systemImage: "cloud.rain")
                        Label(row.grossIrrigationDepthMm.map { IrrigationFormat.depth($0, formatter: formatter) } ?? "—",
                              systemImage: "drop")
                        if let pct = row.irrigationPercentOfCombined {
                            Text(String(format: "%.0f%% irrigation", pct))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if row.rainfallDataComplete == false {
                        Text("Rainfall data incomplete for this period")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var sourcesSection: some View {
        Group {
            SwiftUI.Section("By record source") {
                if recordSourceRows.isEmpty { emptyRow }
                ForEach(recordSourceRows) { row in
                    Button {
                        var f = filter
                        f.sourceType = row.sourceType
                        drillDown = DrillDownContext(title: row.sourceLabel ?? row.sourceType, filter: f)
                    } label: {
                        reportRow(
                            title: row.sourceLabel ?? row.sourceType,
                            subtitle: row.sourceGroup?.replacingOccurrences(of: "_", with: " ").capitalized,
                            volume: row.totalLitres,
                            details: [
                                "\(row.sessionCount) sessions",
                                row.percentOfTotalLitres.map { String(format: "%.1f%%", $0) },
                            ])
                    }
                    .buttonStyle(.plain)
                }
            }
            SwiftUI.Section("By calculation method") {
                if calcSourceRows.isEmpty { emptyRow }
                ForEach(calcSourceRows) { row in
                    reportRow(
                        title: row.calculationLabel ?? row.calculationMethod,
                        subtitle: row.measurementLabel,
                        volume: row.totalLitres,
                        details: [
                            "\(row.sessionCount) sessions",
                            row.percentOfTotalLitres.map { String(format: "%.1f%%", $0) },
                        ])
                }
            }
        }
    }

    private var trendsSection: some View {
        SwiftUI.Section("Last \(trendRows.count) vintages") {
            if trendRows.isEmpty { emptyRow }
            ForEach(trendRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Vintage \(String(row.vintageYear))").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(IrrigationFormat.volume(row.totalLitres, formatter: formatter))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                    HStack(spacing: 8) {
                        Text("\(row.sessionCount) sessions")
                        if let depth = row.irrigationDepthMm {
                            Text(IrrigationFormat.depth(depth, formatter: formatter))
                        }
                        if let rain = row.rainfallMm {
                            Label(IrrigationFormat.depth(rain, formatter: formatter), systemImage: "cloud.rain")
                        }
                        if let quality = row.dataQuality {
                            Text(quality.replacingOccurrences(of: "_", with: " ").capitalized)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Row helpers

    private func metric(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
            .font(.subheadline)
    }

    private func reportRow(title: String, subtitle: String?, volume: Double,
                           details: [String?]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(IrrigationFormat.volume(volume, formatter: formatter))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
            let parts = details.compactMap(\.self)
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptySection: some View {
        SwiftUI.Section { emptyRow }
    }

    private var emptyRow: some View {
        Text("No data for this selection yet.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func periodTitle(_ row: IrrigationPeriodReportRow) -> String {
        switch section {
        case .daily: return IrrigationFormat.displayDate(row.periodKey)
        case .weekly:
            if let start = row.periodStart {
                return "Week of \(IrrigationFormat.displayDate(start))"
            }
            return row.periodKey
        default: return row.monthLabel ?? row.periodKey
        }
    }

    private func changeText(_ litres: Double?, percent: Double?) -> String {
        guard let litres else { return "—" }
        let sign = litres >= 0 ? "+" : ""
        var text = sign + IrrigationFormat.volume(litres, formatter: formatter)
        if let percent {
            text += String(format: " (%@%.1f%%)", percent >= 0 ? "+" : "", percent)
        }
        return text
    }

    private func drillContext(title: String, dateFrom: String?, dateTo: String?) -> DrillDownContext {
        var f = filter
        f.dateFrom = dateFrom
        f.dateTo = dateTo
        return DrillDownContext(title: title, filter: f)
    }

    // MARK: Loading

    private func reload() async {
        guard let vineyardId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            switch section {
            case .overview:
                let o = try await repository.vintageOverview(vineyardId: vineyardId, filter: filter)
                overview = o
                resolvedVintage = o.vintageYear
                warnings = o.warnings ?? []
            case .daily:
                let env = try await repository.dailyReport(vineyardId: vineyardId, filter: filter)
                periodRows = env.rows.reversed()
                resolvedVintage = env.vintageYear
                warnings = env.warnings ?? []
            case .weekly:
                let env = try await repository.weeklyReport(vineyardId: vineyardId, filter: filter)
                periodRows = env.rows.reversed()
                resolvedVintage = env.vintageYear
                warnings = env.warnings ?? []
            case .monthly:
                let env = try await repository.monthlyReport(vineyardId: vineyardId, filter: filter)
                periodRows = env.rows
                resolvedVintage = env.vintageYear
                warnings = env.warnings ?? []
            case .blocks:
                let env = try await repository.blockReport(vineyardId: vineyardId, filter: filter)
                blockRows = env.rows
                resolvedVintage = env.vintageYear
                warnings = env.warnings ?? []
            case .valves:
                let env = try await repository.valveReport(vineyardId: vineyardId, filter: filter)
                valveRows = env.rows
                resolvedVintage = env.vintageYear
                warnings = env.warnings ?? []
            case .varieties:
                let env = try await repository.varietyReport(vineyardId: vineyardId, filter: filter)
                varietyRows = env.rows
                resolvedVintage = env.vintageYear
                warnings = env.warnings ?? []
            case .water:
                let env = try await repository.waterSourceReport(vineyardId: vineyardId, filter: filter)
                waterRows = env.rows
                resolvedVintage = env.vintageYear
                warnings = env.warnings ?? []
            case .rainfall:
                let env = try await repository.rainfallReport(vineyardId: vineyardId, filter: filter,
                                                              groupBy: rainfallGroupBy)
                rainfallRows = env.rows
                resolvedVintage = env.vintageYear
                warnings = env.warnings ?? []
            case .sources:
                async let recordTask = repository.recordSourceReport(vineyardId: vineyardId, filter: filter)
                async let calcTask = repository.calculationSourceReport(vineyardId: vineyardId, filter: filter)
                let record = try await recordTask
                let calc = try await calcTask
                recordSourceRows = record.rows
                calcSourceRows = calc.rows
                resolvedVintage = record.vintageYear
                warnings = record.warnings ?? []
            case .trends:
                let env = try await repository.vintageTrends(vineyardId: vineyardId, filter: filter,
                                                             vintageCount: 5)
                trendRows = env.rows
                resolvedVintage = env.vintageYear
                warnings = []
            }
        } catch {
            let text = error.localizedDescription
            errorMessage = text.contains("irrigation_access_denied")
                ? "Irrigation reports are limited to System Administrators during validation."
                : "This report could not be loaded. \(text)"
        }
    }
}

// MARK: - Drill-down

struct DrillDownContext: Identifiable {
    let id = UUID()
    let title: String
    let filter: IrrigationReportFilter
}

struct IrrigationReportDrillDownSheet: View {
    let context: DrillDownContext

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [IrrigationSession] = []
    @State private var totalCount = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let repository = SupabaseIrrigationRepository.shared
    private var formatter: RegionFormatter { RegionFormatter(settings: store.settings.regionSettings) }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.orange)
                } else if sessions.isEmpty {
                    Text("No sessions behind this row.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    SwiftUI.Section("\(totalCount) session\(totalCount == 1 ? "" : "s")") {
                        ForEach(sessions) { session in
                            NavigationLink {
                                IrrigationSessionDetailView(sessionId: session.id) {}
                            } label: {
                                IrrigationSessionRow(session: session, formatter: formatter)
                            }
                        }
                    }
                }
            }
            .navigationTitle(context.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        defer { isLoading = false }
        do {
            let list = try await repository.reportSessions(vineyardId: vineyardId,
                                                           filter: context.filter, limit: 100)
            sessions = list.sessions
            totalCount = list.totalCount
        } catch {
            errorMessage = "Sessions could not be loaded. \(error.localizedDescription)"
        }
    }
}
