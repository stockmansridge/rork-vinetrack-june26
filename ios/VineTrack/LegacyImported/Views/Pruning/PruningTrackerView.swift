import SwiftUI

/// Ordering options for the Pruning Tracker block list.
enum PruningBlockSort: String, CaseIterable, Identifiable {
    case rowNumber
    case alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rowNumber: return "Row number"
        case .alphabetical: return "Block name"
        }
    }
}

/// Resolved state of the "can this account create pruning records?" question.
///
/// The create action is NEVER silently removed. An unknown or still-loading
/// role renders a disabled control with an explanation, because a missing
/// permission answer is a configuration problem the user must be able to see —
/// not a reason to present a blank interface.
enum PruningCreateAccess: Equatable {
    case loading
    case allowed
    case denied
    case unresolved(String)

    var isAllowed: Bool { self == .allowed }

    /// Explanation shown to the user whenever the action is not usable.
    var explanation: String? {
        switch self {
        case .allowed:
            return nil
        case .loading:
            return "Checking your vineyard permissions…"
        case .denied:
            return "Your role on this vineyard can view pruning progress but not record it. Ask an owner or manager for record-creation access."
        case .unresolved(let reason):
            return "Pruning permissions couldn't be confirmed, so recording is locked. \(reason)"
        }
    }
}

