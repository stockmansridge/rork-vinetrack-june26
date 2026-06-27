package com.rork.vinetrack.data.model

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * A single forecast day used by the irrigation calculator. Mirrors the iOS
 * `ForecastDay` contract (Open-Meteo `et0_fao_evapotranspiration` +
 * `precipitation_sum`).
 */
data class ForecastDay(
    val dateEpochMs: Long,
    val forecastEToMm: Double,
    val forecastRainMm: Double,
)

/**
 * Tunable irrigation parameters. Mirrors the iOS `IrrigationSettings` defaults.
 * Calculator-only — these are not persisted to the backend.
 */
data class IrrigationSettings(
    val irrigationApplicationRateMmPerHour: Double,
    val cropCoefficientKc: Double = 0.65,
    val irrigationEfficiencyPercent: Double = 90.0,
    val rainfallEffectivenessPercent: Double = 80.0,
    val replacementPercent: Double = 100.0,
    val soilMoistureBufferMm: Double = 0.0,
) {
    companion object {
        val defaults = IrrigationSettings(irrigationApplicationRateMmPerHour = 0.0)
    }
}

/**
 * Soil-aware inputs derived from a [BackendSoilProfile] (or manual values).
 * All fields are optional so soil-aware logic stays additive — irrigation
 * recommendations still work when no soil profile exists. Mirrors the iOS
 * `SoilProfileInputs`.
 */
data class SoilProfileInputs(
    val irrigationSoilClass: String? = null,
    val availableWaterCapacityMmPerM: Double? = null,
    val effectiveRootDepthM: Double? = null,
    val managementAllowedDepletionPercent: Double? = null,
    val infiltrationRisk: String? = null,
    val drainageRisk: String? = null,
    val waterloggingRisk: String? = null,
    val modelVersion: String = "soil_aware_irrigation_v1",
) {
    /** Derived root-zone capacity (mm) = AWC x effective root depth. */
    val rootZoneCapacityMm: Double?
        get() {
            val awc = availableWaterCapacityMmPerM ?: return null
            val depth = effectiveRootDepthM ?: return null
            if (awc <= 0 || depth <= 0) return null
            return awc * depth
        }

    /** Readily available water (mm) = root-zone capacity x allowed depletion. */
    val readilyAvailableWaterMm: Double?
        get() {
            val rzc = rootZoneCapacityMm ?: return null
            val depl = managementAllowedDepletionPercent ?: return null
            if (depl <= 0) return null
            return rzc * (depl / 100.0)
        }

    companion object {
        val empty = SoilProfileInputs()
    }
}

/** Soil-aware advice category derived from the configured soil class. */
enum class IrrigationSoilAdvice {
    SandyFrequent,
    LoamNormal,
    ClayCaution,
    Shallow,
    Generic,
}

/**
 * Soil-Aware Irrigation v2 urgency tier — derived from forecast deficit
 * relative to RAW / root-zone capacity, plus forecast rain.
 */
enum class IrrigationUrgency(val displayLabel: String) {
    IrrigateNow("Irrigate now"),
    IrrigateSoon("Irrigate soon"),
    Monitor("Monitor"),
    DelayRainLikely("Delay — rain likely"),
}

/**
 * Soil-Aware Irrigation v2 outputs. Present only when the v2 flag is on.
 * Mirrors the iOS `SoilAwareV2Result`.
 */
data class SoilAwareV2Result(
    /** Base replacement demand (gross mm) before any soil adjustment. */
    val baseGrossIrrigationMm: Double,
    /** Soil-adjusted single-event recommendation (gross mm). May be capped at RAW. */
    val soilAdjustedGrossMm: Double,
    /** Estimated urgency tier. */
    val urgency: IrrigationUrgency,
    /** True when the soil adjustment differs materially from the base. */
    val soilAdjusted: Boolean,
    /** True when splitting into multiple smaller events is recommended. */
    val splitSuggested: Boolean,
    /** Suggested number of split events (>= 2 when split is suggested, else 1). */
    val splitCount: Int,
    /** Human-readable reason the soil adjusted the recommendation. */
    val adjustmentReason: String? = null,
    /** Optional caution shown alongside the recommendation. */
    val cautionText: String? = null,
)

/** Per-day breakdown produced by [IrrigationCalculator]. */
data class DailyIrrigationBreakdown(
    val dateEpochMs: Long,
    val forecastEToMm: Double,
    val forecastRainMm: Double,
    val cropUseMm: Double,
    val effectiveRainMm: Double,
    val dailyDeficitMm: Double,
)

