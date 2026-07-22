import Foundation

nonisolated struct ForecastDay: Sendable, Hashable, Identifiable {
    let date: Date
    let forecastEToMm: Double
    let forecastRainMm: Double
    let forecastWindKmhMax: Double?
    let forecastTempMaxC: Double?
    let forecastTempMinC: Double?

    var id: Date { date }

    init(
        date: Date,
        forecastEToMm: Double,
        forecastRainMm: Double,
        forecastWindKmhMax: Double? = nil,
        forecastTempMaxC: Double? = nil,
        forecastTempMinC: Double? = nil
    ) {
        self.date = date
        self.forecastEToMm = forecastEToMm
        self.forecastRainMm = forecastRainMm
        self.forecastWindKmhMax = forecastWindKmhMax
        self.forecastTempMaxC = forecastTempMaxC
        self.forecastTempMinC = forecastTempMinC
    }
}

nonisolated struct IrrigationSettings: Sendable, Hashable {
    var irrigationApplicationRateMmPerHour: Double
    var cropCoefficientKc: Double
    var irrigationEfficiencyPercent: Double
    var rainfallEffectivenessPercent: Double
    var replacementPercent: Double
    var soilMoistureBufferMm: Double

    static let defaults = IrrigationSettings(
        irrigationApplicationRateMmPerHour: 0,
        cropCoefficientKc: 0.65,
        irrigationEfficiencyPercent: 90,
        rainfallEffectivenessPercent: 80,
        replacementPercent: 100,
        soilMoistureBufferMm: 0
    )
}

nonisolated struct DailyIrrigationBreakdown: Sendable, Hashable, Identifiable {
    let date: Date
    let forecastEToMm: Double
    let forecastRainMm: Double
    let cropUseMm: Double
    let effectiveRainMm: Double
    let dailyDeficitMm: Double

    var id: Date { date }
}

/// Soil-aware inputs derived from a `BackendSoilProfile` (or manual values).
/// All fields are optional so soil-aware logic stays additive — irrigation
/// recommendations still work when no soil profile exists.
nonisolated struct SoilProfileInputs: Sendable, Hashable {
    var irrigationSoilClass: String?
    var availableWaterCapacityMmPerM: Double?
    var effectiveRootDepthM: Double?
    var managementAllowedDepletionPercent: Double?
    var infiltrationRisk: String?
    var drainageRisk: String?
    var waterloggingRisk: String?
    /// Versioning so we can update AWC defaults / mapping / formulas later.
    var modelVersion: String

    static let empty = SoilProfileInputs(modelVersion: "soil_aware_irrigation_v1")

    /// Derived root-zone capacity (mm) = AWC × effective root depth.
    var rootZoneCapacityMm: Double? {
        guard let awc = availableWaterCapacityMmPerM,
              let depth = effectiveRootDepthM,
              awc > 0, depth > 0 else { return nil }
        return awc * depth
    }

    /// Readily available water (mm) = root-zone capacity × allowed depletion.
    var readilyAvailableWaterMm: Double? {
        guard let rzc = rootZoneCapacityMm,
              let depl = managementAllowedDepletionPercent,
              depl > 0 else { return nil }
        return rzc * (depl / 100.0)
    }
}

nonisolated enum IrrigationSoilAdvice: String, Sendable, Hashable {
    case sandyFrequent
    case loamNormal
    case clayCaution
    case shallow
    case generic
}

/// Soil-Aware Irrigation v2 urgency tier — derived from forecast deficit
/// relative to RAW / root-zone capacity, plus forecast rain.
nonisolated enum IrrigationUrgency: String, Sendable, Hashable {
    case irrigateNow
    case irrigateSoon
    case monitor
    case delayRainLikely

    var displayLabel: String {
        switch self {
        case .irrigateNow:      return "Irrigate now"
        case .irrigateSoon:     return "Irrigate soon"
        case .monitor:          return "Monitor"
        case .delayRainLikely:  return "Delay — rain likely"
        }
    }
}

