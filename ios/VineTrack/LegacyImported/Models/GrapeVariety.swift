import Foundation
import CryptoKit

nonisolated struct GrapeVariety: Codable, Identifiable, Sendable, Hashable {
    /// Stable identifier. Mutable so the canonicalization pass can
    /// migrate built-in varieties onto their deterministic id without
    /// losing the rest of the record.
    var id: UUID
    var vineyardId: UUID
    var name: String
    var optimalGDD: Double
    var isBuiltIn: Bool
    /// Stable slug for built-in varieties (e.g. "pinot_noir"). Optional so
    /// existing/user-created entries decode without it. Built-in varieties
    /// derive a deterministic `id` from `(vineyardId, key)`, so the same
    /// variety always resolves to the same id across devices/app resets.
    var key: String?

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String,
        optimalGDD: Double,
        isBuiltIn: Bool = false,
        key: String? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.optimalGDD = optimalGDD
        self.isBuiltIn = isBuiltIn
        self.key = key
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, optimalGDD, isBuiltIn, key
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        name = try c.decode(String.self, forKey: .name)
        optimalGDD = try c.decode(Double.self, forKey: .optimalGDD)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        key = try c.decodeIfPresent(String.self, forKey: .key)
    }
}

extension GrapeVariety {
    /// Deterministic UUIDv5-style id derived from `(vineyardId, key)`. Ensures
    /// the same built-in variety always has the same id within a vineyard,
    /// regardless of when/where it was seeded — so paddock allocations stay
    /// resolvable across devices and app resets.
    static func deterministicID(vineyardId: UUID, key: String) -> UUID {
        var data = Data()
        withUnsafeBytes(of: vineyardId.uuid) { data.append(contentsOf: $0) }
        data.append(Data(key.utf8))
        let digest = Insecure.MD5.hash(data: data)
        var bytes = Array(digest)
        // RFC 4122-style version 5 + variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    static func defaults(for vineyardId: UUID) -> [GrapeVariety] {
        BuiltInGrapeVarietyCatalog.entries.map { entry in
            GrapeVariety(
                id: deterministicID(vineyardId: vineyardId, key: entry.key),
                vineyardId: vineyardId,
                name: entry.name,
                optimalGDD: entry.optimalGDD,
                isBuiltIn: true,
                key: entry.key
            )
        }
    }
}

