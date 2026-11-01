import Foundation

/// An in-progress spray already has a start and recorded work. Choosing it
/// must never call the separate activation path for an unstarted saved job.
/// A server-active flag alone does not transfer this device's trip ownership.
nonisolated enum SprayProgramResumeRoute: Equatable, Sendable {
    case activeTrip
    case tripDetails(String)
    case unavailable(String)

    static func resolve(
        record: SprayRecord?,
        trip: Trip?,
        selectedVineyardId: UUID?,
        deviceActiveTripId: UUID?,
        isDeviceTripOwner: Bool,
        liveTripId: UUID?
    ) -> Self {
        guard let record, !record.isTemplate,
              let trip, record.canonicalTripId == trip.id,
              trip.vineyardId == record.vineyardId,
              selectedVineyardId == trip.vineyardId else {
            return .unavailable("The linked spray or vineyard changed. Close this screen and reopen the original spray.")
        }
        guard record.endTime == nil, trip.isActive, trip.endTime == nil else {
            return .tripDetails("This spray is no longer in progress. Its saved trip details are shown below.")
        }
        if deviceActiveTripId == trip.id && isDeviceTripOwner && liveTripId == trip.id {
            return .activeTrip
        }
        if deviceActiveTripId == trip.id && !isDeviceTripOwner {
            return .tripDetails("Sign in as the operator who started this trip to continue it on this device. Its saved trip details are shown below.")
        }
        return .tripDetails("This device cannot control this in-progress trip. Continue with the device and account that started it. Its saved trip details are shown below.")
    }
}
