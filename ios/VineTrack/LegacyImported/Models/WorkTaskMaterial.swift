import Foundation

/// Work Task Material Costs — domain models (sql/247).
///
/// The whole concept is `material + quantity + unit + unit cost = material cost`.
/// This is NOT inventory: there is no stock on hand, no supplier, no purchase,
/// no pack conversion and no tax anywhere in this file.
///
/// Three layers, mirroring the database exactly:
///
///  1. ``MaterialCatalogueItem``  — the global VineTrack base catalogue
///     (`public.material_catalogue`). High level, system owned, price free.
///  2. ``VineyardMaterial``       — one vineyard's library
///     (`public.vineyard_materials`): its own default costs for base items,
///     plus its own custom materials. Prices live HERE.
///  3. ``WorkTaskMaterial``       — what was actually used on a task
///     (`public.work_task_materials`), carrying a FROZEN snapshot.
///
/// Money is `Decimal` throughout — never `Double`. The authoritative stored
/// values are Postgres `numeric`; `Decimal` is the only Swift type that can
/// round-trip them without binary floating-point drift.

// MARK: - Units

/// Suggested units. Deliberately NOT an enum end-to-end: the database column
/// is free text so a vineyard can be given a new unit later without a
/// migration. This list only drives suggestions.
nonisolated enum MaterialUnitCatalog {
    static let suggested: [String] = ["Each", "Metre", "Roll", "Pack", "Box", "Bag"]

    /// Trim, and fall back to `Each` when a caller supplies nothing. The
    /// database rejects a blank unit; this keeps the client from ever
    /// attempting that write.
    static func normalised(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Each" : trimmed
    }
}

// MARK: - Categories

/// The base catalogue's category names. Free text in the database (so a
/// vineyard's custom material can sit anywhere), listed here only for stable
/// display ordering.
nonisolated enum MaterialCategoryCatalog {
    static let trellis = "Trellis"
    static let fasteners = "Fasteners & Training"
    static let netting = "Netting & Protection"
    static let irrigation = "Irrigation"
    static let establishment = "Vine Establishment"
    static let other = "Other"

    static let ordered: [String] = [trellis, fasteners, netting, irrigation, establishment, other]

    /// Sort index for a category name; unknown (vineyard-invented) categories
    /// sort after the known ones rather than being hidden.
    static func order(of category: String) -> Int {
        ordered.firstIndex(of: category) ?? ordered.count
    }
}

// MARK: - Money decoding

/// PostgREST returns `numeric` as a JSON number, but a cached payload may hold
/// a string. Both decode to the same `Decimal` without going through `Double`,
/// which is the only way a money value survives the round trip exactly.
nonisolated enum MaterialMoney {
    static func decimal<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> Decimal? {
        if let value = try? container.decodeIfPresent(Decimal.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key), !text.isEmpty {
            return Decimal(string: text)
        }
        return nil
    }

    /// `quantity × unitCost`, rounded to 2 decimal places half-up — the same
    /// arithmetic the generated `work_task_materials.total_cost` column does.
    static func lineTotal(quantity: Decimal, unitCost: Decimal) -> Decimal {
        var raw = quantity * unitCost
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 2, .plain)
        return rounded
    }
}

// MARK: - A. Base catalogue

