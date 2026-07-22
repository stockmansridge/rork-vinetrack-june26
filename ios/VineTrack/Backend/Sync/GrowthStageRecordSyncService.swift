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
    private let repository: any GrowthStageRecordSyncRepositoryProtocol
    private let metadata: GrowthStageRecordSyncMetadata
    private let persistence: PersistenceStore
    private let persistenceKey = "vinetrack_growth_stage_records"
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

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
        metadata: GrowthStageRecordSyncMetadata? = nil,
        persistence: PersistenceStore = .shared
    ) {
        self.repository = repository ?? SupabaseGrowthStageRecordSyncRepository()
        self.metadata = metadata ?? GrowthStageRecordSyncMetadata()
        self.persistence = persistence
        self.records = persistence.load(key: persistenceKey) ?? []
    }

    // MARK: - Configuration

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true

        // Mirror new growth-stage pins into growth_stage_records.
        store.onGrowthStagePinAdded = { [weak self] pin in
            self?.mirrorGrowthStagePin(pin)
        }
        // When a growth-stage pin is soft-deleted locally, also soft-delete
        // its mirrored record so the dedicated table stays in sync.
        store.onGrowthStagePinDeleted = { [weak self] pinId in
            self?.softDeleteByPin(pinId)
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
            mirrorPinWithoutSync(pin)
        }
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
        if pin.growthStageCode == GrowthStage.budburstCode,
           let paddockId = pin.paddockId,
           let store,
           let pIdx = store.paddocks.firstIndex(where: { $0.id == paddockId }),
           store.paddocks[pIdx].budburstDate == nil {
            var p = store.paddocks[pIdx]
            p.budburstDate = pin.timestamp
            store.updatePaddock(p)
            #if DEBUG
            print("[GrowthStageRecord] auto-set budburstDate=\(pin.timestamp) for paddock=\(paddockId) from EL4 pin=\(pin.id)")
            #endif
        }
        // Best-effort: push (debounced) so the record is visible to other
        // devices / Lovable without waiting for the next sync cycle.
        scheduleEagerPush()
    }

    /// Core mirror logic without persistence or sync side-effects. Returns
    /// `true` if the pin was a valid growth-stage pin and was mirrored.
    @discardableResult
    private func mirrorPinWithoutSync(_ pin: VinePin) -> Bool {
        guard pin.mode == .growth, let code = pin.growthStageCode, !code.isEmpty else {
            #if DEBUG
            print("[GrowthStageRecord] mirrorPinWithoutSync SKIPPED — not a growth-stage pin")
            #endif
            return false
        }
        let stageLabel = GrowthStage.allStages.first { $0.code == code }?.description
        let variety = variety(for: pin.paddockId)
        if let idx = records.firstIndex(where: { $0.pinId == pin.id }) {
            var updated = records[idx]
            updated.stageCode = code
            updated.stageLabel = stageLabel
            updated.variety = variety ?? updated.variety
            updated.observedAt = pin.timestamp
            updated.latitude = pin.latitude
            updated.longitude = pin.longitude
            updated.rowNumber = pin.rowNumber
            updated.side = pin.side.rawValue
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
                variety: variety
            ) else { return false }
            mirrored.recordedByName = pin.createdBy ?? auth?.userName
            records.append(mirrored)
            metadata.markDirty(mirrored.id, at: Date())
            #if DEBUG
            print("[GrowthStageRecord] mirrored new record id=\(mirrored.id) for pin=\(pin.id)")
            #endif
        }
        return true
    }

    private func variety(for paddockId: UUID?) -> String? {
        guard let paddockId, let store else { return nil }
        guard let paddock = store.paddocks.first(where: { $0.id == paddockId }) else { return nil }
        // Paddock.variety / grapeVariety field names vary across the codebase;
        // resolve via Mirror so we don't hard-couple to a specific schema.
        for child in Mirror(reflecting: paddock).children {
            guard let label = child.label else { continue }
            let l = label.lowercased()
            if l == "variety" || l == "grapevariety" || l == "grape" {
                if let s = child.value as? String, !s.isEmpty { return s }
                if let s = (child.value as? String?) ?? nil, !s.isEmpty { return s }
            }
        }
        return nil
    }

    private func softDeleteByPin(_ pinId: UUID) {
        guard let idx = records.firstIndex(where: { $0.pinId == pinId }) else { return }
        let recordId = records[idx].id
        records.remove(at: idx)
        metadata.markDeleted(recordId, at: Date())
        persist()
        scheduleEagerPush()
    }

    // MARK: - Public sync entry points

    func syncForSelectedVineyard() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId else { return }
        await sync(vineyardId: vineyardId)
    }

    func sync(vineyardId: UUID) async {
        guard SupabaseClientProvider.shared.isConfigured else {
            errorMessage = "Supabase not configured"
            syncStatus = .failure("Supabase not configured")
            return
        }
        syncStatus = .syncing
        errorMessage = nil
        do {
            try await pushLocal(vineyardId: vineyardId)
            try await pullRemote(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: - Push

    private func pushLocal(vineyardId: UUID) async throws {
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendGrowthStageRecordUpsert] = []
            var pushedIds: [UUID] = []
            for (recordId, ts) in dirty {
                guard let record = byId[recordId], record.vineyardId == vineyardId else { continue }
                payloads.append(BackendGrowthStageRecord.upsert(
                    from: record,
                    createdBy: createdBy,
                    clientUpdatedAt: ts
                ))
                pushedIds.append(recordId)
            }
            if !payloads.isEmpty {
                try await repository.upsertGrowthStageRecords(payloads)
                metadata.clearDirty(pushedIds)
            }
        }

        let deletes = metadata.pendingDeletes
        for (recordId, _) in deletes {
            do {
                try await repository.softDeleteGrowthStageRecord(id: recordId)
                metadata.clearDeleted([recordId])
            } catch {
                let msg = String(describing: error).lowercased()
                if msg.contains("not found") || msg.contains("pgrst116") || msg.contains("no rows") {
                    metadata.clearDeleted([recordId])
                } else {
                    #if DEBUG
                    print("[GrowthStageRecordSync] soft delete failed for \(recordId): \(error.localizedDescription)")
                    #endif
                    continue
                }
            }
        }
    }

    // MARK: - Pull

    private func pullRemote(vineyardId: UUID) async throws {
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetchGrowthStageRecords(vineyardId: vineyardId, since: lastSync)

        // Initial sync: push everything local if remote is empty.
        if remote.isEmpty, lastSync == nil {
            let local = records.filter { $0.vineyardId == vineyardId }
            if !local.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = local.map {
                    BackendGrowthStageRecord.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now)
                }
                try await repository.upsertGrowthStageRecords(payloads)
            }
            return
        }

        for backendRecord in remote {
            apply(backendRecord, vineyardId: vineyardId)
        }
        persist()
    }

    private func apply(_ backend: BackendGrowthStageRecord, vineyardId: UUID) {
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
    }

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.state = persistence.load(key: key) ?? State()
    }

    var pendingUpserts: [UUID: Date] { state.pendingUpserts }
    var pendingDeletes: [UUID: Date] { state.pendingDeletes }

    func lastSync(for vineyardId: UUID) -> Date? {
        state.lastSyncByVineyard[vineyardId]
    }

    func setLastSync(_ date: Date, for vineyardId: UUID) {
        state.lastSyncByVineyard[vineyardId] = date
        save()
    }

    func markDirty(_ id: UUID, at date: Date) {
        state.pendingUpserts[id] = date
        save()
    }

    func markDeleted(_ id: UUID, at date: Date) {
        state.pendingUpserts.removeValue(forKey: id)
        state.pendingDeletes[id] = date
        save()
    }

    func clearDirty(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.pendingUpserts.removeValue(forKey: id) }
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
