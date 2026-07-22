import Foundation

/// Seeds sensible local default data per vineyard. Idempotent: only seeds when
/// the matching local collection is empty for the given vineyard. Never
/// overwrites user-created data. All seeding is local-only — no Supabase sync.
@MainActor
enum DefaultDataSeeder {

    /// Seed defaults for the currently selected vineyard. Safe to call repeatedly.
    static func seedIfNeeded(store: MigratedDataStore) {
        guard let vineyardId = store.selectedVineyardId else { return }
        seedGrapeVarieties(store: store, vineyardId: vineyardId)
        seedOperatorCategories(store: store, vineyardId: vineyardId)
        seedButtonTemplates(store: store, vineyardId: vineyardId)
    }

    // MARK: - Grape Varieties

    private static func seedGrapeVarieties(store: MigratedDataStore, vineyardId: UUID) {
        let existing = store.grapeVarieties.filter { $0.vineyardId == vineyardId }
        guard existing.isEmpty else { return }
        for variety in GrapeVariety.defaults(for: vineyardId) {
            store.addGrapeVariety(variety)
        }
    }

    // MARK: - Operator Categories

    private static func seedOperatorCategories(store: MigratedDataStore, vineyardId: UUID) {
        let existing = store.operatorCategories.filter { $0.vineyardId == vineyardId }
        guard existing.isEmpty else { return }
        let defaults: [(String, Double)] = [
            ("Vineyard Manager", 65),
            ("Tractor Operator", 45),
            ("General Hand", 32),
            ("Contractor", 55)
        ]
        for entry in defaults {
            store.addOperatorCategory(OperatorCategory(
                vineyardId: vineyardId,
                name: entry.0,
                costPerHour: entry.1
            ))
        }
    }

    // MARK: - Button Templates

    private static func seedButtonTemplates(store: MigratedDataStore, vineyardId: UUID) {
        let existing = store.buttonTemplates.filter { $0.vineyardId == vineyardId }
        guard existing.isEmpty else { return }
        store.addButtonTemplate(ButtonTemplate.defaultRepairTemplate(for: vineyardId))
        store.addButtonTemplate(ButtonTemplate.defaultGrowthTemplate(for: vineyardId))
    }
}