/// Stable catalog of built-in grape varieties. Slugs MUST remain stable —
/// they are part of the variety identity. Add new varieties at the end;
/// never repurpose an existing slug.
nonisolated enum BuiltInGrapeVarietyCatalog {
    struct Entry: Sendable, Hashable {
        let key: String
        let name: String
        let optimalGDD: Double
        /// Alternate display names (case/punct-insensitive) that should
        /// also resolve to this slug. Used to repair allocations whose
        /// `name` snapshot was written with a different spelling.
        let aliases: [String]
    }

    static let entries: [Entry] = [
        // Existing built-ins (alias merges mirror SQL migration 074).
        Entry(key: "chardonnay", name: "Chardonnay", optimalGDD: 1145, aliases: []),
        Entry(key: "pinot_gris", name: "Pinot Gris / Grigio", optimalGDD: 1100, aliases: ["Pinot Gris", "Pinot Grigio", "PG", "Grauburgunder", "Ruländer"]),
        Entry(key: "riesling", name: "Riesling", optimalGDD: 1200, aliases: ["Johannisberg Riesling", "White Riesling"]),
        Entry(key: "sauvignon_blanc", name: "Sauvignon Blanc", optimalGDD: 1150, aliases: ["Sauv Blanc", "Sav Blanc", "Savvy B", "Fumé Blanc", "Fume Blanc"]),
        Entry(key: "semillon", name: "Semillon", optimalGDD: 1200, aliases: ["Sémillon"]),
        Entry(key: "chenin_blanc", name: "Chenin Blanc", optimalGDD: 1250, aliases: ["Steen", "Pineau de la Loire"]),
        Entry(key: "gewurztraminer", name: "Gewurztraminer", optimalGDD: 1150, aliases: ["Gewürztraminer", "Traminer Aromatico"]),
        Entry(key: "viognier", name: "Viognier", optimalGDD: 1260, aliases: []),
        Entry(key: "shiraz", name: "Shiraz / Syrah", optimalGDD: 1255, aliases: ["Shiraz", "Syrah"]),
        Entry(key: "merlot", name: "Merlot", optimalGDD: 1250, aliases: []),
        Entry(key: "cabernet_franc", name: "Cabernet Franc", optimalGDD: 1255, aliases: ["Cab Franc", "Bouchet"]),
        Entry(key: "cabernet_sauvignon", name: "Cabernet Sauvignon", optimalGDD: 1310, aliases: ["Cab Sav", "Cab Sauv", "Cab"]),
        Entry(key: "pinot_noir", name: "Pinot Noir", optimalGDD: 1145, aliases: ["Spätburgunder", "Pinot Nero", "Blauburgunder"]),
        Entry(key: "tempranillo", name: "Tempranillo", optimalGDD: 1230, aliases: ["Tinta Roriz", "Aragonez", "Tinto Fino", "Cencibel"]),
        Entry(key: "sangiovese", name: "Sangiovese", optimalGDD: 1285, aliases: ["Brunello"]),
        Entry(key: "grenache", name: "Grenache / Garnacha", optimalGDD: 1365, aliases: ["Grenache", "Garnacha", "Cannonau", "Grenache Noir"]),
        Entry(key: "mataro_mourvedre", name: "Mataro / Mourvedre", optimalGDD: 1440, aliases: ["Mataro", "Mourvedre", "Mourvèdre", "Monastrell"]),
        Entry(key: "barbera", name: "Barbera", optimalGDD: 1285, aliases: []),
        Entry(key: "malbec", name: "Malbec", optimalGDD: 1230, aliases: ["Cot", "Côt", "Auxerrois"]),
        Entry(key: "colombard", name: "Colombard", optimalGDD: 1300, aliases: ["French Colombard"]),
        Entry(key: "muscat_gordo_blanco", name: "Muscat Gordo Blanco", optimalGDD: 1350, aliases: ["Muscat Gordo", "Muscat of Alexandria", "Moscatel de Alejandría"]),
        Entry(key: "fiano", name: "Fiano", optimalGDD: 1320, aliases: []),
        Entry(key: "prosecco", name: "Prosecco / Glera", optimalGDD: 1410, aliases: ["Prosecco", "Glera"]),
        Entry(key: "vermentino", name: "Vermentino", optimalGDD: 1290, aliases: ["Rolle", "Pigato"]),
        Entry(key: "gruner_veltliner", name: "Gruner Veltliner", optimalGDD: 1200, aliases: ["Grüner Veltliner", "Gruner", "GV"]),
        Entry(key: "primitivo", name: "Primitivo / Zinfandel", optimalGDD: 1200, aliases: ["Primitivo", "Zinfandel", "Zin", "Crljenak Kaštelanski"]),

        // New international whites.
        Entry(key: "albarino", name: "Albariño", optimalGDD: 1250, aliases: ["Albarino", "Alvarinho"]),
        Entry(key: "arneis", name: "Arneis", optimalGDD: 1280, aliases: []),
        Entry(key: "chasselas", name: "Chasselas", optimalGDD: 1150, aliases: ["Gutedel", "Fendant"]),
        Entry(key: "marsanne", name: "Marsanne", optimalGDD: 1290, aliases: []),
        Entry(key: "muscadelle", name: "Muscadelle", optimalGDD: 1250, aliases: []),
        Entry(key: "muscat_blanc", name: "Muscat Blanc", optimalGDD: 1280, aliases: ["Muscat Blanc à Petits Grains", "Muscat Blanc a Petits Grains", "Moscato Bianco", "Moscato", "Muscat Canelli"]),
        Entry(key: "palomino", name: "Palomino", optimalGDD: 1300, aliases: ["Palomino Fino", "Listán Blanco", "Listan Blanco"]),
        Entry(key: "pedro_ximenez", name: "Pedro Ximénez", optimalGDD: 1320, aliases: ["PX", "Pedro Ximenez"]),
        Entry(key: "picpoul", name: "Picpoul / Piquepoul", optimalGDD: 1250, aliases: ["Piquepoul", "Picpoul Blanc", "Piquepoul Blanc"]),
        Entry(key: "pinot_blanc", name: "Pinot Blanc", optimalGDD: 1150, aliases: ["Weissburgunder", "Weißburgunder", "Pinot Bianco"]),
        Entry(key: "roussanne", name: "Roussanne", optimalGDD: 1300, aliases: []),
        Entry(key: "trebbiano", name: "Trebbiano / Ugni Blanc", optimalGDD: 1290, aliases: ["Ugni Blanc", "Trebbiano Toscano", "St-Emilion"]),
        Entry(key: "verdejo", name: "Verdejo", optimalGDD: 1260, aliases: []),
        Entry(key: "verdelho", name: "Verdelho", optimalGDD: 1280, aliases: ["Verdello"]),

        // New international reds.
        Entry(key: "aglianico", name: "Aglianico", optimalGDD: 1400, aliases: []),
        Entry(key: "carmenere", name: "Carmenère", optimalGDD: 1370, aliases: ["Carmenere", "Grande Vidure"]),
        Entry(key: "cinsault", name: "Cinsault", optimalGDD: 1350, aliases: ["Cinsaut"]),
        Entry(key: "dolcetto", name: "Dolcetto", optimalGDD: 1230, aliases: []),
        Entry(key: "gamay", name: "Gamay", optimalGDD: 1100, aliases: ["Gamay Noir", "Gamay Noir à Jus Blanc"]),
        Entry(key: "montepulciano", name: "Montepulciano", optimalGDD: 1380, aliases: []),
        Entry(key: "nebbiolo", name: "Nebbiolo", optimalGDD: 1410, aliases: ["Spanna", "Chiavennasca", "Picotendro"]),
        Entry(key: "nero_davola", name: "Nero d'Avola", optimalGDD: 1420, aliases: ["Nero dAvola", "Nero d Avola", "Calabrese"]),
        Entry(key: "petit_verdot", name: "Petit Verdot", optimalGDD: 1390, aliases: []),
        Entry(key: "petite_sirah", name: "Petite Sirah / Durif", optimalGDD: 1390, aliases: ["Durif", "Petite Syrah", "Petite Sirah"]),
        Entry(key: "pinot_meunier", name: "Pinot Meunier", optimalGDD: 1100, aliases: ["Meunier", "Schwarzriesling"]),
        Entry(key: "touriga_nacional", name: "Touriga Nacional", optimalGDD: 1380, aliases: []),
        Entry(key: "zweigelt", name: "Zweigelt", optimalGDD: 1180, aliases: ["Blauer Zweigelt", "Rotburger"]),

        // Emerging / Australian / other useful.
        Entry(key: "assyrtiko", name: "Assyrtiko", optimalGDD: 1320, aliases: []),
        Entry(key: "chambourcin", name: "Chambourcin", optimalGDD: 1280, aliases: []),
        Entry(key: "furmint", name: "Furmint", optimalGDD: 1280, aliases: []),
        Entry(key: "lagrein", name: "Lagrein", optimalGDD: 1350, aliases: []),
        Entry(key: "mencia", name: "Mencía", optimalGDD: 1300, aliases: ["Mencia", "Jaen"]),
        Entry(key: "savagnin", name: "Savagnin", optimalGDD: 1200, aliases: ["Traminer", "Heida", "Païen"]),
        Entry(key: "tannat", name: "Tannat", optimalGDD: 1430, aliases: [])
    ]

    /// Canonical-name → entry index (built once).
    static let entriesByCanonicalName: [String: Entry] = {
        var map: [String: Entry] = [:]
        for entry in entries {
            map[canonical(entry.name)] = entry
            for alias in entry.aliases {
                map[canonical(alias)] = entry
            }
        }
        return map
    }()

    /// Same canonicalisation rule used by `PaddockVarietyResolver` /
    /// `RipenessVarietyResolver`. Kept in sync intentionally.
    static func canonical(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics
        return String(trimmed.unicodeScalars.filter { allowed.contains($0) })
    }

    /// Find the built-in catalog entry that matches a free-form name. Uses
    /// canonical comparison + alias table. Returns nil for unknown names.
    static func entry(matching name: String) -> Entry? {
        entriesByCanonicalName[canonical(name)]
    }
}

