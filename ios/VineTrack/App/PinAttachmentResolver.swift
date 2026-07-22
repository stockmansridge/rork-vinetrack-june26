import Foundation
import CoreLocation

/// Resolves the actual attached vine row + side for a pin dropped while
/// driving a path/mid-row.
///
/// A pin dropped while driving Path 14.5 can belong to either Row 14 or
/// Row 15 depending on the operator's direction of travel and which side
/// of the tractor the issue was on. This resolver projects the pin onto
/// the path centreline, computes the operator's forward direction from
/// the path geometry + heading, and decides which adjacent vine row sits
/// on the operator's left vs right.
///
/// Pure functions only. No store, no @MainActor, no I/O.
nonisolated enum PinAttachmentResolver {

    struct Attachment: Sendable {
        /// Driving path / mid-row, e.g. 14.5.
        let drivingRowNumber: Double?
        /// Actual vine row the pin is attached to, e.g. 14 or 15.
        let pinRowNumber: Int?
        /// Side the pin was attached to, from operator's POV.
        let pinSide: PinSide?
        /// Snapped point on the driving path centreline.
        let snappedCoordinate: CLLocationCoordinate2D?
        /// Distance along the driving path from the path's start point.
        let alongRowDistanceM: Double?
        /// True only when geometry confidently resolved both the snap and
        /// the attached vine row. snapped_to_row in Supabase mirrors this.
        let snappedToRow: Bool
    }

    /// Resolve the full attachment for a pin being dropped during an
    /// active trip with a known driving path number.
    ///
    /// - Parameters:
    ///   - rawCoordinate: raw GPS coordinate at the moment of the drop.
    ///   - heading: device true heading in degrees (0–360).
    ///   - operatorSide: side the operator tagged the pin on.
    ///   - drivingPath: live path number from row guidance, e.g. 14.5.
    ///   - paddock: paddock containing the row geometry. Pass `nil` when
    ///     no paddock is known — only `pinSide` will be populated.
    ///   - confident: true when the live path lock confidence is high
    ///     enough to trust geometry (matches the existing 0.6 threshold
    ///     used by TripTrackingService.dropPinDuringTrip).
    static func resolveLive(
        rawCoordinate: CLLocationCoordinate2D,
        heading: Double,
        operatorSide: PinSide,
        drivingPath: Double?,
        paddock: Paddock?,
        confident: Bool
    ) -> Attachment {
        let drivingNumber = drivingPath
        guard confident,
              let drivingPath,
              let paddock,
              let snap = RowGuidance.snapToPath(
                coordinate: rawCoordinate,
                path: drivingPath,
                in: paddock
              )
        else {
            return Attachment(
                drivingRowNumber: drivingNumber,
                pinRowNumber: nil,
                pinSide: operatorSide,
                snappedCoordinate: nil,
                alongRowDistanceM: nil,
                snappedToRow: false
            )
        }

        let attachedRow = attachedVineRow(
            drivingPath: drivingPath,
            paddock: paddock,
            snappedPoint: snap.snapped,
            heading: heading,
            operatorSide: operatorSide
        )

        return Attachment(
            drivingRowNumber: drivingPath,
            pinRowNumber: attachedRow,
            pinSide: operatorSide,
            snappedCoordinate: snap.snapped,
            alongRowDistanceM: snap.distanceAlongMetres,
            snappedToRow: attachedRow != nil
        )
    }

    /// Lightweight attachment for manual pin entry (no live trip lock).
    /// Records the side the operator selected but never speculates which
    /// vine row the pin attaches to — `snappedToRow` stays false.
    static func manual(
        operatorSide: PinSide,
        legacyDrivingRowFloor: Int?
    ) -> Attachment {
        let drivingPath = legacyDrivingRowFloor.map { Double($0) + 0.5 }
        return Attachment(
            drivingRowNumber: drivingPath,
            pinRowNumber: nil,
            pinSide: operatorSide,
            snappedCoordinate: nil,
            alongRowDistanceM: nil,
            snappedToRow: false
        )
    }

    // MARK: - Geometry

    /// Decide which adjacent vine row (floor or ceil of the driving path)
    /// sits on the operator's `operatorSide` given their heading and the
    /// path geometry.
    private static func attachedVineRow(
        drivingPath: Double,
        paddock: Paddock,
        snappedPoint: CLLocationCoordinate2D,
        heading: Double,
        operatorSide: PinSide
    ) -> Int? {
        let lower = Int(floor(drivingPath))
        let upper = Int(ceil(drivingPath))
        // X.0 path (only one neighbour) — fall back to that single row.
        guard lower != upper else { return lower }

        guard let r1 = paddock.rows.first(where: { $0.number == lower }),
              let r2 = paddock.rows.first(where: { $0.number == upper })
        else { return nil }

        // Path bearing (start → end of the midline).
        let pathStart = midpoint(r1.startPoint.coordinate, r2.startPoint.coordinate)
        let pathEnd = midpoint(r1.endPoint.coordinate, r2.endPoint.coordinate)
        let pathBearing = bearingDegrees(from: pathStart, to: pathEnd)

        // Reverse the path bearing if the operator is travelling the
        // opposite way (heading roughly opposite the path's start→end).
        let forwardBearing: Double = {
            let diff = signedAngularDifference(heading, pathBearing)
            if abs(diff) > 90 {
                return normalizedDegrees(pathBearing + 180)
            }
            return pathBearing
        }()

        // "Left" of the operator is forward − 90°.
        let leftBearing = normalizedDegrees(forwardBearing - 90)

        // Bearing from the snapped point to the centroid of the lower row.
        let lowerMid = midpoint(r1.startPoint.coordinate, r1.endPoint.coordinate)
        let toLowerBearing = bearingDegrees(from: snappedPoint, to: lowerMid)
        let lowerIsOnLeft = abs(signedAngularDifference(toLowerBearing, leftBearing)) < 90

        switch operatorSide {
        case .left:  return lowerIsOnLeft ? lower : upper
        case .right: return lowerIsOnLeft ? upper : lower
        }
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

    /// True bearing (0–360°) from `a` to `b`.
    private static func bearingDegrees(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = a.latitude * .pi / 180.0
        let lat2 = b.latitude * .pi / 180.0
        let dLon = (b.longitude - a.longitude) * .pi / 180.0
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180.0 / .pi
        return normalizedDegrees(bearing)
    }

    /// Signed difference (a − b) wrapped to (−180, 180].
    private static func signedAngularDifference(_ a: Double, _ b: Double) -> Double {
        var diff = (a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff <= -180 { diff += 360 }
        return diff
    }

    private static func normalizedDegrees(_ value: Double) -> Double {
        let v = value.truncatingRemainder(dividingBy: 360)
        return v < 0 ? v + 360 : v
    }
}
