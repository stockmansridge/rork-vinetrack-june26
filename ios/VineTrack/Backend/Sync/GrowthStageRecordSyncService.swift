import Foundation
import Observation

/// Local-first sync service for `GrowthStageRecord` entities.
///
/// Mirrors growth-stage pins into the dedicated `growth_stage_records`
/// table so the Lovable web portal can read observations from one
/// canonical source. The legacy pin-based growth observations remain
/// unchanged and continue to be written by the existing iOS flow; this
/// service simply duplicates them into the new table via `pinId`.
@Observable
@MainActor
final class GrowthStageRecordSyncService {

    enum Status: Equatable, Sendable {
        case idle
        case syncing
        case success
        case failure(String)
    }

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    /// In-memory cache of records for the selected vineyard. Persisted to
    /// disk via `PersistenceStore`.
    private(set) var records: [GrowthStageRecord] = []

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private var writeAuthority: VineyardWriteAuthority { store?.operationalWriteAuthority ?? .shared }
    private let repository: any GrowthStageRecordSyncRepositoryProtocol
    private let pinRepository: any PinSyncRepositoryProtocol
    private let photoStorage: any PinPhotoStorageProtocol
    private let metadata: GrowthStageRecordSyncMetadata
    private let persistence: PersistenceStore
    private let deletionStore: LinkedPinGrowthDeletionStore
    private let persistenceKey = "vinetrack_growth_stage_records"
    private let pendingPhotosKey = "vinetrack_pending_growth_photos_v1"
    private var pendingPhotos: [UUID: PendingGrowthPhoto] = [:]
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?
    private var isSyncInFlight: Bool = false
    private var isPushInFlight = false
    private let mirrorEvidenceKey = "vinetrack_growth_mirror_identity_evidence_v1"
    nonisolated struct MirrorIdentityEvidence: Codable, Sendable {
        let original: GrowthStageRecord
        let canonicalId: UUID
    }
    private let acknowledgedPinIds: ((UUID) async throws -> Set<UUID>)?

