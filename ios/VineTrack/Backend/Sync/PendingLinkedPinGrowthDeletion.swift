import Foundation

/// Complete source identity retained before either linked representation is hidden.
nonisolated struct PendingLinkedPinGrowthDeletion: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let pinId: UUID?
    let growthRecordId: UUID?
    let queuedAt: Date
    let growthSnapshot: GrowthStageRecord?
    let pinSnapshot: VinePin?
    var isConfirmed: Bool = false
}

@MainActor
final class LinkedPinGrowthDeletionStore {
    static let shared = LinkedPinGrowthDeletionStore()

    private let persistence: PersistenceStore
    private let key = "vinetrack_linked_pin_growth_deletions_v1"
    private(set) var targets: [UUID: PendingLinkedPinGrowthDeletion]

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.targets = persistence.load(key: key) ?? [:]
    }

    var pinIds: Set<UUID> { Set(targets.values.compactMap(\.pinId)) }
    var growthRecordIds: Set<UUID> { Set(targets.values.compactMap(\.growthRecordId)) }

    func enqueue(_ target: PendingLinkedPinGrowthDeletion) throws {
        var next = targets
        next[target.id] = target
        try persistence.saveOrThrow(next, key: key)
        targets = next
    }

    func markConfirmed(_ id: UUID) throws {
        guard var target = targets[id] else { return }
        target.isConfirmed = true
        var next = targets
        next[id] = target
        try persistence.saveOrThrow(next, key: key)
        targets = next
    }

    func remove(_ id: UUID) throws {
        var next = targets
        next.removeValue(forKey: id)
        try persistence.saveOrThrow(next, key: key)
        targets = next
    }
}
