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
nonisolated struct SprayJobChemicalLine: Codable, Sendable {
    let chemicalId: UUID?
    let name: String
    let activeIngredient: String?
    let rate: Double?
    let unit: String?
    let waterRate: Double?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case chemicalId = "chemical_id"
        case name
        case activeIngredient = "active_ingredient"
        case rate
        case unit
        case waterRate = "water_rate"
        case notes
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
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

        var combinedNotes = notes ?? ""
        if let target, !target.isEmpty {
            combinedNotes = combinedNotes.isEmpty ? "Target: \(target)" : "Target: \(target)\n\(combinedNotes)"
        }

        return SprayRecord(
            id: id,
            vineyardId: vineyardId,
            sprayReference: name,
            tanks: [tank],
            notes: combinedNotes,
            isTemplate: true,
            operationType: operationType.flatMap { OperationType(rawValue: $0) } ?? .foliarSpray
        )
    }
}
