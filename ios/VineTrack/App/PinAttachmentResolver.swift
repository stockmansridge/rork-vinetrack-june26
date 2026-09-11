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
        /// Snapped point on the ATTACHED VINE ROW's centreline — never the
        /// driving-path midline. Nil when no row was confidently selected.
        let snappedCoordinate: CLLocationCoordinate2D?
        /// Distance along the attached vine row from that row's start point.
        let alongRowDistanceM: Double?
        /// True only when geometry confidently resolved both the snap and
        /// the attached vine row. snapped_to_row in Supabase mirrors this.
        let snappedToRow: Bool
        /// The exact validated heading used to choose the side, frozen with the
        /// rest of the capture so a later confirmation cannot save a different
        /// facing. Nil when no usable heading was recorded — an absent heading
        /// is never turned into 0°/North.
        let heading: Double?

        init(
            drivingRowNumber: Double?,
            pinRowNumber: Int?,
            pinSide: PinSide?,
            snappedCoordinate: CLLocationCoordinate2D?,
            alongRowDistanceM: Double?,
            snappedToRow: Bool,
            heading: Double? = nil
        ) {
            self.drivingRowNumber = drivingRowNumber
            self.pinRowNumber = pinRowNumber
            self.pinSide = pinSide
            self.snappedCoordinate = snappedCoordinate
            self.alongRowDistanceM = alongRowDistanceM
            self.snappedToRow = snappedToRow
            self.heading = heading
        }
    }

    /// The live row-guidance lock plus the evidence needed to decide whether it
    /// may speak for THIS capture.
    ///
    /// A confidence number alone is not enough: a lock earned in another block,
    /// or one that has not been confirmed in the corridor recently, describes a
    /// different place or a different moment.
    struct LiveLock: Sendable {
        /// Locked driving path / aisle number, e.g. 14.5.
        let path: Double
        /// Dwell-derived lock confidence (the existing 0–1 tracking value).
        let confidence: Double
        /// Block the lock was established in.
        let paddockId: UUID?
        /// Last moment GPS confirmed the operator inside the locked corridor.
        let confirmedAt: Date?

        init(path: Double, confidence: Double, paddockId: UUID?, confirmedAt: Date?) {
            self.path = path
            self.confidence = confidence
            self.paddockId = paddockId
            self.confirmedAt = confirmedAt
        }
    }

    /// Existing dwell-confidence threshold for trusting a live lock.
    static let minimumLockConfidence: Double = 0.6

    /// Oldest in-corridor confirmation still allowed to describe this capture.
    /// After this the lock is stale evidence, not present evidence.
    static let maximumLockAgeSeconds: Double = 15.0

    /// True when `lock` genuinely describes this capture: confident, earned in
    /// the block the fix resolved to, and confirmed recently enough. Row numbers
    /// are reused across blocks, so a wrong-block lock can never name this row.
    static func lockIsValid(
        _ lock: LiveLock?,
        resolvedPaddockId: UUID?,
        capturedAt: Date
    ) -> Bool {
        guard let lock,
              lock.path.isFinite,
              lock.confidence >= minimumLockConfidence
        else { return false }
        guard let lockPaddockId = lock.paddockId,
              let resolvedPaddockId,
              lockPaddockId == resolvedPaddockId
        else { return false }
        guard let confirmedAt = lock.confirmedAt else { return false }
        let age = capturedAt.timeIntervalSince(confirmedAt)
        return age >= -1.0 && age <= maximumLockAgeSeconds
    }

    /// Resolve the full attachment for a pin being dropped during an
    /// active trip with a known driving path number.
    ///
    /// - Parameters:
    ///   - rawCoordinate: raw GPS coordinate at the moment of the drop.
    ///   - heading: device true heading in degrees (0–360), or nil when none
    ///     was recorded. An absent heading is never treated as 0°/North.
    ///   - operatorSide: side the operator tagged the pin on.
    ///   - drivingPath: live path number from row guidance, e.g. 14.5.
    ///   - paddock: paddock containing the row geometry. Pass `nil` when
    ///     no paddock is known — only `pinSide` will be populated.
    ///   - confident: true only when the caller has already validated the live
    ///     lock through `lockIsValid(_:resolvedPaddockId:capturedAt:)` — block
    ///     scope and recency included, not a confidence number alone.
    ///
    /// The pin snaps onto the SELECTED VINE ROW, not the aisle centreline, and
    /// the raw observation is left untouched for the caller to persist.
    static func resolveLive(
        rawCoordinate: CLLocationCoordinate2D,
        heading: Double?,
        operatorSide: PinSide,
        drivingPath: Double?,
        paddock: Paddock?,
        confident: Bool
    ) -> Attachment {
        let validHeading = PinAisleGeometry.validHeading(heading)
        // The aisle is only evidence when the live lock was validated.
        let drivingNumber = confident ? drivingPath : nil
        guard confident,
              let drivingPath,
              let paddock,
              let bounding = PinAisleGeometry.rowsBounding(path: drivingPath, in: paddock),
              let selection = PinAisleGeometry.rowOnSide(
                rowNumbers: bounding,
                coordinate: rawCoordinate,
                heading: validHeading,
                operatorSide: operatorSide,
                in: paddock
              )
        else {
            // Honest point-only capture: keep the confidently locked aisle and
            // the operator's own side, but claim no vine row and snap nothing
            // to a path centreline.
            return Attachment(
                drivingRowNumber: drivingNumber,
                pinRowNumber: nil,
                pinSide: operatorSide,
                snappedCoordinate: nil,
                alongRowDistanceM: nil,
                snappedToRow: false,
                heading: validHeading
            )
        }

        return Attachment(
            drivingRowNumber: drivingPath,
            pinRowNumber: selection.rowNumber,
            pinSide: operatorSide,
            snappedCoordinate: selection.snapped,
            alongRowDistanceM: selection.distanceAlongMetres,
            snappedToRow: true,
            heading: validHeading
        )
    }

    /// Automatic Left/Right capture without a usable live trip row lock —
    /// launcher Repairs/Growth and quick pins, inside or outside a trip.
    ///
    /// Resolves the aisle physically containing the fix from mapped adjacent
    /// row geometry, then attaches to whichever of that aisle's two rows lies
    /// on the operator's side for their recorded heading. When the heading is
    /// missing, invalid or stale, when the fix's own uncertainty spans more than
    /// the aisle, or when the aisle is otherwise ambiguous, the capture stays
    /// honest: the raw observation and the operator's side are kept, and no row,
    /// driving path or snap is invented.
    ///
    /// - Parameters:
    ///   - headingAgeSeconds: age of the compass sample, when known.
    ///   - horizontalAccuracyMetres: the fix's own reported accuracy radius.
    ///     Aisle confidence is judged separately here; the GPS acceptance
    ///     thresholds in `LocationService` are unchanged.
    static func resolveAutomatic(
        rawCoordinate: CLLocationCoordinate2D,
        heading: Double?,
        headingAgeSeconds: Double? = nil,
        horizontalAccuracyMetres: Double?,
        operatorSide: PinSide,
        paddock: Paddock?,
        capturedAt: Date = Date(),
        aisleLock: PinAisleObservationLock.Lock? = nil
    ) -> Attachment {
        let validHeading = PinAisleGeometry.validHeading(heading, ageSeconds: headingAgeSeconds)
        let unconfirmed = Attachment(
            drivingRowNumber: nil,
            pinRowNumber: nil,
            pinSide: operatorSide,
            snappedCoordinate: nil,
            alongRowDistanceM: nil,
            snappedToRow: false,
            heading: validHeading
        )
        guard let paddock, validHeading != nil else { return unconfirmed }
        let resolvedAisle: (number: Double, rows: (Int, Int))? = {
            if PinAisleObservationLock.isValid(
                aisleLock,
                capturedAt: capturedAt,
                currentCoordinate: rawCoordinate,
                paddock: paddock
            ), let aisleLock,
               let rows = PinAisleGeometry.rowsBounding(path: aisleLock.aisleNumber, in: paddock) {
                return (aisleLock.aisleNumber, rows)
            }
            guard let aisle = PinAisleGeometry.aisle(
                containing: rawCoordinate,
                in: paddock,
                horizontalAccuracyMetres: horizontalAccuracyMetres
            ) else { return nil }
            return (aisle.aisleNumber, (aisle.nearRowNumber, aisle.farRowNumber))
        }()
        guard let resolvedAisle,
              let selection = PinAisleGeometry.rowOnSide(
                rowNumbers: resolvedAisle.rows,
                coordinate: rawCoordinate,
                heading: validHeading,
                operatorSide: operatorSide,
                in: paddock,
                useAisleMidpointReference: aisleLock != nil
              )
        else { return unconfirmed }

        return Attachment(
            drivingRowNumber: resolvedAisle.number,
            pinRowNumber: selection.rowNumber,
            pinSide: operatorSide,
            snappedCoordinate: selection.snapped,
            alongRowDistanceM: selection.distanceAlongMetres,
            snappedToRow: true,
            heading: validHeading
        )
    }

    /// Operator-confirmed mapped aisle for an otherwise ambiguous frozen
    /// automatic capture. The raw coordinate and heading remain those frozen at
    /// the initiating press; only the mapped aisle identity is supplied by UI.
    static func resolveConfirmedAisle(
        rawCoordinate: CLLocationCoordinate2D,
        heading: Double?,
        operatorSide: PinSide,
        aisleNumber: Double,
        paddock: Paddock?
    ) -> Attachment {
        let validHeading = PinAisleGeometry.validHeading(heading)
        guard let paddock,
              let rows = PinAisleGeometry.rowsBounding(path: aisleNumber, in: paddock),
              PinAisleGeometry.approximateAisle(containing: rawCoordinate, in: paddock) != nil,
              let selection = PinAisleGeometry.rowOnSide(
                rowNumbers: rows,
                coordinate: rawCoordinate,
                heading: validHeading,
                operatorSide: operatorSide,
                in: paddock,
                useAisleMidpointReference: true
              )
        else {
            return Attachment(
                drivingRowNumber: nil,
                pinRowNumber: nil,
                pinSide: operatorSide,
                snappedCoordinate: nil,
                alongRowDistanceM: nil,
                snappedToRow: false,
                heading: validHeading
            )
        }
        return Attachment(
            drivingRowNumber: aisleNumber,
            pinRowNumber: selection.rowNumber,
            pinSide: operatorSide,
            snappedCoordinate: selection.snapped,
            alongRowDistanceM: selection.distanceAlongMetres,
            snappedToRow: true,
            heading: validHeading
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

    /// Full placement for a launcher/manual pin dropped at a real GPS fix
    /// without a live trip lock — the iOS mirror of Android's
    /// `RowAttachment.resolve`/`PinPlacement`. Resolved exactly once at
    /// commit time; the immutable result flows verbatim into the saved pin.
    ///
    /// Finds the nearest mapped vine row in `paddock`, projects the fix onto
    /// its centreline and reports the along-row distance. Like the manual
    /// resolver it never speculates a driving path. `snappedToRow` is true
    /// only when the snap geometry fully resolved; when the block has no
    /// explicit row lines (synthetic-only geometry) the nearest row number is
    /// still recorded but the snap state stays honestly false.
    static func resolveManual(
        coordinate: CLLocationCoordinate2D,
        operatorSide: PinSide,
        paddock: Paddock?
    ) -> Attachment {
        let sideOnly = Attachment(
            drivingRowNumber: nil,
            pinRowNumber: nil,
            pinSide: operatorSide,
            snappedCoordinate: nil,
            alongRowDistanceM: nil,
            snappedToRow: false
        )
        guard let paddock,
              let nearest = RowGuidance.nearestRow(for: coordinate, in: paddock)
        else { return sideOnly }

        let rowNumber = Int(nearest.rowNumber.rounded())
        guard let snap = RowGuidance.snapToRow(
            coordinate: coordinate,
            rowNumber: rowNumber,
            in: paddock
        ) else {
            // Synthetic-only geometry: keep the resolved row, stay unsnapped.
            return Attachment(
                drivingRowNumber: nil,
                pinRowNumber: rowNumber,
                pinSide: operatorSide,
                snappedCoordinate: nil,
                alongRowDistanceM: nil,
                snappedToRow: false
            )
        }
        return Attachment(
            drivingRowNumber: nil,
            pinRowNumber: rowNumber,
            pinSide: operatorSide,
            snappedCoordinate: snap.snapped,
            alongRowDistanceM: snap.distanceAlongMetres,
            snappedToRow: true
        )
    }

    // MARK: - Geometry
    //
    // Aisle identification and heading-aware side selection live in
    // `PinAisleGeometry`, shared by the live-trip and automatic resolvers so
    // both platforms follow one contract (docs/core-pin-location-contract.md).
}
