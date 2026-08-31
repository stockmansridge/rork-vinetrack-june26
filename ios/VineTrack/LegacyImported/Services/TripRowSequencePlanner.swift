import Foundation

/// Shared row/path sequence planning used by both Maintenance Trips
/// (`StartTripSheet`) and Spray Trips (`SprayCalculatorView`).
///
/// Encapsulates the multi-block aware path math so both flows produce the
/// **same** Start Path picker, Sequence Direction handling, and Proposed
/// Row Sequence for a given selection. Real vineyard row numbers are
/// preserved (e.g. a block with rows 69–108 yields paths 68.5–108.5).
enum TripRowSequencePlanner {
    /// Sort blocks by lowest row number first, then by name. Blocks without
    /// row geometry sort to the end (compared by name).
    static func rowOrderSort(_ a: Paddock, _ b: Paddock) -> Bool {
        let aMin = a.rows.map(\.number).min()
        let bMin = b.rows.map(\.number).min()
        switch (aMin, bMin) {
        case let (l?, r?):
            if l != r { return l < r }
            return a.name.lowercased() < b.name.lowercased()
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.name.lowercased() < b.name.lowercased()
        }
    }

    /// Sorted, de-duplicated list of every actual row number contributed by
    /// the selected paddocks. Drives the multi-block path range.
    static func selectedRowNumbers(in paddocks: [Paddock]) -> [Int] {
        var set = Set<Int>()
        for paddock in paddocks {
            for row in paddock.rows { set.insert(row.number) }
        }
        return set.sorted()
    }

    /// Combined total row count across every selected block.
    static func combinedTotalRows(in paddocks: [Paddock]) -> Int {
        paddocks.reduce(0) { $0 + $1.rows.count }
    }

    /// Whether any selected block has row geometry.
    static func hasAnyRowGeometry(_ paddocks: [Paddock]) -> Bool {
        paddocks.contains { !$0.rows.isEmpty }
    }

    /// Available start paths across the full selection. For each actual row
    /// number N we contribute paths N-0.5 (before/between) and N+0.5 (after).
    static func availablePaths(in paddocks: [Paddock]) -> [Double] {
        let numbers = selectedRowNumbers(in: paddocks)
        guard !numbers.isEmpty else { return [0.5] }
        var set = Set<Double>()
        for n in numbers {
            set.insert(Double(n) - 0.5)
            set.insert(Double(n) + 0.5)
        }
        return set.sorted()
    }

    /// Clamp + snap a start path to a valid value within `availablePaths`.
    static func clampedStartPath(_ value: Double, paddocks: [Paddock]) -> Double {
        let paths = availablePaths(in: paddocks)
        guard let first = paths.first, let last = paths.last else { return value }
        var p = value
        if p < first { p = first }
        if p > last { p = last }
        let rounded = (p - 0.5).rounded() + 0.5
        if abs(rounded - p) > 0.01 {
            p = min(max(rounded, first), last)
        }
        return p
    }

    /// Default start path when nothing has been chosen — the very first path
    /// of the selection (e.g. `minRow - 0.5`).
    static func defaultStartPath(in paddocks: [Paddock]) -> Double {
        availablePaths(in: paddocks).first ?? 0.5
    }

