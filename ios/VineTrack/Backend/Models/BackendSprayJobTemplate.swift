import Foundation

/// A reusable spray template row from `public.spray_jobs` (`is_template = true`).
///
/// These rows are created by the Lovable admin portal, so the decoder is
/// deliberately tolerant: templates routinely arrive with `status = 'draft'`,
/// `planned_date = null`, `created_by = null`, and most operational fields
/// (water volume, rates, equipment, canopy) missing. A template must never be
/// dropped because an optional field is null or slightly mis-typed.
nonisolated struct BackendSprayJobTemplate: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let status: String?
    /// Kept as a raw `yyyy-MM-dd` string (Postgres `date`) — templates have no
    /// planned date and the value is display-irrelevant on mobile.
    let plannedDate: String?
    let chemicalLines: [SprayJobChemicalLine]
    let waterVolume: Double?
    let sprayRatePerHa: Double?
    let concentrationFactor: Double?
    let operationType: String?
    let target: String?
    let notes: String?
    let growthStageCode: String?
    let equipmentId: UUID?
    let tractorId: UUID?
    let createdBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case status
        case plannedDate = "planned_date"
        case chemicalLines = "chemical_lines"
        case waterVolume = "water_volume"
        case sprayRatePerHa = "spray_rate_per_ha"
        case concentrationFactor = "concentration_factor"
        case operationType = "operation_type"
        case target
        case notes
        case growthStageCode = "growth_stage_code"
        case equipmentId = "equipment_id"
        case tractorId = "tractor_id"
        case createdBy = "created_by"
    }

    /// Explicit memberwise init — the custom `init(from:)` suppresses the
    /// synthesised one, and the mobile Program Step editor needs to project an
    /// already-persisted update onto the cached row.
    nonisolated init(
        id: UUID,
        vineyardId: UUID,
        name: String,
        status: String? = nil,
        plannedDate: String? = nil,
        chemicalLines: [SprayJobChemicalLine] = [],
        waterVolume: Double? = nil,
        sprayRatePerHa: Double? = nil,
        concentrationFactor: Double? = nil,
        operationType: String? = nil,
        target: String? = nil,
        notes: String? = nil,
        growthStageCode: String? = nil,
        equipmentId: UUID? = nil,
        tractorId: UUID? = nil,
        createdBy: UUID? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.status = status
        self.plannedDate = plannedDate
        self.chemicalLines = chemicalLines
        self.waterVolume = waterVolume
        self.sprayRatePerHa = sprayRatePerHa
        self.concentrationFactor = concentrationFactor
        self.operationType = operationType
        self.target = target
        self.notes = notes
        self.growthStageCode = growthStageCode
        self.equipmentId = equipmentId
        self.tractorId = tractorId
        self.createdBy = createdBy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        plannedDate = try? container.decodeIfPresent(String.self, forKey: .plannedDate)
        let lossyLines = (try? container.decodeIfPresent([LossyChemicalLine].self, forKey: .chemicalLines)) ?? nil
        chemicalLines = lossyLines?.compactMap(\.value) ?? []
        waterVolume = Self.flexibleDouble(container, .waterVolume)
        sprayRatePerHa = Self.flexibleDouble(container, .sprayRatePerHa)
        concentrationFactor = Self.flexibleDouble(container, .concentrationFactor)
        operationType = try? container.decodeIfPresent(String.self, forKey: .operationType)
        target = try? container.decodeIfPresent(String.self, forKey: .target)
        notes = try? container.decodeIfPresent(String.self, forKey: .notes)
        growthStageCode = try? container.decodeIfPresent(String.self, forKey: .growthStageCode)
        equipmentId = try? container.decodeIfPresent(UUID.self, forKey: .equipmentId)
        tractorId = try? container.decodeIfPresent(UUID.self, forKey: .tractorId)
        createdBy = try? container.decodeIfPresent(UUID.self, forKey: .createdBy)
    }

    /// Postgres `numeric` columns normally arrive as JSON numbers, but decode
    /// string payloads too so a portal-written row can never break sync.
    private static func flexibleDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) { return Double(raw) }
        return nil
    }
}

