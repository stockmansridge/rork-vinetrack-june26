import Foundation
import CoreLocation

/// Everything about a pin capture that is settled at the moment the operator
/// presses the button, before any delayed confirmation can intervene.
///
/// A photo prompt, a duplicate warning, a retry or simply walking on must not
/// be able to change WHEN the observation happened or WHICH vineyard/trip it
/// belongs to. The Kotlin mirror is `PinCaptureContext` in
/// `data/QualifiedLocationFix.kt`; both follow
/// `docs/core-pin-location-contract.md`.
nonisolated struct PinCaptureContext: Sendable, Equatable {
    /// Instant of the press — persisted as the pin's timestamp.
    let capturedAt: Date
    /// Vineyard selected at the press. A save into any other vineyard is
    /// refused rather than silently rehomed.
    let vineyardId: UUID
    /// Trip active at the press (nil when the operator was not in a trip).
    /// A trip started or ended during the delay invalidates the capture.
    let tripId: UUID?
    /// The unmodified GPS observation. Never replaced by a snapped point.
    let rawCoordinate: CLLocationCoordinate2D
    /// Reported accuracy radius of that observation, used as aisle evidence.
    let horizontalAccuracyMetres: Double?

    init(
        capturedAt: Date,
        vineyardId: UUID,
        tripId: UUID?,
        rawCoordinate: CLLocationCoordinate2D,
        horizontalAccuracyMetres: Double?
    ) {
        self.capturedAt = capturedAt
        self.vineyardId = vineyardId
        self.tripId = tripId
        self.rawCoordinate = rawCoordinate
        self.horizontalAccuracyMetres = horizontalAccuracyMetres
    }

    static func == (lhs: PinCaptureContext, rhs: PinCaptureContext) -> Bool {
        lhs.capturedAt == rhs.capturedAt
            && lhs.vineyardId == rhs.vineyardId
            && lhs.tripId == rhs.tripId
            && lhs.rawCoordinate.latitude == rhs.rawCoordinate.latitude
            && lhs.rawCoordinate.longitude == rhs.rawCoordinate.longitude
            && lhs.horizontalAccuracyMetres == rhs.horizontalAccuracyMetres
    }

    /// True when this capture may still be written: same vineyard, same trip.
    func isCurrent(vineyardId currentVineyardId: UUID?, tripId currentTripId: UUID?) -> Bool {
        vineyardId == currentVineyardId && tripId == currentTripId
    }
}