    /// Debounced eager-push. Multiple quick edits coalesce into a single sync.
    private func scheduleEagerPush() {
        eagerPushTask?.cancel()
        eagerPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.syncForSelectedVineyard()
        }
    }

    init(
        repository: (any GrowthStageRecordSyncRepositoryProtocol)? = nil,
        pinRepository: (any PinSyncRepositoryProtocol)? = nil,
        photoStorage: (any PinPhotoStorageProtocol)? = nil,
        metadata: GrowthStageRecordSyncMetadata? = nil,
        persistence: PersistenceStore = .shared,
        deletionStore: LinkedPinGrowthDeletionStore? = nil,
        acknowledgedPinIds: ((UUID) async throws -> Set<UUID>)? = nil
    ) {
        self.repository = repository ?? SupabaseGrowthStageRecordSyncRepository()
        self.pinRepository = pinRepository ?? SupabasePinSyncRepository()
        self.photoStorage = photoStorage ?? PinPhotoStorageService()
        self.metadata = metadata ?? GrowthStageRecordSyncMetadata(persistence: persistence)
        self.persistence = persistence
        self.deletionStore = deletionStore ?? .shared
        self.acknowledgedPinIds = acknowledgedPinIds
        self.records = persistence.load(key: persistenceKey) ?? []
        self.pendingPhotos = persistence.load(key: pendingPhotosKey) ?? [:]
    }

    // MARK: - Configuration

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        records.removeAll { deletionStore.growthRecordIds.contains($0.id) }
        for pinId in deletionStore.pinIds { store.applyRemotePinDelete(pinId) }
        persist()
        guard !isConfigured else { return }
        isConfigured = true

        // Mirror new growth-stage pins into growth_stage_records.
        store.onGrowthStagePinAdded = { [weak self] pin in
            self?.mirrorGrowthStagePin(pin)
        }
        // When a growth-stage pin is soft-deleted locally, also soft-delete
        // its mirrored record so the dedicated table stays in sync.
        store.onGrowthStagePinDeleted = { [weak self] pin in
            self?.softDeleteByPin(pin) ?? false
        }
        // Backfill: mirror any growth-stage pins that already exist locally
        // (e.g. pins created before this sync service was wired up, or
        // imported from a previous app version) so they appear in the new
        // Growth Stage Records list without requiring a fresh observation.
        backfillFromExistingPins()
    }

    // MARK: - Backfill

    /// Mirror any growth-stage pins in `store.pins` that don't yet have a
    /// corresponding `GrowthStageRecord`. Idempotent and cheap to call on
    /// every configure.
    func backfillFromExistingPins() {
        guard let store else { return }
        let mirroredPinIds = Set(records.compactMap { $0.pinId })
        let candidates = store.pins.filter { pin in
            pin.mode == .growth
                && (pin.growthStageCode?.isEmpty == false)
                && !mirroredPinIds.contains(pin.id)
        }
        guard !candidates.isEmpty else { return }
        #if DEBUG
        print("[GrowthStageRecord] backfillFromExistingPins mirroring \(candidates.count) legacy pins")
        #endif
        for pin in candidates {
            mirrorPinWithoutSync(pin, snapshotVariety: false)
        }
        reconcileBudburstFromExistingObservations()
        persist()
        // Push the backfilled rows once at the end.
        scheduleEagerPush()
    }

    // MARK: - Mirroring

    /// Mirror a freshly added growth-stage pin into the dedicated table.
    /// Idempotent — if a record already exists for this `pinId`, the
    /// existing row is updated in place.
    func mirrorGrowthStagePin(_ pin: VinePin) {
        #if DEBUG
        print("[GrowthStageRecord] mirrorGrowthStagePin pinId=\(pin.id) mode=\(pin.mode) code=\(pin.growthStageCode ?? "nil") vineyardId=\(pin.vineyardId) paddockId=\(pin.paddockId?.uuidString ?? "nil")")
        #endif
        guard mirrorPinWithoutSync(pin) else { return }
        persist()
        // Auto-suggest budburst date when a Budburst (EL4) growth stage
        // is recorded against a paddock with no Budburst date yet.
        establishBudburstIfNeeded(from: pin)
        // Best-effort: push (debounced) so the record is visible to other
        // devices / Lovable without waiting for the next sync cycle.
        scheduleEagerPush()
    }

    /// Core mirror logic without persistence or sync side-effects. Returns
    /// `true` if the pin was a valid growth-stage pin and was mirrored.
    @discardableResult
    private func mirrorPinWithoutSync(_ pin: VinePin, snapshotVariety: Bool = true) -> Bool {
        guard writeAuthority.canWrite(vineyardId: pin.vineyardId.uuidString) else { return false }
        guard pin.mode == .growth, let code = pin.growthStageCode, !code.isEmpty else {
            #if DEBUG
            print("[GrowthStageRecord] mirrorPinWithoutSync SKIPPED — not a growth-stage pin")
            #endif
            return false
        }
        let stageLabel = GrowthStage.allStages.first { $0.code == code }?.description
        // A legacy pin has no stored variety snapshot: today's allocation cannot
        // establish what was planted when that historical pin was captured.
        let variety = snapshotVariety ? variety(for: pin.paddockId, vineyardId: pin.vineyardId) : nil
        if let idx = records.firstIndex(where: { $0.pinId == pin.id }) {
            var updated = records[idx]
            updated.stageCode = code
            updated.stageLabel = stageLabel
            // Never infer a historical snapshot from today's block allocations.
            updated.observedAt = pin.timestamp
            updated.latitude = pin.latitude
            updated.longitude = pin.longitude
            updated.rowNumber = pin.rowNumber
            updated.side = pin.side?.rawValue
            updated.notes = pin.notes
            updated.photoPaths = pin.photoPath.map { [$0] } ?? updated.photoPaths
            updated.recordedByName = pin.createdBy ?? updated.recordedByName
            updated.updatedBy = pin.createdByUserId ?? updated.updatedBy
            updated.updatedAt = Date()
            records[idx] = updated
            metadata.markDirty(updated.id, at: Date())
        } else {
            guard var mirrored = GrowthStageRecord.mirroring(
                pin,
                stageLabel: stageLabel,
                variety: variety?.displayName,
                varietyId: variety?.varietyId
            ) else { return false }
            // A historical backfill cannot attribute somebody else's old Pin
            // to the person currently signed in. Preserve unknown authorship.
            mirrored.recordedByName = pin.createdBy ?? (snapshotVariety ? auth?.userName : nil)
            // Pin creation stamps the authenticated UUID; do not reattribute imported pins.
            records.append(mirrored)
            metadata.markDirty(mirrored.id, at: Date())
            #if DEBUG
            print("[GrowthStageRecord] mirrored new record id=\(mirrored.id) for pin=\(pin.id)")
            #endif
        }
        return true
    }

    /// Reconciles imported/offline EL4 observations after relaunch. Existing
    /// manual dates always win; choosing the earliest EL4 makes repeated runs
    /// deterministic and idempotent.
    func reconcileBudburstFromExistingObservations() {
        guard let store else { return }
        let observations = store.pins
            .filter { $0.mode == .growth && $0.growthStageCode?.uppercased() == GrowthStage.budburstCode && $0.paddockId != nil }
            .sorted { $0.timestamp < $1.timestamp }
        for observation in observations {
            establishBudburstIfNeeded(from: observation)
        }
    }

    private func establishBudburstIfNeeded(from pin: VinePin) {
        guard pin.growthStageCode?.uppercased() == GrowthStage.budburstCode,
              let paddockId = pin.paddockId,
              let store,
              let index = store.paddocks.firstIndex(where: { $0.id == paddockId }),
              store.paddocks[index].budburstDate == nil else { return }
        var paddock = store.paddocks[index]
        paddock.budburstDate = pin.timestamp
        store.updatePaddock(paddock)
        #if DEBUG
        print("[GrowthStageRecord] budburst source=growth_observation observation=\(pin.id) block=\(paddockId) date=\(pin.timestamp)")
        #endif
    }

    private func variety(for paddockId: UUID?, vineyardId: UUID) -> PaddockVarietyResolver.Resolved? {
        guard let paddockId, let store,
              let paddock = store.paddocks.first(where: { $0.id == paddockId && $0.vineyardId == vineyardId }) else { return nil }
        return Self.primaryVariety(in: paddock, varieties: store.grapeVarieties)
    }

    /// Match Android's `maxByOrNull(displayPercent)` (first allocation wins a tie).
    nonisolated static func primaryVariety(in paddock: Paddock, varieties: [GrapeVariety]) -> PaddockVarietyResolver.Resolved? {
        guard let primary = paddock.varietyAllocations.reduce(nil as PaddockVarietyAllocation?, { best, candidate in
            guard let best else { return candidate }
            return candidate.percent > best.percent ? candidate : best
        }) else { return nil }
        let resolved = PaddockVarietyResolver.resolve(allocation: primary, varieties: varieties)
        return resolved.displayName == nil ? nil : resolved
    }

    func localPhotoData(recordId: UUID) -> Data? {
        pendingPhotos[recordId]?.imageData
    }

    func attachmentRevision(recordId: UUID) -> UUID? {
        pendingPhotos[recordId]?.revision
    }

    /// Retain a captured growth photo before any network work. A newer capture
    /// replaces the pending revision for this observation without affecting metadata.
    func attachPhoto(recordId: UUID, imageData: Data) throws {
        guard let record = records.first(where: { $0.id == recordId }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The growth observation is no longer available."])
        }
        try writeAuthority.requireWrite(vineyardId: record.vineyardId.uuidString)
        let payload = PinPhotoStorage.compress(imageData) ?? imageData
        guard !payload.isEmpty else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The captured photo was empty."])
        }
        let revision = UUID()
        let pending = PendingGrowthPhoto(
            recordId: record.id,
            vineyardId: record.vineyardId,
            pinId: record.pinId,
            revision: revision,
            imageData: payload,
            capturedAt: Date(),
            previousRemotePath: record.photoPaths.first
        )
        var next = pendingPhotos
        next[record.id] = pending
        try persistence.saveOrThrow(next, key: pendingPhotosKey)
        let cacheKey: SharedImageCacheKey = record.pinId.map {
            .pinPhoto(vineyardId: record.vineyardId, pinId: $0)
        } ?? .growthRecordPhoto(vineyardId: record.vineyardId, recordId: record.id)
        try SharedImageCache.shared.saveImageDataOrThrow(
            payload,
            for: cacheKey,
            remotePath: nil,
            remoteUpdatedAt: nil,
            attachmentRevision: revision
        )
        pendingPhotos = next
        scheduleEagerPush()
    }

    /// Source-aware local delete. SQL 230 makes the existing growth RPC delete
    /// a linked pin and observation atomically when this queue replays.
    func deleteRecord(id: UUID) throws {
        guard let record = records.first(where: { $0.id == id }) else { return }
        try writeAuthority.requireWrite(vineyardId: record.vineyardId.uuidString)
        if record.pinId == nil,
           metadata.pendingUpserts[id] != nil,
           !metadata.isUnknownOutcome(id) {
            pendingPhotos.removeValue(forKey: id)
            try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
            metadata.clearDirty([id])
            records.removeAll { $0.id == id }
            persist()
            return
        }
        let pinSnapshot = record.pinId.flatMap { pinId in store?.pins.first(where: { $0.id == pinId }) }
        let target = PendingLinkedPinGrowthDeletion(
            id: record.id,
            vineyardId: record.vineyardId,
            pinId: record.pinId,
            growthRecordId: record.id,
            queuedAt: Date(),
            growthSnapshot: record,
            pinSnapshot: pinSnapshot
        )
        try deletionStore.enqueue(target)
        pendingPhotos.removeValue(forKey: id)
        try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
        records.removeAll { $0.id == id }
        metadata.markDeleted(id, at: Date())
        persist()
        if let pinId = record.pinId { store?.applyRemotePinDelete(pinId) }
        scheduleEagerPush()
    }

    private func softDeleteByPin(_ pin: VinePin) -> Bool {
        guard let record = records.first(where: { $0.pinId == pin.id }) else { return true }
        guard writeAuthority.admit(vineyardId: record.vineyardId.uuidString) else { return false }
        let target = PendingLinkedPinGrowthDeletion(
            id: record.id,
            vineyardId: record.vineyardId,
            pinId: pin.id,
            growthRecordId: record.id,
            queuedAt: Date(),
            growthSnapshot: record,
            pinSnapshot: pin
        )
        do {
            try deletionStore.enqueue(target)
            records.removeAll { $0.id == record.id }
            pendingPhotos.removeValue(forKey: record.id)
            try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
            metadata.markDeleted(record.id, at: Date())
            persist()
            scheduleEagerPush()
            return true
        } catch {
            errorMessage = "Couldn't retain the deletion on this device."
            return false
        }
    }

    /// Invalidates every suspended phase, including same-account/selection round trips.
    private func currentScopeCheck() -> () -> Bool {
        let authority = writeAuthority
        let generation = authority.accountGeneration
        let storeCheck = store?.remoteApplicationCurrentCheck()
        return { [weak self] in
            guard let self else { return false }
            return self.writeAuthority === authority && authority.accountGeneration == generation && (storeCheck?() ?? true)
        }
    }

    private func requireCurrentScope(_ isCurrent: () -> Bool) throws {
        guard isCurrent(), !Task.isCancelled else {
            throw VineyardWriteAuthority.Restricted(reason: "GROWTH_SYNC_SCOPE_CHANGED")
        }
    }

    // MARK: - Public sync entry points

    func syncForSelectedVineyard() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId else { return }
        await sync(vineyardId: vineyardId)
    }

    func sync(vineyardId: UUID) async {
        guard !isSyncInFlight else { return }
        guard SupabaseClientProvider.shared.isConfigured else {
            errorMessage = "Supabase not configured"
            syncStatus = .failure("Supabase not configured")
            return
        }
        isSyncInFlight = true
        defer { isSyncInFlight = false }
        syncStatus = .syncing
        errorMessage = nil
        let isCurrent = currentScopeCheck()
        do {
            try await pushLocal(vineyardId: vineyardId)
            try requireCurrentScope(isCurrent)
            try await pullRemote(vineyardId: vineyardId)
            try requireCurrentScope(isCurrent)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            let remaining = records.filter { $0.vineyardId == vineyardId && metadata.pendingUpserts[$0.id] != nil }.count
            if remaining > 0 {
                let message = "Sync finished · \(remaining) Growth Stage observations retained, awaiting pin confirmation or conflict review. Trips sync independently."
                errorMessage = message
                syncStatus = .failure(message)
            } else {
                syncStatus = .success
            }
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: - Push

    /// A server read is affirmative acknowledgement, including after restart or a duplicate Pin create.
    private func confirmedPins(_ ids: Set<UUID>, vineyardId: UUID) async -> Set<UUID> {
        do {
            if let acknowledgedPinIds { return try await acknowledgedPinIds(vineyardId) }
            return try await pinRepository.persistedPinIds(ids, vineyardId: vineyardId)
        } catch { return [] }
    }

    private func reconcileQueuedLegacyMirrors(vineyardId: UUID) async throws -> Set<UUID> {
        let candidates = records.filter {
            $0.vineyardId == vineyardId && $0.pinId != nil && metadata.pendingUpserts[$0.id] != nil &&
            metadata.pendingDeletes[$0.id] == nil && !deletionStore.growthRecordIds.contains($0.id)
        }
        guard !candidates.isEmpty else { return [] }
        let authority = writeAuthority
        let generation = authority.accountGeneration
        let actor = store?.currentUserIdProvider?()
        let selection = store?.selectedVineyardId
        let isCurrent = store?.remoteApplicationCurrentCheck()
        let queued = metadata.pendingUpserts
        let remote = try await repository.fetchActiveRecordsForPins(Set(candidates.compactMap(\.pinId)), vineyardId: vineyardId)
        guard authority.accountGeneration == generation, store?.currentUserIdProvider?() == actor,
              store?.selectedVineyardId == selection, isCurrent?() ?? true,
              authority.canWrite(vineyardId: vineyardId.uuidString) else {
            throw VineyardWriteAuthority.Restricted(reason: "GROWTH_RECONCILIATION_SCOPE_CHANGED")
        }
        let remoteByPin = Dictionary(grouping: remote.filter { $0.vineyardId == vineyardId && $0.deletedAt == nil && $0.pinId != nil }, by: { $0.pinId! })
        var next = records
        var acknowledged: [UUID] = []
        var evidence: [UUID: MirrorIdentityEvidence]
        switch persistence.loadOutcome(key: mirrorEvidenceKey) as PersistenceStore.LoadOutcome<[UUID: MirrorIdentityEvidence]> {
        case .missing: evidence = [:]
        case .decoded(let retained): evidence = retained
        case .failed(let error): throw error
        }
        var held: Set<UUID> = []
        for candidate in candidates {
            // The lookup may suspend across edits, attachments, deletes or account changes.
            guard records.first(where: { $0.id == candidate.id }) == candidate,
                  metadata.pendingUpserts[candidate.id] == queued[candidate.id],
                  metadata.pendingDeletes[candidate.id] == nil,
                  !deletionStore.growthRecordIds.contains(candidate.id) else {
                held.insert(candidate.id); continue
            }
            guard let pin = candidate.pinId, let matches = remoteByPin[pin] else { continue }
            guard matches.count == 1, let canonical = matches.first else { held.insert(candidate.id); continue }
            if canonical.id == candidate.id { continue }
            guard pendingPhotos[candidate.id] == nil, !deletionStore.pinIds.contains(pin),
                  GrowthStageMirrorReplay.isUnmodifiedBackfill(candidate, of: canonical) else {
                held.insert(candidate.id); continue
            }
            if metadata.pendingDeletes[canonical.id] != nil || deletionStore.growthRecordIds.contains(canonical.id) ||
                metadata.pendingUpserts[canonical.id] != nil || pendingPhotos[canonical.id] != nil ||
                metadata.isUnknownOutcome(canonical.id) { held.insert(candidate.id); continue }
            let canonicalRecord = canonical.toGrowthStageRecord()
            if let cachedIndex = next.firstIndex(where: { $0.id == canonical.id }),
               next[cachedIndex] != canonicalRecord {
                // Canonical has no pending writes, photos, deletes or unknown
                // outcomes (checked above). A newer server revision can safely
                // replace an older clean cache in this same durable save.
                // Never overwrite a newer/equal-time divergent local snapshot.
                guard canonicalRecord.updatedAt > next[cachedIndex].updatedAt else {
                    held.insert(candidate.id); continue
                }
                next[cachedIndex] = canonicalRecord
            }
            // Keep the complete historical mirror, including original identity, owner,
            // notes, photos and timestamps. Only the visible duplicate is aliased.
            if let retained = evidence[candidate.id], retained.original != candidate || retained.canonicalId != canonical.id {
                held.insert(candidate.id); continue
            }
            evidence[candidate.id] = .init(original: candidate, canonicalId: canonical.id)
            next.removeAll { $0.id == candidate.id }
            if !next.contains(where: { $0.id == canonical.id }) { next.append(canonical.toGrowthStageRecord()) }
            acknowledged.append(candidate.id)
        }
        for id in held {
            SyncIssueCenter.shared.recordFailure(id: id, entity: "Growth Stages",
                detail: .init(kind: .permanent, reasonCode: "GROWTH_PIN_IDENTITY_REVIEW",
                    friendlyMessage: "Original observation retained; pin identity conflict needs review.",
                    technicalDetail: "Positive pin lookup did not prove an unchanged, uniquely owned mirror. No overwrite/delete performed."),
                queuedAt: metadata.pendingUpserts[id], payloadKeys: [], vineyardId: vineyardId)
        }
        if !acknowledged.isEmpty {
            try persistence.saveOrThrow(evidence, key: mirrorEvidenceKey)
            try persistence.saveOrThrow(next, key: persistenceKey)
            records = next
            metadata.clearDirty(acknowledged)
            metadata.clearUnknownOutcome(acknowledged)
            SyncIssueCenter.shared.clearIssues(acknowledged)
        }
        return held
    }

    func pushQueuedGrowthRecords(vineyardId: UUID) async throws {
        guard !isPushInFlight, writeAuthority.canWrite(vineyardId: vineyardId.uuidString) else { return }
        isPushInFlight = true
        defer { isPushInFlight = false }
        let generation = writeAuthority.accountGeneration
        let actor = store?.currentUserIdProvider?()
        let isCurrent = currentScopeCheck()
        let heldConflicts = try await reconcileQueuedLegacyMirrors(vineyardId: vineyardId)
        try requireCurrentScope(isCurrent)
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            var payloads: [BackendGrowthStageRecordUpsert] = []
            var pushedIds: [UUID] = []
            var orphans: [UUID] = []
            let linkedIds = Set(records.filter { dirty[$0.id] != nil && $0.vineyardId == vineyardId }.compactMap { $0.pinId })
            let confirmed: Set<UUID> = linkedIds.isEmpty ? [] : await confirmedPins(linkedIds, vineyardId: vineyardId)
            try requireCurrentScope(isCurrent)
            guard writeAuthority.accountGeneration == generation, store?.currentUserIdProvider?() == actor else {
                throw VineyardWriteAuthority.Restricted(reason: "GROWTH_PUSH_SCOPE_CHANGED")
            }
            let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for (recordId, ts) in dirty {
                // Reclaim queue entries with no local record — they can never
                // upload and used to sit in the queue forever.
                guard let record = byId[recordId] else { orphans.append(recordId); continue }
                guard record.vineyardId == vineyardId,
                      !heldConflicts.contains(recordId),
                      metadata.pendingUpserts[recordId] == ts,
                      metadata.permanentSnapshot(recordId) != record,
                      metadata.pendingDeletes[recordId] == nil,
                      !deletionStore.growthRecordIds.contains(recordId),
                      record.pinId.map({ confirmed.contains($0) && !deletionStore.pinIds.contains($0) }) ?? true else { continue }
                payloads.append(BackendGrowthStageRecord.upsert(
                    from: record,
                    createdBy: createdBy,
                    clientUpdatedAt: ts
                ))
                pushedIds.append(recordId)
            }
            // The acknowledgement read can suspend across expiry. Do not claim
            // an unknown-outcome upload, clear orphans or rewrite metadata then.
            guard writeAuthority.canWrite(vineyardId: vineyardId.uuidString) else { return }
            metadata.clearDirty(orphans)
            SyncIssueCenter.shared.clearIssues(orphans)
            let result = await SyncQueuePush.run(
                entity: "Growth Stages",
                ids: pushedIds,
                payloads: payloads,
                queuedAt: dirty,
                vineyardId: vineyardId,
                authority: writeAuthority
            ) { payloads in
                try requireCurrentScope(isCurrent)
                guard writeAuthority.accountGeneration == generation, store?.currentUserIdProvider?() == actor else {
                    throw VineyardWriteAuthority.Restricted(reason: "GROWTH_SEND_SCOPE_CHANGED")
                }
                try writeAuthority.requireWrite(vineyardId: vineyardId.uuidString)
                let originalUnknown = metadata.unknownOutcomeUpserts
                let sendingIds = payloads.map(\.id)
                metadata.markUnknownOutcome(sendingIds)
                do {
                    try await repository.upsertGrowthStageRecords(payloads)
                } catch {
                    if error is VineyardWriteAuthority.Restricted {
                        metadata.restoreUnknownOutcomeAfterHold(sendingIds, original: originalUnknown)
                    }
                    throw error
                }
            }
            try requireCurrentScope(isCurrent)
            guard writeAuthority.accountGeneration == generation, store?.currentUserIdProvider?() == actor else {
                throw VineyardWriteAuthority.Restricted(reason: "GROWTH_ACK_SCOPE_CHANGED")
            }
            // An old upload acknowledgement cannot consume an edit made in flight.
            let unchanged = result.uploaded.filter { id in
                metadata.pendingUpserts[id] == dirty[id] && records.first(where: { $0.id == id }) == byId[id]
            }
            for id in result.permanent {
                if let snapshot = byId[id] { try metadata.holdPermanent(snapshot) }
            }
            metadata.clearDirty(unchanged)
            metadata.clearUnknownOutcome(unchanged)
            SyncIssueCenter.shared.notePending(entity: "Growth Stages", count: metadata.pendingUpserts.count)
            if let error = result.firstRetryableError { throw error }
        }

    }

    private func pushLocal(vineyardId: UUID) async throws {
        let isCurrent = currentScopeCheck()
        var independentUpsertError: Error?
        do { try await pushQueuedGrowthRecords(vineyardId: vineyardId) }
        catch { try requireCurrentScope(isCurrent); independentUpsertError = error }
        try requireCurrentScope(isCurrent)
        // Attachment failures must not prevent independent linked deletions.
        var independentPhotoError: Error?
        do { try await pushPendingPhotos(vineyardId: vineyardId) }
        catch { try requireCurrentScope(isCurrent); independentPhotoError = error }
        try requireCurrentScope(isCurrent)

        let targets = deletionStore.targets.values.filter { $0.vineyardId == vineyardId }
        var firstDeletionError: Error?
        for target in targets {
            guard writeAuthority.canWrite(vineyardId: target.vineyardId.uuidString) else { continue }
            do {
                try await deletePersistedTarget(target)
                try requireCurrentScope(isCurrent)
                if target.pinId != nil {
                    try deletionStore.markConfirmed(target.id)
                } else {
                    try deletionStore.remove(target.id)
                }
                if let growthId = target.growthRecordId {
                    metadata.clearDeleted([growthId])
                    metadata.clearUnknownOutcome([growthId])
                }
            } catch {
                try requireCurrentScope(isCurrent)
                if error is VineyardWriteAuthority.Restricted { continue }
                if Self.isPermissionError(error) {
                    if let growth = target.growthSnapshot, !records.contains(where: { $0.id == growth.id }) {
                        records.append(growth)
                    }
                    if let pin = target.pinSnapshot { store?.applyRemotePinUpsert(pin) }
                    try deletionStore.remove(target.id)
                    if let growthId = target.growthRecordId {
                        metadata.clearDeleted([growthId])
                        metadata.clearUnknownOutcome([growthId])
                    }
                    persist()
                    errorMessage = "You don't have permission to delete this observation."
                } else if firstDeletionError == nil {
                    firstDeletionError = error
                }
            }
        }
        if let firstDeletionError { throw firstDeletionError }
        if let independentPhotoError { throw independentPhotoError }
        if let independentUpsertError { throw independentUpsertError }
    }

    func deletePersistedTarget(_ target: PendingLinkedPinGrowthDeletion) async throws {
        let isCurrent = currentScopeCheck()
        try writeAuthority.requireWrite(vineyardId: target.vineyardId.uuidString)
        if let pinId = target.pinId, let growthId = target.growthRecordId {
            do {
                try await pinRepository.softDeletePin(id: pinId)
                try requireCurrentScope(isCurrent)
                return
            } catch where Self.isMissingRowError(error) {
                try requireCurrentScope(isCurrent)
                try writeAuthority.requireWrite(vineyardId: target.vineyardId.uuidString)
                try await repository.softDeleteGrowthStageRecord(id: growthId)
                try requireCurrentScope(isCurrent)
                return
            }
        }
        if let growthId = target.growthRecordId {
            do { try await repository.softDeleteGrowthStageRecord(id: growthId) }
            catch where Self.isMissingRowError(error) { try requireCurrentScope(isCurrent); return }
            try requireCurrentScope(isCurrent)
            return
        }
        if let pinId = target.pinId {
            do { try await pinRepository.softDeletePin(id: pinId) }
            catch where Self.isMissingRowError(error) { try requireCurrentScope(isCurrent); return }
            try requireCurrentScope(isCurrent)
        }
    }

    nonisolated private static func isMissingRowError(_ error: Error) -> Bool {
        let messages = [String(describing: error), (error as? LocalizedError)?.errorDescription ?? ""]
            .map { $0.lowercased() }
        if error is URLError || messages.contains(where: {
            $0.contains("permission") || $0.contains("forbidden") || $0.contains("unauthorized") ||
                $0.contains("not authorized") || $0.contains("access denied")
        }) { return false }
        return messages.contains { message in
            // Missing functions/storage objects are not evidence that this record is absent.
            return message.contains("record not found") || message.contains("pin not found") ||
                message.contains("pgrst116") || message.contains("no rows") || message.contains("0 rows")
        }
    }

    nonisolated private static func isPermissionError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("permission") || message.contains("forbidden") || message.contains("403")
    }

    func pushPendingPhotos(vineyardId: UUID) async throws {
        let isCurrent = currentScopeCheck()
        let candidates = pendingPhotos.values
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.capturedAt < $1.capturedAt }
        var firstFailure: Error?
        for snapshot in candidates {
            try requireCurrentScope(isCurrent)
            guard writeAuthority.canWrite(vineyardId: snapshot.vineyardId.uuidString),
                  metadata.pendingDeletes[snapshot.recordId] == nil,
                  metadata.pendingUpserts[snapshot.recordId] == nil,
                  records.contains(where: { $0.id == snapshot.recordId }),
                  pendingPhotos[snapshot.recordId]?.revision == snapshot.revision else { continue }
            do {
                var work = snapshot
                if work.uploadedPath == nil {
                    let path: String
                    if let pinId = work.pinId {
                        path = try await photoStorage.uploadPhoto(
                            vineyardId: work.vineyardId,
                            pinId: pinId,
                            revision: work.revision,
                            imageData: work.imageData
                        )
                    } else {
                        path = try await photoStorage.uploadGrowthPhoto(
                            vineyardId: work.vineyardId,
                            recordId: work.recordId,
                            revision: work.revision,
                            imageData: work.imageData
                        )
                    }
                    try requireCurrentScope(isCurrent)
                    guard metadata.pendingDeletes[work.recordId] == nil,
                          pendingPhotos[work.recordId]?.revision == work.revision else { continue }
                    work.uploadedPath = path
                    pendingPhotos[work.recordId] = work
                    try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
                }

                guard writeAuthority.canWrite(vineyardId: work.vineyardId.uuidString),
                      let path = work.uploadedPath,
                      metadata.pendingDeletes[work.recordId] == nil,
                      pendingPhotos[work.recordId]?.revision == work.revision,
                      let current = records.first(where: { $0.id == work.recordId }) else { continue }
                let photoPaths = Self.replacingOwnedPhoto(
                    in: current.photoPaths,
                    previousPath: work.previousRemotePath,
                    with: path
                )

                if let pinId = work.pinId {
                    _ = try await pinRepository.updatePhotoPath(
                        pinId: pinId,
                        vineyardId: work.vineyardId,
                        path: path
                    )
                    try requireCurrentScope(isCurrent)
                    guard metadata.pendingDeletes[work.recordId] == nil,
                          pendingPhotos[work.recordId]?.revision == work.revision else { continue }
                }
                guard writeAuthority.canWrite(vineyardId: work.vineyardId.uuidString) else { continue }
                _ = try await repository.updatePhotoPaths(
                    recordId: work.recordId,
                    vineyardId: work.vineyardId,
                    photoPaths: photoPaths
                )
                try requireCurrentScope(isCurrent)
                guard metadata.pendingDeletes[work.recordId] == nil,
                      pendingPhotos[work.recordId]?.revision == work.revision,
                      let currentIndex = records.firstIndex(where: { $0.id == work.recordId }) else { continue }

                records[currentIndex].photoPaths = photoPaths
                records[currentIndex].updatedAt = Date()
                if let pinId = work.pinId,
                   var pin = store?.pins.first(where: { $0.id == pinId }) {
                    pin.photoData = work.imageData
                    pin.photoPath = path
                    store?.applyRemotePinUpsert(pin)
                }
                let cacheKey: SharedImageCacheKey = work.pinId.map {
                    .pinPhoto(vineyardId: work.vineyardId, pinId: $0)
                } ?? .growthRecordPhoto(vineyardId: work.vineyardId, recordId: work.recordId)
                try SharedImageCache.shared.saveImageDataOrThrow(
                    work.imageData,
                    for: cacheKey,
                    remotePath: path,
                    remoteUpdatedAt: nil,
                    attachmentRevision: work.revision
                )
                guard pendingPhotos[work.recordId]?.revision == work.revision else { continue }
                pendingPhotos.removeValue(forKey: work.recordId)
                try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
                persist()
            } catch AttachmentReferenceWriteError.recordDeleted {
                try requireCurrentScope(isCurrent)
                guard pendingPhotos[snapshot.recordId]?.revision == snapshot.revision else { continue }
                pendingPhotos.removeValue(forKey: snapshot.recordId)
                try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
            } catch {
                try requireCurrentScope(isCurrent)
                if error is VineyardWriteAuthority.Restricted { continue }
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    nonisolated static func replacingOwnedPhoto(
        in paths: [String],
        previousPath: String?,
        with newPath: String
    ) -> [String] {
        var unrelated = paths.filter { $0 != previousPath && $0 != newPath }
        unrelated.insert(newPath, at: 0)
        return unrelated
    }

    // MARK: - Pull

    func pullRemote(vineyardId: UUID) async throws {
        let isCurrent = currentScopeCheck()
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetchGrowthStageRecords(vineyardId: vineyardId, since: lastSync)
        try requireCurrentScope(isCurrent)

        // Initial sync: push everything local if remote is empty.
        if remote.isEmpty, lastSync == nil {
            guard writeAuthority.canWrite(vineyardId: vineyardId.uuidString) else { return }
            let local = records.filter { $0.vineyardId == vineyardId }
            if !local.isEmpty {
                let now = Date()
                for record in local where metadata.pendingUpserts[record.id] == nil &&
                    !deletionStore.growthRecordIds.contains(record.id) && metadata.pendingDeletes[record.id] == nil {
                    metadata.markDirty(record.id, at: now)
                }
                try await pushQueuedGrowthRecords(vineyardId: vineyardId)
                try requireCurrentScope(isCurrent)
            }
            return
        }

        for backendRecord in remote {
            apply(backendRecord, vineyardId: vineyardId)
        }
        persist()
    }

    private func apply(_ backend: BackendGrowthStageRecord, vineyardId: UUID) {
        guard backend.vineyardId == vineyardId else { return }
        // Remote timestamps/deletions never acknowledge unsent local evidence.
        if metadata.pendingUpserts[backend.id] != nil || pendingPhotos[backend.id] != nil || metadata.isUnknownOutcome(backend.id) { return }
        if metadata.pendingDeletes[backend.id] != nil || deletionStore.growthRecordIds.contains(backend.id) { return }

        if backend.deletedAt != nil {
            records.removeAll { $0.id == backend.id }
            metadata.clearDirty([backend.id])
            metadata.clearDeleted([backend.id])
            return
        }

        if let pendingAt = metadata.pendingUpserts[backend.id] {
            let remoteAt = backend.clientUpdatedAt ?? backend.updatedAt ?? .distantPast
            if pendingAt > remoteAt { return }
        }

        let mapped = backend.toGrowthStageRecord()
        if let idx = records.firstIndex(where: { $0.id == mapped.id }) {
            records[idx] = mapped
        } else {
            records.append(mapped)
        }
        metadata.clearDirty([backend.id])
    }

    // MARK: - Persistence

    private func persist() {
        persistence.save(records, key: persistenceKey)
    }
}

// MARK: - Metadata

@MainActor
final class GrowthStageRecordSyncMetadata {
    private let persistence: PersistenceStore
    private let key: String = "vinetrack_growth_stage_record_sync_metadata"
    private var state: State

    nonisolated struct State: Codable, Sendable {
        var lastSyncByVineyard: [UUID: Date] = [:]
        var pendingUpserts: [UUID: Date] = [:]
        var pendingDeletes: [UUID: Date] = [:]
        var unknownOutcomeUpserts: Set<UUID>?
        var permanentSnapshots: [UUID: GrowthStageRecord]?
    }

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.state = persistence.load(key: key) ?? State()
    }

    func permanentSnapshot(_ id: UUID) -> GrowthStageRecord? { state.permanentSnapshots?[id] }
    func holdPermanent(_ record: GrowthStageRecord) throws {
        if state.permanentSnapshots == nil { state.permanentSnapshots = [:] }
        state.permanentSnapshots?[record.id] = record
        try persistence.saveOrThrow(state, key: key)
    }

    var pendingUpserts: [UUID: Date] { state.pendingUpserts }
    var pendingDeletes: [UUID: Date] { state.pendingDeletes }
    func isUnknownOutcome(_ id: UUID) -> Bool { state.unknownOutcomeUpserts?.contains(id) == true }
    var unknownOutcomeUpserts: Set<UUID>? { state.unknownOutcomeUpserts }

    func restoreUnknownOutcomeAfterHold(_ ids: [UUID], original: Set<UUID>?) {
        var retained = state.unknownOutcomeUpserts ?? []
        retained.subtract(ids.filter { original?.contains($0) != true })
        state.unknownOutcomeUpserts = retained.isEmpty && original == nil ? nil : retained
        save()
    }

    func lastSync(for vineyardId: UUID) -> Date? {
        state.lastSyncByVineyard[vineyardId]
    }

    func setLastSync(_ date: Date, for vineyardId: UUID) {
        state.lastSyncByVineyard[vineyardId] = date
        save()
    }

    func markDirty(_ id: UUID, at date: Date) {
        state.pendingUpserts[id] = date
        state.unknownOutcomeUpserts?.remove(id)
        save()
    }

    func markDeleted(_ id: UUID, at date: Date) {
        state.pendingUpserts.removeValue(forKey: id)
        state.unknownOutcomeUpserts?.remove(id)
        state.pendingDeletes[id] = date
        save()
    }

    func markUnknownOutcome(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var values = state.unknownOutcomeUpserts ?? []
        values.formUnion(ids)
        state.unknownOutcomeUpserts = values
        save()
    }

    func clearUnknownOutcome(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        state.unknownOutcomeUpserts?.subtract(ids)
        save()
    }

    func clearDirty(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            state.pendingUpserts.removeValue(forKey: id)
            state.permanentSnapshots?.removeValue(forKey: id)
        }
        save()
    }

    func clearDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.pendingDeletes.removeValue(forKey: id) }
        save()
    }

    private func save() {
        persistence.save(state, key: key)
    }
}
