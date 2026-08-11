import Foundation

// MARK: - Allocation sentinels

/// Reserved allocation-level keys that are deliberately NOT catalogue rows.
/// `mass_selection` marks vines propagated by mass selection (no certified
/// clone identity); `own_roots` marks ungrafted/own-rooted vines (not a
/// biological rootstock). Absent/nil keys mean "not specified / unknown".
/// Mirrors the sql/182 contract.
nonisolated enum CloneRootstockSentinels {
    static let massSelectionKey = "mass_selection"
    static let massSelectionDisplay = "Mass selection"
    static let ownRootsKey = "own_roots"
    static let ownRootsDisplay = "Own roots"
}

// MARK: - Built-in clone catalogue (offline fallback)

/// Bundled fallback copy of the shared clone catalogue (sql/182,
/// `grape_clone_catalog`). Supabase is the source of truth; this list is
/// only used when the shared cache has never been populated. Keys MUST
/// remain stable — they are part of the clone identity. A clone belongs to
/// exactly ONE variety (`varietyKey`); the same visible number under two
/// selection systems (e.g. FPS 07 vs ENTAV-INRA 07) is two different clones.
nonisolated enum BuiltInCloneCatalog {
    struct Entry: Sendable, Hashable, Identifiable {
        let key: String
        let varietyKey: String
        let displayName: String
        let cloneCode: String
        let selectionSystem: String?
        let sourceCountry: String?
        let aliases: [String]

        var id: String { key }
    }

    static let entries: [Entry] = [
        // Chardonnay
        Entry(key: "chardonnay:gin_gin", varietyKey: "chardonnay", displayName: "Gin Gin", cloneCode: "Gin Gin", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["Gingin"]),
        Entry(key: "chardonnay:mendoza", varietyKey: "chardonnay", displayName: "Mendoza", cloneCode: "Mendoza", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["C2V16", "FPS 01A"]),
        Entry(key: "chardonnay:i10v1", varietyKey: "chardonnay", displayName: "I10V1", cloneCode: "I10V1", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["FPS 06"]),
        Entry(key: "chardonnay:i10v5", varietyKey: "chardonnay", displayName: "I10V5", cloneCode: "I10V5", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["FPS 08"]),
        Entry(key: "chardonnay:p58", varietyKey: "chardonnay", displayName: "P58", cloneCode: "P58", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["Penfolds 58"]),
        Entry(key: "chardonnay:entav_76", varietyKey: "chardonnay", displayName: "ENTAV-INRA 76", cloneCode: "76", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Bernard 76", "Dijon 76"]),
        Entry(key: "chardonnay:entav_95", varietyKey: "chardonnay", displayName: "ENTAV-INRA 95", cloneCode: "95", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Bernard 95", "Dijon 95"]),
        Entry(key: "chardonnay:entav_96", varietyKey: "chardonnay", displayName: "ENTAV-INRA 96", cloneCode: "96", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Bernard 96", "Dijon 96"]),
        Entry(key: "chardonnay:entav_277", varietyKey: "chardonnay", displayName: "ENTAV-INRA 277", cloneCode: "277", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Bernard 277", "Dijon 277"]),
        Entry(key: "chardonnay:entav_548", varietyKey: "chardonnay", displayName: "ENTAV-INRA 548", cloneCode: "548", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "chardonnay:entav_809", varietyKey: "chardonnay", displayName: "ENTAV-INRA 809", cloneCode: "809", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "chardonnay:entav_1066", varietyKey: "chardonnay", displayName: "ENTAV-INRA 1066", cloneCode: "1066", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),

        // Shiraz
        Entry(key: "shiraz:pt23", varietyKey: "shiraz", displayName: "PT23", cloneCode: "PT23", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["PT 23"]),
        Entry(key: "shiraz:1654", varietyKey: "shiraz", displayName: "1654", cloneCode: "1654", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "shiraz:bvrc12", varietyKey: "shiraz", displayName: "BVRC12", cloneCode: "BVRC12", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["BVRC 12"]),
        Entry(key: "shiraz:bvrc30", varietyKey: "shiraz", displayName: "BVRC30", cloneCode: "BVRC30", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["BVRC 30"]),
        Entry(key: "shiraz:entav_174", varietyKey: "shiraz", displayName: "ENTAV-INRA 174", cloneCode: "174", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "shiraz:entav_300", varietyKey: "shiraz", displayName: "ENTAV-INRA 300", cloneCode: "300", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "shiraz:entav_470", varietyKey: "shiraz", displayName: "ENTAV-INRA 470", cloneCode: "470", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "shiraz:entav_524", varietyKey: "shiraz", displayName: "ENTAV-INRA 524", cloneCode: "524", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "shiraz:fps_01", varietyKey: "shiraz", displayName: "FPS 01", cloneCode: "FPS 01", selectionSystem: "FPS (UC Davis)", sourceCountry: "USA", aliases: []),
        Entry(key: "shiraz:fps_07", varietyKey: "shiraz", displayName: "FPS 07", cloneCode: "FPS 07", selectionSystem: "FPS (UC Davis)", sourceCountry: "USA", aliases: []),

        // Pinot Noir
        Entry(key: "pinot_noir:mv6", varietyKey: "pinot_noir", displayName: "MV6", cloneCode: "MV6", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["MV 6"]),
        Entry(key: "pinot_noir:d5v12", varietyKey: "pinot_noir", displayName: "D5V12", cloneCode: "D5V12", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "pinot_noir:d2v5", varietyKey: "pinot_noir", displayName: "D2V5", cloneCode: "D2V5", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "pinot_noir:g5v15", varietyKey: "pinot_noir", displayName: "G5V15", cloneCode: "G5V15", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "pinot_noir:g8v3", varietyKey: "pinot_noir", displayName: "G8V3", cloneCode: "G8V3", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "pinot_noir:entav_114", varietyKey: "pinot_noir", displayName: "ENTAV-INRA 114", cloneCode: "114", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Dijon 114"]),
        Entry(key: "pinot_noir:entav_115", varietyKey: "pinot_noir", displayName: "ENTAV-INRA 115", cloneCode: "115", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Dijon 115"]),
        Entry(key: "pinot_noir:entav_667", varietyKey: "pinot_noir", displayName: "ENTAV-INRA 667", cloneCode: "667", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Dijon 667"]),
        Entry(key: "pinot_noir:entav_777", varietyKey: "pinot_noir", displayName: "ENTAV-INRA 777", cloneCode: "777", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Dijon 777"]),
        Entry(key: "pinot_noir:entav_828", varietyKey: "pinot_noir", displayName: "ENTAV-INRA 828", cloneCode: "828", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Dijon 828"]),
        Entry(key: "pinot_noir:entav_943", varietyKey: "pinot_noir", displayName: "ENTAV-INRA 943", cloneCode: "943", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Dijon 943"]),
        Entry(key: "pinot_noir:pommard", varietyKey: "pinot_noir", displayName: "Pommard", cloneCode: "Pommard", selectionSystem: "FPS (UC Davis)", sourceCountry: "USA", aliases: ["UCD 4", "Pommard 4"]),
        Entry(key: "pinot_noir:abel", varietyKey: "pinot_noir", displayName: "Abel", cloneCode: "Abel", selectionSystem: "New Zealand selection", sourceCountry: "New Zealand", aliases: ["Gumboot", "Ata Rangi"]),

        // Cabernet Sauvignon
        Entry(key: "cabernet_sauvignon:sa125", varietyKey: "cabernet_sauvignon", displayName: "SA125", cloneCode: "SA125", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["SA 125"]),
        Entry(key: "cabernet_sauvignon:g9v3", varietyKey: "cabernet_sauvignon", displayName: "G9V3", cloneCode: "G9V3", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "cabernet_sauvignon:cw44", varietyKey: "cabernet_sauvignon", displayName: "CW44", cloneCode: "CW44", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "cabernet_sauvignon:lc10", varietyKey: "cabernet_sauvignon", displayName: "LC10", cloneCode: "LC10", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["Reynella"]),
        Entry(key: "cabernet_sauvignon:entav_169", varietyKey: "cabernet_sauvignon", displayName: "ENTAV-INRA 169", cloneCode: "169", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "cabernet_sauvignon:entav_191", varietyKey: "cabernet_sauvignon", displayName: "ENTAV-INRA 191", cloneCode: "191", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "cabernet_sauvignon:entav_337", varietyKey: "cabernet_sauvignon", displayName: "ENTAV-INRA 337", cloneCode: "337", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "cabernet_sauvignon:entav_412", varietyKey: "cabernet_sauvignon", displayName: "ENTAV-INRA 412", cloneCode: "412", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "cabernet_sauvignon:fps_07", varietyKey: "cabernet_sauvignon", displayName: "FPS 07", cloneCode: "FPS 07", selectionSystem: "FPS (UC Davis)", sourceCountry: "USA", aliases: []),
        Entry(key: "cabernet_sauvignon:fps_08", varietyKey: "cabernet_sauvignon", displayName: "FPS 08", cloneCode: "FPS 08", selectionSystem: "FPS (UC Davis)", sourceCountry: "USA", aliases: []),

        // Sauvignon Blanc
        Entry(key: "sauvignon_blanc:f4v6", varietyKey: "sauvignon_blanc", displayName: "F4V6", cloneCode: "F4V6", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "sauvignon_blanc:f7v7", varietyKey: "sauvignon_blanc", displayName: "F7V7", cloneCode: "F7V7", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "sauvignon_blanc:entav_242", varietyKey: "sauvignon_blanc", displayName: "ENTAV-INRA 242", cloneCode: "242", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "sauvignon_blanc:entav_316", varietyKey: "sauvignon_blanc", displayName: "ENTAV-INRA 316", cloneCode: "316", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "sauvignon_blanc:entav_317", varietyKey: "sauvignon_blanc", displayName: "ENTAV-INRA 317", cloneCode: "317", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "sauvignon_blanc:entav_530", varietyKey: "sauvignon_blanc", displayName: "ENTAV-INRA 530", cloneCode: "530", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "sauvignon_blanc:fps_01", varietyKey: "sauvignon_blanc", displayName: "FPS 01", cloneCode: "FPS 01", selectionSystem: "FPS (UC Davis)", sourceCountry: "USA", aliases: []),

        // Merlot
        Entry(key: "merlot:d3v14", varietyKey: "merlot", displayName: "D3V14", cloneCode: "D3V14", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "merlot:entav_181", varietyKey: "merlot", displayName: "ENTAV-INRA 181", cloneCode: "181", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "merlot:entav_343", varietyKey: "merlot", displayName: "ENTAV-INRA 343", cloneCode: "343", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "merlot:entav_348", varietyKey: "merlot", displayName: "ENTAV-INRA 348", cloneCode: "348", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),

        // Riesling
        Entry(key: "riesling:gm110", varietyKey: "riesling", displayName: "GM110", cloneCode: "GM110", selectionSystem: "Geisenheim", sourceCountry: "Germany", aliases: ["Geisenheim 110"]),
        Entry(key: "riesling:gm198", varietyKey: "riesling", displayName: "GM198", cloneCode: "GM198", selectionSystem: "Geisenheim", sourceCountry: "Germany", aliases: ["Geisenheim 198"]),
        Entry(key: "riesling:gm239", varietyKey: "riesling", displayName: "GM239", cloneCode: "GM239", selectionSystem: "Geisenheim", sourceCountry: "Germany", aliases: ["Geisenheim 239"]),

        // Pinot Gris
        Entry(key: "pinot_gris:d1v7", varietyKey: "pinot_gris", displayName: "D1V7", cloneCode: "D1V7", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: []),
        Entry(key: "pinot_gris:entav_52", varietyKey: "pinot_gris", displayName: "ENTAV-INRA 52", cloneCode: "52", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "pinot_gris:entav_53", varietyKey: "pinot_gris", displayName: "ENTAV-INRA 53", cloneCode: "53", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "pinot_gris:entav_457", varietyKey: "pinot_gris", displayName: "ENTAV-INRA 457", cloneCode: "457", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),

        // Grenache
        Entry(key: "grenache:entav_136", varietyKey: "grenache", displayName: "ENTAV-INRA 136", cloneCode: "136", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "grenache:entav_362", varietyKey: "grenache", displayName: "ENTAV-INRA 362", cloneCode: "362", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "grenache:entav_513", varietyKey: "grenache", displayName: "ENTAV-INRA 513", cloneCode: "513", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "grenache:entav_515", varietyKey: "grenache", displayName: "ENTAV-INRA 515", cloneCode: "515", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),

        // Semillon
        Entry(key: "semillon:entav_173", varietyKey: "semillon", displayName: "ENTAV-INRA 173", cloneCode: "173", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: []),
        Entry(key: "semillon:entav_299", varietyKey: "semillon", displayName: "ENTAV-INRA 299", cloneCode: "299", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: [])
    ]

    /// Clones for one variety only — a Shiraz clone must never surface
    /// under Chardonnay.
    static func entries(forVarietyKey key: String) -> [Entry] {
        entries.filter { $0.varietyKey == key }
    }

    /// Match legacy free text against name/code/aliases WITHIN a variety.
    /// Used only for suggestions; ambiguous text is never auto-mapped.
    static func entry(matching text: String, varietyKey: String?) -> Entry? {
        let canonical = BuiltInGrapeVarietyCatalog.canonical(text)
        guard !canonical.isEmpty else { return nil }
        let scope = varietyKey.map { entries(forVarietyKey: $0) } ?? entries
        return scope.first { e in
            BuiltInGrapeVarietyCatalog.canonical(e.displayName) == canonical
                || BuiltInGrapeVarietyCatalog.canonical(e.cloneCode) == canonical
                || e.aliases.contains { BuiltInGrapeVarietyCatalog.canonical($0) == canonical }
        }
    }
}

// MARK: - Built-in rootstock catalogue (offline fallback)

/// Bundled fallback copy of the shared rootstock catalogue (sql/182,
/// `rootstock_catalog`). Rootstocks are INDEPENDENT of scion variety —
/// there is deliberately no variety → rootstock relationship.
nonisolated enum BuiltInRootstockCatalog {
    struct Entry: Sendable, Hashable, Identifiable {
        let key: String
        let canonicalName: String
        let displayName: String
        let aliases: [String]
        let parentage: String?

        var id: String { key }
    }

    static let entries: [Entry] = [
        Entry(key: "101_14", canonicalName: "101-14 Mgt", displayName: "101-14 Mgt", aliases: ["101-14", "101.14 Millardet et de Grasset"], parentage: "V. riparia × V. rupestris"),
        Entry(key: "3309c", canonicalName: "3309 Couderc", displayName: "3309 Couderc", aliases: ["3309C", "3309"], parentage: "V. riparia × V. rupestris"),
        Entry(key: "schwarzmann", canonicalName: "Schwarzmann", displayName: "Schwarzmann", aliases: [], parentage: "V. riparia × V. rupestris"),
        Entry(key: "110_richter", canonicalName: "110 Richter", displayName: "110 Richter", aliases: ["110R"], parentage: "V. berlandieri × V. rupestris"),
        Entry(key: "99_richter", canonicalName: "99 Richter", displayName: "99 Richter", aliases: ["99R"], parentage: "V. berlandieri × V. rupestris"),
        Entry(key: "1103_paulsen", canonicalName: "1103 Paulsen", displayName: "1103 Paulsen", aliases: ["1103P", "Paulsen"], parentage: "V. berlandieri × V. rupestris"),
        Entry(key: "140_ruggeri", canonicalName: "140 Ruggeri", displayName: "140 Ruggeri", aliases: ["140Ru", "140 Ru"], parentage: "V. berlandieri × V. rupestris"),
        Entry(key: "5bb_kober", canonicalName: "5BB Kober", displayName: "5BB Kober", aliases: ["Kober 5BB", "5BB"], parentage: "V. berlandieri × V. riparia"),
        Entry(key: "5c_teleki", canonicalName: "5C Teleki", displayName: "5C Teleki", aliases: ["Teleki 5C", "5C"], parentage: "V. berlandieri × V. riparia"),
        Entry(key: "so4", canonicalName: "SO4", displayName: "SO4", aliases: ["Selection Oppenheim 4"], parentage: "V. berlandieri × V. riparia"),
        Entry(key: "420a", canonicalName: "420A Mgt", displayName: "420A Mgt", aliases: ["420A"], parentage: "V. berlandieri × V. riparia"),
        Entry(key: "161_49c", canonicalName: "161-49 Couderc", displayName: "161-49 Couderc", aliases: ["161-49C"], parentage: "V. berlandieri × V. riparia"),
        Entry(key: "ramsey", canonicalName: "Ramsey", displayName: "Ramsey", aliases: ["Salt Creek"], parentage: "V. champinii"),
        Entry(key: "dog_ridge", canonicalName: "Dog Ridge", displayName: "Dog Ridge", aliases: [], parentage: "V. champinii"),
        Entry(key: "freedom", canonicalName: "Freedom", displayName: "Freedom", aliases: [], parentage: "Complex hybrid (1613 Couderc × Dog Ridge parentage)"),
        Entry(key: "harmony", canonicalName: "Harmony", displayName: "Harmony", aliases: [], parentage: "Complex hybrid (1613 Couderc × Dog Ridge parentage)"),
        Entry(key: "1613c", canonicalName: "1613 Couderc", displayName: "1613 Couderc", aliases: ["1613C"], parentage: "Complex hybrid (solonis × Othello)"),
        Entry(key: "k51_40", canonicalName: "K51-40", displayName: "K51-40", aliases: ["K51 40"], parentage: "V. champinii × V. riparia"),
        Entry(key: "riparia_gloire", canonicalName: "Riparia Gloire", displayName: "Riparia Gloire", aliases: ["Riparia Gloire de Montpellier"], parentage: "V. riparia"),
        Entry(key: "st_george", canonicalName: "Rupestris St George", displayName: "Rupestris St George", aliases: ["St George", "Rupestris du Lot"], parentage: "V. rupestris"),
        Entry(key: "borner", canonicalName: "Börner", displayName: "Börner", aliases: ["Borner"], parentage: "V. riparia × V. cinerea"),
        Entry(key: "fercal", canonicalName: "Fercal", displayName: "Fercal", aliases: [], parentage: "Complex hybrid (berlandieri × vinifera parentage)"),
        Entry(key: "gravesac", canonicalName: "Gravesac", displayName: "Gravesac", aliases: [], parentage: "161-49 Couderc × 3309 Couderc"),
        Entry(key: "merbein_5489", canonicalName: "Merbein 5489", displayName: "Merbein 5489", aliases: [], parentage: "CSIRO hybrid"),
        Entry(key: "merbein_5512", canonicalName: "Merbein 5512", displayName: "Merbein 5512", aliases: [], parentage: "CSIRO hybrid"),
        Entry(key: "merbein_6262", canonicalName: "Merbein 6262", displayName: "Merbein 6262", aliases: [], parentage: "CSIRO hybrid")
    ]

    /// Match legacy free text against canonical/display/aliases. Suggestion
    /// only — ambiguous text is never auto-mapped.
    static func entry(matching text: String) -> Entry? {
        let canonical = BuiltInGrapeVarietyCatalog.canonical(text)
        guard !canonical.isEmpty else { return nil }
        return entries.first { e in
            BuiltInGrapeVarietyCatalog.canonical(e.canonicalName) == canonical
                || BuiltInGrapeVarietyCatalog.canonical(e.displayName) == canonical
                || e.aliases.contains { BuiltInGrapeVarietyCatalog.canonical($0) == canonical }
        }
    }
}
