import Foundation

// MARK: - Saved Chemicals

nonisolated struct BackendSavedChemical: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String?
    let ratePerHa: Double?
    let unit: String?
    let chemicalGroup: String?
    let use: String?
    let manufacturer: String?
    let restrictions: String?
    let notes: String?
    let crop: String?
    let problem: String?
    let activeIngredient: String?
    let rates: [ChemicalRate]?
    let purchase: ChemicalPurchase?
    let labelUrl: String?
    let productUrl: String?
    let modeOfAction: String?
    let productCategory: String?
    let productForm: String?
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
    // Chemical Intelligence (sql/194). Nullable throughout so a backend that
    // has not yet had sql/194 applied still decodes.
    let activeIngredients: [ChemicalActiveIngredient]?
    let activityGroups: [String]?
    let activityGroupScheme: String?
    let registrationCountry: String?
    let registrationScheme: String?
    let registrationNumber: String?
    let registrant: String?
    let registeredProductName: String?
    let labelReference: String?
    let labelVersion: String?
    let verificationStatus: String?
    let verificationSources: [ChemicalDataSource]?
    let verificationConflicts: [ChemicalVerificationConflict]?
    let verificationUnresolvedFields: [String]?
    let verifiedAt: Date?
    let registeredUses: [ChemicalRegisteredUse]?
    let labelRateBases: [String]?
    let activityGroupTableVersion: Int?
    let intelligenceSchemaVersion: Int?
    // Master Chemical Catalogue link (sql/199). Nullable throughout so a
    // backend that has not yet had sql/199 applied still decodes.
    let masterChemicalId: UUID?
    let masterSourceRevision: Int?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case ratePerHa = "rate_per_ha"
        case unit
        case chemicalGroup = "chemical_group"
        case use
        case manufacturer
        case restrictions
        case notes
        case crop
        case problem
        case activeIngredient = "active_ingredient"
        case rates
        case purchase
        case labelUrl = "label_url"
        case productUrl = "product_url"
        case modeOfAction = "mode_of_action"
        case productCategory = "product_category"
        case productForm = "product_form"
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
        case activeIngredients = "active_ingredients"
        case activityGroups = "activity_groups"
        case activityGroupScheme = "activity_group_scheme"
        case registrationCountry = "registration_country"
        case registrationScheme = "registration_scheme"
        case registrationNumber = "registration_number"
        case registrant
        case registeredProductName = "registered_product_name"
        case labelReference = "label_reference"
        case labelVersion = "label_version"
        case verificationStatus = "verification_status"
        case verificationSources = "verification_sources"
        case verificationConflicts = "verification_conflicts"
        case verificationUnresolvedFields = "verification_unresolved_fields"
        case verifiedAt = "verified_at"
        case registeredUses = "registered_uses"
        case labelRateBases = "label_rate_bases"
        case activityGroupTableVersion = "activity_group_table_version"
        case intelligenceSchemaVersion = "intelligence_schema_version"
        case masterChemicalId = "master_chemical_id"
        case masterSourceRevision = "master_source_revision"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.ratePerHa = try c.decodeIfPresent(Double.self, forKey: .ratePerHa)
        self.unit = try c.decodeIfPresent(String.self, forKey: .unit)
        self.chemicalGroup = try c.decodeIfPresent(String.self, forKey: .chemicalGroup)
        self.use = try c.decodeIfPresent(String.self, forKey: .use)
        self.manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        self.restrictions = try c.decodeIfPresent(String.self, forKey: .restrictions)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.crop = try c.decodeIfPresent(String.self, forKey: .crop)
        self.problem = try c.decodeIfPresent(String.self, forKey: .problem)
        self.activeIngredient = try c.decodeIfPresent(String.self, forKey: .activeIngredient)
        self.rates = try c.decodeIfPresent([ChemicalRate].self, forKey: .rates)
        self.purchase = try c.decodeIfPresent(ChemicalPurchase.self, forKey: .purchase)
        self.labelUrl = try c.decodeIfPresent(String.self, forKey: .labelUrl)
        // product_url was added in sql/086; tolerate older rows where the
        // column is absent so decoding doesn't fail for legacy backends.
        self.productUrl = try c.decodeIfPresent(String.self, forKey: .productUrl)
        self.modeOfAction = try c.decodeIfPresent(String.self, forKey: .modeOfAction)
        // Unified product-library columns were added in sql/111; tolerate
        // older backends where they are absent.
        self.productCategory = try c.decodeIfPresent(String.self, forKey: .productCategory)
        self.productForm = try c.decodeIfPresent(String.self, forKey: .productForm)
        self.packSize = try c.decodeIfPresent(Double.self, forKey: .packSize)
        self.packUnit = try c.decodeIfPresent(String.self, forKey: .packUnit)
        self.pricePerPack = try c.decodeIfPresent(Double.self, forKey: .pricePerPack)
        self.density = try c.decodeIfPresent(Double.self, forKey: .density)
        self.nitrogenPercent = try c.decodeIfPresent(Double.self, forKey: .nitrogenPercent)
        self.phosphorusPercent = try c.decodeIfPresent(Double.self, forKey: .phosphorusPercent)
        self.potassiumPercent = try c.decodeIfPresent(Double.self, forKey: .potassiumPercent)
        self.analysisBasis = try c.decodeIfPresent(String.self, forKey: .analysisBasis)
        self.organicCertified = try c.decodeIfPresent(Bool.self, forKey: .organicCertified)
        self.inventoryQuantity = try c.decodeIfPresent(Double.self, forKey: .inventoryQuantity)
        self.inventoryUnit = try c.decodeIfPresent(String.self, forKey: .inventoryUnit)
        self.applicationNotes = try c.decodeIfPresent(String.self, forKey: .applicationNotes)
        self.isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
        // Chemical Intelligence columns were added in sql/194. Every one is
        // read with `try?` so a backend without the migration — or a payload
        // written by a newer build — degrades to nil instead of failing the
        // whole chemical and emptying the operator's Chemical Store.
        self.activeIngredients = try? c.decodeIfPresent([ChemicalActiveIngredient].self, forKey: .activeIngredients)
        self.activityGroups = try? c.decodeIfPresent([String].self, forKey: .activityGroups)
        self.activityGroupScheme = try? c.decodeIfPresent(String.self, forKey: .activityGroupScheme)
        self.registrationCountry = try? c.decodeIfPresent(String.self, forKey: .registrationCountry)
        self.registrationScheme = try? c.decodeIfPresent(String.self, forKey: .registrationScheme)
        self.registrationNumber = try? c.decodeIfPresent(String.self, forKey: .registrationNumber)
        self.registrant = try? c.decodeIfPresent(String.self, forKey: .registrant)
        self.registeredProductName = try? c.decodeIfPresent(String.self, forKey: .registeredProductName)
        self.labelReference = try? c.decodeIfPresent(String.self, forKey: .labelReference)
        self.labelVersion = try? c.decodeIfPresent(String.self, forKey: .labelVersion)
        self.verificationStatus = try? c.decodeIfPresent(String.self, forKey: .verificationStatus)
        self.verificationSources = try? c.decodeIfPresent([ChemicalDataSource].self, forKey: .verificationSources)
        self.verificationConflicts = try? c.decodeIfPresent([ChemicalVerificationConflict].self, forKey: .verificationConflicts)
        self.verificationUnresolvedFields = try? c.decodeIfPresent([String].self, forKey: .verificationUnresolvedFields)
        self.verifiedAt = try? c.decodeIfPresent(Date.self, forKey: .verifiedAt)
        self.registeredUses = try? c.decodeIfPresent([ChemicalRegisteredUse].self, forKey: .registeredUses)
        self.labelRateBases = try? c.decodeIfPresent([String].self, forKey: .labelRateBases)
        self.activityGroupTableVersion = try? c.decodeIfPresent(Int.self, forKey: .activityGroupTableVersion)
        self.intelligenceSchemaVersion = try? c.decodeIfPresent(Int.self, forKey: .intelligenceSchemaVersion)
        // Master catalogue link columns were added in sql/199 — tolerant for
        // backends that predate them.
        self.masterChemicalId = try? c.decodeIfPresent(UUID.self, forKey: .masterChemicalId)
        self.masterSourceRevision = try? c.decodeIfPresent(Int.self, forKey: .masterSourceRevision)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.clientUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .clientUpdatedAt)
    }
}

