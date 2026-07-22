import Foundation

// MARK: - Soil class defaults (read-only seed data)

/// One of the VineTrack irrigation soil classes. Kept as raw text so that
/// future provider mappings can introduce new classes without changing the
/// model.
nonisolated enum IrrigationSoilClass: String, Codable, Sendable, CaseIterable, Hashable {
    case sandLoamySand   = "sand_loamy_sand"
    case sandyLoam       = "sandy_loam"
    case loam            = "loam"
    case siltLoam        = "silt_loam"
    case clayLoam        = "clay_loam"
    case clayHeavyClay   = "clay_heavy_clay"
    case basaltClayLoam  = "basalt_clay_loam"
    case shallowRocky    = "shallow_rocky"
    case unknown         = "unknown"

    var fallbackLabel: String {
        switch self {
        case .sandLoamySand:  return "Sand / loamy sand"
        case .sandyLoam:      return "Sandy loam"
        case .loam:           return "Loam"
        case .siltLoam:       return "Silt loam"
        case .clayLoam:       return "Clay loam"
        case .clayHeavyClay:  return "Clay / heavy clay"
        case .basaltClayLoam: return "Basalt clay loam"
        case .shallowRocky:   return "Shallow / rocky"
        case .unknown:        return "Unknown"
        }
    }
}

nonisolated struct SoilClassDefault: Codable, Sendable, Hashable, Identifiable {
    let irrigationSoilClass: String
    let label: String
    let description: String?
    let defaultAwcMinMmPerM: Double?
    let defaultAwcMaxMmPerM: Double?
    let defaultAwcMmPerM: Double
    let defaultAllowedDepletionPercent: Double
    let defaultRootDepthM: Double
    let infiltrationRisk: String?
    let drainageRisk: String?
    let waterloggingRisk: String?
    let sortOrder: Int

    var id: String { irrigationSoilClass }

    var soilClass: IrrigationSoilClass? {
        IrrigationSoilClass(rawValue: irrigationSoilClass)
    }

    enum CodingKeys: String, CodingKey {
        case irrigationSoilClass            = "irrigation_soil_class"
        case label
        case description
        case defaultAwcMinMmPerM            = "default_awc_min_mm_per_m"
        case defaultAwcMaxMmPerM            = "default_awc_max_mm_per_m"
        case defaultAwcMmPerM               = "default_awc_mm_per_m"
        case defaultAllowedDepletionPercent = "default_allowed_depletion_percent"
        case defaultRootDepthM              = "default_root_depth_m"
        case infiltrationRisk               = "infiltration_risk"
        case drainageRisk                   = "drainage_risk"
        case waterloggingRisk               = "waterlogging_risk"
        case sortOrder                      = "sort_order"
    }
}

// MARK: - Paddock soil profile

nonisolated struct BackendSoilProfile: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    /// Nil for the optional vineyard-level fallback profile used by
    /// Whole Vineyard mode. Per-paddock rows always have a non-nil id.
    let paddockId: UUID?

    let source: String
    let sourceProvider: String?
    let sourceDataset: String?
    let sourceFeatureId: String?
    let sourceName: String?
    let modelVersion: String

    let countryCode: String?
    let regionCode: String?
    let lookupLatitude: Double?
    let lookupLongitude: Double?

    let soilLandscape: String?
    let soilLandscapeCode: String?
    let australianSoilClassification: String?
    let australianSoilClassificationCode: String?
    let landSoilCapability: String?
    let landSoilCapabilityClass: Int?
    let soilDescription: String?
    let soilTextureClass: String?
    let irrigationSoilClass: String?

    let availableWaterCapacityMmPerM: Double?
    let effectiveRootDepthM: Double?
    let managementAllowedDepletionPercent: Double?

    let infiltrationRisk: String?
    let drainageRisk: String?
    let waterloggingRisk: String?

    let confidence: String?
    let isManualOverride: Bool
    let manualNotes: String?

    let createdAt: Date?
    let updatedAt: Date?
    let updatedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId                         = "vineyard_id"
        case paddockId                          = "paddock_id"
        case source
        case sourceProvider                     = "source_provider"
        case sourceDataset                      = "source_dataset"
        case sourceFeatureId                    = "source_feature_id"
        case sourceName                         = "source_name"
        case modelVersion                       = "model_version"
        case countryCode                        = "country_code"
        case regionCode                         = "region_code"
        case lookupLatitude                     = "lookup_latitude"
        case lookupLongitude                    = "lookup_longitude"
        case soilLandscape                      = "soil_landscape"
        case soilLandscapeCode                  = "soil_landscape_code"
        case australianSoilClassification       = "australian_soil_classification"
        case australianSoilClassificationCode   = "australian_soil_classification_code"
        case landSoilCapability                 = "land_soil_capability"
        case landSoilCapabilityClass            = "land_soil_capability_class"
        case soilDescription                    = "soil_description"
        case soilTextureClass                   = "soil_texture_class"
        case irrigationSoilClass                = "irrigation_soil_class"
        case availableWaterCapacityMmPerM       = "available_water_capacity_mm_per_m"
        case effectiveRootDepthM                = "effective_root_depth_m"
        case managementAllowedDepletionPercent  = "management_allowed_depletion_percent"
        case infiltrationRisk                   = "infiltration_risk"
        case drainageRisk                       = "drainage_risk"
        case waterloggingRisk                   = "waterlogging_risk"
        case confidence
        case isManualOverride                   = "is_manual_override"
        case manualNotes                        = "manual_notes"
        case createdAt                          = "created_at"
        case updatedAt                          = "updated_at"
        case updatedBy                          = "updated_by"
    }
}

extension BackendSoilProfile {
    /// Derived root-zone capacity (mm) = AWC × effective root depth.
    var rootZoneCapacityMm: Double? {
        guard let awc = availableWaterCapacityMmPerM,
              let depth = effectiveRootDepthM,
              awc > 0, depth > 0 else { return nil }
        return awc * depth
    }

    /// Derived readily available water (mm) = root-zone capacity × allowed
    /// depletion fraction.
    var readilyAvailableWaterMm: Double? {
        guard let rzc = rootZoneCapacityMm,
              let depl = managementAllowedDepletionPercent,
              depl > 0 else { return nil }
        return rzc * (depl / 100.0)
    }

    var typedSoilClass: IrrigationSoilClass? {
        irrigationSoilClass.flatMap { IrrigationSoilClass(rawValue: $0) }
    }
}
