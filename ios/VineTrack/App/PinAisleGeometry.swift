import Foundation
import CoreLocation

/// Pure geometry for the core pin-location contract: which aisle (inter-row
/// driving path) an operator occupies, and which of that aisle's two physically
/// adjacent vine rows lies on their Left vs Right.
///
/// Everything here is derived from mapped row geometry and a validated heading.
/// Row-number ordering is never assumed — Left is not "the lower number", it is
/// whichever adjacent row actually sits to the operator's left.
///
/// Pure functions only. No store, no @MainActor, no I/O.
nonisolated enum PinAisleGeometry {

    /// The two physically adjacent rows bounding the operator's aisle.
    struct Aisle: Sendable, Equatable {
        /// Driving path identifier, the mean of the two adjacent row numbers
        /// (rows 32 and 33 -> 32.5). Derived from geometry, never assumed.
        let aisleNumber: Double
        /// Row whose centreline is nearest the fix.
        let nearRowNumber: Int
        /// Row on the far side of the fix, bounding the same aisle.
        let farRowNumber: Int
    }

    /// A row selected for a given operator side, with its snap onto that row's
    /// own centreline (never the aisle midline).
    struct RowSelection: Sendable {
        let rowNumber: Int
        let snapped: CLLocationCoordinate2D
        let distanceAlongMetres: Double
    }

    /// Minimum offset from a row centreline before an aisle can be claimed.
    /// A fix sitting essentially on the vine row itself does not establish
    /// which of the two neighbouring aisles the operator occupied.
    static let minimumAisleOffsetMetres: Double = 0.15

    /// Fallback aisle width ceiling when the block records no row spacing.
    static let fallbackMaxAisleWidthMetres: Double = 12.0

    /// True when `heading` is a usable recorded facing. A genuine 0° (North) is
    /// valid; nil, non-finite and out-of-range values are not turned into North.
    static func validHeading(_ heading: Double?) -> Double? {
        guard let heading, heading.isFinite, heading >= -0.0001, heading <= 360.0001 else {
            return nil
        }
        return normalizedDegrees(heading)
    }

    /// Resolve the aisle physically containing `coordinate`: the nearest mapped
    /// row plus the nearest row on the opposite side of the fix, provided they
    /// are close enough to be a real aisle. Returns nil when the block has no
    /// mapped rows, the fix sits on a row centreline, the fix is outside the
    /// mapped rows (headland) or no plausible neighbour exists.
    static func aisle(
        containing coordinate: CLLocationCoordinate2D,
        in paddock: Paddock
    ) -> Aisle? {
        let rows = paddock.rows
        guard rows.count >= 2 else { return nil }

        let frame = MetricFrame(around: coordinate)
        let point = frame.project(coordinate)

        // Nearest row and its closest point to the fix.
        var nearest: (row: PaddockRow, closest: Point, distance: Double)?
        for row in rows {
            let a = frame.project(row.startPoint.coordinate)
            let b = frame.project(row.endPoint.coordinate)
            guard let closest = closestPoint(on: a, b, to: point) else { continue }
            let distance = closest.distance(to: point)
            if nearest == nil || distance < (nearest?.distance ?? .greatestFiniteMagnitude) {
                nearest = (row, closest, distance)
            }
        }
        guard let near = nearest, near.distance >= minimumAisleOffsetMetres else { return nil }

        // Axis: the outward direction from the nearest row towards the fix.
        let axis = Point(x: point.x - near.closest.x, y: point.y - near.closest.y)
            .normalized()
        guard let axis else { return nil }
        let fixOffset = near.distance

        // The aisle's far side is the closest row lying beyond the fix along
        // that same axis. Angled rows are handled because each candidate is
        // measured at its own closest point to the fix.
        var far: (row: PaddockRow, closest: Point, offset: Double)?
        for row in rows where row.number != near.row.number {
            let a = frame.project(row.startPoint.coordinate)
            let b = frame.project(row.endPoint.coordinate)
            guard let closest = closestPoint(on: a, b, to: point) else { continue }
            let offset = (closest.x - near.closest.x) * axis.x + (closest.y - near.closest.y) * axis.y
            guard offset > fixOffset else { continue }
            if far == nil || offset < (far?.offset ?? .greatestFiniteMagnitude) {
                far = (row, closest, offset)
            }
        }
        guard let far else { return nil }

        // Reject implausibly wide pairs: a missing neighbour must never be
        // invented by pairing two rows that don't actually form one aisle.
        let maxWidth = paddock.rowWidth > 0 ? paddock.rowWidth * 2.5 : fallbackMaxAisleWidthMetres
        guard far.offset <= maxWidth else { return nil }

        return Aisle(
            aisleNumber: (Double(near.row.number) + Double(far.row.number)) / 2.0,
            nearRowNumber: near.row.number,
            farRowNumber: far.row.number
        )
    }

    /// Choose which of two candidate rows lies on the operator's `side` given a
    /// validated `heading`, then snap the fix onto that row's own centreline.
    ///
    /// Returns nil when the heading is unusable or the candidate geometry is
    /// missing — an unconfirmed side is never guessed.
    static func rowOnSide(
        rowNumbers: (Int, Int),
        coordinate: CLLocationCoordinate2D,
        heading: Double?,
        operatorSide: PinSide,
        in paddock: Paddock
    ) -> RowSelection? {
        guard let heading = validHeading(heading) else { return nil }
        guard let first = paddock.rows.first(where: { $0.number == rowNumbers.0 }),
              let second = paddock.rows.first(where: { $0.number == rowNumbers.1 }),
              first.number != second.number
        else { return nil }

        let frame = MetricFrame(around: coordinate)
        let point = frame.project(coordinate)
        guard let firstClosest = closestPoint(
            on: frame.project(first.startPoint.coordinate),
            frame.project(first.endPoint.coordinate),
            to: point
        ), let secondClosest = closestPoint(
            on: frame.project(second.startPoint.coordinate),
            frame.project(second.endPoint.coordinate),
            to: point
        ) else { return nil }

        let leftBearing = normalizedDegrees(heading - 90)
        let firstBearing = bearing(from: point, to: firstClosest)
        let secondBearing = bearing(from: point, to: secondClosest)
        guard let firstBearing, let secondBearing else { return nil }

        let firstIsLeft = abs(signedAngularDifference(firstBearing, leftBearing)) < 90
        let secondIsLeft = abs(signedAngularDifference(secondBearing, leftBearing)) < 90
        // The two rows must genuinely lie on opposite sides of the operator.
        guard firstIsLeft != secondIsLeft else { return nil }

        let chosen: PaddockRow = {
            switch operatorSide {
            case .left: return firstIsLeft ? first : second
            case .right: return firstIsLeft ? second : first
            }
        }()

        guard let snap = RowGuidance.snapToRow(
            coordinate: coordinate,
            rowNumber: chosen.number,
            in: paddock
        ) else { return nil }

        return RowSelection(
            rowNumber: chosen.number,
            snapped: snap.snapped,
            distanceAlongMetres: snap.distanceAlongMetres
        )
    }

    /// The two vine rows bounding an explicit driving path (e.g. 32.5 -> 32 and
    /// 33). Returns nil unless both rows exist in the block's mapped geometry.
    static func rowsBounding(path: Double, in paddock: Paddock) -> (Int, Int)? {
        let lower = Int(floor(path))
        let upper = Int(ceil(path))
        guard lower != upper else { return nil }
        guard paddock.rows.contains(where: { $0.number == lower }),
              paddock.rows.contains(where: { $0.number == upper })
        else { return nil }
        return (lower, upper)
    }

    // MARK: - Local metric frame

    private struct Point {
        /// Metres east of the frame origin.
        let x: Double
        /// Metres north of the frame origin.
        let y: Double

        func distance(to other: Point) -> Double {
            let dx = x - other.x
            let dy = y - other.y
            return (dx * dx + dy * dy).squareRoot()
        }

        func normalized() -> Point? {
            let length = (x * x + y * y).squareRoot()
            guard length > 1e-9 else { return nil }
            return Point(x: x / length, y: y / length)
        }
    }

    private struct MetricFrame {
        let originLat: Double
        let originLon: Double
        let metresPerDegreeLat: Double = 111_320.0
        let metresPerDegreeLon: Double

        init(around coordinate: CLLocationCoordinate2D) {
            originLat = coordinate.latitude
            originLon = coordinate.longitude
            metresPerDegreeLon = 111_320.0 * cos(coordinate.latitude * .pi / 180.0)
        }

        func project(_ coordinate: CLLocationCoordinate2D) -> Point {
            Point(
                x: (coordinate.longitude - originLon) * metresPerDegreeLon,
                y: (coordinate.latitude - originLat) * metresPerDegreeLat
            )
        }
    }

    private static func closestPoint(on a: Point, _ b: Point, to p: Point) -> Point? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-9 else { return nil }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        return Point(x: a.x + t * dx, y: a.y + t * dy)
    }

    /// True bearing (0–360°) of the vector `from` -> `to` in the local frame.
    private static func bearing(from: Point, to: Point) -> Double? {
        let east = to.x - from.x
        let north = to.y - from.y
        guard (east * east + north * north).squareRoot() > 1e-6 else { return nil }
        return normalizedDegrees(atan2(east, north) * 180.0 / .pi)
    }

    /// Signed difference (a − b) wrapped to (−180, 180].
    static func signedAngularDifference(_ a: Double, _ b: Double) -> Double {
        var diff = (a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff <= -180 { diff += 360 }
        return diff
    }

    static func normalizedDegrees(_ value: Double) -> Double {
        let v = value.truncatingRemainder(dividingBy: 360)
        return v < 0 ? v + 360 : v
    }
}
