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

    // Phase 2F (SQL 156) additive field — optional so older snapshots decode.
    /// Vineyard UUIDs confirmed accessible at the last online verification.
    /// Keyed per user via `userId`; a denial for ONE vineyard never erases
    /// the cached access of another — the whole list is replaced only by a
    /// fresh server matrix.
    var accessibleVineyardIds: [String]?
    /// Verified effective-vineyard capabilities, including denials. Independent
    /// of account offline grace; never interpreted as an app-entry grant here.
    var operationalAccessByVineyard: [String: VineyardOperationalAccess]?

    func operationalAccess(for vineyardId: UUID, userId: UUID) -> VineyardOperationalAccess? {
        // Unlike legacy account grace, these scoped capabilities require an
        // exact authenticated owner. Never inherit an unscoped legacy snapshot.
        guard self.userId.flatMap(UUID.init(uuidString:)) == userId else { return nil }
        return operationalAccessByVineyard?[vineyardId.uuidString]
    }
}

/// Local persistence for the entitlement grace window. Single-snapshot,
/// keyed by user id so a different account never inherits a stale grace.
@MainActor
final class EntitlementVerificationStore {
    static let shared = EntitlementVerificationStore()

    enum AccessDetailsUpdate {
        /// An individual provider has refreshed only part of the access state.
        case mergeProvided
        /// The combined gate resolved a definitive online result. Nil fields
        /// clear the previous source, plan and expiry for the same account.
        case replace
    }

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

    /// A matrix is verified independently of account billing. Preserve the
    /// existing account grace timestamp/result; do not renew a writable lease.
    func recordOperationalAccess(userId: UUID, capabilities: [String: VineyardOperationalAccess]) {
        let existing = load()
        var snapshot: EntitlementVerificationSnapshot
        if let existing, existing.userId.flatMap(UUID.init(uuidString:)) == userId {
            snapshot = existing
        } else {
            snapshot = EntitlementVerificationSnapshot(
                userId: userId.uuidString, lastVerifiedAt: Date(), wasEntitled: false
            )
        }
        snapshot.operationalAccessByVineyard = capabilities
        save(snapshot)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    /// Records a fresh verification result. Provider-only updates merge their
    /// supplied fields; definitive combined results replace all access details.
    /// Vineyard IDs remain independent: only a successfully fetched matrix may
    /// replace that list, including replacing it with an empty list.
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
        supabaseEnforced: Bool? = nil,
        accessibleVineyardIds: [String]? = nil,
        operationalAccessByVineyard: [String: VineyardOperationalAccess]? = nil,
        accessDetailsUpdate: AccessDetailsUpdate = .mergeProvided
    ) -> EntitlementVerificationSnapshot {
        let existing = load()
        let sameUser = existing?.userId == userId
        let retainAccessDetails = sameUser && accessDetailsUpdate == .mergeProvided
        let snapshot = EntitlementVerificationSnapshot(
            userId: userId,
            lastVerifiedAt: Date(),
            wasEntitled: entitled,
            productStatus: productStatus,
            vineyardAccessActive: vineyardAccessActive ?? (retainAccessDetails ? existing?.vineyardAccessActive : nil),
            accessSource: accessSource ?? (retainAccessDetails ? existing?.accessSource : nil),
            planCode: planCode ?? (retainAccessDetails ? existing?.planCode : nil),
            reasonCode: reasonCode ?? (retainAccessDetails ? existing?.reasonCode : nil),
            knownExpiresAt: knownExpiresAt ?? (retainAccessDetails ? existing?.knownExpiresAt : nil),
            supabaseEnforced: supabaseEnforced ?? (retainAccessDetails ? existing?.supabaseEnforced : nil),
            accessibleVineyardIds: accessibleVineyardIds ?? (sameUser ? existing?.accessibleVineyardIds : nil),
            operationalAccessByVineyard: operationalAccessByVineyard ?? (sameUser && userId != nil ? existing?.operationalAccessByVineyard : nil)
        )
        save(snapshot)
        return snapshot
    }
}
