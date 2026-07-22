import Foundation
import Observation

// MARK: - Shared metadata

@MainActor
final class ManagementSyncMetadata {
    private let persistence: PersistenceStore
    private let key: String
    private var state: State

    nonisolated struct State: Codable, Sendable {
        var lastSyncByVineyard: [UUID: Date] = [:]
        var pendingUpserts: [UUID: Date] = [:]
        var pendingDeletes: [UUID: Date] = [:]
    }

    init(key: String, persistence: PersistenceStore = .shared) {
        self.key = key
        self.persistence = persistence
        self.state = persistence.load(key: key) ?? State()
    }

    var pendingUpserts: [UUID: Date] { state.pendingUpserts }
    var pendingDeletes: [UUID: Date] { state.pendingDeletes }

    func lastSync(for vineyardId: UUID) -> Date? { state.lastSyncByVineyard[vineyardId] }

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

    /// Reset all per-vineyard last-sync timestamps so the next sync is treated
    /// as an initial sync. Used by one-time migrations that need to re-attempt
    /// the initial seed push for data that pre-dates the sync wiring.
    func resetAllLastSync() {
        guard !state.lastSyncByVineyard.isEmpty else { return }
        state.lastSyncByVineyard = [:]
        save()
    }

    private func save() { persistence.save(state, key: key) }
}

/// Matches the Postgres 23505 unique-violation raised by
/// `uniq_worker_types_active_name_cost` (sql/106) when two clients create the
/// same worker type (name + cost) under different ids.
private func isDuplicateWorkerTypeError(_ error: Error) -> Bool {
    let message = String(describing: error).lowercased()
    return message.contains("uniq_worker_types_active_name_cost")
        || message.contains("duplicate key")
        || message.contains("23505")
}

/// Byte-for-byte the same normalisation as `worker_type_normalised_name`
/// in sql/106: trim, collapse internal whitespace, lowercase.
private func normalisedWorkerTypeName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .lowercased()
}

private func isMissingRowError(_ error: Error) -> Bool {
    let message = String(describing: error).lowercased()
    if message.contains("not found") { return true }
    if message.contains("pgrst116") { return true }
    if message.contains("no rows") { return true }
    if message.contains("0 rows") { return true }
    return false
}

nonisolated enum ManagementSyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case success
    case failure(String)
}

// MARK: - SavedChemicalSyncService

@Observable
@MainActor
final class SavedChemicalSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any SavedChemicalSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false

    init(repository: (any SavedChemicalSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseSavedChemicalSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_saved_chemical_sync_metadata")

        // One-time recovery: re-attempt initial seed push for rows that
        // pre-date sync wiring but were never pushed remotely.
        let migrationKey = "vinetrack_saved_chemical_sync_reset_v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            self.metadata.resetAllLastSync()
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onSavedChemicalChanged = { [weak self] id in self?.metadata.markDirty(id, at: Date()) }
        store.onSavedChemicalDeleted = { [weak self] id in self?.metadata.markDeleted(id, at: Date()) }
    }

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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.savedChemicals.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendSavedChemicalUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendSavedChemical.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isMissingRowError(error) {
                    metadata.clearDeleted([id])
                }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.savedChemicals.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendSavedChemical.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[SavedChemicalSync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[SavedChemicalSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteSavedChemicalDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteSavedChemicalUpsert(item.toSavedChemical())
            metadata.clearDirty([item.id])
        }
    }
}

// MARK: - SavedSprayPresetSyncService

@Observable
@MainActor
final class SavedSprayPresetSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any SavedSprayPresetSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false

    init(repository: (any SavedSprayPresetSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseSavedSprayPresetSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_saved_spray_preset_sync_metadata")

        let migrationKey = "vinetrack_saved_spray_preset_sync_reset_v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            self.metadata.resetAllLastSync()
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onSavedSprayPresetChanged = { [weak self] id in self?.metadata.markDirty(id, at: Date()) }
        store.onSavedSprayPresetDeleted = { [weak self] id in self?.metadata.markDeleted(id, at: Date()) }
    }

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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.savedSprayPresets.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendSavedSprayPresetUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendSavedSprayPreset.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isMissingRowError(error) { metadata.clearDeleted([id]) }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.savedSprayPresets.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendSavedSprayPreset.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[SavedSprayPresetSync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[SavedSprayPresetSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteSavedSprayPresetDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteSavedSprayPresetUpsert(item.toSavedSprayPreset())
            metadata.clearDirty([item.id])
        }
    }
}

// MARK: - SprayEquipmentSyncService

