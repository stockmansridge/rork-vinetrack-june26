package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.*
import com.rork.vinetrack.data.model.*
import kotlinx.serialization.json.Json
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class SprayPlanningIntentTest {
    @Test fun physicalRowAndControllerTravelNeverShareAnOverRowMultiplier() {
        val standard = SprayPlanningIntent(SprayPassConfiguration.STANDARD_PASS, SprayPlanningMethod.BY_AREA, calibratedLitresPerHectare = 500.0)
        val a = requireNotNull(standard.resolve(10.0, 2.8, 500.0))
        val b = requireNotNull(standard.copy(configuration = SprayPassConfiguration.OVER_ROW).resolve(10.0, 2.8, 500.0))
        assertEquals(14.0, a.physicalRowLitresPer100m!!, 0.00001)
        assertEquals(14.0, b.physicalRowLitresPer100m!!, 0.00001)
        assertEquals(28.0, b.controllerLitresPer100mTravel!!, 0.00001)
        assertEquals(5.6, b.effectiveWorkingWidthMetres!!, 0.00001)
        assertEquals(a.intendedLitres, b.intendedLitres, 0.0)
    }

    @Test fun targetAreaAndCalibrationAgreeForFullTank() {
        val target = SprayPlanningIntent(SprayPassConfiguration.OVER_ROW, SprayPlanningMethod.FULL_TANK, SprayFullTankSpecification.TARGET_AREA, 1000.0, 2.0)
        val rate = target.copy(fullTankSpecification = SprayFullTankSpecification.CALIBRATED_RATE, targetAreaHa = null, calibratedLitresPerHectare = 500.0)
        val a = requireNotNull(target.resolve(10.0, 2.8, 1000.0))
        assertEquals(a, rate.resolve(10.0, 2.8, 1000.0))
        assertEquals(2.0, a.plannedAreaHa, 0.0)
        assertEquals(2.0, a.concentrationFactor, 0.0)
    }

    @Test fun invalidAndUnrecordedInputsNeverBecomeKnownDefaults() {
        val intent = SprayPlanningIntent(SprayPassConfiguration.STANDARD_PASS, SprayPlanningMethod.FULL_TANK, SprayFullTankSpecification.TARGET_AREA, 1000.0, 2.0)
        for (area in listOf(0.0, -1.0, 11.0, Double.NaN, Double.POSITIVE_INFINITY)) assertNull(intent.copy(targetAreaHa = area).resolve(10.0, 2.8, 500.0))
        assertNull(intent.copy(configuration = null).resolve(10.0, 2.8, 500.0))
        assertNull(SprayPlanningIntent().resolve(10.0, 2.8, 500.0))
    }

    @Test fun fullTankUsesUnchangedChemicalEngineAndDoesNotAllocatePartialBlocks() {
        val inputs = SprayGuidedInputs(
            blocks = listOf(SprayBlockInput("A", grossAreaHectares = 10.0, mappedRowLengthMetres = 35714.285714, rowSpacingMetres = 2.8)),
            targets = setOf(SprayTarget.POWDERY_MILDEW), sprayHeadTarget = SprayHeadTarget.FULL_CANOPY,
            isGrowthStageAssigned = true, isEquipmentSelected = true, isEquipmentConfirmed = true,
            tankCapacityLitres = 1000.0, isCanopyConfirmed = true,
            canopy = SprayCanopySelection.prefilled(SprayCalculator.CanopySize.MEDIUM, SprayCalculator.CanopyDensity.HIGH),
            planningIntent = SprayPlanningIntent(SprayPassConfiguration.OVER_ROW, SprayPlanningMethod.FULL_TANK, SprayFullTankSpecification.TARGET_AREA, 1000.0, 2.0),
            products = listOf(SprayProductLineInput("area", "Area product", "L", SprayProductRateBasis.WHOLE_BLOCK_AREA, 3.0)),
        )
        val flow = SprayGuidedFlow(inputs)
        assertTrue(flow.isComplete)
        assertEquals(1000.0, flow.plan.totalCarrierLitres, 0.00001)
        assertEquals(6.0, flow.plan.productLines.single().totalQuantity!!, 0.00001)
        assertEquals(10.0, flow.plan.grossAreaHectares, 0.0)
        assertNull(flow.plan.treatedAreaHectares)
        val snapshot = requireNotNull(flow.snapshot)
        assertNull(snapshot.blocks)
        assertNull(snapshot.canonicalRowLengthMetres)
        assertEquals(2.0, snapshot.planningResolution!!.plannedAreaHa, 0.0)
        assertEquals(SprayPlanningOperationalGate.MIGRATION_MESSAGE, flow.operationalBlocker)
        val row = inputs.copy(products = listOf(SprayProductLineInput("row", "Row product", "L", SprayProductRateBasis.PER_100_METRES, 1.0)))
        assertFalse(SprayGuidedFlow(row).isComplete)
        assertNull(SprayGuidedFlow(inputs.copy(planningIntent = inputs.planningIntent!!.copy(intendedTankLitres = 1001.0))).planningResolution)
    }

    @Test fun byAreaCardUsesExistingMappedRowCarrierNotAnIndependentAreaTotal() {
        val inputs = SprayGuidedInputs(blocks = listOf(SprayBlockInput("A", grossAreaHectares = 10.0, mappedRowLengthMetres = 10000.0, rowSpacingMetres = 2.8)),
            canopy = SprayCanopySelection.prefilled(SprayCalculator.CanopySize.MEDIUM, SprayCalculator.CanopyDensity.HIGH), isCanopyConfirmed = true,
            carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES, sprayVolumeChoice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE,
            customSprayerBasis = SprayCarrierBasis.LITRES_PER_100_METRES, customSprayerRate = 10.0,
            planningIntent = SprayPlanningIntent(SprayPassConfiguration.STANDARD_PASS, SprayPlanningMethod.BY_AREA))
        val flow = SprayGuidedFlow(inputs)
        assertEquals(1000.0, flow.carrier!!.totalLitres, 0.00001)
        assertEquals(1000.0, flow.planningResolution!!.intendedLitres, 0.00001)
    }

    @Test fun localSnapshotsAndOutboxPayloadsRetainIntentBasisAndFrozenOutputs() {
        val json = Json { encodeDefaults = true }
        val intent = SprayPlanningIntent(SprayPassConfiguration.OVER_ROW, SprayPlanningMethod.FULL_TANK, SprayFullTankSpecification.TARGET_AREA, 1000.0, 2.0,
            inputProvenance = SprayPlanningInputProvenance("264.172052", "4.9421076", "", "gallons", "acres", "acre", "US"))
        val snapshot = SprayApplicationSnapshot(rowSpacingMetres = 2.8, carrierVolumeBasis = SprayCarrierBasis.LITRES_PER_100_METRES,
            planningIntent = intent, planningResolution = intent.resolve(10.0, 2.8, 1000.0))
        val restored = json.decodeFromString(SprayApplicationSnapshot.serializer(), json.encodeToString(SprayApplicationSnapshot.serializer(), snapshot))
        assertEquals(snapshot, restored)
        assertEquals(snapshot.planningResolution, restored.withBlocks(null)!!.planningResolution)
        assertEquals(intent, restored.templateConfiguration()!!.planningIntent)
        assertNull(restored.templateConfiguration()!!.planningResolution)
        val payload = SprayRecordUpdateSync.Payload("original", "2026-10-12", "2026-10-12", applicationGeometry = snapshot, clientUpdatedAt = "original-revision")
        assertEquals(payload, json.decodeFromString(SprayRecordUpdateSync.Payload.serializer(), json.encodeToString(SprayRecordUpdateSync.Payload.serializer(), payload)))
        val historical = json.decodeFromString(SprayApplicationSnapshot.serializer(), "{\"carrierVolumeBasis\":\"l_per_ha\",\"totalCarrierLitres\":500}")
        assertNull(historical.planningIntent)
        assertNull(historical.planningResolution)
        assertEquals(500.0, historical.totalCarrierLitres!!, 0.0)
    }

    @Test fun acceptanceNumbersAndTamperedFullTankResolution() {
        val standard = SprayPlanningIntent(SprayPassConfiguration.STANDARD_PASS, SprayPlanningMethod.BY_AREA, calibratedLitresPerHectare = 600.0)
        val a = requireNotNull(standard.resolve(3.0, 2.8, 600.0))
        val b = requireNotNull(standard.copy(configuration = SprayPassConfiguration.OVER_ROW).resolve(3.0, 2.8, 600.0))
        assertEquals(16.8, a.controllerLitresPer100mTravel!!, 0.00000001)
        assertEquals(33.6, b.controllerLitresPer100mTravel!!, 0.00000001)
        val target = SprayPlanningIntent(SprayPassConfiguration.OVER_ROW, SprayPlanningMethod.FULL_TANK, SprayFullTankSpecification.TARGET_AREA, 1500.0, 3.0)
        val resolved = requireNotNull(target.resolve(10.0, 2.8, 600.0))
        assertEquals(500.0, resolved.litresPerHectare, 0.0)
        assertNull(target.fullTankExecutionBlocker(resolved, 10.0))
        assertNotNull(target.fullTankExecutionBlocker(resolved.copy(litresPerHectare = 600.0), 10.0))
        assertNotNull(target.fullTankExecutionBlocker(null, 10.0))
        val calibrated = target.copy(fullTankSpecification = SprayFullTankSpecification.CALIBRATED_RATE, targetAreaHa = null, calibratedLitresPerHectare = 600.0)
        assertEquals(2.5, calibrated.resolve(10.0, 2.8, 600.0)!!.plannedAreaHa, 0.0)
        assertNull(SprayPlanningIntent().fullTankExecutionBlocker(null, null))
    }

    @Test fun reviewedFlatWireFieldsRoundTripAndLegacyColumnsStayAbsent() {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val remote = json.decodeFromString(SprayRecord.serializer(), """{"id":"record","vineyard_id":"vineyard",
            "sprayer_configuration":"over_row_two_rows","spray_planning_method":"full_tank",
            "full_tank_specification":"target_area","planning_tank_capacity_litres":1500,
            "planned_application_area_ha":3,"planning_calibrated_litres_per_hectare":500,
            "gross_area_ha":10,"total_carrier_litres":1500,"carrier_litres_per_hectare":500,"applied_litres_per_100m":14,
            "controller_litres_per_100m_travel":28,"effective_working_width_metres":5.6,"concentration_factor":1.2}""")
        val snapshot = requireNotNull(remote.applicationGeometry)
        assertEquals(SprayPassConfiguration.OVER_ROW, snapshot.planningIntent!!.configuration)
        assertEquals(14.0, snapshot.appliedLitresPer100m!!, 0.0)
        assertEquals(28.0, snapshot.planningResolution!!.controllerLitresPer100mTravel!!, 0.0)
        assertEquals(remote, json.decodeFromString(SprayRecord.serializer(), json.encodeToString(SprayRecord.serializer(), remote)))
        val fields = SprayPlanningWireFields.from(snapshot)
        assertEquals(snapshot.planningIntent, fields.intent)
        val empty = kotlinx.serialization.json.JsonObject(emptyMap())
        assertEquals(empty, SprayPlanningWireFields.from(null).merging(empty, json))
        assertNull(SprayPlanningWireFields.from(snapshot, template = true).controllerLitresPer100mTravel)
        assertEquals(SprayPlanningOperationalGate.MIGRATION_MESSAGE, SprayPlanningOperationalGate.blocker(snapshot, emptyList()))
    }

    @Test fun namedChemicalBlockerDoesNotBlockAreaOnlyMixes() {
        val dilute = SprayChemical("dilute", name = "Unverified sulphur", ratePer100L = 100.0)
        val tanks = listOf(SprayTank("tank", concentrationFactor = 2.0, chemicals = listOf(dilute)))
        assertTrue(SprayPlanningOperationalGate.blocker(null, tanks)!!.contains("Unverified sulphur"))
        val area = SprayChemical("area", name = "Area only", ratePerHa = 2000.0, rateBasis = SprayProductRateBasis.WHOLE_BLOCK_AREA.raw)
        assertNull(SprayPlanningOperationalGate.blocker(null, listOf(tanks.single().copy(chemicals = listOf(area)))))
    }

    @Test fun cfNeverAuthorisesConcentrateAndUndeployedIntentAlwaysBlocks() {
        assertEquals(SprayPlanningOperationalGate.CONCENTRATE_MESSAGE, SprayPlanningOperationalGate.blocker(false, 2.0, true))
        assertEquals(SprayPlanningOperationalGate.MIGRATION_MESSAGE, SprayPlanningOperationalGate.blocker(true, 1.0, false))
        assertNull(SprayPlanningOperationalGate.blocker(false, 1.0, true))
    }

    @Test fun blockedReplayRetainsExactOriginalPayloadWithoutCallingAnyRepository() = runBlocking {
        val json = Json { encodeDefaults = true }
        val snapshot = SprayApplicationSnapshot(planningIntent = SprayPlanningIntent(configuration = SprayPassConfiguration.OVER_ROW))
        val payload = SprayRecordUpdateSync.Payload("original", "2026-10-12", "2026-10-12", applicationGeometry = snapshot, clientUpdatedAt = "original-revision")
        val bytes = json.encodeToString(SprayRecordUpdateSync.Payload.serializer(), payload)
        val disk = InMemoryPendingWriteStore()
        val outbox = PendingWriteRepository(disk)
        val queued = outbox.enqueue(PendingEntityType.SPRAY_RECORD, PendingOpType.UPDATE, bytes, "original")
        var published = false
        SprayRecordUpdateSync(outbox).replayAll { published = true }
        val restored = PendingWriteRepository(disk).list().single()
        assertFalse(published)
        assertEquals(queued.id, restored.id)
        assertEquals(bytes, restored.payloadJson)
        assertEquals(PendingWriteStatus.BLOCKED, restored.status)
        assertEquals(0, restored.attemptCount)
        assertEquals(SprayPlanningOperationalGate.MIGRATION_MESSAGE, restored.lastError)
    }
}