    /// Format a path value with a single decimal where required ("1", "1.5").
    static func formatPath(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    /// Friendly label for a path in a picker menu, e.g.
    /// "Path before row 69 — 68.5" or "Between rows 12–13 — 12.5".
    static func pathMenuLabel(_ path: Double, paddocks: [Paddock]) -> String {
        let pathStr = formatPath(path)
        let numbers = selectedRowNumbers(in: paddocks)
        let lo = numbers.first ?? 1
        let hi = numbers.last ?? 0
        if !numbers.isEmpty, path < Double(lo) {
            return "Path before row \(lo) — \(pathStr)"
        }
        if !numbers.isEmpty, path > Double(hi) {
            return "Path after row \(hi) — \(pathStr)"
        }
        let lower = Int(floor(path))
        let upper = lower + 1
        return "Between rows \(lower)\u{2013}\(upper) — \(pathStr)"
    }

    /// Combined row range label like "Rows 69–108" or "Rows not configured".
    static func combinedRangeLabel(_ paddocks: [Paddock]) -> String {
        let numbers = selectedRowNumbers(in: paddocks)
        guard let lo = numbers.first, let hi = numbers.last else {
            return "Rows not configured"
        }
        if lo == hi { return "Row \(lo)" }
        return "Rows \(lo)\u{2013}\(hi)"
    }

    /// Combined paths label like "Paths 0.5–108.5".
    static func combinedPathsLabel(_ paddocks: [Paddock]) -> String {
        let paths = availablePaths(in: paddocks)
        guard let lo = paths.first, let hi = paths.last else { return "" }
        return "Paths \(formatPath(lo))\u{2013}\(formatPath(hi))"
    }

    /// Build a compact row-range label from a sorted list of actual row numbers.
    static func compactRowRangeLabel(_ numbers: [Int]) -> String {
        guard let lo = numbers.first, let hi = numbers.last else { return "Rows" }
        var segments: [(Int, Int)] = []
        var segStart = lo
        var prev = lo
        for n in numbers.dropFirst() {
            if n == prev + 1 {
                prev = n
            } else {
                segments.append((segStart, prev))
                segStart = n
                prev = n
            }
        }
        segments.append((segStart, prev))
        if segments.count == 1 {
            return lo == hi ? "Row \(lo)" : "Rows \(lo)\u{2013}\(hi)"
        }
        if segments.count <= 2 {
            let parts = segments.map { $0.0 == $0.1 ? "\($0.0)" : "\($0.0)\u{2013}\($0.1)" }
            return "Rows " + parts.joined(separator: ", ")
        }
        return "Rows \(lo)\u{2013}\(hi)"
    }

    /// Generate the full traversal sequence for the given pattern, start path,
    /// and direction across all selected paddocks. Returns paths expressed as
    /// real row numbers (e.g. `68.5`, `69.5`, …), matching what `Trip.rowSequence`
    /// expects.
    ///
    /// Every produced value is a member of `availablePaths(in:)` — the pattern
    /// walks *indices into that set*, so it can never invent a path above or
    /// below the selection, and never fabricates paths through row-number gaps
    /// in a non-contiguous multi-block selection.
    static func generateSequence(
        paddocks: [Paddock],
        pattern: TrackingPattern,
        startPath: Double,
        directionHigherFirst: Bool
    ) -> [Double] {
        guard combinedTotalRows(in: paddocks) > 0 else { return [] }
        return plannedSequence(
            paths: availablePaths(in: paddocks),
            pattern: pattern,
            startPath: startPath,
            higherFirst: directionHigherFirst
        )
    }

    /// The authoritative planner. `paths` is the universe of valid paths; the
    /// returned sequence is drawn entirely from it.
    ///
    /// Patterns operate on *indices* into the direction-ordered, start-rotated
    /// universe rather than on arithmetic over path values, so `startPath + 5`
    /// can never name a path that does not exist.
    static func plannedSequence(
        paths: [Double],
        pattern: TrackingPattern,
        startPath: Double,
        higherFirst: Bool
    ) -> [Double] {
        guard pattern != .freeDrive, !paths.isEmpty else { return [] }

        // Every Second Row already planned against the explicit valid path set;
        // that behaviour is preserved verbatim.
        if pattern == .everySecondRow {
            return everySecondRowSequence(
                paths: paths,
                startPath: startPath,
                higherFirst: higherFirst
            )
        }

        let ordered = orderedTraversal(paths: paths, startPath: startPath, higherFirst: higherFirst)
        guard !ordered.isEmpty else { return [] }

        switch pattern {
        case .sequential, .custom:
            return ordered
        case .upAndBack:
            return ordered.flatMap { [$0, $0] }
        case .fiveThree:
            return indexed(ordered, by: fiveThreeIndices(count: ordered.count))
        case .twoRowUpBack:
            return indexed(ordered, by: twoRowUpBackIndices(count: ordered.count))
        case .everySecondRow, .freeDrive:
            return ordered
        }
    }

    /// The valid path universe ordered by traversal direction and rotated so
    /// the selected start path is first.
    ///
    /// `higherFirst` mirrors the picker: `true` = "Lower to higher" (ascending),
    /// `false` = "Higher to lower" (descending). Rotation — rather than
    /// clamping — is what preserves full coverage from a mid-block start.
    static func orderedTraversal(
        paths: [Double],
        startPath: Double,
        higherFirst: Bool
    ) -> [Double] {
        guard !paths.isEmpty else { return [] }
        let sorted = higherFirst ? paths.sorted() : paths.sorted(by: >)
        guard let idx = nearestIndex(in: sorted, to: startPath) else { return sorted }
        return Array(sorted[idx...]) + Array(sorted[..<idx])
    }

    /// Index of the path closest to `value`. The start path is clamped/snapped
    /// before it reaches here; this is the final guarantee that traversal
    /// begins on a real member of the universe.
    private static func nearestIndex(in ordered: [Double], to value: Double) -> Int? {
        guard let first = ordered.first else { return nil }
        var best = 0
        var bestDelta = abs(first - value)
        for (i, p) in ordered.enumerated() {
            let delta = abs(p - value)
            if delta < bestDelta {
                best = i
                bestDelta = delta
            }
        }
        return best
    }

    private static func indexed(_ ordered: [Double], by indices: [Int]) -> [Double] {
        indices.compactMap { $0 >= 0 && $0 < ordered.count ? ordered[$0] : nil }
    }

    /// 3/5 pattern in index space: startup 0, +3, +1, +5, +2 then alternating
    /// +5 / -3, finally sweeping up whatever the walk missed.
    private static func fiveThreeIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var indices: [Int] = []
        var visited = Set<Int>()

        for offset in [0, 3, 1, 5, 2] where offset < count && !visited.contains(offset) {
            indices.append(offset)
            visited.insert(offset)
        }

        if var current = indices.last {
            var usePlusFive = true
            while true {
                let next = usePlusFive ? current + 5 : current - 3
                if next < 0 || next >= count || visited.contains(next) { break }
                indices.append(next)
                visited.insert(next)
                current = next
                usePlusFive.toggle()
            }
        }

        for i in 0..<count where !visited.contains(i) { indices.append(i) }
        return indices
    }

