import Foundation

extension Trip {
    nonisolated func withOccurrenceProjection(_ coverage: TripOccurrenceCoverage.JSON) throws -> Trip {
        let d = try TripOccurrenceCoverage.requireDocument(coverage)
        var trip = self
        trip.occurrenceCoverage = coverage
        trip.completedPaths = []; trip.skippedPaths = []
        trip.rowSequence = d.activeOrder.compactMap { id in d.items.first { $0.occurrenceId == id }?.pathNumber }
        trip.sequenceIndex = d.plannedCursorId.flatMap { d.activeOrder.firstIndex(of: $0) } ?? d.activeOrder.count
        // Scalars are display projections only. The optional IDs remain authority when no work remains.
        if let current = d.items.first(where: { $0.occurrenceId == d.targetId }) { trip.currentRowNumber = current.pathNumber }
        if let next = d.activeOrder.first(where: { $0 != d.targetId && d.states[$0]?.status == "incomplete" }),
           let item = d.items.first(where: { $0.occurrenceId == next }) { trip.nextRowNumber = item.pathNumber }
        return trip
    }
}
