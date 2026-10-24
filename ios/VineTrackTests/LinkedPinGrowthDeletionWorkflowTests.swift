import XCTest
import Foundation
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

    func testLocalizedRecordMissingMessagesPermitOnlyTheLinkedFallback() async throws {
        for message in ["Pin not found", "Growth stage record not found"] {
            let pins = DeletionPinRepository(failure: DeletionFixtureError(message: message))
            let growth = DeletionGrowthRepository()
            let service = GrowthStageRecordSyncService(repository: growth, pinRepository: pins,
                photoStorage: DeletionPhotoStorage(), persistence: temporaryPersistence())
            let target = PendingLinkedPinGrowthDeletion(id: UUID(), vineyardId: UUID(), pinId: UUID(),
                growthRecordId: UUID(), queuedAt: Date(), growthSnapshot: nil, pinSnapshot: nil)
            try await service.deletePersistedTarget(target)
            let pinCount = await pins.deleteCount()
            let growthCount = await growth.deleteCount()
            XCTAssertEqual(pinCount, 1)
            XCTAssertEqual(growthCount, 1)
        }
    }

    func testUnrelatedDeletionFailuresPropagateWithoutGrowthFallback() async {
        let failures: [any Error] = [
            DeletionFixtureError(message: "permission denied"),
            DeletionFixtureError(message: "permission denied: record not found"),
            DeletionFixtureError(message: "unauthorized"),
            DeletionFixtureError(message: "required server function not found"),
            DeletionFixtureError(message: "storage object not found"),
            DeletionFixtureError(message: "unexpected deletion failure"),
            URLError(.timedOut)
        ]
        for failure in failures {
            let pins = DeletionPinRepository(failure: failure)
            let growth = DeletionGrowthRepository()
            let service = GrowthStageRecordSyncService(repository: growth, pinRepository: pins,
                photoStorage: DeletionPhotoStorage(), persistence: temporaryPersistence())
            let target = PendingLinkedPinGrowthDeletion(id: UUID(), vineyardId: UUID(), pinId: UUID(),
                growthRecordId: UUID(), queuedAt: Date(), growthSnapshot: nil, pinSnapshot: nil)
            do {
                try await service.deletePersistedTarget(target)
                XCTFail("An unrelated deletion error must propagate")
            } catch {
                if let expected = failure as? DeletionFixtureError {
                    XCTAssertEqual((error as? DeletionFixtureError)?.message, expected.message)
                } else {
                    XCTAssertEqual((error as? URLError)?.code, .timedOut)
                }
            }
            let pinCount = await pins.deleteCount()
            let growthCount = await growth.deleteCount()
            XCTAssertEqual(pinCount, 1)
            XCTAssertEqual(growthCount, 0)
        }
    }

    func testMissingPinFallbackPropagatesUnrelatedGrowthFailure() async {
        let pins = DeletionPinRepository(missingDeletes: 1)
        let growth = DeletionGrowthRepository(failure: DeletionFixtureError(message: "permission denied"))
        let service = GrowthStageRecordSyncService(repository: growth, pinRepository: pins,
            photoStorage: DeletionPhotoStorage(), persistence: temporaryPersistence())
        let target = PendingLinkedPinGrowthDeletion(id: UUID(), vineyardId: UUID(), pinId: UUID(),
            growthRecordId: UUID(), queuedAt: Date(), growthSnapshot: nil, pinSnapshot: nil)
        do {
            try await service.deletePersistedTarget(target)
            XCTFail("Growth fallback rejection must propagate")
        } catch {
            XCTAssertEqual((error as? DeletionFixtureError)?.message, "permission denied")
        }
        let pinCount = await pins.deleteCount()
        let growthCount = await growth.deleteCount()
        XCTAssertEqual(pinCount, 1)
        XCTAssertEqual(growthCount, 1)
    }

    func testHeldLocalOnlyGrowthDeleteAndIndependentReplayPreserveOriginalRecordPhotoAndMetadata() async throws {
        let disk = temporaryPersistence(), vineyard = UUID(), owner = UUID()
        // Persistence uses ISO-8601 whole seconds; keep the original fixture at
        // that precision so equality detects hold-time changes, not decoding.
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
        let record = GrowthStageRecord(vineyardId: vineyard, stageCode: "EL4", observedAt: timestamp,
            createdBy: owner, createdAt: timestamp, updatedAt: timestamp)
        try disk.saveOrThrow([record], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: disk)
        let originalDate = Date(timeIntervalSince1970: 1_790_000_000)
        metadata.markDirty(record.id, at: originalDate)
        let store = MigratedDataStore(persistence: disk)
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: "growth-hold-" + UUID().uuidString)!)
        gate.bind(userId: owner)
        store.operationalWriteAuthority = gate
        let auth = NewBackendAuthService()
        auth.userId = owner
        auth.isSignedIn = true
        let growth = DeletionGrowthRepository(), photos = DeletionPhotoStorage()
        let service = GrowthStageRecordSyncService(repository: growth, photoStorage: photos, metadata: metadata,
            persistence: disk, deletionStore: LinkedPinGrowthDeletionStore(persistence: disk))
        service.configure(store: store, auth: auth)
        let bytes = Data([51, 52, 53])
        try service.attachPhoto(recordId: record.id, imageData: bytes)
        let revision = service.attachmentRevision(recordId: record.id)
        gate.hold(vineyardId: vineyard.uuidString, reason: "VT_READ_ONLY")
        XCTAssertThrowsError(try service.deleteRecord(id: record.id)) { error in
            XCTAssertTrue(error is VineyardWriteAuthority.Restricted)
        }
        XCTAssertThrowsError(try service.attachPhoto(recordId: record.id, imageData: Data([99])))
        try await service.pushQueuedGrowthRecords(vineyardId: vineyard)
        try await service.pushPendingPhotos(vineyardId: vineyard)
        XCTAssertEqual(service.records, [record])
        XCTAssertEqual(service.localPhotoData(recordId: record.id), bytes)
        XCTAssertEqual(service.attachmentRevision(recordId: record.id), revision)
        XCTAssertEqual(metadata.pendingUpserts, [record.id: originalDate])
        XCTAssertFalse(metadata.isUnknownOutcome(record.id))
        XCTAssertEqual(growth.writeCount, 0)
        XCTAssertEqual(photos.uploadCount, 0)
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

