import Foundation

extension BackendSprayRecordUpsert {
    /// Declared planning edits replace all v2 fields atomically, including obsolete NULL outputs.
    /// Historical records with no planning evidence keep the legacy wire inventory.
    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encodeIfPresent(tripId, forKey: .tripId)
        try c.encode(date, forKey: .date)
        try c.encode(startTime, forKey: .startTime)
        try c.encodeIfPresent(endTime, forKey: .endTime)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(windSpeed, forKey: .windSpeed)
        try c.encode(windDirection, forKey: .windDirection)
        try c.encodeIfPresent(humidity, forKey: .humidity)
        try c.encode(sprayReference, forKey: .sprayReference)
        try c.encode(notes, forKey: .notes)
        try c.encode(numberOfFansJets, forKey: .numberOfFansJets)
        try c.encodeIfPresent(averageSpeed, forKey: .averageSpeed)
        try c.encode(equipmentType, forKey: .equipmentType)
        try c.encode(tractor, forKey: .tractor)
        try c.encode(tractorGear, forKey: .tractorGear)
        try c.encodeIfPresent(machineId, forKey: .machineId)
        try c.encodeIfPresent(tractorId, forKey: .tractorId)
        try c.encodeIfPresent(sprayEquipmentId, forKey: .sprayEquipmentId)
        try c.encode(isTemplate, forKey: .isTemplate)
        try c.encode(operationType, forKey: .operationType)
        try c.encode(tanks, forKey: .tanks)
        try c.encodeIfPresent(grossAreaHa, forKey: .grossAreaHa)
        try c.encodeIfPresent(treatedAreaHa, forKey: .treatedAreaHa)
        try c.encodeIfPresent(applicationMode, forKey: .applicationMode)
        try c.encodeIfPresent(treatedAreaMethod, forKey: .treatedAreaMethod)
        try c.encodeIfPresent(bandWidthTotalMetres, forKey: .bandWidthTotalMetres)
        try c.encodeIfPresent(bandWidthLeftMetres, forKey: .bandWidthLeftMetres)
        try c.encodeIfPresent(bandWidthRightMetres, forKey: .bandWidthRightMetres)
        try c.encodeIfPresent(canonicalRowLengthMetres, forKey: .canonicalRowLengthMetres)
        try c.encodeIfPresent(rowSpacingMetres, forKey: .rowSpacingMetres)
        try c.encodeIfPresent(geometrySource, forKey: .geometrySource)
        try c.encodeIfPresent(geometryQuality, forKey: .geometryQuality)
        try c.encodeIfPresent(carrierVolumeBasis, forKey: .carrierVolumeBasis)
        try c.encodeIfPresent(totalCarrierLitres, forKey: .totalCarrierLitres)
        try c.encodeIfPresent(carrierLitresPerHectare, forKey: .carrierLitresPerHectare)
        try c.encodeIfPresent(diluteLitresPer100m, forKey: .diluteLitresPer100m)
        try c.encodeIfPresent(appliedLitresPer100m, forKey: .appliedLitresPer100m)
        try c.encodeIfPresent(concentrationFactor, forKey: .concentrationFactor)
        try c.encodeIfPresent(targets, forKey: .targets)
        try c.encodeIfPresent(sprayHeadTarget, forKey: .sprayHeadTarget)
        try c.encodeIfPresent(groundApplicationTarget, forKey: .groundApplicationTarget)
        try c.encodeIfPresent(carrierAreaBasis, forKey: .carrierAreaBasis)
        try c.encodeIfPresent(applicationBlocks, forKey: .applicationBlocks)
        try c.encodeIfPresent(sprayJobId, forKey: .sprayJobId)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        var fields = SprayPlanningWireFields(intent: nil)
        fields.sprayerConfiguration = sprayerConfiguration
        fields.sprayPlanningMethod = sprayPlanningMethod
        fields.fullTankSpecification = fullTankSpecification
        fields.planningInputProvenance = planningInputProvenance
        fields.planningIntendedTankLitres = planningIntendedTankLitres
        fields.planningTargetAreaHa = planningTargetAreaHa
        fields.planningCalibratedLitresPerHectare = planningCalibratedLitresPerHectare
        fields.plannedApplicationAreaHa = plannedApplicationAreaHa
        fields.resolvedPlanningCarrierLitres = resolvedPlanningCarrierLitres
        fields.resolvedPlanningLitresPerHectare = resolvedPlanningLitresPerHectare
        fields.resolvedPlanningPhysicalRowLitresPer100m = resolvedPlanningPhysicalRowLitresPer100m
        fields.resolvedPlanningConcentrationFactor = resolvedPlanningConcentrationFactor
        fields.controllerLitresPer100mTravel = controllerLitresPer100mTravel
        fields.effectiveWorkingWidthMetres = effectiveWorkingWidthMetres
        try fields.encode(to: encoder, inputsOnly: false, explicitClear: planningFieldsCleared)
    }
}
