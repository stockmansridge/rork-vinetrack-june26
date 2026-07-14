import Foundation

/// Physical form of a fertiliser product — drives units (kg vs L).
nonisolated enum FertiliserForm: String, Codable, CaseIterable, Identifiable, Sendable {
    case solid
    case liquid

    var id: String { rawValue }
    var label: String { self == .solid ? "Solid" : "Liquid" }
    /// Base unit for totals and pack sizes.
    var unit: String { self == .solid ? "kg" : "L" }
    /// Per-vine rate unit.
    var perVineUnit: String { self == .solid ? "g" : "mL" }
}

/// Unified saved-product category (`saved_chemicals.product_category`, sql/111).
/// The shared library covers spray chemicals AND fertiliser/nutrient products.
/// Raw keys are stable and shared across iOS, Android and the portal.
/// "" (no case) = uncategorised — every legacy spray chemical.
nonisolated enum ProductCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case fungicide
    case insecticide
    case herbicide
    case adjuvant
    case growthRegulator
    case foliarNutrient
    case granularFertiliser
    case liquidFertiliser
    case fertigation
    case compost
    case manure
    case biofertiliser
    case compostTea
    case seaweed
    case fishHydrolysate
    case humicFulvic
    case soilAmendment
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fungicide: return "Fungicide"
        case .insecticide: return "Insecticide"
        case .herbicide: return "Herbicide"
        case .adjuvant: return "Adjuvant"
        case .growthRegulator: return "Growth regulator"
        case .foliarNutrient: return "Foliar nutrient"
        case .granularFertiliser: return "Granular fertiliser"
        case .liquidFertiliser: return "Liquid fertiliser"
        case .fertigation: return "Fertigation product"
        case .compost: return "Compost"
        case .manure: return "Manure"
        case .biofertiliser: return "Biofertiliser"
        case .compostTea: return "Compost tea"
        case .seaweed: return "Seaweed"
        case .fishHydrolysate: return "Fish hydrolysate"
        case .humicFulvic: return "Humic / fulvic product"
        case .soilAmendment: return "Soil amendment"
        case .other: return "Other"
        }
    }

    /// Categories the Fertiliser Calculator shows by default.
    static let fertiliserCategories: [ProductCategory] = [
        .foliarNutrient, .granularFertiliser, .liquidFertiliser, .fertigation,
        .compost, .manure, .biofertiliser, .compostTea, .seaweed,
        .fishHydrolysate, .humicFulvic, .soilAmendment,
    ]

    /// True when this category is fertiliser / nutrient related, which makes
    /// the pack, N-P-K and inventory fields relevant in the product editor.
    var isFertiliser: Bool { Self.fertiliserCategories.contains(self) }
}

/// Whether the stored P/K analysis uses elemental values or oxide (P₂O₅ / K₂O)
/// label values. Mixing these up causes major calculation errors, so the unit
/// is stored explicitly on every product.
nonisolated enum FertiliserAnalysisBasis: String, Codable, CaseIterable, Identifiable, Sendable {
    case elemental
    case oxide

    var id: String { rawValue }
    var label: String { self == .elemental ? "Elemental (P, K)" : "Oxide (P₂O₅, K₂O)" }
}

// MARK: - SavedChemical fertiliser helpers

/// The Fertiliser Calculator reads products from the shared saved chemical
/// library (`saved_chemicals`, sql/111) — these helpers derive the
/// fertiliser-specific view of a saved product.
extension SavedChemical {
    /// Parsed unified category; nil when uncategorised.
    var category: ProductCategory? {
        productCategory.isEmpty ? nil : ProductCategory(rawValue: productCategory)
    }

    /// True when the product belongs to a fertiliser/nutrient category.
    var isFertiliserProduct: Bool { category?.isFertiliser ?? false }

    /// Solid/liquid form for fertiliser maths — explicit `productForm` first,
    /// falling back to the spray unit (Litres/mL = liquid).
    var fertiliserForm: FertiliserForm {
        switch productForm {
        case "liquid": return .liquid
        case "solid": return .solid
        default: return (unit == .litres || unit == .millilitres) ? .liquid : .solid
        }
    }

    /// Cost per base unit (kg or L), derived from the pack price.
    var costPerPackUnit: Double? {
        guard let pricePerPack, let packSize, packSize > 0 else { return nil }
        return pricePerPack / packSize
    }

