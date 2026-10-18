import Foundation

// Fertiliser products live in the shared saved chemical library
// (`saved_chemicals`, sql/111) and sync through `SavedChemicalSyncService`.
// Only records + allocations have dedicated fertiliser tables.

// MARK: - fertiliser_records

nonisolated struct BackendFertiliserRecord: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let productId: UUID?
    let productName: String?
    let form: String?
    let calculationMode: String?
    let recordStatus: String?
    let applicationDate: String?
    let blockNames: [String]?
    let totalAreaHa: Double?
    let totalVines: Int?
    var vineCountBasis: String? = nil
    let applicationRate: Double?
    let applicationRateUnit: String?
    let totalProductRequired: Double?
    let productUnit: String?
    let packSize: Double?
    let packCount: Double?
    let estimatedProductCost: Double?
    let labourCost: Double?
    let machineryCost: Double?
    let totalJobCost: Double?
    let notes: String?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?
    var nutrientKey: String? = nil
    var nutrientDisplayName: String? = nil
    var targetRate: Double? = nil
    var targetRateUnit: String? = nil
    var nutrientPercent: Double? = nil
    var nutrientPercentSource: String? = nil
    var analysisBasis: String? = nil
    var concentrationBasis: String? = nil
    var productDensityKgPerL: Double? = nil
    var productDensitySource: String? = nil
    var productDensityReference: String? = nil
    var productAnalysisSnapshot: SprayReportPayloadV1.JSONValue? = nil
    var nutrientContractVersion: String? = nil
    var nutrientDeclaredAs: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case productId = "product_id"
        case productName = "product_name"
        case form
        case calculationMode = "calculation_mode"
        case recordStatus = "record_status"
        case applicationDate = "application_date"
        case blockNames = "block_names"
        case totalAreaHa = "total_area_ha"
        case totalVines = "total_vines"
        case vineCountBasis = "vine_count_basis"
        case applicationRate = "application_rate"
        case applicationRateUnit = "application_rate_unit"
        case totalProductRequired = "total_product_required"
        case productUnit = "product_unit"
        case packSize = "pack_size"
        case packCount = "pack_count"
        case estimatedProductCost = "estimated_product_cost"
        case labourCost = "labour_cost"
        case machineryCost = "machinery_cost"
        case totalJobCost = "total_job_cost"
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case nutrientKey = "nutrient_key", nutrientDisplayName = "nutrient_display_name"
        case targetRate = "target_rate", targetRateUnit = "target_rate_unit"
        case nutrientPercent = "nutrient_percent", nutrientPercentSource = "nutrient_percent_source"
        case analysisBasis = "analysis_basis", concentrationBasis = "concentration_basis"
        case productDensityKgPerL = "product_density_kg_per_l", productDensitySource = "product_density_source"
        case productDensityReference = "product_density_reference", productAnalysisSnapshot = "product_analysis_snapshot"
        case nutrientContractVersion = "nutrient_contract_version", nutrientDeclaredAs = "nutrient_declared_as"
    }
}

