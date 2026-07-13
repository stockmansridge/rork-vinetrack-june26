import Foundation

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
nonisolated struct PruningSegment: Codable, Hashable, Sendable {
    var row: Int
    var quarter: Int

    init(row: Int, quarter: Int) {
        self.row = row
        self.quarter = min(max(quarter, 1), 4)
    }
}

/// Per-block pruning configuration (due date, crew, working days).
nonisolated struct PruningBlockSetup: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var paddockId: UUID
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
        id: UUID = UUID(),
        vineyardId: UUID,
        paddockId: UUID,
        startDate: Date? = nil,
        dueDate: Date? = nil,
        method: PruningMethod = .spur,
        crew: String = "",
        workingDays: [Int] = [1, 2, 3, 4, 5],
        rowCountOverride: Int? = nil,
        estimatedLabourHours: Double? = nil,
        notes: String = ""
    ) {
        self.id = id
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
    var date: Date
    var segments: [PruningSegment]
    var worker: String
    var labourHours: Double?
    var startTime: Date?
    var finishTime: Date?
    var method: PruningMethod
    var notes: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        paddockId: UUID,
        date: Date = Date(),
        segments: [PruningSegment] = [],
        worker: String = "",
        labourHours: Double? = nil,
        startTime: Date? = nil,
        finishTime: Date? = nil,
        method: PruningMethod = .spur,
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.paddockId = paddockId
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

    /// Union of completed segments across entries, clipped to the block's row count.
    static func completedSegments(entries: [PruningEntry], rowCount: Int) -> Set<PruningSegment> {
        var set = Set<PruningSegment>()
        for entry in entries {
            for segment in entry.segments where segment.row >= 1 && segment.row <= rowCount {
                set.insert(segment)
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
        let mappedRows = paddock.rows.count
        let rowCount = mappedRows > 0 ? mappedRows : (setup?.rowCountOverride ?? 0)
        let completed = completedSegments(entries: entries, rowCount: max(rowCount, 1))
        let completedRowEq = Double(completed.count) / 4.0
        let totalRowEq = Double(rowCount)
        let fraction = totalRowEq > 0 ? min(completedRowEq / totalRowEq, 1.0) : 0

        let totalVines = paddock.effectiveVineCount
        let vinesPerRow = rowCount > 0 ? Double(totalVines) / Double(rowCount) : 0
        let vinesPruned = Int((Double(completed.count) * vinesPerRow / 4.0).rounded())
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

    /// Vines represented by a set of segments for a block.
    static func vines(forSegmentCount count: Int, vinesPerRow: Double) -> Int {
        Int((Double(count) * vinesPerRow / 4.0).rounded())
    }
}
