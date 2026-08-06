import Foundation

/// Manual Issue contract — categories, priorities, statuses, location scopes,
/// row segments, validation, and marker derivation.
///
/// A manual issue is a lightweight, manually created issue / action / planning
/// marker for a point, a row selection, or a whole block. It never creates a
/// repair, growth observation, Work Task, labour, cost, machinery or pruning
/// record. This file is pure logic (no I/O) and is mirrored exactly by
/// `ManualIssueModels.kt` on Android — the parity tests on both platforms
/// assert the same fixture values.

nonisolated enum ManualIssueCategory: String, Codable, CaseIterable, Sendable {
    case general
    case actionRequired = "action_required"
    case inspection
    case planning
    case infrastructure
    case vineOrRow = "vine_or_row"
    case safety
    case other

    var label: String {
        switch self {
        case .general: return "General"
        case .actionRequired: return "Action required"
        case .inspection: return "Inspection"
        case .planning: return "Planning"
        case .infrastructure: return "Infrastructure"
        case .vineOrRow: return "Vine or row issue"
        case .safety: return "Safety"
        case .other: return "Other"
        }
    }
}

nonisolated enum ManualIssuePriority: String, Codable, CaseIterable, Sendable {
    case low
    case normal
    case high
    case urgent

    var label: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }

    /// Urgent first when sorting lists by priority.
    var sortOrder: Int {
        switch self {
        case .urgent: return 0
        case .high: return 1
        case .normal: return 2
        case .low: return 3
        }
    }
}

nonisolated enum ManualIssueStatus: String, Codable, CaseIterable, Sendable {
    case open
    case inProgress = "in_progress"
    case completed
    case cancelled

    var label: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }

    /// Statuses shown by the default map/list filter.
    var isActive: Bool { self == .open || self == .inProgress }
}

nonisolated enum ManualIssueLocationScope: String, Codable, CaseIterable, Sendable {
    case point
    case row
    case block

    var label: String {
        switch self {
        case .point: return "Point"
        case .row: return "Rows"
        case .block: return "Whole block"
        }
    }
}

/// One selected quarter of a block row — the same canonical shape as the
/// pruning tracker's segments (row number ≥ 1, segment/quarter 1–4). A whole
/// row is all four quarters.
nonisolated struct ManualIssueSegment: Codable, Hashable, Sendable {
    let row: Int
    let segment: Int
}

