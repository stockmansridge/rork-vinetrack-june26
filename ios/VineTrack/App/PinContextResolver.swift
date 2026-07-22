import Foundation
import CoreLocation

/// Resolves `(paddockId, rowNumber)` for a pin being created at a coordinate.
///
/// Priority:
/// 1. If an active trip is detecting a paddock + row live, use those values.
/// 2. Otherwise, geometrically resolve from the coordinate against
///    `store.paddocks` (preferring trip-selected paddocks when a trip is
///    active). The row number returned is the actual paddock row number
///    (when explicit row geometry exists) or the synthetic row index.
///
/// This keeps the row guidance the operator sees in the trip UI consistent
/// with what gets persisted on the pin row, and it ensures manual pins
/// (no active trip) still capture the paddock/row when geometry is known.
@MainActor
enum PinContextResolver {

    struct Resolved: Equatable {
        var paddockId: UUID?
        var paddockName: String?
        var rowNumber: Int?
        var source: String   // "trip_live" | "geometry" | "trip_paddock_only" | "none"
    }

    static func resolve(
        coordinate: CLLocationCoordinate2D,
        store: MigratedDataStore,
        tracking: TripTrackingService?
    ) -> Resolved {
        // Trip-aware geometric resolution. We always prefer to recompute row
        // number from the coordinate (rather than the live path number which
        // sits between rows) so the persisted row matches the nearest actual
        // vineyard row.
        let trip = tracking?.activeTrip
        let candidates: [Paddock]
        if let trip {
            var ids = trip.paddockIds
            if ids.isEmpty, let id = trip.paddockId { ids = [id] }
            let scoped = ids.compactMap { id in store.paddocks.first(where: { $0.id == id }) }
            candidates = scoped.isEmpty ? store.paddocks : scoped
        } else {
            candidates = store.paddocks
        }

        if let paddock = RowGuidance.paddock(for: coordinate, in: candidates) {
            let row = RowGuidance.nearestRow(for: coordinate, in: paddock)
            let rowInt = row.map { Int($0.rowNumber.rounded()) }
            return Resolved(
                paddockId: paddock.id,
                paddockName: paddock.name,
                rowNumber: rowInt,
                source: tracking?.isTracking == true ? "trip_live" : "geometry"
            )
        }

        // Fall back to the trip's declared paddock if geometry didn't resolve.
        if let trip, let pid = trip.paddockId,
           let paddock = store.paddocks.first(where: { $0.id == pid }) {
            return Resolved(
                paddockId: paddock.id,
                paddockName: paddock.name,
                rowNumber: nil,
                source: "trip_paddock_only"
            )
        }

        return Resolved(paddockId: nil, paddockName: nil, rowNumber: nil, source: "none")
    }

    /// Build a safe diagnostic line describing what context the new pin was
    /// saved with. Contains no tokens, secrets or user emails.
    static func diagnostic(
        coordinate: CLLocationCoordinate2D,
        side: PinSide,
        mode: PinMode,
        resolved: Resolved,
        store: MigratedDataStore,
        tracking: TripTrackingService?
    ) -> String {
        let lat = String(format: "%.6f", coordinate.latitude)
        let lon = String(format: "%.6f", coordinate.longitude)
        let vid = store.selectedVineyardId?.uuidString ?? "nil"
        let pid = resolved.paddockId?.uuidString ?? "nil"
        let pname = resolved.paddockName ?? "nil"
        let row = resolved.rowNumber.map(String.init) ?? "nil"
        let tripId = tracking?.activeTrip?.id.uuidString ?? "nil"
        let livePath = tracking?.currentRowNumber.map { String(format: "%.1f", $0) } ?? "nil"
        let plannedPath: String = {
            guard let trip = tracking?.activeTrip,
                  trip.rowSequence.indices.contains(trip.sequenceIndex) else { return "nil" }
            return String(format: "%.1f", trip.rowSequence[trip.sequenceIndex])
        }()
        return """
        [PinDiag] vineyard=\(vid) paddock=\(pid) name=\(pname) row=\(row) \
        side=\(side.rawValue) mode=\(mode.rawValue) source=\(resolved.source) \
        lat=\(lat) lon=\(lon) trip=\(tripId) livePath=\(livePath) plannedPath=\(plannedPath)
        """
    }
}
