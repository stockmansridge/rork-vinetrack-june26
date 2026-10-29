import Testing
import Foundation
@testable import VineTrack

/// Six PR19 regressions, with service-level preservation checks below.
@MainActor struct GrowthStageMirrorReplayTests {
    private func pair() -> (GrowthStageRecord, BackendGrowthStageRecord) {
        let when = Date(timeIntervalSince1970: 1_780_000_000)
        let local = GrowthStageRecord(vineyardId: UUID(), paddockId: UUID(), pinId: UUID(), stageCode: "EL13",
            observedAt: when, latitude: -33.1, longitude: 149.1, notes: "saved note", createdBy: UUID(), createdAt: when, updatedAt: when)
        return (local, server(local))
    }
    private func server(_ local: GrowthStageRecord, id: UUID = UUID(), author: UUID? = nil) -> BackendGrowthStageRecord {
        BackendGrowthStageRecord(id: id, vineyardId: local.vineyardId, paddockId: local.paddockId, pinId: local.pinId,
            stageCode: local.stageCode, stageLabel: local.stageLabel, variety: local.variety, varietyId: local.varietyId,
            observedAt: local.observedAt, latitude: local.latitude, longitude: local.longitude, rowNumber: local.rowNumber,
            side: local.side, notes: local.notes, photoPaths: local.photoPaths, recordedByName: local.recordedByName,
            createdBy: author ?? local.createdBy, updatedBy: nil, createdAt: local.createdAt, updatedAt: local.updatedAt,
            clientUpdatedAt: nil, syncVersion: 1, deletedAt: nil)
    }
    private func disk() throws -> PersistenceStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return PersistenceStore(directory: url)
    }
    @Test func sameMirror() { let (l, r) = pair(); #expect(GrowthStageMirrorReplay.isUnmodifiedBackfill(l, of: r)) }
    @Test func changedStage() { var (l, r) = pair(); l.stageCode = "EL15"; #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(l, of: r)) }
    @Test func changedNote() { var (l, r) = pair(); l.notes = "new offline note"; #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(l, of: r)) }
    @Test func changedTime() { var (l, r) = pair(); l.updatedAt.addTimeInterval(100); #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(l, of: r)) }
    @Test func changedPhoto() { var (l, r) = pair(); l.photoPaths = ["local/photo.jpg"]; #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(l, of: r)) }
    @Test func changedVineyard() { var (l, r) = pair(); l.vineyardId = UUID(); #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(l, of: r)) }

    @Test func delayedHistoricalFieldCaptureIsRecognisedOnlyWithIndependentSaveTimeProof() {
        let (local, original) = pair()
        func remote(observedLag: TimeInterval, savedLag: TimeInterval) -> BackendGrowthStageRecord {
            BackendGrowthStageRecord(id: original.id, vineyardId: original.vineyardId,
                paddockId: original.paddockId, pinId: original.pinId, stageCode: original.stageCode,
                stageLabel: original.stageLabel, variety: original.variety, varietyId: original.varietyId,
                observedAt: local.observedAt.addingTimeInterval(-observedLag), latitude: original.latitude,
                longitude: original.longitude, rowNumber: original.rowNumber, side: original.side,
                notes: original.notes, photoPaths: original.photoPaths,
                recordedByName: original.recordedByName, createdBy: original.createdBy,
                updatedBy: original.updatedBy, createdAt: local.createdAt.addingTimeInterval(savedLag),
                updatedAt: original.updatedAt, clientUpdatedAt: nil, syncVersion: 1, deletedAt: nil)
        }
        #expect(GrowthStageMirrorReplay.isUnmodifiedBackfill(local, of: remote(observedLag: 98, savedLag: 0.4)))
        #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(local, of: remote(observedLag: 121, savedLag: 0.4)))
        #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(local, of: remote(observedLag: 98, savedLag: 4)))
    }

    @Test func cleanStaleCanonicalCacheIsUpdatedWithoutDroppingMirrorEvidence() async throws {
        let (local, remote) = pair(), storage = try disk()
        var oldCachedCanonical = remote.toGrowthStageRecord()
        oldCachedCanonical.notes = "older remote version"
        oldCachedCanonical.updatedAt.addTimeInterval(-100)
        storage.save([local, oldCachedCanonical], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: storage)
        metadata.markDirty(local.id, at: Date())
        let updatedRemote = BackendGrowthStageRecord(
            id: remote.id, vineyardId: remote.vineyardId, paddockId: remote.paddockId,
            pinId: remote.pinId, stageCode: remote.stageCode, stageLabel: remote.stageLabel,
            variety: remote.variety, varietyId: remote.varietyId, observedAt: remote.observedAt,
            latitude: remote.latitude, longitude: remote.longitude, rowNumber: remote.rowNumber,
            side: remote.side, notes: remote.notes, photoPaths: remote.photoPaths,
            recordedByName: remote.recordedByName, createdBy: remote.createdBy, updatedBy: remote.updatedBy,
            createdAt: remote.createdAt, updatedAt: local.updatedAt.addingTimeInterval(1),
            clientUpdatedAt: nil, syncVersion: 2, deletedAt: nil)
        let repo = MirrorReplayRepository(rows: [updatedRemote])
        let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage)
        try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
        #expect(service.pendingUpsertCount == 0)
        #expect(service.records.map(\\.id) == [updatedRemote.id])
        #expect(service.records.first?.notes == remote.notes)
        let archive: [UUID: GrowthStageRecordSyncService.MirrorIdentityEvidence] =
            storage.load(key: "vinetrack_growth_mirror_identity_evidence_v1") ?? [:]
        #expect(archive[local.id]?.original == local)
        #expect(repo.uploaded.isEmpty)
    }


    @Test func synthetic230MirrorsReconcileWithoutRemoteWritesAndRetainOriginalEvidenceAcrossRestart() async throws {
        let (sample, _) = pair(), storage = try disk()
        let locals = (0..<230).map { _ in GrowthStageRecord(vineyardId: sample.vineyardId, paddockId: sample.paddockId,
            pinId: UUID(), stageCode: sample.stageCode, observedAt: sample.observedAt, latitude: sample.latitude,
            longitude: sample.longitude, notes: sample.notes, createdBy: sample.createdBy,
            createdAt: sample.createdAt, updatedAt: sample.updatedAt) }
        let remotes = locals.map { server($0) }
        storage.save(locals, key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: storage)
        for local in locals { metadata.markDirty(local.id, at: Date()) }
        let repo = MirrorReplayRepository(rows: remotes)
        let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage)
        try await service.pushQueuedGrowthRecords(vineyardId: sample.vineyardId)
        #expect(service.pendingUpsertCount == 0)
        #expect(Set(service.records.map(\.id)) == Set(remotes.map(\.id)))
        #expect(repo.uploaded.isEmpty)
        let archive: [UUID: GrowthStageRecordSyncService.MirrorIdentityEvidence] = storage.load(key: "vinetrack_growth_mirror_identity_evidence_v1") ?? [:]
        #expect(archive.count == 230)
        for original in locals { #expect(archive[original.id]?.original == original) }
        let restart = GrowthStageRecordSyncService(repository: repo, persistence: storage)
        try await restart.pushQueuedGrowthRecords(vineyardId: sample.vineyardId)
        #expect(restart.pendingUpsertCount == 0)
        #expect(restart.records.count == 230)
        #expect(repo.uploaded.isEmpty)
    }

    @Test func changedAndAmbiguousMirrorsRemainQueuedAcrossRepeatedSweepsWithoutUploads() async throws {
        let (local, remote) = pair(), storage = try disk()
        var edited = local; edited.notes = "unsent edit"; edited.photoPaths = ["unsent/photo"]
        storage.save([edited], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: storage)
        metadata.markDirty(local.id, at: Date())
        let repo = MirrorReplayRepository(rows: [remote])
        let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage)
        for _ in 0..<2 { try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId) }
        #expect(service.records == [edited]); #expect(service.pendingUpsertCount == 1)
        #expect(repo.uploaded.isEmpty)
        repo.rows = [remote, server(local)]
        try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
        #expect(service.records == [edited]); #expect(repo.uploaded.isEmpty)
        await service.sync(vineyardId: local.vineyardId)
        #expect(service.syncStatus != .syncing)
        #expect(service.errorMessage?.contains("retained") == true)
        #expect(service.records.contains(edited))
    }

    @Test func localCanonicalEditAndDeletionAreNeverConsumedByAlias() async throws {
        for deletion in [false, true] {
            let (local, remote) = pair(), storage = try disk()
            var canonical = remote.toGrowthStageRecord(); canonical.notes = "new canonical note"
            storage.save([local, canonical], key: "vinetrack_growth_stage_records")
            let metadata = GrowthStageRecordSyncMetadata(persistence: storage)
            metadata.markDirty(local.id, at: Date())
            if deletion { metadata.markDeleted(canonical.id, at: Date()) }
            else { metadata.markDirty(canonical.id, at: Date()) }
            let repo = MirrorReplayRepository(rows: [remote])
            let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage,
                acknowledgedPinIds: { _ in [] })
            try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
            #expect(service.records.contains(local)); #expect(service.records.contains(canonical))
            #expect(metadata.pendingUpserts[local.id] != nil); #expect(repo.uploaded.isEmpty)
            #expect((metadata.pendingDeletes[canonical.id] != nil) == deletion)
        }
    }

    @Test func ownershipAndHistoricalMetadataCannotBeInferred() {
        let (local, _) = pair()
        #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(local, of: server(local, author: UUID())))
        var unknown = local; unknown.createdBy = nil
        #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(unknown, of: server(local)))
        var changed = local; changed.variety = "historical snapshot"; changed.recordedByName = "Original operator"
        #expect(!GrowthStageMirrorReplay.isUnmodifiedBackfill(changed, of: server(local)))
    }

    @Test func permanentSnapshotSuppressesIdenticalUploadsAfterRestartButNotEditedPayload() async throws {
        let (local, _) = pair(), storage = try disk()
        storage.save([local], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: storage)
        metadata.markDirty(local.id, at: Date()); try metadata.holdPermanent(local)
        let repo = MirrorReplayRepository(rows: [])
        let service = GrowthStageRecordSyncService(repository: repo, persistence: storage, acknowledgedPinIds: { _ in [local.pinId!] })
        try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
        #expect(repo.uploaded.isEmpty); #expect(service.pendingUpsertCount == 1)
        var pin = VinePin(id: local.pinId!, vineyardId: local.vineyardId, latitude: -33.1, longitude: 149.1,
            heading: nil, buttonName: "Growth", buttonColor: "green", side: nil, mode: .growth)
        pin.growthStageCode = "EL15"; pin.notes = "deliberate new edit"
        service.mirrorGrowthStagePin(pin)
        try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
        #expect(repo.uploaded.count == 1); #expect(repo.uploaded.first?.notes == "deliberate new edit")
    }

    @Test func photoOrDeleteDuringLookupRetainsOriginalAndIntent() async throws {
        for deleting in [false, true] {
            let (local, remote) = pair(), storage = try disk()
            storage.save([local], key: "vinetrack_growth_stage_records")
            let metadata = GrowthStageRecordSyncMetadata(persistence: storage); metadata.markDirty(local.id, at: Date())
            let repo = MirrorReplayRepository(rows: [remote])
            let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage)
            repo.onLookup = {
                if deleting { metadata.markDeleted(local.id, at: Date()) }
                else { try? service.attachPhoto(recordId: local.id, imageData: Data([1, 2, 3])) }
            }
            try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
            #expect(service.records.contains(where: { $0.id == local.id }))
            #expect(repo.uploaded.isEmpty)
            if deleting { #expect(metadata.pendingDeletes[local.id] != nil) }
            else { #expect(service.localPhotoData(recordId: local.id) == Data([1, 2, 3])) }
        }
    }

    @Test func diskFailureBeforeCanonicalSaveRetainsOriginalAndOutbox() async throws {
        let (local, remote) = pair(), storage = try disk()
        storage.save([local], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: storage); metadata.markDirty(local.id, at: Date())
        let repo = MirrorReplayRepository(rows: [remote])
        let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage)
        storage.durableSaveFailureForTesting = { key in
            key == "vinetrack_growth_stage_records" ? NSError(domain: "SyntheticDiskFull", code: 28) : nil
        }
        do {
            try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
            Issue.record("Failed canonical write must not acknowledge the original")
        } catch { #expect((error as NSError).code == 28) }
        #expect(service.records == [local]); #expect(metadata.pendingUpserts[local.id] != nil)
        #expect(repo.uploaded.isEmpty)
        storage.durableSaveFailureForTesting = nil
        let restart = GrowthStageRecordSyncService(repository: repo, persistence: storage)
        try await restart.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
        #expect(restart.records.map(\.id) == [remote.id]); #expect(restart.pendingUpsertCount == 0)
    }

    @Test func accountRoundTripDuringLookupCannotAcknowledgeOriginal() async throws {
        let (local, remote) = pair(), storage = try disk(), owner = UUID()
        storage.save([local], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: storage); metadata.markDirty(local.id, at: Date())
        let repo = MirrorReplayRepository(rows: [remote])
        let store = MigratedDataStore(persistence: storage)
        let authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        authority.bind(userId: owner); store.operationalWriteAuthority = authority
        store.currentUserIdProvider = { owner }; store.selectedVineyardId = local.vineyardId
        let auth = NewBackendAuthService()
        let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage)
        service.configure(store: store, auth: auth)
        repo.onLookup = { authority.bind(userId: nil); authority.bind(userId: owner) }
        do {
            try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
            Issue.record("Retired account incarnation acknowledged a mirror")
        } catch is VineyardWriteAuthority.Restricted {}
        #expect(service.records == [local]); #expect(metadata.pendingUpserts[local.id] != nil)
        #expect(repo.uploaded.isEmpty)
    }

    @Test func editDuringUploadCannotBeConsumedByOldAcknowledgement() async throws {
        let (local, _) = pair(), storage = try disk()
        storage.save([local], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: storage); metadata.markDirty(local.id, at: Date())
        let repo = MirrorReplayRepository(rows: [])
        let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage,
            acknowledgedPinIds: { _ in [local.pinId!] })
        repo.onUpload = {
            var pin = VinePin(id: local.pinId!, vineyardId: local.vineyardId, latitude: -33.1, longitude: 149.1,
                heading: nil, buttonName: "Growth", buttonColor: "green", side: nil, mode: .growth)
            pin.growthStageCode = local.stageCode; pin.notes = "newer edit during upload"
            service.mirrorGrowthStagePin(pin)
        }
        try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
        #expect(service.records.first?.notes == "newer edit during upload")
        #expect(metadata.pendingUpserts[local.id] != nil)
        #expect(repo.uploaded.count == 1)
    }

    @Test func growthConflictDoesNotBlockIndependentTripPush() async throws {
        let (local, remote) = pair(), storage = try disk()
        var edited = local; edited.notes = "unresolved growth note"
        storage.save([edited], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: storage); metadata.markDirty(local.id, at: Date())
        let growthRepo = MirrorReplayRepository(rows: [remote])
        let growth = GrowthStageRecordSyncService(repository: growthRepo, metadata: metadata, persistence: storage)
        try await growth.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
        let store = MigratedDataStore(persistence: storage), auth = NewBackendAuthService()
        let trip = Trip(vineyardId: local.vineyardId, paddockName: "Independent trip", isActive: false)
        store.selectedVineyardId = local.vineyardId; store.trips = [trip]
        let tripMetadata = TripSyncMetadata(persistence: storage), tripRepo = MirrorIndependentTripRepository()
        let trips = TripSyncService(repository: tripRepo, metadata: tripMetadata)
        trips.configure(store: store, auth: auth); tripMetadata.markDirty(trip.id, at: Date())
        try await trips.pushLocalTrips(vineyardId: local.vineyardId)
        #expect(tripRepo.uploaded.map(\.id) == [trip.id])
        #expect(!trips.isPendingUpsert(trip.id)); #expect(growth.pendingUpsertCount == 1)
        #expect(growth.records.contains(edited)); #expect(growthRepo.uploaded.isEmpty)
    }

    @Test func newPinWithPendingPhotoCanUploadObservationBeforePhoto() async throws {
        let (local, _) = pair(), storage = try disk()
        storage.save([local], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: storage); metadata.markDirty(local.id, at: Date())
        let repo = MirrorReplayRepository(rows: [])
        let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage,
            acknowledgedPinIds: { _ in [local.pinId!] })
        try service.attachPhoto(recordId: local.id, imageData: Data([1, 2, 3]))
        try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
        #expect(repo.uploaded.map(\.id) == [local.id])
        #expect(metadata.pendingUpserts[local.id] == nil)
        #expect(service.localPhotoData(recordId: local.id) == Data([1, 2, 3]))
    }

    @Test func accountRoundTripDuringPullCannotApplyRemoteOrSeedLocal() async throws {
        for empty in [false, true] {
            let (local, _) = pair(), storage = try disk(), owner = UUID()
            storage.save([local], key: "vinetrack_growth_stage_records")
            let metadata = GrowthStageRecordSyncMetadata(persistence: storage)
            var remoteLocal = local; remoteLocal.notes = "remote replacement"
            let repo = MirrorReplayRepository(rows: empty ? [] : [server(remoteLocal, id: local.id)])
            let store = MigratedDataStore(persistence: storage)
            let authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            authority.bind(userId: owner); store.operationalWriteAuthority = authority
            store.currentUserIdProvider = { owner }; store.selectedVineyardId = local.vineyardId
            let auth = NewBackendAuthService()
            let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage)
            service.configure(store: store, auth: auth)
            repo.onPull = { authority.bind(userId: nil); authority.bind(userId: owner) }
            do {
                try await service.pullRemote(vineyardId: local.vineyardId)
                Issue.record("Retired account pull applied or seeded observations")
            } catch is VineyardWriteAuthority.Restricted {}
            #expect(service.records == [local]); #expect(metadata.pendingUpserts.isEmpty)
            #expect(repo.uploaded.isEmpty)
        }
    }

    @Test func accountRoundTripDuringPhotoUploadOrReferenceRetainsPhotoIntent() async throws {
        for duringReference in [false, true] {
            var (local, _) = pair(); local.pinId = nil
            let storage = try disk(), owner = UUID()
            storage.save([local], key: "vinetrack_growth_stage_records")
            let repo = MirrorReplayRepository(rows: []), photos = MirrorPhotoStorage()
            let store = MigratedDataStore(persistence: storage)
            let authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            authority.bind(userId: owner); store.operationalWriteAuthority = authority
            store.currentUserIdProvider = { owner }; store.selectedVineyardId = local.vineyardId
            let auth = NewBackendAuthService()
            let service = GrowthStageRecordSyncService(repository: repo, photoStorage: photos, persistence: storage)
            service.configure(store: store, auth: auth)
            try service.attachPhoto(recordId: local.id, imageData: Data([1, 2, 3]))
            let change = { authority.bind(userId: nil); authority.bind(userId: owner) }
            if duringReference { repo.onPhotoReference = change } else { photos.onUpload = change }
            do {
                try await service.pushPendingPhotos(vineyardId: local.vineyardId)
                Issue.record("Retired account photo work was acknowledged")
            } catch is VineyardWriteAuthority.Restricted {}
            #expect(service.records == [local])
            #expect(service.localPhotoData(recordId: local.id) == Data([1, 2, 3]))
            #expect(repo.photoReferences == (duringReference ? 1 : 0))
            let restart = GrowthStageRecordSyncService(repository: repo, persistence: storage)
            #expect(restart.localPhotoData(recordId: local.id) == Data([1, 2, 3]))
        }
    }

    @Test func scopeChangeAbortsFollowingPhasesAndRetainsDeletionAcknowledgement() async throws {
        for duringDelete in [false, true] {
            let (local, _) = pair(), storage = try disk(), owner = UUID()
            storage.save(duringDelete ? [] as [GrowthStageRecord] : [local], key: "vinetrack_growth_stage_records")
            let metadata = GrowthStageRecordSyncMetadata(persistence: storage)
            if !duringDelete { metadata.markDirty(local.id, at: Date()) }
            let deletions = LinkedPinGrowthDeletionStore(persistence: storage)
            let target = PendingLinkedPinGrowthDeletion(id: UUID(), vineyardId: local.vineyardId, pinId: nil,
                growthRecordId: UUID(), queuedAt: Date(), growthSnapshot: nil, pinSnapshot: nil)
            try deletions.enqueue(target)
            metadata.markDeleted(target.growthRecordId!, at: Date())
            let repo = MirrorReplayRepository(rows: []), photos = MirrorPhotoStorage()
            let store = MigratedDataStore(persistence: storage)
            let authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            authority.bind(userId: owner); store.operationalWriteAuthority = authority
            store.currentUserIdProvider = { owner }; store.selectedVineyardId = local.vineyardId
            let auth = NewBackendAuthService()
            let service = GrowthStageRecordSyncService(repository: repo, photoStorage: photos, metadata: metadata,
                persistence: storage, deletionStore: deletions)
            service.configure(store: store, auth: auth)
            if !duringDelete { try service.attachPhoto(recordId: local.id, imageData: Data([1, 2, 3])) }
            let change = { authority.bind(userId: nil); authority.bind(userId: owner) }
            if duringDelete { repo.onDelete = change } else { repo.onLookup = change }
            await service.sync(vineyardId: local.vineyardId)
            #expect(service.syncStatus != .syncing)
            #expect(deletions.targets[target.id] != nil)
            #expect(metadata.pendingDeletes[target.growthRecordId!] != nil)
            #expect(repo.deletes == (duringDelete ? 1 : 0))
            #expect(photos.uploads == 0); #expect(repo.photoReferences == 0)
            #expect(metadata.lastSync(for: local.vineyardId) == nil)
            if !duringDelete {
                #expect(metadata.pendingUpserts[local.id] != nil)
                #expect(service.localPhotoData(recordId: local.id) == Data([1, 2, 3]))
            }
        }
    }

    @Test func editDuringLookupMustSurviveAndStayQueued() async throws {
        let (local, remote) = pair(), storage = try disk()
        storage.save([local], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: storage)
        metadata.markDirty(local.id, at: Date())
        let repo = MirrorReplayRepository(rows: [remote])
        let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: storage)
        repo.onLookup = {
            var pin = VinePin(id: local.pinId!, vineyardId: local.vineyardId, latitude: -33.1, longitude: 149.1,
                heading: nil, buttonName: "Growth", buttonColor: "green", side: nil, mode: .growth)
            pin.growthStageCode = local.stageCode
            pin.notes = "new edit during suspended lookup"
            service.mirrorGrowthStagePin(pin)
        }
        try await service.pushQueuedGrowthRecords(vineyardId: local.vineyardId)
        #expect(service.records.first(where: { $0.id == local.id })?.notes == "new edit during suspended lookup")
        #expect(metadata.pendingUpserts[local.id] != nil)
        #expect(repo.uploaded.isEmpty)
    }
}

