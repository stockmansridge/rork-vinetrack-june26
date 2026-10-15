import Foundation
import Observation

/// Local-first sync service for per-vineyard repair/growth button configuration.
/// Tracks dirty state for the currently selected vineyard's button sets and
/// pushes/pulls them against Supabase via `SupabaseButtonConfigSyncRepository`.
/// Dirty local edits survive pulls; conditional writes require an exact returned acknowledgement.
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
    private let isBackendConfigured: () -> Bool
    private var isConfigured: Bool = false
    private var isSyncing: Bool = false

    init(
        repository: (any ButtonConfigSyncRepositoryProtocol)? = nil,
        metadata: ButtonConfigSyncMetadata? = nil,
        isBackendConfigured: @escaping () -> Bool = { SupabaseClientProvider.shared.isConfigured }
    ) {
        self.isBackendConfigured = isBackendConfigured
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
        guard isBackendConfigured() else {
            errorMessage = "Supabase not configured"
            syncStatus = .failure("Supabase not configured")
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        syncStatus = .syncing
        errorMessage = nil
        do {
            try await pullRemoteButtonConfig(vineyardId: vineyardId)
            try await pushLocalButtonConfig(vineyardId: vineyardId)
            guard metadata.pendingTimestamp(vineyardId: vineyardId, type: .repairButtons) == nil,
                  metadata.pendingTimestamp(vineyardId: vineyardId, type: .growthButtons) == nil else {
                throw ButtonConfigSyncError.reviewRequired
            }
            metadata.setLastSync(Date(), for: vineyardId)
            guard metadata.persistenceError == nil else { throw ButtonConfigSyncError.reviewRequired }
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
        let actor = auth?.userId
        let signOutSequence = auth?.completedSignOutSequence
        let remote = try await repository.fetchButtonConfigs(vineyardId: vineyardId)
        guard auth?.userId == actor, auth?.completedSignOutSequence == signOutSequence, store.selectedVineyardId == vineyardId else { throw ButtonConfigSyncError.scopeChanged }

        for row in remote {
            guard let type = row.type, row.deletedAt == nil else { continue }
            guard row.vineyardId == vineyardId else { throw ButtonConfigSyncError.reviewRequired }
            metadata.rememberRowId(row.id, vineyardId: vineyardId, type: type)
            if let dirty = metadata.pendingTimestamp(vineyardId: vineyardId, type: type), dirty != .distantPast {
                // A remote timestamp is not an acknowledgement of our unsent edit.
                continue
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
        guard store.selectedVineyardId == vineyardId else { throw ButtonConfigSyncError.scopeChanged }
        let createdBy = auth?.userId
        let signOutSequence = auth?.completedSignOutSequence
        guard metadata.persistenceError == nil else { throw ButtonConfigSyncError.reviewRequired }
        var payloads: [BackendButtonConfigUpsert] = []

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

        }

        for payload in payloads {
            let rows = try await repository.fetchButtonConfigs(vineyardId: vineyardId)
            guard auth?.userId == createdBy, auth?.completedSignOutSequence == signOutSequence, store.selectedVineyardId == vineyardId else { throw ButtonConfigSyncError.scopeChanged }
            let matches = rows.filter { $0.configType == payload.configType && $0.vineyardId == vineyardId }
            guard matches.count <= 1 else { throw ButtonConfigSyncError.reviewRequired }
            let expected = matches.first
            if let expected, (expected.clientUpdatedAt ?? expected.updatedAt ?? .distantPast) > payload.clientUpdatedAt,
               expected.configData != payload.configData { throw ButtonConfigSyncError.reviewRequired }
            let request = BackendButtonConfigUpsert(id: expected?.id ?? payload.id, vineyardId: vineyardId,
                configType: payload.configType, configData: payload.configData,
                createdBy: expected == nil ? createdBy : expected?.createdBy, clientUpdatedAt: payload.clientUpdatedAt)
            let ack = try await repository.saveButtonConfig(request, replacing: expected)
            guard auth?.userId == createdBy, auth?.completedSignOutSequence == signOutSequence, store.selectedVineyardId == vineyardId else { throw ButtonConfigSyncError.scopeChanged }
            guard ack.id == request.id, ack.vineyardId == vineyardId, ack.configType == request.configType,
                  ack.deletedAt == nil, ack.configData == request.configData else { throw ButtonConfigSyncError.reviewRequired }
            guard let type = BackendButtonConfigType(rawValue: payload.configType) else { throw ButtonConfigSyncError.reviewRequired }
            metadata.rememberRowId(ack.id, vineyardId: vineyardId, type: type)
            let current = type == .repairButtons ? store.repairButtons : store.growthButtons
            if current == payload.configData {
                metadata.clearDirty(vineyardId: vineyardId, type: type, matching: payload.clientUpdatedAt)
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
    private(set) var persistenceError: String?

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
        let previous = state
        state.pendingByKey.removeValue(forKey: compositeKey(vineyardId, type))
        if !save() { state = previous }
    }

    func clearDirty(vineyardId: UUID, type: BackendButtonConfigType, matching timestamp: Date) {
        guard pendingTimestamp(vineyardId: vineyardId, type: type) == timestamp else { return }
        clearDirty(vineyardId: vineyardId, type: type)
    }

    func rememberRowId(_ id: UUID, vineyardId: UUID, type: BackendButtonConfigType) {
        state.rowIdsByKey[compositeKey(vineyardId, type)] = id
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

    @discardableResult private func save() -> Bool {
        do {
            try persistence.saveOrThrow(state, key: key)
            persistenceError = nil
            return true
        } catch {
            persistenceError = "Button sync state could not be saved. Keep this app open, free storage and retry."
            return false
        }
    }
}
