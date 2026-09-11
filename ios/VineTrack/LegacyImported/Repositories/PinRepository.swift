import Foundation

/// Owns persistence and merge/replace logic for VinePin.
@MainActor
final class PinRepository {

    static let storageKey = "vinetrack_pins"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - Load

    enum CacheReadError: Error {
        case unreadable(Error)
        case pinNotFound
    }

    func loadAll() -> [VinePin] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func loadAllForDurableUpdate() throws -> [VinePin] {
        let outcome: PersistenceStore.LoadOutcome<[VinePin]> = persistence.loadOutcome(key: Self.storageKey)
        switch outcome {
        case .missing:
            return []
        case .decoded(let pins):
            return pins
        case .failed(let error):
            throw CacheReadError.unreadable(error)
        }
    }

    func load(for vineyardId: UUID) -> [VinePin] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    // MARK: - Save

    func saveSlice(_ items: [VinePin], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    /// Updates only notes on the originally-bound pin and vineyard, preserving
    /// every newer field from the durable cache and reporting write failures.
    func updateNotesDurably(pinId: UUID, vineyardId: UUID, notes: String?) throws -> VinePin {
        var all = try loadAllForDurableUpdate()
        guard let index = all.firstIndex(where: { $0.id == pinId && $0.vineyardId == vineyardId }) else {
            throw CacheReadError.pinNotFound
        }
        all[index].notes = notes
        try persistence.saveOrThrow(all, key: Self.storageKey)
        return all[index]
    }

    // MARK: - Sync

    func replace(_ remote: [VinePin], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    /// Replaces one vineyard slice with one checked cache read and one durable write.
    /// An unreadable shared cache is never interpreted as an empty cache.
    func replaceDurably(_ slice: [VinePin], for vineyardId: UUID) throws {
        var all = try loadAllForDurableUpdate()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: slice)
        try persistence.saveOrThrow(all, key: Self.storageKey)
    }

    /// Applies a complete remote batch with exactly one shared-cache read and
    /// one durable write, retaining every other vineyard unchanged.
    func applyRemoteBatchDurably(
        vineyardId: UUID,
        selectedSlice: [VinePin]?,
        cacheSnapshot: [VinePin],
        upserts: [VinePin],
        deleting ids: Set<UUID>
    ) throws -> [VinePin] {
        var all = cacheSnapshot
        var slice = selectedSlice ?? all.filter { $0.vineyardId == vineyardId }
        if !ids.isEmpty { slice.removeAll { ids.contains($0.id) } }
        var indexById = Dictionary(uniqueKeysWithValues: slice.indices.map { (slice[$0].id, $0) })
        for pin in upserts where pin.vineyardId == vineyardId {
            if let index = indexById[pin.id] {
                slice[index] = pin
            } else {
                indexById[pin.id] = slice.count
                slice.append(pin)
            }
        }
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: slice)
        try persistence.saveOrThrow(all, key: Self.storageKey)
        return slice
    }

    /// Add-if-not-exists merge (does not overwrite existing items).
    /// Returns the slice for `vineyardId` after the merge.
    func merge(_ remote: [VinePin], for vineyardId: UUID) -> [VinePin] {
        var all = loadAll()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.storageKey)
        return all.filter { $0.vineyardId == vineyardId }
    }
}
