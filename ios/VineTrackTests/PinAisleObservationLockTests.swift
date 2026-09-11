import Testing
import Foundation
@testable import VineTrack

struct PinAisleObservationLockTests {
    private let blockA = UUID()
    private let blockB = UUID()
    private let now = Date(timeIntervalSince1970: 1_000)

    private func item(_ secondsAgo: Double, block: UUID?, aisle: Double?, qualified: Bool = true) -> PinAisleObservationLock.Evidence {
        PinAisleObservationLock.Evidence(
            observedAt: now.addingTimeInterval(-secondsAgo),
            paddockId: block,
            aisleNumber: aisle,
            isQualified: qualified
        )
    }

    @Test func stationaryFreshSamplesRemainDistinctWhileReplayAndStaleSamplesAreRejected() {
        let receivedAt = now
        let first = now.addingTimeInterval(-2)
        let second = now.addingTimeInterval(-1)
        #expect(PinAisleObservationLock.acceptsObservation(observedAt: first, previousObservedAt: nil, receivedAt: receivedAt))
        // Coordinate movement is intentionally absent from identity: a newer
        // provider timestamp remains usable while the operator is stationary.
        #expect(PinAisleObservationLock.acceptsObservation(observedAt: second, previousObservedAt: first, receivedAt: receivedAt))
        #expect(!PinAisleObservationLock.acceptsObservation(observedAt: second, previousObservedAt: second, receivedAt: receivedAt))
        #expect(!PinAisleObservationLock.acceptsObservation(observedAt: first, previousObservedAt: second, receivedAt: receivedAt))
        #expect(!PinAisleObservationLock.acceptsObservation(observedAt: now.addingTimeInterval(-6), previousObservedAt: nil, receivedAt: receivedAt))
    }

    @Test func requiresDistinctSupportingObservationsRatherThanElapsedTime() {
        let two = [item(2, block: blockA, aisle: 12.5), item(1, block: blockA, aisle: 12.5)]
        #expect(PinAisleObservationLock.resolve(evidence: two, capturedAt: now) == nil)

        let three = two + [item(0, block: blockA, aisle: 12.5)]
        let lock = PinAisleObservationLock.resolve(evidence: three, capturedAt: now)
        #expect(lock?.aisleNumber == 12.5)
        #expect(lock?.paddockId == blockA)
        #expect(lock?.confirmedAt == now)
    }

    @Test func holdsBriefContradictionAndSwitchesAfterSustainedEvidence() {
        let established = [item(6, block: blockA, aisle: 12.5), item(5, block: blockA, aisle: 12.5), item(4, block: blockA, aisle: 12.5)]
        let oneOutlier = established + [item(3, block: blockA, aisle: 13.5)]
        #expect(PinAisleObservationLock.resolve(evidence: oneOutlier, capturedAt: now)?.aisleNumber == 12.5)

        let switched = oneOutlier + [item(2, block: blockA, aisle: 13.5), item(1, block: blockA, aisle: 13.5)]
        #expect(PinAisleObservationLock.resolve(evidence: switched, capturedAt: now)?.aisleNumber == 13.5)
    }

    @Test func blockChangeHeadlandAndExpiryRequireFreshSupportAgain() {
        let established = [item(6, block: blockA, aisle: 12.5), item(5, block: blockA, aisle: 12.5), item(4, block: blockA, aisle: 12.5)]
        #expect(PinAisleObservationLock.resolve(evidence: established + [item(1, block: blockB, aisle: 12.5)], capturedAt: now) == nil)
        #expect(PinAisleObservationLock.resolve(evidence: established + [item(1, block: blockA, aisle: nil)], capturedAt: now) == nil)
        let expired = [item(23, block: blockA, aisle: 12.5), item(22, block: blockA, aisle: 12.5), item(21, block: blockA, aisle: 12.5)]
        #expect(PinAisleObservationLock.resolve(evidence: expired, capturedAt: now) == nil)
    }
}
