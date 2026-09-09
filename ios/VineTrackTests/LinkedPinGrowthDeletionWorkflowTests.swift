import XCTest
@testable import VineTrack

@MainActor
final class LinkedPinGrowthDeletionWorkflowTests: XCTestCase {
    func testLinkedDeleteFallsBackToGrowthRPCWhenRemotePinMirrorIsMissing() async throws {
        let pinRepository = DeletionPinRepository(missingDeletes: 1)
        let growthRepository = DeletionGrowthRepository()
        let service = GrowthStageRecordSyncService(
            repository: growthRepository,
            pinRepository: pinRepository,
            photoStorage: DeletionPhotoStorage(),
            persistence: temporaryPersistence()
        )
        let target = PendingLinkedPinGrowthDeletion(
            id: UUID(),
            vineyardId: UUID(),
            pinId: UUID(),
            growthRecordId: UUID(),
            queuedAt: Date(),
            growthSnapshot: nil,
            pinSnapshot: nil
        )

        try await service.deletePersistedTarget(target)

        let pinDeletes = await pinRepository.deleteCount()
        let growthDeletes = await growthRepository.deleteCount()
        XCTAssertEqual(pinDeletes, 1)
        XCTAssertEqual(growthDeletes, 1)
    }

    func testLinkedDeleteUsesTransactionalPinRPCWhenPinExistsEvenIfGrowthMirrorIsOnlyLocal() async throws {
        let pinRepository = DeletionPinRepository()
        let growthRepository = DeletionGrowthRepository()
        let service = GrowthStageRecordSyncService(
            repository: growthRepository,
            pinRepository: pinRepository,
            photoStorage: DeletionPhotoStorage(),
            persistence: temporaryPersistence()
        )
        let target = PendingLinkedPinGrowthDeletion(
            id: UUID(),
            vineyardId: UUID(),
            pinId: UUID(),
            growthRecordId: UUID(),
            queuedAt: Date(),
            growthSnapshot: nil,
            pinSnapshot: nil
        )

        try await service.deletePersistedTarget(target)

        let pinDeletes = await pinRepository.deleteCount()
        let growthDeletes = await growthRepository.deleteCount()
        XCTAssertEqual(pinDeletes, 1)
        XCTAssertEqual(growthDeletes, 0)
    }

    private func temporaryPersistence() -> PersistenceStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PersistenceStore(directory: directory)
    }
}

private nonisolated struct MissingDeleteError: LocalizedError {
    var errorDescription: String? { "record not found" }
}

private actor DeletionPinRepository: PinSyncRepositoryProtocol {
    private var deletes = 0
    private var missingDeletes: Int

    init(missingDeletes: Int = 0) { self.missingDeletes = missingDeletes }
    func fetchPins(vineyardId: UUID, since: Date?) async throws -> [BackendPin] { [] }
    func fetchAllPins(vineyardId: UUID) async throws -> [BackendPin] { [] }
    func upsertPin(_ pin: BackendPinUpsert) async throws {}
    func upsertPins(_ pins: [BackendPinUpsert]) async throws {}
    func updatePhotoPath(pinId: UUID, vineyardId: UUID, path: String?) async throws -> AttachmentReferenceConfirmation {
        AttachmentReferenceConfirmation(recordId: pinId, vineyardId: vineyardId, photoPath: path, photoPaths: nil)
    }
    func softDeletePin(id: UUID) async throws {
        deletes += 1
        if missingDeletes > 0 { missingDeletes -= 1; throw MissingDeleteError() }
    }
    func deleteCount() -> Int { deletes }
}

private actor DeletionGrowthRepository: GrowthStageRecordSyncRepositoryProtocol {
    private var deletes = 0
    func fetchGrowthStageRecords(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageRecord] { [] }
    func upsertGrowthStageRecord(_ record: BackendGrowthStageRecordUpsert) async throws {}
    func upsertGrowthStageRecords(_ records: [BackendGrowthStageRecordUpsert]) async throws {}
    func updatePhotoPaths(recordId: UUID, vineyardId: UUID, photoPaths: [String]) async throws -> AttachmentReferenceConfirmation {
        AttachmentReferenceConfirmation(recordId: recordId, vineyardId: vineyardId, photoPath: nil, photoPaths: photoPaths)
    }
    func softDeleteGrowthStageRecord(id: UUID) async throws { deletes += 1 }
    func deleteCount() -> Int { deletes }
}

private actor DeletionPhotoStorage: PinPhotoStorageProtocol {
    func uploadPhoto(vineyardId: UUID, pinId: UUID, revision: UUID, imageData: Data) async throws -> String { "pin.jpg" }
    func uploadGrowthPhoto(vineyardId: UUID, recordId: UUID, revision: UUID, imageData: Data) async throws -> String { "growth.jpg" }
    func downloadPhoto(path: String, vineyardId: UUID, pinId: UUID) async throws -> Data { Data() }
    func downloadGrowthPhoto(path: String, vineyardId: UUID, recordId: UUID) async throws -> Data { Data() }
}
