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

    // Phase 2A (SQL 132) additive fields. All optional so snapshots written
    // by earlier builds keep decoding.
    /// Where the verified access came from: "supabase" | "revenuecat" |
    /// "legacy_trial".
    var accessSource: String?
    /// Backend plan code (e.g. "internal_unlimited") when Supabase granted.
    var planCode: String?
    /// Backend machine reason code (e.g. "portal_subscription").
    var reasonCode: String?
    /// Earliest known entitlement expiry — cached offline access must never
    /// extend past this instant regardless of the grace window.
    var knownExpiresAt: Date?
    /// Whether the shared-entitlement rollout flag covered this user at the
    /// last online verification (drives the cold-start path choice).
    var supabaseEnforced: Bool?
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

    /// Records a fresh verification result. Preserves previously known
    /// optional fields for the same user when new values aren't supplied.
    @discardableResult
    func recordVerification(
        userId: String?,
        entitled: Bool,
        productStatus: String?,
        vineyardAccessActive: Bool? = nil,
        accessSource: String? = nil,
        planCode: String? = nil,
        reasonCode: String? = nil,
        knownExpiresAt: Date? = nil,
        supabaseEnforced: Bool? = nil
    ) -> EntitlementVerificationSnapshot {
        let existing = load()
        let sameUser = existing?.userId == userId
        let snapshot = EntitlementVerificationSnapshot(
            userId: userId,
            lastVerifiedAt: Date(),
            wasEntitled: entitled,
            productStatus: productStatus,
            vineyardAccessActive: vineyardAccessActive ?? (sameUser ? existing?.vineyardAccessActive : nil),
            accessSource: accessSource ?? (sameUser ? existing?.accessSource : nil),
            planCode: planCode ?? (sameUser ? existing?.planCode : nil),
            reasonCode: reasonCode ?? (sameUser ? existing?.reasonCode : nil),
            knownExpiresAt: knownExpiresAt ?? (sameUser ? existing?.knownExpiresAt : nil),
            supabaseEnforced: supabaseEnforced ?? (sameUser ? existing?.supabaseEnforced : nil)
        )
        save(snapshot)
        return snapshot
    }
}