    /// 2 Row Up & Back in index space: out on every 4th path from offset 1,
    /// back on every 4th from offset 3, then the remainder in traversal order.
    private static func twoRowUpBackIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var indices: [Int] = []
        var visited = Set<Int>()

        var i = 1
        while i < count {
            indices.append(i)
            visited.insert(i)
            i += 4
        }

        var back: [Int] = []
        i = 3
        while i < count {
            back.append(i)
            i += 4
        }
        for j in back.reversed() where !visited.contains(j) {
            indices.append(j)
            visited.insert(j)
        }

        for k in 0..<count where !visited.contains(k) { indices.append(k) }
        return indices
    }

    /// Every Second Row, parity-preserving sequence across the combined paths.
    static func everySecondRowSequence(
        paths: [Double],
        startPath: Double,
        higherFirst: Bool
    ) -> [Double] {
        guard !paths.isEmpty else { return [] }
        let sorted = paths.sorted()
        let sameParity = sorted.filter { p in
            let diff = Int(round(p - startPath))
            return diff % 2 == 0
        }
        guard !sameParity.isEmpty else { return [] }
        if higherFirst {
            let firstRun = sameParity.filter { $0 >= startPath }.sorted()
            let wrap = sameParity.filter { $0 < startPath }.sorted()
            return firstRun + wrap
        } else {
            let firstRun = sameParity.filter { $0 <= startPath }.sorted(by: >)
            let wrap = sameParity.filter { $0 > startPath }.sorted(by: >)
            return firstRun + wrap
        }
    }

    /// Short preview text for the Proposed Row Sequence card. Caps to the
    /// first `maxItems` and adds an ellipsis when truncated.
    static func sequencePreviewText(_ sequence: [Double], maxItems: Int = 10) -> String {
        let preview = sequence.prefix(maxItems).map { formatPath($0) }
        let joined = preview.joined(separator: " → ")
        return sequence.count > maxItems ? joined + " → …" : joined
    }

    /// Human-readable explanation of how a pattern walks the paths. `nil`
    /// for Free Drive (no planned sequence).
    static func patternPreviewNote(_ pattern: TrackingPattern) -> String? {
        switch pattern {
        case .sequential:
            return "Sequential: walks every path one-by-one in the chosen direction."
        case .everySecondRow:
            return "Every Second Row: advances by +2 in the chosen direction, then wraps to cover the remaining same-parity paths."
        case .fiveThree:
            return "5/3 pattern: skips ahead 5, back 3, repeating from the chosen start."
        case .upAndBack:
            return "Up and Back: traverses then reverses, covering each path once."
        case .twoRowUpBack:
            return "Two Row Up & Back: pairs of rows, advancing then returning."
        case .custom:
            return "Custom pattern: generated from the chosen start and direction."
        case .freeDrive:
            return nil
        }
    }
}
