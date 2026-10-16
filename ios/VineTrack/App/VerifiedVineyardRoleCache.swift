import Foundation

/// Last server-verified membership, usable only within the retained authenticated session.
@MainActor
final class VerifiedVineyardRoleCache {
    nonisolated struct Entry: Codable, Sendable {
        let userId: UUID
        let vineyardId: UUID
        let sessionId: UUID
        let role: BackendRole?
        let workerTypeId: UUID?
    }

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore? = nil) { self.persistence = persistence ?? .shared }

    func load(userId: UUID, vineyardId: UUID, sessionId: UUID) -> Entry? {
        let entry: Entry? = persistence.load(key: key(userId, vineyardId))
        guard entry?.userId == userId, entry?.vineyardId == vineyardId,
              entry?.sessionId == sessionId else { return nil }
        return entry
    }

    func save(_ entry: Entry) throws {
        do {
            try persistence.saveOrThrow(entry, key: key(entry.userId, entry.vineyardId))
        } catch {
            // Never resurrect an older, more privileged role after a confirmed change.
            try persistence.removeOrThrow(key: key(entry.userId, entry.vineyardId))
            throw error
        }
    }

    private func key(_ user: UUID, _ vineyard: UUID) -> String {
        "verified_vineyard_role_v1_\(user.uuidString)_\(vineyard.uuidString)"
    }
}
