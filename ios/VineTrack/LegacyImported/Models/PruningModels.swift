import CryptoKit
import Foundation

/// Deterministic ids + season helpers shared with the Android app so two
/// devices that configure the same block independently converge on the SAME
/// `pruning_seasons` row instead of colliding on the unique
/// (vineyard, paddock, season_year) index.
nonisolated enum PruningSeasonId {
    /// Matches Java's `UUID.nameUUIDFromBytes` (MD5, version 3) so Kotlin and
    /// Swift generate identical ids from the same name string.
    static func make(vineyardId: UUID, paddockId: UUID, seasonYear: Int) -> UUID {
        let name = "vinetrack-pruning-season|\(vineyardId.uuidString.lowercased())|\(paddockId.uuidString.lowercased())|\(seasonYear)"
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

    /// CANONICAL RULE (shared with Android and enforced by sql/161):
    /// the pruning season year is the CALENDAR YEAR IN WHICH THE WINTER
    /// PRUNING HAPPENED — the year of the entry's own date, never the
    /// vintage, and never the device's clock at sync time.
    /// Work on 2 Aug 2026 → season 2026 (vintage 2027).
    static func seasonYear(for date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.year, from: date)
    }

    /// Deterministic season id for the season that OWNS `date`.
    static func make(vineyardId: UUID, paddockId: UUID, date: Date, calendar: Calendar = .current) -> UUID {
        make(vineyardId: vineyardId, paddockId: paddockId, seasonYear: seasonYear(for: date, calendar: calendar))
    }

    /// The season year a NEW block setup defaults to — today's pruning year.
    static var currentSeasonYear: Int {
        seasonYear(for: Date())
    }
}

/// How a block is being pruned. Stored on the block setup and on each daily entry.
nonisolated enum PruningMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case spur
    case cane
    case mechanical
    case followUp
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spur: return "Spur pruning"
        case .cane: return "Cane pruning"
        case .mechanical: return "Mechanical pre-pruning"
        case .followUp: return "Follow-up pruning"
        case .other: return "Other"
        }
    }
}

/// A fixed quarter of a vineyard row. Quarters are segments (1 = 0–25% … 4 = 75–100%)
/// so the same portion can never be recorded twice and the crew's stopping point is visible.
///
/// Identity is the ACTUAL paddock row record (`rowId`) when the block has
/// configured rows — renaming or reordering rows never detaches progress.
/// `row` is the display-number snapshot (the real stored number, e.g. 101,
/// never a 1…N index). `rowId` is nil only for manual fallback rows.
nonisolated struct PruningSegment: Codable, Hashable, Sendable {
    var rowId: UUID?
    var row: Int
    var quarter: Int

    init(rowId: UUID? = nil, row: Int, quarter: Int) {
        self.rowId = rowId
        self.row = row
        self.quarter = min(max(quarter, 1), 4)
    }

    /// Canonical row identity: the stable row id when present, else the number.
    var rowKey: String { rowId?.uuidString.lowercased() ?? "n\(row)" }

    static func == (lhs: PruningSegment, rhs: PruningSegment) -> Bool {
        lhs.rowKey == rhs.rowKey && lhs.quarter == rhs.quarter
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rowKey)
        hasher.combine(quarter)
    }
}

/// One selectable row on the progress screen — the ACTUAL configured paddock
/// row when the block has row records, or a numbered fallback row generated
/// from the manual row count otherwise. Precedence:
///   1. configured paddock rows (stored order, real numbers, per-row length),
///   2. sequential fallback rows from `manual_row_count`.
nonisolated struct PruningRowRef: Identifiable, Sendable, Hashable {
    /// Stable paddock row id (nil for manual fallback rows).
    let rowId: UUID?
    /// Real stored row number (or 1…N only for fallback rows).
    let number: Int
    /// Display label — the stored row identifier.
    let label: String
    /// This row's length in metres when geometry exists.
    let lengthMetres: Double?
    /// Estimated vines in THIS row (rows can have different lengths).
    let vines: Double
    /// True when generated from the manual row count.
    let isFallback: Bool

    var id: String { rowId?.uuidString.lowercased() ?? "n\(number)" }

    func segment(quarter: Int) -> PruningSegment {
        PruningSegment(rowId: rowId, row: number, quarter: quarter)
    }
}

/// Per-block pruning configuration (due date, crew, working days).
nonisolated struct PruningBlockSetup: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var paddockId: UUID
    /// Pruning season (calendar year). Part of the deterministic season id.
    var seasonYear: Int
    var startDate: Date?
    var dueDate: Date?
    var method: PruningMethod
    var crew: String
    /// ISO weekdays that count as working days (1 = Monday … 7 = Sunday).
    var workingDays: [Int]
    /// Manual row count for blocks without mapped rows.
    var rowCountOverride: Int?
    var estimatedLabourHours: Double?
    var notes: String

    init(
        id: UUID? = nil,
        vineyardId: UUID,
        paddockId: UUID,
        seasonYear: Int = PruningSeasonId.currentSeasonYear,
        startDate: Date? = nil,
        dueDate: Date? = nil,
        method: PruningMethod = .spur,
        crew: String = "",
        workingDays: [Int] = [1, 2, 3, 4, 5],
        rowCountOverride: Int? = nil,
        estimatedLabourHours: Double? = nil,
        notes: String = ""
    ) {
        self.id = id ?? PruningSeasonId.make(vineyardId: vineyardId, paddockId: paddockId, seasonYear: seasonYear)
        self.seasonYear = seasonYear
        self.vineyardId = vineyardId
        self.paddockId = paddockId
        self.startDate = startDate
        self.dueDate = dueDate
        self.method = method
        self.crew = crew
        self.workingDays = workingDays
        self.rowCountOverride = rowCountOverride
        self.estimatedLabourHours = estimatedLabourHours
        self.notes = notes
    }
}

