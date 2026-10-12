package com.rork.vinetrack.data.spray

import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.encodeToJsonElement

/** Exact nullable review-schema projection; serialization does not authorize transport. */
@Serializable
data class SprayPlanningWireFields(
    @SerialName("sprayer_configuration") val sprayerConfiguration: String? = null,
    @SerialName("spray_planning_method") val sprayPlanningMethod: String? = null,
    @SerialName("full_tank_specification") val fullTankSpecification: String? = null,
    @SerialName("planned_application_area_ha") val plannedApplicationAreaHa: Double? = null,
    @SerialName("planning_tank_capacity_litres") val planningTankCapacityLitres: Double? = null,
    @SerialName("planning_calibrated_litres_per_hectare") val planningCalibratedLitresPerHectare: Double? = null,
    @SerialName("controller_litres_per_100m_travel") val controllerLitresPer100mTravel: Double? = null,
    @SerialName("effective_working_width_metres") val effectiveWorkingWidthMetres: Double? = null,
) {
    val intent: SprayPlanningIntent?
        get() = if (listOf(sprayerConfiguration, sprayPlanningMethod, fullTankSpecification, plannedApplicationAreaHa,
                planningTankCapacityLitres, planningCalibratedLitresPerHectare).all { it == null }) null else
            SprayPlanningIntent(
                configuration = SprayPassConfiguration.entries.firstOrNull { it.wireValue == sprayerConfiguration },
                method = SprayPlanningMethod.entries.firstOrNull { it.wireValue == sprayPlanningMethod },
                fullTankSpecification = SprayFullTankSpecification.entries.firstOrNull { it.wireValue == fullTankSpecification },
                intendedTankLitres = planningTankCapacityLitres, targetAreaHa = plannedApplicationAreaHa,
                calibratedLitresPerHectare = planningCalibratedLitresPerHectare)

    /** Read frozen columns verbatim; no geometry or concentration recalculation on reopen. */
    fun resolution(litres: Double?, rate: Double?, physicalRate: Double?, factor: Double?): SprayPlanningResolution? {
        if (litres == null || plannedApplicationAreaHa == null || rate == null || factor == null ||
            (sprayPlanningMethod == null && controllerLitresPer100mTravel == null && effectiveWorkingWidthMetres == null)) return null
        return SprayPlanningResolution(litres, plannedApplicationAreaHa, rate, physicalRate,
            controllerLitresPer100mTravel, effectiveWorkingWidthMetres, factor)
    }

    /** Only add new keys for declared intent; historical writers retain their old column inventory. */
    fun merging(base: JsonObject, json: Json): JsonObject = if (intent == null) base else
        JsonObject(base + (json.encodeToJsonElement(serializer(), this) as JsonObject))

    companion object {
        fun from(snapshot: SprayApplicationSnapshot?, template: Boolean = false): SprayPlanningWireFields = SprayPlanningWireFields(
            sprayerConfiguration = snapshot?.planningIntent?.configuration?.wireValue,
            sprayPlanningMethod = snapshot?.planningIntent?.method?.wireValue,
            fullTankSpecification = snapshot?.planningIntent?.fullTankSpecification?.wireValue,
            plannedApplicationAreaHa = snapshot?.planningIntent?.targetAreaHa ?: snapshot?.planningResolution?.plannedAreaHa,
            planningTankCapacityLitres = snapshot?.planningIntent?.intendedTankLitres,
            planningCalibratedLitresPerHectare = snapshot?.planningIntent?.calibratedLitresPerHectare,
            controllerLitresPer100mTravel = if (template) null else snapshot?.planningResolution?.controllerLitresPer100mTravel,
            effectiveWorkingWidthMetres = if (template) null else snapshot?.planningResolution?.effectiveWorkingWidthMetres)
    }
}

val SprayPassConfiguration.wireValue: String get() = if (this == SprayPassConfiguration.STANDARD_PASS) "standard_pass" else "over_row_two_rows"
val SprayPlanningMethod.wireValue: String get() = if (this == SprayPlanningMethod.BY_AREA) "by_area" else "full_tank"
val SprayFullTankSpecification.wireValue: String get() = if (this == SprayFullTankSpecification.TARGET_AREA) "target_area" else "calibrated_rate"
