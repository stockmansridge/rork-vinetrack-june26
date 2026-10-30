// Host-only dependency boundaries. Cache, row resolver and estimate calculations
// are the unchanged production files. Native tests use the real model/SDK instead.
import Foundation
import Supabase
@MainActor final class SupabaseClientProvider {
    static let shared = SupabaseClientProvider()
    let isConfigured = false
    let client = SupabaseClient()
}
@MainActor final class VineyardWriteAuthority {
    static let shared = VineyardWriteAuthority()
    var accountBinding: String? = nil
    var accountGeneration: UInt64 = 0
}
@MainActor struct YieldBunchWeightsRepository {
    init(provider: SupabaseClientProvider, defaults: UserDefaults) {}
    func fetch(vineyard: UUID) async throws -> [YieldBunchWeightRow] {
        throw URLError(.notConnectedToInternet) // Tests inject the read boundary explicitly.
    }
}
nonisolated struct PaddockVarietyAllocation: Sendable {
    let varietyId: UUID
    let percent: Double
    let name: String?
    let varietyKey: String?
}
nonisolated struct Paddock: Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let varietyAllocations: [PaddockVarietyAllocation]
    var authoritativeVineCount: Int = 1000
    var areaHectares: Double = 1
}
nonisolated struct YieldEstimationSession: Sendable {
    struct Entry: Sendable { let bunchesPerVine: Double }
    struct Site: Sendable { let paddockId: UUID; let bunchCountEntry: Entry? }
    let sampleSites: [Site]
    let blockBunchWeightsKg: [UUID: Double]
    let applyDamage: Bool
    let selectedPaddockIds: [UUID]
}