/// Soil-Aware Irrigation v2 outputs. All optional so v1 callers ignore
/// them transparently.
nonisolated struct SoilAwareV2Result: Sendable, Hashable {
    /// Base replacement demand (gross mm) before any soil adjustment —
    /// matches what v1 would have recommended.
    let baseGrossIrrigationMm: Double
    /// Soil-adjusted single-event recommendation (gross mm). May be
    /// capped at RAW for sandy/shallow soils.
    let soilAdjustedGrossMm: Double
    /// Estimated urgency tier.
    let urgency: IrrigationUrgency
    /// True when the soil adjustment differs materially from the base.
    let soilAdjusted: Bool
    /// True when splitting the irrigation into multiple smaller events
    /// is recommended (typically when base demand > RAW on sandy/shallow).
    let splitSuggested: Bool
    /// Suggested number of split events (2 when split is suggested,
    /// otherwise 1).
    let splitCount: Int
    /// Human-readable reason the soil adjusted the recommendation.
    let adjustmentReason: String?
    /// Optional caution shown alongside the recommendation (heavy clay
    /// + forecast rain, drainage loss, etc.).
    let cautionText: String?
}

nonisolated struct IrrigationRecommendationResult: Sendable, Hashable {
    let dailyBreakdown: [DailyIrrigationBreakdown]
    let forecastCropUseMm: Double
    let forecastEffectiveRainMm: Double
    /// Recent measured/actual rainfall fed into the calculation as a soil
    /// moisture credit. Zero when no actual-rain offset is applied.
    let recentActualRainMm: Double
    let netDeficitMm: Double
    let grossIrrigationMm: Double
    let recommendedIrrigationHours: Double
    let recommendedIrrigationMinutes: Int
    /// Soil-aware values (root-zone capacity, readily available water,
    /// advice text). Nil when no soil profile is configured.
    let soilAdvice: IrrigationSoilAdvice?
    let rootZoneCapacityMm: Double?
    let readilyAvailableWaterMm: Double?
    let soilAdviceText: String?
    let soilCautionText: String?
    /// Soil-aware v2 outputs. Nil when the v2 flag is OFF.
    let v2: SoilAwareV2Result?
}