nonisolated struct BackendSavedChemicalUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let ratePerHa: Double
    let unit: String
    let chemicalGroup: String
    let use: String
    let manufacturer: String
    let restrictions: String
    let notes: String
    let crop: String
    let problem: String
    let activeIngredient: String
    let rates: [ChemicalRate]
    let purchase: ChemicalPurchase?
    let labelUrl: String
    let productUrl: String
    let modeOfAction: String
    let productCategory: String
    let productForm: String
    let packSize: Double?
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
    let isActive: Bool
    // Chemical Intelligence (sql/194).
    let activeIngredients: [ChemicalActiveIngredient]?
    let activityGroups: [String]?
    let activityGroupScheme: String?
    let registrationCountry: String?
    let registrationScheme: String?
    let registrationNumber: String?
    let registrant: String?
    let registeredProductName: String?
    let labelReference: String?
    let labelVersion: String?
    let verificationStatus: String
    let verificationSources: [ChemicalDataSource]?
    let verificationConflicts: [ChemicalVerificationConflict]?
    let verificationUnresolvedFields: [String]?
    let verifiedAt: Date?
    let registeredUses: [ChemicalRegisteredUse]?
    let labelRateBases: [String]?
    let activityGroupTableVersion: Int?
    let intelligenceSchemaVersion: Int
    // Master Chemical Catalogue link (sql/199). Optionals are OMITTED from the
    // upsert payload when nil, so a device that never learned about the
    // catalogue can never blank out a link the portal or another device set.
    let masterChemicalId: UUID?
    let masterSourceRevision: Int?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case ratePerHa = "rate_per_ha"
        case unit
        case chemicalGroup = "chemical_group"
        case use
        case manufacturer
        case restrictions
        case notes
        case crop
        case problem
        case activeIngredient = "active_ingredient"
        case rates
        case purchase
        case labelUrl = "label_url"
        case productUrl = "product_url"
        case modeOfAction = "mode_of_action"
        case productCategory = "product_category"
        case productForm = "product_form"
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
        case activeIngredients = "active_ingredients"
        case activityGroups = "activity_groups"
        case activityGroupScheme = "activity_group_scheme"
        case registrationCountry = "registration_country"
        case registrationScheme = "registration_scheme"
        case registrationNumber = "registration_number"
        case registrant
        case registeredProductName = "registered_product_name"
        case labelReference = "label_reference"
        case labelVersion = "label_version"
        case verificationStatus = "verification_status"
        case verificationSources = "verification_sources"
        case verificationConflicts = "verification_conflicts"
        case verificationUnresolvedFields = "verification_unresolved_fields"
        case verifiedAt = "verified_at"
        case registeredUses = "registered_uses"
        case labelRateBases = "label_rate_bases"
        case activityGroupTableVersion = "activity_group_table_version"
        case intelligenceSchemaVersion = "intelligence_schema_version"
        case masterChemicalId = "master_chemical_id"
        case masterSourceRevision = "master_source_revision"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendSavedChemical {
    static func upsert(from c: SavedChemical, createdBy: UUID?, clientUpdatedAt: Date) -> BackendSavedChemicalUpsert {
        let intel = c.chemicalIntelligence
        // The legacy scalars are written as DERIVED projections whenever
        // structured intelligence exists, so old app builds and the existing
        // API keep seeing a familiar "3 + 11". When it does not exist the
        // operator's own values pass through untouched — saving a legacy
        // chemical must never rewrite it.
        let legacy = c.legacyProjection
        return BackendSavedChemicalUpsert(
            id: c.id,
            vineyardId: c.vineyardId,
            name: c.name,
            ratePerHa: c.ratePerHa,
            unit: c.unit.rawValue,
            chemicalGroup: legacy.chemicalGroup,
            use: c.use,
            manufacturer: c.manufacturer,
            restrictions: c.restrictions,
            notes: c.notes,
            crop: c.crop,
            problem: c.problem,
            activeIngredient: legacy.activeIngredient,
            rates: c.rates,
            purchase: c.purchase,
            labelUrl: c.labelURL,
            productUrl: c.productURL,
            modeOfAction: c.modeOfAction,
            productCategory: c.productCategory,
            productForm: c.productForm,
            packSize: c.packSize,
            packUnit: c.packUnit,
            pricePerPack: c.pricePerPack,
            density: c.density,
            nitrogenPercent: c.nitrogenPercent,
            phosphorusPercent: c.phosphorusPercent,
            potassiumPercent: c.potassiumPercent,
            analysisBasis: c.analysisBasis,
            organicCertified: c.organicCertified,
            inventoryQuantity: c.inventoryQuantity,
            inventoryUnit: c.inventoryUnit,
            applicationNotes: c.applicationNotes,
            isActive: c.isActive,
            activeIngredients: intel?.activeIngredients,
            // Written from the structured actives every time, so the queryable
            // text[] can never drift out of step with them.
            activityGroups: intel?.activityGroupCodes,
            activityGroupScheme: intel?.activityGroups.first?.scheme.rawValue,
            registrationCountry: intel?.registration?.countryCode,
            registrationScheme: intel?.registration?.scheme?.rawValue,
            registrationNumber: intel?.registration?.registrationNumber,
            registrant: intel?.registration?.registrant,
            registeredProductName: intel?.registration?.registeredProductName,
            labelReference: intel?.registration?.labelReference,
            labelVersion: intel?.registration?.labelVersion,
            // The RESOLVED status, never the stored one: a status is a claim
            // about evidence, and it is re-derived from that evidence on every
            // write so an over-optimistic value can never be persisted.
            verificationStatus: (intel?.resolvedVerificationStatus ?? .needsMatch).rawValue,
            verificationSources: intel?.verification.sources,
            verificationConflicts: intel?.verification.conflicts,
            verificationUnresolvedFields: intel?.verification.unresolvedFields,
            verifiedAt: intel?.verification.verifiedAt,
            registeredUses: intel?.registeredUses,
            labelRateBases: intel?.labelRateBases.map(\.rawValue),
            activityGroupTableVersion: intel?.activityGroupTableVersion,
            intelligenceSchemaVersion: intel?.schemaVersion ?? 0,
            masterChemicalId: c.masterChemicalId,
            masterSourceRevision: c.masterSourceRevision,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    /// Rebuilds structured intelligence from the sql/194 columns.
    ///
    /// Returns `nil` when the backend carries nothing structured, so the
    /// chemical falls through to `SavedChemical.resolvedIntelligence` and is
    /// read as an unmatched legacy record rather than an empty verified one.
    private func decodedIntelligence() -> ChemicalIntelligence? {
        let actives = activeIngredients ?? []
        let uses = registeredUses ?? []
        let hasRegistration = (registrationNumber?.isEmpty == false)
            || (registrationCountry?.isEmpty == false)
        guard !actives.isEmpty || !uses.isEmpty || hasRegistration else { return nil }

        let registration: ChemicalRegistration? = hasRegistration
            ? ChemicalRegistration(
                countryCode: registrationCountry ?? "",
                scheme: registrationScheme.flatMap { ChemicalRegistrationScheme(rawValue: $0) },
                registrationNumber: registrationNumber,
                registrant: registrant,
                registeredProductName: registeredProductName,
                labelReference: labelReference,
                labelVersion: labelVersion
            )
            : nil

        let verification = ChemicalVerification(
            status: ChemicalVerificationStatus(rawValue: verificationStatus ?? "") ?? .unverified,
            sources: verificationSources ?? [],
            verifiedAt: verifiedAt,
            conflicts: verificationConflicts ?? [],
            unresolvedFields: verificationUnresolvedFields ?? []
        )

        return ChemicalIntelligence(
            activeIngredients: actives,
            registration: registration,
            verification: verification,
            registeredUses: uses,
            productCategory: productCategory ?? "",
            activityGroupTableVersion: activityGroupTableVersion ?? 0,
            schemaVersion: intelligenceSchemaVersion ?? 0
        )
    }

    func toSavedChemical() -> SavedChemical {
        SavedChemical(
            id: id,
            vineyardId: vineyardId,
            name: name ?? "",
            ratePerHa: ratePerHa ?? 0,
            unit: ChemicalUnit(rawValue: unit ?? "") ?? .litres,
            chemicalGroup: chemicalGroup ?? "",
            use: use ?? "",
            manufacturer: manufacturer ?? "",
            restrictions: restrictions ?? "",
            notes: notes ?? "",
            crop: crop ?? "",
            problem: problem ?? "",
            activeIngredient: activeIngredient ?? "",
            rates: rates ?? [],
            purchase: purchase,
            labelURL: LabelURLValidator.sanitize(labelUrl ?? ""),
            productURL: LabelURLValidator.sanitize(productUrl ?? ""),
            modeOfAction: modeOfAction ?? "",
            productCategory: productCategory ?? "",
            productForm: productForm ?? "",
            packSize: packSize,
            packUnit: packUnit ?? "",
            pricePerPack: pricePerPack,
            density: density,
            nitrogenPercent: nitrogenPercent,
            phosphorusPercent: phosphorusPercent,
            potassiumPercent: potassiumPercent,
            analysisBasis: analysisBasis ?? "elemental",
            organicCertified: organicCertified ?? false,
            inventoryQuantity: inventoryQuantity,
            inventoryUnit: inventoryUnit ?? "",
            applicationNotes: applicationNotes ?? "",
            isActive: isActive ?? true,
            chemicalIntelligence: decodedIntelligence(),
            masterChemicalId: masterChemicalId,
            masterSourceRevision: masterSourceRevision
        )
    }
}

// MARK: - Saved Spray Presets

nonisolated struct BackendSavedSprayPreset: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String?
    let waterVolume: Double?
    let sprayRatePerHa: Double?
    let concentrationFactor: Double?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case waterVolume = "water_volume"
        case sprayRatePerHa = "spray_rate_per_ha"
        case concentrationFactor = "concentration_factor"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendSavedSprayPresetUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let waterVolume: Double
    let sprayRatePerHa: Double
    let concentrationFactor: Double
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case waterVolume = "water_volume"
        case sprayRatePerHa = "spray_rate_per_ha"
        case concentrationFactor = "concentration_factor"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendSavedSprayPreset {
    static func upsert(from p: SavedSprayPreset, createdBy: UUID?, clientUpdatedAt: Date) -> BackendSavedSprayPresetUpsert {
        BackendSavedSprayPresetUpsert(
            id: p.id,
            vineyardId: p.vineyardId,
            name: p.name,
            waterVolume: p.waterVolume,
            sprayRatePerHa: p.sprayRatePerHa,
            concentrationFactor: p.concentrationFactor,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toSavedSprayPreset() -> SavedSprayPreset {
        SavedSprayPreset(
            id: id,
            vineyardId: vineyardId,
            name: name ?? "",
            waterVolume: waterVolume ?? 0,
            sprayRatePerHa: sprayRatePerHa ?? 0,
            concentrationFactor: concentrationFactor ?? 1.0
        )
    }
}

// MARK: - Spray Equipment

nonisolated struct BackendSprayEquipment: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String?
    let tankCapacityLitres: Double?
    let serialNumber: String?
    let vinNumber: String?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case tankCapacityLitres = "tank_capacity_litres"
        case serialNumber = "serial_number"
        case vinNumber = "vin_number"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendSprayEquipmentUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let tankCapacityLitres: Double
    let serialNumber: String?
    let vinNumber: String?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case tankCapacityLitres = "tank_capacity_litres"
        case serialNumber = "serial_number"
        case vinNumber = "vin_number"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendSprayEquipment {
    static func upsert(from e: SprayEquipmentItem, createdBy: UUID?, clientUpdatedAt: Date) -> BackendSprayEquipmentUpsert {
        BackendSprayEquipmentUpsert(
            id: e.id,
            vineyardId: e.vineyardId,
            name: e.name,
            tankCapacityLitres: e.tankCapacityLitres,
            serialNumber: e.serialNumber,
            vinNumber: e.vinNumber,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toSprayEquipmentItem() -> SprayEquipmentItem {
        SprayEquipmentItem(
            id: id,
            vineyardId: vineyardId,
            name: name ?? "",
            tankCapacityLitres: tankCapacityLitres ?? 0,
            serialNumber: serialNumber,
            vinNumber: vinNumber
        )
    }
}

// MARK: - Tractors

nonisolated struct BackendTractor: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String?
    let brand: String?
    let model: String?
    let modelYear: Int?
    let fuelUsageLPerHour: Double?
    let serialNumber: String?
    let vinNumber: String?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case brand
        case model
        case modelYear = "model_year"
        case fuelUsageLPerHour = "fuel_usage_l_per_hour"
        case serialNumber = "serial_number"
        case vinNumber = "vin_number"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendTractorUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let brand: String
    let model: String
    let modelYear: Int?
    let fuelUsageLPerHour: Double
    let serialNumber: String?
    let vinNumber: String?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case brand
        case model
        case modelYear = "model_year"
        case fuelUsageLPerHour = "fuel_usage_l_per_hour"
        case serialNumber = "serial_number"
        case vinNumber = "vin_number"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendTractor {
    static func upsert(from t: Tractor, createdBy: UUID?, clientUpdatedAt: Date) -> BackendTractorUpsert {
        BackendTractorUpsert(
            id: t.id,
            vineyardId: t.vineyardId,
            name: t.name,
            brand: t.brand,
            model: t.model,
            modelYear: t.modelYear,
            fuelUsageLPerHour: t.fuelUsageLPerHour,
            serialNumber: t.serialNumber,
            vinNumber: t.vinNumber,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toTractor() -> Tractor {
        Tractor(
            id: id,
            vineyardId: vineyardId,
            name: name ?? "",
            brand: brand ?? "",
            model: model ?? "",
            modelYear: modelYear,
            fuelUsageLPerHour: fuelUsageLPerHour ?? 0,
            serialNumber: serialNumber,
            vinNumber: vinNumber
        )
    }
}

// MARK: - Vineyard Machines

nonisolated struct BackendVineyardMachine: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String?
    let machineType: String?
    let fuelTrackingEnabled: Bool?
    let availableForJobCosting: Bool?
    let fuelUsageLPerHour: Double?
    let notes: String?
    let serialNumber: String?
    let vinNumber: String?
    let legacyTractorId: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case machineType = "machine_type"
        case fuelTrackingEnabled = "fuel_tracking_enabled"
        case availableForJobCosting = "available_for_job_costing"
        case fuelUsageLPerHour = "fuel_usage_l_per_hour"
        case notes
        case serialNumber = "serial_number"
        case vinNumber = "vin_number"
        case legacyTractorId = "legacy_tractor_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendVineyardMachineUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let machineType: String
    let fuelTrackingEnabled: Bool
    let availableForJobCosting: Bool
    let fuelUsageLPerHour: Double
    let notes: String?
    let serialNumber: String?
    let vinNumber: String?
    let legacyTractorId: UUID?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case machineType = "machine_type"
        case fuelTrackingEnabled = "fuel_tracking_enabled"
        case availableForJobCosting = "available_for_job_costing"
        case fuelUsageLPerHour = "fuel_usage_l_per_hour"
        case notes
        case serialNumber = "serial_number"
        case vinNumber = "vin_number"
        case legacyTractorId = "legacy_tractor_id"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendVineyardMachine {
    static func upsert(from m: VineyardMachine, createdBy: UUID?, clientUpdatedAt: Date) -> BackendVineyardMachineUpsert {
        BackendVineyardMachineUpsert(
            id: m.id,
            vineyardId: m.vineyardId,
            name: m.name,
            machineType: m.machineType.rawValue,
            fuelTrackingEnabled: m.fuelTrackingEnabled,
            availableForJobCosting: m.availableForJobCosting,
            fuelUsageLPerHour: m.fuelUsageLPerHour,
            notes: m.notes,
            serialNumber: m.serialNumber,
            vinNumber: m.vinNumber,
            legacyTractorId: m.legacyTractorId,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toVineyardMachine() -> VineyardMachine {
        VineyardMachine(
            id: id,
            vineyardId: vineyardId,
            name: name ?? "",
            machineType: machineType.flatMap(VineyardMachineType.init(rawValue:)) ?? .tractor,
            fuelTrackingEnabled: fuelTrackingEnabled ?? true,
            availableForJobCosting: availableForJobCosting ?? false,
            fuelUsageLPerHour: fuelUsageLPerHour ?? 0,
            notes: notes,
            serialNumber: serialNumber,
            vinNumber: vinNumber,
            legacyTractorId: legacyTractorId
        )
    }
}

// MARK: - Fuel Purchases

nonisolated struct BackendFuelPurchase: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let volumeLitres: Double?
    let totalCost: Double?
    let date: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case volumeLitres = "volume_litres"
        case totalCost = "total_cost"
        case date
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendFuelPurchaseUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let volumeLitres: Double
    let totalCost: Double
    let date: Date
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case volumeLitres = "volume_litres"
        case totalCost = "total_cost"
        case date
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendFuelPurchase {
    static func upsert(from f: FuelPurchase, createdBy: UUID?, clientUpdatedAt: Date) -> BackendFuelPurchaseUpsert {
        BackendFuelPurchaseUpsert(
            id: f.id,
            vineyardId: f.vineyardId,
            volumeLitres: f.volumeLitres,
            totalCost: f.totalCost,
            date: f.date,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toFuelPurchase() -> FuelPurchase {
        FuelPurchase(
            id: id,
            vineyardId: vineyardId,
            volumeLitres: volumeLitres ?? 0,
            totalCost: totalCost ?? 0,
            date: date ?? Date()
        )
    }
}

// MARK: - Tractor Fuel Logs

nonisolated struct BackendTractorFuelLog: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let tractorId: UUID?
    let machineId: UUID?
    let fillDatetime: Date?
    let litresAdded: Double?
    let engineHours: Double?
    let operatorUserId: UUID?
    let operatorName: String?
    let costPerLitre: Double?
    let totalCost: Double?
    let filledToFull: Bool?
    let notes: String?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case tractorId = "tractor_id"
        case machineId = "machine_id"
        case fillDatetime = "fill_datetime"
        case litresAdded = "litres_added"
        case engineHours = "engine_hours"
        case operatorUserId = "operator_user_id"
        case operatorName = "operator_name"
        case costPerLitre = "cost_per_litre"
        case totalCost = "total_cost"
        case filledToFull = "filled_to_full"
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendTractorFuelLogUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let tractorId: UUID?
    let machineId: UUID?
    let fillDatetime: Date
    let litresAdded: Double
    let engineHours: Double?
    let operatorUserId: UUID?
    let operatorName: String?
    let costPerLitre: Double?
    let totalCost: Double?
    let filledToFull: Bool?
    let notes: String?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case tractorId = "tractor_id"
        case machineId = "machine_id"
        case fillDatetime = "fill_datetime"
        case litresAdded = "litres_added"
        case engineHours = "engine_hours"
        case operatorUserId = "operator_user_id"
        case operatorName = "operator_name"
        case costPerLitre = "cost_per_litre"
        case totalCost = "total_cost"
        case filledToFull = "filled_to_full"
        case notes
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendTractorFuelLog {
    static func upsert(from f: TractorFuelLog, createdBy: UUID?, clientUpdatedAt: Date) -> BackendTractorFuelLogUpsert {
        BackendTractorFuelLogUpsert(
            id: f.id,
            vineyardId: f.vineyardId,
            tractorId: f.tractorId,
            machineId: f.machineId,
            fillDatetime: f.fillDateTime,
            litresAdded: f.litresAdded,
            engineHours: f.engineHours,
            operatorUserId: f.operatorUserId,
            operatorName: f.operatorName,
            costPerLitre: f.costPerLitre,
            totalCost: f.totalCost,
            filledToFull: f.filledToFull,
            notes: f.notes,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toTractorFuelLog() -> TractorFuelLog {
        TractorFuelLog(
            id: id,
            vineyardId: vineyardId,
            tractorId: tractorId,
            machineId: machineId,
            fillDateTime: fillDatetime ?? Date(),
            litresAdded: litresAdded ?? 0,
            engineHours: engineHours,
            operatorUserId: operatorUserId,
            operatorName: operatorName,
            costPerLitre: costPerLitre,
            totalCost: totalCost,
            filledToFull: filledToFull,
            notes: notes
        )
    }
}

// MARK: - Operator Categories

nonisolated struct BackendOperatorCategory: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String?
    let costPerHour: Double?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case costPerHour = "cost_per_hour"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendOperatorCategoryUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let costPerHour: Double
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case costPerHour = "cost_per_hour"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendOperatorCategory {
    static func upsert(from o: OperatorCategory, createdBy: UUID?, clientUpdatedAt: Date) -> BackendOperatorCategoryUpsert {
        BackendOperatorCategoryUpsert(
            id: o.id,
            vineyardId: o.vineyardId,
            name: o.name,
            costPerHour: o.costPerHour,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toOperatorCategory() -> OperatorCategory {
        OperatorCategory(
            id: id,
            vineyardId: vineyardId,
            name: name ?? "",
            costPerHour: costPerHour ?? 0
        )
    }
}

// MARK: - Work Task Types

nonisolated struct BackendWorkTaskType: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String?
    let isDefault: Bool?
    let sortOrder: Int?
    let createdBy: UUID?
    let updatedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case isDefault = "is_default"
        case sortOrder = "sort_order"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    // Per-row resilient decode: tolerate missing optional fields and
    // string-encoded dates from PostgREST so one malformed row does not
    // break sync for the rest of the vineyard's catalog.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault)
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.updatedBy = try c.decodeIfPresent(UUID.self, forKey: .updatedBy)
        self.createdAt = Self.flexibleDate(c, .createdAt)
        self.updatedAt = Self.flexibleDate(c, .updatedAt)
        self.deletedAt = Self.flexibleDate(c, .deletedAt)
        self.clientUpdatedAt = Self.flexibleDate(c, .clientUpdatedAt)
    }

    private static func flexibleDate(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return BackendDamageRecordDateParser.parse(s)
    }
}

nonisolated struct BackendWorkTaskTypeUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let isDefault: Bool
    let sortOrder: Int
    let createdBy: UUID?
    let updatedBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case isDefault = "is_default"
        case sortOrder = "sort_order"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendWorkTaskType {
    static func upsert(
        from t: WorkTaskType,
        createdBy: UUID?,
        updatedBy: UUID?,
        clientUpdatedAt: Date
    ) -> BackendWorkTaskTypeUpsert {
        BackendWorkTaskTypeUpsert(
            id: t.id,
            vineyardId: t.vineyardId,
            name: t.name,
            isDefault: t.isDefault,
            sortOrder: t.sortOrder,
            createdBy: createdBy,
            updatedBy: updatedBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toWorkTaskType() -> WorkTaskType {
        WorkTaskType(
            id: id,
            vineyardId: vineyardId,
            name: name ?? "",
            isDefault: isDefault ?? false,
            sortOrder: sortOrder ?? 0
        )
    }
}

// MARK: - Equipment Items ("Other")

nonisolated struct BackendEquipmentItem: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String?
    let category: String?
    let make: String?
    let model: String?
    let serialNumber: String?
    let vinNumber: String?
    let notes: String?
    let createdBy: UUID?
    let updatedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case category
        case make
        case model
        case serialNumber = "serial_number"
        case vinNumber = "vin_number"
        case notes
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.category = try c.decodeIfPresent(String.self, forKey: .category)
        self.make = try c.decodeIfPresent(String.self, forKey: .make)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber)
        self.vinNumber = try c.decodeIfPresent(String.self, forKey: .vinNumber)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.updatedBy = try c.decodeIfPresent(UUID.self, forKey: .updatedBy)
        self.createdAt = Self.flexibleDate(c, .createdAt)
        self.updatedAt = Self.flexibleDate(c, .updatedAt)
        self.deletedAt = Self.flexibleDate(c, .deletedAt)
        self.clientUpdatedAt = Self.flexibleDate(c, .clientUpdatedAt)
    }

    private static func flexibleDate(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return BackendDamageRecordDateParser.parse(s)
    }
}

nonisolated struct BackendEquipmentItemUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let category: String
    let make: String?
    let model: String?
    let serialNumber: String?
    let vinNumber: String?
    let notes: String
    let createdBy: UUID?
    let updatedBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case category
        case make
        case model
        case serialNumber = "serial_number"
        case vinNumber = "vin_number"
        case notes
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendEquipmentItem {
    static func upsert(
        from item: EquipmentItem,
        createdBy: UUID?,
        updatedBy: UUID?,
        clientUpdatedAt: Date
    ) -> BackendEquipmentItemUpsert {
        BackendEquipmentItemUpsert(
            id: item.id,
            vineyardId: item.vineyardId,
            name: item.name,
            category: item.category.isEmpty ? "other" : item.category,
            make: item.make,
            model: item.model,
            serialNumber: item.serialNumber,
            vinNumber: item.vinNumber,
            notes: item.notes,
            createdBy: createdBy,
            updatedBy: updatedBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toEquipmentItem() -> EquipmentItem {
        EquipmentItem(
            id: id,
            vineyardId: vineyardId,
            name: name ?? "",
            category: category ?? "other",
            make: make,
            model: model,
            serialNumber: serialNumber,
            vinNumber: vinNumber,
            notes: notes ?? ""
        )
    }
}