/** Aggregate recommendation produced by [IrrigationCalculator]. */
data class IrrigationRecommendationResult(
    val dailyBreakdown: List<DailyIrrigationBreakdown>,
    val forecastCropUseMm: Double,
    val forecastEffectiveRainMm: Double,
    /** Effective recent measured rainfall (mm) subtracted from the deficit. */
    val recentActualRainMm: Double,
    val netDeficitMm: Double,
    val grossIrrigationMm: Double,
    val recommendedIrrigationHours: Double,
    val recommendedIrrigationMinutes: Int,
    /** Soil-aware advice category. Null when no soil profile is configured. */
    val soilAdvice: IrrigationSoilAdvice? = null,
    val rootZoneCapacityMm: Double? = null,
    val readilyAvailableWaterMm: Double? = null,
    val soilAdviceText: String? = null,
    val soilCautionText: String? = null,
    /** Soil-aware v2 outputs. Null when the v2 flag is OFF. */
    val v2: SoilAwareV2Result? = null,
)

/**
 * Pure irrigation maths, ported 1:1 from the iOS `IrrigationCalculator` so the
 * recommendation matches across platforms. Crop use = ETo × Kc; rainfall under
 * 2 mm is treated as ineffective; the deficit is reduced by the soil buffer,
 * scaled by replacement %, then grossed up by irrigation efficiency before
 * converting to run-time hours via the system application rate.
 */
object IrrigationCalculator {
    fun calculate(
        forecastDays: List<ForecastDay>,
        settings: IrrigationSettings,
        /**
         * Total recent measured rainfall (mm) over the lookback window. Subtracted
         * from the forecast deficit (after rainfall effectiveness) so users with a
         * weather station don't over-irrigate after a recent storm. Mirrors the iOS
         * `recentActualRainMm` offset.
         */
        recentActualRainMm: Double = 0.0,
        /**
         * Soil-aware inputs derived from the active soil profile. When empty,
         * soil-aware advice and the v2 result are omitted.
         */
        soil: SoilProfileInputs = SoilProfileInputs.empty,
        /** Enables the soil-aware v2 recommendation (RAW caps, urgency, splits). */
        soilAwareV2Enabled: Boolean = false,
    ): IrrigationRecommendationResult? {
        if (forecastDays.isEmpty()) return null
        if (settings.irrigationApplicationRateMmPerHour <= 0) return null

        val kc = settings.cropCoefficientKc
        val rainEff = settings.rainfallEffectivenessPercent / 100.0
        val irrEff = max(settings.irrigationEfficiencyPercent / 100.0, 0.0001)
        val replacement = settings.replacementPercent / 100.0

        val breakdown = mutableListOf<DailyIrrigationBreakdown>()
        var totalCropUse = 0.0
        var totalEffectiveRain = 0.0
        var totalDeficit = 0.0

        for (day in forecastDays) {
            val cropUseMm = day.forecastEToMm * kc
            val rawEffectiveRain = day.forecastRainMm * rainEff
            val effectiveRainMm = if (day.forecastRainMm < 2.0) 0.0 else rawEffectiveRain
            val dailyDeficitMm = max(0.0, cropUseMm - effectiveRainMm)

            breakdown.add(
                DailyIrrigationBreakdown(
                    dateEpochMs = day.dateEpochMs,
                    forecastEToMm = day.forecastEToMm,
                    forecastRainMm = day.forecastRainMm,
                    cropUseMm = cropUseMm,
                    effectiveRainMm = effectiveRainMm,
                    dailyDeficitMm = dailyDeficitMm,
                )
            )

            totalCropUse += cropUseMm
            totalEffectiveRain += effectiveRainMm
            totalDeficit += dailyDeficitMm
        }

        // Subtract recent measured rainfall (after effectiveness) before the
        // soil-buffer offset, matching the iOS calculator.
        val actualRainOffset = max(0.0, recentActualRainMm * rainEff)
        val adjustedNetDeficitMm = max(0.0, totalDeficit - settings.soilMoistureBufferMm - actualRainOffset)
        val targetNetIrrigationMm = adjustedNetDeficitMm * replacement
        val grossIrrigationMm = targetNetIrrigationMm / irrEff
        val hours = grossIrrigationMm / settings.irrigationApplicationRateMmPerHour
        val minutes = (hours * 60.0).roundToInt()

        // Derive soil-aware advice (descriptive in v1; the v2 block applies the
        // soil-driven adjustments to the recommended depth).
        val advice = soilAdvice(soil)
        val adviceText = adviceCopy(advice, soil, grossIrrigationMm)
        val cautionText = cautionCopy(advice, soil, forecastDays)

        val v2: SoilAwareV2Result? = if (soilAwareV2Enabled) {
            computeV2(
                advice = advice,
                soil = soil,
                forecastDays = forecastDays,
                baseGrossMm = grossIrrigationMm,
                adjustedNetDeficitMm = adjustedNetDeficitMm,
            )
        } else null

        return IrrigationRecommendationResult(
            dailyBreakdown = breakdown,
            forecastCropUseMm = totalCropUse,
            forecastEffectiveRainMm = totalEffectiveRain,
            recentActualRainMm = actualRainOffset,
            netDeficitMm = adjustedNetDeficitMm,
            grossIrrigationMm = grossIrrigationMm,
            recommendedIrrigationHours = hours,
            recommendedIrrigationMinutes = minutes,
            soilAdvice = advice,
            rootZoneCapacityMm = soil.rootZoneCapacityMm,
            readilyAvailableWaterMm = soil.readilyAvailableWaterMm,
            soilAdviceText = adviceText,
            soilCautionText = cautionText,
            v2 = v2,
        )
    }