@Observable
@MainActor
final class SprayEquipmentSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }
    private let repository: any SprayEquipmentSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false

    init(repository: (any SprayEquipmentSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseSprayEquipmentSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_spray_equipment_sync_metadata")

        let migrationKey = "vinetrack_spray_equipment_sync_reset_v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            self.metadata.resetAllLastSync()
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onSprayEquipmentChanged = { [weak self] id in self?.metadata.markDirty(id, at: Date()) }
        store.onSprayEquipmentDeleted = { [weak self] id in self?.metadata.markDeleted(id, at: Date()) }
    }

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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.sprayEquipment.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendSprayEquipmentUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendSprayEquipment.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isMissingRowError(error) { metadata.clearDeleted([id]) }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.sprayEquipment.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendSprayEquipment.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[SprayEquipmentSync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[SprayEquipmentSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteSprayEquipmentDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteSprayEquipmentUpsert(item.toSprayEquipmentItem())
            metadata.clearDirty([item.id])
        }
    }
}

// MARK: - TractorSyncService

@Observable
@MainActor
final class TractorSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any TractorSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false

    init(repository: (any TractorSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseTractorSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_tractor_sync_metadata")

        // One-time recovery: existing devices may have a stored lastSync from
        // a previous failed initial seed (tractors created before sync was
        // wired never reached Supabase). Reset lastSync once so the next sync
        // treats it as a fresh initial sync and re-attempts the seed push.
        let migrationKey = "vinetrack_tractor_sync_reset_v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            self.metadata.resetAllLastSync()
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onTractorChanged = { [weak self] id in self?.metadata.markDirty(id, at: Date()) }
        store.onTractorDeleted = { [weak self] id in self?.metadata.markDeleted(id, at: Date()) }
    }

    func syncForSelectedVineyard() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId else { return }
        await sync(vineyardId: vineyardId)
    }

    /// Diagnostics helper: count remote tractor rows for the selected
    /// vineyard (including soft-deleted) so the Sync panel can compare
    /// local vs remote without changing the user-facing pull path.
    func fetchRemoteCountForSelectedVineyard() async -> Int? {
        guard let store, let vineyardId = store.selectedVineyardId else { return nil }
        do {
            let remote = try await repository.fetch(vineyardId: vineyardId, since: nil)
            return remote.filter { $0.deletedAt == nil }.count
        } catch {
            return nil
        }
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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.tractors.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendTractorUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendTractor.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isMissingRowError(error) { metadata.clearDeleted([id]) }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)

        // Initial sync: push any local tractors that don't yet exist remotely.
        // Previously this only ran when `remote.isEmpty`, which missed cases
        // where some (but not all) local tractors had been pushed.
        if lastSync == nil {
            let allRemote: [BackendTractor]
            if remote.isEmpty {
                allRemote = remote
            } else {
                // `remote` already contains every row for this vineyard when
                // since is nil, so we can reuse it.
                allRemote = remote
            }
            let remoteIds = Set(allRemote.map { $0.id })
            let local = store.tractors.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendTractor.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[TractorSync] initial seed pushed \(payloads.count) local tractor(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[TractorSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }

        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteTractorDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteTractorUpsert(item.toTractor())
            metadata.clearDirty([item.id])
        }
    }
}

// MARK: - VineyardMachineSyncService

@Observable
@MainActor
final class VineyardMachineSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any VineyardMachineSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false

    init(repository: (any VineyardMachineSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseVineyardMachineSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_vineyard_machine_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onVineyardMachineChanged = { [weak self] id in self?.metadata.markDirty(id, at: Date()) }
        store.onVineyardMachineDeleted = { [weak self] id in self?.metadata.markDeleted(id, at: Date()) }
    }

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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.vineyardMachines.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendVineyardMachineUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendVineyardMachine.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isMissingRowError(error) { metadata.clearDeleted([id]) }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)

        // Initial sync: push any local machines not yet present remotely so a
        // device that created machines offline does not lose them.
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.vineyardMachines.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendVineyardMachine.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[VineyardMachineSync] initial seed pushed \(payloads.count) local machine(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[VineyardMachineSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }

        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteVineyardMachineDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteVineyardMachineUpsert(item.toVineyardMachine())
            metadata.clearDirty([item.id])
        }
    }
}

// MARK: - FuelPurchaseSyncService

