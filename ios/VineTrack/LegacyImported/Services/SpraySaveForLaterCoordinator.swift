import Foundation

/// Orders durable writes so a failed or uncertain record acknowledgement cannot create a Trip.
@MainActor
enum SpraySaveForLaterCoordinator {
    static func save(record: SprayRecord, trip: Trip,
                     saveRecord: (SprayRecord) throws -> Void,
                     saveTrip: (Trip) throws -> Void) throws {
        guard record.tripId == trip.id, record.vineyardId == trip.vineyardId,
              !trip.isActive, trip.endTime == nil,
              record.operationalPlanningBlocker == nil else {
            throw SprayTankActualValidationError.localSaveFailed
        }
        try saveRecord(record)
        try saveTrip(trip)
    }
}
