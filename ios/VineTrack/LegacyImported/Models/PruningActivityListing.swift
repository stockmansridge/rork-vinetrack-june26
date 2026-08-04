import Foundation

/// How a multi-block pruning activity is PRESENTED in a list — one row per
/// parent activity, never one row per block.
///
/// Pure and byte-identical to the Kotlin `PruningActivityListing`, so the
/// Tracker history, the mobile Activity Report and the editor summary can never
/// label the same activity differently.
nonisolated enum PruningActivityListing {

    /// The compact block label of one activity:
    /// * one block  → "Cab Franc"
    /// * two blocks → "Cab Franc + Sauv Blanc"
    /// * three+     → "Cab Franc + Sauv Blanc +2 more"
    static func blockLabel(_ names: [String]) -> String {
        var seen = Set<String>()
        var clean: [String] = []
        for raw in names {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Block" : trimmed
            if seen.insert(name).inserted { clean.append(name) }
        }
        if clean.isEmpty { return "No blocks" }
        if clean.count <= 2 { return clean.joined(separator: " + ") }
        return clean.prefix(2).joined(separator: " + ") + " +\(clean.count - 2) more"
    }

    /// True when a free-text search matches the activity: ANY allocation
    /// matching is a match for the whole parent record.
    static func matches(
        query: String,
        blockNames: [String],
        worker: String,
        notes: String,
        rowLabels: [String]
    ) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = (blockNames + [worker, notes] + rowLabels).joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(needle)
    }

    /// "42–44, 66–67" — contiguous runs of the rows an allocation covered.
    static func rowRangeLabel(_ rows: [Int]) -> String {
        let sorted = Array(Set(rows)).sorted()
        guard let first = sorted.first else { return "—" }
        var parts: [String] = []
        var start = first
        var previous = first
        for row in sorted.dropFirst() {
            if row == previous + 1 {
                previous = row
                continue
            }
            parts.append(start == previous ? "\(start)" : "\(start)–\(previous)")
            start = row
            previous = row
        }
        parts.append(start == previous ? "\(start)" : "\(start)–\(previous)")
        return parts.joined(separator: ", ")
    }
}

/// One quarter a write could not attribute, with the block it belongs to.
nonisolated struct PruningQuarterConflict: Identifiable, Sendable, Hashable {
    let paddockId: UUID?
    var blockName: String = ""
    var row: Int?
    var quarter: Int?
    var reason: String?

    var id: String { "\(paddockId?.uuidString ?? "-")|\(row ?? -1)|\(quarter ?? -1)" }

    var label: String {
        "Row \(row.map(String.init) ?? "?") · q\(quarter.map(String.init) ?? "?")"
    }
}

/// The reconciliation result of ONE activity write (sql/166). A save is never
/// reported as fully successful while conflicts exist: the user is told exactly
/// how many quarters landed, how many were already recorded elsewhere, and which
/// blocks to open to review them.
nonisolated struct PruningActivityReconciliation: Identifiable, Sendable, Equatable {
    let activityId: UUID
    var blockSummary: String = ""
    var quartersRequested: Int = 0
    var quartersRecorded: Int = 0
    var conflicts: [PruningQuarterConflict] = []
    var seasonYear: Int?
    var vintageYear: Int?
    var workTaskConflict: Bool = false
    var isReversal: Bool = false
    var quartersReleased: Int = 0
    var isStale: Bool = false
    var error: String?

    var id: UUID { activityId }

    var quartersConflicted: Int { conflicts.count }

    var hasConflicts: Bool { !conflicts.isEmpty }

    /// Blocks the user can open to review refused quarters.
    var conflictBlockIds: [UUID] {
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for conflict in conflicts {
            guard let id = conflict.paddockId else { continue }
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    func conflicts(in paddockId: UUID) -> [PruningQuarterConflict] {
        conflicts.filter { $0.paddockId == paddockId }
    }

    /// Only a clean, acknowledged write counts as fully synced.
    var isFullySynced: Bool { error == nil && !isStale && !hasConflicts }

    var headline: String {
        if error != nil { return "Activity not saved yet" }
        if isReversal { return "Activity reversed" }
        if hasConflicts { return "Activity saved with conflicts" }
        return "Activity saved"
    }

    var detail: String {
        if error != nil {
            return "Queued — the server hasn't confirmed this activity yet. It will retry automatically."
        }
        if isReversal {
            return "\(quartersReleased) \(Self.quarterWord(quartersReleased)) reopened across \(blockSummary)."
        }
        var parts = ["\(quartersRecorded) \(Self.quarterWord(quartersRecorded)) recorded"]
        if hasConflicts {
            var seen = Set<String>()
            var blocks: [String] = []
            for conflict in conflicts {
                let name = conflict.blockName.isEmpty ? "another block" : conflict.blockName
                if seen.insert(name).inserted { blocks.append(name) }
            }
            parts.append(
                "\(quartersConflicted) \(Self.quarterWord(quartersConflicted)) were already recorded elsewhere (\(blocks.joined(separator: ", ")))"
            )
        }
        if workTaskConflict { parts.append("the Work Task link is already used by another activity") }
        return parts.joined(separator: " · ") + "."
    }

    private static func quarterWord(_ count: Int) -> String {
        count == 1 ? "quarter" : "quarters"
    }

    /// Maps the raw sql/166 response onto what the UI shows. `attributed` is what
    /// actually landed; `conflicts` are quarters another record already owns
    /// (never stolen).
    static func from(
        _ result: PruningActivityResult,
        blockNames: [UUID: String] = [:],
        blockSummary: String = "",
        activityId: UUID,
        isReversal: Bool = false
    ) -> PruningActivityReconciliation {
        let allocationResults = result.allocationResults ?? []
        let allocationConflicts = allocationResults.flatMap { $0.conflicts ?? [] }
        let raw = (result.conflicts?.isEmpty == false) ? (result.conflicts ?? []) : allocationConflicts
        let conflicts = raw.map { conflict in
            PruningQuarterConflict(
                paddockId: conflict.paddockId,
                blockName: conflict.paddockId.flatMap { blockNames[$0] } ?? "",
                row: conflict.row,
                quarter: conflict.segment,
                reason: conflict.reason
            )
        }
        let totals = result.canonical?.totals
        let summary: String = {
            guard let canonical = totals?.blockSummary, !canonical.isEmpty else { return blockSummary }
            return canonical
        }()
        return PruningActivityReconciliation(
            activityId: result.activityId ?? activityId,
            blockSummary: summary,
            quartersRequested: allocationResults.reduce(0) { $0 + ($1.requested ?? 0) },
            quartersRecorded: totals?.quarters ?? allocationResults.reduce(0) { $0 + ($1.attributed ?? 0) },
            conflicts: conflicts,
            seasonYear: result.canonical?.activity?.seasonYear,
            vintageYear: result.canonical?.activity?.vintageYear,
            workTaskConflict: result.workTaskConflict ?? false,
            isReversal: isReversal || (result.reversed ?? false),
            quartersReleased: result.quartersReleased ?? 0,
            isStale: result.stale ?? false,
            error: result.error
        )
    }
}