@MainActor private final class MirrorReplayRepository: GrowthStageRecordSyncRepositoryProtocol {
    var rows: [BackendGrowthStageRecord]
    var onLookup: (() -> Void)?
    var onUpload: (() -> Void)?
    var onPull: (() -> Void)?
    var onPhotoReference: (() -> Void)?
    var onDelete: (() -> Void)?
    var deletes = 0
    var photoReferences = 0
    var uploaded: [BackendGrowthStageRecordUpsert] = []
    init(rows: [BackendGrowthStageRecord]) { self.rows = rows }
    func fetchActiveRecordsForPins(_ pinIds: Set<UUID>, vineyardId: UUID) async throws -> [BackendGrowthStageRecord] {
        onLookup?(); onLookup = nil
        return rows
    }
    func fetchGrowthStageRecords(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageRecord] {
        onPull?(); onPull = nil
        return rows
    }
    func upsertGrowthStageRecord(_ record: BackendGrowthStageRecordUpsert) async throws { uploaded.append(record) }
    func upsertGrowthStageRecords(_ records: [BackendGrowthStageRecordUpsert]) async throws {
        uploaded += records; onUpload?(); onUpload = nil
    }
    func updatePhotoPaths(recordId: UUID, vineyardId: UUID, photoPaths: [String]) async throws -> AttachmentReferenceConfirmation {
        photoReferences += 1; onPhotoReference?(); onPhotoReference = nil
        return .init(recordId: recordId, vineyardId: vineyardId, photoPath: nil, photoPaths: photoPaths)
    }
    func softDeleteGrowthStageRecord(id: UUID) async throws {
        deletes += 1
        guard let onDelete else { Issue.record("Reconciliation must never delete observations"); return }
        onDelete(); self.onDelete = nil
    }
}