@Observable
@MainActor
final class FuelPurchaseSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }
    private let repository: any FuelPurchaseSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false

    init(repository: (any FuelPurchaseSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseFuelPurchaseSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_fuel_purchase_sync_metadata")

        let migrationKey = "vinetrack_fuel_purchase_sync_reset_v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            self.metadata.resetAllLastSync()
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onFuelPurchaseChanged = { [weak self] id in self?.metadata.markDirty(id, at: Date()) }
        store.onFuelPurchaseDeleted = { [weak self] id in self?.metadata.markDeleted(id, at: Date()) }
    }

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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.fuelPurchases.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendFuelPurchaseUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendFuelPurchase.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isMissingRowError(error) { metadata.clearDeleted([id]) }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.fuelPurchases.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendFuelPurchase.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[FuelPurchaseSync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[FuelPurchaseSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteFuelPurchaseDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteFuelPurchaseUpsert(item.toFuelPurchase())
            metadata.clearDirty([item.id])
        }
    }
}

// MARK: - TractorFuelLogSyncService

@Observable
@MainActor
final class TractorFuelLogSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }
    private let repository: any TractorFuelLogSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false

    init(repository: (any TractorFuelLogSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseTractorFuelLogSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_tractor_fuel_log_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onTractorFuelLogChanged = { [weak self] id in self?.metadata.markDirty(id, at: Date()) }
        store.onTractorFuelLogDeleted = { [weak self] id in self?.metadata.markDeleted(id, at: Date()) }
    }

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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.tractorFuelLogs.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendTractorFuelLogUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendTractorFuelLog.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isMissingRowError(error) { metadata.clearDeleted([id]) }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.tractorFuelLogs.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendTractorFuelLog.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[TractorFuelLogSync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[TractorFuelLogSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteTractorFuelLogDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteTractorFuelLogUpsert(item.toTractorFuelLog())
            metadata.clearDirty([item.id])
        }
    }
}

// MARK: - OperatorCategorySyncService

