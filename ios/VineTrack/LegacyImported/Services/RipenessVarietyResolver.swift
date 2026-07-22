import Foundation

/// Status of a paddock's primary variety with respect to the
/// Optimal Ripeness / GDD calculation.
enum RipenessVarietyStatus: Equatable {
    /// Variety resolves to a managed `GrapeVariety` and has a usable
    /// optimal GDD target.
    case ready(GrapeVariety)
    /// The variety record was found but has no usable optimal GDD target
    /// (zero or negative).
    case missingTarget(GrapeVariety)
    /// The paddock has a variety allocation but the referenced variety
    /// could not be resolved in the managed variety list.
    case unrecognised(PaddockVarietyAllocation)
    /// The paddock has no variety allocation at all.
    case missing
}

/// Result of resolving a paddock's primary variety. Encapsulates the
/// primary allocation, the resolved `GrapeVariety` (if any) and the
/// status used by both the setup checklist and the block row UI.
struct RipenessVarietyResolution {
    let primaryAllocation: PaddockVarietyAllocation?
    let variety: GrapeVariety?
    let status: RipenessVarietyStatus

    /// True only when the variety resolves and has a usable target.
    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    /// Short label suitable for inline display under a block name.
    var shortLabel: String {
        switch status {
        case .ready(let v): return v.name
        case .missingTarget(let v): return v.name
        case .unrecognised: return "Unrecognised variety"
        case .missing: return "No variety"
        }
    }
}

/// Central helper used by the setup checklist, the block row list and
/// the GDD calculation to decide whether a paddock's variety is usable.
///
/// Lookup order:
/// 1. By id in `store.grapeVarieties` (the same lookup the GDD
///    calculation uses via `store.grapeVariety(for:)`).
/// 2. Fallback to any persisted `GrapeVariety` whose id matches but is
///    scoped to a different vineyard — this guards against transient
///    sync states where the master list lags behind paddock data.
///
/// All matching is id-based because allocations only carry `varietyId`.
/// Name-based fallback isn't possible from the allocation alone, but
/// the resolver normalises name matching when comparing variety lists
/// for diagnostics (`canonicalName`).
@MainActor
enum RipenessVarietyResolver {

    /// Canonical form used for any name-based comparisons (case- and
    /// whitespace-insensitive, slashes/punctuation collapsed).
    static func canonicalName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics
        return String(trimmed.unicodeScalars.filter { allowed.contains($0) })
    }

    /// Resolve the primary variety + target status for a paddock.
    static func resolve(_ paddock: Paddock, store: MigratedDataStore) -> RipenessVarietyResolution {
        guard let primary = paddock.varietyAllocations.max(by: { $0.percent < $1.percent }) else {
            return RipenessVarietyResolution(primaryAllocation: nil, variety: nil, status: .missing)
        }
        return resolve(allocation: primary, store: store)
    }

    /// Resolve a specific allocation's variety + target status. Used by
    /// surfaces that show one row per allocation (e.g. multi-variety
    /// blocks in the Optimal Ripeness list).
    ///
    /// Resolution order:
    /// 1. id match against `store.grapeVarieties`.
    /// 2. name-snapshot match (canonical + built-in alias) — recovers
    ///    allocations written before built-in varieties had stable ids.
    static func resolve(allocation: PaddockVarietyAllocation, store: MigratedDataStore) -> RipenessVarietyResolution {
        let resolvedVariety: GrapeVariety? = {
            if let v = store.grapeVariety(for: allocation.varietyId) {
                return v
            }
            // Name fallback. Honours the canonical-name dictionary and the
            // built-in alias table so e.g. "Syrah" resolves to Shiraz.
            guard let raw = allocation.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            let canonical = BuiltInGrapeVarietyCatalog.canonical(raw)
            if let byName = store.grapeVarieties.first(where: {
                BuiltInGrapeVarietyCatalog.canonical($0.name) == canonical
            }) {
                return byName
            }
            if let entry = BuiltInGrapeVarietyCatalog.entry(matching: raw),
               let byKey = store.grapeVarieties.first(where: { $0.key == entry.key }) {
                return byKey
            }
            return nil
        }()

        if let variety = resolvedVariety {
            if variety.optimalGDD > 0 {
                return RipenessVarietyResolution(
                    primaryAllocation: allocation,
                    variety: variety,
                    status: .ready(variety)
                )
            }
            return RipenessVarietyResolution(
                primaryAllocation: allocation,
                variety: variety,
                status: .missingTarget(variety)
            )
        }
        return RipenessVarietyResolution(
            primaryAllocation: allocation,
            variety: nil,
            status: .unrecognised(allocation)
        )
    }

    /// The unique set of managed `GrapeVariety` records currently
    /// referenced by at least one block in the vineyard.
    static func varietiesInUse(store: MigratedDataStore) -> [GrapeVariety] {
        var seen = Set<UUID>()
        var result: [GrapeVariety] = []
        for paddock in store.orderedPaddocks {
            for alloc in paddock.varietyAllocations {
                guard !seen.contains(alloc.varietyId) else { continue }
                if let v = store.grapeVariety(for: alloc.varietyId) {
                    seen.insert(v.id)
                    result.append(v)
                }
            }
        }
        return result
    }

    /// Allocation ids that point at varieties the master list cannot
    /// resolve, even after name-snapshot fallback. Used to surface
    /// "unrecognised variety" warnings.
    static func unresolvedAllocationVarietyIds(store: MigratedDataStore) -> Set<UUID> {
        var ids: Set<UUID> = []
        for paddock in store.orderedPaddocks {
            for alloc in paddock.varietyAllocations {
                let resolution = resolve(allocation: alloc, store: store)
                if resolution.variety == nil {
                    ids.insert(alloc.varietyId)
                }
            }
        }
        return ids
    }
}
