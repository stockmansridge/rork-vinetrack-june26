import Foundation
import CoreLocation

/// Pure helpers for warning when a new pin is being dropped on top of an
/// existing one. Backend-neutral — works with whatever pins are already
/// loaded into `MigratedDataStore.pins`.
nonisolated enum PinDuplicateChecker {

    /// Default fallback radius (metres) when no row-spacing is known.
    /// Sized for typical field GPS error (3-5 m) so two pins placed at the
    /// same vine actually trigger a duplicate warning even when the GPS
    /// fix has drifted between drops.
    static let fallbackRadiusMeters: Double = 3.0

    /// Hard cap on radius. Above this, two pins are clearly different
    /// targets — but this is intentionally generous to account for GPS
    /// noise during active trips at slow speeds.
    static let maxRadiusMeters: Double = 6.0

    /// Minimum radius even when row spacing is known. Bumped from 1.5 m to
    /// 2.5 m so vineyard GPS jitter (typically 2–3 m horizontal accuracy)
    /// can't sneak a near-duplicate pin past the warning. Narrow-row
    /// paddocks may now warn on adjacent rows, which is the correct
    /// trade-off for repair/growth pin work.
    static let minRadiusMeters: Double = 2.5

    /// Compute the duplicate-warning radius for a pin being dropped at
    /// `coordinate`. Uses half the row spacing of the most relevant paddock
    /// (the one containing the coordinate, falling back to `paddockId`),
    /// or a conservative fallback when geometry isn't available.
    static func duplicateRadius(
        coordinate: CLLocationCoordinate2D,
        paddockId: UUID?,
        paddocks: [Paddock]
    ) -> Double {
        if let containing = RowGuidance.paddock(for: coordinate, in: paddocks),
           containing.rowWidth > 0 {
            return min(maxRadiusMeters, max(minRadiusMeters, containing.rowWidth / 2.0))
        }
        if let id = paddockId,
           let paddock = paddocks.first(where: { $0.id == id }),
           paddock.rowWidth > 0 {
            return min(maxRadiusMeters, max(minRadiusMeters, paddock.rowWidth / 2.0))
        }
        return fallbackRadiusMeters
    }

    /// The closest pin within `radius` of `coordinate`, scoped to the same
    /// vineyard. Active (not-completed) pins are preferred; completed pins
    /// are returned only when no active match exists. Returns `nil` when
    /// no pin is in range.
    /// Along-row duplicate radius. When pin-snapping projects two pins
    /// onto the same row line, raw GPS distance under-counts duplicates
    /// because tractor jitter spreads samples along the row. We use a
    /// tighter, fixed along-row radius for same-row, same-mode pins so a
    /// repair tapped twice within a couple of metres warns reliably.
    static let alongRowDuplicateMetres: Double = 2.5

    /// Find a likely duplicate using along-row geometry. Same vineyard +
    /// same paddock + same row number + same mode + along-row distance
    /// within `alongRowDuplicateMetres`. Returns the closest match (open
    /// pins preferred). Falls back to nil when no row context exists —
    /// callers should then use the lat/lng-based `nearbyPin` check.
    static func nearbyPinAlongRow(
        snappedCoordinate: CLLocationCoordinate2D,
        vineyardId: UUID?,
        paddockId: UUID?,
        rowNumber: Int?,
        side: PinSide? = nil,
        mode: PinMode?,
        in pins: [VinePin],
        paddocks: [Paddock]
    ) -> (pin: VinePin, distance: Double)? {
        guard let paddockId, let rowNumber,
              let paddock = paddocks.first(where: { $0.id == paddockId }) else {
            return nil
        }
        guard let snappedSelf = RowGuidance.snapToRow(
            coordinate: snappedCoordinate,
            rowNumber: rowNumber,
            in: paddock
        ) else { return nil }

        var bestActive: (pin: VinePin, distance: Double)?
        var bestDone: (pin: VinePin, distance: Double)?
        for pin in pins {
            if let vid = vineyardId, pin.vineyardId != vid { continue }
            guard pin.paddockId == paddockId else { continue }
            // Match by the new pin_row_number when present (actual vine
            // row), otherwise fall back to the legacy row_number storage
            // (driving path floor). New + legacy pins both compare cleanly.
            let candidateRow = pin.pinRowNumber ?? pin.rowNumber
            guard candidateRow == rowNumber else { continue }
            // Only constrain by side when the caller actually knows the
            // side — otherwise treat both sides as candidate duplicates.
            // Prefer the new pin_side; legacy pin.side is operator-side too.
            if let side, (pin.pinSide ?? pin.side) != side { continue }
            if let mode, pin.mode != mode { continue }
            guard let snappedOther = RowGuidance.snapToRow(
                coordinate: pin.attachedCoordinate,
                rowNumber: rowNumber,
                in: paddock
            ) else { continue }
            let delta = abs(snappedSelf.distanceAlongMetres - snappedOther.distanceAlongMetres)
            guard delta <= alongRowDuplicateMetres else { continue }
            let scoped: (VinePin, Double) = (pin, delta)
            if pin.isCompleted {
                if bestDone == nil || delta < bestDone!.distance { bestDone = scoped }
            } else {
                if bestActive == nil || delta < bestActive!.distance { bestActive = scoped }
            }
        }
        return bestActive ?? bestDone
    }

    static func nearbyPin(
        coordinate: CLLocationCoordinate2D,
        vineyardId: UUID?,
        paddockId: UUID?,
        radius: Double,
        in pins: [VinePin]
    ) -> (pin: VinePin, distance: Double)? {
        var bestActive: (pin: VinePin, distance: Double)?
        var bestDone: (pin: VinePin, distance: Double)?

        for pin in pins {
            if let vid = vineyardId, pin.vineyardId != vid { continue }
            let d = RowGuidance.metresBetween(
                coordinate,
                CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
            )
            guard d <= radius else { continue }

            // Same paddock matches sort first by tightening the radius slightly.
            let scoped: (VinePin, Double) = (pin, d)
            if pin.isCompleted {
                if bestDone == nil || d < bestDone!.distance {
                    bestDone = scoped
                }
            } else {
                if bestActive == nil || d < bestActive!.distance {
                    bestActive = scoped
                }
            }
            _ = paddockId
        }
        return bestActive ?? bestDone
    }
}
