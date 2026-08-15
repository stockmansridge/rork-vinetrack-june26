import Foundation

nonisolated struct SprayRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var tripId: UUID
    var vineyardId: UUID
    var date: Date
    var startTime: Date
    var endTime: Date?
    var temperature: Double?
    var windSpeed: Double?
    var windDirection: String
    var humidity: Double?
    var sprayReference: String
    var tanks: [SprayTank]
    var notes: String
    var numberOfFansJets: String
    var averageSpeed: Double?
    var equipmentType: String
    var tractor: String
    var tractorGear: String
    /// Optional stable link to a `VineyardMachine` derived from the `tractor`
    /// text snapshot. The text fields remain the authoritative display
    /// snapshots; these enable stable linking going forward.
    var machineId: UUID?
    /// Optional stable link to a `Tractor` derived from the `tractor` text.
    var tractorId: UUID?
    /// Optional stable link to a `SprayEquipmentItem` derived from the
    /// `equipmentType` text.
    var sprayEquipmentId: UUID?
    var isTemplate: Bool
    var operationType: OperationType
    /// Frozen projection of the canonical `SprayApplicationPlan` this record was
    /// calculated from (sql/191 + sql/192 columns).
    ///
    /// `nil` for every record written before sql/191 and for any record never
    /// calculated through the Spray Engine. Absence is preserved, never guessed:
    /// a historical banded spray whose treated area was never measured stays
    /// `nil` rather than acquiring one derived from today's block geometry.
    ///
    /// Read this instead of re-deriving geometry — a completed record is a
    /// compliance document and must not change when the vineyard does.
    var applicationGeometry: SprayApplicationSnapshot?

    init(
        id: UUID = UUID(),
        tripId: UUID = UUID(),
        vineyardId: UUID = UUID(),
        date: Date = Date(),
        startTime: Date = Date(),
        endTime: Date? = nil,
        temperature: Double? = nil,
        windSpeed: Double? = nil,
        windDirection: String = "",
        humidity: Double? = nil,
        sprayReference: String = "",
        tanks: [SprayTank] = [],
        notes: String = "",
        numberOfFansJets: String = "",
        averageSpeed: Double? = nil,
        equipmentType: String = "",
        tractor: String = "",
        tractorGear: String = "",
        machineId: UUID? = nil,
        tractorId: UUID? = nil,
        sprayEquipmentId: UUID? = nil,
        isTemplate: Bool = false,
        operationType: OperationType = .foliarSpray,
        applicationGeometry: SprayApplicationSnapshot? = nil
    ) {
        self.id = id
        self.tripId = tripId
        self.vineyardId = vineyardId
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.temperature = temperature
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.humidity = humidity
        self.sprayReference = sprayReference
        self.tanks = tanks
        self.notes = notes
        self.numberOfFansJets = numberOfFansJets
        self.averageSpeed = averageSpeed
        self.equipmentType = equipmentType
        self.tractor = tractor
        self.tractorGear = tractorGear
        self.machineId = machineId
        self.tractorId = tractorId
        self.sprayEquipmentId = sprayEquipmentId
        self.isTemplate = isTemplate
        self.operationType = operationType
        self.applicationGeometry = applicationGeometry
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, tripId, vineyardId, date, startTime, endTime
        case temperature, windSpeed, windDirection, humidity
        case sprayReference, tanks, notes, numberOfFansJets
        case averageSpeed, equipmentType, tractor, tractorGear
        case machineId, tractorId, sprayEquipmentId, isTemplate, operationType
        case applicationGeometry
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tripId = try container.decode(UUID.self, forKey: .tripId)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        date = try container.decode(Date.self, forKey: .date)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        windSpeed = try container.decodeIfPresent(Double.self, forKey: .windSpeed)
        windDirection = try container.decodeIfPresent(String.self, forKey: .windDirection) ?? ""
        humidity = try container.decodeIfPresent(Double.self, forKey: .humidity)
        sprayReference = try container.decodeIfPresent(String.self, forKey: .sprayReference) ?? ""
        tanks = try container.decode([SprayTank].self, forKey: .tanks)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        numberOfFansJets = try container.decodeIfPresent(String.self, forKey: .numberOfFansJets) ?? ""
        averageSpeed = try container.decodeIfPresent(Double.self, forKey: .averageSpeed)
        equipmentType = try container.decodeIfPresent(String.self, forKey: .equipmentType) ?? ""
        tractor = try container.decodeIfPresent(String.self, forKey: .tractor) ?? ""
        tractorGear = try container.decodeIfPresent(String.self, forKey: .tractorGear) ?? ""
        machineId = try container.decodeIfPresent(UUID.self, forKey: .machineId)
        tractorId = try container.decodeIfPresent(UUID.self, forKey: .tractorId)
        sprayEquipmentId = try container.decodeIfPresent(UUID.self, forKey: .sprayEquipmentId)
        isTemplate = try container.decodeIfPresent(Bool.self, forKey: .isTemplate) ?? false
        operationType = try container.decodeIfPresent(OperationType.self, forKey: .operationType) ?? .foliarSpray
        let decodedGeometry = try? container.decodeIfPresent(
            SprayApplicationSnapshot.self,
            forKey: .applicationGeometry
        )
        // An all-null snapshot is indistinguishable from "never recorded", so
        // normalise it to nil and keep one representation of absence.
        applicationGeometry = (decodedGeometry?.isEmpty ?? true) ? nil : decodedGeometry
    }
}

