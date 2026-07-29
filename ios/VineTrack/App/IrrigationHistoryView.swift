import SwiftUI

// MARK: - Irrigation history (filters + rows + actions)

struct IrrigationHistoryView: View {
    @Environment(MigratedDataStore.self) private var store

    @State private var sessions: [IrrigationSession] = []
    @State private var totalCount = 0
    @State private var valves: [IrrigationValve] = []
    @State private var filterValveId: UUID?
    @State private var filterStatus: String?
    @State private var filterSource: String?
    @State private var includeReversed = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let repository = SupabaseIrrigationRepository.shared

    private var vineyardId: UUID? { store.selectedVineyardId }
    private var formatter: RegionFormatter { RegionFormatter(settings: store.settings.regionSettings) }

    var body: some View {
        List {
            Section("Filters") {
                Picker("Valve", selection: $filterValveId) {
                    Text("All valves").tag(UUID?.none)
                    ForEach(valves) { valve in
                        Text(valve.name).tag(UUID?.some(valve.id))
                    }
                }
                Picker("Status", selection: $filterStatus) {
                    Text("All statuses").tag(String?.none)
                    Text("Completed").tag(String?.some("completed"))
                    Text("Corrected").tag(String?.some("corrected"))
                    Text("Imported").tag(String?.some("imported"))
                    Text("Reversed").tag(String?.some("reversed"))
                }
                Picker("Source", selection: $filterSource) {
                    Text("All sources").tag(String?.none)
                    Text("Manual").tag(String?.some("manual"))
                    Text("Imported").tag(String?.some("imported"))
                    Text("Galcon GSI").tag(String?.some("galcon_gsi_import"))
                }
                Toggle("Include reversed", isOn: $includeReversed)
            }

            Section {
                if isLoading && sessions.isEmpty {
                    ProgressView()
                } else if sessions.isEmpty {
                    Text("No irrigation sessions match these filters.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions) { session in
                        NavigationLink {
                            IrrigationSessionDetailView(sessionId: session.id) {
                                Task { await reload() }
                            }
                        } label: {
                            IrrigationSessionRow(session: session, formatter: formatter)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowBackground(Color.clear)
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("\(totalCount) session\(totalCount == 1 ? "" : "s")")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Irrigation History")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: vineyardId) { await load() }
        .onChange(of: filterValveId) { _, _ in Task { await reload() } }
        .onChange(of: filterStatus) { _, _ in Task { await reload() } }
        .onChange(of: filterSource) { _, _ in Task { await reload() } }
        .onChange(of: includeReversed) { _, _ in Task { await reload() } }
        .refreshable { await reload() }
    }

    private func load() async {
        guard let vineyardId else { return }
        do {
            valves = try await repository.listValves(vineyardId: vineyardId, includeInactive: true)
        } catch {
            // Valve filter stays empty; history still loads.
        }
        await reload()
    }

    private func reload() async {
        guard let vineyardId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await repository.listSessions(
                vineyardId: vineyardId,
                valveId: filterValveId,
                status: filterStatus,
                sourceType: filterSource,
                includeReversed: includeReversed || filterStatus == "reversed",
                limit: 100)
            sessions = result.sessions
            totalCount = result.totalCount
        } catch {
            errorMessage = "History could not be loaded. \(error.localizedDescription)"
        }
    }
}

// MARK: - Session detail (view / edit / duplicate / reverse)

struct IrrigationSessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    let sessionId: UUID
    var onChanged: () -> Void = {}

    @State private var session: IrrigationSession?
    @State private var capabilities: IrrigationCapabilities?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showReverseConfirm = false
    @State private var isReversing = false

    private let repository = SupabaseIrrigationRepository.shared
    private var formatter: RegionFormatter { RegionFormatter(settings: store.settings.regionSettings) }

    var body: some View {
        List {
            if let session {
                detailSections(session)
            } else if isLoading {
                ProgressView()
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Irrigation Session")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog("Reverse this irrigation record?",
                            isPresented: $showReverseConfirm, titleVisibility: .visible) {
            Button("Reverse Record", role: .destructive) {
                Task { await reverse() }
            }
        } message: {
            Text("The record is excluded from totals but kept in history for audit. This cannot be undone from the app.")
        }
    }

    @ViewBuilder
    private func detailSections(_ session: IrrigationSession) -> some View {
        Section("Session") {
            LabeledContent("Date", value: IrrigationFormat.displayDate(session.sessionDate))
            if let times = IrrigationFormat.timeRange(startedAt: session.startedAt, finishedAt: session.finishedAt) {
                LabeledContent("Times", value: times)
            }
            LabeledContent("Vintage", value: String(session.vintageYear))
            LabeledContent("System", value: session.systemName ?? "—")
            LabeledContent("Valve", value: session.valveName ?? "—")
            LabeledContent("Duration", value: IrrigationFormat.duration(minutes: session.durationMinutes))
            LabeledContent("Method", value: IrrigationCalculationMethod(rawValue: session.calculationMethod)?.label ?? session.calculationMethod)
            if let flow = session.flowLitresPerHour {
                LabeledContent("Flow", value: IrrigationFormat.flow(flow, formatter: formatter))
            }
            if let start = session.meterStartLitres, let finish = session.meterFinishLitres {
                LabeledContent("Meter", value: String(format: "%.0f → %.0f L", start, finish))
            }
            LabeledContent("Status") {
                Text(session.status.capitalized)
                    .foregroundStyle(session.status == "reversed" ? .red :
                                     (session.status == "corrected" ? .orange :
                                      (session.status == "imported" ? .cyan : .green)))
            }
            LabeledContent("Source", value: session.sourceLabel)
        }

        if let info = session.importInfo {
            importSection(info)
        }

        Section("Water") {
            LabeledContent("Total water",
                           value: IrrigationFormat.volume(session.totalVolumeLitres, formatter: formatter))
            if let effective = session.effectiveVolumeLitres {
                LabeledContent("Effective water",
                               value: IrrigationFormat.volume(effective, formatter: formatter))
            }
        }

        Section("Blocks") {
            ForEach(session.blocks) { block in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(block.blockName ?? "Block")
                            .font(.subheadline.weight(.semibold))
                        if let variety = block.varietyName, !variety.isEmpty {
                            Text(variety)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f%%", block.allocationPercentage))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Text(IrrigationFormat.volume(block.allocatedVolumeLitres, formatter: formatter))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                        if let perVine = block.waterLitresPerVine {
                            Text(IrrigationFormat.perVine(perVine, formatter: formatter))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let perHa = block.waterLitresPerHectare {
                            Text(IrrigationFormat.perHectare(perHa, formatter: formatter))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let depth = block.irrigationDepthMm {
                            Text(IrrigationFormat.depth(depth, formatter: formatter))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }

        if let notes = session.notes, !notes.isEmpty {
            Section("Notes") {
                Text(notes)
                    .font(.footnote)
            }
        }

        // Public release (SQL 151): actions follow the shared role capabilities.
        // The server enforces each one independently — this is visibility only.
        if session.status != "reversed" && !session.isImported,
           let caps = capabilities,
           caps.canEditIrrigation || caps.canRecordIrrigation || caps.canReverseIrrigation {
            Section {
                if caps.canEditIrrigation {
                    NavigationLink {
                        IrrigationRecordEntryView(editingSession: session) {
                            Task { await reload() }
                            onChanged()
                        }
                    } label: {
                        Label("Edit Record", systemImage: "pencil")
                    }
                }
                if caps.canRecordIrrigation {
                    NavigationLink {
                        IrrigationRecordEntryView(duplicateFrom: session) {
                            onChanged()
                        }
                    } label: {
                        Label("Duplicate as New Record", systemImage: "plus.square.on.square")
                    }
                }
                if caps.canReverseIrrigation {
                    Button(role: .destructive) {
                        showReverseConfirm = true
                    } label: {
                        if isReversing {
                            ProgressView()
                        } else {
                            Label("Reverse Record", systemImage: "arrow.uturn.backward.circle")
                        }
                    }
                    .disabled(isReversing)
                }
            }
        }

        if session.status != "reversed" && session.isImported {
            Section {
                Text("Imported sessions are managed through the Portal import workflow. Reversing the whole import batch removes every session it created.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Frozen controller-import details (SQL 142) — source data, classification
    /// and warnings stay traceable to the original export row.
    @ViewBuilder
    private func importSection(_ info: IrrigationImportInfo) -> some View {
        Section("Controller Import") {
            LabeledContent("Provider", value: info.providerLabel)
            if let unit = info.unitName {
                LabeledContent("Controller", value: unit)
            }
            if let valve = info.externalValveName {
                LabeledContent("Controller valve", value: valve)
            }
            if let program = info.program {
                LabeledContent("Program", value: program)
            }
            if let water = info.originalWaterValue {
                LabeledContent("Reported water",
                               value: "\(water.formatted()) \(info.originalWaterUnit ?? "m\u{00B3}")")
            }
            if let flow = info.originalFlowValue {
                LabeledContent("Reported flow",
                               value: "\(flow.formatted()) \(info.originalFlowUnit ?? "m\u{00B3}/h")")
            }
            if let seconds = info.reportedRuntimeSeconds {
                LabeledContent("Reported runtime",
                               value: IrrigationFormat.duration(minutes: Int((Double(seconds) / 60.0).rounded())))
            }
            if let comment = info.sourceComment, !comment.isEmpty {
                LabeledContent("Controller status", value: comment)
            }
            if let classification = info.classification {
                LabeledContent("Classification", value: classification.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            if let batchId = info.batchId {
                LabeledContent("Import batch", value: String(batchId.uuidString.prefix(8)).lowercased())
            }
            if let rowNumber = info.sourceRowNumber {
                LabeledContent("Source row", value: "#\(rowNumber)")
            }
            if info.overrideThreshold == true || info.overrideTest == true {
                VStack(alignment: .leading, spacing: 4) {
                    Label(info.overrideTest == true ? "Test-program override applied" : "Volume-threshold override applied",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    if let reason = info.overrideReason, !reason.isEmpty {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let warnings = info.validationWarnings, !warnings.isEmpty {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            session = try await repository.getSession(id: sessionId)
        } catch {
            errorMessage = "The session could not be loaded. \(error.localizedDescription)"
        }
    }

    private func reverse() async {
        isReversing = true
        defer { isReversing = false }
        do {
            session = try await repository.reverseSession(id: sessionId)
            onChanged()
        } catch {
            errorMessage = friendlyIrrigationError(error)
        }
    }
}

// MARK: - Phase 1 reports

struct IrrigationReportsView: View {
    enum ReportTab: String, CaseIterable, Identifiable {
        case vintage = "Vintage"
        case valves = "Valves"
        case blocks = "Blocks"
        case varieties = "Varieties"
        case daily = "Daily"
        case monthly = "Monthly"
        var id: String { rawValue }
    }

    @Environment(MigratedDataStore.self) private var store

    @State private var tab: ReportTab = .vintage
    @State private var vintage: IrrigationVintageSummary?
    @State private var valveRows: [IrrigationValveSummaryRow] = []
    @State private var blockRows: [IrrigationBlockSummaryRow] = []
    @State private var varietyRows: [IrrigationVarietySummaryRow] = []
    @State private var dailyRows: [IrrigationDailySummaryRow] = []
    @State private var monthlyRows: [IrrigationMonthlySummaryRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let repository = SupabaseIrrigationRepository.shared
    private var vineyardId: UUID? { store.selectedVineyardId }
    private var formatter: RegionFormatter { RegionFormatter(settings: store.settings.regionSettings) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReportTab.allCases) { t in
                        Button {
                            tab = t
                        } label: {
                            Text(t.rawValue)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(tab == t ? Color.cyan : Color(.secondarySystemGroupedBackground),
                                            in: .capsule)
                                .foregroundStyle(tab == t ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            List {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                switch tab {
                case .vintage: vintageSection
                case .valves: valveSection
                case .blocks: blockSection
                case .varieties: varietySection
                case .daily: dailySection
                case .monthly: monthlySection
                }
            }
        }
        .navigationTitle("Irrigation Reports")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: vineyardId) { await reload() }
        .refreshable { await reload() }
    }

    @ViewBuilder
    private var vintageSection: some View {
        if let vintage {
            Section("Vintage \(String(vintage.vintageYear))") {
                LabeledContent("Total water",
                               value: IrrigationFormat.volume(vintage.totalVolumeLitres, formatter: formatter))
                if let effective = vintage.effectiveVolumeLitres {
                    LabeledContent("Effective water",
                                   value: IrrigationFormat.volume(effective, formatter: formatter))
                }
                LabeledContent("Total runtime",
                               value: IrrigationFormat.duration(minutes: vintage.totalRuntimeMinutes))
                LabeledContent("Sessions", value: "\(vintage.sessionCount)")
                if let avg = vintage.averageSessionMinutes {
                    LabeledContent("Average session",
                                   value: IrrigationFormat.duration(minutes: Int(avg.rounded())))
                }
                if let perVine = vintage.waterLitresPerVine {
                    LabeledContent("Water per vine",
                                   value: IrrigationFormat.perVine(perVine, formatter: formatter))
                }
                if let depth = vintage.irrigationDepthMm {
                    LabeledContent("Irrigation depth",
                                   value: IrrigationFormat.depth(depth, formatter: formatter))
                }
            }
        } else if isLoading {
            ProgressView()
        }
    }

    private var valveSection: some View {
        Section("By valve") {
            if valveRows.isEmpty {
                emptyRow
            }
            ForEach(valveRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.valveName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(IrrigationFormat.volume(row.totalVolumeLitres, formatter: formatter))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                    Text("\(row.sessionCount) sessions · \(IrrigationFormat.duration(minutes: row.totalRuntimeMinutes)) · last \(row.lastIrrigationDate.map(IrrigationFormat.displayDate) ?? "—")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var blockSection: some View {
        Section("By block") {
            if blockRows.isEmpty {
                emptyRow
            }
            ForEach(blockRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.blockName ?? "Block")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(IrrigationFormat.volume(row.totalVolumeLitres, formatter: formatter))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                    HStack(spacing: 12) {
                        if let perVine = row.waterLitresPerVine {
                            Text(IrrigationFormat.perVine(perVine, formatter: formatter))
                        }
                        if let perHa = row.waterLitresPerHectare {
                            Text(IrrigationFormat.perHectare(perHa, formatter: formatter))
                        }
                        if let depth = row.irrigationDepthMm {
                            Text(IrrigationFormat.depth(depth, formatter: formatter))
                        }
                        Text("last \(row.lastIrrigationDate.map(IrrigationFormat.displayDate) ?? "—")")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var varietySection: some View {
        Section("By variety") {
            if varietyRows.isEmpty {
                emptyRow
            }
            ForEach(varietyRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.varietyName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(IrrigationFormat.volume(row.totalVolumeLitres, formatter: formatter))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                    HStack(spacing: 12) {
                        if let vines = row.totalServicedVines {
                            Text("\(vines) vines")
                        }
                        if let perVine = row.averageWaterLitresPerVine {
                            Text(IrrigationFormat.perVine(perVine, formatter: formatter))
                        }
                        if let perHa = row.averageWaterLitresPerHectare {
                            Text(IrrigationFormat.perHectare(perHa, formatter: formatter))
                        }
                        if let depth = row.irrigationDepthMm {
                            Text(IrrigationFormat.depth(depth, formatter: formatter))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dailySection: some View {
        Section("By day") {
            if dailyRows.isEmpty {
                emptyRow
            }
            ForEach(dailyRows) { row in
                HStack {
                    Text(IrrigationFormat.displayDate(row.date))
                        .font(.subheadline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(IrrigationFormat.volume(row.totalVolumeLitres, formatter: formatter))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.cyan)
                        Text("\(row.sessionCount) session\(row.sessionCount == 1 ? "" : "s") · \(IrrigationFormat.duration(minutes: row.runtimeMinutes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var monthlySection: some View {
        Section("By month") {
            if monthlyRows.isEmpty {
                emptyRow
            }
            ForEach(monthlyRows) { row in
                HStack {
                    Text(monthLabel(row.month))
                        .font(.subheadline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(IrrigationFormat.volume(row.totalVolumeLitres, formatter: formatter))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.cyan)
                        HStack(spacing: 8) {
                            Text("\(row.sessionCount) session\(row.sessionCount == 1 ? "" : "s")")
                            if let depth = row.irrigationDepthMm {
                                Text(IrrigationFormat.depth(depth, formatter: formatter))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var emptyRow: some View {
        Text("No data for this vintage yet.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func monthLabel(_ isoMonth: String) -> String {
        guard let date = IrrigationFormat.dateFormat.date(from: isoMonth) else { return isoMonth }
        return date.formatted(.dateTime.month(.wide).year())
    }

    private func reload() async {
        guard let vineyardId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let vintageTask = repository.vintageSummary(vineyardId: vineyardId)
            async let valveTask = repository.valveSummary(vineyardId: vineyardId)
            async let blockTask = repository.blockSummary(vineyardId: vineyardId)
            async let varietyTask = repository.varietySummary(vineyardId: vineyardId)
            async let dailyTask = repository.dailySummary(vineyardId: vineyardId)
            async let monthlyTask = repository.monthlySummary(vineyardId: vineyardId)
            vintage = try await vintageTask
            valveRows = try await valveTask
            blockRows = try await blockTask
            varietyRows = try await varietyTask
            dailyRows = try await dailyTask
            monthlyRows = try await monthlyTask
        } catch {
            errorMessage = "Reports could not be loaded. \(error.localizedDescription)"
        }
    }
}
