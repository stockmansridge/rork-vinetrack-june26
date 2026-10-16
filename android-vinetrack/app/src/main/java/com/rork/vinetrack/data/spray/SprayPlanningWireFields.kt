package com.rork.vinetrack.data.spray

import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.encodeToJsonElement

/** Exact v2 projection; serialization never authorizes transport. */
@Serializable
data class SprayPlanningWireFields(
    @SerialName("sprayer_configuration") val sprayerConfiguration: String? = null,
    @SerialName("spray_planning_method") val sprayPlanningMethod: String? = null,
    @SerialName("full_tank_specification") val fullTankSpecification: String? = null,
    @SerialName("planning_input_provenance") val planningInputProvenance: SprayPlanningWireProvenance? = null,
    @SerialName("planning_intended_tank_litres") val planningIntendedTankLitres: Double? = null,
    @SerialName("planning_target_area_ha") val planningTargetAreaHa: Double? = null,
    @SerialName("planning_calibrated_litres_per_hectare") val planningCalibratedLitresPerHectare: Double? = null,
    @SerialName("planned_application_area_ha") val plannedApplicationAreaHa: Double? = null,
    @SerialName("resolved_planning_carrier_litres") val resolvedPlanningCarrierLitres: Double? = null,
    @SerialName("resolved_planning_litres_per_hectare") val resolvedPlanningLitresPerHectare: Double? = null,
    @SerialName("resolved_planning_physical_row_litres_per_100m") val resolvedPlanningPhysicalRowLitresPer100m: Double? = null,
    @SerialName("resolved_planning_concentration_factor") val resolvedPlanningConcentrationFactor: Double? = null,
    @SerialName("controller_litres_per_100m_travel") val controllerLitresPer100mTravel: Double? = null,
    @SerialName("effective_working_width_metres") val effectiveWorkingWidthMetres: Double? = null,
) {
    val intent: SprayPlanningIntent?
        get() = if (listOf(sprayerConfiguration, sprayPlanningMethod, fullTankSpecification, planningInputProvenance,
                planningTargetAreaHa, planningIntendedTankLitres, planningCalibratedLitresPerHectare).all { it == null }) null else
            SprayPlanningIntent(
                configuration = SprayPassConfiguration.entries.firstOrNull { it.wireValue == sprayerConfiguration },
                method = SprayPlanningMethod.entries.firstOrNull { it.wireValue == sprayPlanningMethod },
                fullTankSpecification = SprayFullTankSpecification.entries.firstOrNull { it.wireValue == fullTankSpecification },
                intendedTankLitres = planningIntendedTankLitres, targetAreaHa = planningTargetAreaHa,
                calibratedLitresPerHectare = planningCalibratedLitresPerHectare, inputProvenance = planningInputProvenance?.local)

    /** Never substitute mutable geometry or input values for absent frozen outputs. */
    fun resolution(): SprayPlanningResolution? {
        val litres = resolvedPlanningCarrierLitres ?: return null
        val area = plannedApplicationAreaHa ?: return null
        val rate = resolvedPlanningLitresPerHectare ?: return null
        val factor = resolvedPlanningConcentrationFactor ?: 1.0
        return SprayPlanningResolution(litres, area, rate, resolvedPlanningPhysicalRowLitresPer100m,
            controllerLitresPer100mTravel, effectiveWorkingWidthMetres, factor)
    }

    /** Declared changes replace the tuple, including NULLs. Historical omission remains distinct. */
    fun merging(base: JsonObject, json: Json, template: Boolean = false, explicitClear: Boolean = false): JsonObject {
        if (!template && LegacySpraySetup.canCarry(this, explicitClear)) {
            val notes = (base["notes"] as? kotlinx.serialization.json.JsonPrimitive)?.content
            return JsonObject(base + ("notes" to kotlinx.serialization.json.JsonPrimitive(LegacySpraySetup.notes(notes, this))))
        }
        if (!explicitClear && intent == null && resolution() == null) return base
        val encoded = json.encodeToJsonElement(serializer(), this) as JsonObject
        val keys = if (template) INPUT_KEYS else RECORD_KEYS
        return JsonObject(base + keys.associateWith { encoded[it] ?: JsonNull })
    }

    companion object {
        val INPUT_KEYS: Set<String> = setOf("sprayer_configuration", "spray_planning_method", "full_tank_specification",
            "planning_input_provenance", "planning_intended_tank_litres", "planning_target_area_ha", "planning_calibrated_litres_per_hectare")
        val RECORD_KEYS: Set<String> = INPUT_KEYS + setOf("planned_application_area_ha", "resolved_planning_carrier_litres",
            "resolved_planning_litres_per_hectare", "resolved_planning_physical_row_litres_per_100m", "resolved_planning_concentration_factor",
            "controller_litres_per_100m_travel", "effective_working_width_metres")

        fun from(snapshot: SprayApplicationSnapshot?, template: Boolean = false): SprayPlanningWireFields {
            val input = snapshot?.planningIntent
            val output = snapshot?.planningResolution.takeUnless { template }
            return SprayPlanningWireFields(
                sprayerConfiguration = input?.configuration?.wireValue,
                sprayPlanningMethod = input?.method?.wireValue,
                fullTankSpecification = input?.fullTankSpecification?.wireValue,
                planningInputProvenance = input?.inputProvenance?.let(::SprayPlanningWireProvenance),
                planningIntendedTankLitres = input?.intendedTankLitres,
                planningTargetAreaHa = input?.targetAreaHa,
                planningCalibratedLitresPerHectare = input?.calibratedLitresPerHectare,
                plannedApplicationAreaHa = output?.plannedAreaHa,
                resolvedPlanningCarrierLitres = output?.intendedLitres,
                resolvedPlanningLitresPerHectare = output?.litresPerHectare,
                resolvedPlanningPhysicalRowLitresPer100m = output?.physicalRowLitresPer100m,
                resolvedPlanningConcentrationFactor = output?.concentrationFactor,
                controllerLitresPer100mTravel = output?.controllerLitresPer100mTravel,
                effectiveWorkingWidthMetres = output?.effectiveWorkingWidthMetres)
        }
    }
}

