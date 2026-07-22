import Foundation

/// Owns persistence and merge/replace logic for AppSettings (per-vineyard).
@MainActor
final class SettingsRepository {

    static let storageKey = "vinetrack_settings_v2"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - Load

    func loadAll() -> [AppSettings] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> AppSettings {
        loadAll().first { $0.vineyardId == vineyardId } ?? AppSettings(vineyardId: vineyardId)
    }

    // MARK: - Save

    /// Upsert a single settings record keyed by vineyardId.
    func upsert(_ settings: AppSettings) {
        var all = loadAll()
        if let index = all.firstIndex(where: { $0.vineyardId == settings.vineyardId }) {
            all[index] = settings
        } else {
            all.append(settings)
        }
        persistence.save(all, key: Self.storageKey)
    }

    /// Remove the settings row for a vineyard (used on vineyard deletion).
    func removeSettings(for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        persistence.save(all, key: Self.storageKey)
    }

    // MARK: - Sync

    /// Merge remote settings keyed by vineyardId (remote wins on conflict).
    /// Returns the settings slice for `vineyardId` after merge, if any.
    @discardableResult
    func merge(_ remote: [AppSettings], for vineyardId: UUID) -> AppSettings? {
        var all = loadAll()
        for item in remote {
            if let index = all.firstIndex(where: { $0.vineyardId == item.vineyardId }) {
                all[index] = item
            } else {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.storageKey)
        return all.first { $0.vineyardId == vineyardId }
    }
}
