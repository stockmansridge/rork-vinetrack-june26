import Foundation

typealias RateBasis = ChemicalRateBasis

nonisolated enum OperationType: String, CaseIterable, Sendable, Codable {
    case foliarSpray = "Foliar Spray"
    case bandedSpray = "Banded Spray"
    case spreader = "Spreader"

    var iconName: String {
        switch self {
        case .foliarSpray: return "leaf.arrow.circlepath"
        case .bandedSpray: return "line.3.horizontal"
        case .spreader: return "square.3.layers.3d"
        }
    }

    var useConcentrationFactor: Bool {
        switch self {
        case .foliarSpray: return true
        case .bandedSpray, .spreader: return false
        }
    }
}

nonisolated struct ChemicalLine: Identifiable, Sendable, Codable {
    let id: UUID
    var chemicalId: UUID
    var selectedRateId: UUID
    var basis: RateBasis
    /// Operator-entered override expressed in the chemical's display unit
    /// (e.g. mL or g) per the selected basis. When non-nil, the calculator
    /// uses this value instead of the saved/recommended rate, and the UI
    /// flags the line as manually overridden until the operator taps Reset.
    var overrideRate: Double?

    init(
        id: UUID = UUID(),
        chemicalId: UUID,
        selectedRateId: UUID,
        basis: RateBasis = .perHectare,
        overrideRate: Double? = nil
    ) {
        self.id = id
        self.chemicalId = chemicalId
        self.selectedRateId = selectedRateId
        self.basis = basis
        self.overrideRate = overrideRate
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, chemicalId, selectedRateId, basis, overrideRate
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        chemicalId = try c.decode(UUID.self, forKey: .chemicalId)
        selectedRateId = try c.decode(UUID.self, forKey: .selectedRateId)
        basis = try c.decodeIfPresent(RateBasis.self, forKey: .basis) ?? .perHectare
        overrideRate = try c.decodeIfPresent(Double.self, forKey: .overrideRate)
    }
}

nonisolated struct PhenologyStage: Identifiable, Sendable {
    let id: UUID
    let name: String
    let code: String

    static let allStages: [PhenologyStage] = GrowthStage.allStages.map { gs in
        PhenologyStage(
            id: deterministicUUID(from: "phenology-\(gs.code)"),
            name: gs.description,
            code: gs.code
        )
    }

    private static func deterministicUUID(from string: String) -> UUID {
        let data = Array(string.utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in data.enumerated() {
            bytes[i % 16] ^= byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

nonisolated struct PaddockPhenologyEntry: Codable, Sendable {
    var paddockId: UUID
    var phenologyStageId: UUID?
}

nonisolated struct WeatherSnapshot: Codable, Sendable {
    var temperature: Double?
    var windSpeed: Double?
    var windDirection: String?
    var humidity: Double?
}

nonisolated struct SprayApplication: Codable, Identifiable, Sendable {
    let id: UUID
    var vineyardId: UUID
    var paddockIds: [UUID]
    var equipmentId: UUID
    var chemicalLines: [ChemicalLine]
    var waterRateLitresPerHectare: Double
    var operationType: OperationType
    var sprayName: String
    var notes: String
    var weather: WeatherSnapshot?
    var paddockPhenologyEntries: [PaddockPhenologyEntry]
    var jobStartDate: Date?
    var jobEndDate: Date?
    var jobDurationHours: Double?
    var startWeather: WeatherSnapshot?
    var numberOfFansJets: String
    var tractorGear: String
    var trackingPattern: TrackingPattern
    var startDirection: String
    var concentrationFactor: Double

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        paddockIds: [UUID] = [],
        equipmentId: UUID = UUID(),
        chemicalLines: [ChemicalLine] = [],
        waterRateLitresPerHectare: Double = 0,
        operationType: OperationType = .foliarSpray,
        sprayName: String = "",
        notes: String = "",
        weather: WeatherSnapshot? = nil,
        paddockPhenologyEntries: [PaddockPhenologyEntry] = [],
        jobStartDate: Date? = nil,
        jobEndDate: Date? = nil,
        jobDurationHours: Double? = nil,
        startWeather: WeatherSnapshot? = nil,
        numberOfFansJets: String = "",
        tractorGear: String = "",
        trackingPattern: TrackingPattern = .sequential,
        startDirection: String = "firstRow",
        concentrationFactor: Double = 1.0
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.paddockIds = paddockIds
        self.equipmentId = equipmentId
        self.chemicalLines = chemicalLines
        self.waterRateLitresPerHectare = waterRateLitresPerHectare
        self.operationType = operationType
        self.sprayName = sprayName
        self.notes = notes
        self.weather = weather
        self.paddockPhenologyEntries = paddockPhenologyEntries
        self.jobStartDate = jobStartDate
        self.jobEndDate = jobEndDate
        self.jobDurationHours = jobDurationHours
        self.startWeather = startWeather
        self.numberOfFansJets = numberOfFansJets
        self.tractorGear = tractorGear
        self.trackingPattern = trackingPattern
        self.startDirection = startDirection
        self.concentrationFactor = concentrationFactor
    }
}

nonisolated struct PaddockChemicalBreakdown: Identifiable, Sendable {
    let id = UUID()
    let paddockName: String
    let areaHectares: Double
    let amountRequired: Double
}

nonisolated struct ChemicalCalculationResult: Identifiable, Sendable {
    let id = UUID()
    let chemicalName: String
    let unit: ChemicalUnit
    let selectedRate: Double
    let basis: RateBasis
    let totalAmountRequired: Double
    let amountPerFullTank: Double
    let amountInLastTank: Double
    let paddockBreakdown: [PaddockChemicalBreakdown]
    /// Source `SavedChemical.id` so downstream snapshots (e.g. `SprayChemical.savedChemicalId`)
    /// can be populated reliably without name-matching.
    let savedChemicalId: UUID?
    /// Snapshot of `SavedChemical.purchase.costPerBaseUnit` at the time of
    /// calculation. `nil` when the saved chemical has no purchase data so
    /// downstream code can mark the cost as unavailable rather than zero.
    let costPerBaseUnit: Double?
}

nonisolated struct ChemicalCostResult: Identifiable, Sendable {
    let id = UUID()
    let chemicalName: String
    let totalAmountBase: Double
    let costPerBaseUnit: Double
    let totalCost: Double
    let costPerHectare: Double
    let unit: ChemicalUnit
}

nonisolated struct FuelCostResult: Sendable {
    let tractorName: String
    let fuelUsageLPerHour: Double
    let jobDurationHours: Double
    let fuelCostPerLitre: Double
    let totalFuelLitres: Double
    let totalFuelCost: Double
    let fuelCostPerHectare: Double
}

nonisolated struct SprayCostingSummary: Sendable {
    let chemicalCosts: [ChemicalCostResult]
    let totalChemicalCost: Double
    let totalCostPerHectare: Double
    let totalAreaHectares: Double
    let fuelCost: FuelCostResult?
    let grandTotal: Double
    let grandTotalPerHectare: Double
}

nonisolated struct SprayCalculationResult: Sendable {
    let totalAreaHectares: Double
    let totalWaterLitres: Double
    let tankCapacityLitres: Double
    let fullTankCount: Int
    let lastTankLitres: Double
    let chemicalResults: [ChemicalCalculationResult]
    let concentrationFactor: Double
    let costingSummary: SprayCostingSummary?
}