/// One day's recorded pruning work on a block.
nonisolated struct PruningEntry: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var paddockId: UUID
    /// The `pruning_seasons` row this entry belongs to (deterministic per
    /// vineyard + paddock + season year).
    var seasonId: UUID
    var date: Date
    var segments: [PruningSegment]
    var worker: String
    var labourHours: Double?
    var startTime: Date?
    var finishTime: Date?
    var method: PruningMethod
    var notes: String
    /// Client estimate at save time; the server re-attributes on sync.
    var estimatedVines: Int
    /// The Work Task created from this recording (at most one per entry).
    var workTaskId: UUID?
    var createdAt: Date
    /// Server `updated_at` — the ONLY signal that distinguishes an edited
    /// record from an untouched one in the Activity Report. Nil until the
    /// entry has been pulled back from the server.
    var updatedAt: Date?
    /// Server `created_by` (the account that entered the record).
    var enteredBy: UUID?
    /// Server `deleted_at` — a REVERSED entry. Reversed entries are retained
    /// locally for the Activity Report's audit history and are excluded from
    /// every progress/rate/forecast calculation (see `PruningStore.entries`).
    var reversedAt: Date?
    /// `pruning_entries.pruning_activity_id` (sql/166) — the PARENT activity
    /// this row is one ALLOCATION of. Nil for records that predate the activity
    /// model; the server back-fills those with `pruning_activity_id = id`, which
    /// is exactly what `activityKey` falls back to.
    ///
    /// Optional so an already-cached entry decoded from disk keeps working.
    var pruningActivityId: UUID?
    /// `pruning_entries.allocation_index` — 0 for the PRIMARY allocation, the
    /// only one carrying the activity's labour, timing and Work Task link.
    var allocationIndex: Int?
    /// `pruning_entries.is_skipped` (sql/168) — this record marks its sections
    /// as OUT OF PRUNING ROTATION (vines removed, row pulled out, replanted,
    /// dead) rather than pruned.
    ///
    /// Optional in the Codable sense ONLY, so entries cached before the column
    /// existed still decode instead of wiping the whole local cache. Always
    /// read it through `isSkipped`, never compare to `true` directly.
    var skipped: Bool?

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        paddockId: UUID,
        seasonId: UUID? = nil,
        date: Date = Date(),
        segments: [PruningSegment] = [],
        worker: String = "",
        labourHours: Double? = nil,
        startTime: Date? = nil,
        finishTime: Date? = nil,
        method: PruningMethod = .spur,
        notes: String = "",
        estimatedVines: Int = 0,
        workTaskId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        enteredBy: UUID? = nil,
        reversedAt: Date? = nil,
        pruningActivityId: UUID? = nil,
        allocationIndex: Int? = nil,
        skipped: Bool? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.paddockId = paddockId
        // The season ALWAYS follows the entry's own date (sql/161), so a
        // backdated record, an offline queue replayed after New Year, or a
        // device with a skewed clock can never file work under another year.
        self.seasonId = seasonId ?? PruningSeasonId.make(vineyardId: vineyardId, paddockId: paddockId, date: date)
        self.estimatedVines = estimatedVines
        self.date = date
        self.segments = segments
        self.worker = worker
        self.labourHours = labourHours
        self.startTime = startTime
        self.finishTime = finishTime
        self.method = method
        self.notes = notes
        self.workTaskId = workTaskId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.enteredBy = enteredBy
        self.reversedAt = reversedAt
        self.pruningActivityId = pruningActivityId
        self.allocationIndex = allocationIndex
        self.skipped = skipped
    }

    /// A full row = 1.0; each quarter = 0.25.
    var rowEquivalents: Double { Double(segments.count) / 4.0 }

    /// True when this record marks its sections SKIPPED — out of rotation.
    ///
    /// A skipped record counts its sections as COMPLETE for progress, and as
    /// nothing at all for pruning work: no vines pruned, no labour, no cost, no
    /// worker, no Work Task, no rate. It never carries labour of its own, so
    /// every rate calculation must exclude it on BOTH sides of the ratio.
    var isSkipped: Bool { skipped == true }

    /// The parent activity this allocation belongs to. A legacy single-block
    /// record is its own activity, matching the server's back-fill, so grouping
    /// by this key is safe for every record ever written.
    var activityKey: UUID { pruningActivityId ?? id }

    /// Allocation position within the parent activity; 0 = PRIMARY.
    var allocationOrder: Int { allocationIndex ?? 0 }

    /// Reversed entries are audit history only — never progress, never rates.
    var isReversed: Bool { reversedAt != nil }

    /// Person-hours span between the recorded start and finish times.
    var durationHours: Double? {
        guard let startTime, let finishTime else { return nil }
        let seconds = finishTime.timeIntervalSince(startTime)
        guard seconds > 0 else { return nil }
        return seconds / 3_600
    }
}

/// Schedule status for a block, derived from projected finish vs due date.
nonisolated enum PruningStatus: String, Sendable {
    case notStarted
    case ahead
    case onTrack
    case atRisk
    case behind
    case complete

    var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .ahead: return "Ahead"
        case .onTrack: return "On track"
        case .atRisk: return "At risk"
        case .behind: return "Behind"
        case .complete: return "Complete"
        }
    }
}