nonisolated struct PaddockVarietyAllocation: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var varietyId: UUID
    var percent: Double
    /// Optional display-name snapshot. Populated when the allocation is
    /// resolved against the managed `GrapeVariety` list, or when remote
    /// systems (e.g. the Lovable web portal) write a `name`/`variety`
    /// name string alongside the id. Used by
    /// `PaddockVarietyResolver` as a fallback when the id no longer
    /// matches a managed variety (e.g. local-only varieties seeded with
    /// different UUIDs across devices).
    var name: String?
    /// Stable catalog key (e.g. `pinot_gris`) or vineyard-scoped custom
    /// key (`custom:<vineyardId>:<slug>`). Carries the allocation's
    /// identity across devices, resets, and id drift — the resolver
    /// trusts this before `varietyId` or `name`.
    var varietyKey: String?
    /// Optional reference-only clone designation for this allocation
    /// (e.g. `MV6`). Display-only — never used in spray, trip, row,
    /// yield, irrigation, geometry, or validation logic.
    var clone: String?
    /// Optional reference-only rootstock designation for this allocation
    /// (e.g. `101-14`). Display-only — same constraints as `clone`.
    var rootstock: String?

    init(
        id: UUID = UUID(),
        varietyId: UUID,
        percent: Double,
        name: String? = nil,
        varietyKey: String? = nil,
        clone: String? = nil,
        rootstock: String? = nil
    ) {
        self.id = id
        self.varietyId = varietyId
        self.percent = percent
        self.name = name
        self.varietyKey = varietyKey
        self.clone = clone
        self.rootstock = rootstock
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case varietyId
        case percent
        case name
        case varietyKey
        case clone
        case rootstock
        // Tolerant aliases for payloads written by other systems.
        case variety_id
        case variety
        case varietyName
        case variety_key
        case key
        case root_stock
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()

        // Variety id: accept `varietyId`, `variety_id`, or a UUID-shaped
        // `variety` value. Fall back to a placeholder UUID so the model
        // still decodes — the resolver will fall back to name matching.
        if let v = try? c.decode(UUID.self, forKey: .varietyId) {
            varietyId = v
        } else if let v = try? c.decode(UUID.self, forKey: .variety_id) {
            varietyId = v
        } else if let v = try? c.decode(UUID.self, forKey: .variety) {
            varietyId = v
        } else if let s = try? c.decode(String.self, forKey: .varietyId),
                  let v = UUID(uuidString: s) {
            varietyId = v
        } else if let s = try? c.decode(String.self, forKey: .variety_id),
                  let v = UUID(uuidString: s) {
            varietyId = v
        } else {
            varietyId = UUID()
        }

        percent = (try? c.decode(Double.self, forKey: .percent)) ?? 0

        // Optional name snapshot. Accept `name`, `varietyName`, or
        // `variety` when it is not a UUID string.
        if let n = try? c.decode(String.self, forKey: .name),
           !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = n
        } else if let n = try? c.decode(String.self, forKey: .varietyName),
                  !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = n
        } else if let n = try? c.decode(String.self, forKey: .variety),
                  UUID(uuidString: n) == nil,
                  !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = n
        } else {
            name = nil
        }

        // Optional stable key. Accept `varietyKey`, `variety_key`, or `key`.
        if let k = try? c.decode(String.self, forKey: .varietyKey),
           !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            varietyKey = k
        } else if let k = try? c.decode(String.self, forKey: .variety_key),
                  !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            varietyKey = k
        } else if let k = try? c.decode(String.self, forKey: .key),
                  !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            varietyKey = k
        } else {
            varietyKey = nil
        }

        // Optional reference-only clone. Empty/whitespace decodes to nil.
        if let c0 = try? c.decode(String.self, forKey: .clone),
           !c0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clone = c0.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            clone = nil
        }

        // Optional reference-only rootstock. Accept `rootstock` or
        // `root_stock`. Empty/whitespace decodes to nil.
        if let r = try? c.decode(String.self, forKey: .rootstock),
           !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rootstock = r.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let r = try? c.decode(String.self, forKey: .root_stock),
                  !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rootstock = r.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            rootstock = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(varietyId, forKey: .varietyId)
        try c.encode(percent, forKey: .percent)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(varietyKey, forKey: .varietyKey)
        try c.encodeIfPresent(clone, forKey: .clone)
        try c.encodeIfPresent(rootstock, forKey: .rootstock)
    }
}
