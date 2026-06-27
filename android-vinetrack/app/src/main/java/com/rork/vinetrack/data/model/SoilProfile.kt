package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Soil-aware irrigation models, mirroring the iOS `BackendSoilProfile`,
 * `SoilClassDefault`, `SoilProfileUpsert` and `NSWSeedSoilSuggestion` types.
 * Backed by the shared `soil_class_defaults` / `paddock_soil_profiles` tables
 * and their RPCs (sql/064-066), plus the `nsw-seed-soil-lookup` edge function.
 */
enum class IrrigationSoilClass(val raw: String, val fallbackLabel: String) {
    SandLoamySand("sand_loamy_sand", "Sand / loamy sand"),
    SandyLoam("sandy_loam", "Sandy loam"),
    Loam("loam", "Loam"),
    SiltLoam("silt_loam", "Silt loam"),
    ClayLoam("clay_loam", "Clay loam"),
    ClayHeavyClay("clay_heavy_clay", "Clay / heavy clay"),
    BasaltClayLoam("basalt_clay_loam", "Basalt clay loam"),
    ShallowRocky("shallow_rocky", "Shallow / rocky"),
    Unknown("unknown", "Unknown");

    companion object {
        fun fromRaw(raw: String?): IrrigationSoilClass? =
            entries.firstOrNull { it.raw == raw }
    }
}

/** Read-only seed defaults for the soil class picker (`get_soil_class_defaults`). */
@Serializable
data class SoilClassDefault(
    @SerialName("irrigation_soil_class") val irrigationSoilClass: String,
    val label: String,
    val description: String? = null,
    @SerialName("default_awc_min_mm_per_m") val defaultAwcMinMmPerM: Double? = null,
    @SerialName("default_awc_max_mm_per_m") val defaultAwcMaxMmPerM: Double? = null,
    @SerialName("default_awc_mm_per_m") val defaultAwcMmPerM: Double = 0.0,
    @SerialName("default_allowed_depletion_percent") val defaultAllowedDepletionPercent: Double = 0.0,
    @SerialName("default_root_depth_m") val defaultRootDepthM: Double = 0.0,
    @SerialName("infiltration_risk") val infiltrationRisk: String? = null,
    @SerialName("drainage_risk") val drainageRisk: String? = null,
    @SerialName("waterlogging_risk") val waterloggingRisk: String? = null,
    @SerialName("sort_order") val sortOrder: Int = 0,
) {
    val soilClass: IrrigationSoilClass? get() = IrrigationSoilClass.fromRaw(irrigationSoilClass)
}

