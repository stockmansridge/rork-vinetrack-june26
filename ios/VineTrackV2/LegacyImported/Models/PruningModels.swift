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

    static var currentSeasonYear: Int {
        Calendar.current.component(.year, from: Date())
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
    var createdAt: Date

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
        createdAt: Date = Date()
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.paddockId = paddockId
        self.seasonId = seasonId ?? PruningSeasonId.make(vineyardId: vineyardId, paddockId: paddockId, seasonYear: PruningSeasonId.currentSeasonYear)
        self.estimatedVines = estimatedVines
        self.date = date
        self.segments = segments
        self.worker = worker
        self.labourHours = labourHours
        self.startTime = startTime
        self.finishTime = finishTime
        self.method = method
        self.notes = notes
        self.createdAt = createdAt
    }

    /// A full row = 1.0; each quarter = 0.25.
    var rowEquivalents: Double { Double(segments.count) / 4.0 }
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

/// Aggregated progress + rate metrics for one block.
nonisolated struct PruningBlockMetrics: Sendable {
    /// The actual rows the tracker operates on (configured rows first,
    /// manual fallback rows only when none are configured).
    var rows: [PruningRowRef]
    var rowCount: Int
    var completed: Set<PruningSegment>
    var completedRowEquivalents: Double
    var totalRowEquivalents: Double
    var fractionComplete: Double
    var vinesPerRow: Double
    var vinesPruned: Int
    var vinesTotal: Int
    var averageRowLength: Double
    var ratePerWorkday: Double?
    var projectedFinish: Date?
    var status: PruningStatus
    var timeElapsedFraction: Double?
}

/// Pure calculation helpers for the Pruning Tracker.
nonisolated enum PruningCalculator {

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
    /// rows (stored order, real numbers — non-sequential and >1 starts are
    /// preserved); falls back to sequential rows from the manual row count
    /// only when the block has no configured row records.
    ///
    /// Vine distribution: each row is weighted by its own length (rows
    /// without geometry get the average mapped length, or an equal share
    /// when nothing is mapped), and the block's effective vine count is
    /// split across those weights — so a quarter contributes 25% of THAT
    /// row's vines and totals always reconcile with the block vine count.
    static func rowRefs(paddock: Paddock, setup: PruningBlockSetup?) -> [PruningRowRef] {
        let totalVines = Double(paddock.effectiveVineCount)
        let configured = paddock.rows
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

    /// Average row equivalents per day-with-entries, over the most recent `lastDays`
    /// working days (days without entries — e.g. rain days — never count against the rate).
    static func rowEquivalentsPerDay(entries: [PruningEntry], lastDays: Int?, calendar: Calendar = .current) -> Double? {
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
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

    /// Full metric bundle for one block.
    static func metrics(
        paddock: Paddock,
        setup: PruningBlockSetup?,
        entries: [PruningEntry],
        calendar: Calendar = .current
    ) -> PruningBlockMetrics {
        let rows = rowRefs(paddock: paddock, setup: setup)
        let rowCount = rows.count
        let completed = completedSegments(entries: entries, rows: rows)
        let completedRowEq = Double(completed.count) / 4.0
        let totalRowEq = Double(rowCount)
        let fraction = totalRowEq > 0 ? min(completedRowEq / totalRowEq, 1.0) : 0

        let totalVines = paddock.effectiveVineCount
        let vinesPerRow = rowCount > 0 ? Double(totalVines) / Double(rowCount) : 0
        let vinesPruned = vines(for: completed, rows: rows)
        let averageRowLength = rowCount > 0 ? paddock.effectiveTotalRowLength / Double(rowCount) : 0

        let rate = preferredRate(entries: entries, calendar: calendar)
        let remaining = max(totalRowEq - completedRowEq, 0)
        let projected: Date?
        if let rate, rate > 0, remaining > 0 {
            projected = projectedFinish(
                remainingRowEquivalents: remaining,
                ratePerWorkday: rate,
                workingDays: setup?.workingDays ?? [1, 2, 3, 4, 5],
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
                let gone = Date().timeIntervalSince(start)
                elapsed = min(max(gone / total, 0), 1)
            }
        }

        return PruningBlockMetrics(
            rows: rows,
            rowCount: rowCount,
            completed: completed,
            completedRowEquivalents: completedRowEq,
            totalRowEquivalents: totalRowEq,
            fractionComplete: fraction,
            vinesPerRow: vinesPerRow,
            vinesPruned: vinesPruned,
            vinesTotal: totalVines,
            averageRowLength: averageRowLength,
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

    /// Vines represented by a set of segments using each ACTUAL row's vine
    /// estimate — a quarter contributes 25% of that specific row's vines.
    static func vines(for segments: some Collection<PruningSegment>, rows: [PruningRowRef]) -> Int {
        var byKey: [String: Double] = [:]
        for ref in rows { byKey[ref.id] = ref.vines }
        let total = segments.reduce(0.0) { $0 + (byKey[$1.rowKey] ?? 0) / 4.0 }
        return Int(total.rounded())
    }
}
