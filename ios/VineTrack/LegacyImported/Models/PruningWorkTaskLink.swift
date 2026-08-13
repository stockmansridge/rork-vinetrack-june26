import Foundation

/// Draft of a Work Task being created from inside the pruning activity editor.
///
/// The task belongs to the WHOLE activity: its date is the activity date, its
/// blocks are every block in the activity, and its duration is the activity's
/// shared labour hours. Nothing here is ever stored per allocation.
nonisolated struct PruningWorkTaskLinkDraft: Equatable, Identifiable, Sendable {
    /// Presentation identity only — lets the create sheet be driven by `item:`.
    let id: UUID = UUID()
    var taskType: String = PruningWorkTaskLink.defaultTaskType
    var notes: String = ""
    /// Completed tasks are the norm: the pruning already happened.
    var markCompleted: Bool = true

    // MARK: Costing (sql/188)
    //
    // The task is created COMPLETE: its costing basis is agreed HERE, in the
    // same flow, rather than left to a second edit somewhere else. `hourly` is
    // the default, so a user who ignores this section creates exactly the task
    // this flow has always created.

    var costingMethod: WorkTaskCostingMethod = .hourly

    // Hourly basis — the SAME inputs as a standard Work Task labour line, so
    // creating from pruning writes an ordinary labour line and never a
    // pruning-specific cost record.
    var operatorCategoryId: UUID?
    var workerType: String = ""
    var workerCount: Int = 1
    var hoursPerWorker: Double?
    var hourlyRate: Double?

    // Piece-rate basis — the agreed rate and the quantity it applies to.
    // `vineCount` is seeded from the activity's OWN selection, so the operator
    // confirms a number the app already derived rather than counting one.
    var ratePerVine: Double?
    var vineCount: Int = 0

    var trimmedType: String { taskType.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isPieceRate: Bool { costingMethod == .pieceRate }

    /// True when enough was entered to write a real labour line. Hourly labour
    /// stays OPTIONAL at creation: a task may legitimately be created before the
    /// crew's hours are known.
    var recordsHourlyLabour: Bool {
        workerCount > 0 && (hoursPerWorker ?? 0) > 0
    }

    /// The cost this job will be created with, under its chosen method ONLY —
    /// the two bases are never summed.
    var estimatedCost: Double? {
        if isPieceRate {
            return PieceRateCosting.cost(vineCount: vineCount, ratePerVine: ratePerVine)
        }
        guard recordsHourlyLabour else { return nil }
        return WorkTaskLabourCosting.lineCost(
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker ?? 0,
            hourlyRate: hourlyRate
        )
    }

    /// Person-hours this job will be created with. Present for BOTH methods —
    /// hours on a piece-rate job are operational history and never drive cost.
    var personHours: Double {
        WorkTaskLabourCosting.personHours(
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker ?? 0
        )
    }

    /// A task needs a work type. A PIECE-RATE task additionally needs a complete
    /// agreement, because its cost has no other source — an hourly task can be
    /// created now and costed later from its labour lines.
    var isValid: Bool {
        guard !trimmedType.isEmpty else { return false }
        guard isPieceRate else { return true }
        return PieceRateCosting.isValid(ratePerVine: ratePerVine, vineCount: vineCount)
    }
}

/// ACTIVITY-LEVEL Work Task linkage for the multi-block pruning editor
/// (sql/166) — the iOS twin of the Kotlin `PruningActivityTaskLink`. Named
/// `PruningWorkTaskLink` here because `PruningActivityTaskLink` is already the
/// Activity Report's task-link FILTER enum.
///
/// The link lives on exactly one field — `PruningActivityDraft.workTaskId` — and
/// NEVER on a `BlockPruningSelection`. Every mutation here returns a copy with
/// only that field changed, so the allocation dictionary (rows, quarters, row
/// equivalents, vines per block) is carried through untouched: creating,
/// linking, changing or unlinking a task can never disturb a block selection.
///
/// The offline rule this type also encodes: `pruning_activities.work_task_id` is
/// a real foreign key, so an activity referencing a Work Task created offline
/// must WAIT for that task to reach the server. The link is never dropped to
/// make the pruning upload succeed.
nonisolated enum PruningWorkTaskLink {
    static let defaultTaskType = "Pruning"

    /// Operator-facing reason shown while an activity is held back.
    static let waitingReason =
        "Waiting for the linked Work Task to reach the server — the pruning activity will sync straight after."

    // MARK: Draft mutations (allocation-preserving by construction)

    /// Links `taskId` to the parent activity, preserving every allocation.
    static func link(_ draft: PruningActivityDraft, taskId: UUID) -> PruningActivityDraft {
        var copy = draft
        copy.workTaskId = taskId
        return copy
    }

    /// Removes the link. The activity, its labour and every block allocation
    /// stay exactly as they are — `update_pruning_activity` receives
    /// `clear_work_task = true` and clears only the parent's column.
    static func unlink(_ draft: PruningActivityDraft) -> PruningActivityDraft {
        var copy = draft
        copy.workTaskId = nil
        return copy
    }

    /// The linked task, when this device has it cached.
    static func linkedTask(_ draft: PruningActivityDraft, tasks: [WorkTask]) -> WorkTask? {
        guard let id = draft.workTaskId else { return nil }
        return tasks.first { $0.id == id }
    }

    /// True when the draft references a task this device cannot resolve — one
    /// created on another device and not pulled yet, or one that was deleted.
    /// Surfaced as a warning; never auto-cleared.
    static func hasUnresolvableLink(_ draft: PruningActivityDraft, tasks: [WorkTask]) -> Bool {
        draft.workTaskId != nil && linkedTask(draft, tasks: tasks) == nil
    }

    // MARK: Existing-task picker

    /// Searchable, newest-first candidates for linking. Matches the work type,
    /// the block snapshot, the notes or the date, so the operator can find the
    /// task by whatever they remember about it. Archived tasks are never offered.
    static func search(_ tasks: [WorkTask], query: String) -> [WorkTask] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks
            .filter { !$0.isArchived }
            .filter { task in
                guard !needle.isEmpty else { return true }
                if task.taskType.localizedStandardContains(needle) { return true }
                if task.paddockName.localizedStandardContains(needle) { return true }
                if task.notes.localizedStandardContains(needle) { return true }
                return dateKey(task.date).localizedStandardContains(needle)
            }
            .sorted { $0.date > $1.date }
    }

    /// One-line description of a linkable task: work type · block · date.
    static func label(_ task: WorkTask) -> String {
        let type = task.taskType.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            type.isEmpty ? "Work task" : type,
            task.paddockName.isEmpty ? nil : task.paddockName,
            dateKey(task.date)
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    // MARK: Creating a task for the activity

    /// Seeds the create form from the activity itself, so the operator normally
    /// only has to confirm. The notes carry the block summary, so the Work Task
    /// records WHICH blocks the shared labour covered.
    /// The piece-rate quantity is seeded from the activity's OWN vine total —
    /// the same `499 vines` the Activity Summary shows — so choosing Piece Rate
    /// never asks the operator to re-enter a quantity the app already derived
    /// from the selected quarters.
    static func createDraft(_ draft: PruningActivityDraft) -> PruningWorkTaskLinkDraft {
        PruningWorkTaskLinkDraft(
            taskType: defaultTaskType,
            notes: composedNotes(draft),
            hoursPerWorker: draft.labourHours.flatMap { $0 > 0 ? $0 : nil },
            vineCount: vineCount(draft)
        )
    }

    /// THE piece-rate quantity for an activity: exactly the vine total the
    /// Activity Summary displays.
    ///
    /// Quarter-aware by construction — each allocation's `estimatedVines` was
    /// derived from its SELECTED QUARTERS through
    /// `PruningCalculator.vines(for:rows:)`, so selecting 8 quarters across 2
    /// rows prices 8 quarters, never 2 whole rows.
    static func vineCount(_ draft: PruningActivityDraft) -> Int {
        draft.totalEstimatedVines
    }

    /// Rounds a vine quantity half away from zero — the same rule the per-row
    /// vine-count calculation uses, so no platform reports a vine another does
    /// not.
    static func roundVines(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let magnitude = Int((abs(value) + 0.5).rounded(.down))
        return value < 0 ? -magnitude : magnitude
    }

    /// Builds the HISTORICAL per-row snapshot behind a piece-rate job
    /// (sql/188) from the quarters actually selected in each block.
    ///
    /// A row with 2 of its 4 quarters selected contributes HALF its vines, so
    /// the breakdown matches what was really pruned. These rows are supporting
    /// audit detail: the authoritative priced quantity is the task's own
    /// `piece_vine_count`, which is why per-row rounding here may differ from
    /// the total by a vine or two without changing what anyone is paid.
    ///
    /// - Parameter rowsByPaddock: each block's rows, already resolved through
    ///   `PruningCalculator.rowRefs` so the grid, the vine estimate and this
    ///   snapshot all agree.
    static func pieceRateRows(
        activity: PruningActivityDraft,
        workTaskId: UUID,
        vineyardId: UUID,
        rowsByPaddock: [UUID: [PruningRowRef]]
    ) -> [WorkTaskPieceRateRow] {
        var snapshot: [WorkTaskPieceRateRow] = []
        for allocation in activity.activeAllocations {
            guard let rows = rowsByPaddock[allocation.paddockId] else { continue }
            var quartersByRowKey: [String: Int] = [:]
            for segment in allocation.segments {
                quartersByRowKey[segment.rowKey, default: 0] += 1
            }
            for row in rows {
                guard let quarters = quartersByRowKey[row.id], quarters > 0 else { continue }
                snapshot.append(WorkTaskPieceRateRow(
                    workTaskId: workTaskId,
                    vineyardId: vineyardId,
                    paddockId: allocation.paddockId,
                    paddockRowId: row.rowId,
                    rowNumber: row.number,
                    vineCount: roundVines(row.vines * Double(quarters) / 4.0)
                ))
            }
        }
        return snapshot
    }

    static func composedNotes(_ draft: PruningActivityDraft) -> String {
        let blocks = draft.blockSummary.isEmpty ? nil : draft.blockSummary
        let quarters = "\(draft.totalQuarters) quarters (\(trimmed(draft.totalRowEquivalents)) row equivalents)"
        let head = [blocks, quarters].compactMap { $0 }.joined(separator: " — ")
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? head : head + "\n" + notes
    }

    /// Duration for the created task = the activity's SHARED labour hours,
    /// counted once for the whole job and never apportioned per block.
    static func durationHours(_ draft: PruningActivityDraft) -> Double {
        draft.labourHours ?? 0
    }

    /// Every block in the activity — the task spans them all.
    static func paddockIds(_ draft: PruningActivityDraft) -> [UUID] {
        let active = draft.activeAllocations.map(\.paddockId)
        if !active.isEmpty { return active }
        return draft.allocations.keys.sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: Offline dependency

    /// Whether an activity write must wait. The pruning activity is held back —
    /// with its `work_task_id` intact — until the linked task lands.
    static func isWaitingForTask(_ workTaskId: UUID?, isTaskPending: (UUID) -> Bool) -> Bool {
        guard let workTaskId else { return false }
        return isTaskPending(workTaskId)
    }

    static func isWaitingForTask(_ workTaskId: UUID?, unresolvedTaskIds: Set<UUID>) -> Bool {
        isWaitingForTask(workTaskId) { unresolvedTaskIds.contains($0) }
    }

    // MARK: Helpers

    private static func dateKey(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private static func trimmed(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
