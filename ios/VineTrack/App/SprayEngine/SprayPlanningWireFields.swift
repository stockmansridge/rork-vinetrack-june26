import Foundation

/// Exact additive review-schema projection. This adapter does not authorize a network write.
nonisolated struct SprayPlanningWireFields: Codable, Sendable, Hashable {
    var sprayerConfiguration: String? = nil
    var sprayPlanningMethod: String? = nil
    var fullTankSpecification: String? = nil
    var plannedApplicationAreaHa: Double? = nil
    var planningTankCapacityLitres: Double? = nil
    var planningCalibratedLitresPerHectare: Double? = nil
    var controllerLitresPer100mTravel: Double? = nil
    var effectiveWorkingWidthMetres: Double? = nil

    enum CodingKeys: String, CodingKey {
        case sprayerConfiguration = "sprayer_configuration"
        case sprayPlanningMethod = "spray_planning_method"
        case fullTankSpecification = "full_tank_specification"
        case plannedApplicationAreaHa = "planned_application_area_ha"
        case planningTankCapacityLitres = "planning_tank_capacity_litres"
        case planningCalibratedLitresPerHectare = "planning_calibrated_litres_per_hectare"
        case controllerLitresPer100mTravel = "controller_litres_per_100m_travel"
        case effectiveWorkingWidthMetres = "effective_working_width_metres"
    }

    init(intent: SprayPlanningIntent?, resolution: SprayPlanningResolution? = nil, isTemplate: Bool = false) {
        sprayerConfiguration = intent?.configuration?.rawValue
        sprayPlanningMethod = intent?.method?.rawValue
        fullTankSpecification = intent?.fullTankSpecification?.rawValue
        plannedApplicationAreaHa = intent?.targetAreaHa ?? resolution?.plannedAreaHa
        planningTankCapacityLitres = intent?.intendedTankLitres
        planningCalibratedLitresPerHectare = intent?.calibratedLitresPerHectare
        controllerLitresPer100mTravel = isTemplate ? nil : resolution?.controllerLitresPer100mTravel
        effectiveWorkingWidthMetres = isTemplate ? nil : resolution?.effectiveWorkingWidthMetres
    }

    var intent: SprayPlanningIntent? {
        guard sprayerConfiguration != nil || sprayPlanningMethod != nil || fullTankSpecification != nil ||
                plannedApplicationAreaHa != nil || planningTankCapacityLitres != nil || planningCalibratedLitresPerHectare != nil else { return nil }
        return SprayPlanningIntent(configuration: sprayerConfiguration.flatMap(SprayPassConfiguration.init(rawValue:)),
            method: sprayPlanningMethod.flatMap(SprayPlanningMethod.init(rawValue:)),
            fullTankSpecification: fullTankSpecification.flatMap(SprayFullTankSpecification.init(rawValue:)),
            intendedTankLitres: planningTankCapacityLitres, targetAreaHa: plannedApplicationAreaHa,
            calibratedLitresPerHectare: planningCalibratedLitresPerHectare)
    }

    /// Reconstruct only complete stored outputs, never resolve historical geometry or recompute CF.
    func resolution(totalLitres: Double?, rate: Double?, physicalRowRate: Double?, concentrationFactor: Double?) -> SprayPlanningResolution? {
        guard let litres = totalLitres, let area = plannedApplicationAreaHa, let rate,
              let concentrationFactor, sprayPlanningMethod != nil || controllerLitresPer100mTravel != nil || effectiveWorkingWidthMetres != nil else { return nil }
        return SprayPlanningResolution(intendedLitres: litres, plannedAreaHa: area, litresPerHectare: rate,
            physicalRowLitresPer100m: physicalRowRate, controllerLitresPer100mTravel: controllerLitresPer100mTravel,
            effectiveWorkingWidthMetres: effectiveWorkingWidthMetres, concentrationFactor: concentrationFactor)
    }
}