nonisolated struct BackendFertiliserRecordUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let productId: UUID?
    let productName: String
    let form: String
    let calculationMode: String
    let recordStatus: String
    let applicationDate: String
    let blockNames: [String]
    let totalAreaHa: Double
    let totalVines: Int
    var vineCountBasis: String? = nil
    let applicationRate: Double
    let applicationRateUnit: String
    let totalProductRequired: Double
    let productUnit: String
    let packSize: Double?
    let packCount: Double?
    let estimatedProductCost: Double?
    let labourCost: Double?
    let totalJobCost: Double?
    let notes: String
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case productId = "product_id"
        case productName = "product_name"
        case form
        case calculationMode = "calculation_mode"
        case recordStatus = "record_status"
        case applicationDate = "application_date"
        case blockNames = "block_names"
        case totalAreaHa = "total_area_ha"
        case totalVines = "total_vines"
        case vineCountBasis = "vine_count_basis"
        case applicationRate = "application_rate"
        case applicationRateUnit = "application_rate_unit"
        case totalProductRequired = "total_product_required"
        case productUnit = "product_unit"
        case packSize = "pack_size"
        case packCount = "pack_count"
        case estimatedProductCost = "estimated_product_cost"
        case labourCost = "labour_cost"
        case totalJobCost = "total_job_cost"
        case notes
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendFertiliserRecord {
    static func upsert(from record: FertiliserRecord, createdBy: UUID?, clientUpdatedAt: Date) -> BackendFertiliserRecordUpsert {
        BackendFertiliserRecordUpsert(
            id: record.id,
            vineyardId: record.vineyardId,
            productId: record.productId,
            productName: record.productName,
            form: record.form.rawValue,
            calculationMode: record.mode.rawValue,
            recordStatus: record.status.rawValue,
            applicationDate: record.applicationDateSnapshot ?? PruningSyncDate.ymd(from: record.date),
            blockNames: record.blockNames,
            totalAreaHa: record.areaHectares,
            totalVines: record.vineCount,
            vineCountBasis: record.vineCountBasis.flatMap { $0.isEmpty ? nil : $0 },
            applicationRate: record.rate,
            applicationRateUnit: record.rateUnit,
            totalProductRequired: record.totalProduct,
            productUnit: record.form.unit,
            packSize: record.packSize,
            packCount: record.packSize.flatMap { size in
                size > 0 ? record.totalProduct / size : nil
            },
            estimatedProductCost: record.productCost,
            labourCost: record.labourMachineryCost,
            totalJobCost: record.totalCost,
            notes: record.notes,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toFertiliserRecord(allocations: [FertiliserAllocation], timeZone: TimeZone = .current) -> FertiliserRecord {
        var record = FertiliserRecord(
            id: id,
            vineyardId: vineyardId,
            date: FertiliserApplicationDate.date(applicationDate, timeZone: timeZone) ?? createdAt ?? Date(),
            status: FertiliserRecordStatus(rawValue: recordStatus ?? "") ?? .planned,
            mode: FertiliserCalcMode(rawValue: calculationMode ?? ""),
            productId: productId,
            productName: productName ?? "",
            form: FertiliserForm(rawValue: form ?? "") ?? .solid,
            paddockIds: allocations.map(\.paddockId),
            blockNames: blockNames ?? [],
            areaHectares: totalAreaHa ?? 0,
            vineCount: totalVines ?? 0,
            rate: applicationRate ?? 0,
            totalProduct: totalProductRequired ?? 0,
            packSize: packSize,
            productCost: estimatedProductCost,
            labourMachineryCost: labourCost,
            notes: notes ?? "",
            allocations: allocations,
            createdAt: createdAt ?? Date(),
            vineCountBasis: vineCountBasis,
            applicationDateSnapshot: applicationDate
        )
        if !record.mode.isSupported { record.unsupportedSnapshot = self }
        return record
    }
}

// MARK: - fertiliser_record_allocations

nonisolated struct BackendFertiliserAllocation: Codable, Sendable, Identifiable {
    let id: UUID
    let fertiliserRecordId: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let areaHa: Double?
    let vineCount: Int?
    let applicationRate: Double?
    let productRequired: Double?
    let allocatedCost: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case fertiliserRecordId = "fertiliser_record_id"
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case areaHa = "area_ha"
        case vineCount = "vine_count"
        case applicationRate = "application_rate"
        case productRequired = "product_required"
        case allocatedCost = "allocated_cost"
    }

    static func upsert(from allocation: FertiliserAllocation, record: FertiliserRecord) -> BackendFertiliserAllocation {
        BackendFertiliserAllocation(
            id: allocation.id,
            fertiliserRecordId: record.id,
            vineyardId: record.vineyardId,
            paddockId: allocation.paddockId,
            areaHa: allocation.areaHectares,
            vineCount: allocation.vineCount,
            applicationRate: allocation.rate,
            productRequired: allocation.productRequired,
            allocatedCost: allocation.allocatedCost
        )
    }

    func toFertiliserAllocation() -> FertiliserAllocation {
        FertiliserAllocation(
            id: id,
            paddockId: paddockId,
            areaHectares: areaHa ?? 0,
            vineCount: vineCount ?? 0,
            rate: applicationRate ?? 0,
            productRequired: productRequired ?? 0,
            allocatedCost: allocatedCost
        )
    }
}
