import Foundation
import Observation

/// Local-first sync service for per-vineyard repair/growth button configuration.
/// Tracks dirty state for the currently selected vineyard's button sets and
/// pushes/pulls them against Supabase via `SupabaseButtonConfigSyncRepository`.
/// Conflict resolution is last-write-wins based on `client_updated_at`.
@Observable
@MainActor
final class ButtonConfigSyncService {

    enum Status: Equatable, Sendable {
        case idle
        case syncing
        case success
        case failure(String)
    }

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any ButtonConfigSyncRepositoryProtocol
    private let metadata: ButtonConfigSyncMetadata
    private var isConfigured: Bool = false

    init(
        repository: (any ButtonConfigSyncRepositoryProtocol)? = nil,
        metadata: ButtonConfigSyncMetadata? = nil
    ) {
        self.repository = repository ?? SupabaseButtonConfigSyncRepository()
        self.metadata = metadata ?? ButtonConfigSyncMetadata()
    }

    // MARK: - Configuration

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onRepairButtonsChanged = { [weak self] ts in
            guard let self, let vineyardId = store.selectedVineyardId else { return }
            self.metadata.markDirty(vineyardId: vineyardId, type: .repairButtons, at: ts)
        }
        store.onGrowthButtonsChanged = { [weak self] ts in
            guard let self, let vineyardId = store.selectedVineyardId else { return }
            self.metadata.markDirty(vineyardId: vineyardId, type: .growthButtons, at: ts)
        }
    }

    // MARK: - Dirty tracking

    func markRepairButtonsDirty() {
        guard let vineyardId = store?.selectedVineyardId else { return }
        metadata.markDirty(vineyardId: vineyardId, type: .repairButtons, at: Date())
    }

    func markGrowthButtonsDirty() {
        guard let vineyardId = store?.selectedVineyardId else { return }
        metadata.markDirty(vineyardId: vineyardId, type: .growthButtons, at: Date())
    }

    // MARK: - Public sync entry points

    func syncButtonConfigForSelectedVineyard() async {
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
            try await pullRemoteButtonConfig(vineyardId: vineyardId)
            try await pushLocalButtonConfig(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: - Pull

    func pullRemoteButtonConfig(vineyardId: UUID) async throws {
        guard let store else { return }
        let remote = try await repository.fetchButtonConfigs(vineyardId: vineyardId)

        for row in remote {
            guard let type = row.type, row.deletedAt == nil else { continue }
            // Last-write-wins: skip remote if the local pending change is newer.
            if let pendingDirtyAt = metadata.pendingTimestamp(vineyardId: vineyardId, type: type) {
                let remoteAt = row.clientUpdatedAt ?? row.updatedAt ?? .distantPast
                if pendingDirtyAt > remoteAt { continue }
            }
            switch type {
            case .repairButtons:
                store.applyRemoteRepairButtons(row.configData, vineyardId: vineyardId)
                metadata.clearDirty(vineyardId: vineyardId, type: .repairButtons)
            case .growthButtons:
                store.applyRemoteGrowthButtons(row.configData, vineyardId: vineyardId)
                metadata.clearDirty(vineyardId: vineyardId, type: .growthButtons)
            case .buttonTemplates:
                continue
            }
        }
    }

    // MARK: - Push

    func pushLocalButtonConfig(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        var payloads: [BackendButtonConfigUpsert] = []
        var pushed: [(BackendButtonConfigType, Date)] = []

        if let dirtyAt = metadata.pendingTimestamp(vineyardId: vineyardId, type: .repairButtons),
           !store.repairButtons.isEmpty {
            let id = metadata.rowId(vineyardId: vineyardId, type: .repairButtons)
            payloads.append(BackendButtonConfig.upsert(
                id: id,
                vineyardId: vineyardId,
                configType: .repairButtons,
                buttons: store.repairButtons,
                createdBy: createdBy,
                clientUpdatedAt: dirtyAt
            ))
            pushed.append((.repairButtons, dirtyAt))
        }

        if let dirtyAt = metadata.pendingTimestamp(vineyardId: vineyardId, type: .growthButtons),
           !store.growthButtons.isEmpty {
            let id = metadata.rowId(vineyardId: vineyardId, type: .growthButtons)
            payloads.append(BackendButtonConfig.upsert(
                id: id,
                vineyardId: vineyardId,
                configType: .growthButtons,
                buttons: store.growthButtons,
                createdBy: createdBy,
                clientUpdatedAt: dirtyAt
            ))
            pushed.append((.growthButtons, dirtyAt))
        }

        if !payloads.isEmpty {
            try await repository.upsertButtonConfigs(payloads)
            for (type, _) in pushed {
                metadata.clearDirty(vineyardId: vineyardId, type: type)
            }
        }
    }
}

// MARK: - Metadata

@MainActor
final class ButtonConfigSyncMetadata {
    private let persistence: PersistenceStore
    private let key: String = "vinetrack_button_config_sync_metadata"
    private var state: State

    nonisolated struct PendingKey: Codable, Sendable, Hashable {
        let vineyardId: UUID
        let type: String
    }

    nonisolated struct State: Codable, Sendable {
        var lastSyncByVineyard: [UUID: Date] = [:]
        var pendingByKey: [String: Date] = [:]
        var rowIdsByKey: [String: UUID] = [:]
    }

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.state = persistence.load(key: key) ?? State()
    }

    private func compositeKey(_ vineyardId: UUID, _ type: BackendButtonConfigType) -> String {
        "\(vineyardId.uuidString)::\(type.rawValue)"
    }

    func lastSync(for vineyardId: UUID) -> Date? {
        state.lastSyncByVineyard[vineyardId]
    }

    func setLastSync(_ date: Date, for vineyardId: UUID) {
        state.lastSyncByVineyard[vineyardId] = date
        save()
    }

    func pendingTimestamp(vineyardId: UUID, type: BackendButtonConfigType) -> Date? {
        state.pendingByKey[compositeKey(vineyardId, type)]
    }

    func markDirty(vineyardId: UUID, type: BackendButtonConfigType, at date: Date) {
        state.pendingByKey[compositeKey(vineyardId, type)] = date
        save()
    }

    func clearDirty(vineyardId: UUID, type: BackendButtonConfigType) {
        state.pendingByKey.removeValue(forKey: compositeKey(vineyardId, type))
        save()
    }

    /// Stable row id used for upserting a vineyard+config_type pair. The DB
    /// uniqueness is on (vineyard_id, config_type); the id only matters for
    /// matching up future updates locally.
    func rowId(vineyardId: UUID, type: BackendButtonConfigType) -> UUID {
        let key = compositeKey(vineyardId, type)
        if let existing = state.rowIdsByKey[key] {
            return existing
        }
        let new = UUID()
        state.rowIdsByKey[key] = new
        save()
        return new
    }

    private func save() {
        persistence.save(state, key: key)
    }
}
