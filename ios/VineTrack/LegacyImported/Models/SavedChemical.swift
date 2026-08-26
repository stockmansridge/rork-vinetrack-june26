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

    /// The physical dimension this unit measures.
    ///
    /// Litres and millilitres are the SAME quantity written two ways, as are
    /// kilograms and grams — which is exactly why every dosage is stored in
    /// the family's base (mL or g) and only displayed through `fromBase`.
    /// Volume and mass are not interchangeable at all.
    var dimension: ChemicalUnitDimension {
        switch self {
        case .litres, .millilitres: return .volume
        case .kilograms, .grams: return .mass
        }
    }

    /// Whether a stored BASE value means the same thing under both units.
    ///
    /// True only within one family, where the base unit is shared and the
    /// magnitude therefore needs no conversion. Across families it is false and
    /// stays false: turning millilitres into grams requires a density this app
    /// does not hold per dosage, so the honest answer is to refuse rather than
    /// to invent one.
    func isDimensionallyCompatible(with other: ChemicalUnit) -> Bool {
        dimension == other.dimension
    }
}

/// Volume vs mass — the boundary no dosage may silently cross.
nonisolated enum ChemicalUnitDimension: Sendable, Hashable {
    case volume
    case mass
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

    nonisolated enum CodingKeys: String, CodingKey {
        case id, label, value, basis
    }

    /// Tolerant decode (P4 cross-platform parity).
    ///
    /// The synthesised decoder required all four keys, so ONE canonical row
    /// written by the portal or another client without a rate `id` threw and
    /// took the operator's ENTIRE chemical out of the Chemical Store. Every
    /// field now falls back to its documented default and an absent `id`
    /// becomes a fresh local list identity — a UI handle, never chemistry.
    /// No rate value, unit or basis is ever invented: a missing basis reads
    /// as the model's own default exactly as a fresh `ChemicalRate` would.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        value = (try? c.decodeIfPresent(Double.self, forKey: .value)) ?? 0
        let rawBasis = (try? c.decodeIfPresent(String.self, forKey: .basis)) ?? ""
        basis = ChemicalRateBasis(rawValue: rawBasis) ?? .perHectare
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

    nonisolated enum CodingKeys: String, CodingKey {
        case brand, activeIngredient, chemicalGroup, labelURL
        case costDollars, containerSizeML, containerUnit
    }

    /// Tolerant decode (P4 cross-platform parity).
    ///
    /// Android models every purchase field with a default, so a partial
    /// `purchase` object round-trips there; iOS's synthesised decoder
    /// required all seven keys and threw, dropping the whole chemical. The
    /// costing fields now degrade individually — an unreadable container
    /// unit reads as the model default rather than destroying the record.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brand = (try? c.decodeIfPresent(String.self, forKey: .brand)) ?? ""
        activeIngredient = (try? c.decodeIfPresent(String.self, forKey: .activeIngredient)) ?? ""
        chemicalGroup = (try? c.decodeIfPresent(String.self, forKey: .chemicalGroup)) ?? ""
        labelURL = (try? c.decodeIfPresent(String.self, forKey: .labelURL)) ?? ""
        costDollars = (try? c.decodeIfPresent(Double.self, forKey: .costDollars)) ?? 0
        containerSizeML = (try? c.decodeIfPresent(Double.self, forKey: .containerSizeML)) ?? 0
        let rawUnit = (try? c.decodeIfPresent(String.self, forKey: .containerUnit)) ?? ""
        containerUnit = ChemicalUnit(rawValue: rawUnit) ?? .litres
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

    // MARK: Unified product library fields (sql/111)
    // Fertilisers and nutrient products are saved products in the same
    // library. These fields are optional/defaulted so ordinary spray
    // chemicals never need them.

    /// `ProductCategory` raw key; "" = uncategorised (legacy spray chemical).
    var productCategory: String
    /// "solid" | "liquid" | "" (unspecified — derived from `unit` when empty).
    var productForm: String
    /// Pack size in kg (solid) or L (liquid).
    var packSize: Double?
    var packUnit: String
    var pricePerPack: Double?
    /// kg per litre, for liquid products where relevant.
    var density: Double?
    var nitrogenPercent: Double?
    var phosphorusPercent: Double?
    var potassiumPercent: Double?
    /// "elemental" or "oxide" (P₂O₅ / K₂O label values).
    var analysisBasis: String
    var organicCertified: Bool
    /// Stock on hand (in `inventoryUnit`, typically packs).
    var inventoryQuantity: Double?
    var inventoryUnit: String
    var applicationNotes: String
    var isActive: Bool

    // MARK: Chemical Intelligence (sql/194)

    /// Structured, verification-aware chemical information.
    ///
    /// This — not `chemicalGroup` — is the resistance authority. The scalar
    /// `activeIngredient` / `chemicalGroup` fields above stay exactly where
    /// they are for old app builds and the existing API, and are written as
    /// DERIVED projections of this value whenever it is present.
    ///
    /// `nil` on every chemical saved before Chemical Intelligence. Use
    /// `resolvedIntelligence` to read a legacy record as a candidate without
    /// mutating it or implying it has been verified.
    var chemicalIntelligence: ChemicalIntelligence?

    // MARK: Master Chemical Catalogue (sql/199)

    /// Link to the shared master catalogue product this record was derived
    /// from. Set only by identity-exact flows — never name similarity, never
    /// backfill. `nil` is valid forever: an unlinked chemical keeps working
    /// exactly as before.
    var masterChemicalId: UUID?
    /// The master `catalogue_version` the structured chemistry was copied at.
    /// A larger current master revision means “updated verified information
    /// available” via Re-verify; master updates never rewrite this record.
    var masterSourceRevision: Int?

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
        modeOfAction: String = "",
        productCategory: String = "",
        productForm: String = "",
        packSize: Double? = nil,
        packUnit: String = "",
        pricePerPack: Double? = nil,
        density: Double? = nil,
        nitrogenPercent: Double? = nil,
        phosphorusPercent: Double? = nil,
        potassiumPercent: Double? = nil,
        analysisBasis: String = "elemental",
        organicCertified: Bool = false,
        inventoryQuantity: Double? = nil,
        inventoryUnit: String = "",
        applicationNotes: String = "",
        isActive: Bool = true,
        chemicalIntelligence: ChemicalIntelligence? = nil,
        masterChemicalId: UUID? = nil,
        masterSourceRevision: Int? = nil
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
        self.productCategory = productCategory
        self.productForm = productForm
        self.packSize = packSize
        self.packUnit = packUnit
        self.pricePerPack = pricePerPack
        self.density = density
        self.nitrogenPercent = nitrogenPercent
        self.phosphorusPercent = phosphorusPercent
        self.potassiumPercent = potassiumPercent
        self.analysisBasis = analysisBasis
        self.organicCertified = organicCertified
        self.inventoryQuantity = inventoryQuantity
        self.inventoryUnit = inventoryUnit
        self.applicationNotes = applicationNotes
        self.isActive = isActive
        self.chemicalIntelligence = chemicalIntelligence
        self.masterChemicalId = masterChemicalId
        self.masterSourceRevision = masterSourceRevision
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, ratePerHa, unit, chemicalGroup, use, manufacturer
        case restrictions, notes, crop, problem, activeIngredient, rates, purchase
        case labelURL, productURL, modeOfAction
        case productCategory, productForm, packSize, packUnit, pricePerPack
        case density, nitrogenPercent, phosphorusPercent, potassiumPercent
        case analysisBasis, organicCertified, inventoryQuantity, inventoryUnit
        case applicationNotes, isActive
        case chemicalIntelligence
        case masterChemicalId, masterSourceRevision
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
        // Tolerant (P4): a malformed rate or purchase degrades to the empty
        // default instead of failing the whole chemical.
        rates = (try? container.decodeIfPresent([ChemicalRate].self, forKey: .rates)) ?? []
        purchase = try? container.decodeIfPresent(ChemicalPurchase.self, forKey: .purchase)
        labelURL = LabelURLValidator.sanitize(try container.decodeIfPresent(String.self, forKey: .labelURL) ?? "")
        // Product URL is user-facing as a non-label link; sanitize for
        // placeholder hosts but do not require a document path.
        productURL = LabelURLValidator.sanitize(try container.decodeIfPresent(String.self, forKey: .productURL) ?? "")
        modeOfAction = try container.decodeIfPresent(String.self, forKey: .modeOfAction) ?? ""
        productCategory = try container.decodeIfPresent(String.self, forKey: .productCategory) ?? ""
        productForm = try container.decodeIfPresent(String.self, forKey: .productForm) ?? ""
        packSize = try container.decodeIfPresent(Double.self, forKey: .packSize)
        packUnit = try container.decodeIfPresent(String.self, forKey: .packUnit) ?? ""
        pricePerPack = try container.decodeIfPresent(Double.self, forKey: .pricePerPack)
        density = try container.decodeIfPresent(Double.self, forKey: .density)
        nitrogenPercent = try container.decodeIfPresent(Double.self, forKey: .nitrogenPercent)
        phosphorusPercent = try container.decodeIfPresent(Double.self, forKey: .phosphorusPercent)
        potassiumPercent = try container.decodeIfPresent(Double.self, forKey: .potassiumPercent)
        analysisBasis = try container.decodeIfPresent(String.self, forKey: .analysisBasis) ?? "elemental"
        organicCertified = try container.decodeIfPresent(Bool.self, forKey: .organicCertified) ?? false
        inventoryQuantity = try container.decodeIfPresent(Double.self, forKey: .inventoryQuantity)
        inventoryUnit = try container.decodeIfPresent(String.self, forKey: .inventoryUnit) ?? ""
        applicationNotes = try container.decodeIfPresent(String.self, forKey: .applicationNotes) ?? ""
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        // Additive and tolerant: a chemical saved before Chemical Intelligence
        // has none, and a malformed payload degrades to nil so the chemical
        // still loads and still works everywhere it did before.
        chemicalIntelligence = try? container.decodeIfPresent(
            ChemicalIntelligence.self, forKey: .chemicalIntelligence)
        // Master catalogue link (sql/199): additive and tolerant — records
        // saved before the catalogue existed simply have none.
        masterChemicalId = try? container.decodeIfPresent(UUID.self, forKey: .masterChemicalId)
        masterSourceRevision = try? container.decodeIfPresent(Int.self, forKey: .masterSourceRevision)
    }
}

