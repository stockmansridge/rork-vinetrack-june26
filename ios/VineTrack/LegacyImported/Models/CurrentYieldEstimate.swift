import Foundation

/// A current master result, never decoded from a trip payload or local weight preference.
nonisolated struct YieldMasterWeight: Codable, Sendable, Equatable {
    let bunchWeightGrams: Double?
    let source: String
    let recordId: UUID?
    let varietyKey: String?
    enum CodingKeys: String, CodingKey {
        case bunchWeightGrams = "bunch_weight_grams", source
        case recordId = "record_id", varietyKey = "variety_key"
    }
    var kg: Double? {
        guard ["block_override", "variety_default"].contains(source), recordId != nil,
              let grams = bunchWeightGrams, grams.isFinite, grams > 0 else { return nil }
        return grams / 1000
    }
    var sourceLabel: String {
        switch source {
        case "block_override": "Block override"
        case "variety_default": "Vineyard variety master"
        default: "Not configured"
        }
    }
}

nonisolated enum CurrentYieldEstimate {
    struct Planting: Sendable {
        let key: String
        let name: String
        let share: Double
    }
    struct Block: Identifiable, Sendable {
        var id: UUID { paddockId }
        let paddockId: UUID
        let name: String
        let varieties: String
        let samplesRecorded: Int
        let samplesTotal: Int
        let averageBunches: Double?
        let vines: Int
        let sampledAreaHa: Double
        let weightKg: Double?
        let weightSources: [String]
        let historicalWeightKg: Double?
        let baseTonnes: Double?
        let adjustedTonnes: Double?
        let displayTonnes: Double?
        var tonnesPerHa: Double? {
            guard sampledAreaHa > 0 else { return nil }
            return displayTonnes.map { $0 / sampledAreaHa }
        }
    }
    struct Trip: Sendable {
        let blocks: [Block]
        let sampledAreaHa: Double
        let totalTonnes: Double?
        var tonnesPerHa: Double? {
            guard sampledAreaHa > 0 else { return nil }
            return totalTonnes.map { $0 / sampledAreaHa }
        }
    }
    static func key(blockId: UUID, varietyKey: String) -> String {
        blockId.uuidString.lowercased() + "|" + varietyKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    static func plantings(_ paddock: Paddock) -> [Planting] {
        paddock.varietyAllocations.filter { $0.percent > 0 && $0.percent.isFinite }.map {
            // Name-derived compatibility is permitted ONLY when no canonical key was stored.
            let stored = $0.varietyKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = $0.name ?? "Unknown variety"
            let legacy = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "_")
            return Planting(key: stored.flatMap { $0.isEmpty ? nil : $0 }?.lowercased() ?? legacy,
                            name: name, share: $0.percent)
        }
    }
    static func block(session: YieldEstimationSession, paddock: Paddock,
                      weights: [String: YieldMasterWeight], remaining: Double = 1) -> Block {
        let sites = session.sampleSites.filter { $0.paddockId == paddock.id }
        let counts = sites.compactMap(\.bunchCountEntry).map(\.bunchesPerVine)
        let average: Double? = counts.isEmpty || counts.contains(where: { !$0.isFinite || $0 < 0 })
            ? nil : counts.reduce(0, +) / Double(counts.count)
        let plantings = plantings(paddock)
        let share = plantings.reduce(0) { $0 + $1.share }
        let resolved = plantings.map { weights[key(blockId: paddock.id, varietyKey: $0.key)] }
        let complete = !plantings.isEmpty && resolved.allSatisfy { $0?.kg != nil } && share > 0
        let weight: Double? = complete ? zip(plantings, resolved).reduce(0) { $0 + $1.0.share / share * ($1.1?.kg ?? 0) } : nil
        let vines = paddock.authoritativeVineCount
        let base: Double? = average.flatMap { avg in weight.map { avg * Double(vines) * $0 / 1000 } }
        let adjusted = base.map { $0 * min(1, max(0, remaining.isFinite ? remaining : 1)) }
        return Block(paddockId: paddock.id, name: paddock.name,
                     varieties: plantings.map(\.name).joined(separator: ", "),
                     samplesRecorded: counts.count, samplesTotal: sites.count, averageBunches: average,
                     vines: vines, sampledAreaHa: counts.isEmpty ? 0 : max(0, paddock.areaHectares),
                     weightKg: weight,
                     weightSources: zip(plantings, resolved).map { "\($0.0.name): \($0.1?.sourceLabel ?? "Not confirmed")" },
                     historicalWeightKg: session.blockBunchWeightsKg[paddock.id],
                     baseTonnes: base, adjustedTonnes: adjusted,
                     displayTonnes: session.applyDamage ? adjusted : base)
    }
    static func trip(session: YieldEstimationSession, paddocks: [Paddock],
                     weights: [String: YieldMasterWeight], remaining: (UUID) -> Double = { _ in 1 }) -> Trip {
        let blocks = paddocks.filter { session.selectedPaddockIds.contains($0.id) }.map {
            block(session: session, paddock: $0, weights: weights, remaining: remaining($0.id))
        }
        let sampled = blocks.filter { $0.samplesRecorded > 0 }
        // Never present a partial sum as the whole trip when one contributing weight is missing.
        let total: Double? = sampled.isEmpty || sampled.contains { $0.displayTonnes == nil }
            ? nil : sampled.reduce(0) { $0 + ($1.displayTonnes ?? 0) }
        return Trip(blocks: blocks, sampledAreaHa: sampled.reduce(0) { $0 + $1.sampledAreaHa }, totalTonnes: total)
    }
}
