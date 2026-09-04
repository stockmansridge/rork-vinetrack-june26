import Foundation

/// Protects the full in-progress route when a delayed active server copy is
/// reconciled after relaunch. Other remote fields remain authoritative.
nonisolated enum ActiveTripPathReconciler {
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
