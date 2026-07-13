import Foundation
import Observation

/// Local-first store for the Pruning Tracker (in development — System Admin only).
/// Persists to UserDefaults as JSON; the model shapes mirror the planned
/// `pruning_block_setups` / `pruning_entries` sync tables so cloud sync can be
/// added later without a data migration.
@Observable
final class PruningStore {
    private(set) var setups: [PruningBlockSetup] = []
    private(set) var entries: [PruningEntry] = []

    private static let setupsKey = "vinetrack_pruning_setups"
    private static let entriesKey = "vinetrack_pruning_entries"

    init() {
        load()
    }

    // MARK: Setups

    func setup(for paddockId: UUID) -> PruningBlockSetup? {
        setups.first { $0.paddockId == paddockId }
    }

    func upsertSetup(_ setup: PruningBlockSetup) {
        if let index = setups.firstIndex(where: { $0.paddockId == setup.paddockId }) {
            setups[index] = setup
        } else {
            setups.append(setup)
        }
        persistSetups()
    }

    // MARK: Entries

    func entries(for paddockId: UUID) -> [PruningEntry] {
        entries
            .filter { $0.paddockId == paddockId }
            .sorted { $0.date > $1.date }
    }

    func entries(forVineyard vineyardId: UUID) -> [PruningEntry] {
        entries.filter { $0.vineyardId == vineyardId }
    }

    func addEntry(_ entry: PruningEntry) {
        entries.append(entry)
        persistEntries()
    }

    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        persistEntries()
    }

    // MARK: Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.setupsKey),
           let decoded = try? JSONDecoder().decode([PruningBlockSetup].self, from: data) {
            setups = decoded
        }
        if let data = defaults.data(forKey: Self.entriesKey),
           let decoded = try? JSONDecoder().decode([PruningEntry].self, from: data) {
            entries = decoded
        }
    }

    private func persistSetups() {
        if let data = try? JSONEncoder().encode(setups) {
            UserDefaults.standard.set(data, forKey: Self.setupsKey)
        }
    }

    private func persistEntries() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.entriesKey)
        }
    }
}
