import Foundation

/// One-shot repair pass that fixes drift between the managed
/// `GrapeVariety` master list and `Paddock.varietyAllocations` caused by
/// the previous design — built-in varieties were seeded with random
/// UUIDs, so the same logical variety ended up with different ids across
/// devices, app resets and cross-device sync. Existing block allocations
/// then pointed at stale ids and surfaced as "Unknown" / "not in master
/// list" even when the variety was a standard built-in.
///
/// Behaviour (idempotent, safe to call repeatedly):
/// 1. For each variety in the current vineyard whose name matches a
///    built-in catalog entry, upgrade it: stamp `key`, mark built-in,
///    and migrate it onto the deterministic id derived from
///    `(vineyardId, key)`. Allocations pointing at the old id are
///    remapped to the new id.
/// 2. Collapse duplicates: when two varieties share the same canonical
///    name within a vineyard, keep the canonical one (built-in/key-stamped
///    record wins) and remap allocations from the dropped duplicates.
/// 3. Backfill allocation name snapshots so allocations remain
///    resolvable on devices that don't yet have the master list.
/// 4. Repair orphan allocations: when an allocation's `varietyId` no
///    longer matches any managed variety but `name` matches one
///    (canonically or via the built-in alias table), update the
///    allocation to point at the canonical id.
@MainActor
enum GrapeVarietyCanonicalization {

