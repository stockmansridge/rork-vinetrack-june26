import XCTest
@testable import VineTrack

@MainActor
final class PinPhotoWorkflowTests: XCTestCase {
    func testFirstPhotoWithoutRemotePathUploadsAndReferences() async throws {
        let fixture = try makeFixture()
        try fixture.service.attachPhoto(pinId: fixture.pin.id, imageData: Data([1, 2, 3]))

        try await fixture.service.pushLocalPins(vineyardId: fixture.vineyardId)

        XCTAssertFalse(fixture.service.hasPendingPhoto(pinId: fixture.pin.id))
        let referencedPath = await fixture.pinRepository.lastPhotoPath()
        let uploadedPath = await fixture.storage.lastPath()
        XCTAssertEqual(referencedPath, uploadedPath)
        XCTAssertTrue(uploadedPath?.contains("photo-") == true)
    }

    func testMetadataSuccessDoesNotClearFailedPhotoAcrossRelaunch() async throws {
        let fixture = try makeFixture(storageFailure: true)
        try fixture.service.attachPhoto(pinId: fixture.pin.id, imageData: Data([4, 5, 6]))

        do {
            try await fixture.service.pushLocalPins(vineyardId: fixture.vineyardId)
            XCTFail("Expected upload failure")
        } catch {}

        XCTAssertTrue(fixture.service.hasPendingPhoto(pinId: fixture.pin.id))
        let relaunched = PinSyncService(
            repository: fixture.pinRepository,
            photoStorage: fixture.storage,
            persistence: fixture.persistence,
            deletionStore: fixture.deletionStore
        )
        XCTAssertTrue(relaunched.hasPendingPhoto(pinId: fixture.pin.id))
        let upsertCount = await fixture.pinRepository.upsertCount()
        XCTAssertEqual(upsertCount, 1)
    }

    func testUploadedObjectIsReusedWhenReferenceWriteRetries() async throws {
        let fixture = try makeFixture(photoReferenceFailures: 1)
        try fixture.service.attachPhoto(pinId: fixture.pin.id, imageData: Data([7, 8, 9]))
        do { try await fixture.service.pushLocalPins(vineyardId: fixture.vineyardId) } catch {}
        XCTAssertTrue(fixture.service.hasPendingPhoto(pinId: fixture.pin.id))

        try await fixture.service.pushLocalPins(vineyardId: fixture.vineyardId)

        let uploadCount = await fixture.storage.uploadCount()
        XCTAssertEqual(uploadCount, 1)
        XCTAssertFalse(fixture.service.hasPendingPhoto(pinId: fixture.pin.id))
    }

    func testGrowthPhotoReplacementPreservesUnrelatedPaths() {
        XCTAssertEqual(
            GrowthStageRecordSyncService.replacingOwnedPhoto(
                in: ["old.jpg", "evidence.jpg"],
                previousPath: "old.jpg",
                with: "revision.jpg"
            ),
            ["revision.jpg", "evidence.jpg"]
        )
    }

    func testCacheRevisionInvalidatesUnchangedPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SharedImageCache(baseDir: directory)
        let key = SharedImageCacheKey.pinPhoto(vineyardId: UUID(), pinId: UUID())
        let first = UUID()
        try cache.saveImageDataOrThrow(Data([1]), for: key, remotePath: "same.jpg", remoteUpdatedAt: nil, attachmentRevision: first)

        XCTAssertTrue(cache.isCacheCurrent(for: key, remotePath: "same.jpg", remoteUpdatedAt: nil, attachmentRevision: first))
        XCTAssertFalse(cache.isCacheCurrent(for: key, remotePath: "same.jpg", remoteUpdatedAt: nil, attachmentRevision: UUID()))
    }

    private func makeFixture(
        storageFailure: Bool = false,
        photoReferenceFailures: Int = 0
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: directory)
        let vineyardId = UUID()
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        let pin = VinePin(
            id: UUID(), vineyardId: vineyardId, latitude: -34, longitude: 138,
            heading: nil, buttonName: "Repair", buttonColor: "red", side: nil, mode: .repairs
        )
        let pinRepository = PinRepositoryDouble(photoReferenceFailures: photoReferenceFailures)
        let storage = PhotoStorageDouble(shouldFail: storageFailure)
        let deletionStore = LinkedPinGrowthDeletionStore(persistence: persistence)
        let service = PinSyncService(
            repository: pinRepository,
            photoStorage: storage,
            persistence: persistence,
            deletionStore: deletionStore
        )
        let auth = NewBackendAuthService()
        auth.userId = UUID()
        auth.isSignedIn = true
        service.configure(store: store, auth: auth)
        store.addPin(pin)
        return Fixture(vineyardId: vineyardId, pin: pin, store: store, persistence: persistence, service: service, pinRepository: pinRepository, storage: storage, deletionStore: deletionStore)
    }

    private struct Fixture {
        let vineyardId: UUID
        let pin: VinePin
        let store: MigratedDataStore
        let persistence: PersistenceStore
        let service: PinSyncService
        let pinRepository: PinRepositoryDouble
        let storage: PhotoStorageDouble
        let deletionStore: LinkedPinGrowthDeletionStore
    }
}

private actor PinRepositoryDouble: PinSyncRepositoryProtocol {
    private var upserts: Int = 0
    private var path: String?
    private var remainingPhotoFailures: Int

    init(photoReferenceFailures: Int) { remainingPhotoFailures = photoReferenceFailures }
    func fetchPins(vineyardId: UUID, since: Date?) async throws -> [BackendPin] { [] }
    func fetchAllPins(vineyardId: UUID) async throws -> [BackendPin] { [] }
    func upsertPin(_ pin: BackendPinUpsert) async throws { upserts += 1 }
    func upsertPins(_ pins: [BackendPinUpsert]) async throws { upserts += pins.count }
    func updatePhotoPath(pinId: UUID, vineyardId: UUID, path: String?) async throws -> AttachmentReferenceConfirmation {
        if remainingPhotoFailures > 0 {
            remainingPhotoFailures -= 1
            throw URLError(.cannotConnectToHost)
        }
        self.path = path
        return AttachmentReferenceConfirmation(
            recordId: pinId,
            vineyardId: vineyardId,
            photoPath: path,
            photoPaths: nil
        )
    }
    func softDeletePin(id: UUID) async throws {}
    func lastPhotoPath() -> String? { path }
    func upsertCount() -> Int { upserts }
}

private actor PhotoStorageDouble: PinPhotoStorageProtocol {
    private let shouldFail: Bool
    private var uploads: Int = 0
    private var path: String?

    init(shouldFail: Bool) { self.shouldFail = shouldFail }
    func uploadPhoto(vineyardId: UUID, pinId: UUID, revision: UUID, imageData: Data) async throws -> String {
        uploads += 1
        if shouldFail { throw URLError(.notConnectedToInternet) }
        let value = PinPhotoStorage.path(vineyardId: vineyardId, pinId: pinId, revision: revision)
        path = value
        return value
    }
    func uploadGrowthPhoto(vineyardId: UUID, recordId: UUID, revision: UUID, imageData: Data) async throws -> String {
        uploads += 1
        return PinPhotoStorage.growthPath(vineyardId: vineyardId, recordId: recordId, revision: revision)
    }
    func downloadPhoto(path: String, vineyardId: UUID, pinId: UUID) async throws -> Data { Data() }
    func downloadGrowthPhoto(path: String, vineyardId: UUID, recordId: UUID) async throws -> Data { Data() }
    func uploadCount() -> Int { uploads }
    func lastPath() -> String? { path }
}
