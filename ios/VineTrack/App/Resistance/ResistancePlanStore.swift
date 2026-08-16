import Foundation

/// Local cache contract for Resistance Plans.
///
/// A protocol rather than a concrete `UserDefaults` class so the repository — where every
/// conflict, adoption and merge decision actually lives — is testable with no storage and
/// no network. Those decisions are the ones that can silently lose a grower's season plan,
/// so they must be the ones under test.
///
/// Mirrors `ResistancePlanLocalStore` on Android.
protocol ResistancePlanLocalStore: AnyObject, Sendable {
    /// Every cached plan for a vineyard, INCLUDING soft-deleted tombstones.
    func loadAll(vineyardId: String) -> [ResistancePlan]
    func saveAll(vineyardId: String, plans: [ResistancePlan])
    /// Ids of plans with local changes not yet accepted by the server (the outbox).
    func loadPending(vineyardId: String) -> Set<String>
    func savePending(vineyardId: String, ids: Set<String>)
    /// Whether the one-time adoption of Planner v1 local-only plans has completed.
    func isAdopted(vineyardId: String) -> Bool
    func markAdopted(vineyardId: String)
}

/// `UserDefaults`-backed local cache and outbox for Resistance Plans.
///
/// This is the OFFLINE CACHE, not the source of truth — the server
/// (`public.resistance_plans`, sql/196) is. It keeps three things per vineyard:
///
///   1. every plan, INCLUDING soft-deleted tombstones, so a delete can propagate;
///   2. the set of plan ids with unpushed local changes (the outbox);
///   3. a one-time flag recording that Planner v1's local-only plans were adopted.
///
/// The plans key is UNCHANGED from Planner v1 (`resistance_plans_v1_<vineyardId>`) on
/// purpose: that is what lets an existing user's plans be FOUND and adopted rather than
/// orphaned under a key nothing reads any more.
///
/// Mirrors `ResistancePlanStore.kt` on Android.
final class ResistancePlanStore: ResistancePlanLocalStore, @unchecked Sendable {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func plansKey(_ vineyardId: String) -> String { "resistance_plans_v1_\(vineyardId)" }
    private func pendingKey(_ vineyardId: String) -> String { "resistance_plans_pending_v1_\(vineyardId)" }
    private func adoptedKey(_ vineyardId: String) -> String { "resistance_plans_adopted_v1_\(vineyardId)" }

    func loadAll(vineyardId: String) -> [ResistancePlan] {
        guard let data = defaults.data(forKey: plansKey(vineyardId)) else { return [] }
        do {
            return try JSONDecoder().decode([ResistancePlan].self, from: data)
        } catch {
            // A decode failure must not wipe the grower's plans. The stored blob is left
            // untouched so a later app version can still read it, and the server copy is
            // unaffected either way.
            print("[ResistancePlanStore] Could not read cached plans: \(error.localizedDescription)")
            return []
        }
    }

    func saveAll(vineyardId: String, plans: [ResistancePlan]) {
        do {
            let data = try JSONEncoder().encode(plans)
            defaults.set(data, forKey: plansKey(vineyardId))
        } catch {
            print("[ResistancePlanStore] Could not cache plans: \(error.localizedDescription)")
        }
    }

    func loadPending(vineyardId: String) -> Set<String> {
        Set(defaults.stringArray(forKey: pendingKey(vineyardId)) ?? [])
    }

    func savePending(vineyardId: String, ids: Set<String>) {
        defaults.set(Array(ids), forKey: pendingKey(vineyardId))
    }

    func isAdopted(vineyardId: String) -> Bool {
        defaults.bool(forKey: adoptedKey(vineyardId))
    }

    func markAdopted(vineyardId: String) {
        defaults.set(true, forKey: adoptedKey(vineyardId))
    }
}

/// In-memory local store for tests and previews.
///
/// Lives in production source rather than a test target so the Android mirror and any
/// future preview mode use exactly the same cache semantics the repository is tested
/// against — a test-only fake that drifts from the real store proves nothing.
final class InMemoryResistancePlanLocalStore: ResistancePlanLocalStore, @unchecked Sendable {
    private var plans: [String: [ResistancePlan]] = [:]
    private var pending: [String: Set<String>] = [:]
    private var adopted: Set<String> = []

    func loadAll(vineyardId: String) -> [ResistancePlan] { plans[vineyardId] ?? [] }

    func saveAll(vineyardId: String, plans: [ResistancePlan]) { self.plans[vineyardId] = plans }

    func loadPending(vineyardId: String) -> Set<String> { pending[vineyardId] ?? [] }

    func savePending(vineyardId: String, ids: Set<String>) { pending[vineyardId] = ids }

    func isAdopted(vineyardId: String) -> Bool { adopted.contains(vineyardId) }

    func markAdopted(vineyardId: String) { adopted.insert(vineyardId) }
}
