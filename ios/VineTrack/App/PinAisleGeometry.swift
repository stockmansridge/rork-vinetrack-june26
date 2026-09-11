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

    /// Oldest compass sample still accepted as the operator's facing at the
    /// moment of capture. Heading freshness only — this never changes the GPS
    /// acceptance thresholds enforced by `LocationService`.
    static let maximumHeadingAgeSeconds: Double = 5.0

    /// True when `heading` is a usable recorded facing. A genuine 0° (North) is
    /// valid; nil, non-finite and out-of-range values are not turned into North.
    static func validHeading(_ heading: Double?) -> Double? {
        guard let heading, heading.isFinite, heading >= -0.0001, heading <= 360.0001 else {
            return nil
        }
        return normalizedDegrees(heading)
    }

    /// Validated facing with temporal evidence. A compass sample older than
    /// `maximumHeadingAgeSeconds` describes an earlier moment, not this capture,
    /// so it is discarded instead of frozen into the pin. A nil age means no age
    /// was reported and is not treated as evidence of staleness.
    static func validHeading(_ heading: Double?, ageSeconds: Double?) -> Double? {
        if let ageSeconds {
            guard ageSeconds.isFinite,
                  ageSeconds >= -0.5,
                  ageSeconds <= maximumHeadingAgeSeconds
            else { return nil }
        }
        return validHeading(heading)
    }

    /// True when the accepted fix is precise enough for mapped-aisle matching.
    ///
    /// Requiring the entire accuracy circle to fit on both sides of a ~3 m aisle
    /// made ordinary field GPS incapable of attaching almost every standalone
    /// pin. The mapped adjacent rows, containment and headland checks already
    /// constrain the candidate corridor, so accuracy is compared with the full
    /// mapped aisle width. An uncertainty spanning the aisle (or no valid
    /// accuracy at all) remains ambiguous and requires operator confirmation.
    static func uncertaintyFitsBetweenRows(
        horizontalAccuracyMetres: Double?,
        distanceToNearRowMetres: Double,
        distanceToFarRowMetres: Double
    ) -> Bool {
        guard let accuracy = horizontalAccuracyMetres,
              accuracy.isFinite,
              accuracy >= 0,
              distanceToNearRowMetres.isFinite,
              distanceToNearRowMetres > 0,
              distanceToFarRowMetres.isFinite,
              distanceToFarRowMetres > 0
        else { return false }
        return accuracy < distanceToNearRowMetres + distanceToFarRowMetres
    }

    /// Resolve the aisle physically containing `coordinate`: the nearest mapped
    /// row plus the nearest row on the opposite side of the fix, provided they
    /// are close enough to be a real aisle AND the reported GPS uncertainty is
    /// small enough to tell this aisle apart from its neighbours.
    ///
    /// Returns nil when the block has no mapped rows, the fix sits on a row
    /// centreline, the fix lies beyond the ends of the rows (a clamped endpoint
    /// projection proves nothing about containment), no plausible neighbour
    /// exists, or the uncertainty spans more than the aisle. Callers keep an
    /// honest unconfirmed attachment in every one of those cases.
    ///
    /// - Parameter horizontalAccuracyMetres: the fix's own reported accuracy
    ///   radius. Required evidence — nil or invalid resolves to no aisle.
    static func aisle(
        containing coordinate: CLLocationCoordinate2D,
        in paddock: Paddock,
        horizontalAccuracyMetres: Double?
    ) -> Aisle? {
        resolveAisle(
            containing: coordinate,
            in: paddock,
            horizontalAccuracyMetres: horizontalAccuracyMetres,
            requiresQualifiedAccuracy: true
        )
    }

    /// Browsing-only aisle estimate. It uses the same mapped-row containment,
    /// headland and width checks as capture, but does not claim capture-grade GPS
    /// certainty. Callers must label the result as approximate and never persist it.
    static func approximateAisle(
        containing coordinate: CLLocationCoordinate2D,
        in paddock: Paddock
    ) -> Aisle? {
        resolveAisle(
            containing: coordinate,
            in: paddock,
            horizontalAccuracyMetres: nil,
            requiresQualifiedAccuracy: false
        )
    }

    private static func resolveAisle(
        containing coordinate: CLLocationCoordinate2D,
        in paddock: Paddock,
        horizontalAccuracyMetres: Double?,
        requiresQualifiedAccuracy: Bool
    ) -> Aisle? {
        let rows = paddock.rows
        guard rows.count >= 2 else { return nil }

        let frame = MetricFrame(around: coordinate)
        let point = frame.project(coordinate)

        // Nearest row and its closest point to the fix.
        var nearest: (row: PaddockRow, closest: Projection, distance: Double)?
        for row in rows {
            let a = frame.project(row.startPoint.coordinate)
            let b = frame.project(row.endPoint.coordinate)
            guard let closest = closestPoint(on: a, b, to: point) else { continue }
            let distance = closest.point.distance(to: point)
            if nearest == nil || distance < (nearest?.distance ?? .greatestFiniteMagnitude) {
                nearest = (row, closest, distance)
            }
        }
        guard let near = nearest, near.distance >= minimumAisleOffsetMetres else { return nil }
        // Past the end of a row the nearest point is only its endpoint. That
        // clamped projection is a geometry artefact, never proof the operator
        // was between the rows, so a headland fix stays unconfirmed.
        guard !near.closest.clampedToEnd else { return nil }

        // Axis: the outward direction from the nearest row towards the fix.
        let axis = Point(x: point.x - near.closest.point.x, y: point.y - near.closest.point.y)
            .normalized()
        guard let axis else { return nil }
        let fixOffset = near.distance

        // The aisle's far side is the closest row lying beyond the fix along
        // that same axis. Angled rows are handled because each candidate is
        // measured at its own closest point to the fix.
        var far: (row: PaddockRow, closest: Projection, offset: Double)?
        for row in rows where row.number != near.row.number {
            let a = frame.project(row.startPoint.coordinate)
            let b = frame.project(row.endPoint.coordinate)
            guard let closest = closestPoint(on: a, b, to: point), !closest.clampedToEnd else { continue }
            let offset = (closest.point.x - near.closest.point.x) * axis.x
                + (closest.point.y - near.closest.point.y) * axis.y
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

        // Map matching has already established the containing adjacent-row
        // corridor. Reject only when reported uncertainty spans that full aisle;
        // tighter single-fix evidence may attach without requiring trip state.
        let farDistance = far.closest.point.distance(to: point)
        if requiresQualifiedAccuracy {
            guard uncertaintyFitsBetweenRows(
                horizontalAccuracyMetres: horizontalAccuracyMetres,
                distanceToNearRowMetres: near.distance,
                distanceToFarRowMetres: farDistance
            ) else { return nil }
        }

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
        in paddock: Paddock,
        useAisleMidpointReference: Bool = false
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
        )?.point, let secondClosest = closestPoint(
            on: frame.project(second.startPoint.coordinate),
            frame.project(second.endPoint.coordinate),
            to: point
        )?.point else { return nil }

        // A locked aisle survives a brief lateral GPS outlier. Use the mapped
        // aisle midpoint only to determine physical Left/Right; the raw current
        // fix remains unchanged and is still projected onto the selected row.
        let sideReference = useAisleMidpointReference
            ? Point(x: (firstClosest.x + secondClosest.x) / 2, y: (firstClosest.y + secondClosest.y) / 2)
            : point
        let leftBearing = normalizedDegrees(heading - 90)
        let firstBearing = bearing(from: sideReference, to: firstClosest)
        let secondBearing = bearing(from: sideReference, to: secondClosest)
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

    /// Closest point on a segment, plus whether the projection had to be
    /// clamped to an endpoint — i.e. the fix lies beyond that end of the row.
    private struct Projection {
        let point: Point
        let clampedToEnd: Bool
    }

    private static func closestPoint(on a: Point, _ b: Point, to p: Point) -> Projection? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-9 else { return nil }
        let rawT = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        let t = max(0, min(1, rawT))
        let tolerance = 1e-9
        return Projection(
            point: Point(x: a.x + t * dx, y: a.y + t * dy),
            clampedToEnd: rawT < -tolerance || rawT > 1 + tolerance
        )
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
