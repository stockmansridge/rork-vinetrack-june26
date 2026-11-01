import Foundation
import Testing
@testable import VineTrack

struct SprayProgramResumeRouteTests {
    private let vineyardId = UUID()

    private func resolve(
        trip: Trip?, record: SprayRecord?, deviceTripId: UUID? = nil,
        owner: Bool = false, liveTripId: UUID? = nil, vineyard: UUID? = nil
    ) -> SprayProgramResumeRoute {
        SprayProgramResumeRoute.resolve(
            record: record, trip: trip, selectedVineyardId: vineyard ?? vineyardId,
            deviceActiveTripId: deviceTripId, isDeviceTripOwner: owner, liveTripId: liveTripId
        )
    }

    private func record(for trip: Trip) -> SprayRecord {
        SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId, sprayReference: "Test step")
    }

    @Test("The owned in-progress spray opens the existing live trip without rate confirmation")
    func ownedActiveTripOpensDirectly() {
        let trip = Trip(vineyardId: vineyardId, isActive: true)
        #expect(resolve(trip: trip, record: record(for: trip), deviceTripId: trip.id,
                        owner: true, liveTripId: trip.id) == .activeTrip)
    }

    @Test("Opening a paused spray preserves the original clock, progress and tank session")
    func pausedTripPreservesOperationalState() {
        var trip = Trip(vineyardId: vineyardId, isActive: true)
        trip.startTime = Date(timeIntervalSince1970: 1_790_000_000)
        trip.isPaused = true
        trip.pauseTimestamps = [trip.startTime.addingTimeInterval(30)]
        trip.rowSequence = [1.5, 2.5, 3.5]
        trip.sequenceIndex = 1
        trip.completedPaths = [1.5]
        trip.totalDistance = 123
        trip.tankSessions = [TankSession(tankNumber: 1, startTime: trip.startTime)]
        trip.activeTankNumber = 1
        let original = trip
        let spray = record(for: trip)
        #expect(resolve(trip: trip, record: spray, deviceTripId: trip.id,
                        owner: true, liveTripId: trip.id) == .activeTrip)
        #expect(trip == original)
        #expect(spray.tripId == original.id)
    }

    @Test("A server-active trip without device ownership shows details and an explanation")
    func remoteActiveTripIsNotAdopted() {
        let trip = Trip(vineyardId: vineyardId, isActive: true)
        guard case .tripDetails(let message) = resolve(trip: trip, record: record(for: trip)) else {
            Issue.record("A remote active record must never enter a new-start or live-control flow")
            return
        }
        #expect(message.contains("device and account that started it"))
    }

    @Test("Another operator's device ownership cannot grant live controls")
    func wrongAccountShowsActionableDetails() {
        let trip = Trip(vineyardId: vineyardId, isActive: true)
        guard case .tripDetails(let message) = resolve(trip: trip, record: record(for: trip),
                                                     deviceTripId: trip.id, owner: false, liveTripId: trip.id) else {
            Issue.record("An ownership mismatch must show details")
            return
        }
        #expect(message.contains("Sign in as the operator"))
    }

    @Test("Opening another active spray cannot replace the device's existing trip")
    func differentOwnedTripIsNotReplaced() {
        let trip = Trip(vineyardId: vineyardId, isActive: true)
        let otherTripId = UUID()
        guard case .tripDetails = resolve(trip: trip, record: record(for: trip),
                                          deviceTripId: otherTripId, owner: true, liveTripId: otherTripId) else {
            Issue.record("The owned trip must not be replaced by a different active spray")
            return
        }
    }

    @Test("Completion between picker tap and presentation opens the saved details")
    func completedAfterSelectionDoesNotRestart() {
        var trip = Trip(vineyardId: vineyardId, isActive: false)
        trip.endTime = Date()
        guard case .tripDetails = resolve(trip: trip, record: record(for: trip),
                                          deviceTripId: trip.id, owner: true, liveTripId: trip.id) else {
            Issue.record("A completed spray cannot be resumed or reactivated")
            return
        }
    }

    @Test("A vineyard switch or a broken original link produces an explicit unavailable state")
    func wrongScopeAndMissingLinkAreVisible() {
        let trip = Trip(vineyardId: vineyardId, isActive: true)
        guard case .unavailable = resolve(trip: trip, record: record(for: trip), vineyard: UUID()) else {
            Issue.record("A vineyard switch must invalidate the destination")
            return
        }
        guard case .unavailable = resolve(trip: nil, record: record(for: trip)) else {
            Issue.record("A missing original trip must be explained")
            return
        }
        var unlinked = record(for: trip)
        unlinked.hasRecordedTripLink = false
        guard case .unavailable = resolve(trip: trip, record: unlinked) else {
            Issue.record("A compatibility trip UUID must not become a live trip link")
            return
        }
    }

    @Test("A link to a different vineyard or trip cannot expose its live controls")
    func conflictingLinkIsRejected() {
        let trip = Trip(vineyardId: vineyardId, isActive: true)
        var linked = record(for: trip)
        linked.vineyardId = UUID()
        guard case .unavailable = resolve(trip: trip, record: linked, deviceTripId: trip.id,
                                          owner: true, liveTripId: trip.id) else {
            Issue.record("Mismatched record and trip vineyards must be rejected")
            return
        }
    }
}