nonisolated enum IrrigationCalculator {
    static func calculate(
        forecastDays: [ForecastDay],
        settings: IrrigationSettings,
        recentActualRainMm: Double = 0,
        soil: SoilProfileInputs = .empty,
        soilAwareV2Enabled: Bool = false
    ) -> IrrigationRecommendationResult? {
        guard !forecastDays.isEmpty else { return nil }
        guard settings.irrigationApplicationRateMmPerHour > 0 else { return nil }

        let kc = settings.cropCoefficientKc
        let rainEff = settings.rainfallEffectivenessPercent / 100.0
        let irrEff = max(settings.irrigationEfficiencyPercent / 100.0, 0.0001)
        let replacement = settings.replacementPercent / 100.0

        var breakdown: [DailyIrrigationBreakdown] = []
        var totalCropUse: Double = 0
        var totalEffectiveRain: Double = 0
        var totalDeficit: Double = 0

        for day in forecastDays {
            let cropUseMm = day.forecastEToMm * kc
            let rawEffectiveRain = day.forecastRainMm * rainEff
            let effectiveRainMm = day.forecastRainMm < 2.0 ? 0 : rawEffectiveRain
            let dailyDeficitMm = max(0, cropUseMm - effectiveRainMm)

            breakdown.append(DailyIrrigationBreakdown(
                date: day.date,
                forecastEToMm: day.forecastEToMm,
                forecastRainMm: day.forecastRainMm,
                cropUseMm: cropUseMm,
                effectiveRainMm: effectiveRainMm,
                dailyDeficitMm: dailyDeficitMm
            ))

            totalCropUse += cropUseMm
            totalEffectiveRain += effectiveRainMm
            totalDeficit += dailyDeficitMm
        }

        // Subtract recent measured rainfall (capped at calc deficit) before
        // soil-buffer offset, so users with Davis stations don't over-irrigate
        // after a recent storm.
        let actualRainOffset = max(0, recentActualRainMm * (settings.rainfallEffectivenessPercent / 100.0))
        let adjustedNetDeficitMm = max(0, totalDeficit - settings.soilMoistureBufferMm - actualRainOffset)
        let targetNetIrrigationMm = adjustedNetDeficitMm * replacement
        let grossIrrigationMm = targetNetIrrigationMm / irrEff
        let hours = grossIrrigationMm / settings.irrigationApplicationRateMmPerHour
        let minutes = Int((hours * 60.0).rounded())

        // Derive soil-aware advice. This is descriptive only in v1 — it
        // does not alter the recommended depth so users can build trust
        // before deeper soil-driven decision rules are layered in.
        let advice = soilAdvice(for: soil)
        let adviceText = adviceCopy(for: advice, soil: soil, grossIrrigationMm: grossIrrigationMm)
        let cautionText = cautionCopy(for: advice, soil: soil, forecastDays: forecastDays)

        let v2: SoilAwareV2Result? = soilAwareV2Enabled
            ? computeV2(
                advice: advice,
                soil: soil,
                forecastDays: forecastDays,
                baseGrossMm: grossIrrigationMm,
                adjustedNetDeficitMm: adjustedNetDeficitMm
            )
            : nil

        return IrrigationRecommendationResult(
            dailyBreakdown: breakdown,
            forecastCropUseMm: totalCropUse,
            forecastEffectiveRainMm: totalEffectiveRain,
            recentActualRainMm: actualRainOffset,
            netDeficitMm: adjustedNetDeficitMm,
            grossIrrigationMm: grossIrrigationMm,
            recommendedIrrigationHours: hours,
            recommendedIrrigationMinutes: minutes,
            soilAdvice: advice,
            rootZoneCapacityMm: soil.rootZoneCapacityMm,
            readilyAvailableWaterMm: soil.readilyAvailableWaterMm,
            soilAdviceText: adviceText,
            soilCautionText: cautionText,
            v2: v2
        )
    }

    // MARK: - Soil-Aware v2

    /// Soil-aware v2 logic: RAW-capped single events, split suggestions,
    /// urgency tiers, and heavy-clay / sandy / shallow cautions. Kept
    /// conservative on purpose — when soil data is missing we fall back
    /// to base demand with `monitor` urgency.
    private static func computeV2(
        advice: IrrigationSoilAdvice?,
        soil: SoilProfileInputs,
        forecastDays: [ForecastDay],
        baseGrossMm: Double,
        adjustedNetDeficitMm: Double
    ) -> SoilAwareV2Result {
        let raw = soil.readilyAvailableWaterMm
        let forecastRain = forecastDays.reduce(0) { $0 + $1.forecastRainMm }
        let rzc = soil.rootZoneCapacityMm

        // 1. RAW cap for sandy / shallow soils. Loam + clay are not capped
        //    because their root zone can absorb a larger refilling event.
        var soilAdjustedGrossMm = baseGrossMm
        var splitSuggested = false
        var adjustmentReason: String? = nil
        let shouldCapAtRaw: Bool = {
            switch advice {
            case .sandyFrequent, .shallow: return true
            default: return false
            }
        }()
        if shouldCapAtRaw, let raw, raw > 0, baseGrossMm > raw {
            soilAdjustedGrossMm = raw
            splitSuggested = true
            let descriptor = advice == .shallow ? "shallow soil" : "sandy soil"
            adjustmentReason = String(
                format: "RAW limit for %@: capping single event at %.0f mm. Split remainder into a follow-up irrigation.",
                descriptor, raw
            )
        }

        let splitCount = splitSuggested
            ? max(2, Int((baseGrossMm / max(soilAdjustedGrossMm, 1)).rounded(.up)))
            : 1

        // 2. Urgency from depletion vs RAW.
        //    With no RAW we fall back to a deficit-only heuristic.
        let urgency: IrrigationUrgency = {
            // Heavy clay + significant forecast rain → delay even if a
            // deficit exists, to avoid waterlogging.
            if advice == .clayCaution, forecastRain >= 10 {
                return .delayRainLikely
            }
            // Forecast rain covers most of the deficit → monitor/delay.
            if adjustedNetDeficitMm <= 0 { return .monitor }
            if forecastRain >= adjustedNetDeficitMm * 1.5 {
                return .delayRainLikely
            }
            if let raw, raw > 0 {
                if adjustedNetDeficitMm >= raw { return .irrigateNow }
                if adjustedNetDeficitMm >= raw * 0.7 { return .irrigateSoon }
                return .monitor
            }
            if let rzc, rzc > 0 {
                if adjustedNetDeficitMm >= rzc * 0.5 { return .irrigateNow }
                if adjustedNetDeficitMm >= rzc * 0.3 { return .irrigateSoon }
                return .monitor
            }
            // No soil data: use deficit heuristic.
            if adjustedNetDeficitMm >= 20 { return .irrigateNow }
            if adjustedNetDeficitMm >= 8  { return .irrigateSoon }
            return .monitor
        }()

        // 3. Cautions.
        var cautions: [String] = []
        if advice == .clayCaution, forecastRain >= 10 {
            cautions.append(String(
                format: "Heavy clay soil with %.0f mm forecast rain — risk of waterlogging. Consider delaying or reducing irrigation.",
                forecastRain
            ))
        }
        if advice == .sandyFrequent, let raw, raw > 0, baseGrossMm > raw {
            cautions.append(String(
                format: "Applying more than ~%.0f mm at once on sandy soils may drain below the root zone.",
                raw
            ))
        }
        if advice == .shallow, let raw, raw > 0 {
            cautions.append(String(
                format: "Shallow root zone — keep individual events under ~%.0f mm to avoid runoff.",
                raw
            ))
        }
        if soil.availableWaterCapacityMmPerM == nil || soil.effectiveRootDepthM == nil {
            cautions.append("Soil profile incomplete — soil-aware adjustments limited. Add AWC and effective root depth for a full v2 recommendation.")
        }
        let cautionText: String? = cautions.isEmpty ? nil : cautions.joined(separator: "\n")

        let soilAdjusted = abs(soilAdjustedGrossMm - baseGrossMm) > 0.5

        return SoilAwareV2Result(
            baseGrossIrrigationMm: baseGrossMm,
            soilAdjustedGrossMm: soilAdjustedGrossMm,
            urgency: urgency,
            soilAdjusted: soilAdjusted,
            splitSuggested: splitSuggested,
            splitCount: splitCount,
            adjustmentReason: adjustmentReason,
            cautionText: cautionText
        )
    }

    private static func soilAdvice(for soil: SoilProfileInputs) -> IrrigationSoilAdvice? {
        guard let raw = soil.irrigationSoilClass,
              let cls = IrrigationSoilClass(rawValue: raw) else { return nil }
        switch cls {
        case .sandLoamySand, .sandyLoam:
            return .sandyFrequent
        case .loam, .siltLoam, .clayLoam, .basaltClayLoam:
            return .loamNormal
        case .clayHeavyClay:
            return .clayCaution
        case .shallowRocky:
            return .shallow
        case .unknown:
            return .generic
        }
    }

    private static func adviceCopy(
        for advice: IrrigationSoilAdvice?,
        soil: SoilProfileInputs,
        grossIrrigationMm: Double
    ) -> String? {
        guard let advice else { return nil }
        let raw = soil.readilyAvailableWaterMm
        switch advice {
        case .sandyFrequent:
            if let raw, raw > 0, grossIrrigationMm > raw {
                return String(format: "Sandy soils drain quickly. Consider splitting this into smaller irrigations of about %.0f mm each.", raw)
            }
            return "Sandy soils drain quickly. Prefer smaller, more frequent irrigations to limit drainage below the root zone."
        case .loamNormal:
            return "Loam / clay-loam soils hold water well. Use the soil buffer to smooth irrigation decisions between events."
        case .clayCaution:
            return "Heavy clay soils hold water but drain slowly. Avoid large refilling events, especially before forecast rain."
        case .shallow:
            return "Shallow / rocky soils have a small root zone. Irrigate little and often to avoid runoff."
        case .generic:
            return "Soil class is unknown — irrigation recommendation uses generic defaults. Update the soil profile for site-specific guidance."
        }
    }

    private static func cautionCopy(
        for advice: IrrigationSoilAdvice?,
        soil: SoilProfileInputs,
        forecastDays: [ForecastDay]
    ) -> String? {
        guard let advice else { return nil }
        let forecastRain = forecastDays.reduce(0) { $0 + $1.forecastRainMm }
        switch advice {
        case .clayCaution:
            if forecastRain >= 10 {
                return "Significant rain forecast on heavy clay — risk of waterlogging or slow drainage."
            }
            return nil
        case .sandyFrequent:
            if let raw = soil.readilyAvailableWaterMm, raw > 0 {
                return String(format: "Applying more than ~%.0f mm at once may drain below the root zone.", raw)
            }
            return nil
        default:
            return nil
        }
    }
}
