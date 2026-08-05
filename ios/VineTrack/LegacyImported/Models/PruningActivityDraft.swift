import CryptoKit
import Foundation

/// MULTI-BLOCK PRUNING ACTIVITIES (sql/166) — the iOS twin of the backend
/// contract and of the Kotlin `PruningActivityDraft`.
///
/// A pruning activity is ONE piece of work: one crew, one date, one start and
/// finish time, one set of labour hours, one rate, one note, one linked Work
/// Task. It may cover ONE OR MANY blocks. The split is strict:
///
/// * ACTIVITY level (`PruningActivityDraft`) — vineyard, date, worker/crew,
///   method, start/finish, duration, labour hours, hourly rate, notes, linked
///   Work Task, creator, reversal state and sync identity.
/// * ALLOCATION level (`BlockPruningSelection`) — block, season, rows,
///   quarters, row equivalents and vines.
///
/// Labour and timing exist EXACTLY ONCE on the parent and are never apportioned
/// or duplicated across blocks — not in the editor, not in the payload, not in
/// the offline draft.

/// Deterministic allocation ids, byte-identical to `derive_pruning_allocation_id`
/// (sql/166 §3) and to the Kotlin `PruningAllocationIds.make`.
nonisolated enum PruningAllocationId {
    static func make(activityId: UUID, paddockId: UUID) -> UUID {
        let name = "vinetrack-pruning-allocation|\(activityId.uuidString.lowercased())|\(paddockId.uuidString.lowercased())"
        var bytes = Array(Insecure.MD5.hash(data: Data(name.utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// One block's contribution to an activity. Retains rows, quarters, row
/// equivalents and vines for THAT block only — never labour.
nonisolated struct BlockPruningSelection: Codable, Identifiable, Sendable, Hashable {
    var paddockId: UUID
    /// Stable allocation id; derived from (activity, block) when nil.
    var allocationId: UUID?
    var blockName: String
    /// The selected quarters — the canonical rows/quarters representation.
    var segments: [PruningSegment]
    /// Client vine estimate for this block; the server re-attributes on sync.
    var estimatedVines: Int
    /// Season the SERVER filed this allocation under (nil until acknowledged).
    var serverSeasonId: UUID?
    var serverSeasonYear: Int?

    var id: UUID { paddockId }

    init(
        paddockId: UUID,
        allocationId: UUID? = nil,
        blockName: String = "",
        segments: [PruningSegment] = [],
        estimatedVines: Int = 0,
        serverSeasonId: UUID? = nil,
        serverSeasonYear: Int? = nil
    ) {
        self.paddockId = paddockId
        self.allocationId = allocationId
        self.blockName = blockName
        self.segments = segments
        self.estimatedVines = estimatedVines
        self.serverSeasonId = serverSeasonId
        self.serverSeasonYear = serverSeasonYear
    }

    /// Distinct row numbers touched, ascending.
    var rows: [Int] { Array(Set(segments.map(\.row))).sorted() }

    /// Quarters selected in this block.
    var quarters: Int { segments.count }

    /// A full row = 1.0, each quarter = 0.25.
    var rowEquivalents: Double { Double(segments.count) / 4.0 }

    var isEmpty: Bool { segments.isEmpty }

    /// Toggles one quarter, preserving every other selection in this block.
    func toggling(_ segment: PruningSegment) -> BlockPruningSelection {
        var copy = self
        if let index = segments.firstIndex(of: segment) {
            copy.segments.remove(at: index)
        } else {
            copy.segments.append(segment)
        }
        return copy
    }

    func allocationId(for activityId: UUID) -> UUID {
        allocationId ?? PruningAllocationId.make(activityId: activityId, paddockId: paddockId)
    }
}

/// The editor's working state — a real parent activity plus a DICTIONARY of
/// block allocations keyed by block id. Switching blocks changes which
/// allocation the UI is editing; it never clears the others.
nonisolated struct PruningActivityDraft: Codable, Identifiable, Sendable, Hashable {
    /// Stable client-generated activity id — the idempotency key for retries.
    let id: UUID
    var vineyardId: UUID
    /// The season of EVERY allocation derives from this date.
    var date: Date
    var worker: String
    var method: PruningMethod
    var startTime: Date?
    var finishTime: Date?
    /// ACTIVITY-level labour. Never split across blocks.
    var labourHours: Double?
    var hourlyRate: Double?
    var notes: String
    var workTaskId: UUID?
    /// Every block allocation, keyed by block id.
    var allocations: [UUID: BlockPruningSelection]
    /// The block currently open in the editor (UI focus only).
    var focusedPaddockId: UUID?
    var createdAt: Date
    var updatedAt: Date?
    var enteredBy: UUID?
    var reversedAt: Date?
    /// Set once the server has acknowledged this activity (sql/166 response).
    var serverAcknowledged: Bool
    var serverSeasonYear: Int?
    var vintageYear: Int?
    /// Server roll-up of the activity's completed quarters, taken from the
    /// canonical `totals` block of ANY response — summary or detailed. Held so
    /// the cache can tell "this activity really has no quarters" apart from
    /// "this device has not been given the quarter detail yet".
    var serverQuarters: Int?
    /// Server roll-up of the activity's allocation count, same purpose.
    var serverAllocationCount: Int?

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        date: Date = Date(),
        worker: String = "",
        method: PruningMethod = .spur,
        startTime: Date? = nil,
        finishTime: Date? = nil,
        labourHours: Double? = nil,
        hourlyRate: Double? = nil,
        notes: String = "",
        workTaskId: UUID? = nil,
        allocations: [UUID: BlockPruningSelection] = [:],
        focusedPaddockId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        enteredBy: UUID? = nil,
        reversedAt: Date? = nil,
        serverAcknowledged: Bool = false,
        serverSeasonYear: Int? = nil,
        vintageYear: Int? = nil,
        serverQuarters: Int? = nil,
        serverAllocationCount: Int? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.date = date
        self.worker = worker
        self.method = method
        self.startTime = startTime
        self.finishTime = finishTime
        self.labourHours = labourHours
        self.hourlyRate = hourlyRate
        self.notes = notes
        self.workTaskId = workTaskId
        self.allocations = allocations
        self.focusedPaddockId = focusedPaddockId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.enteredBy = enteredBy
        self.reversedAt = reversedAt
        self.serverAcknowledged = serverAcknowledged
        self.serverSeasonYear = serverSeasonYear
        self.vintageYear = vintageYear
        self.serverQuarters = serverQuarters
        self.serverAllocationCount = serverAllocationCount
    }

    var isReversed: Bool { reversedAt != nil }

    /// True when the server's own roll-up says this activity holds more blocks
    /// or more completed quarters than this device can account for — i.e. the
    /// local copy is HOLLOW and must be repaired from `get_pruning_activity`
    /// before it is trusted for progress or shown as a breakdown.
    ///
    /// Reversed activities are excluded: the server releases their quarters and
    /// drops their allocations, so a roll-up above the local count is expected.
    var needsCanonicalDetail: Bool {
        guard !isReversed else { return false }
        if let count = serverAllocationCount, count > blockCount { return true }
        if let quarters = serverQuarters, quarters > totalQuarters { return true }
        return false
    }

    /// Allocations that actually contribute work, in stable block order.
    var activeAllocations: [BlockPruningSelection] {
        allocations.values
            .filter { !$0.isEmpty }
            .sorted { $0.paddockId.uuidString < $1.paddockId.uuidString }
    }

    var blockCount: Int { activeAllocations.count }

    var totalQuarters: Int { activeAllocations.reduce(0) { $0 + $1.quarters } }

    var totalRowEquivalents: Double { Double(totalQuarters) / 4.0 }

    var totalEstimatedVines: Int { activeAllocations.reduce(0) { $0 + $1.estimatedVines } }

    /// "Cab Franc + Sauvignon Blanc" — the parent record's block summary.
    var blockSummary: String {
        var seen = Set<String>()
        var names: [String] = []
        for allocation in activeAllocations {
            let name = allocation.blockName.isEmpty ? "Block" : allocation.blockName
            if seen.insert(name).inserted { names.append(name) }
        }
        return names.joined(separator: " + ")
    }

    /// Person-hours span between the recorded start and finish times.
    var durationHours: Double? {
        guard let startTime, let finishTime else { return nil }
        let seconds = finishTime.timeIntervalSince(startTime)
        guard seconds > 0 else { return nil }
        return seconds / 3_600
    }

    /// Labour cost of the WHOLE activity — counted once, never per block.
    var labourCost: Double? {
        guard let labourHours, let hourlyRate else { return nil }
        return labourHours * hourlyRate
    }

    /// The canonical pruning season year of every allocation (sql/161).
    var seasonYear: Int { PruningSeasonId.seasonYear(for: date) }

    /// A saveable activity needs at least one block with at least one quarter.
    var canSave: Bool { !activeAllocations.isEmpty }

    /// Opens an EXISTING single-block entry as an activity with exactly one
    /// allocation. Nothing is recomputed: the date, worker, method, times,
    /// labour, notes, task link, vines and reversal state come straight from the
    /// stored record, and the entry's own id becomes the activity id — exactly
    /// how sql/166 back-fills history.
    static func fromLegacyEntry(_ entry: PruningEntry, blockName: String = "") -> PruningActivityDraft {
        PruningActivityDraft(
            id: entry.id,
            vineyardId: entry.vineyardId,
            date: entry.date,
            worker: entry.worker,
            method: entry.method,
            startTime: entry.startTime,
            finishTime: entry.finishTime,
            labourHours: entry.labourHours,
            hourlyRate: nil,
            notes: entry.notes,
            workTaskId: entry.workTaskId,
            allocations: [
                entry.paddockId: BlockPruningSelection(
                    paddockId: entry.paddockId,
                    allocationId: entry.id,
                    blockName: blockName,
                    segments: entry.segments,
                    estimatedVines: entry.estimatedVines,
                    serverSeasonId: entry.seasonId,
                    serverSeasonYear: entry.updatedAt == nil ? nil : PruningSeasonId.seasonYear(for: entry.date)
                )
            ],
            focusedPaddockId: entry.paddockId,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            enteredBy: entry.enteredBy,
            reversedAt: entry.reversedAt,
            serverAcknowledged: entry.updatedAt != nil,
            serverSeasonYear: entry.updatedAt == nil ? nil : PruningSeasonId.seasonYear(for: entry.date)
        )
    }
}

/// How much of a canonical response may be adopted.
///
/// `pruning_activity_json` serves the same envelope in two fidelities, and the
/// cache MUST treat them differently: a summary feed is allowed to refresh
/// parent metadata and the allocation set, but only a detailed record may
/// rewrite completed quarters. Anything else lets a lightweight list refresh
/// silently erase the progress a detailed record established.
nonisolated enum PruningCanonicalScope: Sendable, Equatable {
    /// `get_pruning_activity`, or a create / update / reverse response — every
    /// allocation carried its quarters, so this is authoritative for progress.
    case detailed
    /// `list_pruning_activities` — quarters withheld. Parent metadata and the
    /// allocation set only.
    case summary

    init(_ canonical: BackendPruningActivityCanonical) {
        self = canonical.hasSegmentDetail ? .detailed : .summary
    }

    /// Only a detailed record may replace an allocation's or an entry's quarters.
    var replacesSegments: Bool { self == .detailed }
}

/// The multi-block editor engine — pure, testable, and the ONLY place the
/// allocation dictionary changes.
///
/// Invariants it guarantees:
/// * selecting or deselecting quarters in one block never touches another,
/// * switching the focused block preserves every earlier selection,
/// * removing a block removes only its allocation,
/// * labour, timing, rate and notes live on the parent and are untouched by
///   every allocation operation.
nonisolated enum PruningAllocationEditor {

    /// Focuses `paddockId`, creating an EMPTY allocation if it has none yet.
    static func focus(
        _ draft: PruningActivityDraft,
        paddockId: UUID,
        blockName: String = ""
    ) -> PruningActivityDraft {
        var copy = draft
        if var existing = copy.allocations[paddockId] {
            if !blockName.isEmpty, existing.blockName != blockName {
                existing.blockName = blockName
                copy.allocations[paddockId] = existing
            }
        } else {
            copy.allocations[paddockId] = BlockPruningSelection(paddockId: paddockId, blockName: blockName)
        }
        copy.focusedPaddockId = paddockId
        return copy
    }

    /// Toggles one quarter of one block. Every other block is preserved verbatim.
    static func toggleSegment(
        _ draft: PruningActivityDraft,
        paddockId: UUID,
        segment: PruningSegment,
        blockName: String = ""
    ) -> PruningActivityDraft {
        var copy = focus(draft, paddockId: paddockId, blockName: blockName)
        if let current = copy.allocations[paddockId] {
            copy.allocations[paddockId] = current.toggling(segment)
        }
        return copy
    }

    /// Replaces one block's whole quarter set (e.g. "select all rows").
    static func setSegments(
        _ draft: PruningActivityDraft,
        paddockId: UUID,
        segments: [PruningSegment],
        blockName: String = ""
    ) -> PruningActivityDraft {
        var copy = focus(draft, paddockId: paddockId, blockName: blockName)
        if var current = copy.allocations[paddockId] {
            var unique: [PruningSegment] = []
            var seen = Set<PruningSegment>()
            for segment in segments where seen.insert(segment).inserted {
                unique.append(segment)
            }
            current.segments = unique
            copy.allocations[paddockId] = current
        }
        return copy
    }

    /// Stores this block's own vine estimate. Never an activity-level value.
    static func setEstimatedVines(
        _ draft: PruningActivityDraft,
        paddockId: UUID,
        vines: Int
    ) -> PruningActivityDraft {
        guard var current = draft.allocations[paddockId] else { return draft }
        var copy = draft
        current.estimatedVines = vines
        copy.allocations[paddockId] = current
        return copy
    }

    /// Removes ONE block. The activity and every other allocation survive.
    static func removeBlock(_ draft: PruningActivityDraft, paddockId: UUID) -> PruningActivityDraft {
        var copy = draft
        copy.allocations.removeValue(forKey: paddockId)
        if copy.focusedPaddockId == paddockId {
            copy.focusedPaddockId = copy.allocations.values
                .sorted { $0.paddockId.uuidString < $1.paddockId.uuidString }
                .first?
                .paddockId
        }
        return copy
    }

    /// Drops blocks the user opened but never selected anything in.
    static func pruneEmptyBlocks(_ draft: PruningActivityDraft) -> PruningActivityDraft {
        var copy = draft
        copy.allocations = draft.allocations.filter { !$0.value.isEmpty }
        if let focus = copy.focusedPaddockId, copy.allocations[focus] != nil {
            return copy
        }
        copy.focusedPaddockId = copy.allocations.values
            .sorted { $0.paddockId.uuidString < $1.paddockId.uuidString }
            .first?
            .paddockId
        return copy
    }

    /// Adopts the CANONICAL server state (sql/166 response): the activity
    /// fields, the allocation SET, each allocation's canonical season and the
    /// vintage.
    ///
    /// The allocation SET is always authoritative — `pruning_activity_json`
    /// lists every live allocation whether or not it includes their quarters, so
    /// a block genuinely removed server-side disappears here.
    ///
    /// The per-quarter SEGMENTS are only replaced when the response actually
    /// supplied them (`get_pruning_activity`, create, update). When a summary
    /// feed withholds them (`list_pruning_activities`), the existing quarters
    /// are PRESERVED in this priority order:
    ///
    ///   1. the canonical segments, when supplied,
    ///   2. the segments already on this local allocation,
    ///   3. `knownSegments` — the legacy projected entry for the same allocation
    ///      id, which carries the server's own `pruning_row_segments`
    ///      attribution and lets a reinstalled device rehydrate without a
    ///      network round trip.
    ///
    /// Treating a withheld `segments` array as an empty one is what emptied the
    /// allocation set, hollowed out the legacy projection and collapsed block
    /// and vineyard progress on every pull.
    static func adoptCanonical(
        _ draft: PruningActivityDraft,
        canonical: BackendPruningActivityCanonical,
        knownSegments: [UUID: [PruningSegment]] = [:]
    ) -> PruningActivityDraft {
        guard let activity = canonical.activity else { return draft }
        var copy = draft
        let knownNames = draft.allocations.mapValues(\.blockName)

        var adopted: [UUID: BlockPruningSelection] = [:]
        for allocation in canonical.allocations {
            let segments: [PruningSegment]
            if let supplied = allocation.segments {
                segments = supplied.map {
                    PruningSegment(rowId: $0.rowId, row: $0.row, quarter: $0.segment)
                }
            } else {
                let local = draft.allocations[allocation.paddockId]?.segments ?? []
                segments = local.isEmpty ? (knownSegments[allocation.id] ?? []) : local
            }
            adopted[allocation.paddockId] = BlockPruningSelection(
                paddockId: allocation.paddockId,
                allocationId: allocation.id,
                blockName: allocation.blockName.isEmpty
                    ? (knownNames[allocation.paddockId] ?? "")
                    : allocation.blockName,
                segments: segments,
                estimatedVines: allocation.estimatedVines,
                serverSeasonId: allocation.pruningSeasonId,
                serverSeasonYear: allocation.seasonYear
            )
        }

        copy.date = PruningSyncDate.date(fromYmd: activity.entryDate) ?? draft.date
        copy.worker = activity.workerOrCrew ?? draft.worker
        copy.method = PruningMethod(rawValue: activity.method ?? "") ?? draft.method
        copy.labourHours = activity.labourHours
        copy.hourlyRate = activity.hourlyRate
        copy.notes = activity.notes ?? draft.notes
        copy.workTaskId = activity.workTaskId
        copy.allocations = adopted
        copy.reversedAt = (activity.isReversed ?? false) ? (draft.reversedAt ?? Date()) : nil
        copy.serverAcknowledged = true
        copy.serverSeasonYear = activity.seasonYear
        copy.vintageYear = activity.vintageYear
        // Server roll-ups ride along on BOTH shapes, so a summary refresh still
        // teaches the cache how much detail it is missing.
        copy.serverQuarters = canonical.totals?.quarters ?? copy.serverQuarters
        copy.serverAllocationCount = canonical.totals?.allocationCount ?? copy.serverAllocationCount
        if let focus = copy.focusedPaddockId, adopted[focus] != nil {
            return copy
        }
        copy.focusedPaddockId = adopted.values
            .sorted { $0.paddockId.uuidString < $1.paddockId.uuidString }
            .first?
            .paddockId
        return copy
    }

    /// Projects a draft onto the LEGACY per-block entries so every existing
    /// screen, report, forecast and progress calculation keeps working while the
    /// activity model rolls out.
    ///
    /// Labour and timing are carried by the PRIMARY allocation only (the lowest
    /// block id, matching the server's `allocation_index = 0` mirror), so any
    /// legacy sum of `labourHours` still counts the activity's hours once.
    static func toLegacyEntries(_ draft: PruningActivityDraft) -> [PruningEntry] {
        let active = draft.activeAllocations
        let primary = active.first?.paddockId
        return active.enumerated().map { index, allocation in
            let isPrimary = allocation.paddockId == primary
            return PruningEntry(
                id: allocation.allocationId(for: draft.id),
                vineyardId: draft.vineyardId,
                paddockId: allocation.paddockId,
                seasonId: allocation.serverSeasonId ?? PruningSeasonId.make(
                    vineyardId: draft.vineyardId,
                    paddockId: allocation.paddockId,
                    date: draft.date
                ),
                date: draft.date,
                segments: allocation.segments,
                worker: draft.worker,
                labourHours: isPrimary ? draft.labourHours : nil,
                startTime: isPrimary ? draft.startTime : nil,
                finishTime: isPrimary ? draft.finishTime : nil,
                method: draft.method,
                notes: draft.notes,
                estimatedVines: allocation.estimatedVines,
                workTaskId: isPrimary ? draft.workTaskId : nil,
                createdAt: draft.createdAt,
                updatedAt: draft.updatedAt,
                enteredBy: draft.enteredBy,
                reversedAt: draft.reversedAt,
                pruningActivityId: draft.id,
                allocationIndex: index
            )
        }
    }
}
