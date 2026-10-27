import Foundation

/// Owns persistence and merge/replace logic for the yield domain:
/// YieldEstimationSession, DamageRecord, HistoricalYieldRecord.
@MainActor
final class YieldRepository {

    static let sessionsKey = "vinetrack_yield_sessions"
    static let damageKey = "vinetrack_damage_records"
    static let historicalKey = "vinetrack_historical_yield_records"
    static let determinationKey = "vinetrack_yield_determination_results"
    static let pickingKey = "vinetrack_picking_records"
    static let pruningSettingsKey = "vinetrack_pruning_yield_settings"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - YieldEstimationSession

    /// Session and replay intent share ONE atomic durable file. Older installs
    /// stored a bare array; decoding it does not manufacture pending completions.
    nonisolated struct SaveIntent: Codable, Sendable {
        var token: UUID
        var timestamp: Date
    }

    nonisolated struct SessionsState: Codable, Sendable {
        var sessions: [YieldEstimationSession] = []
        var pending: [UUID: SaveIntent] = [:]
        enum CodingKeys: String, CodingKey { case sessions, pending }
        init() {}
        init(from decoder: Decoder) throws {
            if let legacy = try? decoder.singleValueContainer().decode([YieldEstimationSession].self) {
                sessions = legacy
                pending = [:]
            } else {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                sessions = try c.decode([YieldEstimationSession].self, forKey: .sessions)
                pending = try c.decodeIfPresent([UUID: SaveIntent].self, forKey: .pending) ?? [:]
            }
        }
    }

    private func sessionsState() throws -> SessionsState {
        let outcome: PersistenceStore.LoadOutcome<SessionsState> = persistence.loadOutcome(key: Self.sessionsKey)
        switch outcome {
        case .missing: return SessionsState()
        case .decoded(let state): return state
        case .failed(let error): throw error // never overwrite unreadable evidence
        }
    }

    func loadAllSessions() -> [YieldEstimationSession] {
        (try? sessionsState().sessions) ?? []
    }

    func pendingSessionIntents() -> [UUID: SaveIntent] { (try? sessionsState().pending) ?? [:] }
    func pendingSessionSaves() -> [UUID: Date] { pendingSessionIntents().mapValues(\.timestamp) }

    func saveLocalSession(_ session: YieldEstimationSession, at timestamp: Date) throws {
        guard !session.isCompleted || session.completedAt != nil else {
            throw CocoaError(.coderInvalidValue)
        }
        var state = try sessionsState()
        state.sessions.removeAll { $0.id == session.id }
        state.sessions.append(session)
        state.pending[session.id] = SaveIntent(token: UUID(), timestamp: timestamp)
        try persistence.saveOrThrow(state, key: Self.sessionsKey)
    }

    /// Only the exact version sent may be acknowledged. A completion authored
    /// during an older draft upload remains durable and eligible for replay.
    func acknowledgeSessionSaves(_ expected: [UUID: UUID]) throws {
        var state = try sessionsState()
        for (id, token) in expected where state.pending[id]?.token == token {
            state.pending.removeValue(forKey: id)
        }
        try persistence.saveOrThrow(state, key: Self.sessionsKey)
    }

    func loadSessions(for vineyardId: UUID) -> [YieldEstimationSession] {
        loadAllSessions().filter { $0.vineyardId == vineyardId }
    }

    func saveSessionsSlice(_ items: [YieldEstimationSession], for vineyardId: UUID) {
        guard var state = try? sessionsState() else { return }
        state.sessions.removeAll { $0.vineyardId == vineyardId }
        state.sessions.append(contentsOf: items)
        // A local explicit delete must not leave a save intent to resurrect it.
        let retained = Set(state.sessions.map(\.id))
        state.pending = state.pending.filter { retained.contains($0.key) }
        try? persistence.saveOrThrow(state, key: Self.sessionsKey)
    }

    func replaceSessions(_ remote: [YieldEstimationSession], for vineyardId: UUID) {
        guard var state = try? sessionsState() else { return }
        let pending = state.sessions.filter { state.pending[$0.id] != nil }
        let pendingIds = Set(pending.map(\.id))
        state.sessions.removeAll { $0.vineyardId == vineyardId && !pendingIds.contains($0.id) }
        state.sessions.append(contentsOf: remote.filter { !pendingIds.contains($0.id) })
        try? persistence.saveOrThrow(state, key: Self.sessionsKey)
    }