private nonisolated struct DeletionFixtureError: LocalizedError, CustomStringConvertible {
    let message: String
    var errorDescription: String? { message }
    var description: String { "Deletion fixture error" }
}

@MainActor private final class DeletionPinRepository: PinSyncRepositoryProtocol {
    private var deletes = 0
    private var missingDeletes: Int

    private let failure: (any Error)?
    init(missingDeletes: Int = 0, failure: (any Error)? = nil) {
        self.missingDeletes = missingDeletes
        self.failure = failure
    }
    func fetchPins(vineyardId: UUID, since: Date?) async throws -> [BackendPin] { [] }
    func fetchAllPins(vineyardId: UUID) async throws -> [BackendPin] { [] }
    func upsertPin(_ pin: BackendPinUpsert) async throws {}
    func upsertPins(_ pins: [BackendPinUpsert]) async throws {}
    func updatePhotoPath(pinId: UUID, vineyardId: UUID, path: String?) async throws -> AttachmentReferenceConfirmation {
        AttachmentReferenceConfirmation(recordId: pinId, vineyardId: vineyardId, photoPath: path, photoPaths: nil)
    }
    func softDeletePin(id: UUID) async throws {
        deletes += 1
        if let failure { throw failure }
        if missingDeletes > 0 { missingDeletes -= 1; throw MissingDeleteError() }
    }
    func deleteCount() -> Int { deletes }
}

@MainActor private final class DeletionGrowthRepository: GrowthStageRecordSyncRepositoryProtocol {
    private var deletes = 0
    private(set) var writeCount = 0
    private let failure: (any Error)?
    init(failure: (any Error)? = nil) { self.failure = failure }
    func fetchGrowthStageRecords(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageRecord] { [] }
    func upsertGrowthStageRecord(_ record: BackendGrowthStageRecordUpsert) async throws { writeCount += 1 }
    func upsertGrowthStageRecords(_ records: [BackendGrowthStageRecordUpsert]) async throws { writeCount += 1 }
    func updatePhotoPaths(recordId: UUID, vineyardId: UUID, photoPaths: [String]) async throws -> AttachmentReferenceConfirmation {
        AttachmentReferenceConfirmation(recordId: recordId, vineyardId: vineyardId, photoPath: nil, photoPaths: photoPaths)
    }
    func softDeleteGrowthStageRecord(id: UUID) async throws {
        deletes += 1
        if let failure { throw failure }
    }
    func deleteCount() -> Int { deletes }
}

@MainActor private final class DeletionPhotoStorage: PinPhotoStorageProtocol {
    private(set) var uploadCount = 0
    func uploadPhoto(vineyardId: UUID, pinId: UUID, revision: UUID, imageData: Data) async throws -> String { uploadCount += 1; return "pin.jpg" }
    func uploadGrowthPhoto(vineyardId: UUID, recordId: UUID, revision: UUID, imageData: Data) async throws -> String { uploadCount += 1; return "growth.jpg" }
    func downloadPhoto(path: String, vineyardId: UUID, pinId: UUID) async throws -> Data { Data() }
    func downloadGrowthPhoto(path: String, vineyardId: UUID, recordId: UUID) async throws -> Data { Data() }
}
