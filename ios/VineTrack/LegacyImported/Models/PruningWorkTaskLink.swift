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

    var trimmedType: String { taskType.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A task needs a work type; everything else is optional.
    var isValid: Bool { !trimmedType.isEmpty }
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
    static func createDraft(_ draft: PruningActivityDraft) -> PruningWorkTaskLinkDraft {
        PruningWorkTaskLinkDraft(taskType: defaultTaskType, notes: composedNotes(draft))
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
