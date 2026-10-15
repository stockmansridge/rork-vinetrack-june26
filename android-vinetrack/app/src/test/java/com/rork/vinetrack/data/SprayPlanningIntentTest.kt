package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.*
import com.rork.vinetrack.data.model.*
import kotlinx.serialization.json.Json
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class SprayPlanningIntentTest {
    @Test fun fourPlanningCombinationsRetainFrozenOutputsAndAdvisoryCFBehindGate() {
        for (pass in SprayPassConfiguration.entries) for (method in SprayPlanningMethod.entries) {
            val intent = SprayPlanningIntent(configuration = pass, method = method,
                fullTankSpecification = if (method == SprayPlanningMethod.FULL_TANK) SprayFullTankSpecification.TARGET_AREA else null,
                intendedTankLitres = if (method == SprayPlanningMethod.FULL_TANK) 1500.0 else null,
                targetAreaHa = if (method == SprayPlanningMethod.FULL_TANK) 3.0 else null,
                calibratedLitresPerHectare = 500.0)
            val output = requireNotNull(intent.resolve(10.0, 2.8, 1000.0))
            assertNull(intent.frozenResolutionBlocker(output))
            assertEquals(2.0, output.concentrationFactor, 0.0)
            assertEquals(if (method == SprayPlanningMethod.FULL_TANK) 1500.0 else 5000.0, output.intendedLitres, 0.0)
            val snapshot = SprayApplicationSnapshot(grossAreaHa = 10.0, planningIntent = intent, planningResolution = output)
            val wire = SprayPlanningWireFields.from(snapshot)
            val restored = Json.decodeFromString(SprayPlanningWireFields.serializer(), Json.encodeToString(SprayPlanningWireFields.serializer(), wire))
            assertEquals(intent, restored.intent)
            assertEquals(output, restored.resolution())
            // Unknown label approval contributes no denial; only the independent migration gate remains.
            assertNull(SprayPlanningOperationalGate.blocker(false, output.concentrationFactor, true))
            assertEquals(if (snapshot.planningIntent?.method == SprayPlanningMethod.BY_AREA) null else LegacySpraySetup.FULL_TANK_MESSAGE, SprayPlanningOperationalGate.blocker(snapshot, emptyList()))
            assertNotNull(intent.frozenResolutionBlocker(output.copy(controllerLitresPer100mTravel = 999.0)))
            assertNotNull(intent.frozenResolutionBlocker(output.copy(effectiveWorkingWidthMetres = null)))
            assertNotNull(intent.frozenResolutionBlocker(output.copy(concentrationFactor = Double.NaN)))
        }
    }

    @Test fun byAreaMeasuredRowCarrierIsNotRewrittenAsGrossAreaVolume() {
        val intent = SprayPlanningIntent(SprayPassConfiguration.OVER_ROW, SprayPlanningMethod.BY_AREA, calibratedLitresPerHectare = 500.0)
        val frozen = requireNotNull(intent.resolve(10.0, 2.8, 1000.0)).copy(intendedLitres = 4800.0)
        assertNull(intent.frozenResolutionBlocker(frozen))
        assertEquals(4800.0, frozen.intendedLitres, 0.0)
    }

    @Test fun aboveReferenceLabelReviewIsAdvisoryWithoutChangingCF() {
        assertEquals(1.0, SprayCarrierConversion.concentrationFactor(713.0, 750.0), 0.0)
        assertNull(SprayPlanningOperationalGate.blocker(false, 1.0, true))
        assertEquals(listOf("Copper", "Sulphur"), SprayPlanningOperationalGate.warningProducts(listOf(" Sulphur ", "Sulphur", "", "Copper")))
        assertFalse(SprayPlanningOperationalGate.WARNING_MESSAGE.contains("blocked"))
        assertEquals("Single Row", SprayPassConfiguration.STANDARD_PASS.title)
        assertEquals("Only Full Tanks", SprayPlanningMethod.FULL_TANK.title)
        assertEquals("\"standard_pass\"", Json.encodeToString(SprayPassConfiguration.serializer(), SprayPassConfiguration.STANDARD_PASS))
        assertEquals("\"full_tank\"", Json.encodeToString(SprayPlanningMethod.serializer(), SprayPlanningMethod.FULL_TANK))
    }

    @Test fun labelUncertaintyAloneDoesNotBlockSaveOrStart() {
        val tank = SprayTank("tank", concentrationFactor = 2.0, chemicals = listOf(SprayChemical("chemical", name = "Unverified sulphur", ratePer100L = 100.0)))
        val record = SprayRecord(id = "record", vineyardId = "vineyard", tanks = listOf(tank))
        assertNull(SprayPlanningOperationalGate.blocker(null, listOf(tank)))
        assertNull(SprayPlanningOperationalGate.tankConfirmationBlocker(record, record))
    }

    @Test fun regionalDecimalPlanningEntryRefusesPartialAndNonfiniteValues() {
        assertEquals(3.0, SprayControllerRateEntry.parse(" 3,00 ")!!, 0.0)
        assertEquals(1500.0, SprayControllerRateEntry.parse("1500.")!!, 0.0)
        for (text in listOf("", ".", "1..2", "NaN", "Infinity")) assertNull(SprayControllerRateEntry.parse(text))
    }

    @Test fun bothControllerRatesPreservePhysicalApplication() {
        for (rate in listOf(500.0, 600.0)) for (pass in SprayPassConfiguration.entries) {
            val travel = requireNotNull(SprayControllerRateEntry.displayed(rate, SprayCarrierBasis.LITRES_PER_100_METRES, pass, 2.8))
            assertEquals((if (rate == 500.0) 14.0 else 16.8) * pass.rowEquivalents, travel, 1e-8)
            assertEquals(rate, SprayControllerRateEntry.canonical(travel, SprayCarrierBasis.LITRES_PER_100_METRES, pass, 2.8)!!, 1e-8)
        }
    }

    @Test fun delayedTankConfirmationRequiresCurrentFrozenRecipe() {
        val captured = SprayRecord(id = "record", vineyardId = "vineyard")
        assertNull(SprayPlanningOperationalGate.tankConfirmationBlocker(captured, captured))
        val changed = captured.copy(sprayerConfiguration = "over_row_two_rows", sprayPlanningMethod = "full_tank",
            fullTankSpecification = "target_area", planningIntendedTankLitres = 1500.0, planningTargetAreaHa = 3.0)
        assertEquals(captured.id, changed.id)
        assertNotNull(SprayPlanningOperationalGate.tankConfirmationBlocker(changed, captured))
        assertNotNull(SprayPlanningOperationalGate.tankConfirmationBlocker(null, captured))
        assertEquals(LegacySpraySetup.FULL_TANK_MESSAGE, SprayPlanningOperationalGate.tankConfirmationBlocker(changed, changed))
    }

    @Test fun clearedPlanningRetainsUnrelatedFieldsAndDurableNullIntent() {
        val snapshot = SprayApplicationSnapshot(grossAreaHa = 10.0, rowSpacingMetres = 2.8, totalCarrierLitres = 1500.0,
            planningIntent = SprayPlanningIntent(SprayPassConfiguration.OVER_ROW, SprayPlanningMethod.FULL_TANK, SprayFullTankSpecification.TARGET_AREA, 1500.0, 3.0))
        val cleared = snapshot.clearingPlanning()
        val json = Json { encodeDefaults = false; explicitNulls = false }
        val reloaded = json.decodeFromString(SprayApplicationSnapshot.serializer(), json.encodeToString(SprayApplicationSnapshot.serializer(), cleared))
        assertEquals(cleared, reloaded)
        assertNull(reloaded.planningIntent)
        assertNull(reloaded.planningResolution)
        assertEquals(10.0, reloaded.grossAreaHa!!, 0.0)
        assertEquals(1500.0, reloaded.totalCarrierLitres!!, 0.0)
        assertEquals(true, reloaded.templateConfiguration()?.planningFieldsCleared)
        val base = kotlinx.serialization.json.buildJsonObject { put("notes", kotlinx.serialization.json.JsonPrimitive("Retained notes")) }
        val body = SprayPlanningWireFields.from(reloaded).merging(base, json, explicitClear = reloaded.planningFieldsCleared == true)
        SprayPlanningWireFields.RECORD_KEYS.forEach { assertEquals(kotlinx.serialization.json.JsonNull, body[it]) }
        assertEquals(base["notes"], body["notes"])
        assertFalse(body.containsKey("planningFieldsCleared"))
        assertNotNull(SprayPlanningOperationalGate.blocker(reloaded, emptyList()))
        assertEquals(base, SprayPlanningWireFields.from(null).merging(base, json))
    }

    @Test fun templateEditorRetainsPlanningAndOnlyExplicitEditsReplaceInputs() {
        val intent = SprayPlanningIntent(SprayPassConfiguration.OVER_ROW, SprayPlanningMethod.FULL_TANK, SprayFullTankSpecification.TARGET_AREA, 1500.0, 3.0)
        val record = SprayRecord(id = "synthetic", vineyardId = "synthetic-vineyard", sprayReference = "Synthetic step", isTemplate = true,
            notes = "Unrelated edit", temperature = 20.0, windSpeed = 5.0, tripId = "retained-trip", date = "2026-10-13", startTime = "2026-10-13",
            tanks = listOf(SprayTank(id = "retained-tank", waterVolume = 1500.0, sprayRatePerHa = 500.0)),
            carrierVolumeBasis = "l_per_ha", carrierLitresPerHectare = 500.0, sprayHeadTarget = SprayHeadTarget.FULL_CANOPY.raw,
            sprayerConfiguration = intent.configuration?.wireValue, sprayPlanningMethod = intent.method?.wireValue,
            fullTankSpecification = intent.fullTankSpecification?.wireValue, planningIntendedTankLitres = 1500.0, planningTargetAreaHa = 3.0)
        val draft = SprayProgramStepDraft.fromLocal(record).copy(notes = "Unrelated edit")
        assertEquals(intent, draft.toLocalInput(record).applicationGeometry?.planningIntent)
        assertNull(draft.toLocalInput(record).applicationGeometry?.planningResolution)
        assertEquals(record.applicationGeometry?.carrierVolumeBasis, draft.toLocalInput(record).applicationGeometry?.carrierVolumeBasis)
        assertEquals(record.applicationGeometry?.sprayHeadTarget, draft.toLocalInput(record).applicationGeometry?.sprayHeadTarget)
        assertFalse(draft.portalPayload(null).containsKey("planning_target_area_ha"))
        val edited = draft.copy(planningIntent = intent.copy(targetAreaHa = 2.0))
        assertEquals(kotlinx.serialization.json.JsonPrimitive(2.0), edited.portalPayload(null)["planning_target_area_ha"])
        val replacement = draft.copy(planningIntent = intent.copy(fullTankSpecification = SprayFullTankSpecification.CALIBRATED_RATE,
            targetAreaHa = null, calibratedLitresPerHectare = 600.0))
        assertEquals(kotlinx.serialization.json.JsonNull, replacement.portalPayload(null)["planning_target_area_ha"])
        assertEquals(kotlinx.serialization.json.JsonPrimitive(600.0), replacement.portalPayload(null)["planning_calibrated_litres_per_hectare"])
        val cleared = draft.copy(planningIntent = null)
        val body = cleared.portalPayload(null)
        assertEquals(draft.portalPayload(null), kotlinx.serialization.json.JsonObject(body.filterKeys { it !in SprayPlanningWireFields.INPUT_KEYS }))
        assertEquals(draft.toLocalInput(record).copy(applicationGeometry = null), cleared.toLocalInput(record).copy(applicationGeometry = null))
        SprayPlanningWireFields.INPUT_KEYS.forEach { assertEquals(kotlinx.serialization.json.JsonNull, body[it]) }
        assertFalse(body.containsKey("resolved_planning_carrier_litres"))
        assertEquals(true, cleared.toLocalInput(record).applicationGeometry?.planningFieldsCleared)
        assertEquals(record.applicationGeometry?.carrierLitresPerHectare, cleared.toLocalInput(record).applicationGeometry?.carrierLitresPerHectare)
        assertEquals(record.applicationGeometry?.sprayHeadTarget, cleared.toLocalInput(record).applicationGeometry?.sprayHeadTarget)
    }

    @Test fun unrelatedPortalEditsPreserveTargetWordingWithoutChangingCanonicalIdentifiers() {
        val row = SprayJobTemplateRepository.PortalProgramStepRow(id = "synthetic", vineyardId = "vineyard", name = "Synthetic step",
            growthStageCode = null, operationType = "Foliar Spray", target = "Phomopsis · Powdery Mildew", targets = null,
            notes = "Keep notes", equipmentId = null, tractorId = null, chemicalLines = null)
        val draft = SprayProgramStepDraft.fromPortalRow(row)
        val edited = draft.copy(notes = "Unrelated change")
        assertEquals("Phomopsis · Powdery Mildew", edited.targetDisplay)
        assertEquals(draft.portalPayload(null)["targets"], edited.portalPayload(null)["targets"])
        assertEquals(kotlinx.serialization.json.JsonPrimitive(row.target), edited.portalPayload(null)["target"])
        val cleared = edited.copy(targets = emptyList())
        assertNull(cleared.targetDisplay)
        assertEquals(kotlinx.serialization.json.JsonNull, cleared.portalPayload(null)["target"])
    }

    @Test fun selectedControllerEntryConvertsToOnePhysicalRateAcrossConfigurationChanges() {
        val standard = requireNotNull(SprayControllerRateEntry.canonical(16.8, SprayCarrierBasis.LITRES_PER_100_METRES, SprayPassConfiguration.STANDARD_PASS, 2.8))
        assertEquals(600.0, standard, 0.00000001)
        val over = requireNotNull(SprayControllerRateEntry.displayed(standard, SprayCarrierBasis.LITRES_PER_100_METRES, SprayPassConfiguration.OVER_ROW, 2.8))
        assertEquals(33.6, over, 0.00000001)
        val restored = requireNotNull(SprayControllerRateEntry.canonical(over, SprayCarrierBasis.LITRES_PER_100_METRES, SprayPassConfiguration.OVER_ROW, 2.8))
        assertEquals(standard, restored, 0.00000001)
        assertEquals(restored, SprayControllerRateEntry.displayed(restored, SprayCarrierBasis.LITRES_PER_HECTARE, SprayPassConfiguration.STANDARD_PASS, null)!!, 0.0)
        assertNull(SprayControllerRateEntry.canonical(16.8, SprayCarrierBasis.LITRES_PER_100_METRES, SprayPassConfiguration.OVER_ROW, null))
        assertNull(SprayControllerRateEntry.canonical(0.0, SprayCarrierBasis.LITRES_PER_HECTARE, null, null))
    }

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
        assertEquals(LegacySpraySetup.FULL_TANK_MESSAGE, flow.operationalBlocker)
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
            "full_tank_specification":"target_area","planning_intended_tank_litres":1500,
            "planning_target_area_ha":3,"planned_application_area_ha":3,"planning_calibrated_litres_per_hectare":500,
            "resolved_planning_carrier_litres":1500,"resolved_planning_litres_per_hectare":500,
            "resolved_planning_physical_row_litres_per_100m":14,"resolved_planning_concentration_factor":1.2,
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
        assertEquals(if (snapshot.planningIntent?.method == SprayPlanningMethod.BY_AREA) null else LegacySpraySetup.FULL_TANK_MESSAGE, SprayPlanningOperationalGate.blocker(snapshot, emptyList()))
    }

    @Test fun v2ProjectionSeparatesInputsOutputsAndClearsStaleResolution() {
        val json = Json { encodeDefaults = false }
        val provenance = SprayPlanningInputProvenance(" 1500.00 ", "", "600.00", "litres", "hectares", "hectare", "AU")
        val intent = SprayPlanningIntent(SprayPassConfiguration.STANDARD_PASS, SprayPlanningMethod.FULL_TANK,
            SprayFullTankSpecification.CALIBRATED_RATE, 1500.0, calibratedLitresPerHectare = 600.0, inputProvenance = provenance)
        val output = requireNotNull(intent.resolve(8.0, 2.8, 713.0))
        val fields = SprayPlanningWireFields.from(SprayApplicationSnapshot(planningIntent = intent, planningResolution = output))
        assertNull(fields.planningTargetAreaHa)
        assertEquals(2.5, fields.plannedApplicationAreaHa!!, 0.0)
        assertEquals(output, fields.resolution())
        val empty = kotlinx.serialization.json.JsonObject(emptyMap())
        val patch = fields.merging(empty, json)
        assertEquals(SprayPlanningWireFields.RECORD_KEYS, patch.keys)
        assertFalse(patch.containsKey("planning_tank_capacity_litres"))
        assertEquals(kotlinx.serialization.json.JsonNull, patch["planning_target_area_ha"])
        assertEquals(" 1500.00 ", fields.planningInputProvenance!!.tankText)
        assertEquals(1, fields.planningInputProvenance.schemaVersion)
        val edited = SprayPlanningWireFields.from(SprayApplicationSnapshot(planningIntent = SprayPlanningIntent(configuration = SprayPassConfiguration.OVER_ROW, method = SprayPlanningMethod.BY_AREA)))
        val replacement = edited.merging(empty, json)
        assertEquals(kotlinx.serialization.json.JsonNull, replacement["full_tank_specification"])
        assertEquals(kotlinx.serialization.json.JsonNull, replacement["resolved_planning_carrier_litres"])
        assertNull(edited.resolution())
        assertEquals(SprayPlanningWireFields.INPUT_KEYS, fields.merging(empty, json, template = true).keys)
        val clear = SprayPlanningWireFields.from(null).merging(empty, json, explicitClear = true)
        assertEquals(SprayPlanningWireFields.RECORD_KEYS, clear.keys)
        assertTrue(clear.values.all { it == kotlinx.serialization.json.JsonNull })
    }

    @Test fun capturedGallonsNeverUseCurrentAccountCountry() {
        for ((country, unit) in listOf("US" to "us_gallons", "CA" to "us_gallons", "GB" to "imperial_gallons")) {
            val original = SprayPlanningInputProvenance("123.000", " 3 ", "", "gallons", "acres", "acre", country)
            val wire = SprayPlanningWireProvenance(original)
            assertEquals(unit, wire.volumeUnit)
            val reopened = Json.decodeFromString(SprayPlanningWireProvenance.serializer(), Json.encodeToString(SprayPlanningWireProvenance.serializer(), wire))
            assertEquals(original.tankText, reopened.local.tankText)
            assertEquals(unit, reopened.local.volumeUnit)
            assertEquals(country, reopened.local.countryCode)
        }
    }

    @Test fun complianceIsPerTankAndRejectsMissingInvalidAndAmbiguousDiluteEvidence() {
        val dilute = SprayChemical("dilute", name = "Dilute product", ratePer100L = 100.0)
        val area = SprayChemical("area", name = "Area product", ratePerHa = 2.0, rateBasis = SprayProductRateBasis.WHOLE_BLOCK_AREA.raw)
        val mixed = listOf(SprayTank("safe", concentrationFactor = 1.0, chemicals = listOf(dilute)), SprayTank("area", concentrationFactor = 4.0, chemicals = listOf(area)))
        assertNull(SprayPlanningOperationalGate.blocker(null, mixed))
        for (factor in listOf(0.0, -1.0, 0.9, Double.POSITIVE_INFINITY, Double.NaN)) {
            assertTrue(SprayPlanningOperationalGate.blocker(null, listOf(SprayTank("invalid", concentrationFactor = factor, chemicals = listOf(dilute))))!!.contains("Dilute product"))
        }
        assertNotNull(SprayPlanningOperationalGate.blocker(false, null, true))
        val ambiguous = SprayChemical("ambiguous", name = "Ambiguous", ratePerHa = 1.0, ratePer100L = 1.0)
        assertTrue(SprayPlanningOperationalGate.blocker(null, listOf(SprayTank("ambiguous", concentrationFactor = 1.0, chemicals = listOf(ambiguous))))!!.contains("Ambiguous"))
    }

    @Test fun canopyComparisonHasMinimumOneWithoutAuthorisingConcentrate() {
        for ((rate, factor) in listOf(750.0 to 1.0, 500.0 to 1.426)) {
            val intent = SprayPlanningIntent(SprayPassConfiguration.OVER_ROW, SprayPlanningMethod.BY_AREA, calibratedLitresPerHectare = rate)
            assertEquals(factor, intent.resolve(8.0, 2.8, 713.0)!!.concentrationFactor, 0.00000001)
        }
    }

    @Test fun namedChemicalBlockerDoesNotBlockAreaOnlyMixes() {
        val dilute = SprayChemical("dilute", name = "Unverified sulphur", ratePer100L = 100.0)
        val tanks = listOf(SprayTank("tank", concentrationFactor = 2.0, chemicals = listOf(dilute)))
        assertNull(SprayPlanningOperationalGate.blocker(null, tanks))
        val area = SprayChemical("area", name = "Area only", ratePerHa = 2000.0, rateBasis = SprayProductRateBasis.WHOLE_BLOCK_AREA.raw)
        assertNull(SprayPlanningOperationalGate.blocker(null, listOf(tanks.single().copy(chemicals = listOf(area)))))
    }

    @Test fun cfNeverAuthorisesConcentrateAndUndeployedIntentAlwaysBlocks() {
        assertNull(SprayPlanningOperationalGate.blocker(false, 2.0, true))
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
        assertEquals(LegacySpraySetup.FULL_TANK_MESSAGE, restored.lastError)
    }
}
