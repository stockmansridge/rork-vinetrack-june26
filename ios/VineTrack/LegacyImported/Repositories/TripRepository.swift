import Foundation

/// Owns persistence and merge/replace logic for Trip.
@MainActor
final class TripRepository {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}

    static let storageKey = "vinetrack_trips"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    /// Runs before every disk read so a batched live-Trip write is on disk
    /// before anything reads, merges or rewrites the Trip file.
    var beforeRead: (() -> Void)?

    // MARK: - Load

    func loadAll() -> [Trip] {
        beforeRead?()
        var all: [Trip] = persistence.load(key: Self.storageKey) ?? []
        if let live: Trip = persistence.load(key: Self.liveStorageKey) {
            if let index = all.firstIndex(where: { $0.id == live.id && $0.vineyardId == live.vineyardId }) {
                all[index] = live
            } else {
                // Never resurrects or invents a Trip the history no longer has.
                persistence.remove(key: Self.liveStorageKey)
            }
        }
        return all
    }

    // MARK: - Live Trip file

    /// The Trip this device is recording, written on its own so a GPS save
    /// costs the same however much Trip history the device holds. Every read
    /// of the history overlays it onto the Trip with the same ID; every
    /// history write (which always starts from that overlaid or newer
    /// in-memory data) folds it back in and removes this file.
    static let liveStorageKey = "vinetrack_live_trip_v1"

    func saveLive(_ trip: Trip) {
        persistence.save(trip, key: Self.liveStorageKey)
    }

    private func foldLiveIntoHistory() {
        persistence.remove(key: Self.liveStorageKey)
    }

    func load(for vineyardId: UUID) -> [Trip] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    // MARK: - Save

    func saveSlice(_ items: [Trip], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        // Fold the live file in only once the history write succeeded.
        if (try? persistence.saveOrThrow(all, key: Self.storageKey)) != nil { foldLiveIntoHistory() }
    }

    func saveSliceOrThrow(_ items: [Trip], for vineyardId: UUID) throws {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        try persistence.saveOrThrow(all, key: Self.storageKey)
        foldLiveIntoHistory()
    }

    // MARK: - Sync

    func replace(_ remote: [Trip], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        // Fold the live file in only once the history write succeeded.
        if (try? persistence.saveOrThrow(all, key: Self.storageKey)) != nil { foldLiveIntoHistory() }
    }

    /// Add-if-not-exists merge for trips.
    /// Returns the slice for `vineyardId` after the merge.
    func merge(_ remote: [Trip], for vineyardId: UUID) -> [Trip] {
        var all = loadAll()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        // Fold the live file in only once the history write succeeded.
        if (try? persistence.saveOrThrow(all, key: Self.storageKey)) != nil { foldLiveIntoHistory() }
        return all.filter { $0.vineyardId == vineyardId }
    }
}