/** A persisted paddock (or vineyard-level) soil profile row. */
@Serializable
data class BackendSoilProfile(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("paddock_id") val paddockId: String? = null,
    val source: String = "manual",
    @SerialName("source_provider") val sourceProvider: String? = null,
    @SerialName("source_dataset") val sourceDataset: String? = null,
    @SerialName("source_feature_id") val sourceFeatureId: String? = null,
    @SerialName("source_name") val sourceName: String? = null,
    @SerialName("model_version") val modelVersion: String = "soil_aware_irrigation_v2",
    @SerialName("country_code") val countryCode: String? = null,
    @SerialName("region_code") val regionCode: String? = null,
    @SerialName("lookup_latitude") val lookupLatitude: Double? = null,
    @SerialName("lookup_longitude") val lookupLongitude: Double? = null,
    @SerialName("soil_landscape") val soilLandscape: String? = null,
    @SerialName("soil_landscape_code") val soilLandscapeCode: String? = null,
    @SerialName("australian_soil_classification") val australianSoilClassification: String? = null,
    @SerialName("australian_soil_classification_code") val australianSoilClassificationCode: String? = null,
    @SerialName("land_soil_capability") val landSoilCapability: String? = null,
    @SerialName("land_soil_capability_class") val landSoilCapabilityClass: Int? = null,
    @SerialName("soil_description") val soilDescription: String? = null,
    @SerialName("soil_texture_class") val soilTextureClass: String? = null,
    @SerialName("irrigation_soil_class") val irrigationSoilClass: String? = null,
    @SerialName("available_water_capacity_mm_per_m") val availableWaterCapacityMmPerM: Double? = null,
    @SerialName("effective_root_depth_m") val effectiveRootDepthM: Double? = null,
    @SerialName("management_allowed_depletion_percent") val managementAllowedDepletionPercent: Double? = null,
    @SerialName("infiltration_risk") val infiltrationRisk: String? = null,
    @SerialName("drainage_risk") val drainageRisk: String? = null,
    @SerialName("waterlogging_risk") val waterloggingRisk: String? = null,
    val confidence: String? = null,
    @SerialName("is_manual_override") val isManualOverride: Boolean = false,
    @SerialName("manual_notes") val manualNotes: String? = null,
) {
    val typedSoilClass: IrrigationSoilClass? get() = IrrigationSoilClass.fromRaw(irrigationSoilClass)

    /** Derived root-zone capacity (mm) = AWC x effective root depth. */
    val rootZoneCapacityMm: Double?
        get() {
            val awc = availableWaterCapacityMmPerM ?: return null
            val depth = effectiveRootDepthM ?: return null
            if (awc <= 0 || depth <= 0) return null
            return awc * depth
        }

    /** Derived readily available water (mm) = root-zone capacity x depletion fraction. */
    val readilyAvailableWaterMm: Double?
        get() {
            val rzc = rootZoneCapacityMm ?: return null
            val depl = managementAllowedDepletionPercent ?: return null
            if (depl <= 0) return null
            return rzc * (depl / 100.0)
        }
}

/**
 * Write payload for the upsert RPCs. Either [paddockId] (per-paddock row) or
 * [vineyardId] (vineyard-level fallback) must be non-null.
 */
data class SoilProfileUpsert(
    val paddockId: String? = null,
    val vineyardId: String? = null,
    val irrigationSoilClass: String? = null,
    val availableWaterCapacityMmPerM: Double? = null,
    val effectiveRootDepthM: Double? = null,
    val managementAllowedDepletionPercent: Double? = null,
    val soilLandscape: String? = null,
    val soilLandscapeCode: String? = null,
    val australianSoilClassification: String? = null,
    val australianSoilClassificationCode: String? = null,
    val landSoilCapability: String? = null,
    val landSoilCapabilityClass: Int? = null,
    val soilDescription: String? = null,
    val soilTextureClass: String? = null,
    val confidence: String? = null,
    val isManualOverride: Boolean = true,
    val manualNotes: String? = null,
    val source: String = "manual",
    val sourceProvider: String? = null,
    val sourceDataset: String? = null,
    val sourceFeatureId: String? = null,
    val sourceName: String? = null,
    val countryCode: String? = null,
    val regionCode: String? = null,
    val modelVersion: String = CURRENT_MODEL_VERSION,
) {
    companion object {
        const val CURRENT_MODEL_VERSION = "soil_aware_irrigation_v2"
    }
}

/** Soil suggestion returned by the `nsw-seed-soil-lookup` edge function. */
data class NSWSeedSoilSuggestion(
    val irrigationSoilClass: String? = null,
    val confidence: String? = null,
    val soilLandscape: String? = null,
    val soilLandscapeCode: String? = null,
    val australianSoilClassification: String? = null,
    val australianSoilClassificationCode: String? = null,
    val landSoilCapability: String? = null,
    val landSoilCapabilityClass: Int? = null,
    val sourceFeatureId: String? = null,
    val sourceName: String? = null,
    val sourceDataset: String? = null,
    val countryCode: String? = null,
    val regionCode: String? = null,
    val lookupLatitude: Double? = null,
    val lookupLongitude: Double? = null,
    val modelVersion: String? = null,
    val matchedKeywords: List<String> = emptyList(),
    val disclaimer: String? = null,
)

/** Result of an NSW SEED paddock lookup. */
data class NSWSeedSoilLookupResult(
    val found: Boolean,
    val suggestion: NSWSeedSoilSuggestion?,
    val message: String?,
    val disclaimer: String?,
)