nonisolated struct SprayTank: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var tankNumber: Int
    var waterVolume: Double
    var sprayRatePerHa: Double
    var concentrationFactor: Double
    var rowApplications: [TankRowApplication]
    var chemicals: [SprayChemical]

    var effectiveConcentrationFactor: Double {
        concentrationFactor > 0 ? concentrationFactor : 1.0
    }

    var areaPerTank: Double {
        guard sprayRatePerHa > 0 else { return 0 }
        return (waterVolume * effectiveConcentrationFactor) / sprayRatePerHa
    }

    init(
        id: UUID = UUID(),
        tankNumber: Int = 1,
        waterVolume: Double = 0,
        sprayRatePerHa: Double = 0,
        concentrationFactor: Double = 0,
        rowApplications: [TankRowApplication] = [],
        chemicals: [SprayChemical] = []
    ) {
        self.id = id
        self.tankNumber = tankNumber
        self.waterVolume = waterVolume
        self.sprayRatePerHa = sprayRatePerHa
        self.concentrationFactor = concentrationFactor
        self.rowApplications = rowApplications
        self.chemicals = chemicals
    }
}

nonisolated struct TankRowApplication: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var startRow: Double
    var endRow: Double

    init(id: UUID = UUID(), startRow: Double = 0.5, endRow: Double = 0.5) {
        self.id = id
        self.startRow = startRow
        self.endRow = endRow
    }

    var rowRange: String {
        if startRow == endRow {
            return "Row \(formatRow(startRow))"
        }
        return "Rows \(formatRow(startRow))–\(formatRow(endRow))"
    }

    private func formatRow(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

nonisolated struct SprayChemical: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var volumePerTank: Double
    var ratePerHa: Double
    var ratePer100L: Double
    /// Cost per base unit (mL or g) of this chemical. `0` indicates the cost
    /// is unavailable — callers should treat zero as "missing" rather than
    /// silently zero-cost. Use `hasCost` to test for availability.
    var costPerUnit: Double
    var unit: ChemicalUnit
    /// Which area/volume this line's rate is quoted against, snapshotted so the
    /// amount stays explainable later (sql/191 per-product rate basis).
    ///
    /// Persisted per CHEMICAL LINE inside the `tanks` JSONB — never as a
    /// job-level setting — so one tank can legitimately mix bases:
    ///
    /// ```text
    /// Kelp      2 L/block ha  × 10 ha    = 20 L
    /// Herbicide 2 L/treated ha × 2.5 ha  =  5 L
    /// Adjuvant  100 mL/100 L  × 6,250 L  =  6.25 L
    /// ```
    ///
    /// `nil` on legacy lines. Absence is NOT silently read as
    /// `wholeBlockArea`: use `resolvedRateBasis` where a concrete basis is
    /// required, which documents the legacy assumption at the point of use.
    var rateBasis: SprayProductRateBasis?
    /// Snapshot of the source `SavedChemical.id` when this line was created
    /// from a saved chemical. Enables reliable cost lookup/fallback later if
    /// the snapshot in `costPerUnit` is missing.
    var savedChemicalId: UUID?
    /// Resistance-relevant facts about this product frozen at application time
    /// (Chemical Intelligence, sql/194).
    ///
    /// `nil` on legacy lines and on lines whose product has no structured
    /// intelligence yet — an honest absence. Historical resistance analysis
    /// reads THIS, never the current `SavedChemical`, so correcting a chemical
    /// three years from now cannot silently restate what was actually applied.
    var chemicalSnapshot: ChemicalLineSnapshot?

    /// Whether this chemical line has a usable cost per unit snapshot.
    var hasCost: Bool { costPerUnit > 0 }

    /// The basis to calculate against, defaulting a legacy line to
    /// `wholeBlockArea`.
    ///
    /// This mirrors the sql/191 rule that legacy `per_hectare` means
    /// whole-block area and NEVER treated area — reading an old line as
    /// treated-area would silently under-dose it.
    var resolvedRateBasis: SprayProductRateBasis {
        rateBasis ?? .wholeBlockArea
    }

    var costPerTank: Double {
        costPerUnit * volumePerTank
    }

    var displayVolume: Double {
        unit.fromBase(volumePerTank)
    }

    var displayRate: Double {
        unit.fromBase(ratePerHa)
    }

    var displayRatePer100L: Double {
        unit.fromBase(ratePer100L)
    }

    var unitLabel: String {
        unit.rawValue
    }

    init(id: UUID = UUID(), name: String = "", volumePerTank: Double = 0, ratePerHa: Double = 0, ratePer100L: Double = 0, costPerUnit: Double = 0, unit: ChemicalUnit = .litres, rateBasis: SprayProductRateBasis? = nil, savedChemicalId: UUID? = nil, chemicalSnapshot: ChemicalLineSnapshot? = nil) {
        self.id = id
        self.name = name
        self.volumePerTank = volumePerTank
        self.ratePerHa = ratePerHa
        self.ratePer100L = ratePer100L
        self.costPerUnit = costPerUnit
        self.unit = unit
        self.rateBasis = rateBasis
        self.savedChemicalId = savedChemicalId
        self.chemicalSnapshot = chemicalSnapshot
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, name, volumePerTank, ratePerHa, ratePer100L, costPerUnit, unit, rateBasis, savedChemicalId
        case chemicalSnapshot
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        volumePerTank = try container.decodeIfPresent(Double.self, forKey: .volumePerTank) ?? 0
        ratePerHa = try container.decodeIfPresent(Double.self, forKey: .ratePerHa) ?? 0
        ratePer100L = try container.decodeIfPresent(Double.self, forKey: .ratePer100L) ?? 0
        costPerUnit = try container.decodeIfPresent(Double.self, forKey: .costPerUnit) ?? 0
        unit = try container.decodeIfPresent(ChemicalUnit.self, forKey: .unit) ?? .litres
        // Tolerant, and legacy-aware: an exact basis decodes directly, an older
        // spelling (`per_hectare`, `l/ha`, ...) is mapped deterministically by
        // `legacy(_:)` — which resolves `per_hectare` to whole-block area, never
        // treated area — and anything unrecognised degrades to nil instead of
        // failing the whole record. Mirrors Android's `resolvedRateBasis`.
        if let exact = try? container.decodeIfPresent(SprayProductRateBasis.self, forKey: .rateBasis) {
            rateBasis = exact
        } else if let raw = try? container.decodeIfPresent(String.self, forKey: .rateBasis) {
            rateBasis = SprayProductRateBasis.legacy(raw)
        } else {
            rateBasis = nil
        }
        savedChemicalId = try container.decodeIfPresent(UUID.self, forKey: .savedChemicalId)
        // Additive and tolerant: a line written before Chemical Intelligence
        // simply has no snapshot, and a malformed one degrades to nil rather
        // than failing the whole spray record.
        chemicalSnapshot = try? container.decodeIfPresent(ChemicalLineSnapshot.self, forKey: .chemicalSnapshot)
    }

    /// Activity group codes as recorded AT APPLICATION TIME, e.g. `["3", "11"]`.
    ///
    /// Empty for a line applied before its product was structured — which is a
    /// meaningful answer ("VineTrack did not know"), and never a reason to go
    /// and read the chemical's present-day classification instead.
    nonisolated var recordedActivityGroupCodes: [String] {
        chemicalSnapshot?.activityGroupCodes ?? []
    }

    /// Whether this line can take part in historical resistance analysis.
    nonisolated var hasResistanceSnapshot: Bool {
        chemicalSnapshot?.hasResistanceData ?? false
    }
}

nonisolated enum WindDirection: String, CaseIterable, Codable, Sendable {
    case n = "N"
    case nne = "NNE"
    case ne = "NE"
    case ene = "ENE"
    case e = "E"
    case ese = "ESE"
    case se = "SE"
    case sse = "SSE"
    case s = "S"
    case ssw = "SSW"
    case sw = "SW"
    case wsw = "WSW"
    case w = "W"
    case wnw = "WNW"
    case nw = "NW"
    case nnw = "NNW"
}
