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
        operationType: OperationType = .foliarSpray
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
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, tripId, vineyardId, date, startTime, endTime
        case temperature, windSpeed, windDirection, humidity
        case sprayReference, tanks, notes, numberOfFansJets
        case averageSpeed, equipmentType, tractor, tractorGear
        case machineId, tractorId, sprayEquipmentId, isTemplate, operationType
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
    /// Snapshot of the source `SavedChemical.id` when this line was created
    /// from a saved chemical. Enables reliable cost lookup/fallback later if
    /// the snapshot in `costPerUnit` is missing.
    var savedChemicalId: UUID?

    /// Whether this chemical line has a usable cost per unit snapshot.
    var hasCost: Bool { costPerUnit > 0 }

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

    init(id: UUID = UUID(), name: String = "", volumePerTank: Double = 0, ratePerHa: Double = 0, ratePer100L: Double = 0, costPerUnit: Double = 0, unit: ChemicalUnit = .litres, savedChemicalId: UUID? = nil) {
        self.id = id
        self.name = name
        self.volumePerTank = volumePerTank
        self.ratePerHa = ratePerHa
        self.ratePer100L = ratePer100L
        self.costPerUnit = costPerUnit
        self.unit = unit
        self.savedChemicalId = savedChemicalId
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, name, volumePerTank, ratePerHa, ratePer100L, costPerUnit, unit, savedChemicalId
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
        savedChemicalId = try container.decodeIfPresent(UUID.self, forKey: .savedChemicalId)
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
