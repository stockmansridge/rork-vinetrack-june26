import Foundation
import CoreLocation

/// Lightweight, backend-neutral helpers for paddock/row detection during a trip.
/// Pure functions — no @MainActor state, no network, no persistence.

nonisolated struct RowMatch: Sendable, Hashable {
    let rowNumber: Double
    /// Perpendicular distance from the location to the row centreline, in metres.
    let distance: Double
}

nonisolated enum RowGuidance {

    // MARK: - Public API

    /// Returns the paddock whose polygon contains the coordinate, if any.
    /// Falls back to the closest paddock by centroid distance when the
    /// coordinate is outside every polygon (within `fallbackRadius` metres).
    static func paddock(
        for coordinate: CLLocationCoordinate2D,
        in paddocks: [Paddock],
        fallbackRadius: Double = 50
    ) -> Paddock? {
        for paddock in paddocks {
            let polygon = paddock.polygonPoints.map { $0.coordinate }
            if polygon.count >= 3, isPointInPolygon(point: coordinate, polygon: polygon) {
                return paddock
            }
        }

        var closest: (Paddock, Double)?
        for paddock in paddocks where !paddock.polygonPoints.isEmpty {
            let centroid = polygonCentroid(paddock.polygonPoints.map { $0.coordinate })
            let distance = metresBetween(centroid, coordinate)
            if distance <= fallbackRadius {
                if let current = closest {
                    if distance < current.1 {
                        closest = (paddock, distance)
                    }
                } else {
                    closest = (paddock, distance)
                }
            }
        }
        return closest?.0
    }

    /// Finds the nearest row in the paddock to the given coordinate.
    /// Prefers explicit `paddock.rows` geometry; falls back to a synthetic row
    /// grid derived from `rowDirection`, `rowWidth`, and the polygon shape.
    static func nearestRow(
        for coordinate: CLLocationCoordinate2D,
        in paddock: Paddock
    ) -> RowMatch? {
        if !paddock.rows.isEmpty {
            return nearestExplicitRow(for: coordinate, rows: paddock.rows)
        }
        return nearestSyntheticRow(for: coordinate, paddock: paddock)
    }

    /// Returns the set of distinct row numbers covered by a path.
    /// A row is considered covered when at least one path point falls within
    /// `paddock.rowWidth / 2` metres of the row centreline.
    static func coveredRows(
        for path: [CoordinatePoint],
        in paddock: Paddock
    ) -> [Double] {
        guard !path.isEmpty else { return [] }
        let threshold = max(0.5, paddock.rowWidth / 2.0)
        var covered: Set<Double> = []
        for point in path {
            if let match = nearestRow(for: point.coordinate, in: paddock),
               match.distance <= threshold {
                covered.insert(match.rowNumber)
            }
        }
        return covered.sorted()
    }

    // MARK: - Explicit rows

    private static func nearestExplicitRow(
        for coordinate: CLLocationCoordinate2D,
        rows: [PaddockRow]
    ) -> RowMatch? {
        var best: RowMatch?
        for row in rows {
            let distance = perpendicularDistanceMetres(
                point: coordinate,
                segmentStart: row.startPoint.coordinate,
                segmentEnd: row.endPoint.coordinate
            )
            if best == nil || distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = RowMatch(rowNumber: Double(row.number), distance: distance)
            }
        }
        return best
    }

    // MARK: - Synthetic rows

    private static func nearestSyntheticRow(
        for coordinate: CLLocationCoordinate2D,
        paddock: Paddock
    ) -> RowMatch? {
        let polygon = paddock.polygonPoints.map { $0.coordinate }
        guard polygon.count >= 3, paddock.rowWidth > 0 else { return nil }

        let count = estimatedRowCount(for: paddock)
        guard count > 0 else { return nil }

        let lines = calculateRowLines(
            polygonCoords: polygon,
            direction: paddock.rowDirection,
            count: count,
            width: paddock.rowWidth,
            offset: paddock.rowOffset
        )
        guard !lines.isEmpty else { return nil }

        var best: RowMatch?
        for (index, line) in lines.enumerated() {
            let distance = perpendicularDistanceMetres(
                point: coordinate,
                segmentStart: line.start,
                segmentEnd: line.end
            )
            if best == nil || distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = RowMatch(rowNumber: Double(index + 1), distance: distance)
            }
        }
        return best
    }

    private static func estimatedRowCount(for paddock: Paddock) -> Int {
        let polygon = paddock.polygonPoints.map { $0.coordinate }
        guard polygon.count >= 3, paddock.rowWidth > 0 else { return 0 }
        let centroidLat = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count)
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        let bearingRad = paddock.rowDirection * .pi / 180.0
        let perpRad = bearingRad + .pi / 2.0
        let nx = cos(perpRad)
        let ny = sin(perpRad)
        var minProj = Double.greatestFiniteMagnitude
        var maxProj = -Double.greatestFiniteMagnitude
        for p in polygon {
            let dx = (p.latitude - centroidLat) * mPerDegLat
            let dy = (p.longitude - polygon[0].longitude) * mPerDegLon
            let proj = dx * nx + dy * ny
            minProj = min(minProj, proj)
            maxProj = max(maxProj, proj)
        }
        let span = max(0, maxProj - minProj)
        let count = Int(span / paddock.rowWidth)
        return max(0, min(count, 1000))
    }

    // MARK: - Geometry primitives

    static func isPointInPolygon(
        point: CLLocationCoordinate2D,
        polygon: [CLLocationCoordinate2D]
    ) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        let n = polygon.count
        var j = n - 1
        for i in 0..<n {
            let xi = polygon[i].longitude
            let yi = polygon[i].latitude
            let xj = polygon[j].longitude
            let yj = polygon[j].latitude
            let intersect = ((yi > point.latitude) != (yj > point.latitude)) &&
                (point.longitude < (xj - xi) * (point.latitude - yi) / ((yj - yi) == 0 ? 1e-12 : (yj - yi)) + xi)
            if intersect { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Project a coordinate onto the row line of `rowNumber` in `paddock`,
    /// returning the snapped coordinate and the along-row distance (m)
    /// from the row start. Returns nil when the row geometry isn't
    /// available or the row is degenerate.
    static func snapToRow(
        coordinate: CLLocationCoordinate2D,
        rowNumber: Int,
        in paddock: Paddock
    ) -> (snapped: CLLocationCoordinate2D, distanceAlongMetres: Double, rowLengthMetres: Double)? {
        guard let row = paddock.rows.first(where: { $0.number == rowNumber }) else {
            return nil
        }
        return snap(
            coordinate: coordinate,
            start: row.startPoint.coordinate,
            end: row.endPoint.coordinate
        )
    }

    /// Project a coordinate onto the row centreline implied by an X.5
    /// path number (the path between rows X and X+1). The snapped point
    /// is on the geometric mid-line between the two rows.
    static func snapToPath(
        coordinate: CLLocationCoordinate2D,
        path: Double,
        in paddock: Paddock
    ) -> (snapped: CLLocationCoordinate2D, distanceAlongMetres: Double, rowLengthMetres: Double)? {
        let lower = Int(floor(path))
        let upper = Int(ceil(path))
        guard let r1 = paddock.rows.first(where: { $0.number == lower }) ?? paddock.rows.first(where: { $0.number == upper }) else {
            return nil
        }
        // If we have both neighbours, use their midline; otherwise snap
        // to whichever single row is available.
        if lower != upper,
           let r2 = paddock.rows.first(where: { $0.number == upper }),
           let r1Strict = paddock.rows.first(where: { $0.number == lower }) {
            let start = midpoint(r1Strict.startPoint.coordinate, r2.startPoint.coordinate)
            let end = midpoint(r1Strict.endPoint.coordinate, r2.endPoint.coordinate)
            return snap(coordinate: coordinate, start: start, end: end)
        }
        return snap(coordinate: coordinate, start: r1.startPoint.coordinate, end: r1.endPoint.coordinate)
    }

    /// Project `coordinate` onto the segment `start`→`end`. Returns the
    /// snapped point, along-segment distance from `start`, and the
    /// segment length in metres.
    private static func snap(
        coordinate: CLLocationCoordinate2D,
        start a: CLLocationCoordinate2D,
        end b: CLLocationCoordinate2D
    ) -> (snapped: CLLocationCoordinate2D, distanceAlongMetres: Double, rowLengthMetres: Double)? {
        let centroidLat = (a.latitude + b.latitude + coordinate.latitude) / 3.0
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)

        let ax = a.longitude * mPerDegLon
        let ay = a.latitude * mPerDegLat
        let bx = b.longitude * mPerDegLon
        let by = b.latitude * mPerDegLat
        let px = coordinate.longitude * mPerDegLon
        let py = coordinate.latitude * mPerDegLat

        let dx = bx - ax
        let dy = by - ay
        let lenSq = dx * dx + dy * dy
        guard lenSq > 1e-6 else { return nil }
        let length = sqrt(lenSq)
        var t = ((px - ax) * dx + (py - ay) * dy) / lenSq
        t = max(0, min(1, t))
        let cx = ax + t * dx
        let cy = ay + t * dy
        let snapped = CLLocationCoordinate2D(
            latitude: cy / mPerDegLat,
            longitude: cx / mPerDegLon
        )
        return (snapped, t * length, length)
    }

    private static func midpoint(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (a.latitude + b.latitude) / 2.0,
            longitude: (a.longitude + b.longitude) / 2.0
        )
    }

    static func metresBetween(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        let la = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let lb = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return la.distance(from: lb)
    }

    static func polygonCentroid(_ polygon: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !polygon.isEmpty else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        let lat = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count)
        let lon = polygon.map(\.longitude).reduce(0, +) / Double(polygon.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func perpendicularDistanceMetres(
        point: CLLocationCoordinate2D,
        segmentStart a: CLLocationCoordinate2D,
        segmentEnd b: CLLocationCoordinate2D
    ) -> Double {
        let centroidLat = (a.latitude + b.latitude + point.latitude) / 3.0
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)

        let ax = a.longitude * mPerDegLon
        let ay = a.latitude * mPerDegLat
        let bx = b.longitude * mPerDegLon
        let by = b.latitude * mPerDegLat
        let px = point.longitude * mPerDegLon
        let py = point.latitude * mPerDegLat

        let dx = bx - ax
        let dy = by - ay
        let lenSq = dx * dx + dy * dy
        guard lenSq > 1e-9 else {
            let ex = px - ax
            let ey = py - ay
            return sqrt(ex * ex + ey * ey)
        }
        var t = ((px - ax) * dx + (py - ay) * dy) / lenSq
        t = max(0, min(1, t))
        let cx = ax + t * dx
        let cy = ay + t * dy
        let ex = px - cx
        let ey = py - cy
        return sqrt(ex * ex + ey * ey)
    }
}
