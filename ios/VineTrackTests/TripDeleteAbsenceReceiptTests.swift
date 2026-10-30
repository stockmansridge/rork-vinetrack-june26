import Foundation
import Testing
@testable import VineTrack

struct TripDeleteAbsenceReceiptTests {
    private let trip = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let owner = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func receipt(version: Int = 1, absent: Bool = true,
                         tripId: UUID? = nil, actorId: UUID? = nil) -> TripDeleteAbsenceReceipt {
        TripDeleteAbsenceReceipt(schemaVersion: version, tripId: tripId ?? trip,
                                 actorId: actorId ?? owner, absent: absent)
    }
    private func validate(_ value: TripDeleteAbsenceReceipt,
                          current: UUID? = nil, generation: UInt64 = 12) throws {
        try value.requireConfirmation(trip: trip, owner: owner, generation: 12,
                                      currentOwner: current ?? owner, currentGeneration: generation)
    }

    @Test func confirmedMissingTripIsAcknowledged() throws {
        try validate(receipt())
    }
    @Test func existingTripCannotBeAcknowledgedAsAbsent() {
        #expect(throws: TripDeleteAbsenceReceipt.Failure.self) { try validate(receipt(absent: false)) }
    }
    @Test func wrongRecordCannotClearQueue() {
        #expect(throws: TripDeleteAbsenceReceipt.Failure.self) { try validate(receipt(tripId: UUID())) }
    }
    @Test func wrongServerActorCannotClearQueue() {
        #expect(throws: TripDeleteAbsenceReceipt.Failure.self) { try validate(receipt(actorId: UUID())) }
    }
    @Test func futureSchemaRequiresReview() {
        #expect(throws: TripDeleteAbsenceReceipt.Failure.self) { try validate(receipt(version: 2)) }
    }
    @Test func changedAccountCancelsAcknowledgement() {
        #expect(throws: CancellationError.self) { try validate(receipt(), current: UUID()) }
    }
    @Test func signOutAndBackToSameAccountCancelsAcknowledgement() {
        #expect(throws: CancellationError.self) { try validate(receipt(), generation: 14) }
    }
    @Test func signedOutAccountCancelsAcknowledgement() {
        #expect(throws: CancellationError.self) {
            try receipt().requireConfirmation(trip: trip, owner: owner, generation: 12,
                                              currentOwner: nil, currentGeneration: 12)
        }
    }
    @Test func malformedOrIncompleteReceiptsRemainQueued() {
        for raw in ["{}", "[]", #"{"absent":true}"#, #"{"absent":"true"}"#] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(TripDeleteAbsenceReceipt.self, from: Data(raw.utf8))
            }
        }
    }
    @Test func unresolvedProofCannotMatchLegacyMissingRowShortcut() {
        let error = TripDeleteAbsenceReceipt.Failure.unconfirmed
        let description = String(describing: error).lowercased() + error.localizedDescription.lowercased()
        #expect(!description.contains("not found"))
        #expect(!description.contains("no rows"))
        #expect(!description.contains("pgrst116"))
    }
}
