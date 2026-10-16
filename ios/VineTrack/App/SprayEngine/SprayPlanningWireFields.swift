import Foundation

/// Exact v2 projection. Serialization does not authorize an operational write.
nonisolated struct SprayPlanningWireFields: Codable, Sendable, Hashable {
    var sprayerConfiguration: String? = nil
    var sprayPlanningMethod: String? = nil
    var fullTankSpecification: String? = nil
    var planningInputProvenance: SprayPlanningWireProvenance? = nil
    var planningIntendedTankLitres: Double? = nil
    var planningTargetAreaHa: Double? = nil
    var planningCalibratedLitresPerHectare: Double? = nil
    var plannedApplicationAreaHa: Double? = nil
    var resolvedPlanningCarrierLitres: Double? = nil
    var resolvedPlanningLitresPerHectare: Double? = nil
    var resolvedPlanningPhysicalRowLitresPer100m: Double? = nil
    var resolvedPlanningConcentrationFactor: Double? = nil
    var controllerLitresPer100mTravel: Double? = nil
    var effectiveWorkingWidthMetres: Double? = nil

    enum CodingKeys: String, CodingKey {
        case sprayerConfiguration = "sprayer_configuration"
        case sprayPlanningMethod = "spray_planning_method"
        case fullTankSpecification = "full_tank_specification"
        case planningInputProvenance = "planning_input_provenance"
        case planningIntendedTankLitres = "planning_intended_tank_litres"
        case planningTargetAreaHa = "planning_target_area_ha"
        case planningCalibratedLitresPerHectare = "planning_calibrated_litres_per_hectare"
        case plannedApplicationAreaHa = "planned_application_area_ha"
        case resolvedPlanningCarrierLitres = "resolved_planning_carrier_litres"
        case resolvedPlanningLitresPerHectare = "resolved_planning_litres_per_hectare"
        case resolvedPlanningPhysicalRowLitresPer100m = "resolved_planning_physical_row_litres_per_100m"
        case resolvedPlanningConcentrationFactor = "resolved_planning_concentration_factor"
        case controllerLitresPer100mTravel = "controller_litres_per_100m_travel"
        case effectiveWorkingWidthMetres = "effective_working_width_metres"
    }

    init(intent: SprayPlanningIntent?, resolution: SprayPlanningResolution? = nil, isTemplate: Bool = false) {
        sprayerConfiguration = intent?.configuration?.rawValue
        sprayPlanningMethod = intent?.method?.rawValue
        fullTankSpecification = intent?.fullTankSpecification?.rawValue
        planningInputProvenance = intent?.inputProvenance.map(SprayPlanningWireProvenance.init)
        planningIntendedTankLitres = intent?.intendedTankLitres
        planningTargetAreaHa = intent?.targetAreaHa
        planningCalibratedLitresPerHectare = intent?.calibratedLitresPerHectare
        if !isTemplate {
            plannedApplicationAreaHa = resolution?.plannedAreaHa
            resolvedPlanningCarrierLitres = resolution?.intendedLitres
            resolvedPlanningLitresPerHectare = resolution?.litresPerHectare
            resolvedPlanningPhysicalRowLitresPer100m = resolution?.physicalRowLitresPer100m
            resolvedPlanningConcentrationFactor = resolution?.concentrationFactor
            controllerLitresPer100mTravel = resolution?.controllerLitresPer100mTravel
            effectiveWorkingWidthMetres = resolution?.effectiveWorkingWidthMetres
        }
    }

    var intent: SprayPlanningIntent? {
        guard sprayerConfiguration != nil || sprayPlanningMethod != nil || fullTankSpecification != nil ||
                planningInputProvenance != nil || planningTargetAreaHa != nil || planningIntendedTankLitres != nil ||
                planningCalibratedLitresPerHectare != nil else { return nil }
        return SprayPlanningIntent(configuration: sprayerConfiguration.flatMap(SprayPassConfiguration.init(rawValue:)),
            method: sprayPlanningMethod.flatMap(SprayPlanningMethod.init(rawValue:)),
            fullTankSpecification: fullTankSpecification.flatMap(SprayFullTankSpecification.init(rawValue:)),
            intendedTankLitres: planningIntendedTankLitres, targetAreaHa: planningTargetAreaHa,
            calibratedLitresPerHectare: planningCalibratedLitresPerHectare,
            inputProvenance: planningInputProvenance?.local)
    }

    /// Never substitute legacy geometry, current settings or inputs for absent frozen outputs.
    func resolution() -> SprayPlanningResolution? {
        guard let litres = resolvedPlanningCarrierLitres, let area = plannedApplicationAreaHa,
              let rate = resolvedPlanningLitresPerHectare else { return nil }
        let factor = resolvedPlanningConcentrationFactor ?? 1.0
        return SprayPlanningResolution(intendedLitres: litres, plannedAreaHa: area, litresPerHectare: rate,
            physicalRowLitresPer100m: resolvedPlanningPhysicalRowLitresPer100m,
            controllerLitresPer100mTravel: controllerLitresPer100mTravel,
            effectiveWorkingWidthMetres: effectiveWorkingWidthMetres, concentrationFactor: factor)
    }

    /// A declared mutation replaces the complete tuple, including explicit NULLs for obsolete values.
    /// Absent historical planning is omitted unless the caller explicitly requests clearing.
    func encode(to encoder: Encoder) throws {
        try encode(to: encoder, inputsOnly: false, explicitClear: false)
    }

    func encode(to encoder: Encoder, inputsOnly: Bool, explicitClear: Bool = false) throws {
        guard explicitClear || intent != nil || resolution() != nil else { return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sprayerConfiguration, forKey: .sprayerConfiguration)
        try c.encode(sprayPlanningMethod, forKey: .sprayPlanningMethod)
        try c.encode(fullTankSpecification, forKey: .fullTankSpecification)
        try c.encode(planningInputProvenance, forKey: .planningInputProvenance)
        try c.encode(planningIntendedTankLitres, forKey: .planningIntendedTankLitres)
        try c.encode(planningTargetAreaHa, forKey: .planningTargetAreaHa)
        try c.encode(planningCalibratedLitresPerHectare, forKey: .planningCalibratedLitresPerHectare)
        if !inputsOnly {
            try c.encode(plannedApplicationAreaHa, forKey: .plannedApplicationAreaHa)
            try c.encode(resolvedPlanningCarrierLitres, forKey: .resolvedPlanningCarrierLitres)
            try c.encode(resolvedPlanningLitresPerHectare, forKey: .resolvedPlanningLitresPerHectare)
            try c.encode(resolvedPlanningPhysicalRowLitresPer100m, forKey: .resolvedPlanningPhysicalRowLitresPer100m)
            try c.encode(resolvedPlanningConcentrationFactor, forKey: .resolvedPlanningConcentrationFactor)
            try c.encode(controllerLitresPer100mTravel, forKey: .controllerLitresPer100mTravel)
            try c.encode(effectiveWorkingWidthMetres, forKey: .effectiveWorkingWidthMetres)
        }
    }
}

