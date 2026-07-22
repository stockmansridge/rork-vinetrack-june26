import Foundation

// MARK: - Trip Cost Allocation (financial; owner/manager only)

nonisolated struct BackendTripCostAllocation: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let tripId: UUID
    let seasonYear: Int?
    let tripFunction: String?
    let paddockId: UUID?
    let paddockName: String?
    let variety: String?
    let varietyId: UUID?
    let varietyPercentage: Double?
    let allocationAreaHa: Double?
    let labourCost: Double?
    let fuelCost: Double?
    let chemicalCost: Double?
    let inputCost: Double?
    let totalCost: Double?
    let costPerHa: Double?
    let yieldTonnes: Double?
    let costPerTonne: Double?
    let allocationBasis: String?
    let costingStatus: String?
    let warnings: [String]?
    let calculatedAt: Date?
    let sourceTripUpdatedAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case tripId = "trip_id"
        case seasonYear = "season_year"
        case tripFunction = "trip_function"
        case paddockId = "paddock_id"
        case paddockName = "paddock_name"
        case variety
        case varietyId = "variety_id"
        case varietyPercentage = "variety_percentage"
        case allocationAreaHa = "allocation_area_ha"
        case labourCost = "labour_cost"
        case fuelCost = "fuel_cost"
        case chemicalCost = "chemical_cost"
        case inputCost = "input_cost"
        case totalCost = "total_cost"
        case costPerHa = "cost_per_ha"
        case yieldTonnes = "yield_tonnes"
        case costPerTonne = "cost_per_tonne"
        case allocationBasis = "allocation_basis"
        case costingStatus = "costing_status"
        case warnings
        case calculatedAt = "calculated_at"
        case sourceTripUpdatedAt = "source_trip_updated_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.tripId = try c.decode(UUID.self, forKey: .tripId)
        self.seasonYear = try c.decodeIfPresent(Int.self, forKey: .seasonYear)
        self.tripFunction = try c.decodeIfPresent(String.self, forKey: .tripFunction)
        self.paddockId = try c.decodeIfPresent(UUID.self, forKey: .paddockId)
        self.paddockName = try c.decodeIfPresent(String.self, forKey: .paddockName)
        self.variety = try c.decodeIfPresent(String.self, forKey: .variety)
        self.varietyId = try c.decodeIfPresent(UUID.self, forKey: .varietyId)
        self.varietyPercentage = try c.decodeIfPresent(Double.self, forKey: .varietyPercentage)
        self.allocationAreaHa = try c.decodeIfPresent(Double.self, forKey: .allocationAreaHa)
        self.labourCost = try c.decodeIfPresent(Double.self, forKey: .labourCost)
        self.fuelCost = try c.decodeIfPresent(Double.self, forKey: .fuelCost)
        self.chemicalCost = try c.decodeIfPresent(Double.self, forKey: .chemicalCost)
        self.inputCost = try c.decodeIfPresent(Double.self, forKey: .inputCost)
        self.totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost)
        self.costPerHa = try c.decodeIfPresent(Double.self, forKey: .costPerHa)
        self.yieldTonnes = try c.decodeIfPresent(Double.self, forKey: .yieldTonnes)
        self.costPerTonne = try c.decodeIfPresent(Double.self, forKey: .costPerTonne)
        self.allocationBasis = try c.decodeIfPresent(String.self, forKey: .allocationBasis)
        self.costingStatus = try c.decodeIfPresent(String.self, forKey: .costingStatus)
        self.warnings = try c.decodeIfPresent([String].self, forKey: .warnings)
        self.calculatedAt = try c.decodeIfPresent(Date.self, forKey: .calculatedAt)
        self.sourceTripUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .sourceTripUpdatedAt)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.clientUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .clientUpdatedAt)
    }
}

