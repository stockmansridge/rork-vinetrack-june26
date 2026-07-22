import Foundation

/// Snapshot of the last *successful online* entitlement/access verification.
///
/// Persisted locally so a paying user in a no-service vineyard can keep
/// working during the offline grace window even when neither RevenueCat nor
/// Supabase can be reached. Never contains raw billing payloads — only the
/// coarse status needed to evaluate the grace window.
nonisolated struct EntitlementVerificationSnapshot: Codable, Equatable {
    /// Supabase auth user the verification belongs to.
    var userId: String?
    /// When the last successful online verification completed.
    var lastVerifiedAt: Date
    /// Whether that verification granted entitlement/access.
    var wasEntitled: Bool
    /// Short, non-sensitive product/entitlement status (e.g. "active:...").
    var productStatus: String?
    /// Last known backend (Supabase) vineyard access flag, when resolved.
    var vineyardAccessActive: Bool?
}

/// Local persistence for the entitlement grace window. Single-snapshot,
/// keyed by user id so a different account never inherits a stale grace.
@MainActor
final class EntitlementVerificationStore {
    static let shared = EntitlementVerificationStore()

    private let defaults: UserDefaults
    private let key = "vinetrack.entitlementVerification.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> EntitlementVerificationSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(EntitlementVerificationSnapshot.self, from: data)
    }

    /// Returns the persisted snapshot only when it belongs to `userId`.
    func load(for userId: UUID?) -> EntitlementVerificationSnapshot? {
        guard let snapshot = load() else { return nil }
        guard let userId else {
            return snapshot.userId == nil ? snapshot : nil
        }
        return (snapshot.userId == nil || snapshot.userId == userId.uuidString) ? snapshot : nil
    }

    func save(_ snapshot: EntitlementVerificationSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    /// Records a fresh verification result. Preserves a previously known
    /// vineyard access flag for the same user when a new one isn't supplied.
    @discardableResult
    func recordVerification(
        userId: String?,
        entitled: Bool,
        productStatus: String?,
        vineyardAccessActive: Bool? = nil
    ) -> EntitlementVerificationSnapshot {
        let existing = load()
        let sameUser = existing?.userId == userId
        let snapshot = EntitlementVerificationSnapshot(
            userId: userId,
            lastVerifiedAt: Date(),
            wasEntitled: entitled,
            productStatus: productStatus,
            vineyardAccessActive: vineyardAccessActive ?? (sameUser ? existing?.vineyardAccessActive : nil)
        )
        save(snapshot)
        return snapshot
    }
}