/// Pure contract helpers shared by the composer, sync layer and tests.
nonisolated enum ManualIssueContract {

    static let defaultCategory: ManualIssueCategory = .general
    static let defaultPriority: ManualIssuePriority = .normal
    static let defaultStatus: ManualIssueStatus = .open

    /// De-duplicated segments sorted by (row, segment) — the canonical order
    /// the server stores and returns.
    static func canonicalSegments(_ segments: [ManualIssueSegment]) -> [ManualIssueSegment] {
        Array(Set(segments)).sorted {
            $0.row != $1.row ? $0.row < $1.row : $0.segment < $1.segment
        }
    }

    /// Client-side mirror of the server's `_manual_issue_validate` — returns a
    /// user-facing error, or nil when the draft is valid. The server remains
    /// authoritative; this only enables inline form validation.
    static func validationError(
        title: String,
        scope: ManualIssueLocationScope,
        latitude: Double?,
        longitude: Double?,
        paddockId: UUID?,
        segments: [ManualIssueSegment]
    ) -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A title is required."
        }
        if latitude == nil || longitude == nil {
            return "A map location is required."
        }
        switch scope {
        case .point:
            return nil
        case .row:
            if paddockId == nil { return "Select the block that owns the rows." }
            if canonicalSegments(segments).isEmpty { return "Select at least one row." }
            return nil
        case .block:
            if paddockId == nil { return "Select a block." }
            return nil
        }
    }

    /// Midpoint of one row quarter: fraction (quarter − 0.5) / 4 along the
    /// row line, by linear lat/lng interpolation. Quarter 1 starts at the
    /// row's start point.
    static func segmentMidpoint(
        rowStart: (latitude: Double, longitude: Double),
        rowEnd: (latitude: Double, longitude: Double),
        quarter: Int
    ) -> (latitude: Double, longitude: Double) {
        let fraction = (Double(quarter) - 0.5) / 4.0
        return (
            latitude: rowStart.latitude + (rowEnd.latitude - rowStart.latitude) * fraction,
            longitude: rowStart.longitude + (rowEnd.longitude - rowStart.longitude) * fraction
        )
    }

    /// Representative marker for a row selection: the arithmetic mean of the
    /// selected segment midpoints. The structured selection stays
    /// authoritative — this is only where the map pin is drawn. Rows missing
    /// from `rowLines` are skipped; nil when no selected row has geometry.
    static func markerCoordinate(
        segments: [ManualIssueSegment],
        rowLines: [Int: (start: (latitude: Double, longitude: Double), end: (latitude: Double, longitude: Double))]
    ) -> (latitude: Double, longitude: Double)? {
        let canonical = canonicalSegments(segments)
        var latSum = 0.0
        var lonSum = 0.0
        var count = 0
        for segment in canonical {
            guard let line = rowLines[segment.row] else { continue }
            let mid = segmentMidpoint(rowStart: line.start, rowEnd: line.end, quarter: segment.segment)
            latSum += mid.latitude
            lonSum += mid.longitude
            count += 1
        }
        guard count > 0 else { return nil }
        return (latitude: latSum / Double(count), longitude: lonSum / Double(count))
    }

    /// Block marker: arithmetic mean of the boundary points (matches the
    /// centroid used by the existing pin map surfaces).
    static func blockCentroid(
        points: [(latitude: Double, longitude: Double)]
    ) -> (latitude: Double, longitude: Double)? {
        guard !points.isEmpty else { return nil }
        let lat = points.map { $0.latitude }.reduce(0, +) / Double(points.count)
        let lon = points.map { $0.longitude }.reduce(0, +) / Double(points.count)
        return (latitude: lat, longitude: lon)
    }

    /// Customer-facing summary of a row selection. Whole rows collapse into
    /// compact ranges ("Rows 2–4"); partial rows list their sections
    /// ("Row 5 (sections 1–2)"). Whole rows come first, joined by " · ".
    /// Must produce byte-identical output to the Kotlin mirror.
    static func rowSelectionSummary(_ segments: [ManualIssueSegment]) -> String {
        let canonical = canonicalSegments(segments)
        guard !canonical.isEmpty else { return "" }
        var byRow: [Int: Set<Int>] = [:]
        for segment in canonical {
            byRow[segment.row, default: []].insert(segment.segment)
        }
        let wholeRows = byRow.filter { $0.value.count == 4 }.keys.sorted()
        let partialRows = byRow.filter { $0.value.count < 4 }.keys.sorted()

        var parts: [String] = []
        if !wholeRows.isEmpty {
            var ranges: [String] = []
            var start = wholeRows[0]
            var prev = wholeRows[0]
            for row in wholeRows.dropFirst() {
                if row == prev + 1 {
                    prev = row
                } else {
                    ranges.append(start == prev ? "\(start)" : "\(start)–\(prev)")
                    start = row
                    prev = row
                }
            }
            ranges.append(start == prev ? "\(start)" : "\(start)–\(prev)")
            let label = wholeRows.count == 1 ? "Row" : "Rows"
            parts.append("\(label) \(ranges.joined(separator: ", "))")
        }
        for row in partialRows {
            let quarters = byRow[row]?.sorted() ?? []
            let contiguous = quarters.count > 1 && quarters.last! - quarters.first! == quarters.count - 1
            let sections = contiguous
                ? "\(quarters.first!)–\(quarters.last!)"
                : quarters.map(String.init).joined(separator: ", ")
            let label = quarters.count == 1 ? "section" : "sections"
            parts.append("Row \(row) (\(label) \(sections))")
        }
        return parts.joined(separator: " · ")
    }

    /// Customer-facing wording for a snapped point: the pin is "on row 19.5"
    /// while the exact path-row value stays intact in the data.
    static func attachedRowLabel(drivingRowNumber: Double?, pinRowNumber: Double?, side: String?) -> String? {
        guard let row = drivingRowNumber ?? pinRowNumber else { return nil }
        let rowText = row.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(row)) : String(row)
        if let side, side == "Left" || side == "Right" {
            return "On row \(rowText) · \(side.lowercased()) side"
        }
        return "On row \(rowText)"
    }
}