/// Wire-only versioned provenance; existing local snapshot coding remains backwards compatible.
nonisolated struct SprayPlanningWireProvenance: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let tankText: String
    let areaText: String
    let rateText: String
    let volumeUnit: String
    let areaUnit: String
    let rateAreaUnit: String
    let countryCode: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case tankText = "tank_text"
        case areaText = "area_text"
        case rateText = "rate_text"
        case volumeUnit = "volume_unit"
        case areaUnit = "area_unit"
        case rateAreaUnit = "rate_area_unit"
        case countryCode = "country_code"
    }

    init(_ local: SprayPlanningInputProvenance) {
        schemaVersion = 1
        tankText = local.tankText
        areaText = local.areaText
        rateText = local.rateText
        volumeUnit = local.volumeUnit == "gallons"
            ? (["US", "CA"].contains(local.countryCode.uppercased()) ? "us_gallons" : "imperial_gallons")
            : local.volumeUnit
        areaUnit = local.areaUnit
        rateAreaUnit = local.rateAreaUnit
        countryCode = local.countryCode
    }

    var local: SprayPlanningInputProvenance {
        SprayPlanningInputProvenance(tankText: tankText, areaText: areaText, rateText: rateText,
            volumeUnit: volumeUnit, areaUnit: areaUnit, rateAreaUnit: rateAreaUnit, countryCode: countryCode)
    }
}
