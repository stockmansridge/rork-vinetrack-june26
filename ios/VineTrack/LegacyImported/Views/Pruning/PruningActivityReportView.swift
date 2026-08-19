import SwiftUI

/// Full vineyard-wide Pruning Activity Report — every pruning record for the
/// selected vineyard and growing season in one sortable, filterable table.
///
/// Data source: the SAME server-authoritative pruning cache the tracker uses
/// (`PruningStore`, fed by `record_pruning_entry` / `update_pruning_entry` /
/// `delete_pruning_entry` and the `pruning_row_segments` attribution). No
/// second interpretation of pruning records exists here — rows are projected
/// through the shared `PruningActivityReport` contract, which Android mirrors
/// field for field.
struct PruningActivityReportView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(PruningSyncService.self) private var pruningSync
    @Environment(\.accessControl) private var accessControl
    let pruningStore: PruningStore

    /// Sort + season survive an app restart; ad-hoc filters intentionally do not.
    @AppStorage("pruningReportSortColumn") private var sortColumnRaw: String = ""
    @AppStorage("pruningReportSortAscending") private var sortAscending: Bool = false
    @AppStorage("pruningReportSeason") private var storedSeason: Int = 0

    @State private var filter = PruningActivityFilter()
    @State private var search: String = ""
    @State private var selectedRow: PruningActivityRow?
    @State private var showFilters: Bool = false
    @State private var editTarget: PruningReportEditTarget?
    @State private var openTask: WorkTask?
    @State private var reversalTarget: PruningActivityRow?
    @State private var accountNames: [UUID: String] = [:]
    @State private var didRestoreSeason: Bool = false
    @State private var exportError: String?
    /// Off by default: the PDF is a document people read, so it shows the
    /// activity's name and a short reference. Full ids are for reconciliation
    /// and only appear when someone deliberately asks for them.
    @State private var includeTechnicalReferences: Bool = false

    private var canViewCosting: Bool { accessControl?.canViewCosting ?? false }
    private var canDeleteLinkedTask: Bool { accessControl?.canDelete ?? false }

    private var vineyardId: UUID? { store.selectedVineyardId }

    // MARK: Data pipeline

    private var paddocks: [Paddock] {
        guard let vineyardId else { return store.paddocks }
        return store.paddocks.filter { $0.vineyardId == vineyardId }
    }

    /// Block context resolved ONCE per block (name, variety, rows) — the
    /// report never looks an entity up per record.
    private var blockContexts: [UUID: PruningActivityBlockContext] {
        var map: [UUID: PruningActivityBlockContext] = [:]
        for paddock in paddocks {
            let setup = pruningStore.setup(for: paddock.id)
            map[paddock.id] = PruningActivityBlockContext(
                name: paddock.name,
                variety: paddock.varietyAllocations.max { $0.percent < $1.percent }?.name,
                rows: PruningCalculator.rowRefs(paddock: paddock, setup: setup)
            )
        }
        return map
    }

    /// One pass over the tasks and their labour lines — never one lookup per
    /// record.
    ///
    /// Each task's cost comes from its EFFECTIVE labour cost
    /// (`PieceRateCosting.effectiveLabourCost`), so a piece-rate job reports its
    /// snapshot total even with zero labour lines, while an hourly job keeps the
    /// unchanged labour-line behaviour. A record with neither still falls back
    /// to its own legacy activity value in `PruningActivityReport.rows(...)` —
    /// never both, so a total can't count the same labour twice.
    private var labourCosts: [UUID: Double] {
        var costs = PieceRateCosting.effectiveCostsByWorkTask(
            tasks: store.workTasks,
            labourLines: store.workTaskLabourLines,
            includeCost: canViewCosting
        )
        // sql/200: a multi-task activity reports the SUM of its linked tasks'
        // canonical totals, overlaid on its PRIMARY (mirror) task key so the
        // report engine stays single-keyed and counts each activity once.
        for (mirror, aggregate) in multiTaskAggregates {
            if canViewCosting, let cost = aggregate.cost { costs[mirror] = cost }
        }
        return costs
    }

    /// Per-activity Work Task aggregates for activities with MORE than one
    /// linked task (sql/200), keyed by the activity's primary mirror task.
    private var multiTaskAggregates: [UUID: PruningActivityTaskAggregate] {
        guard let vineyardId else { return [:] }
        let tasks = store.workTasks.filter { $0.vineyardId == vineyardId }
        let linesByTask = PruningWorkTaskLink.linesByTask(store.workTaskLabourLines)
        var result: [UUID: PruningActivityTaskAggregate] = [:]
        for activity in pruningStore.activities(forVineyard: vineyardId) {
            guard let mirror = activity.workTaskId else { continue }
            let linked = PruningWorkTaskLink.linkedTasks(activity, tasks: tasks)
            guard linked.count > 1 else { continue }
            result[mirror] = PruningWorkTaskLink.aggregate(linked, linesByTask: linesByTask)
        }
        return result
    }

    /// SNAPSHOT vine quantities of the piece-rate jobs — the historical
    /// denominator behind each row's cost per vine.
    private var pieceRateVines: [UUID: Int] {
        PieceRateCosting.snapshotVinesByWorkTask(store.workTasks)
    }

    /// Per-task person-hours — the authoritative labour hours for report rows
    /// whose linked task carries labour lines.
    private var labourHours: [UUID: Double] {
        var hours = WorkTaskLabourCosting.hoursByWorkTask(store.workTaskLabourLines)
        for (mirror, aggregate) in multiTaskAggregates {
            if let h = aggregate.hours { hours[mirror] = h }
        }
        return hours
    }

    private var workTaskTitles: [UUID: String] {
        var titles: [UUID: String] = [:]
        for task in store.workTasks {
            let described = task.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
            titles[task.id] = (described?.isEmpty == false ? described : nil)
                ?? (task.taskType.isEmpty ? "Work Task" : task.taskType)
        }
        // A multi-task activity's row names the derived set, not one task.
        for (mirror, aggregate) in multiTaskAggregates where aggregate.taskCount > 1 {
            titles[mirror] = "\(aggregate.taskCount) Work Tasks"
        }
        return titles
    }

    /// Presentable Work Task status for the report's exports ("in_progress" →
    /// "In progress"). Unknown values pass through rather than being blanked, so
    /// a new server status never silently disappears from an export.
    private var workTaskStatuses: [UUID: String] {
        var statuses: [UUID: String] = [:]
        for task in store.workTasks {
            guard let raw = task.status?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let cleaned = raw
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .lowercased()
            statuses[task.id] = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
        return statuses
    }

    private var allRows: [PruningActivityRow] {
        guard let vineyardId else { return [] }
        return PruningActivityReport.rows(
            entries: pruningStore.auditEntries(forVineyard: vineyardId),
            blocks: blockContexts,
            workTaskTitles: workTaskTitles,
            workTaskStatuses: workTaskStatuses,
            labourCosts: labourCosts,
            labourHours: labourHours,
            pieceRateVines: pieceRateVines,
            accountNames: accountNames
        )
    }

    private var activeFilter: PruningActivityFilter {
        var applied = filter
        applied.search = search
        return applied
    }

    private var rows: [PruningActivityRow] {
        PruningActivityReport.sorted(
            PruningActivityReport.filtered(allRows, with: activeFilter),
            by: sort
        )
    }

    private var summary: PruningActivitySummary {
        // `allRows` is the CANONICAL set — every allocation of every activity,
        // before any filter. It supplies the parent activity context and the
        // allocation-share denominator, so filtering to one block of a
        // multi-block activity never hands that block the whole activity's
        // labour.
        PruningActivityReport.summary(rows, includeCost: canViewCosting, canonicalRows: allRows)
    }

    private var columns: [PruningActivityColumn] {
        PruningActivityColumn.displayOrder.filter { canViewCosting || !$0.isCosting }
    }

    private var sort: PruningActivitySort {
        PruningActivitySort(
            column: PruningActivityColumn(rawValue: sortColumnRaw),
            ascending: sortAscending
        )
    }

    private var seasonOptions: [Int] {
        let years = Set(allRows.map(\.seasonYear) + [PruningSeasonId.currentSeasonYear])
        return years.sorted(by: >)
    }

    // MARK: Export

    private enum ExportFormat {
        case csv
        case pdf
    }

    /// Exports carry the CURRENT result set — same filters, same search, same
    /// sort — so the file always matches what is on screen.
    private var exportMenu: some View {
        Menu {
            Button {
                share(.csv)
            } label: {
                Label("Export CSV (one row per allocation)", systemImage: "tablecells")
            }
            Button {
                share(.pdf)
            } label: {
                Label("Export PDF (grouped by activity)", systemImage: "doc.richtext")
            }
            Divider()
            Toggle(isOn: $includeTechnicalReferences) {
                Label("Include technical references", systemImage: "number")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(rows.isEmpty)
        .accessibilityLabel("Export the pruning activity report")
    }

    private var exportVineyardName: String {
        guard let vineyardId else { return "" }
        return store.vineyards.first { $0.id == vineyardId }?.name ?? ""
    }

    /// Writes the export to a temporary file and hands it to the system share
    /// sheet. `canViewCosting` gates the labour cost out of the DATA, not just
    /// the rendering, so a supervisor's file never contains money.
    private func share(_ format: ExportFormat) {
        let exported = rows
        guard !exported.isEmpty else { return }
        let seasonLabel = filter.seasonYear.map(String.init) ?? ""

        do {
            let url: URL
            switch format {
            case .csv:
                url = try PruningActivityExportService.csvURL(
                    rows: exported,
                    vineyardName: exportVineyardName,
                    seasonLabel: seasonLabel,
                    includeCost: canViewCosting,
                    canonicalRows: allRows
                )
            case .pdf:
                url = try PruningActivityExportService.pdfURL(
                    rows: exported,
                    vineyardName: exportVineyardName,
                    seasonLabel: seasonLabel,
                    includeCost: canViewCosting,
                    canonicalRows: allRows,
                    includeTechnicalReferences: includeTechnicalReferences
                )
            }
            present(url)
        } catch {
            exportError = "The report could not be written to a file. Please try again."
        }
    }

    private func present(_ url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        controller.popoverPresentationController?.sourceView = presenter.view
        presenter.present(controller, animated: true)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            summaryStrip
            filterBar
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle("Activity Report")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Worker, block, variety, row, task, notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                exportMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: activeFilter.hasRestrictions
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter the pruning activity report")
            }
        }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .task {
            restoreSeasonIfNeeded()
            await loadAccountNames()
            await pruningSync.syncForSelectedVineyard()
        }
        .refreshable {
            await pruningSync.syncForSelectedVineyard()
        }
        .sheet(isPresented: $showFilters) {
            PruningActivityFilterSheet(
                filter: $filter,
                seasons: seasonOptions,
                workers: distinct(\.worker),
                blocks: blockOptions,
                varieties: distinct(\.variety),
                matchCount: rows.count
            )
        }
        .sheet(item: $selectedRow) { row in
            PruningActivityDetailSheet(
                row: row,
                canViewCosting: canViewCosting,
                onEdit: { beginEdit(row) },
                onOpenWorkTask: { openWorkTask(row) },
                onReverse: { requestReversal(row) }
            )
        }
        .sheet(item: $openTask) { task in
            AddEditWorkTaskView(existingTask: task)
        }
        .navigationDestination(item: $editTarget) { target in
            PruningBlockDetailView(
                paddock: target.paddock,
                pruningStore: pruningStore,
                initialEditEntryId: target.entryId
            )
        }
        .confirmationDialog(
            "This pruning entry has a linked Work Task. What should happen to the task?",
            isPresented: Binding(
                get: { reversalTarget != nil },
                set: { if !$0 { reversalTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Keep Work Task") {
                if let row = reversalTarget { pruningStore.deleteEntry(id: row.id) }
                reversalTarget = nil
            }
            if canDeleteLinkedTask {
                Button("Delete Work Task", role: .destructive) {
                    if let row = reversalTarget {
                        if let taskId = row.workTaskId { store.deleteWorkTask(taskId) }
                        pruningStore.deleteEntry(id: row.id)
                    }
                    reversalTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { reversalTarget = nil }
        } message: {
            Text("Reversing the entry always reopens its row quarters. The linked Work Task can be kept for your labour records or deleted with it.")
        }
    }

    // MARK: Summary strip

    private var summaryStrip: some View {
        let totals = summary
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                summaryChip(value: "\(totals.jobs)", label: "Jobs")
                summaryChip(value: totals.vines.formatted(.number.precision(.fractionLength(0))), label: "Vines")
                summaryChip(value: totals.labourHours.formatted(.number.precision(.fractionLength(0...1))) + " h", label: "Labour hours")
                summaryChip(
                    value: totals.averageVinesPerHour.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—",
                    label: "Avg vines / hr"
                )
                if canViewCosting {
                    summaryChip(
                        value: totals.labourCost.map { "$" + $0.formatted(.number.precision(.fractionLength(2))) } ?? "—",
                        label: "Labour cost"
                    )
                }
                summaryChip(value: "\(totals.activeRecords)", label: "Active")
                summaryChip(value: "\(totals.reversedRecords)", label: "Reversed", muted: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(VineyardTheme.cardBackground)
    }

    private func summaryChip(value: String, label: String, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(muted ? Color.secondary : Color.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(VineyardTheme.appBackground, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            Text(seasonLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.secondary)
            Text("\(rows.count) record\(rows.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if activeFilter.hasRestrictions {
                Button("Clear filters") {
                    var cleared = PruningActivityFilter(seasonYear: filter.seasonYear)
                    cleared.seasonYear = filter.seasonYear
                    filter = cleared
                    search = ""
                }
                .font(.caption.weight(.semibold))
            }
            if sort.column != nil {
                Button("Reset sort") {
                    apply(.default)
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var seasonLabel: String {
        guard let season = filter.seasonYear else { return "All seasons" }
        return "Season \(String(season))"
    }

    // MARK: Table

    /// Report table: sticky heading row, horizontal scrolling for the wider
    /// column set, compact readable cells and a row tap that opens the full
    /// record. Rendered lazily so a large history stays responsive.
    private var table: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in
                            Button {
                                selectedRow = row
                            } label: {
                                tableRow(row)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    } header: {
                        headerRow
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Button {
                    apply(sort.cycled(column))
                } label: {
                    HStack(spacing: 3) {
                        Text(column.label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        switch sort.direction(for: column) {
                        case .ascending:
                            Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
                        case .descending:
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        case .none:
                            EmptyView()
                        }
                    }
                    .frame(width: width(for: column), height: 38, alignment: .leading)
                    .padding(.horizontal, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!column.isSortable)
                .accessibilityLabel(sortAccessibilityLabel(column))
            }
        }
        .background(VineyardTheme.cardBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sortAccessibilityLabel(_ column: PruningActivityColumn) -> String {
        guard column.isSortable else { return column.label }
        switch sort.direction(for: column) {
        case .ascending: return "\(column.label), sorted ascending. Activate to sort descending."
        case .descending: return "\(column.label), sorted descending. Activate to clear the sort."
        case .none: return "\(column.label), unsorted. Activate to sort ascending."
        }
    }

    private func tableRow(_ row: PruningActivityRow) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                cell(row, column)
                    .frame(width: width(for: column), height: 44, alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
        .background(row.isReversed ? Color.secondary.opacity(0.07) : Color.clear)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(row))
    }

    private func rowAccessibilityLabel(_ row: PruningActivityRow) -> String {
        var parts: [String] = [Self.dayFormatter.string(from: row.date)]
        if let worker = row.worker { parts.append(worker) }
        parts.append(row.blockName)
        if let vines = row.vines { parts.append("\(Int(vines.rounded())) vines") }
        parts.append(row.status.label)
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func cell(_ row: PruningActivityRow, _ column: PruningActivityColumn) -> some View {
        switch column {
        case .status:
            statusBadge(row.status)
        case .workTask:
            if row.hasWorkTask {
                Label(row.workTaskTitle ?? "Work Task", systemImage: "link")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .lineLimit(1)
            } else {
                text("—", row)
            }
        default:
            text(value(row, column), row)
        }
    }

    private func text(_ value: String, _ row: PruningActivityRow) -> some View {
        Text(value)
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(row.isReversed ? Color.secondary : Color.primary)
    }

    private func statusBadge(_ status: PruningActivityStatus) -> some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint(status))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint(status).opacity(0.14), in: .capsule)
    }

    private func tint(_ status: PruningActivityStatus) -> Color {
        switch status {
        case .active: return VineyardTheme.leafGreen
        case .edited: return .blue
        case .reversed: return .secondary
        }
    }

    private func value(_ row: PruningActivityRow, _ column: PruningActivityColumn) -> String {
        switch column {
        case .date: return Self.dayFormatter.string(from: row.date)
        case .worker: return row.worker ?? "—"
        case .block: return row.blockName
        case .variety: return row.variety ?? "—"
        case .rows: return row.rowRangeLabel ?? "—"
        case .quarters: return row.quartersLabel ?? "—"
        case .vines: return row.vines.map { $0.rounded().formatted(.number.precision(.fractionLength(0))) } ?? "—"
        case .hours: return row.labourHours.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—"
        case .start: return row.startTime.map { Self.timeFormatter.string(from: $0) } ?? "—"
        case .finish: return row.finishTime.map { Self.timeFormatter.string(from: $0) } ?? "—"
        case .duration: return row.durationHours.map { $0.formatted(.number.precision(.fractionLength(0...1))) + " h" } ?? "—"
        case .vinesPerHour: return row.vinesPerHour.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—"
        case .labourCost: return row.labourCost.map { "$" + $0.formatted(.number.precision(.fractionLength(2))) } ?? "—"
        case .workTask: return row.workTaskTitle ?? "—"
        case .notes: return row.notes ?? "—"
        case .enteredBy: return row.enteredBy ?? "—"
        case .created: return row.createdAt.map { Self.stampFormatter.string(from: $0) } ?? "—"
        case .updated: return row.updatedAt.map { Self.stampFormatter.string(from: $0) } ?? "—"
        case .status: return row.status.label
        }
    }

    private func width(for column: PruningActivityColumn) -> CGFloat {
        switch column {
        case .date: return 92
        case .worker: return 120
        case .block: return 130
        case .variety: return 120
        case .rows: return 74
        case .quarters: return 70
        case .vines: return 70
        case .hours: return 62
        case .start, .finish: return 66
        case .duration: return 78
        case .vinesPerHour: return 78
        case .labourCost: return 96
        case .workTask: return 130
        case .notes: return 180
        case .enteredBy: return 130
        case .created, .updated: return 130
        case .status: return 92
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(allRows.isEmpty ? "No pruning activity yet" : "No records match these filters")
                .font(.headline)
            Text(allRows.isEmpty
                 ? "Record pruning on a block and every job will appear here."
                 : "Adjust the season, date range or filters to see more records.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func apply(_ next: PruningActivitySort) {
        sortColumnRaw = next.column?.rawValue ?? ""
        sortAscending = next.ascending
    }

    private func restoreSeasonIfNeeded() {
        guard !didRestoreSeason else { return }
        didRestoreSeason = true
        let seasons = seasonOptions
        let restored = storedSeason
        if restored > 0, seasons.contains(restored) {
            filter.seasonYear = restored
        } else {
            filter.seasonYear = PruningSeasonId.currentSeasonYear
        }
    }

    /// One directory call per open — never a per-record lookup.
    private func loadAccountNames() async {
        guard let vineyardId, accountNames.isEmpty else { return }
        let members = try? await SupabaseTeamRepository().listMembers(vineyardId: vineyardId)
        guard let members else { return }
        var map: [UUID: String] = [:]
        for member in members {
            let name = member.fullName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            map[member.userId] = [name, display, member.email]
                .compactMap { $0 }
                .first { !$0.isEmpty }
        }
        accountNames = map
    }

    private func beginEdit(_ row: PruningActivityRow) {
        guard !row.isReversed, let paddock = paddocks.first(where: { $0.id == row.paddockId }) else { return }
        selectedRow = nil
        editTarget = PruningReportEditTarget(paddock: paddock, entryId: row.id)
    }

    private func openWorkTask(_ row: PruningActivityRow) {
        guard let taskId = row.workTaskId,
              let task = store.workTasks.first(where: { $0.id == taskId }) else { return }
        selectedRow = nil
        openTask = task
    }

    private func requestReversal(_ row: PruningActivityRow) {
        guard !row.isReversed else { return }
        selectedRow = nil
        if row.hasWorkTask {
            reversalTarget = row
        } else {
            pruningStore.deleteEntry(id: row.id)
        }
    }

    private func distinct(_ keyPath: KeyPath<PruningActivityRow, String?>) -> [String] {
        let values = allRows.compactMap { $0[keyPath: keyPath] }.filter { !$0.isEmpty }
        return Array(Set(values)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var blockOptions: [(id: UUID, name: String)] {
        paddocks
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { (id: $0.id, name: $0.name) }
    }

    // MARK: Formatters

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()
}

/// Deep-link payload: open the block's tracker screen with this entry already
/// in edit mode, so the report reuses the EXISTING edit flow and its RPC.
struct PruningReportEditTarget: Identifiable, Hashable {
    let paddock: Paddock
    let entryId: UUID

    var id: UUID { entryId }

    static func == (lhs: PruningReportEditTarget, rhs: PruningReportEditTarget) -> Bool {
        lhs.entryId == rhs.entryId && lhs.paddock.id == rhs.paddock.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(entryId)
        hasher.combine(paddock.id)
    }
}

// MARK: - Detail sheet

private struct PruningActivityDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let row: PruningActivityRow
    let canViewCosting: Bool
    let onEdit: () -> Void
    let onOpenWorkTask: () -> Void
    let onReverse: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if row.isReversed {
                        Label("Reversed — audit history only. This record no longer contributes to pruning totals and can't be edited or reversed again.", systemImage: "arrow.uturn.backward.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    detail("Status", row.status.label)
                    detail("Date", PruningActivityReportView.dayFormatter.string(from: row.date))
                    detail("Worker or crew", row.worker)
                    detail("Block", row.blockName)
                    detail("Variety", row.variety)
                    detail("Rows", row.rowRangeLabel)
                    detail("Quarters completed", row.quarters > 0 ? "\(row.quarters)" : nil)
                    detail("Row equivalents", row.rowEquivalents.formatted(.number.precision(.fractionLength(0...2))))
                    detail("Vines completed", row.vines.map { $0.rounded().formatted(.number.precision(.fractionLength(0))) })
                    detail("Method", row.method)
                }

                Section("Labour") {
                    detail("Labour hours", row.labourHours.map { $0.formatted(.number.precision(.fractionLength(0...1))) })
                    detail("Start time", row.startTime.map { PruningActivityReportView.timeFormatter.string(from: $0) })
                    detail("Finish time", row.finishTime.map { PruningActivityReportView.timeFormatter.string(from: $0) })
                    detail("Duration", row.durationHours.map { $0.formatted(.number.precision(.fractionLength(0...1))) + " h" })
                    detail("Vines per hour", row.vinesPerHour.map { $0.formatted(.number.precision(.fractionLength(0))) })
                    if canViewCosting {
                        detail("Labour cost", row.labourCost.map { "$" + $0.formatted(.number.precision(.fractionLength(2))) })
                    }
                }

                Section("Record") {
                    detail("Work Task", row.hasWorkTask ? (row.workTaskTitle ?? "Work Task") : nil)
                    detail("Notes", row.notes)
                    detail("Entered by", row.enteredBy)
                    detail("Created", row.createdAt.map { PruningActivityReportView.stampFormatter.string(from: $0) })
                    detail("Last updated", row.updatedAt.map { PruningActivityReportView.stampFormatter.string(from: $0) })
                }

                Section {
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit record", systemImage: "pencil")
                    }
                    .disabled(row.isReversed)
                    if row.hasWorkTask {
                        Button {
                            onOpenWorkTask()
                        } label: {
                            Label("Open Work Task", systemImage: "link")
                        }
                    }
                    Button(role: .destructive) {
                        onReverse()
                    } label: {
                        Label("Reverse record", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(row.isReversed)
                }
            }
            .navigationTitle("Pruning Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Genuinely unavailable values render as "—" — never as a false zero.
    private func detail(_ label: String, _ value: String?) -> some View {
        LabeledContent(label, value: value?.isEmpty == false ? (value ?? "—") : "—")
            .font(.subheadline)
    }
}

// MARK: - Filter sheet

private struct PruningActivityFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: PruningActivityFilter
    let seasons: [Int]
    let workers: [String]
    let blocks: [(id: UUID, name: String)]
    let varieties: [String]
    let matchCount: Int

    @State private var useDateRange: Bool = false
    @State private var from: Date = Date()
    @State private var to: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Growing season") {
                    Picker("Season", selection: Binding(
                        get: { filter.seasonYear ?? 0 },
                        set: { filter.seasonYear = $0 == 0 ? nil : $0 }
                    )) {
                        Text("All seasons").tag(0)
                        ForEach(seasons, id: \.self) { year in
                            Text(String(year)).tag(year)
                        }
                    }
                }

                Section("Date range") {
                    Toggle("Limit to a date range", isOn: $useDateRange)
                        .onChange(of: useDateRange) { _, isOn in
                            filter.dateFrom = isOn ? from : nil
                            filter.dateTo = isOn ? to : nil
                        }
                    if useDateRange {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                            .onChange(of: from) { _, value in filter.dateFrom = value }
                        DatePicker("To", selection: $to, displayedComponents: .date)
                            .onChange(of: to) { _, value in filter.dateTo = value }
                    }
                }

                Section("Status") {
                    ForEach(PruningActivityStatus.allCases) { status in
                        toggleRow(status.label, isOn: filter.statuses.contains(status)) { isOn in
                            if isOn { filter.statuses.insert(status) } else { filter.statuses.remove(status) }
                        }
                    }
                }

                Section("Linked Work Task") {
                    Picker("Work Task", selection: $filter.taskLink) {
                        ForEach(PruningActivityTaskLink.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if !workers.isEmpty {
                    Section("Worker or crew") {
                        ForEach(workers, id: \.self) { worker in
                            toggleRow(worker, isOn: filter.workers.contains(worker)) { isOn in
                                if isOn { filter.workers.insert(worker) } else { filter.workers.remove(worker) }
                            }
                        }
                    }
                }

                Section("Block") {
                    ForEach(blocks, id: \.id) { block in
                        toggleRow(block.name, isOn: filter.blocks.contains(block.id)) { isOn in
                            if isOn { filter.blocks.insert(block.id) } else { filter.blocks.remove(block.id) }
                        }
                    }
                }

                if !varieties.isEmpty {
                    Section("Variety") {
                        ForEach(varieties, id: \.self) { variety in
                            toggleRow(variety, isOn: filter.varieties.contains(variety)) { isOn in
                                if isOn { filter.varieties.insert(variety) } else { filter.varieties.remove(variety) }
                            }
                        }
                    }
                }

                Section {
                    Button("Clear filters", role: .destructive) {
                        let season = filter.seasonYear
                        filter = PruningActivityFilter(seasonYear: season)
                        useDateRange = false
                    }
                } footer: {
                    Text("\(matchCount) record\(matchCount == 1 ? "" : "s") match the current filters.")
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                useDateRange = filter.dateFrom != nil || filter.dateTo != nil
                if let existing = filter.dateFrom { from = existing }
                if let existing = filter.dateTo { to = existing }
            }
        }
    }

    private func toggleRow(_ label: String, isOn: Bool, action: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: action))
            .toggleStyle(.switch)
            .font(.subheadline)
    }
}
