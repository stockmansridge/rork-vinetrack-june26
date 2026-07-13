import Foundation

// MARK: - fertiliser_products

nonisolated struct BackendFertiliserProduct: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String?
    let manufacturer: String?
    let category: String?
    let form: String?
    let packSize: Double?
    let packUnit: String?
    let pricePerPack: Double?
    let density: Double?
    let nitrogenPercent: Double?
    let phosphorusPercent: Double?
    let potassiumPercent: Double?
    let analysisBasis: String?
    let organicCertified: Bool?
    let inventoryQuantity: Double?
    let inventoryUnit: String?
    let applicationNotes: String?
    let isActive: Bool?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case manufacturer
        case category
        case form
        case packSize = "pack_size"
        case packUnit = "pack_unit"
        case pricePerPack = "price_per_pack"
        case density
        case nitrogenPercent = "nitrogen_percent"
        case phosphorusPercent = "phosphorus_percent"
        case potassiumPercent = "potassium_percent"
        case analysisBasis = "analysis_basis"
        case organicCertified = "organic_certified"
        case inventoryQuantity = "inventory_quantity"
        case inventoryUnit = "inventory_unit"
        case applicationNotes = "application_notes"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendFertiliserProductUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let manufacturer: String
    let category: String
    let form: String
    let packSize: Double
    let packUnit: String
    let pricePerPack: Double?
    let density: Double?
    let nitrogenPercent: Double?
    let phosphorusPercent: Double?
    let potassiumPercent: Double?
    let analysisBasis: String
    let organicCertified: Bool
    let inventoryQuantity: Double?
    let inventoryUnit: String
    let applicationNotes: String
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case manufacturer
        case category
        case form
        case packSize = "pack_size"
        case packUnit = "pack_unit"
        case pricePerPack = "price_per_pack"
        case density
        case nitrogenPercent = "nitrogen_percent"
        case phosphorusPercent = "phosphorus_percent"
        case potassiumPercent = "potassium_percent"
        case analysisBasis = "analysis_basis"
        case organicCertified = "organic_certified"
        case inventoryQuantity = "inventory_quantity"
        case inventoryUnit = "inventory_unit"
        case applicationNotes = "application_notes"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendFertiliserProduct {
    static func upsert(from product: FertiliserProduct, createdBy: UUID?, clientUpdatedAt: Date) -> BackendFertiliserProductUpsert {
        BackendFertiliserProductUpsert(
            id: product.id,
            vineyardId: product.vineyardId,
            name: product.name,
            manufacturer: product.manufacturer,
            category: product.category.rawValue,
            form: product.form.rawValue,
            packSize: product.packSize,
            packUnit: product.form.unit,
            pricePerPack: product.pricePerPack,
            density: product.density,
            nitrogenPercent: product.nitrogenPercent,
            phosphorusPercent: product.phosphorusPercent,
            potassiumPercent: product.potassiumPercent,
            analysisBasis: product.analysisBasis.rawValue,
            organicCertified: product.organicCertified,
            inventoryQuantity: product.inventoryPacks,
            inventoryUnit: "packs",
            applicationNotes: product.applicationNotes,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toFertiliserProduct() -> FertiliserProduct {
        FertiliserProduct(
            id: id,
            vineyardId: vineyardId,
            name: name ?? "",
            manufacturer: manufacturer ?? "",
            form: FertiliserForm(rawValue: form ?? "") ?? .solid,
            category: FertiliserCategory(rawValue: category ?? "") ?? .conventional,
            packSize: packSize ?? 25,
            pricePerPack: pricePerPack,
            density: density,
            nitrogenPercent: nitrogenPercent,
            phosphorusPercent: phosphorusPercent,
            potassiumPercent: potassiumPercent,
            analysisBasis: FertiliserAnalysisBasis(rawValue: analysisBasis ?? "") ?? .elemental,
            organicCertified: organicCertified ?? false,
            applicationNotes: applicationNotes ?? "",
            inventoryPacks: inventoryQuantity
        )
    }
}

// MARK: - fertiliser_records

nonisolated struct BackendFertiliserRecord: Codable, Sendable, Identifiable {
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
            applicationDate: PruningSyncDate.ymd(from: record.date),
            blockNames: record.blockNames,
            totalAreaHa: record.areaHectares,
            totalVines: record.vineCount,
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

    func toFertiliserRecord(allocations: [FertiliserAllocation]) -> FertiliserRecord {
        FertiliserRecord(
            id: id,
            vineyardId: vineyardId,
            date: PruningSyncDate.date(fromYmd: applicationDate) ?? createdAt ?? Date(),
            status: FertiliserRecordStatus(rawValue: recordStatus ?? "") ?? .planned,
            mode: FertiliserCalcMode(rawValue: calculationMode ?? "") ?? .perHectare,
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
            createdAt: createdAt ?? Date()
        )
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