    // region Soil-Aware v2

    /**
     * Soil-aware v2 logic: RAW-capped single events, split suggestions,
     * urgency tiers, and heavy-clay / sandy / shallow cautions. Kept
     * conservative — when soil data is missing we fall back to base demand
     * with [IrrigationUrgency.Monitor]. Ported 1:1 from the iOS engine.
     */
    private fun computeV2(
        advice: IrrigationSoilAdvice?,
        soil: SoilProfileInputs,
        forecastDays: List<ForecastDay>,
        baseGrossMm: Double,
        adjustedNetDeficitMm: Double,
    ): SoilAwareV2Result {
        val raw = soil.readilyAvailableWaterMm
        val forecastRain = forecastDays.sumOf { it.forecastRainMm }
        val rzc = soil.rootZoneCapacityMm

        // 1. RAW cap for sandy / shallow soils. Loam + clay are not capped
        //    because their root zone can absorb a larger refilling event.
        var soilAdjustedGrossMm = baseGrossMm
        var splitSuggested = false
        var adjustmentReason: String? = null
        val shouldCapAtRaw = advice == IrrigationSoilAdvice.SandyFrequent ||
            advice == IrrigationSoilAdvice.Shallow
        if (shouldCapAtRaw && raw != null && raw > 0 && baseGrossMm > raw) {
            soilAdjustedGrossMm = raw
            splitSuggested = true
            val descriptor = if (advice == IrrigationSoilAdvice.Shallow) "shallow soil" else "sandy soil"
            adjustmentReason = String.format(
                java.util.Locale.US,
                "RAW limit for %s: capping single event at %.0f mm. Split remainder into a follow-up irrigation.",
                descriptor, raw,
            )
        }

        val splitCount = if (splitSuggested) {
            max(2, ceil(baseGrossMm / max(soilAdjustedGrossMm, 1.0)).toInt())
        } else 1

        // 2. Urgency from depletion vs RAW (deficit-only heuristic when no soil).
        val urgency: IrrigationUrgency = when {
            advice == IrrigationSoilAdvice.ClayCaution && forecastRain >= 10 -> IrrigationUrgency.DelayRainLikely
            adjustedNetDeficitMm <= 0 -> IrrigationUrgency.Monitor
            forecastRain >= adjustedNetDeficitMm * 1.5 -> IrrigationUrgency.DelayRainLikely
            raw != null && raw > 0 -> when {
                adjustedNetDeficitMm >= raw -> IrrigationUrgency.IrrigateNow
                adjustedNetDeficitMm >= raw * 0.7 -> IrrigationUrgency.IrrigateSoon
                else -> IrrigationUrgency.Monitor
            }
            rzc != null && rzc > 0 -> when {
                adjustedNetDeficitMm >= rzc * 0.5 -> IrrigationUrgency.IrrigateNow
                adjustedNetDeficitMm >= rzc * 0.3 -> IrrigationUrgency.IrrigateSoon
                else -> IrrigationUrgency.Monitor
            }
            adjustedNetDeficitMm >= 20 -> IrrigationUrgency.IrrigateNow
            adjustedNetDeficitMm >= 8 -> IrrigationUrgency.IrrigateSoon
            else -> IrrigationUrgency.Monitor
        }

        // 3. Cautions.
        val cautions = mutableListOf<String>()
        if (advice == IrrigationSoilAdvice.ClayCaution && forecastRain >= 10) {
            cautions.add(
                String.format(
                    java.util.Locale.US,
                    "Heavy clay soil with %.0f mm forecast rain — risk of waterlogging. Consider delaying or reducing irrigation.",
                    forecastRain,
                )
            )
        }
        if (advice == IrrigationSoilAdvice.SandyFrequent && raw != null && raw > 0 && baseGrossMm > raw) {
            cautions.add(
                String.format(
                    java.util.Locale.US,
                    "Applying more than ~%.0f mm at once on sandy soils may drain below the root zone.",
                    raw,
                )
            )
        }
        if (advice == IrrigationSoilAdvice.Shallow && raw != null && raw > 0) {
            cautions.add(
                String.format(
                    java.util.Locale.US,
                    "Shallow root zone — keep individual events under ~%.0f mm to avoid runoff.",
                    raw,
                )
            )
        }
        if (soil.availableWaterCapacityMmPerM == null || soil.effectiveRootDepthM == null) {
            cautions.add("Soil profile incomplete — soil-aware adjustments limited. Add AWC and effective root depth for a full v2 recommendation.")
        }
        val cautionText = if (cautions.isEmpty()) null else cautions.joinToString("\n")

        val soilAdjusted = abs(soilAdjustedGrossMm - baseGrossMm) > 0.5

        return SoilAwareV2Result(
            baseGrossIrrigationMm = baseGrossMm,
            soilAdjustedGrossMm = soilAdjustedGrossMm,
            urgency = urgency,
            soilAdjusted = soilAdjusted,
            splitSuggested = splitSuggested,
            splitCount = splitCount,
            adjustmentReason = adjustmentReason,
            cautionText = cautionText,
        )
    }