/// Outcome of the vineyard-wide completion forecast.
nonisolated enum PruningForecastOutcome: Sendable, Equatable {
    /// Not enough valid data to forecast (no entries, no configured vines,
    /// zero average). NEVER render an arbitrary date for this case.
    case notEnoughData
    /// Pruning is finished — the date is the LAST valid pruning activity.
    case completed(Date)
    /// today + estimated days remaining.
    case projected(Date)
}

/// Vineyard-wide completion forecast.
///
/// SHARED CONTRACT (identical on iOS, Android and any portal implementation):
/// * elapsed days = calendar days from the FIRST valid pruning entry through
///   today, INCLUSIVE — days with no recorded pruning still count,
/// * average vines/day = total exact vines pruned ÷ elapsed days,
/// * remaining = every configured block's vines − vines pruned (blocks with
///   zero progress are part of the workload),
/// * days remaining = ceil(remaining ÷ average) — rounded UP so the forecast
///   never understates the finish date.
nonisolated struct PruningVineyardForecast: Sendable, Equatable {
    /// Earliest valid pruning entry across the whole vineyard.
    var firstEntryDate: Date?
    /// Latest valid pruning entry across the whole vineyard.
    var lastEntryDate: Date?
    /// Inclusive calendar days from `firstEntryDate` through `asOf` (0 when unknown).
    var elapsedDays: Int
    /// Vines pruned ÷ elapsed calendar days.
    var averageVinesPerElapsedDay: Double?
    /// Exact vines still to prune across every configured block.
    var vinesRemainingExact: Double
    /// ceil(remaining ÷ average), nil when it cannot be computed.
    var estimatedDaysRemaining: Int?
    var outcome: PruningForecastOutcome

    static let empty = PruningVineyardForecast(
        firstEntryDate: nil,
        lastEntryDate: nil,
        elapsedDays: 0,
        averageVinesPerElapsedDay: nil,
        vinesRemainingExact: 0,
        estimatedDaysRemaining: nil,
        outcome: .notEnoughData
    )
}

/// Aggregated progress + rate metrics for one block.
nonisolated struct PruningBlockMetrics: Sendable {
    /// The actual rows the tracker operates on (configured rows first,
    /// manual fallback rows only when none are configured).
    var rows: [PruningRowRef]
    var rowCount: Int
    /// EVERY finished quarter — pruned AND skipped. This is what "complete"
    /// means for progress, rows remaining and sections remaining.
    var completed: Set<PruningSegment>
    /// Quarters finished by actual pruning work. `completed` minus `skipped`.
    var pruned: Set<PruningSegment>
    /// Quarters marked OUT OF ROTATION (sql/168 `is_skipped`). Complete, but
    /// never pruning work — no vines, no labour, no cost, no rate.
    var skipped: Set<PruningSegment>
    var completedRowEquivalents: Double
    /// Row equivalents finished by real pruning work.
    var prunedRowEquivalents: Double
    /// Row equivalents marked skipped.
    var skippedRowEquivalents: Double
    var totalRowEquivalents: Double
    /// Pruned + skipped ÷ total — the headline "Complete overall".
    var fractionComplete: Double
    /// Pruned ÷ total — the "Pruned" line of the split display.
    var fractionPruned: Double
    /// Skipped ÷ total — the "Skipped" line of the split display.
    var fractionSkipped: Double
    var vinesPerRow: Double
    /// EXACT (unrounded) vines pruned — sum of each completed quarter's exact
    /// vines. Vineyard totals MUST sum this and round once at display
    /// (rounding per block first drifts against Android/portal).
    var vinesPrunedExact: Double
    /// Display value for this block: round(vinesPrunedExact).
    var vinesPruned: Int
    /// EXACT vines inside skipped sections. Counted as complete, never as
    /// pruned — reported separately so "vines pruned" stays truthful.
    var vinesSkippedExact: Double
    var vinesSkipped: Int
    var vinesTotal: Int
    var averageRowLength: Double
    /// Hectares finished — pruned + skipped. Use for completion reporting.
    var completionAreaHa: Double
    /// Hectares actually WORKED. Skipped area is excluded, so this is the only
    /// safe denominator for cost per hectare.
    var workedAreaHa: Double
    var ratePerWorkday: Double?
    var projectedFinish: Date?
    var status: PruningStatus
    var timeElapsedFraction: Double?

    /// True when any section of this block is out of rotation — the trigger
    /// for showing the Pruned / Skipped / Complete split instead of one figure.
    var hasSkippedSections: Bool { !skipped.isEmpty }
}

