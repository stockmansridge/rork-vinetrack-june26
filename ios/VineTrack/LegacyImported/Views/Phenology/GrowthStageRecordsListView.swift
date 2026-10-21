import SwiftUI

/// Growth Stage Records.
///
/// Two views over **one** read feed: a Summary (statistics + record list) and
/// the E-L Ripeness Heatmap. Both are driven by the same
/// `ELRipenessHeatmapModel`, which merges the locally-synced
/// `growth_stage_records` store, the remote `v_growth_stage_observations`
/// view, the offline cache and not-yet-synced pins into a single deduplicated
/// set. That shared feed is the whole point: previously the Summary read the
/// local store and the map read the remote view, so the two could disagree
/// about how many observations existed.
struct GrowthStageRecordsListView: View {

    /// Which view of the same feed is on screen.
    private enum ViewMode: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case heatmap = "Growth Stage Heatmap"

        var id: String { rawValue }
    }

    @Environment(MigratedDataStore.self) private var store
    @Environment(GrowthStageRecordSyncService.self) private var growthStageRecordSync
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.scenePhase) private var scenePhase

    @State private var feed = ELRipenessHeatmapModel()
    @State private var viewMode: ViewMode = .summary
    @State private var searchText: String = ""
    @State private var isExporting: Bool = false
    @State private var exportError: String?
    @State private var sharePDF: SharePDFURL?

    private struct SharePDFURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }
    private var timeZone: TimeZone { store.settings.resolvedTimeZone }

    /// The single source of truth for both views.
    private var vineyardRecords: [GrowthStageRecord] { feed.summaryRecords }

    private var filteredRecords: [GrowthStageRecord] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return vineyardRecords }
        return vineyardRecords.filter { record in
            let haystack = [
                record.stageCode,
                record.stageLabel ?? "",
                record.variety ?? "",
                paddockName(for: record.paddockId) ?? "",
                record.notes ?? "",
                record.recordedByName ?? ""
            ].joined(separator: " ").lowercased()
            return haystack.contains(trimmed)
        }
    }

    var body: some View {
        Group {
            switch viewMode {
            case .summary:
                summaryList
            case .heatmap:
                ELRipenessHeatmapContent(
                    model: feed,
                    isOnline: network.isOnline,
                    formatter: fmt,
                    timeZone: timeZone,
                    onRetry: { await load(force: true) }
                )
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("Growth Stage Records")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.selectedVineyardId) {
            await growthStageRecordSync.syncForSelectedVineyard()
            await load()
        }
        .onChange(of: growthStageRecordSync.records) {
            feed.refreshLocal(
                pins: store.pins,
                localRecords: growthStageRecordSync.records,
                timeZone: timeZone
            )
        }
        .onChange(of: store.pins) {
            feed.refreshLocal(
                pins: store.pins,
                localRecords: growthStageRecordSync.records,
                timeZone: timeZone
            )
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await growthStageRecordSync.syncForSelectedVineyard()
                await load(force: true)
            }
        }
        .onDisappear { feed.teardown() }
        .toolbar {
            // Only shown when it performs a real export.
            if accessControl.canExport, !vineyardRecords.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportPDF()
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Label("Export PDF", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExporting)
                }
            }
        }
        .sheet(item: $sharePDF) { item in
            ShareSheet(items: [item.url])
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Summary

    private var summaryList: some View {
        let presentation = summaryPresentation
        return List {
            Section {
                HStack {
                    Label(feed.selectedVintage.map(VintageYearText.label) ?? "Vintage —", systemImage: "calendar")
                    Spacer()
                }
                if feed.availableVintages.count > 1 {
                    Picker("Vintage", selection: vintageBinding) {
                        ForEach(feed.availableVintages, id: \.self) { vintage in
                            Text(verbatim: VintageYearText.format(vintage)).tag(vintage)
                        }
                    }
                }
            }

            if let message = feedProblem {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("Blocks") {
                if feed.blocks.isEmpty {
                    Text("No blocks in this vineyard yet.").foregroundStyle(.secondary)
                }
                ForEach(presentation.rows, id: \.block.id) { row in
                    let block = row.block
                    let stage = row.currentEL
                    NavigationLink {
                        // The destination may be built after the row was drawn.
                        // Resolve its stage and instant cutoff from the live feed.
                        let detail = GrowthStageSummaryPresentation.detail(
                            for: block.id,
                            observations: feed.vintageObservations,
                            records: vineyardRecords,
                            now: Date(),
                            timeZone: timeZone
                        )
                        GrowthStageBlockDetailView(
                            blockName: block.name ?? "Block",
                            currentEl: detail.currentEL,
                            records: detail.records,
                            formatter: fmt
                        )
                    } label: {
                        HStack(spacing: 14) {
                            Color(.tertiarySystemGroupedBackground)
                                .frame(width: 50, height: 50)
                                .overlay {
                                    if let stage,
                                       let growthStage = GrowthStage.allStages.first(where: { Double($0.code.dropFirst(2)) == stage }),
                                       let image = store.resolvedELStageImage(for: growthStage) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .allowsHitTesting(false)
                                    } else {
                                        Image(systemName: "leaf.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .clipShape(.rect(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(block.name ?? "Block").font(.headline)
                                Text(stage.map(ELRipeness.formatEl) ?? "No current stage")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(stage.map { Color(uiColor: ELRipenessPinFactory.uiColour(for: $0)) } ?? .secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await growthStageRecordSync.syncForSelectedVineyard()
            await load(force: true)
        }
    }

    private var summaryPresentation: GrowthStageSummaryPresentation {
        let timing = PerformanceCapture.shared.beginComputation()
        defer { PerformanceCapture.shared.endComputation(timing, label: "Growth summary block ordering", records: feed.vintageObservations.count) }
        return GrowthStageSummaryPresentation(
            blocks: feed.blocks,
            observations: feed.vintageObservations,
            now: Date(),
            timeZone: timeZone
        )
    }

    /// A load problem worth telling the operator about, phrased for the
    /// Summary. A failure must never render as "no records".
    private var feedProblem: String? {
        switch feed.loadState {
        case .failed(let message):
            return "Could not load observations: \(message)"
        case .unavailableOffline:
            return "Not downloaded to this device yet — connect once to see this Vintage."
        default:
            break
        }
        for notice in feed.notices {
            if case .remoteFailed = notice {
                return "Showing locally stored data — the server could not be reached."
            }
            if case .offlineCache(let date) = notice {
                return "Offline — showing data cached \(fmt.formatDate(date))."
            }
        }
        return nil
    }

    private var summaryCard: some View {
        let counts = feed.statusCounts
        return VStack(spacing: 12) {
            HStack {
                Label(
                    feed.selectedVintage.map(VintageYearText.label) ?? "Vintage —",
                    systemImage: "calendar"
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
                if let median = feed.medianEl {
                    Text("Typical stage \(ELRipeness.formatEl(median))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 0) {
                summaryStat(
                    value: "\(counts.recorded)",
                    label: "recorded",
                    icon: "leaf.fill",
                    color: .green
                )
                summaryStat(
                    value: "\(counts.influencing)",
                    label: "current",
                    icon: "target",
                    color: .blue
                )
                summaryStat(
                    value: "\(counts.stale)",
                    label: "stale",
                    icon: "clock.arrow.circlepath",
                    color: .secondary
                )
                if counts.unassigned > 0 {
                    summaryStat(
                        value: "\(counts.unassigned)",
                        label: "unassigned",
                        icon: "mappin.slash",
                        color: .orange
                    )
                }
            }

            if feed.availableVintages.count > 1 {
                Picker("Vintage", selection: vintageBinding) {
                    ForEach(feed.availableVintages, id: \.self) { vintage in
                        Text(verbatim: VintageYearText.format(vintage)).tag(vintage)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var vintageBinding: Binding<Int> {
        Binding(
            get: { feed.selectedVintage ?? feed.availableVintages.first ?? 0 },
            set: { feed.selectedVintage = $0 }
        )
    }

    private func summaryStat(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    // MARK: - Row

    private func recordRow(_ record: GrowthStageRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.stageCode)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.gradient, in: .capsule)
                if let label = record.stageLabel, !label.isEmpty {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer()
                Text(fmt.formatDate(record.observedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(paddockName(for: record.paddockId) ?? "—")
                    .font(.caption)
                    .foregroundStyle(.primary)
                if let variety = record.variety, !variety.isEmpty {
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "leaf")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(variety)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }

            if let notes = record.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                if let name = record.recordedByName, !name.isEmpty {
                    Label(name, systemImage: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !record.photoPaths.isEmpty {
                    Label("\(record.photoPaths.count)", systemImage: "photo.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "leaf.circle")
                .font(.system(size: 44))
                .foregroundStyle(.green.opacity(0.6))
            Text(searchText.isEmpty ? "No growth stage records yet" : "No matches")
                .font(.headline)
            Text(searchText.isEmpty
                 ? "Add a growth-stage pin in the field — it will appear here immediately, before it syncs."
                 : "Try a different search term.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Loading & export

    private func load(force: Bool = false) async {
        guard let vineyardId = store.selectedVineyardId else { return }
        await feed.load(
            vineyardId: vineyardId,
            paddocks: store.paddocks,
            pins: store.pins,
            localRecords: growthStageRecordSync.records,
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay,
            timeZone: timeZone,
            isOnline: network.isOnline,
            force: force
        )
    }

    private func exportPDF() {
        guard !isExporting else { return }
        isExporting = true

        let records = filteredRecords
        let paddocks = store.paddocks.filter { $0.vineyardId == store.selectedVineyardId }
        let vineyardName = store.selectedVineyard?.name ?? "Vineyard"
        let logoData = store.selectedVineyard?.logoData
        let exportTimeZone = timeZone
        let dateFormat = store.settings.regionSettings.dateStyle.dateFormatTemplate
        let localeIdentifier = "en_\(store.settings.regionSettings.countryCode.uppercased())"

        Task.detached {
            do {
                let url = try GrowthStageReportExport.export(
                    records: records,
                    paddocks: paddocks,
                    vineyardName: vineyardName,
                    logoData: logoData,
                    timeZone: exportTimeZone,
                    dateFormat: dateFormat,
                    localeIdentifier: localeIdentifier
                )
                await MainActor.run {
                    isExporting = false
                    sharePDF = SharePDFURL(url: url)
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Helpers

    private func paddockName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return store.paddocks.first(where: { $0.id == id })?.name
    }
}

/// Temporary values for one Summary evaluation. The feed remains the source
/// of truth; no result survives into a later view update or navigation action.
struct GrowthStageSummaryPresentation {
    struct Row {
        let block: ELRipeness.BlockInput
        let currentEL: Double?
    }

    struct Detail {
        let currentEL: Double?
        let records: [GrowthStageRecord]
    }

    let rows: [Row]

    init(
        blocks: [ELRipeness.BlockInput],
        observations: [ELRipeness.Observation],
        now: Date,
        timeZone: TimeZone
    ) {
        guard !blocks.isEmpty else {
            rows = []
            return
        }
        let stages = Self.currentStages(
            for: Set(blocks.map { $0.id.lowercased() }),
            observations: observations,
            today: Self.localDay(now, timeZone: timeZone)
        )
        // Keep blocks as an array: duplicate IDs and equal sort keys retain
        // the same multiplicity and input order as the existing screen.
        rows = blocks.map { Row(block: $0, currentEL: stages[$0.id.lowercased()]) }
            .sorted { left, right in
                let leftEL = left.currentEL ?? -1
                let rightEL = right.currentEL ?? -1
                return leftEL == rightEL
                    ? (left.block.name ?? "") < (right.block.name ?? "")
                    : leftEL > rightEL
            }
    }

    static func detail(
        for blockID: String,
        observations: [ELRipeness.Observation],
        records: [GrowthStageRecord],
        now: Date,
        timeZone: TimeZone
    ) -> Detail {
        let key = blockID.lowercased()
        let stage = currentStages(
            for: [key],
            observations: observations,
            today: localDay(now, timeZone: timeZone)
        )[key]
        // Detail membership is an instant cutoff, unlike the E-L influence
        // policy's vineyard-local day. Keep the source record order intact.
        let visibleRecords = records.filter {
            $0.paddockId?.uuidString.lowercased() == key && $0.observedAt <= now
        }
        return Detail(currentEL: stage, records: visibleRecords)
    }

    private static func currentStages(
        for blockIDs: Set<String>,
        observations: [ELRipeness.Observation],
        today: String
    ) -> [String: Double] {
        var values: [String: [Double]] = [:]
        for observation in observations {
            guard let key = observation.paddockId?.lowercased(),
                  blockIDs.contains(key),
                  ELRipeness.isInfluencing(observation, atDateISO: today) else { continue }
            values[key, default: []].append(observation.el)
        }
        // Use the same max operation over the same ordered values as before.
        return values.compactMapValues { $0.max() }
    }

    private static func localDay(_ now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
}
