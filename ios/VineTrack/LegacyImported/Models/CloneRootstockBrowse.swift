import Foundation

/// Pure helpers for the Grape Varieties settings CATALOGUE BROWSER
/// (Varieties | Clones | Rootstocks). Unlike the per-allocation pickers —
/// which always scope clones to one variety — the browser can list across
/// ALL varieties (`varietyKey == nil`).
///
/// Also owns allocation-usage matching: an allocation "uses" a catalogue
/// record when its stable key matches, or (legacy rows only, key absent)
/// when its free-text snapshot canonically equals one of the record's
/// names/aliases. Reserved sentinels (`mass_selection`, `own_roots`) are
/// allocation-level conventions, never catalogue rows, so they can never
/// match a record.
///
/// Mirrored exactly by Android `CloneRootstockBrowse`; behaviour is pinned
/// by `CloneRootstockBrowseTests.swift` / `CloneRootstockBrowseTest.kt`.
nonisolated enum CloneRootstockBrowse {

    /// Built-in clones, optionally scoped to one variety (`nil` = all).
    static func systemClones(
        _ catalog: [SharedGrapeCloneCatalogEntry],
        varietyKey: String?,
        query: String = ""
    ) -> [SharedGrapeCloneCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.filter { entry in
            guard entry.isActive else { return false }
            if let varietyKey, entry.varietyKey != varietyKey { return false }
            guard !q.isEmpty else { return true }
            return entry.displayName.localizedCaseInsensitiveContains(q)
                || entry.cloneCode.localizedCaseInsensitiveContains(q)
                || entry.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    /// Vineyard custom clones, optionally scoped to one variety (`nil` = all).
    static func customClones(
        _ custom: [VineyardGrapeCloneRow],
        varietyKey: String?,
        query: String = ""
    ) -> [VineyardGrapeCloneRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.filter { row in
            guard row.isActive else { return false }
            if let varietyKey, row.varietyKey != varietyKey { return false }
            guard !q.isEmpty else { return true }
            return row.displayName.localizedCaseInsensitiveContains(q)
        }
    }

    /// Built-in rootstocks (rootstocks are independent of scion variety).
    static func systemRootstocks(
        _ catalog: [SharedRootstockCatalogEntry],
        query: String = ""
    ) -> [SharedRootstockCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.filter { entry in
            guard entry.isActive else { return false }
            guard !q.isEmpty else { return true }
            return entry.displayName.localizedCaseInsensitiveContains(q)
                || entry.canonicalName.localizedCaseInsensitiveContains(q)
                || entry.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
                || (entry.parentage?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Vineyard custom rootstocks.
    static func customRootstocks(
        _ custom: [VineyardRootstockRow],
        query: String = ""
    ) -> [VineyardRootstockRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.filter { row in
            guard row.isActive else { return false }
            guard !q.isEmpty else { return true }
            return row.displayName.localizedCaseInsensitiveContains(q)
        }
    }

    /// Names a built-in clone can be matched against (legacy free text).
    static func cloneMatchNames(_ entry: SharedGrapeCloneCatalogEntry) -> [String] {
        [entry.displayName, entry.cloneCode] + entry.aliases
    }

    /// Names a built-in rootstock can be matched against (legacy free text).
    static func rootstockMatchNames(_ entry: SharedRootstockCatalogEntry) -> [String] {
        [entry.displayName, entry.canonicalName] + entry.aliases
    }

    /// True when a block allocation uses the clone identified by `entryKey`.
    /// Stable-key match wins; legacy free-text (no key) matches canonically
    /// against `matchNames`. An allocation carrying a DIFFERENT key
    /// (including the `mass_selection` sentinel) never matches, even if its
    /// display text happens to collide.
    static func allocationUsesClone(
        allocationCloneKey: String?,
        allocationCloneText: String?,
        entryKey: String,
        matchNames: [String]
    ) -> Bool {
        if allocationCloneKey == entryKey { return true }
        if allocationCloneKey != nil { return false }
        guard let text = allocationCloneText else { return false }
        let canonical = BuiltInGrapeVarietyCatalog.canonical(text)
        guard !canonical.isEmpty else { return false }
        return matchNames.contains { BuiltInGrapeVarietyCatalog.canonical($0) == canonical }
    }

    /// Rootstock counterpart of `allocationUsesClone`.
    static func allocationUsesRootstock(
        allocationRootstockKey: String?,
        allocationRootstockText: String?,
        entryKey: String,
        matchNames: [String]
    ) -> Bool {
        if allocationRootstockKey == entryKey { return true }
        if allocationRootstockKey != nil { return false }
        guard let text = allocationRootstockText else { return false }
        let canonical = BuiltInGrapeVarietyCatalog.canonical(text)
        guard !canonical.isEmpty else { return false }
        return matchNames.contains { BuiltInGrapeVarietyCatalog.canonical($0) == canonical }
    }
}