    private fun soilAdvice(soil: SoilProfileInputs): IrrigationSoilAdvice? {
        val cls = IrrigationSoilClass.fromRaw(soil.irrigationSoilClass) ?: return null
        return when (cls) {
            IrrigationSoilClass.SandLoamySand, IrrigationSoilClass.SandyLoam -> IrrigationSoilAdvice.SandyFrequent
            IrrigationSoilClass.Loam, IrrigationSoilClass.SiltLoam, IrrigationSoilClass.ClayLoam, IrrigationSoilClass.BasaltClayLoam -> IrrigationSoilAdvice.LoamNormal
            IrrigationSoilClass.ClayHeavyClay -> IrrigationSoilAdvice.ClayCaution
            IrrigationSoilClass.ShallowRocky -> IrrigationSoilAdvice.Shallow
            IrrigationSoilClass.Unknown -> IrrigationSoilAdvice.Generic
        }
    }

    private fun adviceCopy(
        advice: IrrigationSoilAdvice?,
        soil: SoilProfileInputs,
        grossIrrigationMm: Double,
    ): String? {
        if (advice == null) return null
        val raw = soil.readilyAvailableWaterMm
        return when (advice) {
            IrrigationSoilAdvice.SandyFrequent ->
                if (raw != null && raw > 0 && grossIrrigationMm > raw) {
                    String.format(java.util.Locale.US, "Sandy soils drain quickly. Consider splitting this into smaller irrigations of about %.0f mm each.", raw)
                } else {
                    "Sandy soils drain quickly. Prefer smaller, more frequent irrigations to limit drainage below the root zone."
                }
            IrrigationSoilAdvice.LoamNormal ->
                "Loam / clay-loam soils hold water well. Use the soil buffer to smooth irrigation decisions between events."
            IrrigationSoilAdvice.ClayCaution ->
                "Heavy clay soils hold water but drain slowly. Avoid large refilling events, especially before forecast rain."
            IrrigationSoilAdvice.Shallow ->
                "Shallow / rocky soils have a small root zone. Irrigate little and often to avoid runoff."
            IrrigationSoilAdvice.Generic ->
                "Soil class is unknown — irrigation recommendation uses generic defaults. Update the soil profile for site-specific guidance."
        }
    }

    private fun cautionCopy(
        advice: IrrigationSoilAdvice?,
        soil: SoilProfileInputs,
        forecastDays: List<ForecastDay>,
    ): String? {
        if (advice == null) return null
        val forecastRain = forecastDays.sumOf { it.forecastRainMm }
        return when (advice) {
            IrrigationSoilAdvice.ClayCaution ->
                if (forecastRain >= 10) "Significant rain forecast on heavy clay — risk of waterlogging or slow drainage." else null
            IrrigationSoilAdvice.SandyFrequent -> {
                val raw = soil.readilyAvailableWaterMm
                if (raw != null && raw > 0) String.format(java.util.Locale.US, "Applying more than ~%.0f mm at once may drain below the root zone.", raw) else null
            }
            else -> null
        }
    }

    // endregion
}
