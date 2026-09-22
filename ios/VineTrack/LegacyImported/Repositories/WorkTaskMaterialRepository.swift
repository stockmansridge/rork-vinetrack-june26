import Foundation

/// Offline-first local persistence for Work Task Material Costs (sql/247).
///
/// Three sibling stores, all following the existing
/// `WorkTaskLabourLineRepository` / `WorkTaskMachineLineRepository` pattern —
/// `PersistenceStore` JSON slices on disk, the data store holds the in-memory
/// collection and delegates here.
///
/// Durability requirement: a material line created offline must survive app
/// termination, relaunch and network loss, and then sync exactly once. Every
/// mutation writes the full slice through `PersistenceStore.save`, which is an
/// atomic file write, so a kill mid-save can never leave a half-written slice.

// MARK: - Base catalogue (global, not vineyard scoped)

/// Local cache of the global base catalogue.
///
/// The catalogue is NOT vineyard scoped — it is the same 18 items for every
/// vineyard — so it is stored as one slice. When nothing has ever synced, the
/// bundled ``MaterialCatalogueSeed`` is returned so an offline fresh install
/// still has a usable picker with the SAME keys the server uses.
@MainActor
final class MaterialCatalogueRepository {

    static let storageKey = "vinetrack_material_catalogue"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    /// The cached server catalogue, or nil when nothing has ever synced.
    func loadCached() -> [MaterialCatalogueItem]? {
        persistence.load(key: Self.storageKey)
    }

    /// The catalogue to actually use: cached server copy when present,
    /// otherwise the bundled offline fallback.
    func loadEffective() -> [MaterialCatalogueItem] {
        MaterialCatalogueSeed.resolve(server: nil, cached: loadCached())
    }

    /// Replace the cache with an authoritative server read. An EMPTY server
    /// read is ignored rather than cached: it would blank every picker, and in
    /// practice only happens when the migration has not been applied yet.
    func replace(_ items: [MaterialCatalogueItem]) {
        guard !items.isEmpty else { return }
        persistence.save(items, key: Self.storageKey)
    }
}

// MARK: - Vineyard material library

@MainActor
final class VineyardMaterialRepository {

    static let storageKey = "vinetrack_vineyard_materials"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    func loadAll() -> [VineyardMaterial] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [VineyardMaterial] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    func saveSlice(_ items: [VineyardMaterial], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    func replace(_ remote: [VineyardMaterial], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    func merge(_ remote: [VineyardMaterial], for vineyardId: UUID) -> [VineyardMaterial] {
        var all = loadAll()
        for item in remote {
            if let idx = all.firstIndex(where: { $0.id == item.id }) {
                all[idx] = item
            } else {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.storageKey)
        return all.filter { $0.vineyardId == vineyardId }
    }
}

// MARK: - Work Task material lines

@MainActor
final class WorkTaskMaterialRepository {

    static let storageKey = "vinetrack_work_task_materials"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    func loadAll() -> [WorkTaskMaterial] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [WorkTaskMaterial] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    /// The material lines of ONE task, in stable display order.
    func load(forWorkTask workTaskId: UUID) -> [WorkTaskMaterial] {
        WorkTaskMaterialCosting.lines(loadAll(), for: workTaskId)
    }

    func saveSlice(_ items: [WorkTaskMaterial], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    func replace(_ remote: [WorkTaskMaterial], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    /// Merge a remote slice by id.
    ///
    /// Idempotent by construction: a line created offline already carries its
    /// FINAL id (minted before any network call), so replaying its upload and
    /// then pulling it back updates the same row rather than creating a second
    /// one.
    func merge(_ remote: [WorkTaskMaterial], for vineyardId: UUID) -> [WorkTaskMaterial] {
        var all = loadAll()
        for item in remote {
            if let idx = all.firstIndex(where: { $0.id == item.id }) {
                all[idx] = item
            } else {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.storageKey)
        return all.filter { $0.vineyardId == vineyardId }
    }
}
