import Foundation

/// Owns persistence and merge/replace logic for the yield domain:
/// YieldEstimationSession, DamageRecord, HistoricalYieldRecord.
@MainActor
final class YieldRepository {

    static let sessionsKey = "vinetrack_yield_sessions"
    static let damageKey = "vinetrack_damage_records"
    static let historicalKey = "vinetrack_historical_yield_records"
    static let determinationKey = "vinetrack_yield_determination_results"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - YieldEstimationSession

    func loadAllSessions() -> [YieldEstimationSession] {
        persistence.load(key: Self.sessionsKey) ?? []
    }

    func loadSessions(for vineyardId: UUID) -> [YieldEstimationSession] {
        loadAllSessions().filter { $0.vineyardId == vineyardId }
    }

    func saveSessionsSlice(_ items: [YieldEstimationSession], for vineyardId: UUID) {
        var all = loadAllSessions()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.sessionsKey)
    }

    func replaceSessions(_ remote: [YieldEstimationSession], for vineyardId: UUID) {
        var all = loadAllSessions()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.sessionsKey)
    }

    func mergeSessions(_ remote: [YieldEstimationSession], for vineyardId: UUID) -> [YieldEstimationSession] {
        var all = loadAllSessions()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.sessionsKey)
        return all.filter { $0.vineyardId == vineyardId }
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