/// Pure calculation helpers for the Pruning Tracker.
///
/// CALCULATION CONTRACT (shared with Android + the portal RPC
/// `get_pruning_vineyard_summary`): all intermediate row/quarter vine values
/// stay full-precision doubles; rounding happens ONCE at display via
/// `displayPercent` / `round(exact)`. Overall progress is row-equivalent
/// based (completed ÷ total row equivalents), never vine-weighted.
nonisolated enum PruningCalculator {

    /// The ONE display rounding rule for percentages on every platform:
    /// round(fraction × 100) half away from zero. (Kotlin `roundToInt` and
    /// the SQL RPC use the same rule — never truncate, never banker's-round.)
    static func displayPercent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    /// ISO weekday (1 = Monday … 7 = Sunday) for a date.
    static func isoWeekday(of date: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return ((weekday + 5) % 7) + 1
    }

    /// Length of one mapped row in metres (equirectangular, matches
    /// `Paddock.totalRowLengthMetres`).
    static func rowLength(_ row: PaddockRow, paddock: Paddock) -> Double {
        let points = paddock.polygonPoints
        let centroidLat = points.isEmpty
            ? row.startPoint.latitude
            : points.map(\.latitude).reduce(0, +) / Double(points.count)
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        let dLat = (row.endPoint.latitude - row.startPoint.latitude) * mPerDegLat
        let dLon = (row.endPoint.longitude - row.startPoint.longitude) * mPerDegLon
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// The rows the tracker operates on. Uses the ACTUAL configured paddock
    /// rows (ascending row-number order, real numbers — non-sequential and
    /// >1 starts are preserved); falls back to sequential rows from the manual row count
    /// only when the block has no configured row records.
    ///
    /// Vine distribution: each row is weighted by its own length (rows
    /// without geometry get the average mapped length, or an equal share
    /// when nothing is mapped), and the block's effective vine count is
    /// split across those weights — so a quarter contributes 25% of THAT
    /// row's vines and totals always reconcile with the block vine count.
    static func rowRefs(paddock: Paddock, setup: PruningBlockSetup?) -> [PruningRowRef] {
        let totalVines = Double(paddock.effectiveVineCount)
        let configured = paddock.rows.sorted { $0.number < $1.number }
        if !configured.isEmpty {
            let lengths = configured.map { rowLength($0, paddock: paddock) }
            let positive = lengths.filter { $0 > 0 }
            let averageLength = positive.isEmpty ? 0 : positive.reduce(0, +) / Double(positive.count)
            let weights = lengths.map { $0 > 0 ? $0 : (averageLength > 0 ? averageLength : 1) }
            let totalWeight = weights.reduce(0, +)
            return configured.enumerated().map { index, row in
                PruningRowRef(
                    rowId: row.id,
                    number: row.number,
                    label: "\(row.number)",
                    lengthMetres: lengths[index] > 0 ? lengths[index] : nil,
                    vines: totalWeight > 0 ? totalVines * weights[index] / totalWeight : 0,
                    isFallback: false
                )
            }
        }
        let count = setup?.rowCountOverride ?? 0
        guard count > 0 else { return [] }
        return (1...count).map { number in
            PruningRowRef(
                rowId: nil,
                number: number,
                label: "\(number)",
                lengthMetres: nil,
                vines: totalVines / Double(count),
                isFallback: true
            )
        }
    }

    /// Union of completed segments across entries, canonicalised onto the
    /// block's actual rows. Segments carrying a row id only match that exact
    /// row (a renamed row keeps its progress; a deleted row's quarters are
    /// excluded rather than silently attached to a different row). Legacy
    /// segments without a row id are matched by their stored number.
    static func completedSegments(entries: [PruningEntry], rows: [PruningRowRef]) -> Set<PruningSegment> {
        var byId: [String: PruningRowRef] = [:]
        var byNumber: [Int: PruningRowRef] = [:]
        for ref in rows {
            if let rowId = ref.rowId { byId[rowId.uuidString.lowercased()] = ref }
            if byNumber[ref.number] == nil { byNumber[ref.number] = ref }
        }
        var set = Set<PruningSegment>()
        for entry in entries {
            for segment in entry.segments {
                let ref: PruningRowRef?
                if let rowId = segment.rowId {
                    ref = byId[rowId.uuidString.lowercased()]
                } else {
                    ref = byNumber[segment.row]
                }
                if let ref {
                    set.insert(ref.segment(quarter: segment.quarter))
                }
            }
        }
        return set
    }

    /// Quarters marked SKIPPED (out of rotation), canonicalised onto the
    /// block's rows exactly like `completedSegments`.
    ///
    /// A quarter that is ALSO claimed by a real pruning record is not returned:
    /// recorded work always outranks a skip, so a stray overlapping skip can
    /// never erase pruning from the vines-pruned figures.
    static func skippedSegments(entries: [PruningEntry], rows: [PruningRowRef]) -> Set<PruningSegment> {
        let skipped = completedSegments(entries: entries.filter(\.isSkipped), rows: rows)
        guard !skipped.isEmpty else { return [] }
        let worked = completedSegments(entries: entries.filter { !$0.isSkipped }, rows: rows)
        return skipped.subtracting(worked)
    }

    /// Entries that represent actual pruning WORK. Skipped records carry no
    /// labour, no vines and no rate, so every work-rate calculation drops them
    /// from both sides of the ratio rather than counting them as a fast day.
    static func workEntries(_ entries: [PruningEntry]) -> [PruningEntry] {
        entries.filter { !$0.isSkipped }
    }

    /// Hectares represented by a set of quarters: each quarter is 25% of THAT
    /// row's length × the block's row width. Rows without geometry use the
    /// average mapped length, matching the vine-weighting rule.
    static func areaHectares(
        for segments: some Collection<PruningSegment>,
        rows: [PruningRowRef],
        paddock: Paddock
    ) -> Double {
        guard paddock.rowWidth > 0, !rows.isEmpty else { return 0 }
        let mapped = rows.compactMap(\.lengthMetres).filter { $0 > 0 }
        let fallback = mapped.isEmpty
            ? (paddock.effectiveTotalRowLength > 0 ? paddock.effectiveTotalRowLength / Double(rows.count) : 0)
            : mapped.reduce(0, +) / Double(mapped.count)
        guard fallback > 0 || !mapped.isEmpty else { return 0 }
        var lengthByKey: [String: Double] = [:]
        for ref in rows { lengthByKey[ref.id] = ref.lengthMetres ?? fallback }
        let metres = segments.reduce(0.0) { $0 + (lengthByKey[$1.rowKey] ?? fallback) / 4.0 }
        return metres * paddock.rowWidth / 10_000.0
    }

    /// Average row equivalents per day-with-entries, over the most recent `lastDays`
    /// working days (days without entries — e.g. rain days — never count against the rate).
    ///
    /// Skipped records are excluded: marking a dead block out of rotation is not
    /// a productive day and must never inflate the crew's throughput.
    static func rowEquivalentsPerDay(entries: [PruningEntry], lastDays: Int?, calendar: Calendar = .current) -> Double? {
        let byDay = Dictionary(grouping: workEntries(entries)) { calendar.startOfDay(for: $0.date) }
        guard !byDay.isEmpty else { return nil }
        let days = byDay.keys.sorted(by: >)
        let selected = lastDays.map { Array(days.prefix($0)) } ?? days
        guard !selected.isEmpty else { return nil }
        let total = selected.reduce(0.0) { sum, day in
            sum + (byDay[day] ?? []).reduce(0.0) { $0 + $1.rowEquivalents }
        }
        return total / Double(selected.count)
    }

    /// Preferred rolling rate: last 3 working days when available, otherwise the whole period.
    static func preferredRate(entries: [PruningEntry], calendar: Calendar = .current) -> Double? {
        rowEquivalentsPerDay(entries: entries, lastDays: 3, calendar: calendar)
            ?? rowEquivalentsPerDay(entries: entries, lastDays: nil, calendar: calendar)
    }

    /// Projects the completion date by walking forward through configured working days.
    static func projectedFinish(
        remainingRowEquivalents: Double,
        ratePerWorkday: Double,
        workingDays: [Int],
        from start: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard ratePerWorkday > 0 else { return nil }
        guard remainingRowEquivalents > 0 else { return calendar.startOfDay(for: start) }
        let workSet = Set(workingDays.isEmpty ? [1, 2, 3, 4, 5] : workingDays)
        var daysNeeded = Int(ceil(remainingRowEquivalents / ratePerWorkday))
        var date = calendar.startOfDay(for: start)
        var iterations = 0
        while iterations < 3_660 {
            if workSet.contains(isoWeekday(of: date, calendar: calendar)) {
                daysNeeded -= 1
                if daysNeeded <= 0 { return date }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
            date = next
            iterations += 1
        }
        return nil
    }

    /// Ahead > 3 days early · On track within 3 days · At risk 1–3 days late · Behind > 3 days late.
    static func status(
        completedRowEquivalents: Double,
        totalRowEquivalents: Double,
        projectedFinish: Date?,
        dueDate: Date?,
        calendar: Calendar = .current
    ) -> PruningStatus {
        if totalRowEquivalents > 0, completedRowEquivalents >= totalRowEquivalents - 0.0001 {
            return .complete
        }
        if completedRowEquivalents <= 0 { return .notStarted }
        guard let projectedFinish, let dueDate else { return .onTrack }
        let projected = calendar.startOfDay(for: projectedFinish)
        let due = calendar.startOfDay(for: dueDate)
        let daysLate = calendar.dateComponents([.day], from: due, to: projected).day ?? 0
        if daysLate < -3 { return .ahead }
        if daysLate <= 0 { return .onTrack }
        if daysLate <= 3 { return .atRisk }
        return .behind
    }

    /// Full metric bundle for one block. `asOf` is the projection start date
    /// (defaults to now; fixture tests pass a fixed date for determinism).
    static func metrics(
        paddock: Paddock,
        setup: PruningBlockSetup?,
        entries: [PruningEntry],
        calendar: Calendar = .current,
        asOf: Date = Date()
    ) -> PruningBlockMetrics {
        let rows = rowRefs(paddock: paddock, setup: setup)
        let rowCount = rows.count
        // `completed` is pruned + skipped: both finish a section, so both count
        // toward progress, rows remaining and sections remaining. Only `pruned`
        // is ever treated as work done.
        let completed = completedSegments(entries: entries, rows: rows)
        let skipped = skippedSegments(entries: entries, rows: rows)
        let pruned = completed.subtracting(skipped)
        let completedRowEq = Double(completed.count) / 4.0
        let prunedRowEq = Double(pruned.count) / 4.0
        let skippedRowEq = Double(skipped.count) / 4.0
        let totalRowEq = Double(rowCount)
        let fraction = totalRowEq > 0 ? min(completedRowEq / totalRowEq, 1.0) : 0
        let prunedFraction = totalRowEq > 0 ? min(prunedRowEq / totalRowEq, 1.0) : 0
        let skippedFraction = totalRowEq > 0 ? min(skippedRowEq / totalRowEq, 1.0) : 0

        let totalVines = paddock.effectiveVineCount
        let vinesPerRow = rowCount > 0 ? Double(totalVines) / Double(rowCount) : 0
        let vinesPrunedExact = exactVines(for: pruned, rows: rows)
        let vinesSkippedExact = exactVines(for: skipped, rows: rows)
        let averageRowLength = rowCount > 0 ? paddock.effectiveTotalRowLength / Double(rowCount) : 0

        let rate = preferredRate(entries: entries, calendar: calendar)
        let remaining = max(totalRowEq - completedRowEq, 0)
        let projected: Date?
        if let rate, rate > 0, remaining > 0 {
            projected = projectedFinish(
                remainingRowEquivalents: remaining,
                ratePerWorkday: rate,
                workingDays: setup?.workingDays ?? [1, 2, 3, 4, 5],
                from: asOf,
                calendar: calendar
            )
        } else {
            projected = nil
        }

        let blockStatus = status(
            completedRowEquivalents: completedRowEq,
            totalRowEquivalents: totalRowEq,
            projectedFinish: projected,
            dueDate: setup?.dueDate,
            calendar: calendar
        )

        var elapsed: Double?
        if let due = setup?.dueDate {
            let start = setup?.startDate
                ?? entries.map(\.date).min()
            if let start, due > start {
                let total = due.timeIntervalSince(start)
                let gone = asOf.timeIntervalSince(start)
                elapsed = min(max(gone / total, 0), 1)
            }
        }

        return PruningBlockMetrics(
            rows: rows,
            rowCount: rowCount,
            completed: completed,
            pruned: pruned,
            skipped: skipped,
            completedRowEquivalents: completedRowEq,
            prunedRowEquivalents: prunedRowEq,
            skippedRowEquivalents: skippedRowEq,
            totalRowEquivalents: totalRowEq,
            fractionComplete: fraction,
            fractionPruned: prunedFraction,
            fractionSkipped: skippedFraction,
            vinesPerRow: vinesPerRow,
            vinesPrunedExact: vinesPrunedExact,
            vinesPruned: Int(vinesPrunedExact.rounded()),
            vinesSkippedExact: vinesSkippedExact,
            vinesSkipped: Int(vinesSkippedExact.rounded()),
            vinesTotal: totalVines,
            averageRowLength: averageRowLength,
            completionAreaHa: areaHectares(for: completed, rows: rows, paddock: paddock),
            workedAreaHa: areaHectares(for: pruned, rows: rows, paddock: paddock),
            ratePerWorkday: rate,
            projectedFinish: projected,
            status: blockStatus,
            timeElapsedFraction: elapsed
        )
    }

    /// Vines represented by a set of segments for a block (average-row basis;
    /// used for rate stats).
    static func vines(forSegmentCount count: Int, vinesPerRow: Double) -> Int {
        Int((Double(count) * vinesPerRow / 4.0).rounded())
    }

    /// EXACT vines represented by a set of segments using each ACTUAL row's
    /// vine estimate — a quarter contributes 25% of that specific row's vines.
    /// Full precision: aggregate these and round ONCE at display.
    static func exactVines(for segments: some Collection<PruningSegment>, rows: [PruningRowRef]) -> Double {
        var byKey: [String: Double] = [:]
        for ref in rows { byKey[ref.id] = ref.vines }
        return segments.reduce(0.0) { $0 + (byKey[$1.rowKey] ?? 0) / 4.0 }
    }

    /// Display-rounded variant of `exactVines`. Never sum these — sum the
    /// exact values and round the total instead.
    static func vines(for segments: some Collection<PruningSegment>, rows: [PruningRowRef]) -> Int {
        Int(exactVines(for: segments, rows: rows).rounded())
    }

    /// Mean EXACT vines per day-with-entries (whole period) — the same
    /// vines/day contract the vineyard dashboard and the SQL 115 RPC use,
    /// applied to one block. Days without entries never count against the rate.
    static func exactVinesPerDay(
        entries: [PruningEntry],
        rows: [PruningRowRef],
        calendar: Calendar = .current
    ) -> Double? {
        var byDay: [Date: Double] = [:]
        for entry in workEntries(entries) {
            byDay[calendar.startOfDay(for: entry.date), default: 0] += exactVines(for: entry.segments, rows: rows)
        }
        guard !byDay.isEmpty else { return nil }
        return byDay.values.reduce(0, +) / Double(byDay.count)
    }

    /// Vines per person-hour: Σ EXACT vines of entries with labour hours > 0
    /// ÷ Σ labour hours. Entries without hours are excluded from BOTH sides
    /// (SQL 115 contract). Round only for display.
    static func vinesPerLabourHour(entries: [PruningEntry], rows: [PruningRowRef]) -> Double? {
        var vines = 0.0
        var hours = 0.0
        for entry in workEntries(entries) {
            if let entryHours = entry.labourHours, entryHours > 0 {
                vines += exactVines(for: entry.segments, rows: rows)
                hours += entryHours
            }
        }
        return hours > 0 ? vines / hours : nil
    }

    /// THE vineyard dashboard aggregation — mirrors the authoritative SQL 115
    /// RPC `get_pruning_vineyard_summary` exactly:
    /// * Σ EXACT per-quarter vines across blocks, rounded ONCE at the end,
    /// * overall % = completed ÷ total row equivalents (row-equivalent based),
    /// * vines/day = mean of per-day exact totals over days-with-entries,
    /// * vines/labour hr = exact vines of hour-carrying entries ÷ person-hours,
    /// * `projectedFinish` = the LATEST block projection (kept ONLY for the
    ///   SQL 115 parity diagnostic — never displayed; the dashboard uses
    ///   `forecast`, the elapsed-calendar-day vineyard forecast).
    static func vineyardSummary(
        blocks: [(metrics: PruningBlockMetrics, entries: [PruningEntry])],
        calendar: Calendar = .current,
        asOf: Date = Date()
    ) -> PruningVineyardSummary {
        var completedEq = 0.0
        var prunedEq = 0.0
        var skippedEq = 0.0
        var totalEq = 0.0
        var vinesPrunedExact = 0.0
        var vinesSkippedExact = 0.0
        var vinesTotal = 0
        var completionAreaHa = 0.0
        var workedAreaHa = 0.0
        var blocksComplete = 0
        var blocksAtRisk = 0
        var projected: Date?
        var vinesByDay: [Date: Double] = [:]
        var validEntryDays: [Date] = []
        var vinesForHours = 0.0
        var hours = 0.0

        for block in blocks {
            let metrics = block.metrics
            completedEq += metrics.completedRowEquivalents
            prunedEq += metrics.prunedRowEquivalents
            skippedEq += metrics.skippedRowEquivalents
            totalEq += metrics.totalRowEquivalents
            vinesPrunedExact += metrics.vinesPrunedExact
            vinesSkippedExact += metrics.vinesSkippedExact
            vinesTotal += metrics.vinesTotal
            completionAreaHa += metrics.completionAreaHa
            workedAreaHa += metrics.workedAreaHa
            if metrics.status == .complete { blocksComplete += 1 }
            if metrics.status == .behind || metrics.status == .atRisk { blocksAtRisk += 1 }
            if let finish = metrics.projectedFinish {
                projected = max(projected ?? finish, finish)
            }
            // Skipped records are excluded from EVERY work figure below: they
            // carry no vines pruned, no labour and no rate, so including them
            // would make an out-of-rotation block look like a productive day.
            for entry in workEntries(block.entries) {
                let vines = exactVines(for: entry.segments, rows: metrics.rows)
                let day = calendar.startOfDay(for: entry.date)
                vinesByDay[day, default: 0] += vines
                // A VALID entry is one whose segments actually resolve onto
                // this block's rows — quarters pointing at deleted rows (or
                // an entry that was reversed to empty) must not anchor the
                // elapsed period.
                if !completedSegments(entries: [entry], rows: metrics.rows).isEmpty {
                    validEntryDays.append(day)
                }
                if let entryHours = entry.labourHours, entryHours > 0 {
                    vinesForHours += vines
                    hours += entryHours
                }
            }
        }

        let fraction = totalEq > 0 ? min(completedEq / totalEq, 1.0) : 0
        let complete = (totalEq > 0 && completedEq >= totalEq - 0.0001)
            || (vinesTotal > 0 && Double(vinesTotal) - vinesPrunedExact - vinesSkippedExact < 0.5)
        let forecast = vineyardForecast(
            vinesPrunedExact: vinesPrunedExact,
            vinesTotal: vinesTotal,
            isComplete: complete,
            entryDates: validEntryDays,
            asOf: asOf,
            calendar: calendar,
            vinesSkippedExact: vinesSkippedExact
        )
        return PruningVineyardSummary(
            blockCount: blocks.count,
            completedRowEquivalents: completedEq,
            prunedRowEquivalents: prunedEq,
            skippedRowEquivalents: skippedEq,
            totalRowEquivalents: totalEq,
            fraction: fraction,
            fractionPruned: totalEq > 0 ? min(prunedEq / totalEq, 1.0) : 0,
            fractionSkipped: totalEq > 0 ? min(skippedEq / totalEq, 1.0) : 0,
            vinesPrunedExact: vinesPrunedExact,
            vinesPruned: Int(vinesPrunedExact.rounded()),
            vinesSkippedExact: vinesSkippedExact,
            vinesSkipped: Int(vinesSkippedExact.rounded()),
            vinesTotal: vinesTotal,
            completionAreaHa: completionAreaHa,
            workedAreaHa: workedAreaHa,
            vinesPerDay: vinesByDay.isEmpty ? nil : vinesByDay.values.reduce(0, +) / Double(vinesByDay.count),
            vinesPerLabourHour: hours > 0 ? vinesForHours / hours : nil,
            labourHours: hours,
            blocksComplete: blocksComplete,
            blocksAtRisk: blocksAtRisk,
            projectedFinish: projected,
            forecast: forecast
        )
    }

    /// THE vineyard completion forecast — the one rule iOS, Android and the
    /// portal must all apply (see `PruningVineyardForecast`).
    ///
    /// * `entryDates` — dates of every VALID pruning entry across ALL blocks.
    /// * `vinesTotal` — vines of EVERY configured block, including blocks
    ///   with zero progress (they are still remaining workload).
    ///
    /// Never derived from per-block rates or per-block projections, and never
    /// from "days that contain entries" — rain days count as elapsed time.
    /// `vinesSkippedExact` — vines inside sections marked OUT OF ROTATION.
    /// They are already complete and will never be pruned, so they leave the
    /// remaining workload without ever counting as work done.
    static func vineyardForecast(
        vinesPrunedExact: Double,
        vinesTotal: Int,
        isComplete: Bool,
        entryDates: some Collection<Date>,
        asOf: Date = Date(),
        calendar: Calendar = .current,
        vinesSkippedExact: Double = 0
    ) -> PruningVineyardForecast {
        let days = entryDates.map { calendar.startOfDay(for: $0) }.sorted()
        let first = days.first
        let last = days.last
        let remaining = max(Double(vinesTotal) - vinesPrunedExact - vinesSkippedExact, 0)

        var forecast = PruningVineyardForecast(
            firstEntryDate: first,
            lastEntryDate: last,
            elapsedDays: 0,
            averageVinesPerElapsedDay: nil,
            vinesRemainingExact: remaining,
            estimatedDaysRemaining: nil,
            outcome: .notEnoughData
        )

        // No configured vines, or no valid pruning activity at all.
        guard vinesTotal > 0, let first, let last, vinesPrunedExact > 0 else { return forecast }

        let today = calendar.startOfDay(for: asOf)
        // Inclusive elapsed rule: the first pruning day counts as day 1, and
        // every calendar day since counts — including days with no entries.
        let spanned = calendar.dateComponents([.day], from: first, to: today).day ?? 0
        let elapsedDays = max(spanned + 1, 1)
        forecast.elapsedDays = elapsedDays

        let average = vinesPrunedExact / Double(elapsedDays)
        guard average > 0 else { return forecast }
        forecast.averageVinesPerElapsedDay = average

        // < 0.5 rounds to "0 vines remaining" on the dashboard — treat it as done.
        if isComplete || remaining < 0.5 {
            forecast.estimatedDaysRemaining = 0
            forecast.outcome = .completed(last)
            return forecast
        }

        let daysRemaining = min(max(Int(ceil(remaining / average)), 1), 3_650)
        forecast.estimatedDaysRemaining = daysRemaining
        if let finish = calendar.date(byAdding: .day, value: daysRemaining, to: today) {
            forecast.outcome = .projected(finish)
        }
        return forecast
    }

    /// Convenience overload building block metrics from raw store data —
    /// used by the online SQL 115 parity check and the shared fixture tests.
    /// Includes EVERY non-deleted paddock of the vineyard (blocks without a
    /// season row or without entries still count), matching the RPC.
    static func vineyardSummary(
        paddocks: [Paddock],
        setups: [PruningBlockSetup],
        entries: [PruningEntry],
        calendar: Calendar = .current,
        asOf: Date = Date()
    ) -> PruningVineyardSummary {
        let blocks: [(metrics: PruningBlockMetrics, entries: [PruningEntry])] = paddocks.map { paddock in
            let setup = setups
                .filter { $0.paddockId == paddock.id }
                .max { $0.seasonYear < $1.seasonYear }
            let blockEntries = entries.filter { $0.paddockId == paddock.id }
            return (
                metrics(paddock: paddock, setup: setup, entries: blockEntries, calendar: calendar, asOf: asOf),
                blockEntries
            )
        }
        return vineyardSummary(blocks: blocks, calendar: calendar, asOf: asOf)
    }
}

/// Vineyard-wide dashboard summary — the aggregation contract shared with
/// Android and the SQL 115 RPC `get_pruning_vineyard_summary`. All values are
/// exact; round only at display.
nonisolated struct PruningVineyardSummary: Sendable {
    var blockCount: Int
    /// Pruned + skipped row equivalents — what "complete" means.
    var completedRowEquivalents: Double
    /// Row equivalents finished by real pruning work.
    var prunedRowEquivalents: Double = 0
    /// Row equivalents marked out of rotation.
    var skippedRowEquivalents: Double = 0
    var totalRowEquivalents: Double
    /// Exact completion fraction (row-equivalent based, capped at 1).
    var fraction: Double
    /// Pruned ÷ total — the "Pruned: 70%" line.
    var fractionPruned: Double = 0
    /// Skipped ÷ total — the "Skipped: 10%" line.
    var fractionSkipped: Double = 0
    var vinesPrunedExact: Double
    /// round(vinesPrunedExact) — the ONE rounding point for vine totals.
    var vinesPruned: Int
    /// Vines inside skipped sections — complete, but never pruned.
    var vinesSkippedExact: Double = 0
    var vinesSkipped: Int = 0
    var vinesTotal: Int
    /// Hectares finished (pruned + skipped).
    var completionAreaHa: Double = 0
    /// Hectares actually worked — the ONLY safe denominator for cost per
    /// hectare. Skipped area is excluded by construction.
    var workedAreaHa: Double = 0
    var vinesPerDay: Double?
    var vinesPerLabourHour: Double?
    var labourHours: Double
    var blocksComplete: Int
    var blocksAtRisk: Int
    /// Roll-up of the per-block projections. Parity diagnostics ONLY — the
    /// dashboard shows `forecast`, which is vineyard-wide and calendar based.
    var projectedFinish: Date?
    /// The vineyard-wide completion forecast shown on the dashboard.
    var forecast: PruningVineyardForecast = .empty

    /// Vines pruned ÷ elapsed calendar days ("Average vines / day").
    var averageVinesPerElapsedDay: Double? { forecast.averageVinesPerElapsedDay }
    /// Vines still needing work. Skipped vines are complete and are never
    /// coming back into rotation, so they leave the remaining workload.
    var vinesRemaining: Int { max(vinesTotal - vinesPruned - vinesSkipped, 0) }
    var displayPercent: Int { PruningCalculator.displayPercent(fraction) }
    /// "Pruned: 70%" — real work only.
    var prunedPercent: Int { PruningCalculator.displayPercent(fractionPruned) }
    /// "Skipped: 10%" — out of rotation.
    var skippedPercent: Int { PruningCalculator.displayPercent(fractionSkipped) }
    /// True when the vineyard has any out-of-rotation sections, so the UI
    /// should show the Pruned / Skipped / Complete split rather than one figure.
    var hasSkippedSections: Bool { skippedRowEquivalents > 0 }
}