/// One line of the `spray_jobs.chemical_lines` JSONB array. The portal and
/// Excel import write snake_case keys (`chemical_id`, `rate`, `unit`,
/// `water_rate`) but the decoder also accepts camelCase variants defensively.
nonisolated struct SprayJobChemicalLine: Codable, Sendable, Equatable {
    let chemicalId: UUID?
    let name: String
    let activeIngredient: String?
    let rate: Double?
    let unit: String?
    let waterRate: Double?
    let notes: String?
    /// The product's chemistry FROZEN when this job line was created (sql/201).
    ///
    /// Additive inside the existing `chemical_lines` JSONB — no column, no
    /// migration. It exists because `chemical_id` + `name` are a POINTER, and a
    /// pointer is re-read: re-verifying or correcting the Saved Chemical after a
    /// job was created would silently restate what that job was created to apply,
    /// including its resistance groups. Freezing the actives and their
    /// scheme-qualified FRAC/HRAC/IRAC classification here keeps the job's
    /// chemistry answerable to the day it was planned.
    ///
    /// Nil is legitimate: a position planned as a bare group has no product to
    /// freeze, and inventing one would be worse than the absence.
    let chemicalSnapshot: ChemicalLineSnapshot?

    enum CodingKeys: String, CodingKey {
        case chemicalId = "chemical_id"
        case name
        case activeIngredient = "active_ingredient"
        case rate
        case unit
        case waterRate = "water_rate"
        case notes
        case chemicalSnapshot = "chemical_snapshot"
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Explicit memberwise init — the custom `init(from:)` suppresses the
    /// synthesised one, and Stage 5B (plan -> spray job) constructs lines
    /// directly when prefilling a job from a resistance plan position.
    nonisolated init(
        chemicalId: UUID? = nil,
        name: String,
        activeIngredient: String? = nil,
        rate: Double? = nil,
        unit: String? = nil,
        waterRate: Double? = nil,
        notes: String? = nil,
        chemicalSnapshot: ChemicalLineSnapshot? = nil
    ) {
        self.chemicalId = chemicalId
        self.name = name
        self.activeIngredient = activeIngredient
        self.rate = rate
        self.unit = unit
        self.waterRate = waterRate
        self.notes = notes
        self.chemicalSnapshot = chemicalSnapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)

        func string(_ keys: [String]) -> String? {
            for key in keys {
                guard let anyKey = AnyKey(stringValue: key) else { continue }
                if let value = try? container.decodeIfPresent(String.self, forKey: anyKey),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        func double(_ keys: [String]) -> Double? {
            for key in keys {
                guard let anyKey = AnyKey(stringValue: key) else { continue }
                if let value = try? container.decodeIfPresent(Double.self, forKey: anyKey) {
                    return value
                }
                if let raw = try? container.decodeIfPresent(String.self, forKey: anyKey),
                   let value = Double(raw) {
                    return value
                }
            }
            return nil
        }

        chemicalId = string(["chemical_id", "chemicalId", "saved_chemical_id", "savedChemicalId"])
            .flatMap(UUID.init(uuidString:))
        name = string(["name", "product_name", "productName", "product", "chemical_name", "chemicalName"]) ?? ""
        activeIngredient = string(["active_ingredient", "activeIngredient"])
        rate = double(["rate", "rate_per_ha", "ratePerHa", "rate_value", "amount"])
        unit = string(["unit", "rate_unit", "rateUnit"])
        waterRate = double(["water_rate", "waterRate"])
        notes = string(["notes", "note"])
        // Tolerant, like every other field here: a portal write that omits or
        // mangles the frozen chemistry must cost the line its snapshot, never
        // the whole job.
        chemicalSnapshot = AnyKey(stringValue: "chemical_snapshot").flatMap { key in
            (try? container.decodeIfPresent(ChemicalLineSnapshot.self, forKey: key)) ?? nil
        }
    }
}

/// Lossy per-line wrapper: a malformed chemical line is skipped instead of
/// failing the whole template row.
nonisolated private struct LossyChemicalLine: Decodable, Sendable {
    let value: SprayJobChemicalLine?
    init(from decoder: Decoder) throws {
        value = try? SprayJobChemicalLine(from: decoder)
    }
}

extension BackendSprayJobTemplate {
    /// Parse a free-text chemical line unit ("L/ha", "mL/100L", "kg/ha", "g")
    /// into the strict `ChemicalUnit` enum plus a per-100L basis flag.
    nonisolated static func parseLineUnit(_ raw: String?) -> (unit: ChemicalUnit, per100L: Bool) {
        let lowered = (raw ?? "").lowercased()
        let per100 = lowered.contains("100")
        let unit: ChemicalUnit
        if lowered.contains("ml") {
            unit = .millilitres
        } else if lowered.contains("kg") {
            unit = .kilograms
        } else if lowered.hasPrefix("g") || lowered.contains("g/") {
            unit = .grams
        } else {
            unit = .litres
        }
        return (unit, per100)
    }

    /// Map this portal template into an in-memory `SprayRecord` template so
    /// the existing template pickers and calculator prefill flow work
    /// unchanged. The result is NEVER stored in `MigratedDataStore` — it is a
    /// read-only view that the prefill flow deep-copies into a brand-new
    /// spray record.
    func toSprayRecord() -> SprayRecord {
        let chemicals: [SprayChemical] = chemicalLines.map { line in
            let parsed = Self.parseLineUnit(line.unit)
            let baseRate = parsed.unit.toBase(line.rate ?? 0)
            return SprayChemical(
                name: line.name,
                volumePerTank: 0,
                ratePerHa: parsed.per100L ? 0 : baseRate,
                ratePer100L: parsed.per100L ? baseRate : 0,
                costPerUnit: 0,
                unit: parsed.unit,
                // The basis the portal's own unit string states. Previously
                // left nil, so a `mL/100L` program line reloaded as a
                // whole-block-area rate and reported as 0/ha — the same class
                // of defect P10 fixed on the CSV import path. A line with no
                // rate at all stays nil: an honest "not stated".
                rateBasis: baseRate > 0 ? (parsed.per100L ? .per100Litres : .wholeBlockArea) : nil,
                savedChemicalId: line.chemicalId
            )
        }

        let tank = SprayTank(
            tankNumber: 1,
            waterVolume: waterVolume ?? 0,
            sprayRatePerHa: sprayRatePerHa ?? 0,
            concentrationFactor: concentrationFactor ?? 0,
            rowApplications: [],
            chemicals: chemicals
        )

        // The portal's target wording, mapped onto VineTrack's typed targets
        // where it maps cleanly. Carrying it structurally is what lets the
        // guided calculator prefill Step 3 instead of the operator re-deriving
        // the target from a sentence in the notes.
        let mappedTargets = SprayProgramTargetParser.targets(from: target)

        // Only fall back to the old "Target: ..." notes prefix when NOTHING
        // mapped — a label may name a target VineTrack has no case for
        // (Phomopsis, Black Spot), and that wording must not be lost. When it
        // did map, the prefix would just duplicate what the UI now shows.
        var combinedNotes = notes ?? ""
        if let target, !target.isEmpty, mappedTargets.isEmpty {
            combinedNotes = combinedNotes.isEmpty ? "Target: \(target)" : "Target: \(target)\n\(combinedNotes)"
        }

        return SprayRecord(
            id: id,
            vineyardId: vineyardId,
            sprayReference: name,
            tanks: [tank],
            notes: combinedNotes,
            // Already-synced identities the previous adapter decoded and then
            // dropped. Passing them through lets a Program Step prefill the
            // equipment and tractor the portal chose, by ID rather than by
            // matching a display name.
            tractorId: tractorId,
            sprayEquipmentId: equipmentId,
            isTemplate: true,
            operationType: operationType.flatMap { OperationType(rawValue: $0) } ?? .foliarSpray,
            // Targets only — a template has no geometry, and this snapshot
            // never reaches history. `blocks` stays nil, which reads as
            // "blocks not recorded", because a reusable step does not know
            // where it is going.
            applicationGeometry: mappedTargets.isEmpty
                ? nil
                : SprayApplicationSnapshot(targets: mappedTargets)
        )
    }
}
