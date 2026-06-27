import Foundation

/// Pure helpers for the Block / Row Infrastructure Calculator.
///
/// Mirrors the computed properties on `Paddock` (areaHectares,
/// totalRowLengthMetres, estimatedVineCount, emitter / post / flow
/// derivations) so the website can compute the same values from raw
/// numeric inputs without depending on `Paddock`, `CoreLocation`, or
/// the iOS data store.
///
/// The live `Paddock` extension still owns the in-app values; this
/// file is additive and does not change behaviour.
nonisolated enum RowInfrastructureCalculator {
    // MARK: - Geometry

    nonisolated struct LatLon: Sendable, Hashable {
        public let latitude: Double
        public let longitude: Double
        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// Polygon area in hectares using a local equirectangular
    /// projection (matches `Paddock.areaHectares`).
    /// - Returns: 0 when fewer than 3 points.
    static func areaHectares(polygon: [LatLon]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        let centroidLat = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count)
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        var area = 0.0
        let n = polygon.count
        for i in 0..<n {
            let j = (i + 1) % n
            let xi = polygon[i].longitude * mPerDegLon
            let yi = polygon[i].latitude * mPerDegLat
            let xj = polygon[j].longitude * mPerDegLon
            let yj = polygon[j].latitude * mPerDegLat
            area += xi * yj - xj * yi
        }
        area = abs(area) / 2.0
        return area / 10_000.0
    }

    /// Length in metres of a single row segment (start → end) using
    /// the same equirectangular approximation as `Paddock.totalRowLengthMetres`.
    static func rowLengthMetres(start: LatLon, end: LatLon, centroidLatitude: Double) -> Double {
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centroidLatitude * .pi / 180.0)
        let dLat = (end.latitude - start.latitude) * mPerDegLat
        let dLon = (end.longitude - start.longitude) * mPerDegLon
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// Sum of all row segment lengths.
    static func totalRowLengthMetres(rows: [(start: LatLon, end: LatLon)], polygon: [LatLon]) -> Double {
        let centroidLat = polygon.isEmpty ? 0 : polygon.map(\.latitude).reduce(0, +) / Double(polygon.count)
        return rows.reduce(0) { $0 + rowLengthMetres(start: $1.start, end: $1.end, centroidLatitude: centroidLat) }
    }

    // MARK: - Vine counts

    /// Estimated vine count from row length and vine spacing.
    /// `effectiveTotalRowLength = rowLengthOverride ?? totalRowLengthMetres`.
    static func estimatedVineCount(effectiveTotalRowLength: Double, vineSpacing: Double) -> Int {
        guard vineSpacing > 0 else { return 0 }
        return Int(effectiveTotalRowLength / vineSpacing)
    }

    /// Effective vine count: operator override wins, otherwise
    /// estimated from spacing.
    static func effectiveVineCount(
        vineCountOverride: Int?,
        effectiveTotalRowLength: Double,
        vineSpacing: Double
    ) -> Int {
        if let v = vineCountOverride { return v }
        return estimatedVineCount(effectiveTotalRowLength: effectiveTotalRowLength, vineSpacing: vineSpacing)
    }

    // MARK: - Irrigation infrastructure

    /// Emitters per hectare = `10_000 / (rowSpacing × emitterSpacing)`.
    static func emittersPerHectare(rowSpacing: Double, emitterSpacing: Double) -> Double? {
        guard rowSpacing > 0, emitterSpacing > 0 else { return nil }
        return 10_000.0 / (rowSpacing * emitterSpacing)
    }

    /// Litres / ha / hour = emittersPerHa × flowPerEmitter.
    static func litresPerHaPerHour(rowSpacing: Double, emitterSpacing: Double, flowPerEmitter: Double) -> Double? {
        guard let eph = emittersPerHectare(rowSpacing: rowSpacing, emitterSpacing: emitterSpacing) else { return nil }
        return eph * flowPerEmitter
    }

    /// mm / hour ≈ litresPerHaPerHour × 100 / 1_000_000 (matches Paddock.mmPerHour).
    static func mmPerHour(rowSpacing: Double, emitterSpacing: Double, flowPerEmitter: Double) -> Double? {
        guard let lph = litresPerHaPerHour(rowSpacing: rowSpacing, emitterSpacing: emitterSpacing, flowPerEmitter: flowPerEmitter) else { return nil }
        return (lph / 1_000_000.0) * 100.0
    }

    /// Total litres per hour for a block: `(effectiveTotalRowLength / emitterSpacing) × flowPerEmitter`.
    static func litresPerHour(effectiveTotalRowLength: Double, emitterSpacing: Double, flowPerEmitter: Double) -> Double? {
        guard emitterSpacing > 0, flowPerEmitter > 0, effectiveTotalRowLength > 0 else { return nil }
        return (effectiveTotalRowLength / emitterSpacing) * flowPerEmitter
    }

    /// Total emitters across a block.
    static func totalEmitters(effectiveTotalRowLength: Double, emitterSpacing: Double) -> Int? {
        guard emitterSpacing > 0 else { return nil }
        return Int(effectiveTotalRowLength / emitterSpacing)
    }

    /// Litres per vine per hour = (vineSpacing / emitterSpacing) × flowPerEmitter.
    static func litresPerVinePerHour(vineSpacing: Double, emitterSpacing: Double, flowPerEmitter: Double) -> Double? {
        guard emitterSpacing > 0, vineSpacing > 0, flowPerEmitter > 0 else { return nil }
        return (vineSpacing / emitterSpacing) * flowPerEmitter
    }

    // MARK: - Posts

    /// Intermediate post count, excluding the 2 end posts on each row.
    /// Matches `Paddock.intermediatePostCount`.
    static func intermediatePostCount(
        effectiveTotalRowLength: Double,
        intermediatePostSpacing: Double,
        rowCount: Int
    ) -> Int? {
        guard intermediatePostSpacing > 0, effectiveTotalRowLength > 0 else { return nil }
        let rawPosts = Int(effectiveTotalRowLength / intermediatePostSpacing)
        let endPosts = 2 * rowCount
        return max(0, rawPosts - endPosts)
    }
}