// MARK: - Chemical Intelligence access

extension SavedChemical {
    /// Structured intelligence for this chemical, falling back to a CANDIDATE
    /// reading of the legacy scalar fields when none has been stored.
    ///
    /// The fallback is explicitly `.needsMatch` and sourced `.legacyRecord`, so
    /// it can populate the audit and pre-fill the verification screen while
    /// being structurally incapable of passing as verified.
    var resolvedIntelligence: ChemicalIntelligence {
        if let chemicalIntelligence, !chemicalIntelligence.isEmpty {
            return chemicalIntelligence
        }
        return ChemicalIntelligence.legacySeed(
            activeIngredientText: activeIngredient,
            chemicalGroupText: chemicalGroup,
            modeOfActionText: modeOfAction,
            productCategory: productCategory,
            manufacturer: manufacturer,
            countryCode: chemicalIntelligence?.registration?.countryCode ?? ""
        )
    }

    /// The trust level to DISPLAY for this chemical.
    var verificationStatus: ChemicalVerificationStatus {
        resolvedIntelligence.resolvedVerificationStatus
    }

    /// Machine-readable group codes, e.g. `["3", "11"]`.
    ///
    /// Empty when nothing dependable is known — which is the honest answer, and
    /// the reason nothing in VineTrack may fall back to splitting
    /// `chemicalGroup` on "+".
    var activityGroupCodes: [String] {
        resolvedIntelligence.activityGroupCodes
    }

