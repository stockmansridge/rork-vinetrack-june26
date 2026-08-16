import Foundation
import Observation

/// Local storage for Resistance Plans.
///
/// WHY LOCAL FOR v1 (audited before writing any SQL):
///
/// VineTrack's synced domain objects each have a dedicated Supabase table plus a
/// repository, RLS policies and sync plumbing (`SupabaseSprayRecordSyncRepository`,
/// `SupabasePaddockSyncRepository`, and so on). There is NO generic per-vineyard JSON
/// document table to borrow, and the nearest planning-shaped stores — the Operational
/// Tools layout, button templates, fertiliser defaults, GDD settings — are either
/// user-preference tables with fixed columns or local-only stores. None of them can
/// host a plan without a migration.
///
/// So a plan cannot be synced today without new SQL, and this task explicitly must not
/// apply a production migration. The tradeoff of staying local, stated plainly: a plan
/// does not follow the grower to another device, is not visible to a colleague, and is
/// lost if the app is reinstalled. That is a real limitation for a tool whose whole
/// purpose is season-long planning, which is why the proposed schema is included in the
/// report for approval rather than deferred.
///
/// The model is already shaped for that move — `Codable`, vineyard-scoped, stable
/// position ids, stamped ruleset version — so adopting the table is a repository swap
/// behind this same interface, not a redesign.
@Observable
final class ResistancePlanStore {

    /// Plans for the currently loaded vineyard, newest first.
    private(set) var plans: [ResistancePlan] = []
    private(set) var isLoaded: Bool = false

    /// Shown wherever plans are listed, so the local-only limitation is never a
    /// surprise discovered by losing work.
    static let localOnlyNotice =
        "Resistance plans are saved on this device only. They do not yet sync between devices or to other users."

    private let defaults: UserDefaults
    private var vineyardId: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func storageKey(_ vineyardId: String) -> String {
        "resistance_plans_v1_\(vineyardId)"
    }

    func load(vineyardId: String) {
        self.vineyardId = vineyardId
        isLoaded = true
        guard let data = defaults.data(forKey: storageKey(vineyardId)) else {
            plans = []
            return
        }
        do {
            plans = try JSONDecoder().decode([ResistancePlan].self, from: data).sorted {
                $0.updatedAtEpochMs > $1.updatedAtEpochMs
            }
        } catch {
            // A decode failure must not wipe the grower's plans. Leave the stored blob
            // untouched so a later app version with a migration can still read it.
            plans = []
            print("[ResistancePlanStore] Could not read stored plans: \(error.localizedDescription)")
        }
    }

    /// Plans for a season and disease, newest first.
    func plans(seasonId: String, disease: ResistanceDisease) -> [ResistancePlan] {
        plans.filter { $0.seasonId == seasonId && $0.disease == disease }
    }

    func save(_ plan: ResistancePlan) {
        guard let vineyardId else { return }
        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[index] = plan
        } else {
            plans.append(plan)
        }
        plans.sort { $0.updatedAtEpochMs > $1.updatedAtEpochMs }
        persist(vineyardId: vineyardId)
    }

    func delete(id planId: String) {
        guard let vineyardId else { return }
        plans.removeAll { $0.id == planId }
        persist(vineyardId: vineyardId)
    }

    private func persist(vineyardId: String) {
        do {
            let data = try JSONEncoder().encode(plans)
            defaults.set(data, forKey: storageKey(vineyardId))
        } catch {
            print("[ResistancePlanStore] Could not save plans: \(error.localizedDescription)")
        }
    }
}
