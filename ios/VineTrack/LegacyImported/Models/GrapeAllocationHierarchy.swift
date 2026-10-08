import Foundation

/// Read-only block attribution. Deliberately separate from financial block splitting.
nonisolated enum GrapeAllocationHierarchy {
    // Portal src/lib/varietyResolver.ts: allocation-display aliases only, not stored identities.
    private static let portalNames: [(String, [String])] = [
        ("Cabernet Sauvignon", ["cab sauv", "cabernet sauv", "cab", "cabernet"]),
        ("Cabernet Franc", ["cab franc", "cab frnc", "cab fr", "cabernet fr"]),
        ("Merlot", ["mer"]), ("Shiraz", ["syrah"]),
        ("Pinot Noir", ["pinot n", "p noir", "pn"]),
        ("Pinot Gris", ["pinot grigio", "pinot gris grigio", "pinot gris / grigio", "p gris", "pg", "pinot_grigio"]),
        ("Pinot Meunier", ["meunier"]), ("Chardonnay", ["chard"]),
        ("Sauvignon Blanc", ["sauv blanc", "savvy b", "sb", "sauvignon b"]),
        ("Semillon", ["sem", "sémillon"]), ("Riesling", ["ries"]),
        ("Gruner Veltliner", ["grüner veltliner", "gruner", "grüner", "gv"]),
        ("Tempranillo", ["temp"]), ("Primitivo", ["zinfandel", "zin"]),
        ("Nebbiolo", ["nebb"]), ("Sangiovese", ["sangio"]), ("Grenache", ["garnacha"]),
        ("Mourvedre", ["mourvèdre", "monastrell", "mataro"]), ("Viognier", ["vio"]),
        ("Verdelho", []), ("Vermentino", []), ("Marsanne", []), ("Roussanne", []),
        ("Petit Verdot", ["pv"]), ("Malbec", []), ("Barbera", []), ("Montepulciano", []),
        ("Fiano", []), ("Arneis", []), ("Gewurztraminer", ["gewürztraminer", "gewurz"])
    ]
    private static func builtinKey(_ raw: String) -> String {
        raw.decomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "[\\u0300-\\u036f]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
    private static let builtinNames: [String: String] = {
        var names: [String: String] = [:]
        for (name, aliases) in portalNames {
            for raw in [name] + aliases { names[builtinKey(raw)] = name }
        }
        return names
    }()
    static func varietyKey(_ raw: String) -> String {
        if let name = builtinNames[builtinKey(raw)] { return name.lowercased() }
        let key = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return key.isEmpty ? "__unspecified__" : key
    }
    static func varietyLabel(_ raw: String) -> String {
        if let name = builtinNames[builtinKey(raw)] { return name }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Unspecified variety" }
        return trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed
    }

    /// Group presentation supply before legacy name normalization can erase custom punctuation.
    static func supply(_ projection: SeasonYieldProjection.Result?) -> [GrapeAllocationCalculator.CanonicalSupply] {
        guard let projection else { return [] }
        return projection.varieties.map { variety in
            .init(varietyKey: varietyKey(variety.displayName), displayName: variety.displayName,
                  tonnes: projection.damageApplied ? variety.adjustedTonnes : variety.baseTonnes,
                  knownTonnes: projection.damageApplied ? variety.knownAdjustedTonnes : variety.knownBaseTonnes,
                  isEstimateComplete: variety.isEstimateComplete)
        }
    }

    static func varietyRows(supply: [GrapeAllocationCalculator.CanonicalSupply], allocations: [GrapeAllocation],
                            vineyardId: UUID?, vintage: Int) -> [GrapeAllocationCalculator.CanonicalVarietyRow] {
        let estimates = Dictionary(grouping: supply, by: { varietyKey($0.displayName) })
        let scoped = allocations.filter { $0.vineyardId == vineyardId && $0.vintage == vintage }
        let allocated = Dictionary(grouping: scoped, by: { varietyKey($0.varietyName) })
        return Set(estimates.keys).union(allocated.keys).map { key in
            let sources = estimates[key] ?? []
            let records = allocated[key] ?? []
            let tonnes = sources.compactMap(\.tonnes)
            return GrapeAllocationCalculator.CanonicalVarietyRow(
                varietyKey: key, displayName: varietyLabel(sources.first?.displayName ?? records.first?.varietyName ?? ""),
                estimatedTonnes: !sources.isEmpty && tonnes.count == sources.count ? tonnes.reduce(0, +) : nil,
                knownEstimatedTonnes: sources.reduce(0) { $0 + $1.knownTonnes },
                isEstimateComplete: !sources.isEmpty && sources.allSatisfy(\.isEstimateComplete),
                ownUseTonnes: records.filter { $0.allocationType == .ownUse }.reduce(0) { $0 + $1.quantityTonnes },
                externalTonnes: records.filter { $0.allocationType == .external }.reduce(0) { $0 + $1.quantityTonnes })
        }.sorted {
            if $0.estimatedTonnes != $1.estimatedTonnes { return ($0.estimatedTonnes ?? -.infinity) > ($1.estimatedTonnes ?? -.infinity) }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    struct Estimate: Sendable {
        let paddockId: UUID
        let varietyName: String
        let tonnes: Double?
    }

    struct BlockRow: Identifiable, Sendable {
        var id: String { paddockId?.uuidString ?? "no-block" }
        let paddockId: UUID?
        let name: String
        var estimatedTonnes: Double?
        var ownUseTonnes: Double = 0
        var externalTonnes: Double = 0
        var allocationIds: [UUID] = []
        var hasUnspecifiedQuantity: Bool = false
        var allocatedTonnes: Double { ownUseTonnes + externalTonnes }
        var balanceTonnes: Double? { estimatedTonnes.map { $0 - allocatedTonnes } }
    }

    static func estimates(_ projection: SeasonYieldProjection.Result?) -> [Estimate] {
        guard let projection else { return [] }
        return projection.blocks.flatMap { block in
            block.groups.map { group in
                Estimate(paddockId: block.paddockId, varietyName: group.displayName,
                         tonnes: group.isEstimateAvailable ? (projection.damageApplied ? group.adjustedTonnes : group.baseTonnes) : nil)
            }
        }
    }

    /// Unknown estimates remain unknown, and duplicate links are merged by block UUID.
    /// A signed residual preserves reconciliation even for legacy over-assigned records.
    static func rows(varietyKey: String, vineyardId: UUID, vintage: Int,
                     allocations: [GrapeAllocation], estimates: [Estimate],
                     blockNames: [UUID: String]) -> [BlockRow] {
        var rows: [String: BlockRow] = [:]
        func ensure(_ id: UUID?) -> String {
            let key = id?.uuidString ?? "no-block"
            if rows[key] == nil {
                rows[key] = BlockRow(paddockId: id,
                    name: id.map { blockNames[$0] ?? "Unknown block" } ?? "No block specified",
                    estimatedTonnes: nil)
            }
            return key
        }
        var seenEstimates: Set<UUID> = []
        for estimate in estimates where self.varietyKey(estimate.varietyName) == varietyKey {
            let key = ensure(estimate.paddockId)
            if seenEstimates.insert(estimate.paddockId).inserted {
                rows[key]?.estimatedTonnes = estimate.tonnes
            } else if let previous = rows[key]?.estimatedTonnes, let tonnes = estimate.tonnes {
                rows[key]?.estimatedTonnes = previous + tonnes
            } else {
                rows[key]?.estimatedTonnes = nil
            }
        }
        func add(_ id: UUID?, _ allocation: GrapeAllocation, _ tonnes: Double, unspecified: Bool = false) {
            let key = ensure(id)
            if allocation.allocationType == .ownUse { rows[key]?.ownUseTonnes += tonnes }
            else { rows[key]?.externalTonnes += tonnes }
            if rows[key]?.allocationIds.contains(allocation.id) == false { rows[key]?.allocationIds.append(allocation.id) }
            if unspecified { rows[key]?.hasUnspecifiedQuantity = true }
        }
        for allocation in allocations where allocation.vineyardId == vineyardId && allocation.vintage == vintage && self.varietyKey(allocation.varietyName) == varietyKey {
            let links = Dictionary(grouping: allocation.blocks, by: \.paddockId)
            var assigned: Double = 0
            for (id, details) in links {
                let quantities = details.compactMap { $0.quantityTonnes }.filter(\.isFinite)
                let tonnes: Double? = quantities.isEmpty ? (links.count == 1 ? allocation.quantityTonnes : nil) : quantities.reduce(0, +)
                add(id, allocation, tonnes ?? 0, unspecified: tonnes == nil)
                assigned += tonnes ?? 0
            }
            let remainder = allocation.quantityTonnes - assigned
            if remainder != 0 || links.isEmpty { add(nil, allocation, remainder) }
        }
        return rows.values.sorted {
            if ($0.paddockId == nil) != ($1.paddockId == nil) { return $0.paddockId != nil }
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
