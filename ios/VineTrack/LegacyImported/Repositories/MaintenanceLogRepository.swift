import Foundation

/// Records, original photo bytes and their replay intents share one atomic file.
@MainActor
final class MaintenanceLogRepository {
    static let storageKey = "vinetrack_maintenance_logs"
    private let persistence: PersistenceStore

    nonisolated struct Intent: Codable, Sendable {
        var token: UUID
        var timestamp: Date
        var accountId: UUID
        var original: MaintenanceLog
        var deleted: Bool
    }

    nonisolated struct State: Codable, Sendable {
        var records: [MaintenanceLog] = []
        var pending: [UUID: Intent] = [:]
        enum CodingKeys: String, CodingKey { case records, pending }
        init() {}
        init(from decoder: Decoder) throws {
            if let legacy = try? decoder.singleValueContainer().decode([MaintenanceLog].self) {
                records = legacy
            } else {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                records = try c.decode([MaintenanceLog].self, forKey: .records)
                pending = try c.decodeIfPresent([UUID: Intent].self, forKey: .pending) ?? [:]
            }
        }
    }

    init(persistence: PersistenceStore = .shared) { self.persistence = persistence }

    private func state() throws -> State {
        let outcome: PersistenceStore.LoadOutcome<State> = persistence.loadOutcome(key: Self.storageKey)
        switch outcome {
        case .missing: return State()
        case .decoded(let state): return state
        case .failed(let error): throw error
        }
    }

    func loadAll() -> [MaintenanceLog] { (try? state().records) ?? [] }
    func load(for vineyardId: UUID) -> [MaintenanceLog] { loadAll().filter { $0.vineyardId == vineyardId } }
    func pendingIntents() -> [UUID: Intent] { (try? state().pending) ?? [:] }

    func saveLocal(_ record: MaintenanceLog, accountId: UUID, deleted: Bool = false, at timestamp: Date = Date()) throws {
        var state = try state()
        if let existing = state.pending[record.id], existing.accountId != accountId {
            throw CocoaError(.fileWriteNoPermission)
        }
        state.records.removeAll { $0.id == record.id }
        if !deleted { state.records.append(record) }
        state.pending[record.id] = Intent(token: UUID(), timestamp: timestamp, accountId: accountId, original: record, deleted: deleted)
        try persistence.saveOrThrow(state, key: Self.storageKey)
    }

    /// Saving an upload receipt cannot acknowledge metadata or replace a newer edit.
    @discardableResult
    func retainPhotoReceipt(id: UUID, token: UUID, path: String) throws -> Bool {
        var state = try state()
        guard var intent = state.pending[id], intent.token == token, !intent.deleted else { return false }
        intent.original.photoPath = path
        state.pending[id] = intent
        if let index = state.records.firstIndex(where: { $0.id == id }) { state.records[index].photoPath = path }
        try persistence.saveOrThrow(state, key: Self.storageKey)
        return true
    }

    func acknowledge(_ expected: [UUID: UUID]) throws {
        var state = try state()
        for (id, token) in expected where state.pending[id]?.token == token {
            state.pending.removeValue(forKey: id)
        }
        try persistence.saveOrThrow(state, key: Self.storageKey)
    }

    /// Remote refreshes and legacy callers cannot replace a pending revision or
    /// resurrect a tombstone, including when another vineyard slice is loaded.
    func saveSlice(_ items: [MaintenanceLog], for vineyardId: UUID) {
        guard var state = try? state() else { return }
        state.records.removeAll { $0.vineyardId == vineyardId && state.pending[$0.id] == nil }
        state.records.append(contentsOf: items.filter { state.pending[$0.id] == nil })
        try? persistence.saveOrThrow(state, key: Self.storageKey)
    }

    func replace(_ remote: [MaintenanceLog], for vineyardId: UUID) { saveSlice(remote, for: vineyardId) }

    func merge(_ remote: [MaintenanceLog], for vineyardId: UUID) -> [MaintenanceLog] {
        guard var state = try? state() else { return load(for: vineyardId) }
        for item in remote where state.pending[item.id] == nil {
            state.records.removeAll { $0.id == item.id }
            state.records.append(item)
        }
        try? persistence.saveOrThrow(state, key: Self.storageKey)
        return state.records.filter { $0.vineyardId == vineyardId }
    }
}
