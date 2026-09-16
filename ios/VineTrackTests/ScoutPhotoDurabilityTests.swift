import Testing
import Foundation
@testable import VineTrack

/// Scout photograph durability — the iOS mirror of the Android
/// `ScoutPhotoDurabilityTest`.
///
/// A scouting photograph is evidence of a condition that existed at one moment
/// in one block, and it cannot be retaken later. So these tests hold one line:
/// the bytes reach storage BEFORE an upload is queued, a failed upload never
/// looks like a lost photograph, and a photograph that could not be written is
/// refused rather than displayed and then quietly lost.
@MainActor
struct ScoutPhotoDurabilityTests {

    private let vineyardID = UUID()
    private let otherVineyardID = UUID()
    private let blockA = UUID()

    /// A service plus the store it uses, so a test can inspect the queue
    /// directly rather than inferring it from the UI state.
    private func makeService() -> (service: VineyardInsightsService, store: VineyardInsightsStore) {
        let suiteName = "scout-photo-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = VineyardInsightsStore(defaults: defaults)
        let service = VineyardInsightsService(store: store)
        return (service, store)
    }

    private func jpeg(_ marker: UInt8 = 7) -> Data { Data([marker, 2, 3, 4]) }

    private func startVisit(
        _ service: VineyardInsightsService,
        vineyard: UUID? = nil
    ) -> ScoutVisit {
        service.startVisit(
            vineyardID: vineyard ?? vineyardID,
            scoutUserID: UUID(),
            scoutName: "Jonathan",
            seasonStartMonth: 7,
            seasonStartDay: 1,
            date: Date(timeIntervalSince1970: 1_795_000_000)
        )
    }

    private func openBlock(_ service: VineyardInsightsService, _ visit: ScoutVisit) -> UUID {
        service.toggleBlock(visitID: visit.id, paddockID: blockA)
        return service.visit(visit.id)!.assessment(paddockID: blockA)!.id
    }

    private let files = ScoutPhotoFileStore()

    // MARK: - Local-first capture

    @Test("Capture writes the bytes to storage before queueing the upload")
    func captureIsLocalFirst() {
        let (service, store) = makeService()
        let visit = startVisit(service)
        let id = openBlock(service, visit)

        let photo = service.capturePhoto(
            visitID: visit.id,
            assessmentID: id,
            item: .weeds,
            imageData: jpeg(),
            locationFix: nil,
            capturedByUserID: nil
        )

        #expect(photo != nil)
        #expect(photo?.localPath != nil)
        #expect(files.exists(atRelativePath: photo!.localPath!))
        #expect(store.loadPhotoQueue().count == 1)
        // No server path until it genuinely uploads.
        #expect(photo?.storagePath == nil)

        service.clearOnSignOut()
    }