    func mergeSessions(_ remote: [YieldEstimationSession], for vineyardId: UUID) -> [YieldEstimationSession] {
        guard var state = try? sessionsState() else { return loadSessions(for: vineyardId) }
        for item in remote {
            if !state.sessions.contains(where: { $0.id == item.id }) {
                state.sessions.append(item)
            }
        }
        try? persistence.saveOrThrow(state, key: Self.sessionsKey)
        return state.sessions.filter { $0.vineyardId == vineyardId }
    }

    // MARK: - DamageRecord

    func loadAllDamage() -> [DamageRecord] {
        persistence.load(key: Self.damageKey) ?? []
    }

    func loadDamage(for vineyardId: UUID) -> [DamageRecord] {
        loadAllDamage().filter { $0.vineyardId == vineyardId }
    }

    func saveDamageSlice(_ items: [DamageRecord], for vineyardId: UUID) {
        var all = loadAllDamage()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.damageKey)
    }

    func replaceDamage(_ remote: [DamageRecord], for vineyardId: UUID) {
        var all = loadAllDamage()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.damageKey)
    }

    func mergeDamage(_ remote: [DamageRecord], for vineyardId: UUID) -> [DamageRecord] {
        var all = loadAllDamage()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.damageKey)
        return all.filter { $0.vineyardId == vineyardId }
    }

    // MARK: - HistoricalYieldRecord

    func loadAllHistorical() -> [HistoricalYieldRecord] {
        persistence.load(key: Self.historicalKey) ?? []
    }

    func loadHistorical(for vineyardId: UUID) -> [HistoricalYieldRecord] {
        loadAllHistorical().filter { $0.vineyardId == vineyardId }
    }

    func saveHistoricalSlice(_ items: [HistoricalYieldRecord], for vineyardId: UUID) {
        var all = loadAllHistorical()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.historicalKey)
    }

    func replaceHistorical(_ remote: [HistoricalYieldRecord], for vineyardId: UUID) {
        var all = loadAllHistorical()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.historicalKey)
    }

    func mergeHistorical(_ remote: [HistoricalYieldRecord], for vineyardId: UUID) -> [HistoricalYieldRecord] {
        var all = loadAllHistorical()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.historicalKey)
        return all.filter { $0.vineyardId == vineyardId }
    }

    // MARK: - PickingRecord (Detailed picking log)

    func loadAllPicking() -> [PickingRecord] {
        persistence.load(key: Self.pickingKey) ?? []
    }

    func loadPicking(for vineyardId: UUID) -> [PickingRecord] {
        loadAllPicking().filter { $0.vineyardId == vineyardId }
    }

    func savePickingSlice(_ items: [PickingRecord], for vineyardId: UUID) {
        var all = loadAllPicking()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.pickingKey)
    }

    func replacePicking(_ remote: [PickingRecord], for vineyardId: UUID) {
        var all = loadAllPicking()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.pickingKey)
    }

    // MARK: - PruningYieldSettings (shared per-block calculator config, sql/181)

    func loadAllPruningSettings() -> [PruningYieldSettings] {
        persistence.load(key: Self.pruningSettingsKey) ?? []
    }

    func loadPruningSettings(for vineyardId: UUID) -> [PruningYieldSettings] {
        loadAllPruningSettings().filter { $0.vineyardId == vineyardId }
    }

    func savePruningSettingsSlice(_ items: [PruningYieldSettings], for vineyardId: UUID) {
        var all = loadAllPruningSettings()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.pruningSettingsKey)
    }

    func replacePruningSettings(_ remote: [PruningYieldSettings], for vineyardId: UUID) {
        var all = loadAllPruningSettings()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.pruningSettingsKey)
    }

    // MARK: - YieldDeterminationResult (local only — sync-ready shape)

    func loadAllDetermination() -> [YieldDeterminationResult] {
        persistence.load(key: Self.determinationKey) ?? []
    }

    func loadDetermination(for vineyardId: UUID) -> [YieldDeterminationResult] {
        loadAllDetermination().filter { $0.vineyardId == vineyardId }
    }

    func saveDeterminationSlice(_ items: [YieldDeterminationResult], for vineyardId: UUID) {
        var all = loadAllDetermination()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.determinationKey)
    }
}
