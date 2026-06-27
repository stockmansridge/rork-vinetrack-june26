import Foundation

nonisolated enum ChemicalUnit: String, CaseIterable, Codable, Sendable {
    case litres = "Litres"
    case millilitres = "mL"
    case kilograms = "Kg"
    case grams = "g"

    func toBase(_ value: Double) -> Double {
        switch self {
        case .litres: return value * 1000
        case .millilitres: return value
        case .kilograms: return value * 1000
        case .grams: return value
        }
    }

    func fromBase(_ value: Double) -> Double {
        switch self {
        case .litres: return value / 1000
        case .millilitres: return value
        case .kilograms: return value / 1000
        case .grams: return value
        }
    }

    var baseLabel: String {
        switch self {
        case .litres, .millilitres: return "mL"
        case .kilograms, .grams: return "g"
        }
    }
}

nonisolated enum ChemicalRateBasis: String, Codable, Sendable {
    case perHectare = "per_hectare"
    case per100Litres = "per_100_litres"
}

nonisolated struct ChemicalRate: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var label: String
    var value: Double
    var basis: ChemicalRateBasis

    init(id: UUID = UUID(), label: String = "", value: Double = 0, basis: ChemicalRateBasis = .perHectare) {
        self.id = id
        self.label = label
        self.value = value
        self.basis = basis
    }
}

nonisolated struct ChemicalPurchase: Codable, Sendable, Hashable {
    var brand: String
    var activeIngredient: String
    var chemicalGroup: String
    var labelURL: String
    var costDollars: Double
    var containerSizeML: Double
    var containerUnit: ChemicalUnit

    var costPerBaseUnit: Double {
        let containerInBase = containerUnit.toBase(containerSizeML)
        guard containerInBase > 0 else { return 0 }
        return costDollars / containerInBase
    }

    init(
        brand: String = "",
        activeIngredient: String = "",
        chemicalGroup: String = "",
        labelURL: String = "",
        costDollars: Double = 0,
        containerSizeML: Double = 0,
        containerUnit: ChemicalUnit = .litres
    ) {
        self.brand = brand
        self.activeIngredient = activeIngredient
        self.chemicalGroup = chemicalGroup
        self.labelURL = labelURL
        self.costDollars = costDollars
        self.containerSizeML = containerSizeML
        self.containerUnit = containerUnit
    }
}

nonisolated struct SavedChemical: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var ratePerHa: Double
    var unit: ChemicalUnit
    var chemicalGroup: String
    var use: String
    var manufacturer: String
    var restrictions: String
    var notes: String
    var crop: String
    var problem: String
    var activeIngredient: String
    var rates: [ChemicalRate]
    var purchase: ChemicalPurchase?
    var labelURL: String
    /// Optional manufacturer/product marketing page. Distinct from
    /// `labelURL` — must NEVER be displayed as a "Label" link in the UI.
    /// Show separately as "Product page" / "Manufacturer page".
    var productURL: String
    var modeOfAction: String

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        ratePerHa: Double = 0,
        unit: ChemicalUnit = .litres,
        chemicalGroup: String = "",
        use: String = "",
        manufacturer: String = "",
        restrictions: String = "",
        notes: String = "",
        crop: String = "",
        problem: String = "",
        activeIngredient: String = "",
        rates: [ChemicalRate] = [],
        purchase: ChemicalPurchase? = nil,
        labelURL: String = "",
        productURL: String = "",
        modeOfAction: String = ""
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.ratePerHa = ratePerHa
        self.unit = unit
        self.chemicalGroup = chemicalGroup
        self.use = use
        self.manufacturer = manufacturer
        self.restrictions = restrictions
        self.notes = notes
        self.crop = crop
        self.problem = problem
        self.activeIngredient = activeIngredient
        self.rates = rates
        self.purchase = purchase
        self.labelURL = labelURL
        self.productURL = productURL
        self.modeOfAction = modeOfAction
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, ratePerHa, unit, chemicalGroup, use, manufacturer
        case restrictions, notes, crop, problem, activeIngredient, rates, purchase
        case labelURL, productURL, modeOfAction
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        ratePerHa = try container.decodeIfPresent(Double.self, forKey: .ratePerHa) ?? 0
        unit = try container.decodeIfPresent(ChemicalUnit.self, forKey: .unit) ?? .litres
        chemicalGroup = try container.decodeIfPresent(String.self, forKey: .chemicalGroup) ?? ""
        use = try container.decodeIfPresent(String.self, forKey: .use) ?? ""
        manufacturer = try container.decodeIfPresent(String.self, forKey: .manufacturer) ?? ""
        restrictions = try container.decodeIfPresent(String.self, forKey: .restrictions) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        crop = try container.decodeIfPresent(String.self, forKey: .crop) ?? ""
        problem = try container.decodeIfPresent(String.self, forKey: .problem) ?? ""
        activeIngredient = try container.decodeIfPresent(String.self, forKey: .activeIngredient) ?? ""
        rates = try container.decodeIfPresent([ChemicalRate].self, forKey: .rates) ?? []
        purchase = try container.decodeIfPresent(ChemicalPurchase.self, forKey: .purchase)
        labelURL = LabelURLValidator.sanitize(try container.decodeIfPresent(String.self, forKey: .labelURL) ?? "")
        // Product URL is user-facing as a non-label link; sanitize for
        // placeholder hosts but do not require a document path.
        productURL = LabelURLValidator.sanitize(try container.decodeIfPresent(String.self, forKey: .productURL) ?? "")
        modeOfAction = try container.decodeIfPresent(String.self, forKey: .modeOfAction) ?? ""
    }
}

nonisolated struct SavedSprayPreset: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var waterVolume: Double
    var sprayRatePerHa: Double
    var concentrationFactor: Double

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        waterVolume: Double = 0,
        sprayRatePerHa: Double = 0,
        concentrationFactor: Double = 1.0
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.waterVolume = waterVolume
        self.sprayRatePerHa = sprayRatePerHa
        self.concentrationFactor = concentrationFactor
    }
}