    /// Short N-P-K summary, e.g. "N 20 · P 5 · K 10".
    var analysisSummary: String? {
        var parts: [String] = []
        if let value = nitrogenPercent, value > 0 { parts.append("N \(value.formatted(.number.precision(.fractionLength(0...1))))") }
        if let value = phosphorusPercent, value > 0 { parts.append("P \(value.formatted(.number.precision(.fractionLength(0...1))))") }
        if let value = potassiumPercent, value > 0 { parts.append("K \(value.formatted(.number.precision(.fractionLength(0...1))))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Calculation mode. Nutrient-target and fertigation modes arrive in phase 2.
nonisolated enum FertiliserCalcMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case perHectare
    case perVine

    var id: String { rawValue }
    var label: String { self == .perHectare ? "Per hectare" : "Per vine" }
}

nonisolated enum FertiliserRecordStatus: String, Codable, Sendable {
    case draft
    case planned
    case completed
    case cancelled

    var label: String {
        switch self {
        case .draft: return "Draft"
        case .planned: return "Planned"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Per-block share of a multi-block calculation, so block-level costing and
/// reporting stay accurate (mirrors `fertiliser_record_allocations`).
nonisolated struct FertiliserAllocation: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var paddockId: UUID
    var areaHectares: Double
    var vineCount: Int
    var rate: Double
    var productRequired: Double
    var allocatedCost: Double?

    init(
        id: UUID = UUID(),
        paddockId: UUID,
        areaHectares: Double,
        vineCount: Int,
        rate: Double,
        productRequired: Double,
        allocatedCost: Double? = nil
    ) {
        self.id = id
        self.paddockId = paddockId
        self.areaHectares = areaHectares
        self.vineCount = vineCount
        self.rate = rate
        self.productRequired = productRequired
        self.allocatedCost = allocatedCost
    }
}

/// A saved calculation — either a planned work task or a completed
/// fertiliser application record. `productId` references the shared saved
/// chemical/product library (`saved_chemicals.id`); `productName`, `form` and
/// `packSize` are historical snapshots taken at calculation time.
nonisolated struct FertiliserRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var date: Date
    var status: FertiliserRecordStatus
    var mode: FertiliserCalcMode
    var productId: UUID?
    var productName: String
    var form: FertiliserForm
    var paddockIds: [UUID]
    var blockNames: [String]
    var areaHectares: Double
    var vineCount: Int
    /// kg/ha or L/ha (per-hectare mode); g/vine or mL/vine (per-vine mode).
    var rate: Double
    /// Total product in kg or L.
    var totalProduct: Double
    var packSize: Double?
    var productCost: Double?
    var labourMachineryCost: Double?
    var notes: String
    /// Per-block breakdown for multi-block calculations.
    var allocations: [FertiliserAllocation]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        date: Date = Date(),
        status: FertiliserRecordStatus,
        mode: FertiliserCalcMode,
        productId: UUID? = nil,
        productName: String,
        form: FertiliserForm,
        paddockIds: [UUID],
        blockNames: [String],
        areaHectares: Double,
        vineCount: Int,
        rate: Double,
        totalProduct: Double,
        packSize: Double? = nil,
        productCost: Double? = nil,
        labourMachineryCost: Double? = nil,
        notes: String = "",
        allocations: [FertiliserAllocation] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.date = date
        self.status = status
        self.mode = mode
        self.productId = productId
        self.productName = productName
        self.form = form
        self.paddockIds = paddockIds
        self.blockNames = blockNames
        self.areaHectares = areaHectares
        self.vineCount = vineCount
        self.rate = rate
        self.totalProduct = totalProduct
        self.packSize = packSize
        self.productCost = productCost
        self.labourMachineryCost = labourMachineryCost
        self.notes = notes
        self.allocations = allocations
        self.createdAt = createdAt
    }

    var totalCost: Double? {
        switch (productCost, labourMachineryCost) {
        case let (product?, labour?): return product + labour
        case let (product?, nil): return product
        case let (nil, labour?): return labour
        default: return nil
        }
    }

    var rateUnit: String {
        switch mode {
        case .perHectare: return "\(form.unit)/ha"
        case .perVine: return "\(form.perVineUnit)/vine"
        }
    }
}

/// Pure calculation helpers for the Fertiliser Calculator.
nonisolated enum FertiliserCalculator {

    /// Per-hectare mode: required product = treated hectares × rate (kg/ha or L/ha).
    static func totalForPerHectare(areaHectares: Double, ratePerHa: Double) -> Double {
        max(areaHectares, 0) * max(ratePerHa, 0)
    }

    /// Per-vine mode: total = vines × grams (or mL) per vine, returned in kg (or L).
    static func totalForPerVine(vineCount: Int, ratePerVine: Double) -> Double {
        Double(max(vineCount, 0)) * max(ratePerVine, 0) / 1_000.0
    }

    /// Packs required (fractional) for a total amount.
    static func packsRequired(total: Double, packSize: Double) -> Double? {
        guard packSize > 0 else { return nil }
        return total / packSize
    }

    /// Pro-rata product cost for the amount actually used.
    static func productCost(total: Double, packSize: Double, pricePerPack: Double?) -> Double? {
        guard let pricePerPack, packSize > 0 else { return nil }
        return total / packSize * pricePerPack
    }
}