nonisolated struct BackendTripCostAllocationUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let tripId: UUID
    let seasonYear: Int
    let tripFunction: String?
    let paddockId: UUID?
    let paddockName: String?
    let variety: String?
    let varietyId: UUID?
    let varietyPercentage: Double?
    let allocationAreaHa: Double?
    let labourCost: Double?
    let fuelCost: Double?
    let chemicalCost: Double?
    let inputCost: Double?
    let totalCost: Double?
    let costPerHa: Double?
    let yieldTonnes: Double?
    let costPerTonne: Double?
    let allocationBasis: String
    let costingStatus: String?
    let warnings: [String]?
    let calculatedAt: Date
    let sourceTripUpdatedAt: Date?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case tripId = "trip_id"
        case seasonYear = "season_year"
        case tripFunction = "trip_function"
        case paddockId = "paddock_id"
        case paddockName = "paddock_name"
        case variety
        case varietyId = "variety_id"
        case varietyPercentage = "variety_percentage"
        case allocationAreaHa = "allocation_area_ha"
        case labourCost = "labour_cost"
        case fuelCost = "fuel_cost"
        case chemicalCost = "chemical_cost"
        case inputCost = "input_cost"
        case totalCost = "total_cost"
        case costPerHa = "cost_per_ha"
        case yieldTonnes = "yield_tonnes"
        case costPerTonne = "cost_per_tonne"
        case allocationBasis = "allocation_basis"
        case costingStatus = "costing_status"
        case warnings
        case calculatedAt = "calculated_at"
        case sourceTripUpdatedAt = "source_trip_updated_at"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendTripCostAllocation {
    static func upsert(from row: TripCostAllocation, createdBy: UUID?, clientUpdatedAt: Date) -> BackendTripCostAllocationUpsert {
        BackendTripCostAllocationUpsert(
            id: row.id,
            vineyardId: row.vineyardId,
            tripId: row.tripId,
            seasonYear: row.seasonYear,
            tripFunction: row.tripFunction,
            paddockId: row.paddockId,
            paddockName: row.paddockName,
            variety: row.variety,
            varietyId: row.varietyId,
            varietyPercentage: row.varietyPercentage,
            allocationAreaHa: row.allocationAreaHa,
            labourCost: row.labourCost,
            fuelCost: row.fuelCost,
            chemicalCost: row.chemicalCost,
            inputCost: row.inputCost,
            totalCost: row.totalCost,
            costPerHa: row.costPerHa,
            yieldTonnes: row.yieldTonnes,
            costPerTonne: row.costPerTonne,
            allocationBasis: row.allocationBasis.rawValue,
            costingStatus: row.costingStatus?.rawValue,
            warnings: row.warnings.isEmpty ? nil : row.warnings,
            calculatedAt: row.calculatedAt,
            sourceTripUpdatedAt: row.sourceTripUpdatedAt,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toTripCostAllocation() -> TripCostAllocation {
        TripCostAllocation(
            id: id,
            vineyardId: vineyardId,
            tripId: tripId,
            seasonYear: seasonYear ?? 0,
            tripFunction: tripFunction,
            paddockId: paddockId,
            paddockName: paddockName,
            variety: variety,
            varietyId: varietyId,
            varietyPercentage: varietyPercentage,
            allocationAreaHa: allocationAreaHa,
            labourCost: labourCost,
            fuelCost: fuelCost,
            chemicalCost: chemicalCost,
            inputCost: inputCost,
            totalCost: totalCost,
            costPerHa: costPerHa,
            yieldTonnes: yieldTonnes,
            costPerTonne: costPerTonne,
            allocationBasis: TripCostAllocationBasis(rawValue: allocationBasis ?? "area") ?? .area,
            costingStatus: costingStatus.flatMap { TripCostAllocationStatus(rawValue: $0) },
            warnings: warnings ?? [],
            calculatedAt: calculatedAt ?? Date(),
            sourceTripUpdatedAt: sourceTripUpdatedAt
        )
    }
}
