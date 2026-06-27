import Foundation
import CoreLocation

/// Maps a multi-block selection into a single global row/path index, sorted in
/// the same order used by `StartTripSheet` (lowest local row first, then by
/// name). Used at runtime by Active Trip to convert a local row hit inside a
/// paddock into a global path number that lines up with `trip.rowSequence`.
///
/// The global row numbering preserves each paddock's actual `row.number`
/// values rather than re-numbering from 1. This means a single-block trip on a
/// block whose rows are 69–108 produces sequence paths around 68.5–108.5, and
/// the operator sees the real row labels in Active Trip.
nonisolated struct GlobalRowIndex: Sendable {
    struct Entry: Sendable, Hashable {
        let paddockId: UUID
        let paddockName: String
        /// Smallest actual `row.number` in this paddock.
        let globalRowStart: Int
        /// Largest actual `row.number` in this paddock.
        let globalRowEnd: Int
        /// Smallest local row number — same as `globalRowStart` because we
        /// preserve actual row numbers across the selection.
        let localRowStart: Int
        let rowCount: Int
    }

    let entries: [Entry]
    /// Total distinct rows across the selection (sum of each paddock's row
    /// count).
    let totalRows: Int
    /// Sorted set of actual row numbers contributed by the selection. Useful
    /// for building the available-path list.
    let allRowNumbers: [Int]

    init(paddocks: [Paddock]) {
        let sorted = paddocks.sorted { a, b in
            let aMin = a.rows.map(\.number).min() ?? Int.max
            let bMin = b.rows.map(\.number).min() ?? Int.max
            if aMin != bMin { return aMin < bMin }
            return a.name.lowercased() < b.name.lowercased()
        }

        var built: [Entry] = []
        var allNumbers: [Int] = []
        for paddock in sorted {
            let numbers = paddock.rows.map(\.number)
            guard let lo = numbers.min(), let hi = numbers.max() else { continue }
            built.append(Entry(
                paddockId: paddock.id,
                paddockName: paddock.name,
                globalRowStart: lo,
                globalRowEnd: hi,
                localRowStart: lo,
                rowCount: numbers.count
            ))
            allNumbers.append(contentsOf: numbers)
        }
        self.entries = built
        self.totalRows = allNumbers.count
        self.allRowNumbers = Array(Set(allNumbers)).sorted()
    }

    /// Find which entry contains the given global row number.
    func entry(forGlobalRow globalRow: Int) -> Entry? {
        entries.first { globalRow >= $0.globalRowStart && globalRow <= $0.globalRowEnd }
    }

    /// Convert a local row inside a paddock to a global row number.
    /// Because we preserve actual row numbers, this is the identity for any
    /// row that exists in the named paddock.
    func globalRow(paddockId: UUID, localRow: Int) -> Int? {
        guard let entry = entries.first(where: { $0.paddockId == paddockId }) else { return nil }
        guard localRow >= entry.globalRowStart && localRow <= entry.globalRowEnd else { return nil }
        return localRow
    }
}