@Observable
@MainActor
final class OperatorCategorySyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any OperatorCategorySyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    private func scheduleEagerPush() {
        eagerPushTask?.cancel()
        eagerPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.syncForSelectedVineyard()
        }
    }

    init(repository: (any OperatorCategorySyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseOperatorCategorySyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_operator_category_sync_metadata")

        let migrationKey = "vinetrack_operator_category_sync_reset_v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            self.metadata.resetAllLastSync()
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onOperatorCategoryChanged = { [weak self] id in
            self?.metadata.markDirty(id, at: Date()); self?.scheduleEagerPush()
        }
        store.onOperatorCategoryDeleted = { [weak self] id in
            self?.metadata.markDeleted(id, at: Date()); self?.scheduleEagerPush()
        }
    }

    func syncForSelectedVineyard() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId else { return }
        await sync(vineyardId: vineyardId)
    }

    /// Diagnostics helper: re-mark every local operator category for the selected
    /// vineyard as pending upsert and push immediately. Use when iOS-created
    /// categories never reached Supabase (e.g. created before sync wiring or
    /// after a metadata reset).
    func forceRepushLocalForSelectedVineyard() async -> String {
        guard let store, let auth, auth.isSignedIn else {
            return "Not signed in"
        }
        guard let vineyardId = store.selectedVineyardId else {
            return "No selected vineyard"
        }
        let now = Date()
        let locals = store.operatorCategories.filter { $0.vineyardId == vineyardId }
        for cat in locals { metadata.markDirty(cat.id, at: now) }
        await sync(vineyardId: vineyardId)
        return "Re-marked \(locals.count) local categor\(locals.count == 1 ? "y" : "ies") dirty; status=\(syncStatus); error=\(errorMessage ?? "none")"
    }

    /// Diagnostics helper: fetch raw remote rows for the selected vineyard.
    func fetchRemoteForSelectedVineyard() async throws -> [BackendOperatorCategory] {
        guard let store, let vineyardId = store.selectedVineyardId else { return [] }
        return try await repository.fetch(vineyardId: vineyardId, since: nil)
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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId

        // Deletes run FIRST: a queued soft-delete can be holding the same
        // (name, cost) slot on the server's `uniq_worker_types_active_name_cost`
        // index. Freeing it before the upserts prevents a permanent
        // duplicate-key wedge when the local de-dupe kept a different id.
        let pendingDeletes = metadata.pendingDeletes
        if !pendingDeletes.isEmpty {
            #if DEBUG
            print("[OperatorCategorySync] push: \(pendingDeletes.count) pending delete(s) for vineyard \(vineyardId.uuidString)")
            #endif
        }
        var firstDeleteError: Error?
        for (id, _) in pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
                #if DEBUG
                print("[OperatorCategorySync] push: soft-deleted id=\(id) on server")
                #endif
            } catch {
                if isMissingRowError(error) {
                    metadata.clearDeleted([id])
                    #if DEBUG
                    print("[OperatorCategorySync] push: id=\(id) missing on server — clearing pending delete")
                    #endif
                } else {
                    #if DEBUG
                    print("[OperatorCategorySync] push: soft-delete FAILED id=\(id) error=\(error.localizedDescription) raw=\(String(describing: error))")
                    #endif
                    if firstDeleteError == nil { firstDeleteError = error }
                }
            }
        }

        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.operatorCategories.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendOperatorCategoryUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendOperatorCategory.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                #if DEBUG
                print("[OperatorCategorySync] push: upserting \(payloads.count) row(s) for vineyard \(vineyardId.uuidString)")
                #endif
                do {
                    try await repository.upsertMany(payloads)
                    metadata.clearDirty(pushed)
                } catch where isDuplicateWorkerTypeError(error) {
                    try await resolveDuplicateWorkerTypes(payloads: payloads, vineyardId: vineyardId)
                }
            }
        }
        if let firstDeleteError { throw firstDeleteError }
    }

    /// A push collided with the server's `uniq_worker_types_active_name_cost`
    /// unique index: another client (portal / Android) already created a LIVE
    /// worker type with the same name + cost under a DIFFERENT id. Keeping the
    /// local copy queued would wedge the sync forever — retry item-by-item and
    /// adopt the server's canonical row for each conflicting one.
    private func resolveDuplicateWorkerTypes(payloads: [BackendOperatorCategoryUpsert], vineyardId: UUID) async throws {
        guard let store else { return }
        var remoteRows: [BackendOperatorCategory]?
        for payload in payloads {
            do {
                try await repository.upsertMany([payload])
                metadata.clearDirty([payload.id])
            } catch where isDuplicateWorkerTypeError(error) {
                if remoteRows == nil {
                    remoteRows = try await repository.fetch(vineyardId: vineyardId, since: nil)
                }
                let wanted = normalisedWorkerTypeName(payload.name)
                let match = (remoteRows ?? []).first {
                    $0.deletedAt == nil
                        && $0.id != payload.id
                        && normalisedWorkerTypeName($0.name ?? "") == wanted
                        && abs(($0.costPerHour ?? 0) - payload.costPerHour) < 0.00005
                }
                if let match {
                    store.adoptRemoteOperatorCategory(localId: payload.id, remote: match.toOperatorCategory())
                    metadata.clearDirty([payload.id])
                    // Never soft-delete the canonical row we just adopted.
                    metadata.clearDeleted([match.id])
                    #if DEBUG
                    print("[OperatorCategorySync] adopted server worker type \(match.id) for local duplicate \(payload.id)")
                    #endif
                } else {
                    // Conflict against a row we cannot see — drop the queued
                    // copy instead of wedging every future sync; the pull
                    // restores the server's truth.
                    metadata.clearDirty([payload.id])
                    #if DEBUG
                    print("[OperatorCategorySync] duplicate conflict for \(payload.id) with no visible server match — dropping queued copy")
                    #endif
                }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        #if DEBUG
        print("[OperatorCategorySync] pull vineyard=\(vineyardId.uuidString) since=\(lastSync.map { ISO8601DateFormatter().string(from: $0) } ?? "nil") remote.count=\(remote.count)")
        for item in remote {
            print("[OperatorCategorySync]   remote id=\(item.id) name=\(item.name ?? "nil") cost=\(item.costPerHour ?? 0) deletedAt=\(item.deletedAt?.description ?? "nil")")
        }
        #endif
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.operatorCategories.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendOperatorCategory.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[OperatorCategorySync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[OperatorCategorySync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteOperatorCategoryDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt {
                    #if DEBUG
                    print("[OperatorCategorySync]   skip id=\(item.id) — local pending newer than remote")
                    #endif
                    continue
                }
            }
            store.applyRemoteOperatorCategoryUpsert(item.toOperatorCategory())
            metadata.clearDirty([item.id])
        }
        // After applying remote upserts, collapse any duplicate operator categories
        // (same vineyard, same name) so the next push will soft-delete the losers.
        _ = store.deduplicateOperatorCategories()
        #if DEBUG
        print("[OperatorCategorySync] local store now has \(store.operatorCategories.filter { $0.vineyardId == vineyardId }.count) operator categor(ies) for vineyard")
        #endif
    }
}

// MARK: - WorkTaskTypeSyncService

@Observable
@MainActor
final class WorkTaskTypeSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any WorkTaskTypeSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    private func scheduleEagerPush() {
        eagerPushTask?.cancel()
        eagerPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.syncForSelectedVineyard()
        }
    }

    init(repository: (any WorkTaskTypeSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseWorkTaskTypeSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_work_task_type_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onWorkTaskTypeChanged = { [weak self] id in
            self?.metadata.markDirty(id, at: Date()); self?.scheduleEagerPush()
        }
        store.onWorkTaskTypeDeleted = { [weak self] id in
            self?.metadata.markDeleted(id, at: Date()); self?.scheduleEagerPush()
        }
    }

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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let userId = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.workTaskTypes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendWorkTaskTypeUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendWorkTaskType.upsert(from: item, createdBy: userId, updatedBy: userId, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        let pendingDeletes = metadata.pendingDeletes
        var firstDeleteError: Error?
        for (id, _) in pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isMissingRowError(error) {
                    metadata.clearDeleted([id])
                } else {
                    #if DEBUG
                    print("[WorkTaskTypeSync] push: soft-delete FAILED id=\(id) error=\(error.localizedDescription)")
                    #endif
                    if firstDeleteError == nil { firstDeleteError = error }
                }
            }
        }
        if let firstDeleteError { throw firstDeleteError }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.workTaskTypes.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let userId = auth?.userId
                let payloads = missing.map { BackendWorkTaskType.upsert(from: $0, createdBy: userId, updatedBy: userId, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[WorkTaskTypeSync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[WorkTaskTypeSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteWorkTaskTypeDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteWorkTaskTypeUpsert(item.toWorkTaskType())
            metadata.clearDirty([item.id])
        }
    }
}

// MARK: - EquipmentItemSyncService

@Observable
@MainActor
final class EquipmentItemSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any EquipmentItemSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    private func scheduleEagerPush() {
        eagerPushTask?.cancel()
        eagerPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.syncForSelectedVineyard()
        }
    }

    init(repository: (any EquipmentItemSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseEquipmentItemSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_equipment_item_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onEquipmentItemChanged = { [weak self] id in
            self?.metadata.markDirty(id, at: Date()); self?.scheduleEagerPush()
        }
        store.onEquipmentItemDeleted = { [weak self] id in
            self?.metadata.markDeleted(id, at: Date()); self?.scheduleEagerPush()
        }
    }

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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let userId = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.equipmentItems.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendEquipmentItemUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendEquipmentItem.upsert(from: item, createdBy: userId, updatedBy: userId, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        let pendingDeletes = metadata.pendingDeletes
        var firstDeleteError: Error?
        for (id, _) in pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isMissingRowError(error) {
                    metadata.clearDeleted([id])
                } else {
                    #if DEBUG
                    print("[EquipmentItemSync] push: soft-delete FAILED id=\(id) error=\(error.localizedDescription)")
                    #endif
                    if firstDeleteError == nil { firstDeleteError = error }
                }
            }
        }
        if let firstDeleteError { throw firstDeleteError }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.equipmentItems.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let userId = auth?.userId
                let payloads = missing.map { BackendEquipmentItem.upsert(from: $0, createdBy: userId, updatedBy: userId, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[EquipmentItemSync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[EquipmentItemSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteEquipmentItemDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteEquipmentItemUpsert(item.toEquipmentItem())
            metadata.clearDirty([item.id])
        }
    }
}

// MARK: - SavedInputSyncService

@Observable
@MainActor
final class SavedInputSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any SavedInputSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    private func scheduleEagerPush() {
        eagerPushTask?.cancel()
        eagerPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.syncForSelectedVineyard()
        }
    }

    init(repository: (any SavedInputSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseSavedInputSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_saved_input_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onSavedInputChanged = { [weak self] id in
            self?.metadata.markDirty(id, at: Date()); self?.scheduleEagerPush()
        }
        store.onSavedInputDeleted = { [weak self] id in
            self?.metadata.markDeleted(id, at: Date()); self?.scheduleEagerPush()
        }
    }

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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.savedInputs.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendSavedInputUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendSavedInput.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        var firstDeleteError: Error?
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isMissingRowError(error) {
                    metadata.clearDeleted([id])
                } else if firstDeleteError == nil {
                    firstDeleteError = error
                }
            }
        }
        if let firstDeleteError { throw firstDeleteError }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.savedInputs.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendSavedInput.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[SavedInputSync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[SavedInputSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteSavedInputDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteSavedInputUpsert(item.toSavedInput())
            metadata.clearDirty([item.id])
        }
    }
}
