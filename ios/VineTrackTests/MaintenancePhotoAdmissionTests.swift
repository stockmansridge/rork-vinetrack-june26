import Foundation
import Testing
import Supabase
@testable import VineTrack

@MainActor
struct MaintenancePhotoAdmissionTests {
    @Test func newerMaintenanceRevisionSurvivesOlderAcknowledgementAcrossRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = UUID(), old = Date(timeIntervalSince1970: 100), newer = Date(timeIntervalSince1970: 200)
        let metadata = OperationsSyncMetadata(key: "maintenance-revision", persistence: PersistenceStore(directory: directory))
        metadata.markDirty(record, at: old)
        let captured = metadata.pendingUpserts
        metadata.markDirty(record, at: newer)
        metadata.acknowledgeMaintenanceMetadata([record], pendingPhotos: [], expected: captured)
        let recreated = OperationsSyncMetadata(key: "maintenance-revision", persistence: PersistenceStore(directory: directory))
        #expect(recreated.pendingUpserts == [record: newer])
        recreated.acknowledgeMaintenanceMetadata([record], pendingPhotos: [], expected: [record: newer])
        #expect(recreated.pendingUpserts.isEmpty)
    }

    @Test func attachmentPathsRejectTraversalAndDoNotBorrowSelectedOwner() throws {
        let owner = UUID(), other = UUID()
        #expect(try VineyardAttachmentPath.vineyard(VineyardLogoStorage.path(for: owner)) == owner)
        #expect(try VineyardAttachmentPath.vineyard(ELStageImageStorage.path(vineyardId: other, stageCode: "EL 4")) == other)
        for path in ["\(owner)/../logo.jpg", "\(owner)//logo.jpg", "\(owner)/logo.jpg?other", "\(owner)/%2e%2e/photo.jpg", "not-a-vineyard/photo.jpg"] {
            #expect(throws: (any Error).self) { try VineyardAttachmentPath.vineyard(path) }
        }
    }

    @Test func heldUploadAndDeleteKeepEvidenceAndNeverReadOrSend() async throws {
        let user = UUID(), vineyard = UUID(), record = UUID(), other = UUID()
        let defaults = UserDefaults(suiteName: "maintenance-" + UUID().uuidString)!
        let gate = VineyardWriteAuthority(defaults: defaults)
        gate.bind(userId: user)
        gate.hold(vineyardId: vineyard.uuidString, reason: "VT_READ_ONLY")
        var reads = 0, sends = 0
        let service = MaintenancePhotoStorageService(
            admission: { try VineyardMutationAdmission(currentUserId: { user }, authority: gate) },
            readOwnership: { id in reads += 1; return [.init(id: id, vineyardId: vineyard)] },
            upload: { _, _ in sends += 1 }, remove: { _ in sends += 1 })
        let bytes = Data([1, 2, 3])
        let path = MaintenancePhotoStorage.path(vineyardId: vineyard, maintenanceId: record)
        SharedImageCache.shared.saveImageData(bytes, for: .maintenancePhoto(vineyardId: vineyard, maintenanceId: record), remotePath: path, remoteUpdatedAt: nil)
        do { _ = try await service.uploadPhoto(vineyardId: vineyard, maintenanceId: record, imageData: bytes); Issue.record("Held upload sent") }
        catch { #expect(error is VineyardWriteAuthority.Restricted) }
        do { try await service.deletePhoto(path: path); Issue.record("Held delete sent") }
        catch { #expect(error is VineyardWriteAuthority.Restricted) }
        #expect(reads == 0 && sends == 0)
        #expect(SharedImageCache.shared.cachedImageData(for: .maintenancePhoto(vineyardId: vineyard, maintenanceId: record)) == bytes)
        #expect(SharedImageCache.shared.metadata(for: .maintenancePhoto(vineyardId: vineyard, maintenanceId: record))?.remotePath == path)
        #expect(bytes == Data([1, 2, 3]))
        // Restoring the durable ledger and binding writable B cannot release A.
        let restored = VineyardWriteAuthority(defaults: defaults)
        restored.bind(userId: user)
        #expect(!restored.canWrite(vineyardId: vineyard.uuidString))
        #expect(restored.canWrite(vineyardId: other.uuidString))
    }

    @Test func exactOwningWritableAuthorityResumesOriginalPathAndBytes() async throws {
        let user = UUID(), vineyard = UUID(), record = UUID()
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        gate.bind(userId: user)
        let bytes = Data([7, 8, 9])
        let path = MaintenancePhotoStorage.path(vineyardId: vineyard, maintenanceId: record)
        var sent: [(String, Data)] = []
        let service = MaintenancePhotoStorageService(
            admission: { try VineyardMutationAdmission(currentUserId: { user }, authority: gate) },
            readOwnership: { id in [.init(id: id, vineyardId: vineyard)] },
            upload: { key, data in sent.append((key, data)) }, remove: { _ in })
        let result = try await service.uploadPhoto(vineyardId: vineyard, maintenanceId: record, imageData: bytes)
        #expect(result == path && sent.count == 1 && sent.first?.0 == path && sent.first?.1 == bytes)
    }

    @Test func expiryDuringUploadPreservesReceiptAndStopsDelete() async throws {
        let user = UUID(), vineyard = UUID(), record = UUID()
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        gate.bind(userId: user)
        var sends = 0
        let service = MaintenancePhotoStorageService(
            admission: { try VineyardMutationAdmission(currentUserId: { user }, authority: gate) },
            readOwnership: { id in [.init(id: id, vineyardId: vineyard)] },
            upload: { _, _ in sends += 1; gate.hold(vineyardId: vineyard.uuidString, reason: "VT_READ_ONLY") },
            remove: { _ in sends += 1 })
        let path = try await service.uploadPhoto(vineyardId: vineyard, maintenanceId: record, imageData: Data([4]))
        #expect(path == MaintenancePhotoStorage.path(vineyardId: vineyard, maintenanceId: record))
        do { try await service.deletePhoto(path: path); Issue.record("Subsequent delete escaped") }
        catch { #expect(error is VineyardWriteAuthority.Restricted) }
        #expect(sends == 1)
    }

    @Test func malformedAndWrongOwnerDeletesNeverSend() async throws {
        let user = UUID(), vineyard = UUID(), other = UUID(), record = UUID()
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        gate.bind(userId: user)
        var sends = 0
        let service = MaintenancePhotoStorageService(
            admission: { try VineyardMutationAdmission(currentUserId: { user }, authority: gate) },
            readOwnership: { id in [.init(id: id, vineyardId: other)] },
            upload: { _, _ in sends += 1 }, remove: { _ in sends += 1 })
        let path = MaintenancePhotoStorage.path(vineyardId: vineyard, maintenanceId: record)
        for key in [path, path + "?scope=other", "\(vineyard)/maintenance/../photo.jpg"] {
            do { try await service.deletePhoto(path: key); Issue.record("Wrong owner or malformed path sent") }
            catch { #expect(error is VineyardWriteAuthority.Restricted) }
        }
        do { try await service.deletePhoto(path: path, vineyardId: other, maintenanceId: record); Issue.record("Hint retargeted delete") }
        catch { #expect(error is VineyardWriteAuthority.Restricted) }
        #expect(sends == 0)
    }

    @Test func sameUserNewIncarnationDuringOwnershipReadCannotSend() async throws {
        let user = UUID(), vineyard = UUID(), record = UUID()
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        gate.bind(userId: user)
        var sends = 0
        let service = MaintenancePhotoStorageService(
            admission: { try VineyardMutationAdmission(currentUserId: { user }, authority: gate) },
            readOwnership: { id in
                gate.bind(userId: nil); gate.bind(userId: user)
                return [.init(id: id, vineyardId: vineyard)]
            }, upload: { _, _ in sends += 1 }, remove: { _ in sends += 1 })
        do { _ = try await service.uploadPhoto(vineyardId: vineyard, maintenanceId: record, imageData: Data([6])); Issue.record("Stale operation sent") }
        catch { #expect(error is BackendRepositoryError) }
        #expect(sends == 0)
    }

    @Test func structuredSDKStorageExpiryHoldsButOrdinaryForbiddenDoesNot() async throws {
        let user = UUID(), vineyard = UUID(), record = UUID()
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        gate.bind(userId: user)
        var code = "AccessDenied", sends = 0
        let service = MaintenancePhotoStorageService(
            admission: { try VineyardMutationAdmission(currentUserId: { user }, authority: gate) },
            readOwnership: { id in [.init(id: id, vineyardId: vineyard)] },
            upload: { _, _ in sends += 1; throw StorageError(statusCode: "403", message: "VT_READ_ONLY", error: code) },
            remove: { _ in sends += 1 })
        do { _ = try await service.uploadPhoto(vineyardId: vineyard, maintenanceId: record, imageData: Data([1])); Issue.record("Expected rejection") }
        catch { #expect(error is StorageError) }
        #expect(gate.canWrite(vineyardId: vineyard.uuidString))
        code = "VT_READ_ONLY"
        do { _ = try await service.uploadPhoto(vineyardId: vineyard, maintenanceId: record, imageData: Data([1])); Issue.record("Expected hold") }
        catch { #expect(error is VineyardWriteAuthority.Restricted) }
        #expect(!gate.canWrite(vineyardId: vineyard.uuidString))
        do { try await service.deletePhoto(path: MaintenancePhotoStorage.path(vineyardId: vineyard, maintenanceId: record)); Issue.record("Held delete sent") }
        catch { #expect(error is VineyardWriteAuthority.Restricted) }
        #expect(sends == 2)
    }

    @Test func successfulMetadataDoesNotLoseOriginalPhotoRetryAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let metadata = OperationsSyncMetadata(key: "maintenance-test", persistence: persistence)
        let photo = UUID(), complete = UUID(), timestamp = Date(timeIntervalSince1970: 12345)
        metadata.markDirty(photo, at: timestamp)
        metadata.markDirty(complete, at: timestamp)
        metadata.acknowledgeMaintenanceMetadata([photo, complete], pendingPhotos: [photo])
        let restored = OperationsSyncMetadata(key: "maintenance-test", persistence: PersistenceStore(directory: directory))
        #expect(restored.pendingUpserts == [photo: timestamp])
        #expect(restored.failedUpsertIds.isEmpty)
        restored.acknowledgeMaintenanceMetadata([photo], pendingPhotos: [])
        #expect(restored.pendingUpserts.isEmpty)
    }
}