/** Wire-only provenance; local snapshot formats remain compatible. */
@Serializable
data class SprayPlanningWireProvenance(
    @SerialName("schema_version") val schemaVersion: Int,
    @SerialName("tank_text") val tankText: String,
    @SerialName("area_text") val areaText: String,
    @SerialName("rate_text") val rateText: String,
    @SerialName("volume_unit") val volumeUnit: String,
    @SerialName("area_unit") val areaUnit: String,
    @SerialName("rate_area_unit") val rateAreaUnit: String,
    @SerialName("country_code") val countryCode: String,
) {
    constructor(local: SprayPlanningInputProvenance) : this(1, local.tankText, local.areaText, local.rateText,
        if (local.volumeUnit == "gallons") {
            if (local.countryCode.uppercase() in setOf("US", "CA")) "us_gallons" else "imperial_gallons"
        } else local.volumeUnit, local.areaUnit, local.rateAreaUnit, local.countryCode)
    val local: SprayPlanningInputProvenance get() = SprayPlanningInputProvenance(tankText, areaText, rateText,
        volumeUnit, areaUnit, rateAreaUnit, countryCode)
}

val SprayPassConfiguration.wireValue: String get() = if (this == SprayPassConfiguration.STANDARD_PASS) "standard_pass" else "over_row_two_rows"
val SprayPlanningMethod.wireValue: String get() = if (this == SprayPlanningMethod.BY_AREA) "by_area" else "full_tank"
val SprayFullTankSpecification.wireValue: String get() = if (this == SprayFullTankSpecification.TARGET_AREA) "target_area" else "calibrated_rate"