    @Test("Several photographs for one item never overwrite one another")
    func photographsDoNotCollide() {
        let (service, store) = makeService()
        let visit = startVisit(service)
        let id = openBlock(service, visit)

        let first = service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds,
            imageData: jpeg(1), locationFix: nil, capturedByUserID: nil
        )
        let second = service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds,
            imageData: jpeg(2), locationFix: nil, capturedByUserID: nil
        )
        let third = service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds,
            imageData: jpeg(3), locationFix: nil, capturedByUserID: nil
        )

        let paths = [first, second, third].compactMap { $0?.localPath }
        #expect(paths.count == 3)
        #expect(Set(paths).count == 3)
        #expect(store.loadPhotoQueue().count == 3)
        let saved = service.visit(visit.id)?.assessment(paddockID: blockA)?.observation(.weeds)
        #expect(saved?.photos.count == 3)

        service.clearOnSignOut()
    }

    @Test("A photograph survives a reload from storage")
    func photographSurvivesReload() {
        let (service, store) = makeService()
        let visit = startVisit(service)
        let id = openBlock(service, visit)
        service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .powderyMildew,
            imageData: jpeg(), locationFix: nil, capturedByUserID: nil
        )

        let reloaded = store.loadVisits().first
        let photo = reloaded?
            .assessment(paddockID: blockA)?
            .observation(.powderyMildew)?
            .photos.first

        #expect(photo?.localPath != nil)
        #expect(files.exists(atRelativePath: photo!.localPath!))

        service.clearOnSignOut()
    }

    // MARK: - Location honesty

    @Test("A qualifying fix is the only way coordinates are stored")
    func onlyQualifiedFixBecomesCoordinates() {
        let (service, _) = makeService()
        let visit = startVisit(service)
        let id = openBlock(service, visit)

        let confirmed = service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds,
            imageData: jpeg(),
            locationFix: ScoutPhotoFix(latitude: -33.2835, longitude: 149.0988, accuracyMetres: 4.2),
            capturedByUserID: nil
        )
        let unavailable = service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds,
            imageData: jpeg(), locationFix: nil, capturedByUserID: nil
        )

        #expect(confirmed?.locationStatus == .gpsConfirmed)
        #expect(confirmed?.latitude == -33.2835)
        // No stale fix, no last-known position, no block centroid.
        #expect(unavailable?.locationStatus == .unavailable)
        #expect(unavailable?.latitude == nil)
        #expect(unavailable?.longitude == nil)
        #expect(unavailable?.accuracyMetres == nil)

        service.clearOnSignOut()
    }

    // MARK: - Deletion

    @Test("Deleting a pending photograph also invalidates its queued upload")
    func deletingPendingPhotoClearsQueue() {
        // Otherwise a replay already in flight could resurrect a photograph the
        // operator deliberately removed.
        let (service, store) = makeService()
        let visit = startVisit(service)
        let id = openBlock(service, visit)
        let photo = service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds,
            imageData: jpeg(), locationFix: nil, capturedByUserID: nil
        )!

        let removed = service.deletePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds, photoID: photo.id
        )

        #expect(removed)
        #expect(store.loadPhotoQueue().isEmpty)
        #expect(!files.exists(atRelativePath: photo.localPath!))
        #expect(service.visit(visit.id)?.assessment(paddockID: blockA)?.photoCount == 0)

        service.clearOnSignOut()
    }

    @Test("Deleting one photograph leaves the others and their uploads intact")
    func deletingOnePhotoKeepsOthers() {
        let (service, store) = makeService()
        let visit = startVisit(service)
        let id = openBlock(service, visit)
        let keep = service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds,
            imageData: jpeg(1), locationFix: nil, capturedByUserID: nil
        )!
        let drop = service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds,
            imageData: jpeg(2), locationFix: nil, capturedByUserID: nil
        )!

        service.deletePhoto(visitID: visit.id, assessmentID: id, item: .weeds, photoID: drop.id)

        #expect(store.loadPhotoQueue().map(\.id) == [keep.id])
        #expect(files.exists(atRelativePath: keep.localPath!))
        #expect(!files.exists(atRelativePath: drop.localPath!))

        service.clearOnSignOut()
    }

    // MARK: - Queue ownership

    @Test("A queued photograph keeps the vineyard it was captured in")
    func queuedPhotoKeepsItsVineyard() {
        // An operator who scouts one vineyard, drives home, switches vineyards
        // and reconnects must not have their morning filed against someone
        // else's business.
        let (service, store) = makeService()
        let first = startVisit(service)
        let firstAssessment = openBlock(service, first)
        service.capturePhoto(
            visitID: first.id, assessmentID: firstAssessment, item: .weeds,
            imageData: jpeg(), locationFix: nil, capturedByUserID: nil
        )

        let second = startVisit(service, vineyard: otherVineyardID)
        let secondAssessment = openBlock(service, second)
        service.capturePhoto(
            visitID: second.id, assessmentID: secondAssessment, item: .weeds,
            imageData: jpeg(), locationFix: nil, capturedByUserID: nil
        )

        let queue = store.loadPhotoQueue()
        #expect(queue.count == 2)
        #expect(Set(queue.map(\.vineyardID)) == [vineyardID, otherVineyardID])
        #expect(queue.filter { $0.vineyardID == vineyardID }.count == 1)

        service.clearOnSignOut()
    }

    @Test("The storage path is scoped by vineyard so the bucket policy authorises it")
    func storagePathIsVineyardScoped() {
        // SQL 236 authorises on storage_first_folder_uuid(name), so any other
        // shape would be refused by the bucket rather than silently misfiled.
        let (service, store) = makeService()
        let visit = startVisit(service)
        let id = openBlock(service, visit)
        service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds,
            imageData: jpeg(), locationFix: nil, capturedByUserID: nil
        )
        let entry = store.loadPhotoQueue().first!

        let path = ScoutPhotoFileStore.storagePath(
            vineyardID: entry.vineyardID,
            observationID: entry.observationID,
            photoID: entry.id
        )

        #expect(path.hasPrefix("\(vineyardID.uuidString.lowercased())/"))
        #expect(path.hasSuffix(".jpg"))

        service.clearOnSignOut()
    }

    // MARK: - Sign-out

    @Test("Sign out removes the photographs as well as the records")
    func signOutClearsPhotographs() {
        // This is unreleased System Admin data and the next person to sign in
        // on the handset may be someone else entirely.
        let (service, store) = makeService()
        let visit = startVisit(service)
        let id = openBlock(service, visit)
        let photo = service.capturePhoto(
            visitID: visit.id, assessmentID: id, item: .weeds,
            imageData: jpeg(), locationFix: nil, capturedByUserID: nil
        )!

        service.clearOnSignOut()

        #expect(!files.exists(atRelativePath: photo.localPath!))
        #expect(store.loadPhotoQueue().isEmpty)
        #expect(service.visits.isEmpty)
    }

    // MARK: - E-L linkage

    @Test("Unlinking a Growth Stage record keeps the canonical record")
    func unlinkKeepsCanonicalRecord() {
        // The observation genuinely happened; only the scout's citation of it
        // is removed. The retention notice states this before the operator
        // commits.
        let (service, _) = makeService()
        let visit = startVisit(service)
        let id = openBlock(service, visit)
        let recordID = UUID()
        service.linkGrowthStageRecord(
            visitID: visit.id,
            assessmentID: id,
            pinID: UUID(),
            recordID: recordID,
            stageLabel: "EL23 - 80% cap fall"
        )

        service.unlinkGrowthStageRecord(visitID: visit.id, assessmentID: id)

        let saved = service.visit(visit.id)?.assessment(paddockID: blockA)?.observation(.growthStage)
        #expect(saved?.linkedGrowthStageRecordID == nil)
        #expect(saved?.linkedPinID == nil)
        // Nothing here deletes phenology, and the notice says so.
        #expect(ScoutGrowthStageLink.retentionNotice.contains("are kept"))

        service.clearOnSignOut()
    }

    @Test("A linked E-L observation records both canonical ids and no rival stage value")
    func linkStoresBothCanonicalIDs() {
        let (service, _) = makeService()
        let visit = startVisit(service)
        let id = openBlock(service, visit)
        let pinID = UUID()
        let recordID = UUID()

        service.linkGrowthStageRecord(
            visitID: visit.id,
            assessmentID: id,
            pinID: pinID,
            recordID: recordID,
            stageLabel: "EL23 - 80% cap fall"
        )

        let saved = service.visit(visit.id)?.assessment(paddockID: blockA)?.observation(.growthStage)
        #expect(saved?.linkedPinID == pinID)
        #expect(saved?.linkedGrowthStageRecordID == recordID)
        // The label is a presentation snapshot; the stage VALUE stays canonical.
        #expect(saved?.valueLabel == "EL23 - 80% cap fall")
        #expect(saved?.valueCode == nil)

        service.clearOnSignOut()
    }

    @Test("An offline replay of the same E-L selection is planned as unchanged")
    func replayOfSameStageIsNoOp() {
        // Creating a second record on retry is the duplication the link
        // contract exists to prevent.
        let observationID = UUID()
        let recordID = UUID()

        let plan = ScoutGrowthStageLink.plan(
            observationID: observationID,
            vineyardID: vineyardID,
            paddockID: blockA,
            existingRecordID: recordID,
            existingStageCode: "EL23",
            selectedStageCode: "EL23"
        )

        #expect(plan == .unchanged(growthStageRecordID: recordID))
    }
}
