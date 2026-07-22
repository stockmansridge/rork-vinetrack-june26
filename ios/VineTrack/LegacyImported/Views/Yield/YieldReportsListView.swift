import SwiftUI

struct YieldReportsListView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(YieldEstimationSessionSyncService.self) private var yieldSessionSync
    @Environment(HistoricalYieldRecordSyncService.self) private var historicalYieldSync
    @Environment(\.accessControl) private var accessControl
    @State private var showArchiveSheet: Bool = false
    @State private var showHistoricalDetail: HistoricalYieldRecord?
    @State private var historicalSortBy: HistoricalSort = .newest
    @State private var historicalFilterPaddock: UUID?
    @State private var showStartEstimateSheet: Bool = false

    private var canDelete: Bool { accessControl?.canDelete ?? false }
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var paddocks: [Paddock] {
        store.orderedPaddocks.filter { $0.polygonPoints.count >= 3 }
    }

    private var sessions: [YieldEstimationSession] {
        store.yieldSessions.sorted { $0.createdAt > $1.createdAt }
    }

    private var blockSummaries: [BlockSummary] {
        var summaries: [BlockSummary] = []

        for paddock in paddocks {
            guard let session = store.yieldSessions.first(where: {
                $0.selectedPaddockIds.contains(paddock.id)
            }) else { continue }

            let sites = session.sampleSites.filter { $0.paddockId == paddock.id }
            let recorded = sites.filter { $0.isRecorded }

            guard !recorded.isEmpty else {
                summaries.append(BlockSummary(
                    paddockId: paddock.id,
                    paddockName: paddock.name,
                    areaHa: paddock.areaHectares,
                    yieldTonnes: 0,
                    yieldPerHa: 0,
                    samplesRecorded: 0,
                    samplesTotal: sites.count,
                    lastUpdated: session.createdAt
                ))
                continue
            }

            let avgBunches = recorded.reduce(0.0) { $0 + ($1.bunchCountEntry?.bunchesPerVine ?? 0) } / Double(recorded.count)
            let avgBunchesRounded = (avgBunches * 100).rounded() / 100
            let totalVines = paddock.effectiveVineCount
            let totalBunches = Double(totalVines) * avgBunchesRounded
            let damageFactor = store.damageFactor(for: paddock.id)
            let yieldKg = totalBunches * session.bunchWeightKg(for: paddock.id) * damageFactor
            let yieldTonnes = yieldKg / 1000.0

            let latestDate = recorded
                .compactMap { $0.bunchCountEntry?.recordedAt }
                .max() ?? session.createdAt

            summaries.append(BlockSummary(
                paddockId: paddock.id,
                paddockName: paddock.name,
                areaHa: paddock.areaHectares,
                yieldTonnes: yieldTonnes,
                yieldPerHa: paddock.areaHectares > 0 ? yieldTonnes / paddock.areaHectares : 0,
                samplesRecorded: recorded.count,
                samplesTotal: sites.count,
                lastUpdated: latestDate
            ))
        }

        return summaries
    }

    private var totalYieldTonnes: Double {
        blockSummaries.reduce(0) { $0 + $1.yieldTonnes }
    }

    private var totalArea: Double {
        blockSummaries.reduce(0) { $0 + $1.areaHa }
    }

    private var filteredHistoricalRecords: [HistoricalYieldRecord] {
        var records = store.historicalYieldRecords

        if let filterId = historicalFilterPaddock {
            records = records.filter { record in
                record.blockResults.contains { $0.paddockId == filterId }
            }
        }

        switch historicalSortBy {
        case .newest:
            records.sort { $0.year > $1.year }
        case .oldest:
            records.sort { $0.year < $1.year }
        case .highestYield:
            records.sort { $0.totalYieldTonnes > $1.totalYieldTonnes }
        case .lowestYield:
            records.sort { $0.totalYieldTonnes < $1.totalYieldTonnes }
        }

        return records
    }

    private var uniquePaddockNames: [(id: UUID, name: String)] {
        var seen = Set<UUID>()
        var result: [(id: UUID, name: String)] = []
        for record in store.historicalYieldRecords {
            for block in record.blockResults {
                if !seen.contains(block.paddockId) {
                    seen.insert(block.paddockId)
                    result.append((id: block.paddockId, name: block.paddockName))
                }
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                yieldOverviewSection

                sessionListSection

                historicalSection

                settingsLink
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Yield Reports")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if !blockSummaries.isEmpty {
                        Button {
                            showArchiveSheet = true
                        } label: {
                            Image(systemName: "archivebox")
                        }
                    }
                    Button {
                        showStartEstimateSheet = true
                    } label: {
                        Label("Yield Estimate", systemImage: "plus.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .sheet(isPresented: $showArchiveSheet) {
            ArchiveYieldSheet(blockSummaries: blockSummaries, totalYieldTonnes: totalYieldTonnes, totalArea: totalArea)
        }
        .sheet(isPresented: $showStartEstimateSheet) {
            NavigationStack {
                YieldEstimationView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { showStartEstimateSheet = false }
                        }
                    }
            }
        }
        .sheet(item: $showHistoricalDetail) { record in
            HistoricalYieldDetailSheet(record: record)
        }
    }

    // MARK: - Yield Overview (compact stats + primary action)

    private var yieldOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Yield Overview", systemImage: "chart.bar.xaxis")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                overviewCard(
                    title: "Estimates",
                    value: "\(sessions.count)",
                    icon: "list.bullet.clipboard",
                    color: VineyardTheme.leafGreen
                )
                overviewCard(
                    title: "Blocks Sampled",
                    value: "\(blockSummaries.count)",
                    icon: "map.fill",
                    color: .purple
                )
                overviewCard(
                    title: "Est. Tonnes",
                    value: String(format: "%.2f t", totalYieldTonnes),
                    icon: "scalemass.fill",
                    color: .orange
                )
                overviewCard(
                    title: "Avg Yield/\(fmt.areaUnitAbbreviation)",
                    value: totalArea > 0 ? fmt.formatYieldPerArea(perHectare: totalYieldTonnes / totalArea) : "—",
                    icon: "square.dashed",
                    color: .teal
                )
            }
        }
    }

    private func overviewCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Block Summary

    private var blockSummarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Block Summary", systemImage: "chart.bar.xaxis")
                .font(.headline)

            ForEach(blockSummaries, id: \.paddockId) { summary in
                blockSummaryCard(summary)
            }
        }
    }

    private func blockSummaryCard(_ summary: BlockSummary) -> some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.paddockName)
                        .font(.subheadline.weight(.semibold))
                    Text(fmt.formatArea(hectares: summary.areaHa))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f t", summary.yieldTonnes))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(summary.yieldTonnes > 0 ? VineyardTheme.leafGreen : .secondary)
                    if summary.yieldPerHa > 0 {
                        Text(fmt.formatYieldPerArea(perHectare: summary.yieldPerHa))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    Text("\(summary.samplesRecorded)/\(summary.samplesTotal) samples")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if summary.samplesRecorded > 0 {
                    Text(fmt.formatDate(summary.lastUpdated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let determination = store.latestDetermination(for: summary.paddockId) {
                HStack(spacing: 6) {
                    Image(systemName: "scalemass.fill")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    Text("Determined \(fmt.formatYieldPerArea(perHectare: determination.yieldTonnesPerHa))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if summary.yieldPerHa > 0, determination.yieldTonnesPerHa > 0 {
                        let variance = ((summary.yieldPerHa - determination.yieldTonnesPerHa) / determination.yieldTonnesPerHa) * 100
                        Text(String(format: "%@%.0f%%", variance >= 0 ? "+" : "", variance))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(variance >= 0 ? VineyardTheme.leafGreen : .orange)
                    }
                    Spacer()
                }
            }

            if summary.samplesTotal > 0 {
                ProgressView(value: Double(summary.samplesRecorded), total: Double(summary.samplesTotal))
                    .tint(summary.samplesRecorded == summary.samplesTotal ? .green : .orange)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Session List

    private var sessionListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Yield Reports", systemImage: "list.bullet.clipboard")
                    .font(.headline)
                Spacer()
                if !sessions.isEmpty {
                    Text("\(sessions.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(.secondarySystemFill), in: .capsule)
                }
            }

            if sessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No yield estimates yet")
                        .font(.subheadline.weight(.semibold))
                    Text("Start a guided sampling session to estimate yield for one or more blocks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button {
                        showStartEstimateSheet = true
                    } label: {
                        Label("Start Estimate", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(VineyardTheme.leafGreen, in: .capsule)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            } else {
                ForEach(sessions) { session in
                    SwipeToDeleteCard(
                        actionLabel: "Delete",
                        isEnabled: canDelete
                    ) {
                        store.deleteYieldSession(session)
                        Task { await yieldSessionSync.syncForSelectedVineyard() }
                    } content: {
                        sessionCard(session)
                    }
                }
            }
        }
    }

    private func sessionCard(_ session: YieldEstimationSession) -> some View {
        NavigationLink {
            sessionDetailDestination(session)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(sessionTitle(session))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if session.isCompleted {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(VineyardTheme.leafGreen)
                            }
                        }
                        Text(fmt.formatDateTime(session.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    RecordSyncBadge(
                        state: .forYieldSession(session.id, yieldSync: yieldSessionSync),
                        showsLabel: false
                    )

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 16) {
                    let recorded = session.sampleSites.filter { $0.isRecorded }.count
                    let total = session.sampleSites.count

                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                        Text("\(recorded)/\(total) samples")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "map")
                            .font(.caption2)
                            .foregroundStyle(.teal)
                        Text("\(session.selectedPaddockIds.count) blocks")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    let yieldT = sessionYield(session)
                    if session.isCompleted {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                            Text(String(format: "%.2f t", yieldT))
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(VineyardTheme.leafGreen)
                    } else if yieldT > 0 {
                        Text(String(format: "%.2f t", yieldT))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(VineyardTheme.leafGreen)
                    } else {
                        Text("Pending")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }

                if !session.sampleSites.isEmpty {
                    let recorded = session.sampleSites.filter { $0.isRecorded }.count
                    ProgressView(value: Double(recorded), total: Double(session.sampleSites.count))
                        .tint(recorded == session.sampleSites.count ? .green : .orange)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Historical Section

    private var historicalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Historical Results", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
            }

            if store.historicalYieldRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No historical records")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Archive a completed season to build your yield history.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(HistoricalSort.allCases, id: \.self) { sort in
                            Button {
                                historicalSortBy = sort
                            } label: {
                                Label(sort.label, systemImage: historicalSortBy == sort ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption2.weight(.semibold))
                            Text(historicalSortBy.label)
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                    }

                    Menu {
                        Button {
                            historicalFilterPaddock = nil
                        } label: {
                            Label("All Blocks", systemImage: historicalFilterPaddock == nil ? "checkmark" : "")
                        }
                        Divider()
                        ForEach(uniquePaddockNames, id: \.id) { item in
                            Button {
                                historicalFilterPaddock = item.id
                            } label: {
                                Label(item.name, systemImage: historicalFilterPaddock == item.id ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.caption2.weight(.semibold))
                            Text(filterLabel)
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                    }
                }

                ForEach(filteredHistoricalRecords) { record in
                    SwipeToDeleteCard(
                        actionLabel: "Delete",
                        isEnabled: canDelete
                    ) {
                        store.deleteHistoricalYieldRecord(record)
                        Task { await historicalYieldSync.syncForSelectedVineyard() }
                    } content: {
                        Button {
                            showHistoricalDetail = record
                        } label: {
                            historicalRecordCard(record)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var filterLabel: String {
        guard let filterId = historicalFilterPaddock,
              let name = uniquePaddockNames.first(where: { $0.id == filterId })?.name else {
            return "All Blocks"
        }
        return name
    }

    private func historicalRecordCard(_ record: HistoricalYieldRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.season.isEmpty ? "\(record.year)" : record.season)
                        .font(.subheadline.weight(.semibold))
                    Text(fmt.formatDate(record.archivedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f t", record.totalYieldTonnes))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                    if record.totalAreaHectares > 0 {
                        Text(fmt.formatYieldPerArea(perHectare: record.yieldPerHectare))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "map.fill")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    Text("\(record.blockResults.count) blocks")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "ruler.fill")
                        .font(.caption2)
                        .foregroundStyle(.teal)
                    Text(fmt.formatArea(hectares: record.totalAreaHectares))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !record.notes.isEmpty {
                Text(record.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Settings Link

    private var settingsLink: some View {
        NavigationLink {
            YieldSettingsView()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.body)
                    .foregroundStyle(VineyardTheme.leafGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yield Settings")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Default bunch weights per block")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func sessionDetailDestination(_ session: YieldEstimationSession) -> some View {
        let vm = YieldEstimationViewModel()
        vm.loadSession(session)
        return YieldReportView(viewModel: vm)
    }

    private func sessionTitle(_ session: YieldEstimationSession) -> String {
        let blockNames = session.selectedPaddockIds.compactMap { pid in
            paddocks.first(where: { $0.id == pid })?.name
        }
        if blockNames.isEmpty {
            return "Yield Estimation"
        } else if blockNames.count <= 3 {
            return blockNames.joined(separator: ", ")
        } else {
            return "\(blockNames.prefix(2).joined(separator: ", ")) +\(blockNames.count - 2) more"
        }
    }

    private func sessionYield(_ session: YieldEstimationSession) -> Double {
        let recorded = session.sampleSites.filter { $0.isRecorded }
        guard !recorded.isEmpty else { return 0 }

        var totalYieldKg: Double = 0

        let grouped = Dictionary(grouping: session.sampleSites, by: \.paddockId)
        for (paddockId, sites) in grouped {
            let recordedSites = sites.filter { $0.isRecorded }
            guard !recordedSites.isEmpty else { continue }

            guard let paddock = paddocks.first(where: { $0.id == paddockId }) else { continue }

            let avgBunches = recordedSites.reduce(0.0) { $0 + ($1.bunchCountEntry?.bunchesPerVine ?? 0) } / Double(recordedSites.count)
            let avgBunchesRounded = (avgBunches * 100).rounded() / 100
            let totalVines = paddock.effectiveVineCount
            let totalBunches = Double(totalVines) * avgBunchesRounded
            let dmgFactor = store.damageFactor(for: paddockId)
            totalYieldKg += totalBunches * session.bunchWeightKg(for: paddockId) * dmgFactor
        }

        return totalYieldKg / 1000.0
    }
}

// MARK: - Supporting Types

private struct BlockSummary {
    let paddockId: UUID
    let paddockName: String
    let areaHa: Double
    let yieldTonnes: Double
    let yieldPerHa: Double
    let samplesRecorded: Int
    let samplesTotal: Int
    let lastUpdated: Date
}

private enum HistoricalSort: String, CaseIterable {
    case newest
    case oldest
    case highestYield
    case lowestYield

    var label: String {
        switch self {
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .highestYield: "Highest Yield"
        case .lowestYield: "Lowest Yield"
        }
    }
}

// MARK: - Archive Sheet

private struct ArchiveYieldSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private var fmt: RegionFormatter { store.settings.regionFormatter }
    @State private var season: String = ""
    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var notes: String = ""
    @State private var actualYields: [UUID: String] = [:]
    @FocusState private var focusedBlock: UUID?

    let blockSummaries: [BlockSummary]
    let totalYieldTonnes: Double
    let totalArea: Double

    private func parsedActual(for id: UUID) -> Double? {
        guard let raw = actualYields[id]?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."),
              !raw.isEmpty,
              let v = Double(raw), v >= 0 else { return nil }
        return v
    }

    private var totalActualEntered: Double {
        blockSummaries.reduce(0.0) { $0 + (parsedActual(for: $1.paddockId) ?? 0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Year")
                        Spacer()
                        TextField("Year", value: $year, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    TextField("Season Name (optional)", text: $season)
                } header: {
                    Text("Season")
                } footer: {
                    Text("e.g. \"2024/25 Vintage\" or leave blank for just the year.")
                }

                Section {
                    HStack {
                        Text("Total Yield")
                        Spacer()
                        Text(String(format: "%.2f t", totalYieldTonnes))
                            .foregroundStyle(VineyardTheme.leafGreen)
                            .fontWeight(.semibold)
                    }
                    HStack {
                        Text("Total Area")
                        Spacer()
                        Text(fmt.formatArea(hectares: totalArea))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Blocks")
                        Spacer()
                        Text("\(blockSummaries.count)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Summary")
                }

                Section {
                    ForEach(blockSummaries, id: \.paddockId) { summary in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(summary.paddockName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(String(format: "Est. %.2f t", summary.yieldTonnes))
                                    .font(.caption)
                                    .foregroundStyle(VineyardTheme.leafGreen)
                            }
                            HStack {
                                Text("Actual")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField("0.00", text: Binding(
                                    get: { actualYields[summary.paddockId] ?? "" },
                                    set: { actualYields[summary.paddockId] = $0 }
                                ))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedBlock, equals: summary.paddockId)
                                .frame(width: 100)
                                Text("t")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Block Results & Actual Yield")
                } footer: {
                    Text("Actual yields are optional — you can leave them blank and fill them in later from the archived record.")
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes")
                }
            }
            .navigationTitle("Archive Season")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        archiveSeason()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func archiveSeason() {
        guard let vid = store.selectedVineyardId else { return }

        let now = Date()
        let blockResults = blockSummaries.map { summary -> HistoricalBlockResult in
            let actual = parsedActual(for: summary.paddockId)
            return HistoricalBlockResult(
                paddockId: summary.paddockId,
                paddockName: summary.paddockName,
                areaHectares: summary.areaHa,
                yieldTonnes: summary.yieldTonnes,
                yieldPerHectare: summary.yieldPerHa,
                averageBunchesPerVine: 0,
                averageBunchWeightGrams: 0,
                totalVines: 0,
                samplesRecorded: summary.samplesRecorded,
                damageFactor: 1.0,
                actualYieldTonnes: actual,
                actualRecordedAt: actual != nil ? now : nil
            )
        }

        let record = HistoricalYieldRecord(
            vineyardId: vid,
            season: season,
            year: year,
            blockResults: blockResults,
            totalYieldTonnes: totalYieldTonnes,
            totalAreaHectares: totalArea,
            notes: notes
        )

        store.addHistoricalYieldRecord(record)
    }
}

// MARK: - Historical Detail Sheet

private struct HistoricalYieldDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    private var fmt: RegionFormatter { store.settings.regionFormatter }
    let record: HistoricalYieldRecord
    @State private var editingBlock: HistoricalBlockResult?
    @State private var showDeleteConfirm: Bool = false

    private var currentRecord: HistoricalYieldRecord {
        store.historicalYieldRecords.first(where: { $0.id == record.id }) ?? record
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            detailCard(
                                title: "Estimated",
                                value: String(format: "%.2f t", currentRecord.totalYieldTonnes),
                                icon: "scalemass",
                                color: VineyardTheme.leafGreen
                            )
                            detailCard(
                                title: "Actual",
                                value: currentRecord.totalActualYieldTonnes.map { String(format: "%.2f t", $0) } ?? "—",
                                icon: "scalemass.fill",
                                color: .blue
                            )
                        }

                        HStack(spacing: 12) {
                            detailCard(
                                title: "Est. Yield/\(fmt.areaUnitAbbreviation)",
                                value: currentRecord.totalAreaHectares > 0 ? fmt.formatYieldPerArea(perHectare: currentRecord.yieldPerHectare) : "—",
                                icon: "square.dashed",
                                color: .orange
                            )
                            detailCard(
                                title: "Total Area",
                                value: fmt.formatArea(hectares: currentRecord.totalAreaHectares),
                                icon: "ruler.fill",
                                color: .teal
                            )
                        }

                        if let accuracy = currentRecord.estimateAccuracyPercent {
                            detailCard(
                                title: "Estimate Accuracy",
                                value: String(format: "%.1f%%", accuracy),
                                icon: "scope",
                                color: accuracyColor(accuracy)
                            )
                        }
                    }

                    let missingActuals = currentRecord.blockResults.filter { $0.actualYieldTonnes == nil }.count
                    if missingActuals > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .font(.body)
                                .foregroundStyle(VineyardTheme.info)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enter Actual Yield")
                                    .font(.subheadline.weight(.semibold))
                                Text("Tap any block below to record the actual harvested tonnage and see estimate accuracy.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(VineyardTheme.info.opacity(0.1), in: .rect(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Block Results", systemImage: "chart.bar.doc.horizontal")
                                .font(.headline)
                            Spacer()
                            Text("Tap to edit actuals")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(currentRecord.blockResults) { block in
                            Button {
                                editingBlock = block
                            } label: {
                                blockCard(block)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !currentRecord.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Notes", systemImage: "note.text")
                                .font(.headline)

                            Text(currentRecord.notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationTitle(currentRecord.season.isEmpty ? "\(currentRecord.year)" : currentRecord.season)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if accessControl?.canDelete ?? false {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .sheet(item: $editingBlock) { block in
                EditActualYieldSheet(recordId: currentRecord.id, block: block)
            }
            .alert("Delete Historical Record?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    store.deleteHistoricalYieldRecord(currentRecord)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete this historical yield record. This cannot be undone.")
            }
        }
    }

    private func blockCard(_ block: HistoricalBlockResult) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(block.paddockName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "pencil.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Estimated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f t", block.yieldTonnes))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                    if block.areaHectares > 0 {
                        Text(fmt.formatYieldPerArea(perHectare: block.yieldPerHectare))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().frame(height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Actual")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let actual = block.actualYieldTonnes {
                        Text(String(format: "%.2f t", actual))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(VineyardTheme.info)
                        if let perHa = block.actualYieldPerHectare {
                            Text(fmt.formatYieldPerArea(perHectare: perHa))
                                .font(.caption2)
                                .foregroundStyle(.blue.opacity(0.8))
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                                .font(.caption)
                            Text("Tap to add")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(VineyardTheme.info)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let variance = block.yieldVarianceTonnes {
                HStack(spacing: 4) {
                    Image(systemName: variance >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.weight(.bold))
                    Text(String(format: "%@%.2f t vs estimate", variance >= 0 ? "+" : "", variance))
                        .font(.caption2.weight(.medium))
                    Spacer()
                    if let accuracy = block.estimateAccuracyPercent {
                        HStack(spacing: 3) {
                            Image(systemName: "scope")
                                .font(.caption2.weight(.bold))
                            Text(String(format: "%.0f%% accurate", accuracy))
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(accuracyColor(accuracy))
                    }
                }
                .foregroundStyle(variance >= 0 ? .green : .red)
            }

            HStack {
                Text(fmt.formatArea(hectares: block.areaHectares))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if block.samplesRecorded > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                        Text("\(block.samplesRecorded) samples")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func accuracyColor(_ percent: Double) -> Color {
        if percent >= 90 { return .green }
        if percent >= 75 { return .orange }
        return .red
    }

    private func detailCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }
}

// MARK: - Edit Actual Yield Sheet

private struct EditActualYieldSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private var fmt: RegionFormatter { store.settings.regionFormatter }
    let recordId: UUID
    let block: HistoricalBlockResult
    @State private var actualYieldText: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Block")
                        Spacer()
                        Text(block.paddockName)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Area")
                        Spacer()
                        Text(fmt.formatArea(hectares: block.areaHectares))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Estimated")
                        Spacer()
                        Text(String(format: "%.2f t", block.yieldTonnes))
                            .foregroundStyle(VineyardTheme.leafGreen)
                            .fontWeight(.semibold)
                    }
                }

                Section {
                    HStack {
                        Text("Actual Yield")
                        Spacer()
                        TextField("0.00", text: $actualYieldText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($fieldFocused)
                            .frame(width: 120)
                        Text("t")
                            .foregroundStyle(.secondary)
                    }

                    if let parsed = parsedActualYield, block.areaHectares > 0 {
                        HStack {
                            Text("Yield / \(fmt.areaUnitAbbreviation)")
                            Spacer()
                            Text(fmt.formatYieldPerArea(perHectare: parsed / block.areaHectares))
                                .foregroundStyle(VineyardTheme.info)
                        }
                        let variance = parsed - block.yieldTonnes
                        HStack {
                            Text("Variance")
                            Spacer()
                            Text(String(format: "%@%.2f t", variance >= 0 ? "+" : "", variance))
                                .foregroundStyle(variance >= 0 ? .green : .red)
                                .fontWeight(.semibold)
                        }
                        if parsed > 0 {
                            let accuracy = max(0, (1 - abs(parsed - block.yieldTonnes) / parsed) * 100)
                            HStack {
                                Text("Estimate Accuracy")
                                Spacer()
                                Text(String(format: "%.1f%%", accuracy))
                                    .foregroundStyle(accuracy >= 90 ? .green : (accuracy >= 75 ? .orange : .red))
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                } header: {
                    Text("Harvest Result")
                } footer: {
                    Text("Enter the actual harvested tonnage for this block.")
                }

                if block.actualYieldTonnes != nil {
                    Section {
                        Button(role: .destructive) {
                            clearActual()
                        } label: {
                            Label("Clear Actual Yield", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Actual Yield")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveActual()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(parsedActualYield == nil)
                }
            }
            .onAppear {
                if let existing = block.actualYieldTonnes {
                    actualYieldText = String(format: "%.2f", existing)
                }
                fieldFocused = true
            }
        }
    }

    private var parsedActualYield: Double? {
        let trimmed = actualYieldText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value >= 0 else { return nil }
        return value
    }

    private func saveActual() {
        guard let value = parsedActualYield else { return }
        guard var record = store.historicalYieldRecords.first(where: { $0.id == recordId }) else { return }
        guard let idx = record.blockResults.firstIndex(where: { $0.id == block.id }) else { return }
        record.blockResults[idx].actualYieldTonnes = value
        record.blockResults[idx].actualRecordedAt = Date()
        store.updateHistoricalYieldRecord(record)
    }

    private func clearActual() {
        guard var record = store.historicalYieldRecords.first(where: { $0.id == recordId }) else { return }
        guard let idx = record.blockResults.firstIndex(where: { $0.id == block.id }) else { return }
        record.blockResults[idx].actualYieldTonnes = nil
        record.blockResults[idx].actualRecordedAt = nil
        store.updateHistoricalYieldRecord(record)
        dismiss()
    }
}
