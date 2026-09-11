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

    @Test func requiresDistinctSupportingObservationsRatherThanElapsedTime() {
        let two = [item(2, block: blockA, aisle: 12.5), item(1, block: blockA, aisle: 12.5)]
        #expect(PinAisleObservationLock.resolve(evidence: two, capturedAt: now) == nil)

        let three = two + [item(0, block: blockA, aisle: 12.5)]
        #expect(PinAisleObservationLock.resolve(evidence: three, capturedAt: now)?.aisleNumber == 12.5)
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