/// One row of the global VineTrack base catalogue (`public.material_catalogue`).
///
/// IDENTITY IS ``key``, not the row UUID. The server mints its own UUIDs, so a
/// bundled offline copy cannot know them — but Supabase, iOS and Android all
/// agree on the key. `remoteId` is the server row id once known, and is
/// required before a vineyard OVERRIDE can be written (the database's
/// `vineyard_materials_custom_shape` check needs a real `base_material_id`).
nonisolated struct MaterialCatalogueItem: Codable, Identifiable, Sendable, Hashable {
    /// Stable cross-platform identity, e.g. `material.trellis.gripple`.
    var key: String
    /// Server row id. Nil for the bundled offline fallback until the
    /// catalogue has synced at least once.
    var remoteId: UUID?
    var name: String
    var category: String
    var defaultUnit: String
    var sortOrder: Int
    var isActive: Bool

    var id: String { key }

    init(
        key: String,
        remoteId: UUID? = nil,
        name: String,
        category: String,
        defaultUnit: String,
        sortOrder: Int,
        isActive: Bool = true
    ) {
        self.key = key
        self.remoteId = remoteId
        self.name = name
        self.category = category
        self.defaultUnit = defaultUnit
        self.sortOrder = sortOrder
        self.isActive = isActive
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case key, remoteId, name, category, defaultUnit, sortOrder, isActive
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        remoteId = try c.decodeIfPresent(UUID.self, forKey: .remoteId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? MaterialCategoryCatalog.other
        defaultUnit = MaterialUnitCatalog.normalised(try c.decodeIfPresent(String.self, forKey: .defaultUnit))
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
}

/// The bundled offline copy of the base catalogue.
///
/// VineTrack is offline first, so a fresh install with no connectivity must
/// still be able to open a material picker. These entries use the EXACT keys,
/// names, categories, units and sort orders seeded by sql/247, so a synced
/// server catalogue simply replaces like with like — the same material is
/// never two different materials across Supabase, iOS and Android.
///
/// A successfully synced server catalogue is authoritative and wins.
nonisolated enum MaterialCatalogueSeed {
    static let items: [MaterialCatalogueItem] = [
        // Trellis
        .init(key: "material.trellis.line_post", name: "Line / Trellis Post",
              category: MaterialCategoryCatalog.trellis, defaultUnit: "Each", sortOrder: 10),
        .init(key: "material.trellis.end_post", name: "End / Strainer Post",
              category: MaterialCategoryCatalog.trellis, defaultUnit: "Each", sortOrder: 20),
        .init(key: "material.trellis.wire", name: "Trellis Wire",
              category: MaterialCategoryCatalog.trellis, defaultUnit: "Metre", sortOrder: 30),
        .init(key: "material.trellis.anchor", name: "Anchor / Stay",
              category: MaterialCategoryCatalog.trellis, defaultUnit: "Each", sortOrder: 40),
        .init(key: "material.trellis.gripple", name: "Gripple / Wire Joiner-Tensioner",
              category: MaterialCategoryCatalog.trellis, defaultUnit: "Each", sortOrder: 50),
        // Fasteners & Training
        .init(key: "material.fastener.trellis_clip", name: "Trellis Clip / Staple",
              category: MaterialCategoryCatalog.fasteners, defaultUnit: "Each", sortOrder: 60),
        .init(key: "material.fastener.vine_tie", name: "Vine / Wire Tie",
              category: MaterialCategoryCatalog.fasteners, defaultUnit: "Each", sortOrder: 70),
        .init(key: "material.fastener.zip_tie", name: "Cable / Zip Tie",
              category: MaterialCategoryCatalog.fasteners, defaultUnit: "Each", sortOrder: 80),
        // Netting & Protection
        .init(key: "material.netting.post_cap", name: "Post / Netting Cap",
              category: MaterialCategoryCatalog.netting, defaultUnit: "Each", sortOrder: 90),
        .init(key: "material.netting.bird_netting", name: "Bird Netting",
              category: MaterialCategoryCatalog.netting, defaultUnit: "Metre", sortOrder: 100),
        .init(key: "material.netting.clip_repair", name: "Netting Clip / Repair Material",
              category: MaterialCategoryCatalog.netting, defaultUnit: "Each", sortOrder: 110),
        // Irrigation
        .init(key: "material.irrigation.dripline", name: "Dripline / Poly Pipe",
              category: MaterialCategoryCatalog.irrigation, defaultUnit: "Metre", sortOrder: 120),
        .init(key: "material.irrigation.dripper", name: "Dripper / Emitter",
              category: MaterialCategoryCatalog.irrigation, defaultUnit: "Each", sortOrder: 130),
        .init(key: "material.irrigation.fitting", name: "Irrigation Fitting / Repair Joiner",
              category: MaterialCategoryCatalog.irrigation, defaultUnit: "Each", sortOrder: 140),
        // Vine Establishment
        .init(key: "material.establishment.vine_stake", name: "Vine Stake",
              category: MaterialCategoryCatalog.establishment, defaultUnit: "Each", sortOrder: 150),
        .init(key: "material.establishment.vine_guard", name: "Vine Guard",
              category: MaterialCategoryCatalog.establishment, defaultUnit: "Each", sortOrder: 160),
        .init(key: "material.establishment.vine", name: "Replacement Vine",
              category: MaterialCategoryCatalog.establishment, defaultUnit: "Each", sortOrder: 170),
        // Other
        .init(key: "material.other.miscellaneous", name: "Other / Miscellaneous Material",
              category: MaterialCategoryCatalog.other, defaultUnit: "Each", sortOrder: 180),
    ]

    /// Every seeded key, for parity assertions against Android and the database.
    static var keys: [String] { items.map(\.key) }

    /// A successfully synced server catalogue is authoritative — including an
    /// empty one being impossible in practice, an EMPTY read is still treated
    /// as "nothing to show" only when it came from the server. Offline (nil)
    /// falls back to the bundle so a picker is never blank on a fresh install.
    static func resolve(server: [MaterialCatalogueItem]?, cached: [MaterialCatalogueItem]?) -> [MaterialCatalogueItem] {
        if let server, !server.isEmpty { return server }
        if let cached, !cached.isEmpty { return cached }
        return items
    }
}

// MARK: - B. Vineyard material library

/// One row of a vineyard's own material library (`public.vineyard_materials`).
///
/// Two shapes, enforced by the database's `vineyard_materials_custom_shape`
/// check and mirrored by ``isCustom``:
///
///  * OVERRIDE of a base item — `baseMaterialId` set, `isCustom == false`.
///    "Gripple / Wire Joiner-Tensioner · $1.82 Each".
///  * CUSTOM vineyard material — `baseMaterialId == nil`, `isCustom == true`.
///    "Gripple Plus Medium · $2.15 Each".
///
/// `defaultUnitCost` and `unit` are DEFAULTS applied when the material is added
/// to a task. Changing them later never rewrites a ``WorkTaskMaterial``.
nonisolated struct VineyardMaterial: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var vineyardId: UUID
    /// Server id of the base catalogue row this overrides. Nil for a custom
    /// material.
    var baseMaterialId: UUID?
    /// The base catalogue KEY this overrides, carried locally so an override
    /// still resolves to the right base item when only the bundled catalogue
    /// is available. Nil for a custom material.
    var baseMaterialKey: String?
    var name: String
    var category: String
    var unit: String
    var defaultUnitCost: Decimal?
    var isCustom: Bool
    var isActive: Bool

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        baseMaterialId: UUID? = nil,
        baseMaterialKey: String? = nil,
        name: String,
        category: String = "",
        unit: String,
        defaultUnitCost: Decimal? = nil,
        isCustom: Bool,
        isActive: Bool = true
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.baseMaterialId = baseMaterialId
        self.baseMaterialKey = baseMaterialKey
        self.name = name
        self.category = category
        self.unit = MaterialUnitCatalog.normalised(unit)
        self.defaultUnitCost = defaultUnitCost
        self.isCustom = isCustom
        self.isActive = isActive
    }

    /// A vineyard's own default cost for a BASE catalogue item.
    ///
    /// Requires the base row's server id: the database refuses a non-custom row
    /// without one, so an override is only offered once the catalogue has
    /// synced. Offline, a vineyard can still add a custom material.
    static func override(
        vineyardId: UUID,
        base: MaterialCatalogueItem,
        unit: String? = nil,
        defaultUnitCost: Decimal?,
        id: UUID = UUID()
    ) -> VineyardMaterial? {
        guard let remoteId = base.remoteId else { return nil }
        return VineyardMaterial(
            id: id,
            vineyardId: vineyardId,
            baseMaterialId: remoteId,
            baseMaterialKey: base.key,
            name: base.name,
            category: base.category,
            unit: MaterialUnitCatalog.normalised(unit ?? base.defaultUnit),
            defaultUnitCost: defaultUnitCost,
            isCustom: false
        )
    }

    /// A material that belongs only to this vineyard and is reusable across
    /// its Work Tasks.
    static func custom(
        vineyardId: UUID,
        name: String,
        category: String = MaterialCategoryCatalog.other,
        unit: String,
        defaultUnitCost: Decimal?,
        id: UUID = UUID()
    ) -> VineyardMaterial {
        VineyardMaterial(
            id: id,
            vineyardId: vineyardId,
            baseMaterialId: nil,
            baseMaterialKey: nil,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            unit: unit,
            defaultUnitCost: defaultUnitCost,
            isCustom: true
        )
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, baseMaterialId, baseMaterialKey
        case name, category, unit, defaultUnitCost, isCustom, isActive
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        baseMaterialId = try c.decodeIfPresent(UUID.self, forKey: .baseMaterialId)
        baseMaterialKey = try c.decodeIfPresent(String.self, forKey: .baseMaterialKey)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        unit = MaterialUnitCatalog.normalised(try c.decodeIfPresent(String.self, forKey: .unit))
        defaultUnitCost = MaterialMoney.decimal(from: c, forKey: .defaultUnitCost)
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? (baseMaterialId == nil)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
}

// MARK: - C. Work Task material line

/// One material line on a Work Task (`public.work_task_materials`).
///
/// ## The historical rule
///
/// `materialName`, `category`, `unit`, `quantity` and `unitCost` are a
/// SNAPSHOT owned by the task from the moment the material was added.
/// `baseMaterialId` / `vineyardMaterialId` are provenance only — both may go
/// nil (the database sets them null on delete) and the line still reads
/// correctly from its own snapshot.
///
/// ```text
/// Today:      Trellis Post · 3 Each · $12.40  =  $37.20
/// Library repriced to $14.50 next season
/// Still:      Trellis Post · 3 Each · $12.40  =  $37.20
/// ```
nonisolated struct WorkTaskMaterial: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var workTaskId: UUID
    var vineyardId: UUID

    /// Provenance only — never required to read or cost this line.
    var baseMaterialId: UUID?
    /// Provenance only — never required to read or cost this line.
    var vineyardMaterialId: UUID?

    /// Frozen at the moment the material was placed on the task.
    var materialName: String
    var category: String
    var unit: String
    var quantity: Decimal
    var unitCost: Decimal

    var notes: String

    init(
        id: UUID = UUID(),
        workTaskId: UUID,
        vineyardId: UUID,
        baseMaterialId: UUID? = nil,
        vineyardMaterialId: UUID? = nil,
        materialName: String,
        category: String = "",
        unit: String,
        quantity: Decimal = 0,
        unitCost: Decimal = 0,
        notes: String = ""
    ) {
        self.id = id
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.baseMaterialId = baseMaterialId
        self.vineyardMaterialId = vineyardMaterialId
        self.materialName = materialName
        self.category = category
        self.unit = MaterialUnitCatalog.normalised(unit)
        self.quantity = quantity
        self.unitCost = unitCost
        self.notes = notes
    }

    /// `quantity × unitCost`, rounded to 2dp — identical to the generated
    /// `total_cost` column, so a device and the server can never disagree.
    var totalCost: Decimal {
        MaterialMoney.lineTotal(quantity: quantity, unitCost: unitCost)
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, workTaskId, vineyardId, baseMaterialId, vineyardMaterialId
        case materialName, category, unit, quantity, unitCost, notes
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workTaskId = try c.decode(UUID.self, forKey: .workTaskId)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        baseMaterialId = try c.decodeIfPresent(UUID.self, forKey: .baseMaterialId)
        vineyardMaterialId = try c.decodeIfPresent(UUID.self, forKey: .vineyardMaterialId)
        materialName = try c.decodeIfPresent(String.self, forKey: .materialName) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        unit = MaterialUnitCatalog.normalised(try c.decodeIfPresent(String.self, forKey: .unit))
        quantity = MaterialMoney.decimal(from: c, forKey: .quantity) ?? 0
        unitCost = MaterialMoney.decimal(from: c, forKey: .unitCost) ?? 0
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

// MARK: - Library merge (catalogue + vineyard)

/// One selectable entry in a vineyard's effective material library: a base
/// catalogue item, a base item the vineyard has priced, or a vineyard-only
/// custom material.
nonisolated struct MaterialLibraryEntry: Identifiable, Sendable, Hashable {
    /// `material.<...>` for a base item (priced or not), or the vineyard
    /// material's UUID string for a custom item.
    var id: String
    var name: String
    var category: String
    var unit: String
    var defaultUnitCost: Decimal?
    var baseMaterialKey: String?
    var baseMaterialId: UUID?
    var vineyardMaterialId: UUID?
    var isCustom: Bool
    var sortOrder: Int

    /// Seed a task line from this library entry. The entry's unit and default
    /// cost become the line's OWN snapshot from here on.
    func makeTaskMaterial(
        workTaskId: UUID,
        vineyardId: UUID,
        quantity: Decimal,
        unitCost: Decimal? = nil,
        unit: String? = nil,
        notes: String = "",
        id: UUID = UUID()
    ) -> WorkTaskMaterial {
        WorkTaskMaterial(
            id: id,
            workTaskId: workTaskId,
            vineyardId: vineyardId,
            baseMaterialId: baseMaterialId,
            vineyardMaterialId: vineyardMaterialId,
            materialName: name,
            category: category,
            unit: MaterialUnitCatalog.normalised(unit ?? self.unit),
            quantity: quantity,
            unitCost: unitCost ?? defaultUnitCost ?? 0,
            notes: notes
        )
    }
}

nonisolated enum MaterialLibrary {

    /// Merge the base catalogue with a vineyard's overrides and custom items
    /// AT READ TIME.
    ///
    /// This is why no vineyard is pre-populated with eighteen empty rows: a
    /// vineyard row only exists once someone actually sets a price or adds a
    /// custom material. An override replaces its base entry in place (keeping
    /// the base sort order); custom materials follow, ordered by category then
    /// name. Inactive entries on either side are excluded from selection, but
    /// nothing here touches historical task lines.
    static func merged(
        catalogue: [MaterialCatalogueItem],
        vineyardMaterials: [VineyardMaterial],
        vineyardId: UUID
    ) -> [MaterialLibraryEntry] {
        let scoped = vineyardMaterials.filter { $0.vineyardId == vineyardId && $0.isActive }
        var overridesByKey: [String: VineyardMaterial] = [:]
        var overridesById: [UUID: VineyardMaterial] = [:]
        for material in scoped where !material.isCustom {
            if let key = material.baseMaterialKey { overridesByKey[key] = material }
            if let baseId = material.baseMaterialId { overridesById[baseId] = material }
        }

        var entries: [MaterialLibraryEntry] = []

        for item in catalogue.filter(\.isActive).sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let match = overridesByKey[item.key] ?? item.remoteId.flatMap { overridesById[$0] }
            entries.append(
                MaterialLibraryEntry(
                    id: item.key,
                    name: match?.name.isEmpty == false ? (match?.name ?? item.name) : item.name,
                    category: item.category,
                    unit: match?.unit ?? item.defaultUnit,
                    defaultUnitCost: match?.defaultUnitCost,
                    baseMaterialKey: item.key,
                    baseMaterialId: match?.baseMaterialId ?? item.remoteId,
                    vineyardMaterialId: match?.id,
                    isCustom: false,
                    sortOrder: item.sortOrder
                )
            )
        }

        let customs = scoped.filter(\.isCustom).sorted { lhs, rhs in
            let lo = MaterialCategoryCatalog.order(of: lhs.category)
            let ro = MaterialCategoryCatalog.order(of: rhs.category)
            if lo != ro { return lo < ro }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        for (offset, custom) in customs.enumerated() {
            entries.append(
                MaterialLibraryEntry(
                    id: custom.id.uuidString,
                    name: custom.name,
                    category: custom.category.isEmpty ? MaterialCategoryCatalog.other : custom.category,
                    unit: custom.unit,
                    defaultUnitCost: custom.defaultUnitCost,
                    baseMaterialKey: nil,
                    baseMaterialId: nil,
                    vineyardMaterialId: custom.id,
                    isCustom: true,
                    sortOrder: 1_000 + offset
                )
            )
        }

        return entries
    }
}

// MARK: - Costing

/// Material cost roll-ups. Structured so later reporting (per task, per block,
/// per vineyard, per hectare, per category, per season) needs no schema change
/// — but NO report is built in this phase.
nonisolated enum WorkTaskMaterialCosting {

    /// Active material lines of ONE task, in stable display order.
    static func lines(_ all: [WorkTaskMaterial], for workTaskId: UUID) -> [WorkTaskMaterial] {
        all.filter { $0.workTaskId == workTaskId }
            .sorted { lhs, rhs in
                let lo = MaterialCategoryCatalog.order(of: lhs.category)
                let ro = MaterialCategoryCatalog.order(of: rhs.category)
                if lo != ro { return lo < ro }
                return lhs.materialName.localizedCaseInsensitiveCompare(rhs.materialName) == .orderedAscending
            }
    }

    /// Total material cost of one task.
    ///
    /// A task with no material lines costs `0` — it does NOT need a row to say
    /// so, which is exactly why Material Costs is additive and optional.
    static func total(_ all: [WorkTaskMaterial], for workTaskId: UUID) -> Decimal {
        all.filter { $0.workTaskId == workTaskId }
            .reduce(Decimal(0)) { $0 + $1.totalCost }
    }

    /// Total across any supplied set of lines (a vineyard slice, a season
    /// filter, a block's tasks — the caller decides the scope).
    static func total(_ lines: [WorkTaskMaterial]) -> Decimal {
        lines.reduce(Decimal(0)) { $0 + $1.totalCost }
    }

    /// Material cost grouped by the FROZEN category on each line, so a later
    /// category rename can never retro-reclassify historical spend.
    static func totalByCategory(_ lines: [WorkTaskMaterial]) -> [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for line in lines {
            let key = line.category.isEmpty ? MaterialCategoryCatalog.other : line.category
            totals[key, default: 0] += line.totalCost
        }
        return totals
    }
}
