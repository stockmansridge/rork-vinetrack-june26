import Foundation
import Testing
@testable import VineTrack

struct OccurrenceCreateBlockUUIDTests {
    @Test func newTripBlockIdsAreCanonicalWithoutTouchingOtherPayload() {
        typealias JSON = TripOccurrenceCoverage.JSON
        let uppercase = "B6354157-8BDD-4941-AA93-8C229C11BCA6"
        let lower = uppercase.lowercased()
        let input: [String: JSON] = [
            "paddock_id": .string(uppercase),
            "paddock_ids": .array([.string(uppercase)]),
            "id": .string(uppercase),
            "notes": .string("Unchanged")
        ]
        let result = OccurrenceCreateBlockUUID.canonicalize(input)
        #expect(result["paddock_id"] == .string(lower))
        #expect(result["paddock_ids"] == .array([.string(lower)]))
        #expect(result["id"] == input["id"])
        #expect(result["notes"] == input["notes"])
        #expect(input["paddock_id"] == .string(uppercase))
    }

    @Test func malformedIdsRemainUnchangedForTheServerToReject() {
        typealias JSON = TripOccurrenceCoverage.JSON
        let input: [String: JSON] = [
            "paddock_id": .string("invalid"),
            "paddock_ids": .array([.string("invalid"), .null])
        ]
        #expect(OccurrenceCreateBlockUUID.canonicalize(input) == input)
    }
}
