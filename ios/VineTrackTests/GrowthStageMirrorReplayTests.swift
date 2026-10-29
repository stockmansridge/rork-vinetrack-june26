import Testing
import Foundation
@testable import VineTrack

/// Positive server identity alone does not permit overwriting an offline edit.
struct GrowthStageMirrorReplayTests {
    private func pair() -> (GrowthStageRecord, BackendGrowthStageRecord) {
        let vineyard = UUID(), pin = UUID(), block = UUID(), owner = UUID()
        let when = Date(timeIntervalSince1970: 1_780_000_000)
        let local = GrowthStageRecord(
            vineyardId: vineyard, paddockId: block, pinId: pin,
            stageCode: "EL13", observedAt: when, latitude: -33.1,
            longitude: 149.1, notes: "saved note", createdBy: owner,
            createdAt: when, updatedAt: when
        )
        let remote = BackendGrowthStageRecord(
            id: UUID(), vineyardId: vineyard, paddockId: block, pinId: pin,
            stageCode: "EL13", stageLabel: nil, variety: nil, varietyId: nil,
            observedAt: when, latitude: -33.1, longitude: 149.1,
            rowNumber: nil, side: nil, notes: "saved note",
            photoPaths: [], recordedByName: nil, createdBy: owner,
            updatedBy: nil, createdAt: when, updatedAt: when,
            clientUpdatedAt: nil, syncVersion: 1, deletedAt: nil
        )
        return (local, remote)
    }

    @Test("Identical historical pin mirror may resolve to server identity")
    func sameMirror() {
        let (local, remote) = pair()
        #expect(GrowthStageMirrorReplay.isUnmodifiedBackfill(local, of: remote))
    }

    @Test("Different stage cannot be auto-acknowledged")
    func changedStage() {
        let (local, remote) = pair()
        var changed = local
        changed.stageCode = "EL15"
        #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(changed, of: remote))
    }

    @Test("Unsynced note cannot be auto-acknowledged")
    func changedNote() {
        let (local, remote) = pair()
        var changed = local
        changed.notes = "new offline note"
        #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(changed, of: remote))
    }

    @Test("Edited timestamp cannot be auto-acknowledged")
    func changedTime() {
        let (local, remote) = pair()
        var changed = local
        changed.updatedAt = Date(timeIntervalSince1970: 1_780_000_100)
        #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(changed, of: remote))
    }

    @Test("Unsynced photo cannot be auto-acknowledged")
    func changedPhoto() {
        let (local, remote) = pair()
        var changed = local
        changed.photoPaths = ["local/photo.jpg"]
        #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(changed, of: remote))
    }

    @Test("Different vineyard cannot be auto-acknowledged")
    func changedVineyard() {
        let (local, remote) = pair()
        var changed = local
        changed.vineyardId = UUID()
        #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(changed, of: remote))
    }
}
