import Foundation

nonisolated struct SoilProfileUpsert: Sendable, Hashable {
    /// Either paddockId (per-paddock row) OR vineyardId (vineyard-level
    /// fallback row) must be non-nil. The repository routes to the
    /// matching RPC accordingly.
    var paddockId: UUID?
    var vineyardId: UUID?
    var irrigationSoilClass: String?
    var availableWaterCapacityMmPerM: Double?
    var effectiveRootDepthM: Double?
    var managementAllowedDepletionPercent: Double?
    var soilLandscape: String?
    var soilLandscapeCode: String?
    var australianSoilClassification: String?
    var australianSoilClassificationCode: String?
    var landSoilCapability: String?
    var landSoilCapabilityClass: Int?
    var soilDescription: String?
    var soilTextureClass: String?
    var infiltrationRisk: String?
    var drainageRisk: String?
    var waterloggingRisk: String?
    var confidence: String?
    var isManualOverride: Bool
    var manualNotes: String?
    var source: String
    var sourceProvider: String?
    var sourceDataset: String?
    var sourceFeatureId: String?
    var sourceName: String?
    var countryCode: String?
    var regionCode: String?
    var modelVersion: String

    static let currentModelVersion = "soil_aware_irrigation_v2"

    init(
        paddockId: UUID? = nil,
        vineyardId: UUID? = nil,
        irrigationSoilClass: String? = nil,
        availableWaterCapacityMmPerM: Double? = nil,
        effectiveRootDepthM: Double? = nil,
        managementAllowedDepletionPercent: Double? = nil,
        soilLandscape: String? = nil,
        soilLandscapeCode: String? = nil,
        australianSoilClassification: String? = nil,
        australianSoilClassificationCode: String? = nil,
        landSoilCapability: String? = nil,
        landSoilCapabilityClass: Int? = nil,
        soilDescription: String? = nil,
        soilTextureClass: String? = nil,
        infiltrationRisk: String? = nil,
        drainageRisk: String? = nil,
        waterloggingRisk: String? = nil,
        confidence: String? = nil,
        isManualOverride: Bool = true,
        manualNotes: String? = nil,
        source: String = "manual",
        sourceProvider: String? = nil,
        sourceDataset: String? = nil,
        sourceFeatureId: String? = nil,
        sourceName: String? = nil,
        countryCode: String? = nil,
        regionCode: String? = nil,
        modelVersion: String = Self.currentModelVersion
    ) {
        self.paddockId = paddockId
        self.vineyardId = vineyardId
        self.irrigationSoilClass = irrigationSoilClass
        self.availableWaterCapacityMmPerM = availableWaterCapacityMmPerM
        self.effectiveRootDepthM = effectiveRootDepthM
        self.managementAllowedDepletionPercent = managementAllowedDepletionPercent
        self.soilLandscape = soilLandscape
        self.soilLandscapeCode = soilLandscapeCode
        self.australianSoilClassification = australianSoilClassification
        self.australianSoilClassificationCode = australianSoilClassificationCode
        self.landSoilCapability = landSoilCapability
        self.landSoilCapabilityClass = landSoilCapabilityClass
        self.soilDescription = soilDescription
        self.soilTextureClass = soilTextureClass
        self.infiltrationRisk = infiltrationRisk
        self.drainageRisk = drainageRisk
        self.waterloggingRisk = waterloggingRisk
        self.confidence = confidence
        self.isManualOverride = isManualOverride
        self.manualNotes = manualNotes
        self.source = source
        self.sourceProvider = sourceProvider
        self.sourceDataset = sourceDataset
        self.sourceFeatureId = sourceFeatureId
        self.sourceName = sourceName
        self.countryCode = countryCode
        self.regionCode = regionCode
        self.modelVersion = modelVersion
    }
}

protocol SoilProfileRepositoryProtocol: Sendable {
    func fetchSoilClassDefaults() async throws -> [SoilClassDefault]
    func fetchPaddockSoilProfile(paddockId: UUID) async throws -> BackendSoilProfile?
    func fetchVineyardDefaultSoilProfile(vineyardId: UUID) async throws -> BackendSoilProfile?
    func listVineyardSoilProfiles(vineyardId: UUID) async throws -> [BackendSoilProfile]
    func upsertSoilProfile(_ profile: SoilProfileUpsert) async throws -> BackendSoilProfile?
    func deleteSoilProfile(paddockId: UUID) async throws
    func deleteVineyardDefaultSoilProfile(vineyardId: UUID) async throws
}
