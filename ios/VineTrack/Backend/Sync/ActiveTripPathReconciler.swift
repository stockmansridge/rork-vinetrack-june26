import Foundation

/// Protects the full in-progress route when a delayed active server copy is
/// reconciled after relaunch. Other remote fields remain authoritative.
nonisolated enum ActiveTripPathReconciler {
    /// Exact ordered coordinate inclusion, retaining duplicate observations; decoder-generated IDs are not GPS facts.
    static func containsRoute(_ local: [CoordinatePoint], in remote: [CoordinatePoint]) -> Bool {
        var index = 0
        for point in remote where index < local.count {
            if local[index].latitude == point.latitude && local[index].longitude == point.longitude { index += 1 }
        }
        return index == local.count
    }

    static func reconcile(local: Trip?, remote: Trip) -> Trip {
        guard let local,
              local.id == remote.id,
              local.isActive,
              remote.isActive,
              local.pathPoints.count > remote.pathPoints.count else {
            return remote
        }

        var merged = remote
        merged.pathPoints = local.pathPoints
        merged.totalDistance = local.totalDistance
        return merged
    }
}