    /// The Phase 16 contract handed to the future Resistance Rules Engine.
    ///
    /// The engine consumes this and nothing else — no `SavedChemical`, no
    /// `"Group 3 + 11"` parsing, no label scraping.
    func resistanceProfile() -> ChemicalResistanceProfile {
        let intel = resolvedIntelligence
        return ChemicalResistanceProfile(
            productId: id,
            productName: name,
            registrationIdentityKey: intel.registration?.identityKey,
            countryCode: intel.registration?.countryCode ?? "",
            activeIngredients: intel.activeIngredients,
            activityGroups: intel.activityGroups,
            verificationStatus: intel.resolvedVerificationStatus,
            registeredUses: intel.registeredUses,
            labelRateBases: intel.labelRateBases,
            sourceVersion: "\(intel.schemaVersion).\(intel.activityGroupTableVersion)"
        )
    }

    /// The legacy scalar values this chemical should PERSIST, derived from its
    /// structured intelligence.
    ///
    /// Applied on save so `chemical_group` stays a faithful `"3 + 11"` mirror
    /// for old clients while never being the source of a calculation.
    /// Returns the existing values untouched when there is no intelligence, so
    /// a legacy chemical is never rewritten by the mere act of saving it.
    var legacyProjection: (activeIngredient: String, chemicalGroup: String) {
        guard let intel = chemicalIntelligence, !intel.isEmpty else {
            return (activeIngredient, chemicalGroup)
        }
        let groups = intel.legacyChemicalGroup
        let actives = intel.legacyActiveIngredient
        return (
            actives.isEmpty ? activeIngredient : actives,
            groups.isEmpty ? chemicalGroup : groups
        )
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