/// Pruning Tracker hub — vineyard dashboard plus a visual block list.
/// Reachable from Operational Tools.
struct PruningTrackerView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(PruningSyncService.self) private var pruningSync
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(WorkTaskSyncService.self) private var workTaskSync
    @Environment(WorkTaskLabourLineSyncService.self) private var labourLineSync
    @Environment(WorkTaskPieceRateRowSyncService.self) private var pieceRateRowSync
    @AppStorage("pruningBlockSort") private var blockSortRaw: String = PruningBlockSort.alphabetical.rawValue
    private var pruningStore: PruningStore { .shared }

    /// Set when the user taps a locked create control — surfaces the reason.
    @State private var showAccessExplanation: Bool = false
    /// The activity open in the multi-block editor — the ONE place an activity is
    /// created or changed (sql/166).
    @State private var editorDraft: PruningActivityDraft?
    /// Multi-block activities of this vineyard, pulled through
    /// `list_pruning_activities` — one entry per PARENT record.
    ///
    /// The Tracker no longer renders this feed: the Activity Report (toolbar
    /// action and card below) is the one place activities are listed. The feed is
    /// still loaded here because it is the cache the Activity Report, the editor,
    /// the exports and the sync diagnostics all read, and because refreshing it
    /// is what repairs hollow projections and keeps block progress correct.
    @State private var activities: [PruningActivityDraft] = []

    private var blockSort: PruningBlockSort {
        PruningBlockSort(rawValue: blockSortRaw) ?? .alphabetical
    }

    private var paddocks: [Paddock] {
        let all = store.paddocks
        guard let vineyardId = store.selectedVineyardId else { return all }
        return all.filter { $0.vineyardId == vineyardId }
    }

    private var blockMetrics: [(paddock: Paddock, metrics: PruningBlockMetrics)] {
        let items: [(paddock: Paddock, metrics: PruningBlockMetrics)] = paddocks.map { paddock in
            let setup = pruningStore.setup(for: paddock.id)
            let entries = pruningStore.entries(for: paddock.id)
            return (paddock, PruningCalculator.metrics(paddock: paddock, setup: setup, entries: entries))
        }
        switch blockSort {
        case .alphabetical:
            return items.sorted { $0.paddock.name.localizedStandardCompare($1.paddock.name) == .orderedAscending }
        case .rowNumber:
            // Blocks ordered by their FIRST actual row number; blocks without
            // rows sink to the bottom, ties fall back to the block name.
            return items.sorted { lhs, rhs in
                let left = lhs.metrics.rows.map(\.number).min()
                let right = rhs.metrics.rows.map(\.number).min()
                switch (left, right) {
                case let (l?, r?) where l != r:
                    return l < r
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return lhs.paddock.name.localizedStandardCompare(rhs.paddock.name) == .orderedAscending
                }
            }
        }
    }

    // MARK: Create access

    /// One shared answer for every create affordance on this screen, so the
    /// toolbar `+`, the labelled button and the empty state can never disagree.
    var createAccess: PruningCreateAccess {
        if accessControl.currentRole == nil {
            if accessControl.isLoading { return .loading }
            if let error = accessControl.errorMessage, !error.isEmpty {
                return .unresolved(error)
            }
            return .unresolved("Your membership role for this vineyard hasn't loaded yet. Pull to refresh, or reopen the vineyard.")
        }
        return accessControl.canCreateOperationalRecords ? .allowed : .denied
    }

    /// Total pruning records for the selected vineyard — drives the empty state.
    private var recordedEntryCount: Int {
        paddocks.reduce(0) { $0 + pruningStore.entries(for: $1.id).count }
    }

    /// The create action opens the MULTI-BLOCK editor directly — one activity,
    /// one crew, one set of hours, across as many blocks as the job covered.
    /// A single-block vineyard has that block focused for it.
    private func beginNewActivity() {
        guard createAccess.isAllowed else {
            showAccessExplanation = true
            return
        }
        guard let vineyardId = store.selectedVineyardId else { return }
        pruningSync.clearActivityReconciliation()
        let fresh = PruningActivityDraft(vineyardId: vineyardId)
        if paddocks.count == 1, let only = paddocks.first {
            editorDraft = PruningAllocationEditor.focus(fresh, paddockId: only.id, blockName: only.name)
        } else {
            editorDraft = fresh
        }
    }

    /// Opens an existing activity for editing. The canonical server state is
    /// loaded through `get_pruning_activity`, so every block and quarter is
    /// restored rather than reconstructed from legacy per-block rows.
    private func openActivity(id: UUID, legacy: PruningEntry? = nil) {
        pruningSync.clearActivityReconciliation()
        Task {
            if let loaded = await pruningSync.loadActivity(id: id) {
                editorDraft = loaded
            } else if let legacy {
                let name = paddocks.first { $0.id == legacy.paddockId }?.name ?? ""
                editorDraft = PruningActivityDraft.fromLegacyEntry(legacy, blockName: name)
            }
        }
    }

    private func saveActivity(_ draft: PruningActivityDraft) {
        pruningStore.saveActivity(draft)
        if let vineyardId = store.selectedVineyardId {
            activities = pruningStore.activities(forVineyard: vineyardId)
        }
    }

    /// Creates ONE Work Task for the WHOLE activity through the existing shared
    /// work-task store and sync, and returns its stable client id so the parent
    /// draft can link to it.
    ///
    /// Activity-level by construction: one task, dated with the activity, its
    /// duration the activity's shared labour hours, joined to EVERY block in the
    /// activity. The id is client-generated, so an offline replay or a retry can
    /// never create a second task — and `PruningSyncService` holds the activity
    /// push back until this task has reached the server rather than dropping the
    /// link.
    private func createLinkedWorkTask(
        for activity: PruningActivityDraft,
        task taskDraft: PruningWorkTaskLinkDraft
    ) -> UUID? {
        guard let vineyardId = store.selectedVineyardId else { return nil }
        let blockIds = Set(PruningWorkTaskLink.paddockIds(activity))
        let blocks = paddocks.filter { blockIds.contains($0.id) }
        let userName = auth.userName ?? ""
        let creator = userName.isEmpty ? nil : userName
        let isPieceRate = taskDraft.isPieceRate
        var task = WorkTask(
            vineyardId: vineyardId,
            date: activity.date,
            taskType: taskDraft.trimmedType,
            paddockId: blocks.first?.id,
            paddockName: blocks.map(\.name).joined(separator: ", "),
            durationHours: PruningWorkTaskLink.durationHours(activity),
            notes: taskDraft.trimmedNotes,
            createdBy: creator,
            isFinalized: taskDraft.markCompleted,
            finalizedAt: taskDraft.markCompleted ? Date() : nil,
            finalizedBy: taskDraft.markCompleted ? creator : nil,
            taskDescription: "Pruning — \(activity.blockSummary)",
            status: taskDraft.markCompleted ? "Completed" : nil,
            // sql/188. The costing basis is written WITH the task, so the job is
            // never briefly persisted as an unpriced hourly record.
            costingMethodRaw: taskDraft.costingMethod.rawValue,
            pieceRatePerVine: isPieceRate ? taskDraft.ratePerVine : nil,
            pieceVineCount: isPieceRate ? taskDraft.vineCount : nil
        )
        let area = blocks.reduce(0.0) { $0 + $1.areaHectares }
        if area > 0 { task.areaHa = area }
        store.addWorkTask(task)
        // One join row per block — the task spans every block of the activity.
        for block in blocks {
            store.addWorkTaskPaddock(WorkTaskPaddock(
                workTaskId: task.id,
                vineyardId: vineyardId,
                paddockId: block.id,
                areaHa: block.areaHectares > 0 ? block.areaHectares : nil
            ))
        }

        if isPieceRate {
            // The HISTORICAL per-row breakdown behind the agreed quantity,
            // derived from the quarters actually selected. Written at creation
            // only, so later edits to these rows can never re-cost the job.
            let rowsByPaddock = Dictionary(uniqueKeysWithValues: blocks.map { block in
                (block.id, PruningCalculator.rowRefs(paddock: block, setup: pruningStore.setup(for: block.id)))
            })
            let snapshot = PruningWorkTaskLink.pieceRateRows(
                activity: activity,
                workTaskId: task.id,
                vineyardId: vineyardId,
                rowsByPaddock: rowsByPaddock
            )
            if !snapshot.isEmpty {
                store.replaceWorkTaskPieceRateRows(snapshot, forWorkTask: task.id)
            }
        }

        // Hourly labour is recorded as an ORDINARY labour line — the same record
        // the Work Task editor writes — so there is only ever one hourly
        // calculation in the app. On a piece-rate job the crew's hours are kept
        // too, as operational history that never drives the cost.
        if taskDraft.recordsHourlyLabour {
            store.addWorkTaskLabourLine(WorkTaskLabourLine(
                workTaskId: task.id,
                vineyardId: vineyardId,
                workDate: activity.date,
                operatorCategoryId: taskDraft.operatorCategoryId,
                workerType: taskDraft.workerType.trimmingCharacters(in: .whitespacesAndNewlines),
                workerCount: taskDraft.workerCount,
                hoursPerWorker: taskDraft.hoursPerWorker ?? 0,
                hourlyRate: isPieceRate ? nil : taskDraft.hourlyRate
            ))
        }

        // Push in dependency order: the task header first (its id is a real
        // foreign key), then the children. Each service is idempotent on the
        // client-minted ids, so a retry upserts rather than duplicating.
        Task {
            await workTaskSync.syncForSelectedVineyard()
            await labourLineSync.syncForSelectedVineyard()
            await pieceRateRowSync.syncForSelectedVineyard()
        }
        return task.id
    }

    /// Reverses the parent activity as ONE operation; every allocation inherits it.
    private func reverseActivity(id: UUID) {
        pruningStore.reverseActivity(id: id)
        if let vineyardId = store.selectedVineyardId {
            activities = pruningStore.activities(forVineyard: vineyardId)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if pendingPruningChanges > 0 || pruningSync.errorMessage != nil {
                    pendingSyncBanner
                }
                if !createAccess.isAllowed, let explanation = createAccess.explanation {
                    accessNotice(explanation)
                }
                if let reconciliation = pruningSync.lastActivityReconciliation {
                    reconciliationBanner(reconciliation)
                }
                dashboardCard
                newActivityButton
                activityReportLink
                blockList
                Spacer(minLength: 24)
            }
            .padding(.vertical)
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle("Pruning Tracker")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Always present. Never conditional on toolbar width, tool
                // customisation or a still-loading permission answer — a
                // locked state renders disabled, it does not vanish.
                Button {
                    beginNewActivity()
                } label: {
                    if createAccess == .loading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .disabled(createAccess == .loading || paddocks.isEmpty)
                .accessibilityLabel("New pruning activity")

                NavigationLink {
                    PruningActivityReportView(pruningStore: pruningStore)
                } label: {
                    Image(systemName: "tablecells")
                }
                .accessibilityLabel("Activity Report")
            }
        }
        .navigationDestination(item: $editorDraft) { draft in
            PruningActivityEditorView(
                draft: draft,
                paddocks: paddocks,
                isEditing: draft.serverAcknowledged || activities.contains { $0.id == draft.id },
                canViewCosting: accessControl.canViewCosting,
                workTasks: store.workTasks.filter { $0.vineyardId == store.selectedVineyardId },
                reconciliation: pruningSync.lastActivityReconciliation,
                onSave: { saveActivity($0) },
                onReverse: { reverseActivity(id: draft.id) },
                onCreateWorkTask: { activity, taskDraft in
                    createLinkedWorkTask(for: activity, task: taskDraft)
                }
            )
        }
        .alert("Recording locked", isPresented: $showAccessExplanation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(createAccess.explanation ?? "")
        }
        .refreshable {
            await pruningSync.syncForSelectedVineyard()
            if let vineyardId = store.selectedVineyardId {
                activities = await pruningSync.refreshActivities(vineyardId: vineyardId)
            }
        }
        .task {
            if let vineyardId = store.selectedVineyardId {
                activities = pruningStore.activities(forVineyard: vineyardId)
            }
            await pruningSync.syncForSelectedVineyard()
            if let vineyardId = store.selectedVineyardId {
                activities = await pruningSync.refreshActivities(vineyardId: vineyardId)
            }
        }
    }

    /// Visible, labelled create action — the primary way into recording, so it
    /// cannot be lost to a truncated toolbar.
    @ViewBuilder
    private var newActivityButton: some View {
        Button {
            beginNewActivity()
        } label: {
            HStack(spacing: 12) {
                if createAccess == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Pruning Activity")
                        .font(.subheadline.weight(.semibold))
                    Text(paddocks.isEmpty
                         ? "Add a block in Vineyard Setup first"
                         : "Choose a block, select the rows or quarters pruned, then record crew and hours.")
                        .font(.caption)
                        .opacity(0.85)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(createAccess.isAllowed && !paddocks.isEmpty ? .white : Color.secondary)
            .background(
                createAccess.isAllowed && !paddocks.isEmpty
                    ? AnyShapeStyle(VineyardTheme.leafGreen)
                    : AnyShapeStyle(VineyardTheme.cardBackground),
                in: .rect(cornerRadius: 14)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .disabled(createAccess == .loading || paddocks.isEmpty)
        .accessibilityLabel("New pruning activity")
    }

    /// Authorised users are told WHY recording is unavailable rather than being
    /// handed a screen with no create action and no explanation.
    private func accessNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: createAccess == .loading ? "clock.arrow.circlepath" : "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: Pending-sync warning

    private var pendingPruningChanges: Int {
        pruningSync.pendingUpsertCount + pruningSync.pendingDeleteCount
    }

    /// Progress below may include work that has NOT reached the server yet.
    /// Never hide unsynced pruning writes behind a synced-looking dashboard.
    private var pendingSyncBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                Text(pendingPruningChanges > 0 ? "Pruning changes pending sync" : "Pruning sync problem")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            if pendingPruningChanges > 0 {
                Text("\(pendingPruningChanges) recorded change\(pendingPruningChanges == 1 ? " hasn't" : "s haven't") reached the server yet. The progress below includes this device's unsynced work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = pruningSync.errorMessage, !error.isEmpty {
                Text("Last error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }
            Button {
                Task { await pruningSync.syncForSelectedVineyard() }
            } label: {
                Label("Retry sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.35), lineWidth: 0.5))
        .padding(.horizontal)
    }

    // MARK: Dashboard

    /// SHARED CONTRACT: the dashboard is `PruningCalculator.vineyardSummary`
    /// — the exact aggregation the SQL 115 RPC implements and the fixture
    /// tests verify. Never aggregate here in the view.
    private var totals: PruningVineyardSummary {
        PruningCalculator.vineyardSummary(
            blocks: blockMetrics.map { (metrics: $0.metrics, entries: pruningStore.entries(for: $0.paddock.id)) }
        )
    }

    /// Technical pruning season (calendar-year grouping used by sync) and the
    /// production/costing vintage — both shown so "Season 2026" is never
    /// mistaken for the costing vintage. Mirrors the sql/119 resolver.
    private var seasonVintageLabel: String {
        let seasonYear = PruningSeasonId.currentSeasonYear
        let vintage = VintageResolver.vintageYear(
            for: Date(),
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
        return "\(String(seasonYear)) Winter Pruning · Vintage \(String(vintage))"
    }

    private var dashboardCard: some View {
        let summary = totals
        let fraction = summary.fraction

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vineyard Progress")
                        .font(.headline)
                    Text(seasonVintageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(PruningCalculator.displayPercent(fraction))%")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .monospacedDigit()
            }

            PruningProgressBar(fraction: fraction, elapsedFraction: nil, tint: VineyardTheme.leafGreen)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                dashStat(value: "\(summary.vinesPruned.formatted())", label: "Vines pruned")
                dashStat(value: "\(summary.vinesRemaining.formatted())", label: "Vines remaining")
                dashStat(
                    value: summary.averageVinesPerElapsedDay.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—",
                    label: "Average vines / day"
                )
                dashStat(value: summary.vinesPerLabourHour.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—", label: "Vines / labour hr")
                dashStat(value: "\(summary.blocksComplete)", label: "Blocks complete")
                dashStat(value: "\(summary.blocksAtRisk)", label: "Blocks at risk")
            }

            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Self.forecastLine(summary.forecast))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
        .padding(.horizontal)
    }

    /// Vineyard-wide completion line. Identical wording and date format to the
    /// Android dashboard — never a block-specific projection, and never an
    /// arbitrary date when the data cannot support a forecast.
    static func forecastLine(_ forecast: PruningVineyardForecast) -> String {
        switch forecast.outcome {
        case .notEnoughData:
            return "Projected vineyard completion: Not enough data"
        case .completed(let date):
            return "Vineyard completed: \(forecastDateFormatter.string(from: date))"
        case .projected(let date):
            return "Projected vineyard completion: \(forecastDateFormatter.string(from: date))"
        }
    }

    private static let forecastDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    private func dashStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// Entry point to the full vineyard-wide Activity Report. The compact
    /// per-block history stays where it is for quick access.
    private var activityReportLink: some View {
        NavigationLink {
            PruningActivityReportView(pruningStore: pruningStore)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tablecells")
                    .font(.headline)
                    .foregroundStyle(VineyardTheme.leafGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity Report")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Every pruning job for this vineyard — sort, filter, search and open records.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the pruning Activity Report")
    }

    // MARK: Reconciliation

    /// The server's answer to the last activity write. A save with refused
    /// quarters is never presented as fully successful.
    private func reconciliationBanner(_ reconciliation: PruningActivityReconciliation) -> some View {
        PruningReconciliationRow(
            reconciliation: reconciliation,
            blockName: { id in paddocks.first { $0.id == id }?.name ?? "Block" },
            onOpenBlock: { paddockId in
                pruningSync.clearActivityReconciliation()
                Task {
                    guard let loaded = await pruningSync.loadActivity(id: reconciliation.activityId) else { return }
                    let name = paddocks.first { $0.id == paddockId }?.name ?? ""
                    editorDraft = PruningAllocationEditor.focus(loaded, paddockId: paddockId, blockName: name)
                }
            },
            onDismiss: { pruningSync.clearActivityReconciliation() }
        )
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (reconciliation.hasConflicts ? Color.orange : VineyardTheme.leafGreen).opacity(0.12),
            in: .rect(cornerRadius: 14)
        )
        .padding(.horizontal)
    }

    // MARK: Block list

    @ViewBuilder
    private var blockList: some View {
        if paddocks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "map")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No blocks yet")
                    .font(.headline)
                Text("Add blocks in Vineyard Setup to start tracking pruning.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
            .padding(.horizontal)
        } else {
            VStack(spacing: 12) {
                if recordedEntryCount == 0 {
                    noActivityEmptyState
                }
                blockListHeader
                ForEach(blockMetrics, id: \.paddock.id) { item in
                    NavigationLink {
                        PruningBlockDetailView(paddock: item.paddock, pruningStore: pruningStore)
                    } label: {
                        PruningBlockCard(paddock: item.paddock, metrics: item.metrics, setup: pruningStore.setup(for: item.paddock.id))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    /// Shown until the vineyard has its first pruning record — carries its own
    /// labelled create action so a brand-new vineyard is never a dead end.
    private var noActivityEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "scissors")
                .font(.title2)
                .foregroundStyle(VineyardTheme.leafGreen)
            Text("No pruning recorded yet")
                .font(.headline)
            Text("Record your first activity to start tracking vineyard progress, rates and projected completion.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                beginNewActivity()
            } label: {
                Label("Record Pruning Activity", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(VineyardTheme.leafGreen)
            .disabled(createAccess == .loading)
            if let explanation = createAccess.explanation {
                Text(explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
    }

    /// Compact "Blocks" header with the sort menu — small, no extra chrome.
    private var blockListHeader: some View {
        HStack {
            Text("Blocks")
                .font(.headline)
            Spacer()
            Menu {
                Picker("Sort blocks", selection: $blockSortRaw) {
                    ForEach(PruningBlockSort.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption2)
                    Text(blockSort.label)
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }
}

// MARK: - Block picker

/// Searchable chooser listing EVERY active block in the vineyard, used by the
/// "New Pruning Activity" action. Selecting a block hands off to the row-quarter
/// grid where the activity is recorded.
struct PruningBlockPickerSheet: View {
    let blocks: [Paddock]
    let onSelect: (Paddock) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""

    private var results: [Paddock] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return blocks }
        return blocks.filter { paddock in
            if paddock.name.localizedStandardContains(trimmed) { return true }
            return paddock.varietyAllocations.contains { ($0.name ?? "").localizedStandardContains(trimmed) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(results) { paddock in
                        Button {
                            onSelect(paddock)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(paddock.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if let variety = paddock.varietyAllocations.max(by: { $0.percent < $1.percent })?.name,
                                       !variety.isEmpty {
                                        Text(variety)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search blocks")
            .navigationTitle("Choose a block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Block card

struct PruningBlockCard: View {
    let paddock: Paddock
    let metrics: PruningBlockMetrics
    let setup: PruningBlockSetup?

    private var varietyName: String? {
        paddock.varietyAllocations
            .max { $0.percent < $1.percent }?
            .name
    }

    /// "Rows 5–28" from the block's ACTUAL row numbers (or the fallback range).
    private var rowRange: String? {
        let numbers = metrics.rows.map(\.number)
        guard let lowest = numbers.min(), let highest = numbers.max() else { return nil }
        return lowest == highest ? "Row \(lowest)" : "Rows \(lowest)–\(highest)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(paddock.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let rowRange {
                            Text(rowRange)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if let varietyName, !varietyName.isEmpty {
                        Text(varietyName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                PruningStatusChip(status: metrics.status)
            }

            if metrics.rowCount > 0 {
                PruningProgressBar(
                    fraction: metrics.fractionComplete,
                    elapsedFraction: metrics.timeElapsedFraction,
                    tint: metrics.status.tint
                )

                HStack {
                    Text("\(metrics.completedRowEquivalents.formatted(.number.precision(.fractionLength(0...2)))) of \(metrics.rowCount) row equivalents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(PruningCalculator.displayPercent(metrics.fractionComplete))%")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            } else {
                Text("Row count needed — open to set up")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 14) {
                if let due = setup?.dueDate {
                    labelledDate(icon: "flag.checkered", text: "Due \(due.formatted(date: .abbreviated, time: .omitted))")
                }
                if let projected = metrics.projectedFinish {
                    labelledDate(icon: "calendar.badge.clock", text: "Est. \(projected.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
    }

    private func labelledDate(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Shared bits

struct PruningStatusChip: View {
    let status: PruningStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.14), in: .capsule)
    }
}

/// Progress bar with an optional "time elapsed" marker so work-done vs
/// time-used is visible at a glance.
struct PruningProgressBar: View {
    let fraction: Double
    let elapsedFraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))
                Capsule()
                    .fill(tint)
                    .frame(width: max(width * min(max(fraction, 0), 1), fraction > 0 ? 8 : 0))
                if let elapsedFraction {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2)
                        .offset(x: width * min(max(elapsedFraction, 0), 1) - 1)
                }
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

extension PruningStatus {
    var tint: Color {
        switch self {
        case .notStarted: return .gray
        case .ahead: return .green
        case .onTrack: return .blue
        case .atRisk: return .orange
        case .behind: return .red
        case .complete: return VineyardTheme.leafGreen
        }
    }
}