@MainActor private final class MirrorPhotoStorage: PinPhotoStorageProtocol {
    var uploads = 0
    var onUpload: (() -> Void)?
    func uploadPhoto(vineyardId: UUID, pinId: UUID, revision: UUID, imageData: Data) async throws -> String {
        uploads += 1; onUpload?(); onUpload = nil
        return PinPhotoStorage.path(vineyardId: vineyardId, pinId: pinId, revision: revision)
    }
    func uploadGrowthPhoto(vineyardId: UUID, recordId: UUID, revision: UUID, imageData: Data) async throws -> String {
        uploads += 1; onUpload?(); onUpload = nil
        return PinPhotoStorage.growthPath(vineyardId: vineyardId, recordId: recordId, revision: revision)
    }
    func downloadPhoto(path: String, vineyardId: UUID, pinId: UUID) async throws -> Data { Data() }
    func downloadGrowthPhoto(path: String, vineyardId: UUID, recordId: UUID) async throws -> Data { Data() }
}

@MainActor private final class MirrorIndependentTripRepository: TripSyncRepositoryProtocol {
    var uploaded: [BackendTripUpsert] = []
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] { [] }
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] { [] }
    func fetchAllAccessibleTrips() async throws -> [BackendTrip] { [] }
    func upsertTrip(_ trip: BackendTripUpsert) async throws { uploaded.append(trip) }
    func upsertTrips(_ trips: [BackendTripUpsert]) async throws { uploaded += trips }
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {}
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {}
    func softDeleteTrip(id: UUID) async throws { Issue.record("Independent trip must not be deleted") }
}
