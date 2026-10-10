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

private actor DeletionPinRepository: PinSyncRepositoryProtocol {
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

private actor DeletionGrowthRepository: GrowthStageRecordSyncRepositoryProtocol {
    private var deletes = 0
    private let failure: (any Error)?
    init(failure: (any Error)? = nil) { self.failure = failure }
    func fetchGrowthStageRecords(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageRecord] { [] }
    func upsertGrowthStageRecord(_ record: BackendGrowthStageRecordUpsert) async throws {}
    func upsertGrowthStageRecords(_ records: [BackendGrowthStageRecordUpsert]) async throws {}
    func updatePhotoPaths(recordId: UUID, vineyardId: UUID, photoPaths: [String]) async throws -> AttachmentReferenceConfirmation {
        AttachmentReferenceConfirmation(recordId: recordId, vineyardId: vineyardId, photoPath: nil, photoPaths: photoPaths)
    }
    func softDeleteGrowthStageRecord(id: UUID) async throws {
        deletes += 1
        if let failure { throw failure }
    }
    func deleteCount() -> Int { deletes }
}

private actor DeletionPhotoStorage: PinPhotoStorageProtocol {
    func uploadPhoto(vineyardId: UUID, pinId: UUID, revision: UUID, imageData: Data) async throws -> String { "pin.jpg" }
    func uploadGrowthPhoto(vineyardId: UUID, recordId: UUID, revision: UUID, imageData: Data) async throws -> String { "growth.jpg" }
    func downloadPhoto(path: String, vineyardId: UUID, pinId: UUID) async throws -> Data { Data() }
    func downloadGrowthPhoto(path: String, vineyardId: UUID, recordId: UUID) async throws -> Data { Data() }
}