    /// Run the full repair pass for the currently selected vineyard.
    /// No-op when no vineyard is selected.
    static func run(store: MigratedDataStore) {
        guard let vineyardId = store.selectedVineyardId else { return }

        #if DEBUG
        let startVarieties = store.grapeVarieties.filter { $0.vineyardId == vineyardId }.count
        let startPaddocks = store.paddocks.filter { $0.vineyardId == vineyardId }.count
        print("[GrapeVarietyCanonicalization] start vineyard=\(vineyardId.uuidString.prefix(8)) varieties=\(startVarieties) paddocks=\(startPaddocks)")
        #endif

        var idRemap: [UUID: UUID] = [:]
        var varieties = store.grapeVarieties

        // Step 1: upgrade built-in-shaped varieties to stable ids/keys.
        for index in varieties.indices where varieties[index].vineyardId == vineyardId {
            let v = varieties[index]
            // Already canonical → nothing to do.
            if let key = v.key, !key.isEmpty,
               v.id == GrapeVariety.deterministicID(vineyardId: vineyardId, key: key) {
                // Make sure isBuiltIn is set when key matches a built-in.
                if BuiltInGrapeVarietyCatalog.entriesByCanonicalName[BuiltInGrapeVarietyCatalog.canonical(v.name)] != nil,
                   !v.isBuiltIn {
                    varieties[index].isBuiltIn = true
                }
                continue
            }
            // Try to match against the built-in catalog by name/alias.
            guard let entry = BuiltInGrapeVarietyCatalog.entry(matching: v.name) else {
                continue
            }
            let canonicalId = GrapeVariety.deterministicID(vineyardId: vineyardId, key: entry.key)
            if v.id != canonicalId {
                idRemap[v.id] = canonicalId
            }
            varieties[index].id = canonicalId
            varieties[index].key = entry.key
            varieties[index].isBuiltIn = true
            // Prefer the catalog's canonical display name so the UI shows
            // a consistent spelling across devices.
            varieties[index].name = entry.name
            if varieties[index].optimalGDD <= 0 {
                varieties[index].optimalGDD = entry.optimalGDD
            }
        }

        // Step 2: collapse duplicates within the vineyard by canonical
        // name. Prefer the entry with a `key` (built-in) as the keeper.
        var keptByCanonicalName: [String: UUID] = [:]
        var droppedIds: Set<UUID> = []
        // First pass — register all key-stamped entries as the canonical
        // keeper for their canonical name.
        for v in varieties where v.vineyardId == vineyardId {
            let canonical = BuiltInGrapeVarietyCatalog.canonical(v.name)
            guard !canonical.isEmpty else { continue }
            if v.key != nil, keptByCanonicalName[canonical] == nil {
                keptByCanonicalName[canonical] = v.id
            }
        }
        // Second pass — for remaining duplicates, keep the first.
        for v in varieties where v.vineyardId == vineyardId {
            let canonical = BuiltInGrapeVarietyCatalog.canonical(v.name)
            guard !canonical.isEmpty else { continue }
            if let kept = keptByCanonicalName[canonical] {
                if kept != v.id { idRemap[v.id] = kept; droppedIds.insert(v.id) }
            } else {
                keptByCanonicalName[canonical] = v.id
            }
        }

        // De-duplicate the variety list while preserving order.
        var seen = Set<UUID>()
        var rebuilt: [GrapeVariety] = []
        rebuilt.reserveCapacity(varieties.count)
        for v in varieties {
            if v.vineyardId == vineyardId {
                guard !droppedIds.contains(v.id) else { continue }
                guard seen.insert(v.id).inserted else { continue }
            }
            rebuilt.append(v)
        }

        let varietiesChanged = (rebuilt != store.grapeVarieties)
        if varietiesChanged {
            store.grapeVarieties = rebuilt
            store.persistGrapeVarieties()
        }

        // Step 3+4: repair allocations.
        let scopedVarieties = rebuilt.filter { $0.vineyardId == vineyardId }
        let canonicalNameToId: [String: UUID] = Dictionary(
            uniqueKeysWithValues: scopedVarieties.map {
                (BuiltInGrapeVarietyCatalog.canonical($0.name), $0.id)
            }.uniqued()
        )

        var paddocksChanged = false
        for paddockIndex in store.paddocks.indices where store.paddocks[paddockIndex].vineyardId == vineyardId {
            var paddock = store.paddocks[paddockIndex]
            var allocationsChanged = false
            var updated: [PaddockVarietyAllocation] = []
            updated.reserveCapacity(paddock.varietyAllocations.count)
            for alloc in paddock.varietyAllocations {
                var copy = alloc
                // a) Apply id remap from canonicalization.
                if let remap = idRemap[copy.varietyId] {
                    copy.varietyId = remap
                    allocationsChanged = true
                }
                // b) If id still doesn't match a managed variety, try
                //    resolving by name snapshot (canonical + alias).
                if scopedVarieties.first(where: { $0.id == copy.varietyId }) == nil,
                   let nameSnapshot = copy.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !nameSnapshot.isEmpty {
                    let canonical = BuiltInGrapeVarietyCatalog.canonical(nameSnapshot)
                    if let matchId = canonicalNameToId[canonical] {
                        copy.varietyId = matchId
                        allocationsChanged = true
                    } else if let entry = BuiltInGrapeVarietyCatalog.entry(matching: nameSnapshot),
                              let matchId = scopedVarieties.first(where: { $0.key == entry.key })?.id {
                        copy.varietyId = matchId
                        allocationsChanged = true
                    }
                }
                // c) Backfill name snapshot from the resolved variety.
                if (copy.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                   let v = scopedVarieties.first(where: { $0.id == copy.varietyId }) {
                    copy.name = v.name
                    allocationsChanged = true
                }
                // d) Backfill stable `varietyKey` so the allocation stays
                //    resolvable across devices/resets even if `varietyId`
                //    drifts. Derived from the resolved master variety
                //    (`key` or catalog-folded name) or the name snapshot.
                if (copy.varietyKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    var derivedKey: String? = nil
                    if let v = scopedVarieties.first(where: { $0.id == copy.varietyId }) {
                        if let k = v.key, !k.isEmpty {
                            derivedKey = k
                        } else if let entry = BuiltInGrapeVarietyCatalog.entry(matching: v.name) {
                            derivedKey = entry.key
                        }
                    }
                    if derivedKey == nil,
                       let nameSnapshot = copy.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !nameSnapshot.isEmpty,
                       let entry = BuiltInGrapeVarietyCatalog.entry(matching: nameSnapshot) {
                        derivedKey = entry.key
                    }
                    if let k = derivedKey {
                        copy.varietyKey = k
                        allocationsChanged = true
                    }
                }
                updated.append(copy)
            }
            if allocationsChanged {
                paddock.varietyAllocations = updated
                store.paddocks[paddockIndex] = paddock
                paddocksChanged = true
            }
        }
        if paddocksChanged {
            store.persistPaddocksAfterRepair()
        }

        #if DEBUG
        print("[GrapeVarietyCanonicalization] done varietiesChanged=\(varietiesChanged) paddocksChanged=\(paddocksChanged) idRemap=\(idRemap.count)")
        #endif
    }
}

private extension Array where Element == (String, UUID) {
    /// Deduplicate by key, keeping the first occurrence.
    func uniqued() -> [(String, UUID)] {
        var seen = Set<String>()
        var out: [(String, UUID)] = []
        for (k, v) in self where !k.isEmpty {
            if seen.insert(k).inserted { out.append((k, v)) }
        }
        return out
    }
}
