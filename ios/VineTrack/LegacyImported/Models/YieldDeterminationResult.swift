import Foundation

/// Local-only saved result from the Yield Determination (pruning bud-load)
/// calculator. Persisted via PersistenceStore on-disk JSON so it can be
/// promoted to a synced Supabase table later without changing call sites.
nonisolated struct YieldDeterminationResult: Codable, Identifiable, Hashable {
    var id: UUID
    var vineyardId: UUID
    var paddockId: UUID?
    var createdAt: Date
    var season: String
    var year: Int

    var pruneMethod: String
    var bunchesPerBud: Double
    var budsPerSpur: Double
    var spursPerVine: Double
    var budsPerCane: Double
    var canesPerVine: Double
    var vinesPerHa: Double
    var bunchWeightGrams: Double

    // Calculated snapshots (kept so reports don't need to recompute):
    var budsPerVine: Double
    var bunchesPerHa: Double
    var yieldKgPerHa: Double
    var yieldTonnesPerHa: Double
    var totalYieldTonnes: Double?

    var createdBy: String?

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        paddockId: UUID?,
        createdAt: Date = Date(),
        season: String = "",
        year: Int = Calendar.current.component(.year, from: Date()),
        pruneMethod: String,
        bunchesPerBud: Double,
        budsPerSpur: Double,
        spursPerVine: Double,
        budsPerCane: Double,
        canesPerVine: Double,
        vinesPerHa: Double,
        bunchWeightGrams: Double,
        budsPerVine: Double,
        bunchesPerHa: Double,
        yieldKgPerHa: Double,
        yieldTonnesPerHa: Double,
        totalYieldTonnes: Double?,
        createdBy: String? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.paddockId = paddockId
        self.createdAt = createdAt
        self.season = season
        self.year = year
        self.pruneMethod = pruneMethod
        self.bunchesPerBud = bunchesPerBud
        self.budsPerSpur = budsPerSpur
        self.spursPerVine = spursPerVine
        self.budsPerCane = budsPerCane
        self.canesPerVine = canesPerVine
        self.vinesPerHa = vinesPerHa
        self.bunchWeightGrams = bunchWeightGrams
        self.budsPerVine = budsPerVine
        self.bunchesPerHa = bunchesPerHa
        self.yieldKgPerHa = yieldKgPerHa
        self.yieldTonnesPerHa = yieldTonnesPerHa
        self.totalYieldTonnes = totalYieldTonnes
        self.createdBy = createdBy
    }
}
