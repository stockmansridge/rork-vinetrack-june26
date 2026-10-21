import Foundation

/// Values prepared for one Pruning block view evaluation. This is not a
/// persisted cache or an authority for selecting, recording or reversing work.
nonisolated struct PruningBlockPresentation: Sendable {
    let setup: PruningBlockSetup?
    let entries: [PruningEntry]
    let metrics: PruningBlockMetrics
    let lockedSegments: Set<PruningSegment>
    let completionDates: [PruningSegment: Date]

    /// `entries` is the current block's active, ordered selection from
    /// PruningStore. Keep that selection at the caller so the view observes
    /// the store's existing entry/setup dependencies on every evaluation.
    static func prepare(
        paddock: Paddock,
        setup: PruningBlockSetup?,
        entries: [PruningEntry],
        editingEntry: PruningEntry?,
        calendar: Calendar = .current,
        asOf: Date = Date()
    ) -> PruningBlockPresentation {
        let metrics = PruningCalculator.metrics(
            paddock: paddock,
            setup: setup,
            entries: entries,
            calendar: calendar,
            asOf: asOf
        )
        return PruningBlockPresentation(
            setup: setup,
            entries: entries,
            metrics: metrics,
            lockedSegments: lockedSegments(
                completed: metrics.completed,
                editingEntry: editingEntry,
                rows: metrics.rows
            ),
            completionDates: PruningCalculator.segmentCompletionDates(
                entries: entries,
                rows: metrics.rows
            )
        )
    }

    /// Share the existing edit-unlocking rule with the view's live action
    /// getters. Callers performing an action supply their current rows and
    /// completed set, rather than reusing an earlier presentation value.
    static func lockedSegments(
        completed: Set<PruningSegment>,
        editingEntry: PruningEntry?,
        rows: [PruningRowRef]
    ) -> Set<PruningSegment> {
        guard let editingEntry else { return completed }
        let editingSegments = PruningCalculator.completedSegments(entries: [editingEntry], rows: rows)
        return completed.subtracting(editingSegments)
    }
}
